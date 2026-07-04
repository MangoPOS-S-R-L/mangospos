-- ROLLBACK de 20260704_0001_purchase_invoice_number.sql

begin;

alter table public.purchase_orders
  drop column if exists invoice_number;

commit;
