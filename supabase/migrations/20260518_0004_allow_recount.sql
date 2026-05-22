-- =============================================================================
-- Setting por negocio: permitir reconteos en el flujo de cierre de caja.
--
-- CONTEXTO:
--   El cierre de caja es a ciegas. Hoy el cajero cuenta una vez y, al
--   firmar/confirmar, el registro queda inmutable en BD. Si el cajero
--   se equivocó a mitad del wizard, puede ir Atrás entre pasos pero no
--   tiene un botón explícito para "borrar todo y empezar de nuevo".
--
-- SOLUCIÓN:
--   Flag `allow_recount` que, cuando está activo, expone un botón
--   "Volver a contar" en cada paso del wizard detallado y un botón
--   "Recontar" en el modal compacto. La acción resetea TODOS los
--   montos contados y devuelve al inicio del flujo. Si el cajero ya
--   firmó, el recount NO está disponible (el registro queda inmutable
--   como antes — esto NO es "reabrir caja").
--
-- DEFAULT: false. Preserva el comportamiento histórico hasta que el
-- admin active la opción desde Ajustes → Modo de cierre de caja.
--
-- IDEMPOTENTE: ADD COLUMN IF NOT EXISTS.
-- =============================================================================

begin;

alter table public.business_settings
  add column if not exists allow_recount boolean not null default false;

comment on column public.business_settings.allow_recount is
  'Si TRUE, durante el cierre de caja (ambos modos: compact y detailed) '
  'el cajero ve un botón "Volver a contar" / "Recontar" que limpia los '
  'montos contados y reinicia el flujo. NO permite reabrir un cierre '
  'ya firmado; solo dar marcha atrás antes de confirmar.';

commit;
