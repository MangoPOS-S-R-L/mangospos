-- KDS active items view and required columns
alter table public.order_items
  add column if not exists quantity numeric(10,3),
  add column if not exists started_at timestamptz,
  add column if not exists ready_at timestamptz;

create or replace view public.kds_active_items as
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
    when ts.origin = 'manual' then 'Venta manual'
    when ts.origin = 'quick' then 'Venta rapida'
    else 'Venta'
  end as table_name,
  p.full_name as waiter_name,
  z.business_id,
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
where oi.status in ('pending', 'preparing', 'ready');
