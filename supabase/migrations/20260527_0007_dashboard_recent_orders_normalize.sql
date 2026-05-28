-- =============================================================================
-- Fix de cosmética para `fn_dashboard_recent_orders` (Fase A del dashboard).
--
-- Bugs corregidos:
--
--   1. Cantidad cruda. El items_summary salía como "Coca Cola 1.00000"
--      porque `oi.quantity::text` imprime el numeric con su escala
--      completa. Lo formateamos a entero cuando no tiene decimales y
--      sin trailing zeros cuando sí los tiene. Además usamos prefijo
--      "x" estilo POS ("Coca Cola x2") en vez de "Coca Cola 2".
--
-- La firma de la función NO cambia — solo el contenido del campo
-- `items_summary`. El caller Flutter no necesita ajustes.
--
-- Status badges (sent_to_kitchen, partially_paid, void) se normalizan
-- en el lado Flutter — el RPC sigue devolviendo el enum crudo.
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
    -- Resumen corto: "Coca Cola x2, Pizza x1" (primeros 2 items distintos).
    -- Cantidad formateada: si es entera → "2"; si tiene decimales →
    -- "2.5" (trailing zeros y . removidos).
    (
      SELECT string_agg(line, ', ' ORDER BY line)
      FROM (
        SELECT
          oi.product_name || ' x' || (
            CASE
              WHEN COALESCE(oi.quantity, oi.qty::numeric, 1)
                 = trunc(COALESCE(oi.quantity, oi.qty::numeric, 1))
              THEN trunc(COALESCE(oi.quantity, oi.qty::numeric, 1))::bigint::text
              ELSE rtrim(rtrim(
                COALESCE(oi.quantity, oi.qty::numeric, 1)::text, '0'
              ), '.')
            END
          ) AS line
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
      ) sub
    ) AS items_summary
  FROM scoped_orders s;
$$;

COMMENT ON FUNCTION public.fn_dashboard_recent_orders IS
  'Dashboard widget: últimas N órdenes con resumen ligero de items, customer y total. Cantidad formateada como "x{n}" sin trailing zeros. NO incluye payments — para reportes profundos usar get_sales_summary_v2.';
