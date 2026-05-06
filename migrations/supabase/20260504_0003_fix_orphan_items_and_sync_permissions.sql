-- Fix consolidado:
-- 1) fn_close_order_and_table: marcar items como void/paid cuando se cierra orden
-- 2) Vista kds_active_items: filtrar items de órdenes cerradas/anuladas
-- 3) fn_get_order_bundle: filtrar items de órdenes cerradas/anuladas
-- 4) Sync de role_permissions con el catálogo Dart actualizado:
--    - Quitar ventas.orden.eliminar_item del rol waiter
--    - Asegurar que manager tenga settings.usuarios.crear/editar/desactivar

begin;

-- =============================================================================
-- 1) fn_close_order_and_table: marcar items al cerrar la orden
-- =============================================================================
-- Cuando se cierra una orden con status='void', todos los items vivos quedan
-- como void. Cuando se cierra con 'paid', los items vivos quedan paid.
-- Esto previene items huérfanos que aparecen en mesas nuevas.

create or replace function public.fn_close_order_and_table(
  p_order_id uuid,
  p_status   public.order_status
)
returns void
language plpgsql
security definer
set search_path to 'public'
as $$
declare
  v_session uuid;
  v_open_count int;
  v_table_id uuid;
  v_item_target public.item_status;
begin
  -- Cerrar la orden
  update public.orders
     set status_ext = p_status,
         closed_at  = now()
   where id = p_order_id;

  -- Determinar el target status para items
  v_item_target := case p_status
    when 'paid'      then 'paid'::public.item_status
    when 'void'      then 'void'::public.item_status
    when 'cancelled' then 'void'::public.item_status
    else null
  end;

  -- Marcar items vivos como el target (solo si tenemos uno definido)
  if v_item_target is not null then
    update public.order_items
       set status = v_item_target
     where order_id = p_order_id
       and status not in ('paid'::public.item_status, 'void'::public.item_status);
  end if;

  -- Resolver session y table
  select session_id  into v_session  from public.orders         where id = p_order_id;
  select table_id    into v_table_id from public.table_sessions where id = v_session;

  -- Si no hay más órdenes abiertas en la sesión, cerrar sesión y mesa
  select count(*) into v_open_count
    from public.orders
   where session_id = v_session
     and closed_at is null
     and status_ext not in ('paid', 'void');

  if coalesce(v_open_count, 0) = 0 then
    update public.table_sessions
       set closed_at = now()
     where id = v_session
       and closed_at is null;

    if v_table_id is not null then
      update public.dining_tables
         set state = 'available'
       where id = v_table_id;
    end if;
  end if;
end;
$$;

-- =============================================================================
-- 2) Vista kds_active_items: agregar filtro de orden activa
-- =============================================================================
-- Antes: mostraba items con status pending/preparing/ready aunque la orden
-- estuviera void/cerrada. Ahora filtra por estado de orden padre.

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
    when ts.origin = 'quick'  then 'Venta rapida'
    else 'Venta'
  end as table_name,
  p.full_name as waiter_name,
  z.business_id,
  null::text as area_code,
  coalesce(mods.modifiers, '[]'::json) as modifiers
from public.order_items oi
join public.orders o            on o.id = oi.order_id
join public.table_sessions ts   on ts.id = o.session_id
left join public.dining_tables dt on dt.id = ts.table_id
left join public.zones z          on z.id = dt.zone_id
left join public.profiles p       on p.id = ts.waiter_user_id
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
where oi.status in ('pending', 'preparing', 'ready')
  and o.closed_at is null
  and o.status_ext not in ('paid', 'void');

-- =============================================================================
-- 3) fn_get_order_bundle: filtrar items de órdenes cerradas
-- =============================================================================
-- Defensa en profundidad: si por algún error queda un item vivo en orden
-- cerrada, el bundle lo excluye y la UI no lo muestra.

create or replace function public.fn_get_order_bundle(
  p_order_id uuid
)
returns jsonb
language plpgsql
security definer
set search_path = public
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
    select ts.customer_id, ts.customer_name
    from target_order o
    join public.table_sessions ts on ts.id = o.session_id
  )
  select jsonb_build_object(
    'order',
      (select to_jsonb(o) from target_order o),
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
          join target_order o on o.id = oi.order_id
          where oi.status not in ('paid'::public.item_status, 'void'::public.item_status)
            and (o.closed_at is null or o.status_ext not in ('void', 'paid'))
        ),
        '[]'::jsonb
      ),
    'customer_id',
      (select customer_id from order_customer limit 1),
    'customer_name',
      (select customer_name from order_customer limit 1)
  )
  into v_payload;

  if v_payload is null or (v_payload -> 'order') is null then
    raise exception 'ORDER_NOT_FOUND';
  end if;

  return v_payload;
end;
$$;

grant execute on function public.fn_get_order_bundle(uuid) to authenticated;

-- =============================================================================
-- 4) Sync de role_permissions con el catálogo Dart
-- =============================================================================

-- 4a) Quitar ventas.orden.eliminar_item del rol waiter en TODOS los businesses
delete from public.role_permissions rp
 using public.roles r,
       public.permissions p
 where rp.role_id = r.id
   and rp.permission_id = p.id
   and lower(r.name) = 'waiter'
   and r.is_system = true
   and p.code = 'ventas.orden.eliminar_item';

-- 4b) Asegurar que manager tenga ventas.orden.eliminar_item
do $$
declare
  v_business_id uuid;
  v_role_id uuid;
  v_perm_codes text[] := array[
    'ventas.orden.eliminar_item',
    'settings.usuarios.crear',
    'settings.usuarios.editar',
    'settings.usuarios.desactivar'
  ];
  v_code text;
begin
  for v_business_id in select id from public.businesses loop
    select id into v_role_id
      from public.roles
      where business_id = v_business_id
        and lower(name) = 'manager'
        and is_system = true
      limit 1;

    if v_role_id is null then
      continue;
    end if;

    foreach v_code in array v_perm_codes loop
      insert into public.role_permissions (role_id, permission_id, allow)
      select v_role_id, p.id, true
        from public.permissions p
        where p.code = v_code
      on conflict (role_id, permission_id) do update
        set allow = true;
    end loop;
  end loop;
end;
$$;

-- 4c) Limpiar overrides huérfanos: si un usuario tenía override "allow" para
--     ventas.orden.eliminar_item siendo waiter (porque el rol antes lo daba
--     y se intentó forzar permanencia), no es un problema — los overrides
--     se interpretan correctamente. No se limpian aquí.

commit;

-- =============================================================================
-- Smoke checks (correr después de aplicar)
-- =============================================================================
-- 1. Ningún waiter debe tener ventas.orden.eliminar_item:
--    select count(*) from role_permissions rp
--      join roles r on r.id = rp.role_id
--      join permissions p on p.id = rp.permission_id
--     where lower(r.name) = 'waiter'
--       and p.code = 'ventas.orden.eliminar_item';
--    -- Esperado: 0
--
-- 2. Manager debe tener los 4 permisos clave:
--    select r.business_id, p.code
--      from role_permissions rp
--      join roles r on r.id = rp.role_id
--      join permissions p on p.id = rp.permission_id
--     where lower(r.name) = 'manager'
--       and r.is_system = true
--       and p.code in (
--         'ventas.orden.eliminar_item',
--         'settings.usuarios.crear',
--         'settings.usuarios.editar',
--         'settings.usuarios.desactivar'
--       )
--     order by r.business_id, p.code;
--
-- 3. KDS no debe mostrar items de órdenes void/cerradas:
--    select count(*) from kds_active_items;
--    -- Comparar con: select count(*) from order_items
--    --   where status in ('pending','preparing','ready');
--    -- El primero debe ser <= al segundo
--
-- 4. Test manual: anular una orden (con items vivos), verificar que los items
--    queden con status='void' inmediatamente.
