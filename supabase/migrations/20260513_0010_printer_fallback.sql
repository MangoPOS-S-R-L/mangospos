-- =============================================================================
-- Sprint 3 del refactor de impresión (Square+): failover automático por
-- impresora.
--
-- PROBLEMA HOY:
--   Una impresora cae (papel atascado, sin red, sin tinta) y los tickets
--   de cocina/cajero se quedan en cola intentando 5 veces con backoff
--   exponencial (~155s). En un Friday-night rush eso significa cocina
--   ciega 2.5 minutos antes de que el cajero se entere.
--
-- SOLUCIÓN:
--   Cada impresora puede declarar una `fallback_printer_id`. Al PRIMER
--   fallo (decisión del usuario en Sprint 3, no esperamos retries), el
--   job se re-encola apuntando a la secundaria sin backoff, eligible
--   inmediatamente. Si la secundaria también falla, sigue el flujo
--   existente de retries/backoff sin failover adicional (Solo 1 nivel
--   por decisión del usuario).
--
-- BACKWARDS-COMPATIBLE:
--   - Las columnas nuevas son NULLABLE / con default 0.
--   - Impresoras sin fallback configurado siguen comportándose igual
--     que antes (5 retries con backoff).
--   - `fn_complete_print_job` mantiene su signature; solo añade la rama
--     "si hay fallback y es la 1ª falla, redirige".
--
-- =============================================================================

begin;

-- ---------------------------------------------------------------------------
-- 1. printers.fallback_printer_id
--
-- Self-FK con ON DELETE SET NULL para que si la secundaria se elimina,
-- la primaria no quede colgada apuntando a un UUID inválido — solo
-- pierde su respaldo.
-- ---------------------------------------------------------------------------

alter table public.printers
  add column if not exists fallback_printer_id uuid
  references public.printers(id) on delete set null;

create index if not exists idx_printers_fallback
  on public.printers (fallback_printer_id)
  where fallback_printer_id is not null;

-- No auto-failover a sí misma. CHECK barato (sin lookup recursivo).
do $$
begin
  if not exists (
    select 1 from pg_constraint
    where conname = 'printers_no_self_fallback'
      and conrelid = 'public.printers'::regclass
  ) then
    alter table public.printers
      add constraint printers_no_self_fallback
      check (fallback_printer_id is null or fallback_printer_id <> id);
  end if;
end$$;

comment on column public.printers.fallback_printer_id is
  'Impresora de respaldo si esta falla. Al primer error del job, '
  'fn_complete_print_job redirige a la secundaria en vez de seguir '
  'reintentando en la primaria. Solo 1 nivel: si la secundaria también '
  'falla, sigue el flujo normal de retries (no hay terciaria).';

-- ---------------------------------------------------------------------------
-- 2. print_jobs: trackear failover ya consumido
--
-- failover_count: 0 = primer intento en la primaria. 1 = ya pasamos a
-- la secundaria. No hay 2.
-- original_printer_id: dejamos rastro de cuál fue la primera asignación,
-- útil para métricas ("cuántos jobs terminan en backup?") y para que el
-- cajero entienda en el historial por qué un ticket salió en otra
-- impresora.
-- ---------------------------------------------------------------------------

alter table public.print_jobs
  add column if not exists failover_count smallint default 0 not null;

alter table public.print_jobs
  add column if not exists original_printer_id uuid
  references public.printers(id) on delete set null;

comment on column public.print_jobs.failover_count is
  'Cuántas veces este job rotó a la impresora de respaldo. Solo 1 nivel: '
  'puede valer 0 (sin failover) o 1 (ya en backup). Si la backup falla, '
  'NO se hace nuevo failover — entra a retries normales.';

comment on column public.print_jobs.original_printer_id is
  'Impresora a la que se encoló originalmente. Si failover_count > 0, '
  'printer_id != original_printer_id. Útil para auditoría / métricas.';

-- ---------------------------------------------------------------------------
-- 3. fn_complete_print_job: lógica de failover
--
-- Política (decidida con el usuario en Sprint 3):
--   - Failover INMEDIATO (al 1er fallo, no espera retries).
--   - Solo 1 nivel (si backup también falla, NO va a una tercera).
--
-- Flujo:
--   p_success = true → printed (sin cambios).
--   p_success = false:
--     a) Si retry_count = 0 AND failover_count = 0 AND
--        printers.fallback_printer_id IS NOT NULL:
--        → redirigir job a la secundaria, reset retry_count=0,
--          status='pending', claim libre, sin backoff (eligible YA).
--          Incrementar failover_count=1, guardar original_printer_id.
--     b) Else: flujo legacy (incrementar retry_count, calcular backoff,
--        status='failed' o terminal a los 5).
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
  v_fallback_id uuid;
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
    return v_job;
  end if;

  -- Sprint 3 — intento de failover inmediato.
  -- Solo si es el primer fallo del job (retry_count = 0) y aún no se ha
  -- hecho failover (failover_count = 0) y la impresora primaria declara
  -- una secundaria.
  if v_job.retry_count = 0
     and v_job.failover_count = 0
     and v_job.printer_id is not null then
    select p.fallback_printer_id
      into v_fallback_id
    from public.printers p
    where p.id = v_job.printer_id;

    if v_fallback_id is not null then
      update public.print_jobs
      set printer_id = v_fallback_id,
          original_printer_id = coalesce(v_job.original_printer_id, v_job.printer_id),
          failover_count = 1,
          status = 'pending',
          retry_count = 0,
          claimed_by = null,
          claimed_at = null,
          last_error = format(
            'Primary printer falló: %s. Failover a backup.',
            coalesce(p_error, 'sin detalle')
          ),
          error = null,
          next_retry_at = null
      where id = p_job_id
      returning * into v_job;
      return v_job;
    end if;
  end if;

  -- Flujo legacy: backoff exponencial.
  v_new_retry_count := v_job.retry_count + 1;

  if v_new_retry_count >= 5 then
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

  return v_job;
end;
$$;

grant execute on function public.fn_complete_print_job(uuid, boolean, text)
  to authenticated, service_role;

comment on function public.fn_complete_print_job(uuid, boolean, text) is
  'ACK del agent al terminar un print job. Sprint 3: si el primer fallo '
  'ocurre en una impresora con fallback_printer_id configurado, redirige '
  'inmediatamente al backup (sin backoff, status=pending). Si no hay '
  'backup o ya se usó, aplica retry exponencial (5/10/20/40/80s, máx 5 '
  'intentos). Solo 1 nivel de failover: si el backup también falla, '
  'entra a retries normales (no hay terciaria).';

-- ---------------------------------------------------------------------------
-- 4. Sanity check anti-circular en INSERT/UPDATE
--
-- Aunque limitamos a 1 nivel a nivel de RPC, queremos prevenir que el
-- usuario configure A↔B (mutuo). Un job en A falla → va a B → si B
-- falla pero ya failover_count=1 no vuelve a A; PERO si por error
-- otra ruta resetea failover_count, podría volver a A.
--
-- Trigger ligero: si fallback_printer_id apunta a una impresora cuya
-- fallback_printer_id apunta de vuelta a self, lanzar excepción.
-- (NO bloquea cadenas A→B→C porque solo verifica 1 nivel de profundidad.)
-- ---------------------------------------------------------------------------

create or replace function public.fn_validate_printer_fallback()
returns trigger
language plpgsql
as $$
declare
  v_back_pointer uuid;
begin
  if new.fallback_printer_id is null then
    return new;
  end if;

  if new.fallback_printer_id = new.id then
    raise exception 'INVALID_FALLBACK: una impresora no puede ser su propio respaldo.';
  end if;

  -- Verificar que la fallback existe en el mismo business_id.
  if not exists (
    select 1 from public.printers p
    where p.id = new.fallback_printer_id
      and p.business_id = new.business_id
  ) then
    raise exception
      'INVALID_FALLBACK: la impresora de respaldo no pertenece al mismo negocio.';
  end if;

  -- Detectar ciclo mutuo A↔B.
  select fallback_printer_id into v_back_pointer
  from public.printers
  where id = new.fallback_printer_id;
  if v_back_pointer = new.id then
    raise exception
      'INVALID_FALLBACK: ciclo detectado (A→B y B→A). Elige otra impresora.';
  end if;

  return new;
end;
$$;

drop trigger if exists trg_validate_printer_fallback on public.printers;
create trigger trg_validate_printer_fallback
  before insert or update of fallback_printer_id on public.printers
  for each row
  execute function public.fn_validate_printer_fallback();

comment on function public.fn_validate_printer_fallback() is
  'Valida antes de INSERT/UPDATE que la impresora de respaldo: '
  '(1) no sea sí misma; (2) pertenezca al mismo business; '
  '(3) no forme ciclo A↔B. Permite cadenas A→B→C (no las usamos pero '
  'no las bloqueamos en BD).';

commit;
