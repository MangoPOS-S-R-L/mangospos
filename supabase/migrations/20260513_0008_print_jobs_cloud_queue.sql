-- =============================================================================
-- Sprint 1 del refactor de impresión (Square+): cola persistente en Supabase.
--
-- HOY:
--   La cola real vive en SQLite del agent Node.js (lib/queue/store.js).
--   `print_jobs` en Supabase es solo observabilidad (status redundante).
--   Si el agent se reinicia (corte de luz, update, crash), los jobs en
--   estado pending/printing se pierden — las tablets que enviaron jobs
--   recientes quedan sin imprimir.
--
-- POST-SPRINT 1:
--   `print_jobs` en Supabase es la fuente de verdad. El agent toma jobs
--   con `fn_claim_next_print_job` (atomic, FOR UPDATE SKIP LOCKED), los
--   imprime, reporta con `fn_complete_print_job`. Si el agent reinicia,
--   los jobs en `printing` con claim viejo se reclamen automáticamente.
--
-- CAMBIOS:
--   1. ALTER print_jobs: idempotency_key, retry_count, last_error,
--      next_retry_at, claimed_by, claimed_at, area_code, printer_id,
--      priority, kind.
--   2. fn_claim_next_print_job(p_agent_id, p_max_age_seconds): atomic
--      pick siguiente job que este agent puede procesar (network = any
--      agent, USB/BT = solo el agent host).
--   3. fn_complete_print_job(p_job_id, p_success, p_error): marca
--      printed o calcula backoff exponencial para retry.
--   4. fn_reclaim_stale_print_jobs(): reset a pending de jobs en
--      printing con claim > 60s (agent crasheó después de claim).
--
-- BACKWARDS-COMPATIBLE:
--   Todas las columnas nuevas son nullable o con default. Códigos que
--   leen print_jobs hoy siguen funcionando. El agent legacy SQLite sigue
--   activo durante la transición — se migra en Sprint 1.5 (Dart+agent).
-- =============================================================================

begin;

-- ---------------------------------------------------------------------------
-- 1. Nuevos campos en print_jobs
-- ---------------------------------------------------------------------------

alter table public.print_jobs
  add column if not exists idempotency_key text;

alter table public.print_jobs
  add column if not exists retry_count smallint default 0 not null;

alter table public.print_jobs
  add column if not exists last_error text;

alter table public.print_jobs
  add column if not exists next_retry_at timestamptz;

alter table public.print_jobs
  add column if not exists claimed_by uuid;

alter table public.print_jobs
  add column if not exists claimed_at timestamptz;

alter table public.print_jobs
  add column if not exists area_code text;

alter table public.print_jobs
  add column if not exists printer_id uuid references public.printers(id)
  on delete set null;

alter table public.print_jobs
  add column if not exists priority smallint default 100 not null;

alter table public.print_jobs
  add column if not exists kind text;

-- FK opcional: claimed_by → device_agents.id (no enforced para permitir
-- agentes que se eliminaron; el claim se libera por timeout).
do $$
begin
  if not exists (
    select 1 from pg_constraint
    where conname = 'print_jobs_claimed_by_fkey'
      and conrelid = 'public.print_jobs'::regclass
  ) then
    alter table public.print_jobs
      add constraint print_jobs_claimed_by_fkey
      foreign key (claimed_by) references public.device_agents(id)
      on delete set null;
  end if;
end$$;

comment on column public.print_jobs.idempotency_key is
  'Key para evitar duplicados al re-enviar mismo job (ej. retry del cliente '
  'tras timeout de red). Cliente la genera: order_id + ticket_type + check_id. '
  'UNIQUE por business — si llega un duplicado, retorna el job existente.';

comment on column public.print_jobs.retry_count is
  'Cuántas veces intentamos imprimir este job sin éxito. >= 5 → terminal.';

comment on column public.print_jobs.next_retry_at is
  'Próximo momento elegible para reintento. Backoff exponencial: '
  '5s, 10s, 20s, 40s, 80s.';

comment on column public.print_jobs.claimed_by is
  'Agent que tomó este job (NULL si pending). Usado por fn_claim para '
  'evitar que 2 agents tomen el mismo job. Se libera al completar o '
  'tras timeout (fn_reclaim_stale_print_jobs).';

comment on column public.print_jobs.printer_id is
  'Impresora destino. Si NULL, el agent decide en runtime según area_code '
  '+ asignaciones de print_area_printers. Si NOT NULL, se respeta esa.';

comment on column public.print_jobs.area_code is
  'Código de área destino (kitchen, kitchen_hot, bar, cashier, fiscal). '
  'Usado para routing cuando printer_id es NULL.';

comment on column public.print_jobs.kind is
  'Tipo de ticket: kitchen_order, invoice, precheck, cash_close, other. '
  'Útil para métricas y filtros.';

-- ---------------------------------------------------------------------------
-- 2. Indices para queries de claim y observabilidad
-- ---------------------------------------------------------------------------

-- Index parcial para el claim: solo jobs procesables (pending + status
-- failed con retry_count < 5 y next_retry_at venció).
create index if not exists idx_print_jobs_claimable
  on public.print_jobs (business_id, priority, created_at)
  where status in ('pending', 'failed')
    and retry_count < 5;

-- Idempotency UNIQUE por business. Solo aplica a jobs activos para
-- permitir re-emitir si el job anterior fue cancelado.
create unique index if not exists idx_print_jobs_idempotency
  on public.print_jobs (business_id, idempotency_key)
  where idempotency_key is not null
    and status <> 'cancelled';

create index if not exists idx_print_jobs_claimed
  on public.print_jobs (claimed_by, claimed_at)
  where claimed_by is not null;

create index if not exists idx_print_jobs_printer
  on public.print_jobs (printer_id, created_at desc)
  where printer_id is not null;

-- ---------------------------------------------------------------------------
-- 3. fn_claim_next_print_job: atomic pick del siguiente job
--
-- El agente llama esta función en su loop principal cada 500ms (o
-- subscribe a Realtime de print_jobs cuando lleguemos a WebSocket).
--
-- Lógica de elegibilidad:
--   - status='pending' (job nuevo) o
--   - status='failed' AND retry_count<5 AND next_retry_at < now()
--   Y:
--   - claimed_by IS NULL (nadie lo tiene)
--   Y:
--   - Si printer_id apunta a impresora con host_device_id, solo ese
--     agent la puede tomar (USB/BT son locales al device).
--   - Si printer_id apunta a network printer o es NULL, cualquier agent.
--
-- FOR UPDATE SKIP LOCKED garantiza que dos agents que llaman simultáneo
-- toman jobs distintos.
-- ---------------------------------------------------------------------------

create or replace function public.fn_claim_next_print_job(
  p_agent_id uuid,
  p_business_id uuid default null
)
returns public.print_jobs
language plpgsql
security definer
set search_path = public
as $$
declare
  v_job public.print_jobs;
  v_business_id uuid;
begin
  if p_agent_id is null then
    raise exception 'AGENT_ID_REQUIRED';
  end if;

  -- Si no recibimos business_id, lo derivamos del agent. Permite que el
  -- caller pase el filtro explícitamente para multi-tenant futuro.
  if p_business_id is null then
    select business_id into v_business_id
    from public.device_agents
    where id = p_agent_id;
    if v_business_id is null then
      raise exception 'AGENT_NOT_FOUND: %', p_agent_id;
    end if;
  else
    v_business_id := p_business_id;
  end if;

  -- Atomic select + update. SKIP LOCKED evita que dos agents concurrentes
  -- tomen el mismo job.
  select pj.*
    into v_job
  from public.print_jobs pj
  left join public.printers pr on pr.id = pj.printer_id
  where pj.business_id = v_business_id
    and pj.retry_count < 5
    and (
      pj.status = 'pending'
      or (
        pj.status = 'failed'
        and (pj.next_retry_at is null or pj.next_retry_at <= now())
      )
    )
    and pj.claimed_by is null
    and (
      -- Impresora network o no asignada todavía: cualquier agent puede.
      pr.id is null
      or pr.type = 'network'
      -- USB/Bluetooth: solo el agent que la tiene físicamente conectada.
      or coalesce(pr.host_device_id, p_agent_id) = p_agent_id
    )
  order by pj.priority asc, pj.created_at asc
  limit 1
  for update of pj skip locked;

  if v_job.id is null then
    return null;
  end if;

  -- Marcar como claimed por este agent.
  update public.print_jobs
  set status = 'printing',
      claimed_by = p_agent_id,
      claimed_at = now()
  where id = v_job.id
  returning * into v_job;

  return v_job;
end;
$$;

grant execute on function public.fn_claim_next_print_job(uuid, uuid)
  to authenticated, service_role;

comment on function public.fn_claim_next_print_job(uuid, uuid) is
  'Atomic claim del siguiente print job procesable por p_agent_id. '
  'Respeta routing (USB/BT solo el agent host, network cualquiera). '
  'Marca status=printing+claimed_by para evitar carrera con otros agents.';

-- ---------------------------------------------------------------------------
-- 4. fn_complete_print_job: ACK del agent al terminar
-- ---------------------------------------------------------------------------

create or replace function public.fn_complete_print_job(
  p_job_id uuid,
  p_success boolean,
  p_error text default null
)
returns public.print_jobs
language plpgsql
security definer
set search_path = public
as $$
declare
  v_job public.print_jobs;
  v_new_retry_count smallint;
  v_backoff_seconds integer;
begin
  if p_job_id is null then
    raise exception 'JOB_ID_REQUIRED';
  end if;

  select * into v_job
  from public.print_jobs
  where id = p_job_id
  for update;

  if v_job.id is null then
    raise exception 'JOB_NOT_FOUND: %', p_job_id;
  end if;

  if p_success then
    update public.print_jobs
    set status = 'printed',
        printed_at = now(),
        last_error = null,
        claimed_by = null,
        claimed_at = null
    where id = p_job_id
    returning * into v_job;
  else
    v_new_retry_count := v_job.retry_count + 1;

    if v_new_retry_count >= 5 then
      -- Terminal: descartamos. Cajero debe reintentar manualmente desde
      -- la UI o re-imprimir desde historial.
      update public.print_jobs
      set status = 'failed',
          retry_count = v_new_retry_count,
          last_error = coalesce(p_error, 'Falló tras 5 intentos'),
          error = coalesce(p_error, 'Falló tras 5 intentos'),
          claimed_by = null,
          claimed_at = null,
          next_retry_at = null
      where id = p_job_id
      returning * into v_job;
    else
      -- Backoff exponencial: 5s, 10s, 20s, 40s, 80s.
      v_backoff_seconds := 5 * power(2, v_new_retry_count)::integer;
      update public.print_jobs
      set status = 'failed',
          retry_count = v_new_retry_count,
          last_error = p_error,
          error = p_error,
          claimed_by = null,
          claimed_at = null,
          next_retry_at = now() + (v_backoff_seconds || ' seconds')::interval
      where id = p_job_id
      returning * into v_job;
    end if;
  end if;

  return v_job;
end;
$$;

grant execute on function public.fn_complete_print_job(uuid, boolean, text)
  to authenticated, service_role;

comment on function public.fn_complete_print_job(uuid, boolean, text) is
  'ACK del agent al terminar (o fallar) un print job. Si success: '
  'status=printed. Si failure: incrementa retry_count, calcula next_retry_at '
  '(backoff exp 5s/10s/20s/40s/80s), libera claim. Tras 5 fallos queda '
  'terminal (status=failed sin retry).';

-- ---------------------------------------------------------------------------
-- 5. fn_reclaim_stale_print_jobs: recupera jobs huérfanos
--
-- Si un agent claim un job y crashea antes de ACK, el job queda en
-- printing con claim viejo. Esta función los reseta a pending para que
-- otro agent (o el mismo tras restart) los reintente.
--
-- Se llama desde el agent en su loop principal cada 60s. También puede
-- correrse manualmente desde admin si hay duda.
-- ---------------------------------------------------------------------------

create or replace function public.fn_reclaim_stale_print_jobs(
  p_max_age_seconds integer default 60
)
returns integer
language plpgsql
security definer
set search_path = public
as $$
declare
  v_count integer;
begin
  with reclaimed as (
    update public.print_jobs
    set status = 'pending',
        claimed_by = null,
        claimed_at = null,
        last_error = coalesce(last_error, '') ||
          format(' [reclaimed: claim > %ss]', p_max_age_seconds)
    where status = 'printing'
      and claimed_at is not null
      and claimed_at < now() - (p_max_age_seconds || ' seconds')::interval
    returning id
  )
  select count(*) into v_count from reclaimed;

  return v_count;
end;
$$;

grant execute on function public.fn_reclaim_stale_print_jobs(integer)
  to authenticated, service_role;

comment on function public.fn_reclaim_stale_print_jobs(integer) is
  'Recupera jobs huérfanos: agent crasheó después de claim sin ACK. '
  'Reset a pending para que se re-intente. Llamar desde agent loop cada 60s.';

-- ---------------------------------------------------------------------------
-- 6. Backfill: para jobs viejos sin idempotency_key (no chocan con el
--    UNIQUE porque el index es partial WHERE idempotency_key IS NOT NULL).
--    No los tocamos — quedan en limbo histórico. Si alguno tiene
--    status='pending' y >24h sin claim, lo marcamos cancelled para que
--    el agente no los procese al rollout.
-- ---------------------------------------------------------------------------

update public.print_jobs
set status = 'cancelled',
    last_error = 'Auto-cancelled at queue refactor 20260513_0008: job > 24h sin procesar'
where status = 'pending'
  and idempotency_key is null
  and created_at < now() - interval '24 hours';

commit;
