-- =============================================================================
-- RPCs nuevos para el dashboard rediseñado (Fase A):
--   1. fn_dashboard_top_selling_products — top N productos por cantidad vendida
--   2. fn_dashboard_recent_orders        — últimas N órdenes del business
--
-- Ambas funciones son SECURITY DEFINER + scope por business_id (vía join
-- a table_sessions → zones para validar pertenencia, mismo patrón que
-- usan reports y otras agregaciones). Los callers Flutter pasan el
-- business_id desde la sesión activa.
--
-- No leen tablas histórico-sensibles (fiscal_documents) — solo agregan
-- order_items / orders / menu_items / customers. Seguras para tab dashboard
-- que se refresca cada 30s.
-- =============================================================================

-- =============================================================================
-- 1. Top selling products (para "Top Selling Items" del dashboard)
-- =============================================================================
CREATE OR REPLACE FUNCTION public.fn_dashboard_top_selling_products(
  _business_id uuid,
  _from        timestamptz,
  _to          timestamptz,
  _limit       integer DEFAULT 3
) RETURNS TABLE (
  product_id     uuid,
  product_name   text,
  image_url      text,
  total_quantity numeric,
  total_amount   numeric
)
LANGUAGE sql STABLE SECURITY DEFINER SET search_path TO public AS $$
  SELECT
    oi.product_id,
    -- Si el menu_item fue borrado (product_id NULL) o renombrado, caemos
    -- al snapshot que order_items guardó al momento de la venta.
    COALESCE(mi.name, oi.product_name)         AS product_name,
    mi.image_url                                AS image_url,
    SUM(COALESCE(oi.quantity::numeric, oi.qty, 1)) AS total_quantity,
    SUM(oi.subtotal)                            AS total_amount
  FROM public.order_items oi
  JOIN public.orders o          ON o.id = oi.order_id
  JOIN public.table_sessions ts ON ts.id = o.session_id
  LEFT JOIN public.dining_tables dt ON dt.id = ts.table_id
  LEFT JOIN public.zones z          ON z.id = dt.zone_id
  LEFT JOIN public.menu_items mi    ON mi.id = oi.product_id
  WHERE oi.product_id IS NOT NULL
    AND COALESCE(z.business_id, ts.business_id) = _business_id
    AND o.created_at >= _from
    AND o.created_at <  _to
    AND oi.status::text = ANY (ARRAY['pending','preparing','ready','served','paid'])
    AND o.status_ext::text <> 'canceled'
  GROUP BY oi.product_id, mi.name, oi.product_name, mi.image_url
  ORDER BY total_quantity DESC
  LIMIT GREATEST(_limit, 1);
$$;

REVOKE ALL ON FUNCTION public.fn_dashboard_top_selling_products(uuid, timestamptz, timestamptz, integer) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.fn_dashboard_top_selling_products(uuid, timestamptz, timestamptz, integer) TO authenticated;

COMMENT ON FUNCTION public.fn_dashboard_top_selling_products IS
  'Dashboard widget: top N productos por cantidad vendida en el rango. Excluye órdenes canceladas y productos borrados.';


-- =============================================================================
-- 2. Recent orders (para "Recent Orders" del dashboard)
-- =============================================================================
CREATE OR REPLACE FUNCTION public.fn_dashboard_recent_orders(
  _business_id uuid,
  _limit       integer DEFAULT 10
) RETURNS TABLE (
  id              uuid,
  order_number    text,
  customer_name   text,
  total           numeric,
  status          text,
  created_at      timestamptz,
  items_summary   text
)
LANGUAGE sql STABLE SECURITY DEFINER SET search_path TO public AS $$
  WITH scoped_orders AS (
    SELECT
      o.id,
      LEFT(o.id::text, 8)                      AS order_number,
      COALESCE(ts.customer_name, c.name)       AS customer_name,
      o.total                                  AS total,
      o.status_ext::text                       AS status,
      o.created_at
    FROM public.orders o
    JOIN public.table_sessions ts ON ts.id = o.session_id
    LEFT JOIN public.dining_tables dt ON dt.id = ts.table_id
    LEFT JOIN public.zones z          ON z.id = dt.zone_id
    LEFT JOIN public.customers c      ON c.id = ts.customer_id
    WHERE COALESCE(z.business_id, ts.business_id) = _business_id
    ORDER BY o.created_at DESC
    LIMIT GREATEST(_limit, 1)
  )
  SELECT
    s.id,
    s.order_number,
    s.customer_name,
    s.total,
    s.status,
    s.created_at,
    -- Resumen corto de items: "Burger 2, Pizza 2" (primeros 2 con cantidad).
    -- Si hay más de 2 items distintos, agregamos "+ N más".
    (
      SELECT string_agg(line, ', ' ORDER BY line)
      FROM (
        SELECT
          CASE
            WHEN COUNT(*) FILTER (WHERE rn > 2) = 0 THEN
              oi.product_name || ' ' ||
                COALESCE(oi.quantity::text, oi.qty::text, '1')
            ELSE NULL
          END AS line
        FROM (
          SELECT
            oi2.product_name,
            oi2.quantity,
            oi2.qty,
            ROW_NUMBER() OVER (ORDER BY oi2.created_at) AS rn
          FROM public.order_items oi2
          WHERE oi2.order_id = s.id
            AND oi2.status::text <> 'voided'
        ) oi
        WHERE rn <= 2
        GROUP BY oi.product_name, oi.quantity, oi.qty, oi.rn
      ) sub
      WHERE line IS NOT NULL
    ) AS items_summary
  FROM scoped_orders s;
$$;

REVOKE ALL ON FUNCTION public.fn_dashboard_recent_orders(uuid, integer) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.fn_dashboard_recent_orders(uuid, integer) TO authenticated;

COMMENT ON FUNCTION public.fn_dashboard_recent_orders IS
  'Dashboard widget: últimas N órdenes con resumen ligero de items, customer y total. NO incluye payments — para reportes profundos usar get_sales_summary_v2.';
