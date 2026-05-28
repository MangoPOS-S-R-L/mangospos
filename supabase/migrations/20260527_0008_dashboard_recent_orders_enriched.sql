-- =============================================================================
-- Segunda pasada sobre fn_dashboard_recent_orders. Agregamos data para que
-- la fila del dashboard sea ACTIONABLE:
--
--   - origin       (dine_in / takeout / delivery / quick / manual / self_service)
--                  → permite enrutar el tap a la pantalla correcta.
--   - table_id, table_code, zone_id
--                  → para deep-link `/sales/table/:tableId?code=...&zone=...`
--                    cuando origin = dine_in.
--   - items_count  → total de items no-void en la orden. Si > 2 el resumen
--                    muestra "Item1 x2, Item2 x1 + 3 más".
--
-- Compatible: las nuevas columnas se AGREGAN al final del RETURNS TABLE,
-- el caller existente sigue funcionando si solo lee los campos viejos
-- (Postgrest mapea por nombre). El modelo Dart se extiende en este mismo
-- PR.
--
-- IMPORTANT: cambiar la firma de un RETURNS TABLE requiere DROP FUNCTION
-- antes del CREATE — Postgres no permite alterar columnas devueltas con
-- CREATE OR REPLACE solo. El DROP es seguro porque el caller no falla:
-- el provider Riverpod reintentará en el próximo refresh.
-- =============================================================================

DROP FUNCTION IF EXISTS public.fn_dashboard_recent_orders(uuid, integer);

CREATE FUNCTION public.fn_dashboard_recent_orders(
  _business_id uuid,
  _limit       integer DEFAULT 10
) RETURNS TABLE (
  id              uuid,
  order_number    text,
  customer_name   text,
  total           numeric,
  status          text,
  created_at      timestamptz,
  items_summary   text,
  origin          text,
  table_id        uuid,
  table_code      text,
  zone_id         uuid,
  items_count     integer
)
LANGUAGE sql STABLE SECURITY DEFINER SET search_path TO public AS $$
  WITH scoped_orders AS (
    SELECT
      o.id,
      LEFT(o.id::text, 8)                      AS order_number,
      COALESCE(ts.customer_name, c.name)       AS customer_name,
      o.total                                  AS total,
      o.status_ext::text                       AS status,
      o.created_at,
      ts.origin::text                          AS origin,
      ts.table_id                              AS table_id,
      dt.code                                  AS table_code,
      dt.zone_id                               AS zone_id
    FROM public.orders o
    JOIN public.table_sessions ts ON ts.id = o.session_id
    LEFT JOIN public.dining_tables dt ON dt.id = ts.table_id
    LEFT JOIN public.zones z          ON z.id = dt.zone_id
    LEFT JOIN public.customers c      ON c.id = ts.customer_id
    WHERE COALESCE(z.business_id, ts.business_id) = _business_id
    ORDER BY o.created_at DESC
    LIMIT GREATEST(_limit, 1)
  ),
  -- Pre-calculamos el resumen de items por orden: los primeros 2 items
  -- distintos ordenados por created_at, con cantidad formateada
  -- (entero sin ".0", fracción sin trailing zeros) y prefijo "x".
  -- `items_count` (total) sirve para mostrar "+N más" cuando excede los
  -- 2 que cabe mostrar inline.
  item_lines AS (
    SELECT
      oi.order_id,
      oi.product_name || ' x' || (
        CASE
          WHEN COALESCE(oi.quantity, oi.qty::numeric, 1)
             = trunc(COALESCE(oi.quantity, oi.qty::numeric, 1))
          THEN trunc(COALESCE(oi.quantity, oi.qty::numeric, 1))::bigint::text
          ELSE rtrim(rtrim(
            COALESCE(oi.quantity, oi.qty::numeric, 1)::text, '0'
          ), '.')
        END
      )       AS line,
      oi.rn
    FROM (
      SELECT
        oi2.order_id,
        oi2.product_name,
        oi2.quantity,
        oi2.qty,
        ROW_NUMBER() OVER (
          PARTITION BY oi2.order_id ORDER BY oi2.created_at
        ) AS rn
      FROM public.order_items oi2
      JOIN scoped_orders so ON so.id = oi2.order_id
      WHERE oi2.status::text <> 'voided'
    ) oi
  ),
  item_aggs AS (
    SELECT
      order_id,
      COUNT(*)::int AS total_items,
      string_agg(line, ', ' ORDER BY rn) FILTER (WHERE rn <= 2) AS head_lines
    FROM item_lines
    GROUP BY order_id
  )
  SELECT
    s.id,
    s.order_number,
    s.customer_name,
    s.total,
    s.status,
    s.created_at,
    -- "Burger x2, Pizza x1 + 3 más" cuando hay 5 items;
    -- "Burger x2, Pizza x1"        cuando hay 2 o menos.
    CASE
      WHEN COALESCE(ia.total_items, 0) > 2
        THEN ia.head_lines || ' + ' || (ia.total_items - 2)::text || ' más'
      ELSE ia.head_lines
    END                              AS items_summary,
    s.origin,
    s.table_id,
    s.table_code,
    s.zone_id,
    COALESCE(ia.total_items, 0)::int AS items_count
  FROM scoped_orders s
  LEFT JOIN item_aggs ia ON ia.order_id = s.id;
$$;

REVOKE ALL ON FUNCTION public.fn_dashboard_recent_orders(uuid, integer) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.fn_dashboard_recent_orders(uuid, integer) TO authenticated;

COMMENT ON FUNCTION public.fn_dashboard_recent_orders IS
  'Dashboard widget: últimas N órdenes enriquecidas con origin/table/zone para deep-link y items_count para sufijo "+N más". Cantidad formateada como "x{n}" sin trailing zeros. NO incluye payments — para reportes profundos usar get_sales_summary_v2.';
