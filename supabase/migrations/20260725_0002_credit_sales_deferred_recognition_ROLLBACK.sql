-- =============================================================================
-- ROLLBACK de 20260725_0002 — restaura las versiones previas:
--   - fn_get_cash_session_summary → versión 20260514_0002 (crédito incluido
--     en total_sales_all_methods, sin credit_sales).
--   - fn_dashboard_kpis → versión 20260616_0005 (income = todos los payments
--     completed, sin abonos).
-- =============================================================================

begin;

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
  v_expected_cash       numeric := 0;
  v_expected_total      numeric := 0;
begin
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

  select coalesce(sum(amount), 0) into v_total_deposits
  from public.cash_transactions
  where session_id = p_session_id and type = 'deposit';

  select coalesce(sum(amount), 0) into v_total_withdrawals
  from public.cash_transactions
  where session_id = p_session_id and type = 'withdrawal';

  select coalesce(sum(amount), 0) into v_total_expenses
  from public.cash_transactions
  where session_id = p_session_id and type = 'expense';

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
    coalesce(sum(greatest(p.amount - coalesce(p.change_amount, 0), 0)), 0),
    coalesce(count(*), 0)::int
    into
      v_paid_cash,
      v_expected_card,
      v_expected_transfer,
      v_total_sales_all,
      v_transaction_count
  from public.payments p
  join public.payment_methods pm on pm.id = p.payment_method_id
  where p.session_id = p_session_id
    and p.status = 'completed';

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
    'cash_sales_net', v_cash_sales_net,
    'total_sales', v_cash_sales_net,
    'voided_sales_total', v_voided_sales,
    'total_deposits', v_total_deposits,
    'total_withdrawals', v_total_withdrawals,
    'total_expenses', v_total_expenses,
    'total_income', v_cash_sales_net + v_total_deposits,
    'total_outflows', v_total_withdrawals + v_total_expenses,
    'expected_cash', v_expected_cash,
    'expected_card', v_expected_card,
    'expected_transfer', v_expected_transfer,
    'expected_total', v_expected_total,
    'expected_amount', v_expected_cash,
    'paid_cash', v_paid_cash,
    'total_sales_all_methods', v_total_sales_all,
    'transaction_count', v_transaction_count
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

commit;
