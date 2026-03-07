-- Consolidated Supabase migrations
-- Generated: 2026-03-07 01:11:56 UTC
-- Source dir: supabase/migrations
-- Execution: run this file top-to-bottom in Supabase SQL Editor

-- ===================================================================
-- BEGIN MIGRATION: 20260225_0001_sprint1_p0_fiscal_roles.sql
-- ===================================================================
-- 20260225_0001_sprint1_p0_fiscal_roles.sql
-- Scope: Sprint 1 P0 blockers (fiscal + role constraint)
-- Status: Draft for approval

begin;

-- =====================================================
-- A) Fiscal: reemplazar create_fiscal_document mock
-- =====================================================
create or replace function public.create_fiscal_document(
  p_order_id uuid,
  p_payment_id uuid,
  p_customer_id uuid,
  p_customer_rnc text
)
returns public.fiscal_documents
language plpgsql
security definer
set search_path = public
as $$
declare
  v_doc public.fiscal_documents;
  v_doc_id uuid;
begin
  -- Idempotencia: si ya existe documento para el pago/orden, retornarlo.
  select *
    into v_doc
  from public.fiscal_documents fd
  where (p_payment_id is not null and fd.payment_id = p_payment_id)
     or (fd.order_id = p_order_id and fd.status = 'active')
  order by fd.created_at desc
  limit 1;

  if found then
    return v_doc;
  end if;

  -- Emisión real usando secuencia NCF.
  v_doc_id := public.issue_fiscal_document(p_order_id, p_payment_id);

  select * into v_doc
  from public.fiscal_documents
  where id = v_doc_id;

  -- Completar datos de cliente si fueron provistos.
  if p_customer_id is not null or p_customer_rnc is not null then
    update public.fiscal_documents
       set customer_id = coalesce(customer_id, p_customer_id),
           customer_rnc = coalesce(customer_rnc, p_customer_rnc)
     where id = v_doc_id
     returning * into v_doc;
  end if;

  return v_doc;
end;
$$;

comment on function public.create_fiscal_document(uuid, uuid, uuid, text)
  is 'Sprint1 P0: emision fiscal real e idempotente, sin NCF hardcodeado.';

-- =====================================================
-- B) Roles: alinear constraint de user_businesses.role
-- =====================================================
alter table public.user_businesses
  drop constraint if exists user_businesses_role_check;

alter table public.user_businesses
  add constraint user_businesses_role_check
  check (
    role = any (
      array[
        'owner'::text,
        'admin'::text,
        'manager'::text,
        'cashier'::text,
        'waiter'::text,
        'cook'::text,
        'chef'::text,
        'delivery'::text
      ]
    )
  );

commit;

-- Rollback guide (manual):
-- 1) Restaurar create_fiscal_document previo desde snapshot/tag.
-- 2) Restaurar constraint anterior user_businesses_role_check.

-- END MIGRATION: 20260225_0001_sprint1_p0_fiscal_roles.sql

-- ===================================================================
-- BEGIN MIGRATION: 20260227_0002_cash_closure_consistency.sql
-- ===================================================================
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

-- END MIGRATION: 20260227_0002_cash_closure_consistency.sql

-- ===================================================================
-- BEGIN MIGRATION: 20260227_0003_process_payment_v3.sql
-- ===================================================================
-- 20260227_0003_process_payment_v3.sql
-- Scope:
-- 1) Process payment with explicit cashier session.
-- 2) Persist real change_amount.
-- 3) Register cash movement net of change (cash in drawer).
-- 4) Respect split-check payments without prematurely closing full order.

begin;

create or replace function public.fn_process_payment_v3(
  p_order_id uuid,
  p_check_id uuid,
  p_payment_method_id text,
  p_amount numeric,
  p_reference text,
  p_customer_id uuid default null,
  p_customer_rnc text default null,
  p_cashier_session_id uuid default null,
  p_change_amount numeric default 0
) returns public.payments
language plpgsql
security definer
set search_path = public
as $$
declare
  v_payment public.payments;
  v_business_id uuid;
  v_table_session_id uuid;
  v_payment_method_id uuid;
  v_payment_method_code text;
  v_open_items_count bigint := 0;
  v_cash_in_drawer numeric := 0;
begin
  select o.session_id
    into v_table_session_id
  from public.orders o
  where o.id = p_order_id;

  if v_table_session_id is null then
    raise exception 'ORDER_NOT_FOUND';
  end if;

  select ts.business_id
    into v_business_id
  from public.table_sessions ts
  where ts.id = v_table_session_id;

  if v_business_id is null then
    select bid
      into v_business_id
    from public.current_user_business_ids() as bid
    limit 1;
  end if;

  if v_business_id is null then
    raise exception 'BUSINESS_NOT_FOUND';
  end if;

  if p_cashier_session_id is null then
    raise exception 'CASH_SESSION_REQUIRED';
  end if;

  perform 1
  from public.cash_register_sessions s
  where s.id = p_cashier_session_id
    and s.status = 'open'
    and s.closed_at is null;

  if not found then
    raise exception 'CASH_SESSION_NOT_OPEN';
  end if;

  if p_payment_method_id ~* '^[0-9a-f-]{36}$' then
    select pm.id, pm.code
      into v_payment_method_id, v_payment_method_code
    from public.payment_methods pm
    where pm.id = p_payment_method_id::uuid
      and pm.is_active = true
    limit 1;
  else
    select pm.id, pm.code
      into v_payment_method_id, v_payment_method_code
    from public.payment_methods pm
    where pm.business_id = v_business_id
      and pm.code = p_payment_method_id
      and pm.is_active = true
    limit 1;
  end if;

  if v_payment_method_id is null then
    raise exception 'INVALID_PAYMENT_METHOD';
  end if;

  insert into public.payments(
    business_id,
    order_id,
    check_id,
    payment_method_id,
    amount,
    reference,
    change_amount,
    status,
    processed_by,
    session_id,
    customer_id,
    customer_rnc,
    created_at
  )
  values (
    v_business_id,
    p_order_id,
    p_check_id,
    v_payment_method_id,
    p_amount,
    p_reference,
    coalesce(p_change_amount, 0),
    'completed',
    auth.uid(),
    p_cashier_session_id,
    p_customer_id,
    p_customer_rnc,
    now()
  )
  returning * into v_payment;

  if p_check_id is not null then
    update public.order_items
    set status = 'paid'
    where order_id = p_order_id
      and check_id = p_check_id
      and status <> 'void';

    update public.order_checks
    set is_closed = true,
        closed_at = now()
    where id = p_check_id;

    select count(*)
      into v_open_items_count
    from public.order_items
    where order_id = p_order_id
      and status not in ('paid', 'void');

    if v_open_items_count = 0 then
      perform public.fn_close_order_and_table(p_order_id, 'paid');
    end if;
  else
    update public.order_items
    set status = 'paid'
    where order_id = p_order_id
      and status <> 'void';

    perform public.fn_close_order_and_table(p_order_id, 'paid');
  end if;

  if v_payment_method_code = 'cash' then
    v_cash_in_drawer := greatest(
      coalesce(p_amount, 0) - coalesce(p_change_amount, 0),
      0
    );

    if v_cash_in_drawer > 0 then
      insert into public.cash_transactions(
        session_id,
        amount,
        type,
        description,
        related_order_id
      )
      values (
        p_cashier_session_id,
        v_cash_in_drawer,
        'sale',
        'Venta ' || left(p_order_id::text, 8),
        p_order_id
      );
    end if;
  end if;

  return v_payment;
end;
$$;

grant all on function public.fn_process_payment_v3(
  uuid,
  uuid,
  text,
  numeric,
  text,
  uuid,
  text,
  uuid,
  numeric
) to anon;
grant all on function public.fn_process_payment_v3(
  uuid,
  uuid,
  text,
  numeric,
  text,
  uuid,
  text,
  uuid,
  numeric
) to authenticated;
grant all on function public.fn_process_payment_v3(
  uuid,
  uuid,
  text,
  numeric,
  text,
  uuid,
  text,
  uuid,
  numeric
) to service_role;

commit;

-- END MIGRATION: 20260227_0003_process_payment_v3.sql

-- ===================================================================
-- BEGIN MIGRATION: 20260227_0004_blind_close_summary_breakdown.sql
-- ===================================================================
-- 20260227_0004_blind_close_summary_breakdown.sql
-- Scope:
-- 1) Fix close-session expected cash to include opening amount.
-- 2) Expose blind-close expected breakdown (cash/card/transfer/total).

begin;

create or replace function public.fn_close_cash_session(
  p_session_id uuid,
  p_end_amount numeric,
  p_notes text
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
begin
  select coalesce(start_amount, 0)
    into v_start_amount
  from public.cash_register_sessions
  where id = p_session_id;

  if not found then
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

  v_expected_cash :=
    v_start_amount +
    v_total_sales +
    v_total_deposits -
    v_total_withdrawals -
    v_total_expenses;

  v_difference := p_end_amount - v_expected_cash;

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
    'expected', v_expected_cash,
    'expected_amount', v_expected_cash,
    'expected_cash', v_expected_cash,
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
          then p.amount
        else 0
      end
    ), 0),
    coalesce(sum(
      case
        when pm.code = 'card' or lower(coalesce(pm.name, '')) like '%tarjet%'
          then p.amount
        else 0
      end
    ), 0),
    coalesce(sum(
      case
        when pm.code = 'transfer' or lower(coalesce(pm.name, '')) like '%transfer%'
          then p.amount
        else 0
      end
    ), 0),
    coalesce(sum(p.amount), 0),
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

-- END MIGRATION: 20260227_0004_blind_close_summary_breakdown.sql

-- ===================================================================
-- BEGIN MIGRATION: 20260227_0005_sales_cash_products_hardening.sql
-- ===================================================================
-- NOTE: migration file is empty, skipped intentionally.

-- END MIGRATION: 20260227_0005_sales_cash_products_hardening.sql

-- ===================================================================
-- BEGIN MIGRATION: 20260227_0006_kds_timeout_fix.sql
-- ===================================================================
-- 2026-02-27: KDS timeout hardening
-- Objetivo:
-- 1) Acelerar consulta de items activos de cocina (pending/preparing/ready).
-- 2) Corregir business_id en la vista para que incluya sesiones sin mesa (manual/rapida).

create index if not exists idx_order_items_kds_active_status_created
  on public.order_items (status, created_at desc)
  where status in ('pending'::public.item_status, 'preparing'::public.item_status, 'ready'::public.item_status);

create index if not exists idx_table_sessions_business_id
  on public.table_sessions (business_id);

create or replace view public.kds_active_items
with (security_invoker = on) as
select
  oi.id,
  oi.order_id,
  left(oi.order_id::text, 8) as order_number,
  oi.product_name,
  coalesce(oi.quantity, oi.qty, 1) as quantity,
  oi.notes,
  oi.status,
  oi.created_at,
  oi.started_at,
  oi.ready_at,
  case
    when dt.id is not null then coalesce(dt.label, dt.code, 'Mesa')
    when ts.origin = 'manual'::public.order_origin then 'Venta manual'
    when ts.origin = 'quick'::public.order_origin then 'Venta rapida'
    else 'Venta'
  end as table_name,
  p.full_name as waiter_name,
  coalesce(z.business_id, ts.business_id) as business_id,
  null::text as area_code,
  coalesce(mods.modifiers, '[]'::json) as modifiers
from public.order_items oi
join public.orders o on o.id = oi.order_id
join public.table_sessions ts on ts.id = o.session_id
left join public.dining_tables dt on dt.id = ts.table_id
left join public.zones z on z.id = dt.zone_id
left join public.profiles p on p.id = ts.waiter_user_id
left join lateral (
  select json_agg(
    json_build_object(
      'id', m.id,
      'name', m.name,
      'quantity', m.qty
    )
  ) as modifiers
  from public.order_item_modifiers m
  where m.item_id = oi.id
) mods on true
where oi.status in (
  'pending'::public.item_status,
  'preparing'::public.item_status,
  'ready'::public.item_status
);

-- END MIGRATION: 20260227_0006_kds_timeout_fix.sql

-- ===================================================================
-- BEGIN MIGRATION: 20260227_0007_sales_open_table_split_perf.sql
-- ===================================================================
-- 2026-02-27
-- Performance hardening: open table + split bill
-- Targets:
-- 1) fn_open_table
-- 2) fn_create_split_bill
-- 3) fn_move_item_to_check (used heavily during split)

-- Fast lookup for active order by session.
create index if not exists idx_orders_session_active_created
  on public.orders (session_id, created_at desc)
  where closed_at is null
    and status_ext in (
      'open'::public.order_status,
      'sent_to_kitchen'::public.order_status,
      'partially_paid'::public.order_status
    );

-- Open table: make it idempotent and safer under concurrency.
create or replace function public.fn_open_table(
  p_table_id uuid,
  p_user_id uuid,
  p_people_count int default 1
)
returns jsonb
language plpgsql
security definer
set search_path=public
as $$
declare
  v_session_id uuid;
  v_order_id uuid;
begin
  if p_table_id is null then
    raise exception 'TABLE_ID_REQUIRED';
  end if;

  if p_user_id is null then
    raise exception 'USER_ID_REQUIRED';
  end if;

  -- Serialize by table to avoid races (double open under fast-clicks / multiple clients).
  perform pg_advisory_xact_lock(hashtextextended(p_table_id::text, 0));

  -- Reuse existing open session if present.
  select ts.id
    into v_session_id
  from public.table_sessions ts
  where ts.table_id = p_table_id
    and ts.closed_at is null
  limit 1;

  if v_session_id is null then
    insert into public.table_sessions(table_id, opened_by, origin, waiter_user_id, people_count)
    values (p_table_id, p_user_id, 'dine_in', p_user_id, greatest(1, coalesce(p_people_count, 1)))
    returning id into v_session_id;
  end if;

  -- Avoid unnecessary write churn.
  update public.dining_tables
  set state = 'occupied'
  where id = p_table_id
    and state is distinct from 'occupied';

  -- Reuse active order if present.
  select o.id
    into v_order_id
  from public.orders o
  where o.session_id = v_session_id
    and o.closed_at is null
    and o.status_ext in ('open', 'sent_to_kitchen', 'partially_paid')
  order by o.created_at desc
  limit 1;

  if v_order_id is null then
    insert into public.orders(session_id, status_ext, subtotal, discounts, tax, total, total_amount)
    values (v_session_id, 'open', 0, 0, 0, 0, 0)
    returning id into v_order_id;

    -- Ensure C1 exists without raising in race scenarios.
    insert into public.order_checks(order_id, label, position)
    values (v_order_id, 'C1', 1)
    on conflict (order_id, position) do nothing;
  end if;

  return jsonb_build_object('session_id', v_session_id, 'order_id', v_order_id);
end;
$$;

grant execute on function public.fn_open_table(uuid, uuid, int) to authenticated;

-- Split bill: set-based insert, lock by order, idempotent growth up to max 5.
create or replace function public.fn_create_split_bill(
  p_order_id uuid,
  p_number_of_checks int
)
returns setof public.order_checks
language plpgsql
security definer
set search_path=public
as $$
declare
  v_target int;
  v_existing int;
begin
  if p_order_id is null then
    raise exception 'ORDER_ID_REQUIRED';
  end if;

  v_target := greatest(1, least(coalesce(p_number_of_checks, 1), 5));

  -- Serialize split operations per order.
  perform pg_advisory_xact_lock(hashtextextended(p_order_id::text, 1));

  -- Ensure order exists and lock it.
  perform 1
  from public.orders
  where id = p_order_id
  for update;

  if not found then
    raise exception 'ORDER_NOT_FOUND';
  end if;

  select count(*)::int
    into v_existing
  from public.order_checks
  where order_id = p_order_id;

  if v_existing < v_target then
    insert into public.order_checks(order_id, label, position, is_closed)
    select
      p_order_id,
      case when gs = 1 then 'C1' else 'Cuenta ' || gs::text end,
      gs,
      false
    from generate_series(v_existing + 1, v_target) as gs
    on conflict (order_id, position) do nothing;
  end if;

  return query
  select *
  from public.order_checks
  where order_id = p_order_id
  order by position;
end;
$$;

grant execute on function public.fn_create_split_bill(uuid, int) to authenticated;

-- Move item to check: avoid duplicate update and remove redundant recalc.
-- Order/check totals are already maintained by trigger_update_order_totals.
create or replace function public.fn_move_item_to_check(
  p_item_id uuid,
  p_check_position int
)
returns void
language plpgsql
security definer
set search_path=public
as $$
declare
  v_order uuid;
  v_check uuid;
  v_current_check uuid;
begin
  select oi.order_id, oi.check_id
    into v_order, v_current_check
  from public.order_items oi
  where oi.id = p_item_id;

  if v_order is null then
    raise exception 'ITEM_NOT_FOUND';
  end if;

  v_check := public.fn_get_or_create_check(v_order, p_check_position);

  if v_current_check is distinct from v_check then
    update public.order_items
    set check_id = v_check
    where id = p_item_id;
  end if;
end;
$$;

grant execute on function public.fn_move_item_to_check(uuid, int) to authenticated;

-- Batch move for split operations (reduces N RPC calls to a handful).
create or replace function public.fn_move_items_to_check_batch(
  p_item_ids uuid[],
  p_check_position int
)
returns int
language plpgsql
security definer
set search_path=public
as $$
declare
  v_order uuid;
  v_check uuid;
  v_moved int := 0;
begin
  if p_item_ids is null or array_length(p_item_ids, 1) is null then
    return 0;
  end if;

  select oi.order_id
    into v_order
  from public.order_items oi
  where oi.id = p_item_ids[1];

  if v_order is null then
    raise exception 'ITEM_NOT_FOUND';
  end if;

  if exists (
    select 1
    from public.order_items oi
    where oi.id = any(p_item_ids)
      and oi.order_id is distinct from v_order
  ) then
    raise exception 'ITEMS_MUST_BELONG_TO_SAME_ORDER';
  end if;

  v_check := public.fn_get_or_create_check(v_order, p_check_position);

  update public.order_items oi
  set check_id = v_check
  where oi.id = any(p_item_ids)
    and oi.check_id is distinct from v_check;

  get diagnostics v_moved = row_count;
  return v_moved;
end;
$$;

grant execute on function public.fn_move_items_to_check_batch(uuid[], int) to authenticated;

-- Trigger helper: avoid full COUNT(*) scan on every inserted check.
create or replace function public.fn_check_max_checks()
returns trigger
language plpgsql
as $$
begin
  -- Fast fail for impossible positions.
  if coalesce(new.position, 1) > 5 then
    raise exception 'Max 5 checks per order';
  end if;

  -- Stop as soon as a 5th row exists.
  if exists (
    select 1
    from public.order_checks
    where order_id = new.order_id
    order by position
    offset 4
    limit 1
  ) then
    raise exception 'Max 5 checks per order';
  end if;

  return new;
end;
$$;

-- END MIGRATION: 20260227_0007_sales_open_table_split_perf.sql

-- ===================================================================
-- BEGIN MIGRATION: 20260303_0008_sales_split_open_table_full_fix.sql
-- ===================================================================
-- 2026-03-03
-- Sales performance + consistency hardening
-- Scope:
-- 1) Open table latency
-- 2) Split-bill latency
-- 3) Remove duplicate order_items recalculation triggers
-- 4) Faster zone/table status view used by "Por Zona"

-- ------------------------------------------------------------
-- Indexes for hot paths
-- ------------------------------------------------------------
create index if not exists idx_orders_session_active_created
  on public.orders (session_id, created_at desc)
  where closed_at is null
    and status_ext not in ('paid'::public.order_status, 'void'::public.order_status);

create index if not exists idx_table_sessions_open_lookup
  on public.table_sessions (table_id, opened_at desc)
  where closed_at is null;

create index if not exists idx_orders_active_by_session
  on public.orders (session_id)
  where closed_at is null
    and status_ext not in ('paid'::public.order_status, 'void'::public.order_status);

create index if not exists idx_order_items_active_by_order
  on public.order_items (order_id)
  where status not in ('paid'::public.item_status, 'void'::public.item_status);

-- ------------------------------------------------------------
-- fn_get_or_create_check: race-safe
-- ------------------------------------------------------------
create or replace function public.fn_get_or_create_check(
  p_order_id uuid,
  p_position integer default 1
)
returns uuid
language plpgsql
security definer
set search_path=public
as $$
declare
  v_check_id uuid;
  v_position integer := greatest(1, coalesce(p_position, 1));
begin
  if p_order_id is null then
    raise exception 'ORDER_ID_REQUIRED';
  end if;

  select oc.id
    into v_check_id
  from public.order_checks oc
  where oc.order_id = p_order_id
    and oc.position = v_position
  limit 1;

  if v_check_id is null then
    insert into public.order_checks (order_id, label, position)
    values (
      p_order_id,
      case when v_position = 1 then 'C1' else 'C' || v_position::text end,
      v_position
    )
    on conflict (order_id, position) do nothing
    returning id into v_check_id;

    if v_check_id is null then
      select oc.id
        into v_check_id
      from public.order_checks oc
      where oc.order_id = p_order_id
        and oc.position = v_position
      limit 1;
    end if;
  end if;

  return v_check_id;
end;
$$;

grant execute on function public.fn_get_or_create_check(uuid, integer) to authenticated;

-- ------------------------------------------------------------
-- fn_open_table: idempotent + concurrency-safe
-- ------------------------------------------------------------
create or replace function public.fn_open_table(
  p_table_id uuid,
  p_user_id uuid,
  p_people_count integer default 1
)
returns jsonb
language plpgsql
security definer
set search_path=public
as $$
declare
  v_session_id uuid;
  v_order_id uuid;
  v_user_id uuid;
begin
  if p_table_id is null then
    raise exception 'TABLE_ID_REQUIRED';
  end if;

  if auth.uid() is not null and p_user_id is not null and p_user_id <> auth.uid() then
    raise exception 'INVALID_USER_CONTEXT';
  end if;

  v_user_id := coalesce(auth.uid(), p_user_id);

  if v_user_id is null then
    raise exception 'USER_REQUIRED';
  end if;

  perform public.fn_require_open_cash_session(v_user_id);

  -- Serialize by table to avoid double-open races.
  perform pg_advisory_xact_lock(hashtextextended(p_table_id::text, 0));

  select ts.id
    into v_session_id
  from public.table_sessions ts
  where ts.table_id = p_table_id
    and ts.closed_at is null
  order by ts.opened_at desc
  limit 1;

  if v_session_id is null then
    insert into public.table_sessions (table_id, opened_by, origin, waiter_user_id, people_count)
    values (p_table_id, v_user_id, 'dine_in', v_user_id, greatest(1, coalesce(p_people_count, 1)))
    returning id into v_session_id;
  end if;

  update public.dining_tables
     set state = 'occupied'
   where id = p_table_id
     and state is distinct from 'occupied';

  select o.id
    into v_order_id
  from public.orders o
  where o.session_id = v_session_id
    and o.closed_at is null
    and o.status_ext not in ('paid', 'void')
  order by o.created_at desc
  limit 1;

  if v_order_id is null then
    insert into public.orders (session_id, status_ext, subtotal, discounts, tax, total, total_amount)
    values (v_session_id, 'open', 0, 0, 0, 0, 0)
    returning id into v_order_id;

    insert into public.order_checks (order_id, label, position)
    values (v_order_id, 'C1', 1)
    on conflict (order_id, position) do nothing;
  end if;

  return jsonb_build_object('session_id', v_session_id, 'order_id', v_order_id);
end;
$$;

grant execute on function public.fn_open_table(uuid, uuid, integer) to authenticated;

-- ------------------------------------------------------------
-- fn_create_split_bill: set-based, capped, concurrency-safe
-- ------------------------------------------------------------
create or replace function public.fn_create_split_bill(
  p_order_id uuid,
  p_number_of_checks integer
)
returns setof public.order_checks
language plpgsql
security definer
set search_path=public
as $$
declare
  v_target integer;
  v_existing integer;
begin
  if p_order_id is null then
    raise exception 'ORDER_ID_REQUIRED';
  end if;

  v_target := greatest(1, least(coalesce(p_number_of_checks, 1), 5));

  -- Serialize split operations per order.
  perform pg_advisory_xact_lock(hashtextextended(p_order_id::text, 1));

  perform 1
  from public.orders
  where id = p_order_id
  for update;

  if not found then
    raise exception 'ORDER_NOT_FOUND';
  end if;

  select count(*)::integer
    into v_existing
  from public.order_checks
  where order_id = p_order_id;

  if v_existing < v_target then
    insert into public.order_checks (order_id, label, position, is_closed)
    select
      p_order_id,
      case when gs = 1 then 'C1' else 'Cuenta ' || gs::text end,
      gs,
      false
    from generate_series(v_existing + 1, v_target) as gs
    on conflict (order_id, position) do nothing;
  end if;

  return query
  select *
  from public.order_checks
  where order_id = p_order_id
  order by position;
end;
$$;

grant execute on function public.fn_create_split_bill(uuid, integer) to authenticated;

-- ------------------------------------------------------------
-- Max checks trigger helper: avoid full count(*) on every insert
-- ------------------------------------------------------------
create or replace function public.fn_check_max_checks()
returns trigger
language plpgsql
as $$
begin
  if coalesce(new.position, 1) > 5 then
    raise exception 'Max 5 checks per order';
  end if;

  if exists (
    select 1
    from public.order_checks oc
    where oc.order_id = new.order_id
    order by oc.position
    offset 4
    limit 1
  ) then
    raise exception 'Max 5 checks per order';
  end if;

  return new;
end;
$$;

-- ------------------------------------------------------------
-- Move item to check: avoid redundant full order recalc
-- ------------------------------------------------------------
create or replace function public.fn_move_item_to_check(
  p_item_id uuid,
  p_check_position integer
)
returns void
language plpgsql
security definer
set search_path=public
as $$
declare
  v_order uuid;
  v_check uuid;
  v_current_check uuid;
begin
  select oi.order_id, oi.check_id
    into v_order, v_current_check
  from public.order_items oi
  where oi.id = p_item_id;

  if v_order is null then
    raise exception 'ITEM_NOT_FOUND';
  end if;

  v_check := public.fn_get_or_create_check(v_order, p_check_position);

  if v_current_check is distinct from v_check then
    update public.order_items
       set check_id = v_check
     where id = p_item_id;
  end if;
end;
$$;

grant execute on function public.fn_move_item_to_check(uuid, integer) to authenticated;

-- ------------------------------------------------------------
-- Batch move to reduce N RPC calls during split operations
-- ------------------------------------------------------------
create or replace function public.fn_move_items_to_check_batch(
  p_item_ids uuid[],
  p_check_position integer
)
returns integer
language plpgsql
security definer
set search_path=public
as $$
declare
  v_order uuid;
  v_check uuid;
  v_moved integer := 0;
begin
  if p_item_ids is null or array_length(p_item_ids, 1) is null then
    return 0;
  end if;

  select oi.order_id
    into v_order
  from public.order_items oi
  where oi.id = p_item_ids[1];

  if v_order is null then
    raise exception 'ITEM_NOT_FOUND';
  end if;

  if exists (
    select 1
    from public.order_items oi
    where oi.id = any(p_item_ids)
      and oi.order_id is distinct from v_order
  ) then
    raise exception 'ITEMS_MUST_BELONG_TO_SAME_ORDER';
  end if;

  v_check := public.fn_get_or_create_check(v_order, p_check_position);

  update public.order_items oi
     set check_id = v_check
   where oi.id = any(p_item_ids)
     and oi.check_id is distinct from v_check;

  get diagnostics v_moved = row_count;
  return v_moved;
end;
$$;

grant execute on function public.fn_move_items_to_check_batch(uuid[], integer) to authenticated;

-- ------------------------------------------------------------
-- Keep only one totals trigger path for order_items
-- ------------------------------------------------------------
drop trigger if exists order_items_recalc on public.order_items;
drop trigger if exists trg_recalc_after_item_del on public.order_items;
drop trigger if exists trg_recalc_after_item_ins on public.order_items;
drop trigger if exists trg_recalc_after_item_upd on public.order_items;

create or replace function public.trigger_update_order_totals()
returns trigger
language plpgsql
as $$
begin
  if tg_op = 'DELETE' then
    perform public.calculate_order_totals(old.order_id);
    if old.check_id is not null then
      perform public.calculate_check_totals(old.check_id);
    end if;
    return old;
  end if;

  if tg_op = 'UPDATE' then
    perform public.calculate_order_totals(coalesce(new.order_id, old.order_id));

    if old.check_id is not null then
      perform public.calculate_check_totals(old.check_id);
    end if;

    if new.check_id is not null and new.check_id is distinct from old.check_id then
      perform public.calculate_check_totals(new.check_id);
    end if;

    return new;
  end if;

  perform public.calculate_order_totals(new.order_id);
  if new.check_id is not null then
    perform public.calculate_check_totals(new.check_id);
  end if;
  return new;
end;
$$;

drop trigger if exists order_items_totals_trigger on public.order_items;
create trigger order_items_totals_trigger
after insert or delete or update on public.order_items
for each row execute function public.trigger_update_order_totals();

-- ------------------------------------------------------------
-- Faster zone table status view (used by sales "Por Zona")
-- ------------------------------------------------------------
create or replace view public.v_zone_table_status as
with latest_open_session as (
  select distinct on (ts.table_id)
    ts.id as session_id,
    ts.table_id,
    ts.opened_by,
    ts.opened_at,
    ts.closed_at,
    ts.people_count
  from public.table_sessions ts
  where ts.closed_at is null
  order by ts.table_id, ts.opened_at desc
),
active_orders as (
  select o.id, o.session_id
  from public.orders o
  where o.closed_at is null
    and o.status_ext not in ('paid'::public.order_status, 'void'::public.order_status)
),
session_agg as (
  select
    ao.session_id,
    count(distinct ao.id)::bigint as orders_count,
    coalesce(sum((oi.subtotal + oi.tax) - oi.discounts), 0)::numeric as total,
    count(oi.id)::bigint as items_count
  from active_orders ao
  left join public.order_items oi
    on oi.order_id = ao.id
   and oi.status not in ('paid'::public.item_status, 'void'::public.item_status)
  group by ao.session_id
)
select
  t.id as table_id,
  z.id as zone_id,
  z.name as zone_name,
  z.business_id,
  t.code,
  t.label,
  t.shape,
  t.capacity,
  t.state,
  s.session_id,
  s.opened_by,
  s.opened_at,
  case
    when s.opened_at is not null and s.closed_at is null
      then (extract(epoch from (now() - s.opened_at))::integer / 60)
    else null::integer
  end as minutes_open,
  coalesce(sa.orders_count, 0::bigint) as orders_count,
  s.people_count,
  coalesce(sa.total, 0::numeric) as total,
  coalesce(sa.items_count, 0::bigint) as items_count
from public.dining_tables t
join public.zones z on z.id = t.zone_id
left join latest_open_session s on s.table_id = t.id
left join session_agg sa on sa.session_id = s.session_id;

grant select on public.v_zone_table_status to authenticated;


-- END MIGRATION: 20260303_0008_sales_split_open_table_full_fix.sql

-- ===================================================================
-- BEGIN MIGRATION: 20260303_0009_order_bundle_rpc.sql
-- ===================================================================
-- 2026-03-03
-- Single RPC for order detail payload (order + checks + items + customer)

create or replace function public.fn_get_order_bundle(
  p_order_id uuid
)
returns jsonb
language plpgsql
security definer
set search_path=public
as $$
declare
  v_payload jsonb;
begin
  if p_order_id is null then
    raise exception 'ORDER_ID_REQUIRED';
  end if;

  with target_order as (
    select o.*
    from public.orders o
    where o.id = p_order_id
    limit 1
  ),
  order_customer as (
    select
      ts.customer_id,
      ts.customer_name
    from target_order o
    join public.table_sessions ts on ts.id = o.session_id
  )
  select jsonb_build_object(
    'order',
      (
        select to_jsonb(o)
        from target_order o
      ),
    'checks',
      coalesce(
        (
          select jsonb_agg(to_jsonb(oc) order by oc.position)
          from public.order_checks oc
          where oc.order_id = p_order_id
        ),
        '[]'::jsonb
      ),
    'items',
      coalesce(
        (
          select jsonb_agg(to_jsonb(oi) order by oi.created_at, oi.id)
          from public.order_items oi
          where oi.order_id = p_order_id
            and oi.status not in ('paid'::public.item_status, 'void'::public.item_status)
        ),
        '[]'::jsonb
      ),
    'customer_id',
      (
        select customer_id
        from order_customer
        limit 1
      ),
    'customer_name',
      (
        select customer_name
        from order_customer
        limit 1
      )
  )
  into v_payload;

  if v_payload is null or (v_payload -> 'order') is null then
    raise exception 'ORDER_NOT_FOUND';
  end if;

  return v_payload;
end;
$$;

grant execute on function public.fn_get_order_bundle(uuid) to authenticated;


-- END MIGRATION: 20260303_0009_order_bundle_rpc.sql

-- ===================================================================
-- BEGIN MIGRATION: 20260304_0010_split_items_equally.sql
-- ===================================================================
-- 2026-03-04
-- Split all open order items into N equal sub-checks by quantity (fractional qty).

create or replace function public.fn_split_items_equally(
  p_order_id uuid,
  p_people integer
)
returns setof public.order_checks
language plpgsql
security definer
set search_path=public
as $$
declare
  v_people integer := coalesce(p_people, 0);
  v_idx integer;
  v_pos integer;
  v_item record;
  v_target_check_ids uuid[] := array[]::uuid[];
  v_item_qty numeric(10,3);
  v_item_discounts numeric(12,2);
  v_qty_base numeric(10,3);
  v_qty_share numeric(10,3);
  v_qty_accum numeric(10,3);
  v_discount_base numeric(12,2);
  v_discount_share numeric(12,2);
  v_discount_accum numeric(12,2);
  v_new_item_id uuid;
  v_modifiers jsonb;
  v_mod jsonb;
  v_mod_qty numeric(10,3);
begin
  if p_order_id is null then
    raise exception 'ORDER_ID_REQUIRED';
  end if;

  -- Max 5 checks per order in this project; C1 is principal, so subchecks max=4.
  if v_people < 2 or v_people > 4 then
    raise exception 'PEOPLE_OUT_OF_RANGE';
  end if;

  if not exists (select 1 from public.orders o where o.id = p_order_id) then
    raise exception 'ORDER_NOT_FOUND';
  end if;

  -- Ensure target checks C2..C(N+1) exist and are open.
  for v_idx in 1..v_people loop
    v_pos := v_idx + 1;
    v_target_check_ids := array_append(
      v_target_check_ids,
      public.fn_get_or_create_check(p_order_id, v_pos)
    );
  end loop;

  update public.order_checks oc
  set is_closed = false,
      closed_at = null
  where oc.id = any(v_target_check_ids);

  -- Split each open item by quantity across target checks.
  for v_item in
    select oi.*
    from public.order_items oi
    where oi.order_id = p_order_id
      and oi.status not in ('paid'::public.item_status, 'void'::public.item_status)
    order by oi.created_at, oi.id
  loop
    v_item_qty := round(greatest(coalesce(v_item.qty, v_item.quantity, 1), 0), 3);
    if v_item_qty <= 0 then
      continue;
    end if;

    v_item_discounts := coalesce(v_item.discounts, 0);
    v_qty_base := round(v_item_qty / v_people, 3);
    v_discount_base := round(v_item_discounts / v_people, 2);
    v_qty_accum := 0;
    v_discount_accum := 0;

    select coalesce(
      jsonb_agg(
        jsonb_build_object(
          'name', m.name,
          'qty', m.qty,
          'price', m.price
        )
      ),
      '[]'::jsonb
    )
    into v_modifiers
    from public.order_item_modifiers m
    where m.item_id = v_item.id;

    for v_idx in 1..v_people loop
      if v_idx < v_people then
        v_qty_share := v_qty_base;
        v_discount_share := v_discount_base;
      else
        v_qty_share := round(v_item_qty - v_qty_accum, 3);
        v_discount_share := round(v_item_discounts - v_discount_accum, 2);
      end if;

      v_qty_share := greatest(v_qty_share, 0);
      v_discount_share := greatest(v_discount_share, 0);

      if v_idx = 1 then
        update public.order_items oi
        set
          check_id = v_target_check_ids[v_idx],
          qty = v_qty_share,
          quantity = round(v_qty_share),
          discounts = v_discount_share
        where oi.id = v_item.id;

        delete from public.order_item_modifiers where item_id = v_item.id;

        for v_mod in select value from jsonb_array_elements(v_modifiers)
        loop
          v_mod_qty := round(
            coalesce((v_mod->>'qty')::numeric, 1) *
            case when v_item_qty = 0 then 0 else (v_qty_share / v_item_qty) end,
            3
          );
          if v_mod_qty > 0 then
            insert into public.order_item_modifiers(item_id, name, qty, price)
            values (
              v_item.id,
              coalesce(v_mod->>'name', ''),
              v_mod_qty,
              coalesce((v_mod->>'price')::numeric, 0)
            );
          end if;
        end loop;
      else
        insert into public.order_items (
          order_id,
          product_id,
          product_name,
          sku,
          check_id,
          quantity,
          qty,
          unit_price,
          is_takeout,
          status,
          notes,
          discounts,
          created_at
        ) values (
          v_item.order_id,
          v_item.product_id,
          v_item.product_name,
          v_item.sku,
          v_target_check_ids[v_idx],
          round(v_qty_share),
          v_qty_share,
          v_item.unit_price,
          coalesce(v_item.is_takeout, false),
          v_item.status,
          v_item.notes,
          v_discount_share,
          coalesce(v_item.created_at, now())
        )
        returning id into v_new_item_id;

        for v_mod in select value from jsonb_array_elements(v_modifiers)
        loop
          v_mod_qty := round(
            coalesce((v_mod->>'qty')::numeric, 1) *
            case when v_item_qty = 0 then 0 else (v_qty_share / v_item_qty) end,
            3
          );
          if v_mod_qty > 0 then
            insert into public.order_item_modifiers(item_id, name, qty, price)
            values (
              v_new_item_id,
              coalesce(v_mod->>'name', ''),
              v_mod_qty,
              coalesce((v_mod->>'price')::numeric, 0)
            );
          end if;
        end loop;
      end if;

      v_qty_accum := v_qty_accum + v_qty_share;
      v_discount_accum := v_discount_accum + v_discount_share;
    end loop;
  end loop;

  -- Close extra empty checks not used by this equal split to keep UI clean.
  update public.order_checks oc
  set is_closed = true,
      closed_at = now()
  where oc.order_id = p_order_id
    and oc.position > (v_people + 1)
    and oc.position > 1
    and not exists (
      select 1
      from public.order_items oi
      where oi.check_id = oc.id
        and oi.status not in ('paid'::public.item_status, 'void'::public.item_status)
    );

  return query
  select *
  from public.order_checks oc
  where oc.order_id = p_order_id
    and oc.position between 2 and (v_people + 1)
  order by oc.position;
end;
$$;

grant execute on function public.fn_split_items_equally(uuid, integer) to authenticated;

-- END MIGRATION: 20260304_0010_split_items_equally.sql

-- ===================================================================
-- BEGIN MIGRATION: 20260305_0011_item_discount_rpc.sql
-- ===================================================================
-- 2026-03-05
-- RPCs dedicated to item discount/courtesy updates

create or replace function public.fn_update_item_discount(
  p_item_id uuid,
  p_discounts numeric
)
returns void
language plpgsql
security definer
set search_path=public
as $$
declare
  v_order_id uuid;
  v_check_id uuid;
  v_discount numeric(12,2);
begin
  v_discount := round(greatest(coalesce(p_discounts, 0), 0), 2);

  update public.order_items
     set discounts = v_discount
   where id = p_item_id
   returning order_id, check_id into v_order_id, v_check_id;

  if v_order_id is null then
    raise exception 'ITEM_NOT_FOUND';
  end if;

  perform public.calculate_order_totals(v_order_id);
  if v_check_id is not null then
    perform public.calculate_check_totals(v_check_id);
  end if;
end;
$$;

grant execute on function public.fn_update_item_discount(uuid, numeric) to authenticated;

create or replace function public.fn_update_item_discount_and_notes(
  p_item_id uuid,
  p_discounts numeric,
  p_notes text
)
returns void
language plpgsql
security definer
set search_path=public
as $$
declare
  v_order_id uuid;
  v_check_id uuid;
  v_discount numeric(12,2);
begin
  v_discount := round(greatest(coalesce(p_discounts, 0), 0), 2);

  update public.order_items
     set discounts = v_discount,
         notes = nullif(trim(coalesce(p_notes, '')), '')
   where id = p_item_id
   returning order_id, check_id into v_order_id, v_check_id;

  if v_order_id is null then
    raise exception 'ITEM_NOT_FOUND';
  end if;

  perform public.calculate_order_totals(v_order_id);
  if v_check_id is not null then
    perform public.calculate_check_totals(v_check_id);
  end if;
end;
$$;

grant execute on function public.fn_update_item_discount_and_notes(uuid, numeric, text) to authenticated;

-- END MIGRATION: 20260305_0011_item_discount_rpc.sql

-- ===================================================================
-- BEGIN MIGRATION: 20260305_0012_split_items_equally_hardening.sql
-- ===================================================================
-- 2026-03-05
-- Harden equal split to ensure per-item fractional qty distribution.

create or replace function public.fn_split_items_equally(
  p_order_id uuid,
  p_people integer
)
returns setof public.order_checks
language plpgsql
security definer
set search_path=public
as $$
declare
  v_people integer := coalesce(p_people, 0);
  v_idx integer;
  v_pos integer;
  v_item record;
  v_target_check_ids uuid[] := array[]::uuid[];
  v_item_qty numeric(10,3);
  v_item_discounts numeric(12,2);
  v_qty_base numeric(10,3);
  v_qty_share numeric(10,3);
  v_qty_accum numeric(10,3);
  v_discount_base numeric(12,2);
  v_discount_share numeric(12,2);
  v_discount_accum numeric(12,2);
  v_new_item_id uuid;
  v_modifiers jsonb;
  v_mod jsonb;
  v_mod_qty numeric(10,3);
  v_check_id uuid;
begin
  if p_order_id is null then
    raise exception 'ORDER_ID_REQUIRED';
  end if;

  if v_people < 2 or v_people > 4 then
    raise exception 'PEOPLE_OUT_OF_RANGE';
  end if;

  if not exists (select 1 from public.orders o where o.id = p_order_id) then
    raise exception 'ORDER_NOT_FOUND';
  end if;

  -- Serialize split operations by order to avoid concurrent duplication.
  perform pg_advisory_xact_lock(hashtext(p_order_id::text));

  -- Ensure target checks C2..C(N+1) exist and are open.
  for v_idx in 1..v_people loop
    v_pos := v_idx + 1;
    v_target_check_ids := array_append(
      v_target_check_ids,
      public.fn_get_or_create_check(p_order_id, v_pos)
    );
  end loop;

  update public.order_checks oc
  set is_closed = false,
      closed_at = null
  where oc.id = any(v_target_check_ids);

  -- Split each open item by qty (fractional) across target checks.
  for v_item in
    select oi.*
    from public.order_items oi
    where oi.order_id = p_order_id
      and oi.status not in ('paid'::public.item_status, 'void'::public.item_status)
    order by oi.created_at, oi.id
  loop
    v_item_qty := round(greatest(coalesce(v_item.qty, v_item.quantity, 1), 0), 3);
    if v_item_qty <= 0 then
      continue;
    end if;

    v_item_discounts := coalesce(v_item.discounts, 0);
    v_qty_base := trunc(v_item_qty / v_people, 3);
    v_discount_base := round(v_item_discounts / v_people, 2);
    v_qty_accum := 0;
    v_discount_accum := 0;

    select coalesce(
      jsonb_agg(
        jsonb_build_object(
          'name', m.name,
          'qty', m.qty,
          'price', m.price
        )
      ),
      '[]'::jsonb
    )
    into v_modifiers
    from public.order_item_modifiers m
    where m.item_id = v_item.id;

    for v_idx in 1..v_people loop
      if v_idx < v_people then
        v_qty_share := v_qty_base;
        v_discount_share := v_discount_base;
      else
        v_qty_share := round(v_item_qty - v_qty_accum, 3);
        v_discount_share := round(v_item_discounts - v_discount_accum, 2);
      end if;

      v_qty_share := greatest(v_qty_share, 0);
      v_discount_share := greatest(v_discount_share, 0);

      if v_idx = 1 then
        update public.order_items oi
        set
          check_id = v_target_check_ids[v_idx],
          qty = v_qty_share,
          quantity = round(v_qty_share),
          discounts = v_discount_share
        where oi.id = v_item.id;

        delete from public.order_item_modifiers where item_id = v_item.id;

        for v_mod in select value from jsonb_array_elements(v_modifiers)
        loop
          v_mod_qty := round(
            coalesce((v_mod->>'qty')::numeric, 1) *
            case when v_item_qty = 0 then 0 else (v_qty_share / v_item_qty) end,
            3
          );
          if v_mod_qty > 0 then
            insert into public.order_item_modifiers(item_id, name, qty, price)
            values (
              v_item.id,
              coalesce(v_mod->>'name', ''),
              v_mod_qty,
              coalesce((v_mod->>'price')::numeric, 0)
            );
          end if;
        end loop;
      else
        insert into public.order_items (
          order_id,
          product_id,
          product_name,
          sku,
          check_id,
          quantity,
          qty,
          unit_price,
          is_takeout,
          status,
          notes,
          discounts,
          created_at
        ) values (
          v_item.order_id,
          v_item.product_id,
          v_item.product_name,
          v_item.sku,
          v_target_check_ids[v_idx],
          round(v_qty_share),
          v_qty_share,
          v_item.unit_price,
          coalesce(v_item.is_takeout, false),
          v_item.status,
          v_item.notes,
          v_discount_share,
          coalesce(v_item.created_at, now())
        )
        returning id into v_new_item_id;

        for v_mod in select value from jsonb_array_elements(v_modifiers)
        loop
          v_mod_qty := round(
            coalesce((v_mod->>'qty')::numeric, 1) *
            case when v_item_qty = 0 then 0 else (v_qty_share / v_item_qty) end,
            3
          );
          if v_mod_qty > 0 then
            insert into public.order_item_modifiers(item_id, name, qty, price)
            values (
              v_new_item_id,
              coalesce(v_mod->>'name', ''),
              v_mod_qty,
              coalesce((v_mod->>'price')::numeric, 0)
            );
          end if;
        end loop;
      end if;

      v_qty_accum := v_qty_accum + v_qty_share;
      v_discount_accum := v_discount_accum + v_discount_share;
    end loop;
  end loop;

  -- Close extra empty checks not used by this equal split.
  update public.order_checks oc
  set is_closed = true,
      closed_at = now()
  where oc.order_id = p_order_id
    and oc.position > (v_people + 1)
    and oc.position > 1
    and not exists (
      select 1
      from public.order_items oi
      where oi.check_id = oc.id
        and oi.status not in ('paid'::public.item_status, 'void'::public.item_status)
    );

  -- Force totals refresh to avoid stale values in environments with legacy triggers.
  perform public.calculate_order_totals(p_order_id);
  for v_check_id in
    select oc.id
    from public.order_checks oc
    where oc.order_id = p_order_id
      and oc.position between 1 and (v_people + 1)
  loop
    perform public.calculate_check_totals(v_check_id);
  end loop;

  return query
  select *
  from public.order_checks oc
  where oc.order_id = p_order_id
    and oc.position between 2 and (v_people + 1)
  order by oc.position;
end;
$$;

grant execute on function public.fn_split_items_equally(uuid, integer) to authenticated;

-- END MIGRATION: 20260305_0012_split_items_equally_hardening.sql

-- ===================================================================
-- BEGIN MIGRATION: 20260305_0013_split_decimal_totals_hardening.sql
-- ===================================================================
-- 2026-03-05
-- Ensure item totals are always computed from decimal qty (not integer quantity).

create or replace function public.fn_compute_item_totals()
returns trigger
language plpgsql
as $$
declare
  mods_total numeric(12,2) := 0;
  v_origin public.order_origin;
  v_default_tax numeric := 0;
  v_service_enabled boolean := false;
  v_service_rate numeric := 0;
  v_tax_rate numeric := 0;
  v_qty numeric(10,3);
begin
  select coalesce(sum(price * qty), 0)
    into mods_total
  from public.order_item_modifiers
  where item_id = coalesce(new.id, old.id);

  -- Decimal qty is source of truth for billing math.
  v_qty := round(greatest(coalesce(new.qty, new.quantity::numeric, 1), 0.001), 3);
  new.qty := v_qty;

  -- Keep compatibility with legacy integer quantity consumers.
  if new.quantity is null or new.quantity::numeric <= 0 then
    new.quantity := greatest(round(v_qty), 1);
  end if;

  select
    ts.origin,
    coalesce(bs.default_tax_rate, 0),
    coalesce(bs.service_fee_enabled, false),
    coalesce(bs.service_fee_rate, 0)
  into v_origin, v_default_tax, v_service_enabled, v_service_rate
  from public.orders o
  join public.table_sessions ts on ts.id = o.session_id
  left join public.business_settings bs on bs.business_id = ts.business_id
  where o.id = new.order_id
  limit 1;

  if v_origin = 'quick' then
    v_tax_rate := coalesce(v_service_rate, 0);
  else
    v_tax_rate :=
      coalesce(v_default_tax, 0) +
      (case when v_service_enabled then coalesce(v_service_rate, 0) else 0 end);
  end if;

  new.subtotal := round((new.unit_price * v_qty) + mods_total, 2);
  new.tax := round(new.subtotal * (v_tax_rate / 100.0), 2);
  new.total := new.subtotal - coalesce(new.discounts, 0) + coalesce(new.tax, 0);

  return new;
end;
$$;

-- END MIGRATION: 20260305_0013_split_decimal_totals_hardening.sql

-- ===================================================================
-- BEGIN MIGRATION: 20260305_0014_update_item_details_rpc.sql
-- ===================================================================
-- 2026-03-05
-- RPC for full item edit from product detail modal (qty + discount/courtesy + notes).

create or replace function public.fn_update_item_details(
  p_item_id uuid,
  p_product_name text,
  p_qty numeric,
  p_is_takeout boolean,
  p_discounts numeric,
  p_notes text
)
returns void
language plpgsql
security definer
set search_path=public
as $$
declare
  v_order_id uuid;
  v_check_id uuid;
  v_qty numeric(10,3);
  v_discount numeric(12,2);
begin
  v_qty := round(greatest(coalesce(p_qty, 1), 0.001), 3);
  v_discount := round(greatest(coalesce(p_discounts, 0), 0), 2);

  update public.order_items
     set product_name = coalesce(nullif(trim(coalesce(p_product_name, '')), ''), product_name),
         qty = v_qty,
         quantity = greatest(round(v_qty), 1),
         is_takeout = coalesce(p_is_takeout, false),
         discounts = v_discount,
         notes = nullif(trim(coalesce(p_notes, '')), '')
   where id = p_item_id
   returning order_id, check_id into v_order_id, v_check_id;

  if v_order_id is null then
    raise exception 'ITEM_NOT_FOUND';
  end if;

  perform public.calculate_order_totals(v_order_id);
  if v_check_id is not null then
    perform public.calculate_check_totals(v_check_id);
  end if;
end;
$$;

grant execute on function public.fn_update_item_details(uuid, text, numeric, boolean, numeric, text) to authenticated;

-- END MIGRATION: 20260305_0014_update_item_details_rpc.sql

