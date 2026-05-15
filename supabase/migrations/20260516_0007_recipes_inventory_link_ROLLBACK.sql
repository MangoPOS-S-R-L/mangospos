-- Rollback de `20260516_0007_recipes_inventory_link.sql`.
-- ⚠️ Si hay recetas con inventory_item_id != null y menu_item_id null,
-- el rollback FALLA porque al volver menu_item_id NOT NULL esas filas
-- violarían el constraint. Hay que borrarlas primero:
--   delete from public.recipes where inventory_item_id is not null;
-- (Esto borra también sus recipe_ingredients vía CASCADE.)

begin;

drop index if exists public.recipes_inventory_item_unique;

alter table public.recipes
  drop constraint if exists recipes_target_exclusive_check;

alter table public.recipes
  drop constraint if exists recipes_inventory_item_fk;

alter table public.recipes
  drop column if exists inventory_item_id;

alter table public.recipes
  alter column menu_item_id set not null;

commit;
