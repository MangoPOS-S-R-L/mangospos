-- Rollback de `20260521_0010_business_settings_multi_copy.sql`.

begin;

alter table public.business_settings
  drop column if exists print_precheck_multi_copy,
  drop column if exists print_receipt_multi_copy;

commit;
