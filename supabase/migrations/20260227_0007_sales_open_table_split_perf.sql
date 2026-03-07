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
