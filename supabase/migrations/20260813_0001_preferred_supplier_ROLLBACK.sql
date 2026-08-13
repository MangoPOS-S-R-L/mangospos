-- Rollback de 20260813_0001_preferred_supplier.sql

begin;

alter table public.inventory_items
  drop column if exists preferred_supplier_id;

commit;
