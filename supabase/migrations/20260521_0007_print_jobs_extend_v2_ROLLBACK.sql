-- Rollback de `20260521_0007_print_jobs_extend_v2.sql`.
--
-- Jobs en estados `retry` o `dead` (introducidos en v2) quedan inconsistentes
-- con el CHECK viejo. Antes del rollback, convertir esos a 'failed':
--   update public.print_jobs set status = 'failed' where status in ('retry','dead');

begin;

-- Convertir status nuevos a valores compat
update public.print_jobs set status = 'failed' where status in ('retry','dead');
update public.print_jobs set status = 'pending' where status = 'in_progress';

drop function if exists public.fn_claim_print_job(uuid, text);
drop function if exists public.fn_mark_print_job_printed(uuid);
drop function if exists public.fn_mark_print_job_failed(uuid, text, text);

drop trigger if exists trg_print_jobs_touch_updated_at on public.print_jobs;
drop function if exists public.fn_print_jobs_touch_updated_at();

drop index if exists public.idx_print_jobs_pending_for_device;
drop index if exists public.idx_print_jobs_pending_lan_unassigned;
drop index if exists public.uq_print_jobs_idempotency;
drop index if exists public.idx_print_jobs_printer_created;

alter table public.print_jobs
  drop constraint if exists print_jobs_status_check_v2;
alter table public.print_jobs
  drop constraint if exists print_jobs_attempts_check;
alter table public.print_jobs
  drop constraint if exists print_jobs_transport_check;

alter table public.print_jobs
  drop column if exists updated_at,
  drop column if exists idempotency_key,
  drop column if exists error_log,
  drop column if exists next_attempt_at,
  drop column if exists max_attempts,
  drop column if exists attempts,
  drop column if exists transport,
  drop column if exists target_device_id,
  drop column if exists printer_id;

commit;
