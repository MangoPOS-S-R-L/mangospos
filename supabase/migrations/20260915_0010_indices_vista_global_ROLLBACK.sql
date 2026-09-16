-- ===========================================================================
-- ROLLBACK de 20260915_0010_indices_vista_global.sql
--
-- Borra los cuatro índices. No toca datos: un índice se puede recrear
-- corriendo la migración de nuevo.
--
-- Nota: `drop index` toma un lock exclusivo corto sobre la tabla.
-- ===========================================================================

drop index if exists public.idx_payments_completed_business_created;
drop index if exists public.idx_fiscal_documents_active_business_issued;
drop index if exists public.idx_table_sessions_open_business;
drop index if exists public.idx_print_jobs_created_at;
