-- 20260227_0002_cash_closure_consistency.sql
-- Scope:
-- 1) Include expense transactions in cash-close expected amount.
-- 2) Expose a complete session summary payload for cashier UI/reports.

begin;

create or replace function public.fn_close_cash_session(
  p_session_id uuid,
  p_end_amount numeric,
  p_notes text
) returns jsonb
language plpgsql
security definer
as $$
declare
  v_start_amount numeric := 0;
  v_total_sales numeric := 0;
  v_total_deposits numeric := 0;
  v_total_withdrawals numeric := 0;
  v_total_expenses numeric := 0;
  v_expected_amount numeric := 0;
  v_difference numeric := 0;
begin
  select start_amount
    into v_start_amount
  from public.cash_register_sessions
  where id = p_session_id;

  if v_start_amount is null then
    raise exception 'SESSION_NOT_FOUND';
  end if;

  select coalesce(sum(amount), 0)
    into v_total_sales
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

  v_expected_amount :=
    (v_total_deposits + v_total_sales) -
    (v_total_withdrawals + v_total_expenses);

  v_difference := p_end_amount - v_expected_amount;

  update public.cash_register_sessions
  set closed_at = now(),
      end_amount = p_end_amount,
      difference = v_difference,
      status = 'closed',
      notes = p_notes
  where id = p_session_id;

  return jsonb_build_object(
    'success', true,
    'difference', v_difference,
    'expected', v_expected_amount,
    'expected_amount', v_expected_amount,
    'start_amount', v_start_amount,
    'total_sales', v_total_sales,
    'total_deposits', v_total_deposits,
    'total_withdrawals', v_total_withdrawals,
    'total_expenses', v_total_expenses
  );
end;
$$;

create or replace function public.fn_get_cash_session_summary(
  p_session_id uuid
) returns jsonb
language plpgsql
security definer
as $$
declare
  v_result jsonb;
begin
  select jsonb_build_object(
    'start_amount', s.start_amount,
    'opened_at', s.opened_at,
    'total_sales', (
      select coalesce(sum(amount), 0)
      from public.cash_transactions
      where session_id = s.id and type = 'sale'
    ),
    'total_deposits', (
      select coalesce(sum(amount), 0)
      from public.cash_transactions
      where session_id = s.id and type = 'deposit'
    ),
    'total_withdrawals', (
      select coalesce(sum(amount), 0)
      from public.cash_transactions
      where session_id = s.id and type = 'withdrawal'
    ),
    'total_expenses', (
      select coalesce(sum(amount), 0)
      from public.cash_transactions
      where session_id = s.id and type = 'expense'
    ),
    'total_income', (
      select coalesce(sum(amount), 0)
      from public.cash_transactions
      where session_id = s.id and type in ('sale', 'deposit')
    ),
    'total_outflows', (
      select coalesce(sum(amount), 0)
      from public.cash_transactions
      where session_id = s.id and type in ('withdrawal', 'expense')
    ),
    'expected_amount',
      (
        select coalesce(sum(amount), 0)
        from public.cash_transactions
        where session_id = s.id and type in ('sale', 'deposit')
      )
      -
      (
        select coalesce(sum(amount), 0)
        from public.cash_transactions
        where session_id = s.id and type in ('withdrawal', 'expense')
      )
  )
    into v_result
  from public.cash_register_sessions s
  where s.id = p_session_id;

  return v_result;
end;
$$;

commit;
