-- Rollback de 20260527_0008_dashboard_recent_orders_enriched.sql
-- Restaura la firma previa (la de 20260527_0007: 7 columnas, sin
-- origin/table/zone/items_count).

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

REVOKE ALL ON FUNCTION public.fn_dashboard_recent_orders(uuid, integer) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.fn_dashboard_recent_orders(uuid, integer) TO authenticated;
