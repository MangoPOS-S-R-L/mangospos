-- ROLLBACK de 20260616_0003 — quitar el modelo de factura por negocio.
begin;

alter table public.business_settings
  drop column if exists invoice_print_template;

commit;
