-- =============================================================================
-- 20260907_0008 — Token LAN por negocio para el Hub Local (paso 8 offline)
-- =============================================================================
--
-- Hoy el agente LAN y el cliente del Hub comparten UNA constante compilada
-- (`MANGOPOS_SECURE_TOKEN_123`), igual para todos los negocios del mundo. Quien
-- la conozca —está en el binario— puede hablarle al Hub de cualquier local.
--
-- Peor: el middleware del agente solo rechaza cuando el header viene y NO
-- coincide. Si la petición llega SIN `Authorization`, pasa. O sea que hoy
-- cualquiera en la WiFi del local puede leer el salón y las órdenes
-- (`/hub/salon`, `/hub/order`) y, sobre todo, INYECTAR operaciones en el op-log
-- (`POST /hub/ops`) — que después el uplink sube a Supabase como ventas reales.
-- Eso se cierra del lado app en este mismo cambio.
--
-- Esta migración aporta la mitad de datos: un secreto POR NEGOCIO.
--
-- `gen_random_uuid()` es volátil, así que Postgres lo evalúa POR FILA al
-- agregar la columna: cada negocio existente queda con un token distinto, no
-- todos con el mismo. No hace falta backfill.
--
-- Rollout sin romper nada: la app acepta el token del negocio O la constante
-- legacy mientras haya equipos con builds viejos. Cuando toda la flota esté
-- actualizada se puede quitar la constante (ver `kLegacyHubLanToken`).
--
-- Sin impacto fiscal: no toca emisión, NCF ni fiscal_documents.
-- =============================================================================

begin;

alter table public.business_settings
  add column if not exists lan_token uuid not null default gen_random_uuid();

comment on column public.business_settings.lan_token is
  'Secreto compartido para autorizar las llamadas LAN al Hub Local de ESTE '
  'negocio (`/hub/*` del agente). No es una credencial de Supabase: solo '
  'autoriza dentro de la red del local. Rotarlo obliga a que las cajas '
  'vuelvan a bajar la configuración.';

commit;
