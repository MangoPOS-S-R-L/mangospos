-- ROLLBACK de 20260608_0002_inventory_pack_conversion.sql

begin;

alter table public.purchase_order_items drop column if exists pack_size;
alter table public.purchase_order_items drop column if exists purchase_unit;

alter table public.inventory_items drop column if exists pack_size;
alter table public.inventory_items drop column if exists purchase_unit;

comment on column public.inventory_items.unit is null;

commit;
