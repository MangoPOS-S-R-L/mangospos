-- =============================================================================
-- ROLLBACK 20260918_0001 — Dispositivos con sesión iniciada
-- =============================================================================
--
-- Borra la tabla y los cuatro RPC. Se pierde la lista de sesiones (no es data
-- de negocio: los equipos la vuelven a llenar en su próximo ping si se
-- re-aplica la migración).
--
-- Clientes con la versión nueva de la app siguen llamando el ping: el RPC
-- no existe → la app lo traga (best-effort) y no afecta el login ni la venta.
-- =============================================================================

begin;

drop function if exists public.fn_device_session_rename(uuid, text);
drop function if exists public.fn_device_session_revoke(uuid);
drop function if exists public.fn_device_sessions_list(uuid);
drop function if exists public.fn_device_session_ping(
  uuid, text, text, text, text, text, text, text, uuid, boolean
);
drop table if exists public.device_sessions;

commit;
