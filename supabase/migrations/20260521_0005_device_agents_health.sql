-- =============================================================================
-- Fase 1 — Printing v2: tabla device_agents_health (heartbeat por device).
--
-- CONTEXTO:
--   `printers.last_heartbeat_at` (migración 20260501_0001) trackea la salud
--   de cada IMPRESORA. Esta tabla tracking la salud de cada AGENT — un
--   proceso local en cada PC/tablet que ejecuta print_jobs.
--
--   Un agent puede manejar varias impresoras (típicamente todas las del
--   negocio para LAN, o solo las USB/BT pareadas a su device). Saber qué
--   agents están vivos permite:
--     - Decidir a cuál encolar print_jobs sin target específico (LAN).
--     - Alertar al admin cuando un agent que tiene impresoras vinculadas
--       lleva minutos sin reportar.
--     - Dashboard de "salud del sistema".
--
--   El heartbeat se envía cada 30s desde el agent. La tabla se hace UPSERT
--   por device_id, no se conserva historial — para histórico hay logs.
--
-- COMPATIBILIDAD:
--   Tabla nueva, opcional. Si no hay agents reportando, el comportamiento
--   actual sigue funcionando (print directo desde la app sin pasar por agent).
-- =============================================================================

begin;

-- ─────────────────────────────────────────────────────────────────────────────
-- 1. Tabla
-- ─────────────────────────────────────────────────────────────────────────────

create table if not exists public.device_agents_health (
  device_id text primary key,
  business_id uuid references public.businesses(id) on delete cascade,
  last_heartbeat timestamptz not null default now(),
  agent_version text,
  os text,
  hostname text,
  available_transports text[] not null default '{}',
  metadata jsonb not null default '{}'::jsonb,
  created_at timestamptz not null default now()
);

create index if not exists idx_device_agents_health_business_hb
  on public.device_agents_health (business_id, last_heartbeat desc);

comment on table public.device_agents_health is
  'Heartbeat por agent local. Cada device con agent corriendo hace UPSERT cada ~30s. Se usa para decidir routing y mostrar dashboard de salud.';

comment on column public.device_agents_health.available_transports is
  'Array de transports que este agent puede ejecutar. Ej: {lan,usb,bluetooth}. Determina qué jobs puede tomar.';

comment on column public.device_agents_health.metadata is
  'JSON libre: detalles del runtime, drivers detectados, configuración local. Útil para debugging remoto.';

-- ─────────────────────────────────────────────────────────────────────────────
-- 2. RPC: heartbeat (UPSERT idempotente, llamado desde el agent)
-- ─────────────────────────────────────────────────────────────────────────────

create or replace function public.fn_device_agent_heartbeat(
  p_device_id text,
  p_business_id uuid,
  p_agent_version text default null,
  p_os text default null,
  p_hostname text default null,
  p_available_transports text[] default '{}',
  p_metadata jsonb default '{}'::jsonb
) returns void
language plpgsql
security definer
set search_path = public
as $$
begin
  insert into public.device_agents_health (
    device_id, business_id, last_heartbeat,
    agent_version, os, hostname, available_transports, metadata
  ) values (
    p_device_id, p_business_id, now(),
    p_agent_version, p_os, p_hostname, p_available_transports, p_metadata
  )
  on conflict (device_id) do update set
    business_id = excluded.business_id,
    last_heartbeat = now(),
    agent_version = coalesce(excluded.agent_version, public.device_agents_health.agent_version),
    os = coalesce(excluded.os, public.device_agents_health.os),
    hostname = coalesce(excluded.hostname, public.device_agents_health.hostname),
    available_transports = excluded.available_transports,
    metadata = excluded.metadata;
end;
$$;

grant execute on function public.fn_device_agent_heartbeat(text, uuid, text, text, text, text[], jsonb)
  to authenticated;

comment on function public.fn_device_agent_heartbeat is
  'Llamado por el agent local cada ~30s. UPSERT idempotente. Mantiene null campos no provistos para no sobrescribir info previa.';

-- ─────────────────────────────────────────────────────────────────────────────
-- 3. RLS
-- ─────────────────────────────────────────────────────────────────────────────

alter table public.device_agents_health enable row level security;

drop policy if exists "device_agents_health_select" on public.device_agents_health;
create policy "device_agents_health_select"
  on public.device_agents_health
  for select
  using (
    business_id in (
      select m.business_id from public.memberships m where m.user_id = auth.uid()
    )
  );

-- INSERT/UPDATE va por la RPC (security definer), no por escritura directa.
-- DELETE solo admin/owner.
drop policy if exists "device_agents_health_delete" on public.device_agents_health;
create policy "device_agents_health_delete"
  on public.device_agents_health
  for delete
  using (
    business_id in (
      select m.business_id
      from public.memberships m
      where m.user_id = auth.uid() and m.role in ('owner','admin')
    )
  );

commit;
