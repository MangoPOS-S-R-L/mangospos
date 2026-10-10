#!/usr/bin/env bash
# Disposable local Postgres; no remote DB, print agent or printer involved.
set -euo pipefail
REPO=$(cd "$(dirname "$0")/../.." && pwd)
M=$REPO/supabase/migrations
PG=${PG_BIN:-/opt/homebrew/opt/postgresql@15/bin}
PORT=${PG_PORT:-55451}
WORK=${1:-$(mktemp -d)}
D=$WORK/pg_printer_delivery
mkdir -p "$D"
"$PG/initdb" -D "$D/data" -U postgres --auth=trust >/dev/null
"$PG/pg_ctl" -D "$D/data" -o "-p $PORT -c listen_addresses=127.0.0.1 -c unix_socket_directories=''" -l "$D/log" start -w >/dev/null
trap '"$PG/pg_ctl" -D "$D/data" stop -m fast >/dev/null 2>&1' EXIT
Q() { "$PG/psql" -h 127.0.0.1 -p "$PORT" -U postgres -X -q -v ON_ERROR_STOP=1 "$@"; }
Q <<'SQL'
create role authenticated; create role service_role;
create table public.printers(id uuid primary key, fallback_printer_id uuid, type text default 'network', host_device_id uuid);
create table public.device_agents(id uuid primary key, business_id uuid);
create table public.print_jobs(id uuid primary key default gen_random_uuid(), business_id uuid,
  printer_id uuid, original_printer_id uuid, status text default 'pending',
  retry_count smallint default 0, failover_count smallint default 0,
  next_retry_at timestamptz, last_error text, error text, claimed_by uuid,
  claimed_at timestamptz, printed_at timestamptz, priority integer default 10,
  created_at timestamptz default now());
create function public.test_assert(ok boolean, message text) returns void language plpgsql as $$
begin
  if not coalesce(ok,false) then raise exception 'FAIL: %',message; end if;
  raise notice 'ok: %',message;
end $$;
SQL

# Load the actual repository claim function, without duplicating its source.
python3 - "$M/20260513_0008_print_jobs_cloud_queue.sql" "$D/claim.sql" <<'PY'
from pathlib import Path
import sys
s = Path(sys.argv[1]).read_text()
a = s.index('create or replace function public.fn_claim_next_print_job(')
b = s.index('$$;', a) + 3
Path(sys.argv[2]).write_text(s[a:b])
PY
Q -f "$D/claim.sql"
Q -f "$M/20261009_0001_printer_delivery_uncertain.sql"
Q -f "$M/20261009_0001_printer_delivery_uncertain.sql"
Q <<'SQL'
do $$
declare
  primary_id uuid := gen_random_uuid(); backup_id uuid := gen_random_uuid();
  business_id uuid := gen_random_uuid(); agent_id uuid := gen_random_uuid();
  job public.print_jobs; claimed public.print_jobs; j uuid;
begin
  insert into printers(id) values (backup_id);
  insert into printers(id,fallback_printer_id) values (primary_id,backup_id);
  insert into device_agents(id,business_id) values (agent_id,business_id);
  insert into print_jobs(business_id,printer_id,status,claimed_by,claimed_at)
    values(business_id,primary_id,'printing',agent_id,now()) returning id into j;
  job := fn_complete_print_job(j,false,'[DELIVERY_UNCERTAIN] connection reset after write');
  perform test_assert(job.status='failed' and job.retry_count>=5 and job.next_retry_at is null
    and job.printer_id=primary_id and job.failover_count=0 and job.claimed_by is null,
    'uncertain delivery is terminal, no fallback, claim cleared');
  claimed := fn_claim_next_print_job(agent_id,business_id);
  perform test_assert(claimed.id is null,'terminal uncertain delivery cannot be claimed again');

  insert into print_jobs(business_id,printer_id,status)
    values(business_id,primary_id,'printing') returning id into j;
  job := fn_complete_print_job(j,false,'Connection refused before write');
  perform test_assert(job.status='pending' and job.printer_id=backup_id and job.failover_count=1,
    'pre-write failure retains immediate backup');
  job := fn_complete_print_job(j,false,'Connection refused before write');
  perform test_assert(job.status='failed' and job.retry_count=1 and job.next_retry_at>now(),
    'safe subsequent failure retains exponential backoff');
  job := fn_complete_print_job(j,true,null);
  perform test_assert(job.status='printed' and job.printed_at is not null and job.claimed_by is null,
    'successful acknowledgment still marks printed');

  insert into print_jobs(business_id,printer_id,status,claimed_by,claimed_at)
    values(business_id,primary_id,'printing',agent_id,now()-interval '5 minutes') returning id into j;
  perform test_assert(fn_reclaim_stale_print_jobs(60)=1,'abandoned printing claim detected');
  select * into job from print_jobs where id=j;
  perform test_assert(job.status='failed' and job.retry_count>=5 and job.next_retry_at is null
    and job.last_error like '[DELIVERY_UNCERTAIN]%' and job.claimed_by is null,
    'crash after claim requires review and never automatically replays');
  claimed := fn_claim_next_print_job(agent_id,business_id);
  perform test_assert(claimed.id is null,'stale uncertain claim cannot be claimed again');

  insert into print_jobs(business_id,printer_id,status) values(business_id,primary_id,'pending') returning id into j;
  perform test_assert(fn_reclaim_stale_print_jobs(60)=0,'queued jobs untouched by stale recovery');
  claimed := fn_claim_next_print_job(agent_id,business_id);
  perform test_assert(claimed.id=j and claimed.status='printing','pending job still claims normally');
end $$;
SQL
Q <<'SQL'
do $$
declare
  primary_id uuid := gen_random_uuid(); backup_id uuid := gen_random_uuid();
  business_id uuid := gen_random_uuid(); agent_id uuid := gen_random_uuid();
  other_agent uuid := gen_random_uuid(); job public.print_jobs; waiting uuid; foreign_claim uuid; queued uuid;
begin
  insert into printers(id) values (backup_id);
  insert into printers(id,fallback_printer_id) values (primary_id,backup_id);
  -- Ticket waiting 5 minutes behind a slow printer, held by an alive agent.
  insert into print_jobs(business_id,printer_id,status,claimed_by,claimed_at)
    values(business_id,primary_id,'printing',agent_id,now()-interval '5 minutes') returning id into waiting;
  -- Same age, but held by an agent that stopped renewing.
  insert into print_jobs(business_id,printer_id,status,claimed_by,claimed_at)
    values(business_id,primary_id,'printing',other_agent,now()-interval '5 minutes') returning id into foreign_claim;
  insert into print_jobs(business_id,printer_id,status) values(business_id,primary_id,'pending') returning id into queued;

  perform test_assert(fn_renew_print_job_claims(agent_id,array[waiting,foreign_claim,queued])=1,
    'renewal only touches printing claims held by the calling agent');
  perform test_assert(fn_renew_print_job_claims(agent_id,array[]::uuid[])=0
    and fn_renew_print_job_claims(null,array[waiting])=0,'empty renewal is a no-op');
  perform test_assert(fn_reclaim_stale_print_jobs(60)=1,'only the unrenewed claim is reclaimed');
  select * into job from print_jobs where id=waiting;
  perform test_assert(job.status='printing' and job.claimed_by=agent_id and job.retry_count=0,
    'renewed waiting ticket is not marked delivery uncertain');
  select * into job from print_jobs where id=foreign_claim;
  perform test_assert(job.status='failed' and job.last_error like '[DELIVERY_UNCERTAIN]%',
    'abandoned claim of another agent still requires review');
  select * into job from print_jobs where id=queued;
  perform test_assert(job.status='pending' and job.claimed_by is null,'renewal never claims a queued job');

  -- The waiting ticket then fails before writing: retry and failover still apply.
  job := fn_complete_print_job(waiting,false,'Connection refused before write');
  perform test_assert(job.status='pending' and job.printer_id=backup_id and job.failover_count=1,
    'safe failure after a long wait keeps immediate backup');
end $$;
SQL
Q -f "$M/20261009_0001_printer_delivery_uncertain_ROLLBACK.sql"
Q <<'SQL'
do $$ declare j uuid; job public.print_jobs;
begin
  insert into print_jobs(status,claimed_at) values('printing',now()-interval '5 minutes') returning id into j;
  perform fn_reclaim_stale_print_jobs(60);
  select * into job from print_jobs where id=j;
  perform test_assert(job.status='pending' and job.retry_count=0,'rollback restores original reclaim behavior');
  perform test_assert(to_regprocedure('public.fn_renew_print_job_claims(uuid,uuid[])') is null,
    'rollback removes claim renewal');
end $$;
SQL
