-- =============================================================================
-- Inventario PRD: extender `recipes` para soportar producción de inventory_items.
--
-- CONCEPTO:
--   Hoy `recipes.menu_item_id` apunta SIEMPRE a un menu_item (producto del
--   menú que el cliente compra). Para producción interna (ej. salsa de
--   tomate como insumo intermedio) la receta debe apuntar a un
--   inventory_item directamente.
--
-- ENTREGA:
--   1. Nueva columna `recipes.inventory_item_id` (FK a inventory_items,
--      nullable).
--   2. CHECK constraint: exactamente UNO entre menu_item_id e
--      inventory_item_id debe estar seteado.
--   3. UNIQUE en (inventory_item_id) — una receta por inventory_item.
--
-- IMPACTO:
--   - Recetas existentes no se afectan (todas tienen menu_item_id, el
--     nuevo CHECK lo permite).
--   - Nuevas recetas para inventory items se crean dejando menu_item_id
--     NULL y poblando inventory_item_id.
--
-- IDEMPOTENTE: ADD COLUMN IF NOT EXISTS + DO bloque para constraint.
-- =============================================================================

begin;

-- Cambiar menu_item_id a nullable para permitir recetas de inventory_items.
alter table public.recipes
  alter column menu_item_id drop not null;

alter table public.recipes
  add column if not exists inventory_item_id uuid;

-- FK (idempotente)
do $$
begin
  if not exists (
    select 1 from pg_constraint
    where conname = 'recipes_inventory_item_fk'
  ) then
    alter table public.recipes
      add constraint recipes_inventory_item_fk
      foreign key (inventory_item_id)
      references public.inventory_items(id)
      on delete cascade;
  end if;
end $$;

-- CHECK: exactamente uno de los dos campos debe estar set.
do $$
begin
  if not exists (
    select 1 from pg_constraint
    where conname = 'recipes_target_exclusive_check'
  ) then
    alter table public.recipes
      add constraint recipes_target_exclusive_check
      check (
        (menu_item_id is not null and inventory_item_id is null)
        or (menu_item_id is null and inventory_item_id is not null)
      );
  end if;
end $$;

-- UNIQUE: una sola receta por inventory_item (igual que para menu_items).
create unique index if not exists recipes_inventory_item_unique
  on public.recipes (inventory_item_id)
  where inventory_item_id is not null;

comment on column public.recipes.inventory_item_id is
  'Target de la receta cuando es una receta de producción (inventory item). '
  'Mutuamente excluyente con menu_item_id: cada receta apunta a UN target. '
  'Habilita el flujo de producción donde una raw_material se transforma en '
  'un finished_product mediante una orden de producción.';

commit;
