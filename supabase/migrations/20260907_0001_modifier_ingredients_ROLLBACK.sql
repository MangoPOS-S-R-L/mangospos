-- ROLLBACK de 20260907_0001_modifier_ingredients.sql
--
-- OJO: borra la configuración de insumos por modificador. Si ya se capturó,
-- exportarla antes:
--   select * from public.modifier_ingredients;
--
-- Aplicar ANTES el rollback de 20260907_0003 (el consumo lee esta tabla).

begin;

drop policy if exists "mi_ing_write" on public.modifier_ingredients;
drop policy if exists "mi_ing_select" on public.modifier_ingredients;
drop table if exists public.modifier_ingredients;

commit;
