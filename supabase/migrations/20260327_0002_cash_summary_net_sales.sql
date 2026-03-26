begin;

create or replace function public.fn_get_cash_session_summary(
  p_session_id uuid
) returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_start_amount numeric := 0;
  v_opened_at timestamptz;
  v_cash_sales_net numeric := 0;
  v_total_deposits numeric := 0;
  v_total_withdrawals numeric := 0;
  v_total_expenses numeric := 0;
  v_expected_cash numeric := 0;
  v_paid_cash numeric := 0;
  v_expected_card numeric := 0;
  v_expected_transfer numeric := 0;
  v_total_sales_all_methods numeric := 0;
  v_transaction_count integer := 0;
  v_result jsonb;
begin
  select coalesce(s.start_amount, 0), s.opened_at
    into v_start_amount, v_opened_at
  from public.cash_register_sessions s
  where s.id = p_session_id;

  if not found then
    raise exception 'SESSION_NOT_FOUND';
  end if;

  select coalesce(sum(amount), 0)
    into v_cash_sales_net
  from public.cash_transactions
  where session_id = p_session_id
    and type = 'sale';

  select coalesce(sum(amount), 0)
    into v_total_deposits
  from public.cash_transactions
  where session_id = p_session_id
    and type = 'deposit';

  select coalesce(sum(amount), 0)
    into v_total_withdrawals
  from public.cash_transactions
  where session_id = p_session_id
    and type = 'withdrawal';

  select coalesce(sum(amount), 0)
    into v_total_expenses
  from public.cash_transactions
  where session_id = p_session_id
    and type = 'expense';

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
    into v_paid_cash, v_expected_card, v_expected_transfer, v_total_sales_all_methods, v_transaction_count
  from public.payments p
  join public.payment_methods pm on pm.id = p.payment_method_id
  where p.session_id = p_session_id
    and p.status = 'completed';

  v_expected_cash :=
    v_start_amount +
    v_cash_sales_net +
    v_total_deposits -
    v_total_withdrawals -
    v_total_expenses;

  v_result := jsonb_build_object(
    'start_amount', v_start_amount,
    'opened_at', v_opened_at,
    'total_sales', v_cash_sales_net,
    'cash_sales_net', v_cash_sales_net,
    'total_sales_all_methods', v_total_sales_all_methods,
    'total_deposits', v_total_deposits,
    'total_withdrawals', v_total_withdrawals,
    'total_expenses', v_total_expenses,
    'total_income', (v_cash_sales_net + v_total_deposits),
    'total_outflows', (v_total_withdrawals + v_total_expenses),
    'expected_amount', v_expected_cash,
    'expected_cash', v_expected_cash,
    'expected_card', v_expected_card,
    'expected_transfer', v_expected_transfer,
    'expected_total', (v_expected_cash + v_expected_card + v_expected_transfer),
    'paid_cash', v_paid_cash,
    'transaction_count', v_transaction_count
  );

  return v_result;
end;
$$;

commit;
