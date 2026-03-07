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
