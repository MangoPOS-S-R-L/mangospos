-- =============================================================================
-- Feature flag de inventario (2026-05-13).
--
-- PRD 9 entregaba inventario V1 como "vendido tal cual" (cardinalidad 1
-- menu→inventory). V2 traería recetas. Pero hay un tercer caso: los
-- negocios que NO quieren llevar inventario en absoluto.
--
-- Este flag permite que el admin elija qué nivel de control usar:
--   - `none`: el módulo de Inventario está oculto en Ajustes. La
--     función consume_inventory_from_order corre, pero como no hay
--     recipes vinculadas, no descuenta nada — no-op silencioso.
--   - `basic`: 1:1 menu_item → inventory_item. Al activar, se ejecuta
--     bootstrap_menu_to_inventory_links() que crea inventory_items,
--     recipes y un recipe_ingredient (qty=1) por cada menu_item.
--     El cajero ve "Stock disponible" pero no edita recetas.
--   - `advanced`: receta completa (BOM). El admin edita los
--     recipe_ingredients de cada menu_item (cocteles, platos
--     compuestos). El consumo descuenta cada ingrediente según su qty.
--
-- BACKWARDS-COMPATIBLE:
--   - Default `none`: comportamiento histórico (no se asume nada).
--   - Los negocios que ya tienen inventario configurado pueden setear
--     `advanced` manualmente — no hay migración destructiva.
--   - El backend consume_inventory_from_order es el mismo en los 3
--     modos; el flag controla SOLO la UI (qué muestra, qué oculta).
-- =============================================================================

begin;

alter table public.business_settings
  add column if not exists inventory_mode text default 'none' not null;

-- Restricción al set de valores válidos. Si el código manda algo raro,
-- la BD rechaza.
do $$
begin
  if not exists (
    select 1 from pg_constraint
    where conname = 'business_settings_inventory_mode_check'
      and conrelid = 'public.business_settings'::regclass
  ) then
    alter table public.business_settings
      add constraint business_settings_inventory_mode_check
      check (inventory_mode in ('none', 'basic', 'advanced'));
  end if;
end$$;

comment on column public.business_settings.inventory_mode is
  'Nivel de inventario del negocio. none = sin módulo (default), basic '
  '= 1:1 menu→inventory con stock por unidad, advanced = recetas '
  'completas (BOM) editables. Al cambiar a basic, el admin debe correr '
  'bootstrap_menu_to_inventory_links() para generar los links.';

commit;
