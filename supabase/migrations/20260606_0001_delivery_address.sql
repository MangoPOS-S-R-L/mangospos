-- ============================================================
-- DELIVERY: dirección de entrega opcional (config-driven)
-- ============================================================
-- 1. Columna para guardar la dirección en la sesión de delivery.
-- 2. Toggle en business_settings para mostrar/ocultar el campo.
-- 3. fn_list_delivery_orders ahora devuelve la dirección para las
--    tarjetas de la pantalla Delivery.
-- Todo aditivo y opt-in (default false): no rompe flujos existentes.

begin;

-- 1. Dirección de entrega en la sesión
alter table public.table_sessions
  add column if not exists delivery_address text;

comment on column public.table_sessions.delivery_address is
  'Dirección de entrega del pedido de delivery. Opcional; solo se '
  'captura cuando business_settings.delivery_address_enabled = true.';

-- 2. Toggle de configuración
alter table public.business_settings
  add column if not exists delivery_address_enabled boolean default false;

update public.business_settings
  set delivery_address_enabled = coalesce(delivery_address_enabled, false)
  where delivery_address_enabled is null;

comment on column public.business_settings.delivery_address_enabled is
  'Si true, los pedidos de delivery muestran un campo opcional de '
  'dirección de entrega. Default false (opt-in).';

-- 3. Exponer delivery_address en el listado de delivery
-- DROP previo: CREATE OR REPLACE no puede cambiar el tipo de retorno
-- (se agrega la columna delivery_address al RETURNS TABLE).
drop function if exists public.fn_list_delivery_orders(uuid);

create or replace function public.fn_list_delivery_orders(
  p_business_id uuid
) returns table(
  session_id uuid, order_id uuid, table_id uuid,
  table_code text, delivery_type text, status_ext text,
  total numeric, items_count bigint, opened_at timestamptz,
  customer_name text, delivery_address text
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
    ts.customer_name,
    ts.delivery_address
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

commit;
