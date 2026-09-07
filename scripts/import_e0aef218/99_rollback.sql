-- ============================================================================
-- Import de catálogo — BARRA PAYÁN
-- Business e0aef218-ab95-4ba4-b8ef-036fab1c07c7
-- ============================================================================
--
-- ROLLBACK — deshace los pasos 2-5.
--
-- ⚠ REQUIERE QUE EL STAGING SIGA VIVO (public._import_e0aef218). Es lo que
--   identifica qué productos entraron por el import. Si ya lo borraste en el
--   paso 6, este script aborta sin tocar nada.
--
-- ⚠ NO CORRAS ESTO SI YA SE VENDIÓ. Un menu_item referenciado por order_items
--   no se puede borrar; el script lo detecta y aborta antes de romper nada.
--   Si ya hay ventas, desactiva en vez de borrar (is_active = false).
-- ============================================================================

begin;

do $$
declare
  v_business uuid := 'e0aef218-ab95-4ba4-b8ef-036fab1c07c7';
  v_vendidos int;
  v_group    uuid;
begin
  if not exists (
    select 1 from information_schema.tables
    where table_schema = 'public' and table_name = '_import_e0aef218'
  ) then
    raise exception
      'No existe public._import_e0aef218. Sin el staging no se puede saber '
      'qué borrar. Vuelve a correr 01_staging.sql y reintenta.';
  end if;

  -- Guarda: ¿alguno ya se vendió?
  select count(distinct mi.id) into v_vendidos
  from public.menu_items mi
  join public._import_e0aef218 s on lower(s.name) = lower(mi.name)
  where mi.business_id = v_business
    and exists (select 1 from public.order_items oi where oi.menu_item_id = mi.id);

  if v_vendidos > 0 then
    raise exception
      'ABORTADO: % productos del import ya tienen ventas. Borrarlos rompería '
      'el histórico y los reportes. Desactívalos en vez de borrarlos: '
      'update public.menu_items set is_active = false where ...', v_vendidos;
  end if;

  -- 1) Modificadores
  select id into v_group from public.modifier_groups
  where business_id = v_business and name = 'Adicionales';

  if v_group is not null then
    delete from public.menu_item_groups where group_id = v_group;
    delete from public.modifiers where group_id = v_group;
    delete from public.modifier_groups where id = v_group;
  end if;

  -- 2) Áreas y 3) impuestos caen por FK on delete cascade al borrar el item,
  --    pero se limpian explícito por si el cascade no estuviera.
  delete from public.menu_item_print_areas mipa
  using public.menu_items mi
  join public._import_e0aef218 s on lower(s.name) = lower(mi.name)
  where mipa.menu_item_id = mi.id and mi.business_id = v_business;

  delete from public.menu_item_taxes mit
  using public.menu_items mi
  join public._import_e0aef218 s on lower(s.name) = lower(mi.name)
  where mit.item_id = mi.id and mi.business_id = v_business;

  -- 4) Productos
  delete from public.menu_items mi
  using public._import_e0aef218 s
  where mi.business_id = v_business and lower(mi.name) = lower(s.name);

  -- 5) Categorías, solo si quedaron vacías
  delete from public.categories c
  where c.business_id = v_business
    and c.name in ('Sándwiches', 'Otros', 'Jugos', 'Bebidas')
    and not exists (
      select 1 from public.menu_items m where m.category_id = c.id
    );
end $$;

commit;

-- Verificación: todo debe dar 0.
select
  (select count(*) from public.menu_items
     where business_id = 'e0aef218-ab95-4ba4-b8ef-036fab1c07c7'::uuid) as productos,
  (select count(*) from public.categories
     where business_id = 'e0aef218-ab95-4ba4-b8ef-036fab1c07c7'::uuid) as categorias,
  (select count(*) from public.modifier_groups
     where business_id = 'e0aef218-ab95-4ba4-b8ef-036fab1c07c7'::uuid) as grupos;

-- drop table if exists public._import_e0aef218;
