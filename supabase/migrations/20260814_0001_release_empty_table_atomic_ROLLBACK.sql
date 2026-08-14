-- =============================================================================
-- ROLLBACK 20260814_0001 — quitar fn_release_empty_table
-- =============================================================================
-- OJO: la app (a partir del build que acompaña esta migración) llama a esta
-- función para liberar mesas vacías. Si la borras SIN revertir también el
-- cliente, `releaseEmptyTableIfNeeded` fallará con PGRST202 (función
-- inexistente) y las mesas vacías se quedarán ocupadas hasta que las barra
-- `fn_release_empty_tables` (el cron con gracia de 15 min).
--
-- No hay datos que revertir: la función no crea tablas ni columnas.
-- =============================================================================

begin;

DROP FUNCTION IF EXISTS public.fn_release_empty_table(uuid);

commit;
