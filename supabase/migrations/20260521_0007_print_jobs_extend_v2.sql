-- =============================================================================
-- Fase 1 — Printing v2: extender `print_jobs` con routing + retries + dedup.
--
-- CONTEXTO:
--   La tabla `print_jobs` hoy tiene: id, business_id, data_hex, ip, port,
--   status, error, created_at, printed_at. Funciona para LAN simple
--   (encolar → agent toma → imprime), pero no soporta:
--     - Vincular el job a una `printer_id` concreta (hoy se identifica solo
--       por ip+port, lo cual rompe cuando una impresora cambia de IP).
--     - Rutear a un device específico (necesario para USB/BT).
--     - Reintentos automáticos con backoff (hoy un fallo = fin).
--     - Dedupe (si el cliente reintenta encolar, se duplica).
--     - Multi-transport (hoy implícito LAN).
--
--   Esta migración agrega todas esas columnas como opcionales. Código viejo
--   que usa ip+port y status simple sigue funcionando — las columnas nuevas
--   se ignoran. Código nuevo del orchestrator usa printer_id+transport+retry.
--
-- ESTADOS de status:
--   - pending      — recién encolado, espera a ser tomado
--   - in_progress  — agent lo está procesando
--   - printed      — impresión exitosa
--   - failed       — falló pero será reintentado (attempts < max_attempts)
--   - dead         — falló definitivamente (attempts >= max_attempts)
--   - retry        — explícitamente reencolado para reintento
--
-- COMPATIBILIDAD:
--   Aditivo puro. `ip` y `port` se mantienen NOT NULL (compat con código
--   viejo que los espera). El orchestrator nuevo los llena de la
--   connection_config de la impresora al encolar.
-- =============================================================================

begin;

-- ─────────────────────────────────────────────────────────────────────────────
-- 1. Nuevas columnas
-- ─────────────────────────────────────────────────────────────────────────────

alter table public.print_jobs
  add column if not exists printer_id uuid references public.printers(id) on delete set null;

alter table public.print_jobs
  add column if not exists target_device_id text;

alter table public.print_jobs
  add column if not exists transport text;

alter table public.print_jobs
  add column if not exists attempts int not null default 0;

alter table public.print_jobs
  add column if not exists max_attempts int not null default 5;

alter table public.print_jobs
  add column if not exists next_attempt_at timestamptz;

alter table public.print_jobs
  add column if not exists error_log jsonb not null default '[]'::jsonb;

alter table public.print_jobs
  add column if not exists idempotency_key uuid;

alter table public.print_jobs
  add column if not exists updated_at timestamptz not null default now();

-- ─────────────────────────────────────────────────────────────────────────────
-- 2. CHECKs
-- ─────────────────────────────────────────────────────────────────────────────

alter table public.print_jobs
  drop constraint if exists print_jobs_status_check_v2;
alter table public.print_jobs
  add constraint print_jobs_status_check_v2
  check (status in ('pending','in_progress','printed','failed','dead','retry'));

alter table public.print_jobs
  drop constraint if exists print_jobs_attempts_check;
alter table public.print_jobs
  add constraint print_jobs_attempts_check
  check (attempts >= 0 and max_attempts > 0 and attempts <= max_attempts + 1);

alter table public.print_jobs
  drop constraint if exists print_jobs_transport_check;
alter table public.print_jobs
  add constraint print_jobs_transport_check
  check (transport is null or transport in ('lan','usb','bluetooth','serial','cups'));

-- ─────────────────────────────────────────────────────────────────────────────
-- 3. Índices
-- ─────────────────────────────────────────────────────────────────────────────

-- Agent local: traer jobs pendientes que le toca procesar a este device
create index if not exists idx_print_jobs_pending_for_device
  on public.print_jobs (target_device_id, status, next_attempt_at)
  where status in ('pending','retry');

-- Agent local: traer jobs LAN sin target específico (cualquier device toma)
create index if not exists idx_print_jobs_pending_lan_unassigned
  on public.print_jobs (status, next_attempt_at, created_at)
  where target_device_id is null and status in ('pending','retry');

-- Dedupe por idempotency_key (UNIQUE parcial — solo si está set)
create unique index if not exists uq_print_jobs_idempotency
  on public.print_jobs (idempotency_key)
  where idempotency_key is not null;

-- Búsqueda por printer_id (dashboard, history)
create index if not exists idx_print_jobs_printer_created
  on public.print_jobs (printer_id, created_at desc);

-- ─────────────────────────────────────────────────────────────────────────────
-- 4. Trigger: mantener updated_at
-- ─────────────────────────────────────────────────────────────────────────────

create or replace function public.fn_print_jobs_touch_updated_at()
returns trigger
language plpgsql
as $$
begin
  new.updated_at := now();
  return new;
end;
$$;

drop trigger if exists trg_print_jobs_touch_updated_at on public.print_jobs;
create trigger trg_print_jobs_touch_updated_at
  before update on public.print_jobs
  for each row
  execute function public.fn_print_jobs_touch_updated_at();

-- ─────────────────────────────────────────────────────────────────────────────
-- 5. RPCs para el agent
-- ─────────────────────────────────────────────────────────────────────────────

-- Marcar un job como "in_progress" — claim atómico para evitar que dos
-- agents tomen el mismo job. Retorna true si se logró el claim.
create or replace function public.fn_claim_print_job(
  p_job_id uuid,
  p_device_id text
) returns boolean
language plpgsql
security definer
set search_path = public
as $$
declare
  v_updated int;
begin
  update public.print_jobs
  set status = 'in_progress',
      attempts = attempts + 1
  where id = p_job_id
    and status in ('pending','retry');

  get diagnostics v_updated = row_count;
  return v_updated > 0;
end;
$$;

-- Marcar como impreso exitosamente
create or replace function public.fn_mark_print_job_printed(
  p_job_id uuid
) returns void
language plpgsql
security definer
set search_path = public
as $$
begin
  update public.print_jobs
  set status = 'printed',
      printed_at = now(),
      error = null
  where id = p_job_id;
end;
$$;

-- Marcar como fallido — programa retry con backoff exponencial,
-- o lo marca dead si superó max_attempts.
create or replace function public.fn_mark_print_job_failed(
  p_job_id uuid,
  p_error text,
  p_transport text default null
) returns text  -- retorna el nuevo status: 'retry' o 'dead'
language plpgsql
security definer
set search_path = public
as $$
declare
  v_attempts int;
  v_max int;
  v_new_status text;
  v_backoff_seconds int;
begin
  select attempts, max_attempts into v_attempts, v_max
  from public.print_jobs
  where id = p_job_id;

  if v_attempts >= v_max then
    v_new_status := 'dead';
    v_backoff_seconds := 0;
  else
    v_new_status := 'retry';
    -- Backoff exponencial: 1s, 2s, 4s, 8s, 16s (cap a 5min)
    v_backoff_seconds := least(power(2, v_attempts)::int, 300);
  end if;

  update public.print_jobs
  set status = v_new_status,
      error = p_error,
      next_attempt_at = case when v_new_status = 'retry' then now() + (v_backoff_seconds || ' seconds')::interval else null end,
      error_log = error_log || jsonb_build_array(jsonb_build_object(
        'at', now(),
        'attempt', v_attempts,
        'transport', p_transport,
        'message', p_error
      ))
  where id = p_job_id;

  return v_new_status;
end;
$$;

grant execute on function public.fn_claim_print_job(uuid, text) to authenticated;
grant execute on function public.fn_mark_print_job_printed(uuid) to authenticated;
grant execute on function public.fn_mark_print_job_failed(uuid, text, text) to authenticated;

-- ─────────────────────────────────────────────────────────────────────────────
-- 6. Comentarios
-- ─────────────────────────────────────────────────────────────────────────────

comment on column public.print_jobs.printer_id is
  'FK a printers — el job va a esta impresora. NULL solo en jobs legacy sin migrar.';

comment on column public.print_jobs.target_device_id is
  'Si la impresora es USB/BT, este es el device_id que tiene el binding. Solo ese agent toma el job. NULL = cualquier agent LAN.';

comment on column public.print_jobs.transport is
  'Snapshot del transport al momento de encolar. Permite al agent saber qué adaptador usar sin re-leer printers.';

comment on column public.print_jobs.next_attempt_at is
  'Cuándo el agent debe reintentar. NULL = listo para tomar (en pending/retry sin delay).';

comment on column public.print_jobs.idempotency_key is
  'Clave única que el cliente provee. Evita duplicar jobs si el cliente reintenta encolar (network glitch). Index único parcial.';

comment on column public.print_jobs.error_log is
  'Array de errores acumulados: [{at, attempt, transport, message}]. Útil para debugging post-mortem.';

commit;
