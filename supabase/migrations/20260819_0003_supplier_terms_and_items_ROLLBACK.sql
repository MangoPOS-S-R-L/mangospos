-- =============================================================================
-- ROLLBACK de 20260819_0003_supplier_terms_and_items.sql
--
-- OJO — lo que se pierde:
--   - `supplier_items` se DROPEA con su contenido: los códigos del proveedor,
--     unidades de compra y precios de lista cargados a mano no están en
--     ninguna otra tabla y no se recuperan.
--   - `payment_terms_type` / `payment_terms_from` / `min_order_amount` /
--     `lead_time_days` se pierden. El texto libre `payment_terms` NUNCA se
--     tocó, así que las condiciones vuelven a leerse de ahí igual que antes.
--
-- Lo que NO se toca a propósito:
--   - `payment_terms_days`: la agregaron 20260811_0001 y 20260814_0003, y el
--     módulo de compras la usa para el vencimiento de la cuenta por pagar.
--     Borrarla acá rompería una migración anterior.
-- =============================================================================

begin;

drop index if exists public.idx_suppliers_business_rnc_unique;

drop table if exists public.supplier_items;

alter table public.suppliers
  drop constraint if exists suppliers_payment_terms_type_check;
alter table public.suppliers
  drop constraint if exists suppliers_payment_terms_from_check;

alter table public.suppliers drop column if exists payment_terms_type;
alter table public.suppliers drop column if exists payment_terms_from;
alter table public.suppliers drop column if exists min_order_amount;
alter table public.suppliers drop column if exists lead_time_days;

commit;
