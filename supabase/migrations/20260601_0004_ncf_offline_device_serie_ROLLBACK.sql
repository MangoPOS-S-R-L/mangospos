-- ROLLBACK de 20260601_0004_ncf_offline_device_serie.sql
-- Quita las columnas de trazabilidad de NCF offline. Aditivas → drop seguro.

begin;

alter table public.fiscal_documents
  drop column if exists offline_issued;

alter table public.ncf_sequences
  drop column if exists device_id;

commit;
