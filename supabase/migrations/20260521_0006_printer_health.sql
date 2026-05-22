-- =============================================================================
-- Fase 1 — Printing v2: tabla printer_health (estado granular por impresora).
--
-- CONTEXTO:
--   `printers.online` (boolean) y `printers.last_seen` ya existen pero solo
--   distinguen "vive/no vive". El dashboard nivel Toast necesita estados
--   granulares: sin papel, tapa abierta, error específico, etc.
--
--   Se elige tabla separada (no más columnas en `printers`) porque:
--     1. Health se actualiza MUY frecuente (cada 60s desde el agent). Tabla
--        aparte evita reescribir filas grandes de `printers` cada vez —
--        menos WAL, menos churn de Realtime.
--     2. `printer_health` puede tener su propia política de Realtime (UI
--        suscrita) sin que el cambio dispare actualizaciones en toda la
--        config de impresora.
--     3. Histórico futuro: si se quiere serie temporal de status, agregar
--        otra tabla `printer_health_log` particionada por tiempo.
--
-- ESTADOS:
--   - online        — responde a probe, papel ok, todo bien.
--   - offline       — no responde al probe (timeout, EHOSTUNREACH, etc).
--   - low_paper     — bit 5 de status: poco papel restante.
--   - no_paper      — bit 6 de status: papel agotado.
--   - cover_open    — bit 2 de status: tapa abierta.
--   - error         — error específico no clasificado.
--   - unknown       — nunca se hizo probe / agent no soporta health probe.
--
-- COMPATIBILIDAD:
--   Aditivo. `printers.online` se mantiene como cache simple — apps viejas
--   que solo leen ese campo siguen funcionando. Apps nuevas leen
--   `printer_health.status` para granularidad.
-- =============================================================================

begin;

-- ─────────────────────────────────────────────────────────────────────────────
-- 1. Tabla
-- ─────────────────────────────────────────────────────────────────────────────

create table if not exists public.printer_health (
  printer_id uuid primary key references public.printers(id) on delete cascade,
  status text not null default 'unknown',
  last_checked_at timestamptz not null default now(),
  consecutive_failures int not null default 0,
  last_probed_by_device_id text,
  details jsonb not null default '{}'::jsonb,
  updated_at timestamptz not null default now()
);

create index if not exists idx_printer_health_status
  on public.printer_health (status)
  where status in ('offline','no_paper','cover_open','error');

comment on table public.printer_health is
  'Estado actual de cada impresora. Actualizado por el agent vía health probe (~60s). Separado de `printers` para evitar churn frecuente sobre la config.';

comment on column public.printer_health.last_probed_by_device_id is
  'Device del agent que hizo el último probe. Útil para diagnóstico cuando un device dice "offline" pero otro "online" — puede indicar problema de red local.';

comment on column public.printer_health.details is
  'JSON: {error_code, raw_status_byte, message, ...}. Específico por transport y modelo de impresora.';

-- ─────────────────────────────────────────────────────────────────────────────
-- 2. CHECK constraint
-- ─────────────────────────────────────────────────────────────────────────────

alter table public.printer_health
  drop constraint if exists printer_health_status_check;
alter table public.printer_health
  add constraint printer_health_status_check
  check (status in ('online','offline','low_paper','no_paper','cover_open','error','unknown'));

-- ─────────────────────────────────────────────────────────────────────────────
-- 3. Trigger: mantener `updated_at` y espejar `printers.online`
-- ─────────────────────────────────────────────────────────────────────────────

create or replace function public.fn_printer_health_sync()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  new.updated_at := now();

  -- Espejar a printers.online (boolean simple) para compat con código viejo.
  -- SECURITY DEFINER porque el caller (agent vía RPC) puede no tener UPDATE
  -- directo sobre printers, pero sí sobre printer_health.
  update public.printers
  set online = (new.status = 'online'),
      last_seen = case when new.status = 'online' then now() else last_seen end
  where id = new.printer_id;

  return new;
end;
$$;

drop trigger if exists trg_printer_health_sync on public.printer_health;
create trigger trg_printer_health_sync
  before insert or update on public.printer_health
  for each row
  execute function public.fn_printer_health_sync();

-- ─────────────────────────────────────────────────────────────────────────────
-- 4. RPC: reportar health (UPSERT idempotente desde el agent)
-- ─────────────────────────────────────────────────────────────────────────────

create or replace function public.fn_report_printer_health(
  p_printer_id uuid,
  p_status text,
  p_device_id text default null,
  p_details jsonb default '{}'::jsonb
) returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_prev_status text;
begin
  if p_status not in ('online','offline','low_paper','no_paper','cover_open','error','unknown') then
    raise exception 'INVALID_STATUS: %', p_status;
  end if;

  select status into v_prev_status
  from public.printer_health
  where printer_id = p_printer_id;

  insert into public.printer_health (
    printer_id, status, last_checked_at,
    consecutive_failures, last_probed_by_device_id, details
  ) values (
    p_printer_id, p_status, now(),
    case when p_status = 'online' then 0 else 1 end,
    p_device_id, p_details
  )
  on conflict (printer_id) do update set
    status = excluded.status,
    last_checked_at = now(),
    consecutive_failures = case
      when excluded.status = 'online' then 0
      else public.printer_health.consecutive_failures + 1
    end,
    last_probed_by_device_id = coalesce(excluded.last_probed_by_device_id, public.printer_health.last_probed_by_device_id),
    details = excluded.details;
end;
$$;

grant execute on function public.fn_report_printer_health(uuid, text, text, jsonb)
  to authenticated;

-- ─────────────────────────────────────────────────────────────────────────────
-- 5. RLS
-- ─────────────────────────────────────────────────────────────────────────────

alter table public.printer_health enable row level security;

drop policy if exists "printer_health_select" on public.printer_health;
create policy "printer_health_select"
  on public.printer_health
  for select
  using (
    exists (
      select 1
      from public.printers p
      join public.memberships m on m.business_id = p.business_id
      where p.id = printer_id
        and m.user_id = auth.uid()
    )
  );

-- INSERT/UPDATE va por RPC (security definer). DELETE no se permite — la
-- fila vive con la impresora y se borra por ON DELETE CASCADE.

commit;
