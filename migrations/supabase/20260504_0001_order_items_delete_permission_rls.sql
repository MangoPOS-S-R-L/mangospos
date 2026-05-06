-- Blinda la eliminación de items de orden con el permiso
-- ventas.orden.eliminar_item, tanto a nivel RLS como dentro del RPC
-- fn_delete_item (que es SECURITY DEFINER y bypassea RLS).

begin;

-- 1) Reemplazar la policy combinada items_rw por tres policies explícitas
--    (insert, update, delete) para que solo DELETE valide el permiso.
drop policy if exists "items_rw" on public.order_items;
drop policy if exists "order_items_insert" on public.order_items;
drop policy if exists "order_items_update" on public.order_items;
drop policy if exists "order_items_delete" on public.order_items;

create policy "order_items_insert"
on public.order_items
for insert
to authenticated
with check (
  exists (
    select 1
    from public.orders o
    join public.table_sessions s on s.id = o.session_id
    join public.dining_tables t on t.id = s.table_id
    join public.zones z on z.id = t.zone_id
    where o.id = order_items.order_id
      and z.business_id in (select public.current_user_business_ids())
  )
);

create policy "order_items_update"
on public.order_items
for update
to authenticated
using (
  exists (
    select 1
    from public.orders o
    join public.table_sessions s on s.id = o.session_id
    join public.dining_tables t on t.id = s.table_id
    join public.zones z on z.id = t.zone_id
    where o.id = order_items.order_id
      and z.business_id in (select public.current_user_business_ids())
  )
)
with check (
  exists (
    select 1
    from public.orders o
    join public.table_sessions s on s.id = o.session_id
    join public.dining_tables t on t.id = s.table_id
    join public.zones z on z.id = t.zone_id
    where o.id = order_items.order_id
      and z.business_id in (select public.current_user_business_ids())
  )
);

create policy "order_items_delete"
on public.order_items
for delete
to authenticated
using (
  exists (
    select 1
    from public.orders o
    join public.table_sessions s on s.id = o.session_id
    join public.dining_tables t on t.id = s.table_id
    join public.zones z on z.id = t.zone_id
    where o.id = order_items.order_id
      and z.business_id in (select public.current_user_business_ids())
      and exists (
        select 1
        from public.fn_user_effective_permissions(auth.uid(), z.business_id) p
        where p.code = 'ventas.orden.eliminar_item'
          and p.allowed = true
      )
  )
);

-- 2) Blindar el RPC fn_delete_item: como es SECURITY DEFINER bypassea RLS,
--    así que necesita validar el permiso explícitamente con auth.uid().
create or replace function public.fn_delete_item(p_item_id uuid)
returns void
language plpgsql
security definer
set search_path to 'public'
as $$
declare
  v_order_id uuid;
  v_business_id uuid;
  v_allowed boolean;
begin
  -- Resolver business_id del item para validar permiso
  select z.business_id
    into v_business_id
    from public.order_items oi
    join public.orders o on o.id = oi.order_id
    join public.table_sessions s on s.id = o.session_id
    join public.dining_tables t on t.id = s.table_id
    join public.zones z on z.id = t.zone_id
    where oi.id = p_item_id;

  if v_business_id is null then
    raise exception 'ITEM_NOT_FOUND';
  end if;

  -- Validar permiso ventas.orden.eliminar_item
  select coalesce(bool_or(p.allowed), false)
    into v_allowed
    from public.fn_user_effective_permissions(auth.uid(), v_business_id) p
    where p.code = 'ventas.orden.eliminar_item';

  if not v_allowed then
    raise exception 'PERMISSION_DENIED: ventas.orden.eliminar_item'
      using errcode = '42501';
  end if;

  delete from public.order_items
   where id = p_item_id
   returning order_id into v_order_id;

  if v_order_id is null then
    raise exception 'ITEM_NOT_FOUND';
  end if;

  perform public.fn_recalc_order_totals(v_order_id);
end;
$$;

commit;

-- =============================================================================
-- Smoke checks (ejecutar manualmente en SQL Editor después de aplicar)
-- =============================================================================
-- 1. Verificar que las 3 policies existen:
--    select policyname, cmd from pg_policies
--     where tablename = 'order_items' order by policyname;
--
-- 2. Ver permisos efectivos del usuario en un business:
--    select * from public.fn_user_effective_permissions(
--      auth.uid(), '<business_id>'::uuid
--    ) where code like 'ventas.orden%';
--
-- 3. Como cajero/cook (sin permiso), un DELETE debe fallar.
--    Como manager/owner/admin debe pasar.
