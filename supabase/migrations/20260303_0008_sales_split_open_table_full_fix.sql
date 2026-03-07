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

