-- =============================================================================
-- 20260725_0002 — Venta a crédito: el dinero "sale" cuando SE COBRA, no
-- cuando se fía.
--
-- PROBLEMA:
--   1. `fn_get_cash_session_summary` sumaba TODOS los payments completed de
--      la sesión en `total_sales_all_methods`/`transaction_count` — una venta
--      a crédito (método code='credit') inflaba el "Total ventas" del cierre
--      aunque no entró dinero (y el desglose Efectivo/Tarjeta/Transferencia
--      no cuadraba contra ese total).
--   2. `fn_dashboard_kpis` sumaba el crédito como ingreso del día en que se
--      fió, y el abono (cuando el cliente paga de verdad) no contaba nunca.
--
-- FIX (reconocimiento diferido):
--   1. Cierre de caja: el crédito queda FUERA de total_sales_all_methods y
--      transaction_count. Se expone aparte como `credit_sales` +
--      `credit_sales_count` (informativos, para que el cierre pueda mostrar
--      "Ventas a crédito del turno" sin mezclarlas con lo cobrado). El
--      efectivo esperado NO cambia (el crédito nunca generó cash_transactions).
--      El abono en efectivo ya entra como 'deposit' a la caja abierta
--      (fn_register_credit_abono) — eso no se toca.
--   2. Dashboard: income = payments completed EXCLUYENDO método credit,
--      MÁS los abonos de crédito (credit_payments) recibidos en la ventana.
--      Así el ingreso aparece el día que se cobra, sin duplicarse.
--
-- BASE: recrea `fn_get_cash_session_summary` desde 20260514_0002 y
-- `fn_dashboard_kpis` desde 20260616_0005 (últimas versiones del repo).
-- OJO BD-diverge: antes de aplicar, verificar que la función viva coincide
-- con esas versiones (pg_get_functiondef) — ver query en el PR/nota.
--
-- Solo lectura (ambas funciones son de consulta). Firmas intactas.
-- =============================================================================

begin;

-- ---------------------------------------------------------------------------
-- 1. fn_get_cash_session_summary — crédito fuera del total, expuesto aparte.
-- ---------------------------------------------------------------------------

drop function if exists public.fn_get_cash_session_summary(uuid);

create function public.fn_get_cash_session_summary(
  p_session_id uuid
) returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_start_amount        numeric := 0;
  v_opened_at           timestamptz;
  v_cash_sales_net      numeric := 0;
  v_voided_sales        numeric := 0;
  v_total_deposits      numeric := 0;
  v_total_withdrawals   numeric := 0;
  v_total_expenses      numeric := 0;
  v_paid_cash           numeric := 0;
  v_expected_card       numeric := 0;
  v_expected_transfer   numeric := 0;
  v_total_sales_all     numeric := 0;
  v_transaction_count   int := 0;
  v_credit_sales        numeric := 0;
  v_credit_sales_count  int := 0;
  v_expected_cash       numeric := 0;
  v_expected_total      numeric := 0;
begin
  -- Lookup base de la sesión.
  select coalesce(s.start_amount, 0), s.opened_at
    into v_start_amount, v_opened_at
  from public.cash_register_sessions s
  where s.id = p_session_id;

  if not found then
    return jsonb_build_object(
      'success', false,
      'error', 'SESSION_NOT_FOUND'
    );
  end if;

  -- Ventas en efectivo (excluye anuladas).
  select coalesce(sum(amount), 0)
    into v_cash_sales_net
  from public.cash_transactions ct
  where ct.session_id = p_session_id
    and ct.type = 'sale'
    and not exists (
      select 1 from public.payments p
      where p.order_id = ct.related_order_id
        and p.status in ('cancelled', 'void')
    );

  -- Ventas anuladas (informativo).
  select coalesce(sum(amount), 0)
    into v_voided_sales
  from public.cash_transactions ct
  where ct.session_id = p_session_id
    and ct.type = 'sale'
    and exists (
      select 1 from public.payments p
      where p.order_id = ct.related_order_id
        and p.status in ('cancelled', 'void')
    );

  -- Depósitos, retiros, gastos.
  select coalesce(sum(amount), 0) into v_total_deposits
  from public.cash_transactions
  where session_id = p_session_id and type = 'deposit';

  select coalesce(sum(amount), 0) into v_total_withdrawals
  from public.cash_transactions
  where session_id = p_session_id and type = 'withdrawal';

  select coalesce(sum(amount), 0) into v_total_expenses
  from public.cash_transactions
  where session_id = p_session_id and type = 'expense';

  -- Breakdown de payments por método (excluye cancelled/void).
  -- Crédito (fiao) NO es dinero cobrado: va aparte en credit_sales y queda
  -- FUERA de total_sales_all_methods/transaction_count. El dinero del
  -- crédito entra al cuadre el día del abono (como 'deposit' en caja).
  select
    coalesce(sum(
      case
        when pm.code = 'cash' or lower(coalesce(pm.name, '')) like '%efectivo%'
          then greatest(p.amount - coalesce(p.change_amount, 0), 0)
        else 0
      end
    ), 0),
    coalesce(sum(
      case
        when pm.code = 'card' or lower(coalesce(pm.name, '')) like '%tarjet%'
          then greatest(p.amount - coalesce(p.change_amount, 0), 0)
        else 0
      end
    ), 0),
    coalesce(sum(
      case
        when pm.code = 'transfer' or lower(coalesce(pm.name, '')) like '%transfer%'
          then greatest(p.amount - coalesce(p.change_amount, 0), 0)
        else 0
      end
    ), 0),
    coalesce(sum(
      case
        when pm.code = 'credit' or lower(coalesce(pm.name, '')) in ('crédito', 'credito')
          then 0
        else greatest(p.amount - coalesce(p.change_amount, 0), 0)
      end
    ), 0),
    coalesce(count(*) filter (
      where not (pm.code = 'credit'
        or lower(coalesce(pm.name, '')) in ('crédito', 'credito'))
    ), 0)::int,
    coalesce(sum(
      case
        when pm.code = 'credit' or lower(coalesce(pm.name, '')) in ('crédito', 'credito')
          then greatest(p.amount - coalesce(p.change_amount, 0), 0)
        else 0
      end
    ), 0),
    coalesce(count(*) filter (
      where pm.code = 'credit'
        or lower(coalesce(pm.name, '')) in ('crédito', 'credito')
    ), 0)::int
    into
      v_paid_cash,
      v_expected_card,
      v_expected_transfer,
      v_total_sales_all,
      v_transaction_count,
      v_credit_sales,
      v_credit_sales_count
  from public.payments p
  join public.payment_methods pm on pm.id = p.payment_method_id
  where p.session_id = p_session_id
    and p.status = 'completed';

  -- Fórmula canónica del efectivo esperado en caja:
  -- = monto de apertura
  --   + ventas en efectivo (no anuladas)
  --   + depósitos manuales (incluye abonos de crédito en efectivo)
  --   - retiros
  --   - gastos
  v_expected_cash := v_start_amount
                   + v_cash_sales_net
                   + v_total_deposits
                   - v_total_withdrawals
                   - v_total_expenses;

  v_expected_total := v_expected_cash + v_expected_card + v_expected_transfer;

  return jsonb_build_object(
    'success', true,
    'start_amount', v_start_amount,
    'opened_at', v_opened_at,

    -- Ventas efectivo (informativos individuales)
    'cash_sales_net', v_cash_sales_net,
    'total_sales', v_cash_sales_net,           -- alias legacy
    'voided_sales_total', v_voided_sales,

    -- Movimientos manuales
    'total_deposits', v_total_deposits,
    'total_withdrawals', v_total_withdrawals,
    'total_expenses', v_total_expenses,
    'total_income', v_cash_sales_net + v_total_deposits,
    'total_outflows', v_total_withdrawals + v_total_expenses,

    -- Esperados por método (FUENTE ÚNICA DE VERDAD)
    'expected_cash', v_expected_cash,
    'expected_card', v_expected_card,
    'expected_transfer', v_expected_transfer,
    'expected_total', v_expected_total,
    -- Alias legacy: expected_amount == expected_cash (lo que cuadra contra
    -- el efectivo contado al cerrar).
    'expected_amount', v_expected_cash,

    -- Totales por método informativos (SIN crédito: solo dinero cobrado)
    'paid_cash', v_paid_cash,
    'total_sales_all_methods', v_total_sales_all,
    'transaction_count', v_transaction_count,

    -- Ventas a crédito del turno (informativo, NO es dinero cobrado)
    'credit_sales', v_credit_sales,
    'credit_sales_count', v_credit_sales_count
  );
exception when others then
  return jsonb_build_object(
    'success', false,
    'error', sqlerrm,
    'error_code', sqlstate
  );
end;
$$;

alter function public.fn_get_cash_session_summary(uuid) owner to postgres;

grant execute on function public.fn_get_cash_session_summary(uuid)
  to anon, authenticated, service_role;

comment on function public.fn_get_cash_session_summary(uuid) is
  'Resumen jsonb completo de una sesión de caja. Fuente única de verdad '
  'para el cierre. 2026-07-25: las ventas a crédito (método credit) quedan '
  'FUERA de total_sales_all_methods/transaction_count y se exponen aparte '
  'como credit_sales/credit_sales_count — el dinero del crédito entra al '
  'cuadre el día del abono (deposit en caja), no el día que se fía.';

-- ---------------------------------------------------------------------------
-- 2. fn_dashboard_kpis — ingreso sin crédito fiado + abonos cuando se cobran.
-- ---------------------------------------------------------------------------

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
  -- Ingreso = dinero efectivamente COBRADO en la ventana:
  --   a) payments completed EXCLUYENDO método credit (el fiao no es ingreso
  --      el día que se fía), MÁS
  --   b) abonos de crédito (credit_payments) recibidos en la ventana — el
  --      ingreso del fiao aparece el día que el cliente paga.
  -- Sin duplicar: (a) excluye el fiado y (b) solo suma lo abonado.
  income_by_period AS (
    SELECT t.period, COALESCE(SUM(t.amount), 0) AS income
    FROM (
      SELECT
        CASE
          WHEN p.created_at >= _today_from
           AND p.created_at <  _today_to     THEN 'today'
          ELSE 'yesterday'
        END AS period,
        (p.amount - COALESCE(p.change_amount, 0)) AS amount
      FROM public.payments p
      LEFT JOIN public.payment_methods pm ON pm.id = p.payment_method_id
      WHERE p.business_id = _business_id
        AND (p.status = 'completed' OR p.status IS NULL)
        AND (
          (p.created_at >= _today_from     AND p.created_at <  _today_to)
          OR (p.created_at >= _yesterday_from AND p.created_at <  _yesterday_to)
        )
        AND COALESCE(pm.code, '') <> 'credit'
      UNION ALL
      SELECT
        CASE
          WHEN cp.created_at >= _today_from
           AND cp.created_at <  _today_to    THEN 'today'
          ELSE 'yesterday'
        END AS period,
        cp.amount
      FROM public.credit_payments cp
      JOIN public.customer_credits cc ON cc.id = cp.credit_id
      WHERE cc.business_id = _business_id
        AND (
          (cp.created_at >= _today_from     AND cp.created_at <  _today_to)
          OR (cp.created_at >= _yesterday_from AND cp.created_at <  _yesterday_to)
        )
    ) t
    GROUP BY t.period
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
  'Dashboard "Order Summary": 5 KPIs para HOY vs AYER. income = payments '
  'completed SIN método credit + abonos de crédito (credit_payments) de la '
  'ventana: el fiao cuenta como ingreso el día que se cobra, no el que se fía.';

commit;
