-- Rollback de 20260814_0003_purchase_ncf_and_payment_terms.sql
--
-- Seguro: la migración es aditiva y la copia de NCF dejó intacto
-- `invoice_number`, así que soltar las columnas no pierde ningún dato que no
-- siga estando en su lugar original.

begin;

drop index if exists public.idx_purchase_orders_business_ncf;

alter table public.purchase_orders
  drop column if exists ncf;

alter table public.supplier_credits
  drop column if exists ncf;

alter table public.suppliers
  drop column if exists payment_terms_days;

commit;
