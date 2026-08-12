-- Rollback de 20260811_0001_purchasing_suppliers_extend.sql
-- Elimina las columnas aditivas de suppliers. Seguro mientras ninguna app
-- las escriba todavía (F1 sin desplegar).

begin;

alter table public.suppliers drop column if exists tax_id_type;
alter table public.suppliers drop column if exists whatsapp;
alter table public.suppliers drop column if exists payment_terms_days;

commit;
