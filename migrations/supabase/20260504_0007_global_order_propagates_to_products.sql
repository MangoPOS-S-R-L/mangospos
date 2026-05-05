-- Reordenar grupos de modificadores GLOBALMENTE ahora propaga a TODOS
-- los productos del negocio. Antes el orden global solo aplicaba a nuevas
-- asignaciones (producto + grupo nuevo) por el trigger de la migración 0006.
-- Productos ya asignados mantenían el `position` inicial alfabético, lo
-- cual generaba disonancia visual en venta.
--
-- Cambios:
--   1) fn_reorder_modifier_groups_global ahora también actualiza
--      menu_item_groups.position de TODOS los productos del negocio,
--      sincronizando con el sort_order recién asignado.
--   2) Sincronización one-time para alinear datos existentes.
--
-- Nota: si quieres customizar el orden de un producto específico
-- distinto del global, lo haces en su editor (Modificadores y orden).
-- Pero si después reordenas globalmente, vuelve a pisar.

begin;

create or replace function public.fn_reorder_modifier_groups_global(
  p_business_id uuid,
  p_group_ids   uuid[]
)
returns void
language plpgsql
security definer
set search_path to 'public'
as $$
declare
  i int;
begin
  if p_business_id is null then
    raise exception 'business_id is required';
  end if;
  if p_group_ids is null or array_length(p_group_ids, 1) is null then
    return;
  end if;

  -- a) Actualizar sort_order GLOBAL de cada grupo
  for i in 1..array_length(p_group_ids, 1) loop
    update public.modifier_groups
       set sort_order = i
     where id = p_group_ids[i]
       and business_id = p_business_id;
  end loop;

  -- b) Propagar a TODOS los productos del negocio: actualizar position
  --    a partir del sort_order que acabamos de setear.
  update public.menu_item_groups mig
     set position = (
       select mg.sort_order
         from public.modifier_groups mg
         where mg.id = mig.group_id
     )
   where exists (
     select 1
       from public.menu_items mi
       where mi.id = mig.menu_item_id
         and mi.business_id = p_business_id
   );
end;
$$;

-- Sincronización one-time para alinear datos existentes en TODOS los negocios
-- (los que ya hubieran reordenado globalmente antes de este fix).
update public.menu_item_groups mig
   set position = (
     select mg.sort_order
       from public.modifier_groups mg
       where mg.id = mig.group_id
   )
 where (
   select coalesce(mg.sort_order, 0)
     from public.modifier_groups mg
     where mg.id = mig.group_id
 ) > 0;

commit;

-- =============================================================================
-- Smoke checks
-- =============================================================================
-- 1. Verificar 0 disonancias entre position por producto y sort_order global:
--    select count(*)
--      from public.menu_item_groups mig
--      join public.modifier_groups mg ON mg.id = mig.group_id
--     where mig.position <> mg.sort_order
--       and mg.sort_order > 0;
--    -- Debe devolver 0
--
-- 2. Probar reordenando globalmente y verificando que se propaga:
--    select fn_reorder_modifier_groups_global(
--      '<business_id>'::uuid,
--      array['<group_id_1>'::uuid, '<group_id_2>'::uuid]
--    );
--    select mi.name as producto, mg.name as grupo, mig.position, mg.sort_order
--      from menu_item_groups mig
--      join modifier_groups mg on mg.id = mig.group_id
--      join menu_items mi on mi.id = mig.menu_item_id
--      where mi.business_id = '<business_id>'::uuid
--      order by mi.name, mig.position;
