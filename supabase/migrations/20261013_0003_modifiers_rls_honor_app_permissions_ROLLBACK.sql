-- Rollback de 20261013_0003_modifiers_rls_honor_app_permissions.sql
-- Las policies base (menu_item_groups_write, modifier_groups_write,
-- modifiers_write, mi_ing_write — owner/admin) quedan intactas.

begin;

drop policy if exists "mg_insert_by_permission" on public.modifier_groups;
drop policy if exists "mg_update_by_permission" on public.modifier_groups;
drop policy if exists "mg_delete_by_permission" on public.modifier_groups;

drop policy if exists "mod_insert_by_permission" on public.modifiers;
drop policy if exists "mod_update_by_permission" on public.modifiers;
drop policy if exists "mod_delete_by_permission" on public.modifiers;

drop policy if exists "mig_insert_by_permission" on public.menu_item_groups;
drop policy if exists "mig_update_by_permission" on public.menu_item_groups;
drop policy if exists "mig_delete_by_permission" on public.menu_item_groups;

drop policy if exists "mi_ing_insert_by_permission" on public.modifier_ingredients;
drop policy if exists "mi_ing_update_by_permission" on public.modifier_ingredients;
drop policy if exists "mi_ing_delete_by_permission" on public.modifier_ingredients;

commit;
