-- =============================================================================
-- 20260616_0005 — Dashboard KPIs: Ingresos desde PAYMENTS (no orders.total)
-- =============================================================================
--
-- Bug: el card "Ingresos" mostraba RD$0.00 aunque hubiera órdenes completadas.
-- Causa: `fn_dashboard_kpis` calculaba income = SUM(orders.total) de órdenes
-- 'paid', pero `orders.total` queda en 0 en negocios con cuenta dividida (el
-- trigger de recálculo de totales por ítems, 20260530_0007). Por eso se veían
-- 8 completadas / 69 items pero RD$0.00.
--
-- Fix: derivar el ingreso del dinero REALMENTE cobrado — la tabla `payments`
-- (amount - change_amount) de pagos 'completed' — exactamente la misma fuente
-- que `get_sales_summary_v2` y el cierre de caja. Así los números cuadran entre
-- pantallas y dejan de depender de `orders.total`.
--
-- El resto de KPIs (orders_total, in_progress, completed, items_sold) NO cambia:
-- siguen derivándose de las órdenes/ítems del período como antes.
--
-- Solo lectura, aditiva (CREATE OR REPLACE de la misma firma). No toca pagos,
-- NCF, caja ni datos.
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
  ),
  -- Ingreso = dinero efectivamente cobrado (payments), NO orders.total.
  -- Misma fórmula que get_sales_summary_v2: SUM(amount - change_amount) de
  -- pagos 'completed' (o sin status), scopeados por payments.business_id y
  -- fecha del pago. Robusto frente a orders.total = 0.
  income_by_period AS (
    SELECT
      CASE
        WHEN p.created_at >= _today_from
         AND p.created_at <  _today_to     THEN 'today'
        ELSE 'yesterday'
      END AS period,
      COALESCE(SUM(p.amount - COALESCE(p.change_amount, 0)), 0) AS income
    FROM public.payments p
    WHERE p.business_id = _business_id
      AND (p.status = 'completed' OR p.status IS NULL)
      AND (
        (p.created_at >= _today_from     AND p.created_at <  _today_to)
        OR (p.created_at >= _yesterday_from AND p.created_at <  _yesterday_to)
      )
    GROUP BY 1
  ),
  order_stats AS (
    SELECT
      s.period,
      COUNT(*) FILTER (WHERE s.status <> 'canceled')::int                AS orders_total,
      COUNT(*) FILTER (WHERE s.status IN ('open','sent','served'))::int  AS orders_in_progress,
      COUNT(*) FILTER (WHERE s.status = 'paid')::int                     AS orders_completed,
      COALESCE(MAX(i.qty_sum), 0)                                        AS items_sold
    FROM scoped s
    LEFT JOIN items_by_period i ON i.period = s.period
    GROUP BY s.period
  )
  -- FULL OUTER JOIN: un período puede tener pagos pero ninguna orden creada en
  -- esa ventana (ej. pago hoy de una orden de ayer) y viceversa.
  SELECT
    COALESCE(os.period, ip.period)              AS period,
    COALESCE(ip.income, 0)::numeric             AS income,
    COALESCE(os.orders_total, 0)                AS orders_total,
    COALESCE(os.orders_in_progress, 0)          AS orders_in_progress,
    COALESCE(os.orders_completed, 0)            AS orders_completed,
    COALESCE(os.items_sold, 0)::numeric         AS items_sold
  FROM order_stats os
  FULL OUTER JOIN income_by_period ip ON ip.period = os.period
  WHERE COALESCE(os.period, ip.period) IS NOT NULL;
$$;

REVOKE ALL ON FUNCTION public.fn_dashboard_kpis(uuid, timestamptz, timestamptz, timestamptz, timestamptz) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.fn_dashboard_kpis(uuid, timestamptz, timestamptz, timestamptz, timestamptz) TO authenticated;

COMMENT ON FUNCTION public.fn_dashboard_kpis IS
  'Dashboard "Order Summary": 5 KPIs (income, orders_total, in_progress, completed, items_sold) para HOY vs AYER (mismo tramo del día). income deriva de payments (dinero cobrado), no de orders.total. Devuelve hasta 2 filas (period=today|yesterday).';
