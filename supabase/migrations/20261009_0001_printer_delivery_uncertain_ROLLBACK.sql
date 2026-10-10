-- Manual rollback: restores the previous print retry/failover policy.
begin;

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
-- An agent that still calls it only logs a warning; the old reclaim requeues.
drop function if exists public.fn_renew_print_job_claims(uuid, uuid[]);
commit;
