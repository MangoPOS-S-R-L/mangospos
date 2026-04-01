-- =============================================================================
-- Migration: Ownership hardening for fn_close_cash_session
-- =============================================================================
-- BEFORE: Any authenticated user who knows a session_id can close any session.
-- AFTER:  Only the session owner (user_id = auth.uid()) can close it,
--         UNLESS the caller holds 'owner' or 'admin' role in the same business.
--         Fail-closed: if neither condition is met, the function raises an error.
--
-- Impact:
--   - fn_close_cash_session: adds ownership + role guard before any mutation
--   - No schema changes; reads existing memberships.role for admin/owner check
--   - Flutter client: no changes needed (auth.uid() is implicit via Supabase JWT)
-- =============================================================================

begin;

-- Drop the old 4-arg signature so we can recreate cleanly
drop function if exists public.fn_close_cash_session(uuid, numeric, text, boolean);

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
  v_caller_id uuid := auth.uid();
  v_session_user_id uuid;
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
  v_caller_role public.member_role;
begin
  -- ---------------------------------------------------------------
  -- 1. Fetch session + lock row
  -- ---------------------------------------------------------------
  select
    s.user_id,
    coalesce(s.start_amount, 0),
    cr.business_id
    into v_session_user_id, v_start_amount, v_business_id
  from public.cash_register_sessions s
  join public.cash_registers cr on cr.id = s.cash_register_id
  where s.id = p_session_id
  for update;

  if not found then
    raise exception 'SESSION_NOT_FOUND';
  end if;

  -- ---------------------------------------------------------------
  -- 2. Ownership check (fail-closed)
  -- ---------------------------------------------------------------
  if v_caller_id is null then
    raise exception 'AUTH_REQUIRED';
  end if;

  if v_session_user_id <> v_caller_id then
    -- Caller is not the session owner — check for admin/owner role
    select m.role into v_caller_role
    from public.memberships m
    where m.user_id = v_caller_id
      and m.business_id = v_business_id
      and m.status = 'active'
    limit 1;

    if v_caller_role is null or v_caller_role not in ('owner', 'admin') then
      raise exception 'CLOSE_DENIED: only the session owner or a business admin/owner can close this session';
    end if;
  end if;

  -- ---------------------------------------------------------------
  -- 3. Open tables guard (unchanged logic)
  -- ---------------------------------------------------------------
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

  -- ---------------------------------------------------------------
  -- 4. Compute totals (unchanged)
  -- ---------------------------------------------------------------
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
    end,
    case
      when v_session_user_id <> v_caller_id
        then format('Cerrado por %s (rol: %s)', v_caller_id, v_caller_role)
      else null
    end
  );

  -- ---------------------------------------------------------------
  -- 5. Close the session (unchanged)
  -- ---------------------------------------------------------------
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

commit;
