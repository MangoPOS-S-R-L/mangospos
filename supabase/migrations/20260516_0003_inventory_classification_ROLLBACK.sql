-- Rollback de `20260516_0003_inventory_classification.sql`.
begin;
drop index if exists public.idx_inventory_items_classification;
alter table public.inventory_items
  drop constraint if exists inventory_items_classification_check;
alter table public.inventory_items
  drop column if exists item_classification;
commit;
