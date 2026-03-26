begin;

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
  v_business_id uuid;
begin
  if p_order_id is null then
    raise exception 'ORDER_ID_REQUIRED';
  end if;

  select ts.business_id
    into v_business_id
  from public.orders o
  join public.table_sessions ts on ts.id = o.session_id
  where o.id = p_order_id
  limit 1;

  if v_business_id is null then
    raise exception 'ORDER_NOT_FOUND';
  end if;

  if not exists (
    select 1
    from public.current_user_business_ids() as bid
    where bid = v_business_id
  ) then
    raise exception 'ORDER_OUT_OF_SCOPE';
  end if;

  with target_order as (
    select o.*
    from public.orders o
    join public.table_sessions ts on ts.id = o.session_id
    where o.id = p_order_id
      and ts.business_id = v_business_id
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

drop view if exists public.v_zone_table_status;

create view public.v_zone_table_status
with (security_invoker = on) as
with latest_open_session as (
  select distinct on (ts.table_id)
    ts.id as session_id,
    ts.table_id,
    ts.opened_by,
    ts.opened_at,
    ts.closed_at,
    ts.people_count,
    ts.customer_name
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
  s.customer_name,
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
left join session_agg sa on sa.session_id = s.session_id
where t.is_active = true;

grant select on public.v_zone_table_status to authenticated;

commit;
