-- ROLLBACK de 20260606_0001_delivery_address.sql
-- Restaura fn_list_delivery_orders a su firma previa (sin delivery_address)
-- y elimina las columnas agregadas.

begin;

-- Restaurar la función a la versión de 20260408_0002 (sin delivery_address)
-- DROP previo: cambia el tipo de retorno (quita delivery_address).
drop function if exists public.fn_list_delivery_orders(uuid);

create or replace function public.fn_list_delivery_orders(
  p_business_id uuid
) returns table(
  session_id uuid, order_id uuid, table_id uuid,
  table_code text, delivery_type text, status_ext text,
  total numeric, items_count bigint, opened_at timestamptz,
  customer_name text
)
language sql stable security definer set search_path = public
as $$
  select
    ts.id as session_id,
    o.id as order_id,
    dt.id as table_id,
    dt.code as table_code,
    ts.delivery_type,
    o.status_ext::text,
    coalesce(o.total, 0) as total,
    coalesce(item_counts.cnt, 0) as items_count,
    ts.opened_at,
    ts.customer_name
  from public.table_sessions ts
  join public.dining_tables dt on ts.table_id = dt.id
  join public.zones z on dt.zone_id = z.id
  left join public.orders o on ts.id = o.session_id
  left join lateral (
    select count(*) as cnt from public.order_items oi where oi.order_id = o.id
  ) item_counts on true
  where z.business_id = p_business_id
    and ts.origin = 'delivery'
    and ts.closed_at is null
  order by ts.opened_at desc;
$$;

grant execute on function public.fn_list_delivery_orders(uuid) to authenticated;

alter table public.business_settings drop column if exists delivery_address_enabled;
alter table public.table_sessions drop column if exists delivery_address;

commit;
