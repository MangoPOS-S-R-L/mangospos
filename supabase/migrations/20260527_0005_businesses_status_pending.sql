-- =============================================================================
-- Permite el valor 'pending' en `businesses.status`. Las cuentas nuevas
-- registradas desde la app del POS arrancan en este estado hasta que el
-- equipo interno las apruebe vía Mango Administrador.
--
-- Estados resultantes:
--   - pending   → cuenta creada pero NO puede usar la app (PendingApprovalGuard
--                 la bloquea). Se ve solo la pantalla "en revisión".
--   - active    → flujo normal, comercio operando.
--   - inactive  → suspendida por nosotros (mora, fraude, cierre voluntario).
--
-- Cuentas existentes NO se tocan — siguen como están (típicamente 'active').
-- Solo registros nuevos a partir de esta migration nacen en 'pending'.
-- =============================================================================

ALTER TABLE public.businesses
  DROP CONSTRAINT IF EXISTS businesses_status_check;

ALTER TABLE public.businesses
  ADD CONSTRAINT businesses_status_check
  CHECK (status IN ('active', 'inactive', 'pending'));

COMMENT ON COLUMN public.businesses.status IS
  'Estado operativo: pending (en revisión post-registro, app bloqueada), active (operando), inactive (suspendida/cerrada).';
