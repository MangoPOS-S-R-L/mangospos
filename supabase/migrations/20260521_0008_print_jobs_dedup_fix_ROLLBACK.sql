-- Rollback de `20260521_0008_print_jobs_dedup_fix.sql`.
--
-- NOTA: Restaurar el índice MÁS estricto puede fallar si ya hay rows con
-- la misma idempotency_key en businesses distintos (cosa que el índice
-- existente idx_print_jobs_idempotency sí permite). Si falla, hay que
-- decidir si limpiar la data o saltar el rollback.

begin;

create unique index if not exists uq_print_jobs_idempotency
  on public.print_jobs (idempotency_key)
  where idempotency_key is not null;

commit;
