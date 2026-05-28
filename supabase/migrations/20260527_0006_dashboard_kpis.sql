-- =============================================================================
-- RPC para el "Order Summary" del dashboard: 5 KPIs comparando HOY vs AYER.
--
--   income             — total facturado en órdenes 'paid' del periodo
--   orders_total       — # de órdenes creadas en el periodo (excluye canceladas)
--   orders_in_progress — # de órdenes en estados activos ('open','sent','served')
--   orders_completed   — # de órdenes 'paid' del periodo
--   items_sold         — SUM de qty de order_items (excluye 'voided')
--
-- El caller (Flutter) calcula los timestamps:
--   _today_from     = hoy 00:00 AST
--   _today_to       = ahora
--   _yesterday_from = ayer 00:00 AST
--   _yesterday_to   = ayer 00:00 + (ahora - hoy 00:00)   -- mismo elapsed
--
-- De esa forma la comparación "vs ayer" es contra el mismo "tramo del día"
-- (no contra el día entero), que es la métrica que importa para el delta
-- mostrado en la KPI strip.
--
-- Scope por business_id vía join orders → table_sessions → zones (mismo
-- patrón que fn_dashboard_top_selling_products / fn_dashboard_recent_orders).
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

COMMENT ON FUNCTION public.fn_dashboard_kpis IS
  'Dashboard "Order Summary": 5 KPIs (income, orders_total, in_progress, completed, items_sold) para HOY vs AYER (mismo tramo del día). Devuelve hasta 2 filas (period=today|yesterday). Si un periodo no tuvo órdenes, esa fila simplemente no aparece — el caller debe asumir 0.';
