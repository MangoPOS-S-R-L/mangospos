begin;

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
session_order_totals as (
  select
    ao.session_id,
    count(*)::bigint as orders_count,
    coalesce(sum(o.total), 0)::numeric as total
  from active_orders ao
  join public.orders o
    on o.id = ao.id
  group by ao.session_id
),
session_item_counts as (
  select
    ao.session_id,
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
  coalesce(sot.orders_count, 0::bigint) as orders_count,
  s.people_count,
  coalesce(sot.total, 0::numeric) as total,
  coalesce(sic.items_count, 0::bigint) as items_count
from public.dining_tables t
join public.zones z on z.id = t.zone_id
left join latest_open_session s on s.table_id = t.id
left join session_order_totals sot on sot.session_id = s.session_id
left join session_item_counts sic on sic.session_id = s.session_id
where t.is_active = true;

grant select on public.v_zone_table_status to authenticated;

commit;
