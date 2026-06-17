-- =============================================================================
-- ROLLBACK 20260616_0005 — vuelve fn_dashboard_kpis a income desde orders.total
-- =============================================================================
-- Restaura la definición previa (20260527_0006), donde income = SUM(orders.total)
-- de órdenes 'paid'. OJO: con esto vuelve el bug de RD$0.00 en negocios con
-- cuenta dividida.
-- =============================================================================

CREATE OR REPLACE FUNCTION public.fn_dashboard_kpis(
  _business_id    uuid,
  _today_from     timestamptz,
  _today_to       timestamptz,
  _yesterday_from timestamptz,
  _yesterday_to   timestamptz
) RETURNS TABLE (
  period             text,
  income             numeric,
  orders_total       integer,
  orders_in_progress integer,
  orders_completed   integer,
  items_sold         numeric
)
LANGUAGE sql STABLE SECURITY DEFINER SET search_path TO public AS $$
  WITH scoped AS (
    SELECT
      o.id,
      o.status_ext::text AS status,
      o.total,
      CASE
        WHEN o.created_at >= _today_from
         AND o.created_at <  _today_to       THEN 'today'
        WHEN o.created_at >= _yesterday_from
         AND o.created_at <  _yesterday_to   THEN 'yesterday'
      END AS period
    FROM public.orders o
    JOIN public.table_sessions ts ON ts.id = o.session_id
    LEFT JOIN public.dining_tables dt ON dt.id = ts.table_id
    LEFT JOIN public.zones z          ON z.id = dt.zone_id
    WHERE COALESCE(z.business_id, ts.business_id) = _business_id
      AND (
        (o.created_at >= _today_from     AND o.created_at <  _today_to)
        OR (o.created_at >= _yesterday_from AND o.created_at <  _yesterday_to)
      )
  ),
  items_by_period AS (
    SELECT
      s.period,
      SUM(COALESCE(oi.quantity::numeric, oi.qty, 1)) AS qty_sum
    FROM scoped s
    JOIN public.order_items oi
      ON oi.order_id = s.id
     AND oi.status::text <> 'voided'
    GROUP BY s.period
  )
  SELECT
    s.period,
    COALESCE(SUM(s.total) FILTER (WHERE s.status = 'paid'), 0)        AS income,
    COUNT(*) FILTER (WHERE s.status <> 'canceled')::int                AS orders_total,
    COUNT(*) FILTER (WHERE s.status IN ('open','sent','served'))::int  AS orders_in_progress,
    COUNT(*) FILTER (WHERE s.status = 'paid')::int                     AS orders_completed,
    COALESCE(MAX(i.qty_sum), 0)                                        AS items_sold
  FROM scoped s
  LEFT JOIN items_by_period i ON i.period = s.period
  GROUP BY s.period;
$$;

REVOKE ALL ON FUNCTION public.fn_dashboard_kpis(uuid, timestamptz, timestamptz, timestamptz, timestamptz) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.fn_dashboard_kpis(uuid, timestamptz, timestamptz, timestamptz, timestamptz) TO authenticated;
