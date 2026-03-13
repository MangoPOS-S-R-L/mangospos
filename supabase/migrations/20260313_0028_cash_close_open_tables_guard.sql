-- 20260313_0028_cash_close_open_tables_guard.sql
-- Scope:
-- 1) Allow cash session close with explicit backend flag when there are open tables.
-- 2) Keep table sessions open while there are non-final orders in the session.

begin;

-- Replace the old 3-arg signature with a 4th optional flag.
drop function if exists public.fn_close_cash_session(uuid, numeric, text);

create or replace function public.fn_close_cash_session(
  p_session_id uuid,
  p_end_amount numeric,
  p_notes text,
  p_force_with_open_tables boolean default false
) returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_start_amount numeric := 0;
  v_total_sales numeric := 0;
  v_total_deposits numeric := 0;
  v_total_withdrawals numeric := 0;
  v_total_expenses numeric := 0;
  v_expected_cash numeric := 0;
  v_difference numeric := 0;
  v_business_id uuid;
  v_open_tables_count integer := 0;
  v_notes text;
begin
  select
    coalesce(s.start_amount, 0),
    cr.business_id
    into v_start_amount, v_business_id
  from public.cash_register_sessions s
  join public.cash_registers cr on cr.id = s.cash_register_id
  where s.id = p_session_id
  for update;

  if not found then
    raise exception 'SESSION_NOT_FOUND';
  end if;

  select count(distinct ts.id)
    into v_open_tables_count
  from public.table_sessions ts
  join public.orders o on o.session_id = ts.id
  where ts.business_id = v_business_id
    and ts.closed_at is null
    and o.closed_at is null
    and o.status_ext not in ('paid', 'void');

  if v_open_tables_count > 0 and not coalesce(p_force_with_open_tables, false) then
    raise exception 'OPEN_TABLES_EXIST';
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

  v_expected_cash :=
    v_start_amount +
    v_total_sales +
    v_total_deposits -
    v_total_withdrawals -
    v_total_expenses;

  v_difference := p_end_amount - v_expected_cash;

  v_notes := concat_ws(
    ' | ',
    nullif(trim(coalesce(p_notes, '')), ''),
    case
      when coalesce(p_force_with_open_tables, false)
        then format('Cierre forzado con %s mesa(s) abierta(s)', v_open_tables_count)
      else null
    end
  );

  update public.cash_register_sessions
  set closed_at = now(),
      end_amount = p_end_amount,
      difference = v_difference,
      status = 'closed',
      notes = v_notes
  where id = p_session_id;

  return jsonb_build_object(
    'success', true,
    'difference', v_difference,
    'expected', v_expected_cash,
    'expected_amount', v_expected_cash,
    'expected_cash', v_expected_cash,
    'start_amount', v_start_amount,
    'total_sales', v_total_sales,
    'total_deposits', v_total_deposits,
    'total_withdrawals', v_total_withdrawals,
    'total_expenses', v_total_expenses,
    'open_tables_count', v_open_tables_count,
    'forced_with_open_tables', coalesce(p_force_with_open_tables, false)
  );
end;
$$;

grant execute on function public.fn_close_cash_session(uuid, numeric, text, boolean)
  to authenticated;

create or replace function public.fn_close_order_and_table(
  p_order_id uuid,
  p_status public.order_status
) returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_session uuid;
  v_open_count int;
  v_table_id uuid;
begin
  update public.orders
  set status_ext = p_status,
      closed_at = now()
  where id = p_order_id;

  select session_id into v_session
  from public.orders
  where id = p_order_id;

  select table_id into v_table_id
  from public.table_sessions
  where id = v_session;

  select count(*) into v_open_count
  from public.orders
  where session_id = v_session
    and closed_at is null
    and status_ext not in ('paid', 'void');

  if coalesce(v_open_count, 0) = 0 then
    update public.table_sessions
    set closed_at = now()
    where id = v_session
      and closed_at is null;

    if v_table_id is not null then
      update public.dining_tables
      set state = 'available'
      where id = v_table_id;
    end if;
  end if;
end;
$$;

commit;
