-- Rollback de 20260903_0001_credit_note_annulment.
--
-- OJO: los valores 'B03'/'B04' del enum ncf_type NO se pueden quitar (Postgres
-- no soporta DROP VALUE). Quedan en el enum sin usar, lo cual es inofensivo.
--
-- Las notas de credito YA EMITIDAS no se tocan: son comprobantes fiscales
-- declarados a la DGII. Solo se retira la maquinaria que las emite.

begin;

drop view if exists public.v_fiscal_docs_pending_credit_note;

drop function if exists public.fn_issue_credit_note(uuid, text, smallint);

drop index if exists public.idx_fiscal_documents_related_document;

alter table public.fiscal_documents
  drop constraint if exists fiscal_documents_modification_code_check;

-- Las columnas se dejan: borrarlas perderia el CodigoModificacion de las notas
-- ya emitidas, que es dato fiscal. Descomenta solo si NO hay ninguna.
-- alter table public.fiscal_documents
--   drop column if exists modification_code,
--   drop column if exists modification_reason;

commit;
