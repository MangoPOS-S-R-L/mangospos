-- =============================================================================
-- Permite hasta 2 conteos firmados por sesión (original + reconteo).
--
-- CONTEXTO:
--   El flujo de reconteo cambió: ahora el botón "Volver a contar" sale
--   en la pantalla de resultado (post-firma + impresión) en vez de
--   antes de firmar. Eso requiere que la tabla `cash_count_blind`
--   acepte una segunda fila para la misma sesión (el reconteo), sin
--   borrar la primera — ambas filas quedan como evidencia.
--
-- CAMBIOS:
--   1. Columna nueva `attempt_number` (1 = original, 2 = reconteo).
--   2. CHECK constraint: solo 1 o 2 (máximo 1 reconteo por sesión).
--   3. Reemplazar UNIQUE(cash_register_session_id) por
--      UNIQUE(cash_register_session_id, attempt_number) — permite las
--      dos filas convivir, pero impide duplicar el mismo attempt.
--
-- INMUTABILIDAD:
--   El trigger `trg_cash_count_blind_immutable` sigue activo y aplica
--   a cada fila por separado. Una vez firmada, esa fila no se puede
--   modificar/borrar. El reconteo crea una NUEVA fila — no toca la
--   original.
--
-- COMPATIBILIDAD:
--   Las filas existentes quedan automáticamente con `attempt_number=1`
--   (default). Ningún cliente vivo se rompe.
-- =============================================================================

begin;

alter table public.cash_count_blind
  add column if not exists attempt_number int not null default 1;

alter table public.cash_count_blind
  drop constraint if exists cash_count_blind_attempt_check;
alter table public.cash_count_blind
  add constraint cash_count_blind_attempt_check
  check (attempt_number between 1 and 2);

alter table public.cash_count_blind
  drop constraint if exists cash_count_blind_session_unique;

alter table public.cash_count_blind
  drop constraint if exists cash_count_blind_session_attempt_unique;
alter table public.cash_count_blind
  add constraint cash_count_blind_session_attempt_unique
  unique (cash_register_session_id, attempt_number);

comment on column public.cash_count_blind.attempt_number is
  '1 = conteo original (default). 2 = reconteo opcional disparado por '
  'el botón "Volver a contar" en la pantalla de resultado. Máximo 2 '
  'por sesión (CHECK). Ambas filas quedan como evidencia de auditoría.';

commit;
