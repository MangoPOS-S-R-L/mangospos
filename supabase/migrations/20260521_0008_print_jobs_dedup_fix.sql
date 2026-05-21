-- =============================================================================
-- Fase 1 — Printing v2 fix: eliminar índice redundante de idempotency_key.
--
-- PROBLEMA:
--   La migración 20260521_0007_print_jobs_extend_v2 creó:
--     create unique index uq_print_jobs_idempotency
--       on public.print_jobs (idempotency_key)
--       where idempotency_key is not null;
--
--   Pero la columna `idempotency_key` ya existía como `text` desde la
--   migración 20260513_0008_print_jobs_cloud_queue, junto con su propio
--   índice único MÁS PERMISIVO:
--     create unique index idx_print_jobs_idempotency
--       on public.print_jobs (business_id, idempotency_key)
--       where idempotency_key is not null
--         and status <> 'cancelled';
--
--   Diferencias relevantes:
--     - El existente: UNIQUE por (business_id, idempotency_key) y permite
--       reusar la key en jobs cancelados (intencional para reintentos).
--     - Mi nuevo:    UNIQUE solo por idempotency_key (global), bloqueando
--       que dos businesses distintos usen la misma clave (no es lo deseado).
--
--   Además, el `ADD COLUMN IF NOT EXISTS idempotency_key uuid` de mi
--   migración fue **no-op** porque la columna ya existía como `text` —
--   no cambió el tipo. La columna se queda como `text` (es lo correcto;
--   permite UUIDs como string + hashes/keys arbitrarios del cliente).
--
-- FIX:
--   1. Dropear `uq_print_jobs_idempotency` (mi índice redundante).
--   2. Mantener `idx_print_jobs_idempotency` (el correcto, preexistente).
--
-- COMPATIBILIDAD:
--   100% segura. Eliminar un índice único más estricto no rompe nada —
--   solo deja de rechazar inserts que el otro índice (más permisivo)
--   permitía igual. No hay riesgo de duplicados porque el otro índice
--   sigue activo.
-- =============================================================================

begin;

drop index if exists public.uq_print_jobs_idempotency;

-- Documentar tipo correcto de idempotency_key
comment on column public.print_jobs.idempotency_key is
  'Clave única que el cliente provee para evitar duplicar jobs si reintenta '
  'encolar tras un network glitch. Tipo TEXT (no UUID) — permite UUIDs '
  'serializados como string + hashes/keys arbitrarios. UNIQUE por '
  '(business_id, idempotency_key) WHERE status <> ''cancelled'' (índice '
  'idx_print_jobs_idempotency de migración 20260513_0008).';

commit;
