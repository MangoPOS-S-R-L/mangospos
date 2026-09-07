-- ============================================================================
-- BARRA PAYÁN BEIBOLISTA — ROLLBACK de IMPORT_COMPLETO.sql
-- Business e0aef218-ab95-4ba4-b8ef-036fab1c07c7
-- Generado por scripts/build_import_e0aef218.py — NO EDITAR A MANO.
-- ============================================================================
--
-- Borra los {{N}} productos, sus {{N_CATS}} categorías y el grupo de
-- modificadores. Lleva la lista de nombres embebida, así que no depende de
-- ninguna tabla de staging.
--
-- ⚠ ABORTA SOLO SI YA SE VENDIÓ. Un producto con ventas no se puede borrar sin
--   romper el histórico y los reportes; el script lo detecta y no toca nada.
--   En ese caso desactiva en vez de borrar (is_active = false).
-- ============================================================================

begin;

do $$
declare
  v_business uuid := 'e0aef218-ab95-4ba4-b8ef-036fab1c07c7';
  v_vendidos int;
  v_group    uuid;
begin
  create temp table _payan_nombres(name text) on commit drop;
  insert into _payan_nombres values
    {{NOMBRES}};

  select count(distinct mi.id) into v_vendidos
  from public.menu_items mi
  join _payan_nombres s on lower(s.name) = lower(mi.name)
  where mi.business_id = v_business
    and exists (select 1 from public.order_items oi where oi.menu_item_id = mi.id);

  if v_vendidos > 0 then
    raise exception
      'ABORTADO: % productos ya tienen ventas. Borrarlos rompería el '
      'histórico. Desactívalos en vez de borrarlos: update public.menu_items '
      'set is_active = false where ...', v_vendidos;
  end if;

  select id into v_group from public.modifier_groups
  where business_id = v_business and name = 'Adicionales';

  if v_group is not null then
    delete from public.menu_item_groups where group_id = v_group;
    delete from public.modifiers where group_id = v_group;
    delete from public.modifier_groups where id = v_group;
  end if;

  -- Áreas e impuestos caen por FK cascade al borrar el item; se limpian
  -- explícito por si el cascade no estuviera en algún entorno.
  delete from public.menu_item_print_areas mipa
  using public.menu_items mi
  join _payan_nombres s on lower(s.name) = lower(mi.name)
  where mipa.menu_item_id = mi.id and mi.business_id = v_business;

  delete from public.menu_item_taxes mit
  using public.menu_items mi
  join _payan_nombres s on lower(s.name) = lower(mi.name)
  where mit.item_id = mi.id and mi.business_id = v_business;

  delete from public.menu_items mi
  using _payan_nombres s
  where mi.business_id = v_business and lower(mi.name) = lower(s.name);

  -- Categorías, solo si quedaron vacías.
  delete from public.categories c
  where c.business_id = v_business
    and c.name in ({{CATS_NOMBRES}})
    and not exists (select 1 from public.menu_items m where m.category_id = c.id);
end $$;

commit;

-- Verificación: los tres deben dar 0.
select
  (select count(*) from public.menu_items
     where business_id = 'e0aef218-ab95-4ba4-b8ef-036fab1c07c7'::uuid) as productos,
  (select count(*) from public.categories
     where business_id = 'e0aef218-ab95-4ba4-b8ef-036fab1c07c7'::uuid) as categorias,
  (select count(*) from public.modifier_groups
     where business_id = 'e0aef218-ab95-4ba4-b8ef-036fab1c07c7'::uuid) as grupos;
