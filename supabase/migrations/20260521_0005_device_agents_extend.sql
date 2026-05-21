-- =============================================================================
-- Fase 1 — Printing v2: extender `device_agents` con metadata de salud.
--
-- CONTEXTO:
--   La tabla `device_agents` ya existe (migración 20260501_0002, PRD 5 F2.5)
--   con campos: id (uuid PK), business_id, device_name, agent_url, platform,
--   online, last_heartbeat_at, created_at, updated_at. La función
--   `fn_device_agent_heartbeat(uuid, text)` la actualiza cada 30s desde
--   el agent local.
--
--   Esta migración la EXTIENDE — no crea una tabla duplicada. La intención
--   original de Printing v2 era una `device_agents_health` separada, pero
--   eso duplicaría datos y rompería el contrato del repo. Se reaprovecha
--   la tabla existente.
--
-- CAMBIOS:
--   1. Nuevas columnas en `device_agents`:
--      - agent_version  text   — versión del binario del agent.
--      - os             text   — Darwin/Linux/Windows/Android/iOS.
--      - hostname       text   — hostname legible (display en dashboards).
--      - available_transports text[] — {lan,usb,bluetooth,serial,cups}.
--      - metadata       jsonb  — info libre para debugging remoto.
--   2. La función `fn_device_agent_heartbeat` se reemplaza por una versión
--      backwards-compatible: mismos primeros 2 params, agrega 5 opcionales
--      con DEFAULT NULL. Los callers viejos (que pasan solo (uuid, text))
--      siguen funcionando sin cambios.
--
-- COMPATIBILIDAD:
--   Aditivo + reemplazo backward-compatible. Apps con la versión vieja del
--   agent siguen llamando `fn_device_agent_heartbeat(p_id, p_agent_url)` y
--   funciona. Apps nuevas pueden reportar metadata adicional.
-- =============================================================================

begin;

-- ─────────────────────────────────────────────────────────────────────────────
-- 1. Nuevas columnas en device_agents
-- ─────────────────────────────────────────────────────────────────────────────

alter table public.device_agents
  add column if not exists agent_version text;

alter table public.device_agents
  add column if not exists os text;

alter table public.device_agents
  add column if not exists hostname text;

alter table public.device_agents
  add column if not exists available_transports text[] not null default '{}';

alter table public.device_agents
  add column if not exists metadata jsonb not null default '{}'::jsonb;

comment on column public.device_agents.agent_version is
  'Versión del binario del agent local (ej. "v2.0.1"). NULL hasta que reporte.';

comment on column public.device_agents.os is
  'Sistema operativo del device. Valores típicos: Darwin, Linux, Windows, Android, iOS.';

comment on column public.device_agents.hostname is
  'Hostname legible para dashboards (ej. "MacBook-Caja-1"). Distinto de device_name (que es manual del admin).';

comment on column public.device_agents.available_transports is
  'Array de transports que este agent puede ejecutar. Ej: {lan,usb,bluetooth}. Determina qué jobs puede tomar el agent.';

comment on column public.device_agents.metadata is
  'JSON libre: detalles del runtime, drivers detectados, configuración local. Útil para debugging remoto.';

-- ─────────────────────────────────────────────────────────────────────────────
-- 2. Reemplazar fn_device_agent_heartbeat (backwards-compatible)
-- ─────────────────────────────────────────────────────────────────────────────
--
-- La firma vieja era (uuid, text). La nueva agrega 5 params opcionales con
-- DEFAULT NULL — los callers que solo pasan los primeros 2 siguen funcionando.
-- DROP explícito de la vieja por id (uuid, text) para evitar conflictos de
-- overload ambiguo.

drop function if exists public.fn_device_agent_heartbeat(uuid, text);

create or replace function public.fn_device_agent_heartbeat(
  p_id uuid,
  p_agent_url text default null,
  p_agent_version text default null,
  p_os text default null,
  p_hostname text default null,
  p_available_transports text[] default null,
  p_metadata jsonb default null
) returns void
language plpgsql
security definer
set search_path = public
as $$
begin
  update public.device_agents
  set online = true,
      last_heartbeat_at = now(),
      agent_url = coalesce(p_agent_url, agent_url),
      agent_version = coalesce(p_agent_version, agent_version),
      os = coalesce(p_os, os),
      hostname = coalesce(p_hostname, hostname),
      available_transports = case
        when p_available_transports is null then available_transports
        else p_available_transports
      end,
      metadata = case
        when p_metadata is null then metadata
        else p_metadata
      end,
      updated_at = now()
  where id = p_id;
end;
$$;

grant execute on function public.fn_device_agent_heartbeat(uuid, text, text, text, text, text[], jsonb)
  to anon, authenticated, service_role;

comment on function public.fn_device_agent_heartbeat(uuid, text, text, text, text, text[], jsonb) is
  'Heartbeat idempotente del agent local. v2: agrega 5 params opcionales (agent_version, os, hostname, available_transports, metadata). Callers viejos que solo pasan (id, agent_url) siguen funcionando sin cambios.';

-- ─────────────────────────────────────────────────────────────────────────────
-- 3. Índice para dashboards de salud (por business + último heartbeat)
-- ─────────────────────────────────────────────────────────────────────────────

create index if not exists idx_device_agents_business_hb_desc
  on public.device_agents (business_id, last_heartbeat_at desc);

commit;
