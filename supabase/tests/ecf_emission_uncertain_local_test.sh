#!/usr/bin/env bash
# Postgres 15 desechable; no toca ninguna base remota ni Alanube.
# Prueba 20261010_0009 (T07): estado durable de la emisión fiscal, también
# cuando la respuesta de Alanube es incierta. Outbox y disparador de encolado
# REALES (20260506_0002); los CHECK de estado como en la base viva.
set -euo pipefail
REPO=$(cd "$(dirname "$0")/../.." && pwd)
M=$REPO/supabase/migrations
PG=${PG_BIN:-/opt/homebrew/opt/postgresql@15/bin}
PORT=${PG_PORT:-55472}
WORK=${1:-$(mktemp -d)}
D=$WORK/pg_ecf_uncertain
mkdir -p "$D"
"$PG/initdb" -D "$D/data" -U postgres --auth=trust >/dev/null
"$PG/pg_ctl" -D "$D/data" -o "-p $PORT -c listen_addresses=127.0.0.1 -c unix_socket_directories=''" -l "$D/log" start -w >/dev/null
trap '"$PG/pg_ctl" -D "$D/data" stop -m fast >/dev/null 2>&1' EXIT
Q() { "$PG/psql" -h 127.0.0.1 -p "$PORT" -U postgres -X -q -v ON_ERROR_STOP=1 "$@"; }
QU() { local uid=$1; shift; PGOPTIONS="-c request.jwt.claim.sub=$uid -c request.jwt.claim.role=authenticated" Q "$@"; }
CASHIER=a0000000-0000-0000-0000-000000000002

Q <<'SQL'
create role anon; create role authenticated; create role service_role;
alter default privileges in schema public grant all on functions to anon, authenticated, service_role;
create schema auth;
grant usage on schema auth to anon, authenticated, service_role;
create function auth.uid() returns uuid language sql stable as $$
  select nullif(nullif(current_setting('request.jwt.claim.sub', true), ''), '')::uuid
$$;
create function auth.role() returns text language sql stable as $$
  select nullif(current_setting('request.jwt.claim.role', true), '')
$$;
create type public.ncf_type as enum ('B02','E31','E32','E34');
create table public.businesses(id uuid primary key, owner_id uuid);
create table public.user_businesses(user_id uuid, business_id uuid, role text);
create function public.user_business_role(_user_id uuid, _business_id uuid) returns text
  language sql stable security definer set search_path = public as $$
  select coalesce(
    (select role from public.user_businesses where user_id = _user_id and business_id = _business_id),
    (select 'owner' from public.businesses where id = _business_id and owner_id = _user_id))
$$;
create function public.trigger_set_updated_at() returns trigger language plpgsql as $$
begin new.updated_at := now(); return new; end $$;
create table public.business_alanube_settings(id uuid primary key default gen_random_uuid(),
  business_id uuid not null references public.businesses(id), environment text default 'sandbox',
  mode text default 'electronic',
  constraint business_alanube_settings_business_id_environment_key unique (business_id, environment));
-- Como en la base viva (supabase/schema.sql).
create table public.fiscal_documents(id uuid primary key default gen_random_uuid(),
  business_id uuid not null, order_id uuid, payment_id uuid, ncf_type public.ncf_type not null,
  ncf_number text not null, is_electronic boolean, ecf_status text default 'pending',
  status text default 'active', alanube_document_id text, submitted_at timestamptz,
  last_error text, created_at timestamptz default now(),
  constraint fiscal_documents_ecf_status_check check (ecf_status = any (array['pending','sent','accepted','rejected'])),
  constraint fiscal_documents_status_check check (status = any (array['active','cancelled','modified'])),
  constraint fiscal_documents_business_id_ncf_number_key unique (business_id, ncf_number));
create table public.fiscal_document_status_events(id uuid primary key default gen_random_uuid(),
  fiscal_document_id uuid, previous_status text, new_status text, source text, note text,
  created_at timestamptz default now());
-- Lo que la emisión NUNCA debe tocar.
create table public.payments(id uuid primary key default gen_random_uuid(), order_id uuid, amount numeric);
create table public.inventory_movements(id uuid primary key default gen_random_uuid(), reference_id uuid,
  quantity numeric);
create function public.test_assert(ok boolean, message text) returns void language plpgsql as $$
begin
  if not coalesce(ok, false) then raise exception 'FAIL: %', message; end if;
  raise notice 'ok: %', message;
end $$;
insert into businesses values
  ('b0000000-0000-0000-0000-000000000001', 'a0000000-0000-0000-0000-000000000009'),
  ('b0000000-0000-0000-0000-000000000002', 'a0000000-0000-0000-0000-000000000009');
insert into user_businesses values
  ('a0000000-0000-0000-0000-000000000002', 'b0000000-0000-0000-0000-000000000001', 'cashier');
insert into business_alanube_settings(business_id)
  select id from businesses;
insert into payments(amount) values (100);
insert into inventory_movements(quantity) values (-1);
SQL

Q -f "$M/20260506_0002_alanube_emit_hook.sql" >/dev/null
Q -f "$M/20261010_0009_ecf_emission_uncertain_state.sql"
Q -f "$M/20261010_0009_ecf_emission_uncertain_state.sql"

Q <<'SQL'
create function public.test_doc(p_ncf text, p_business uuid default 'b0000000-0000-0000-0000-000000000001')
returns uuid language plpgsql as $$
declare v uuid;
begin
  insert into fiscal_documents(business_id, ncf_type, ncf_number, is_electronic)
  values (p_business, 'E32', p_ncf, true) returning id into v;
  return v;
end $$;
-- Lo que hace emit-document al reclamar (y, si llega, al empezar el POST).
create function public.test_claim(p_doc uuid, p_sent boolean, p_ago interval default '10 minutes')
returns void language sql as $$
  update alanube_emit_outbox
     set status = 'processing', attempts = attempts + 1,
         last_attempt_at = now() - p_ago,
         lease_expires_at = now() - p_ago + interval '5 minutes',
         send_started_at = case when p_sent then now() - p_ago end
   where fiscal_document_id = p_doc
$$;
create function public.outbox_status(p_doc uuid) returns text language sql stable as $$
  select status from alanube_emit_outbox where fiscal_document_id = p_doc
$$;
SQL

Q <<'SQL'
do $$
declare d1 uuid; d2 uuid; d3 uuid; d4 uuid; d5 uuid; r jsonb; v uuid;
begin
  d1 := test_doc('E320000000001');
  perform test_assert(outbox_status(d1) = 'pending', 'an e-CF is queued by the real trigger');

  -- Cortada ANTES del POST: reenviar es seguro.
  perform test_claim(d1, false);
  -- Cortada DESPUÉS del POST: pudo llegar.
  d2 := test_doc('E320000000002');
  perform test_claim(d2, true);
  -- Todavía dentro de su plazo: no se toca.
  d3 := test_doc('E320000000003');
  perform test_claim(d3, true, interval '1 minute');
  r := fn_alanube_outbox_recover_stale();
  perform test_assert((r ->> 'to_pending')::int = 1 and (r ->> 'to_uncertain')::int = 1
    and outbox_status(d1) = 'pending' and outbox_status(d2) = 'uncertain'
    and outbox_status(d3) = 'processing',
    'stale claims: before the POST back to pending; after it uncertain; live claims untouched');
  perform test_assert((select ecf_status = 'uncertain' and last_error like 'No se sabe si Alanube%'
                         from fiscal_documents where id = d2)
    and (select next_attempt_at is null from alanube_emit_outbox where fiscal_document_id = d2),
    'an uncertain e-CF is never scheduled to be resent by itself');

  -- No se anula hasta resolverlo.
  begin
    update fiscal_documents set status = 'cancelled' where id = d2;
    raise exception 'FAIL: uncertain e-CF cancelled';
  exception when others then
    perform test_assert(sqlerrm like 'ECF_UNCERTAIN%', 'an uncertain e-CF cannot be annulled until resolved');
  end;

  -- El webhook lo concilia por su e-NCF (uno solo coincide).
  v := fn_alanube_adopt_uncertain('E320000000002', 'ALN-123');
  perform test_assert(v = d2
    and (select alanube_document_id = 'ALN-123' and ecf_status = 'sent' from fiscal_documents where id = d2)
    and (select status = 'done' and resolution = 'webhook_match' from alanube_emit_outbox
          where fiscal_document_id = d2),
    'the webhook adopts the uncertain e-CF by its e-NCF: done, with its Alanube id');
  perform test_assert(fn_alanube_adopt_uncertain('E320000000002', 'ALN-999') is null,
    'a second webhook for the same e-NCF does not overwrite it');

  -- Mismo e-NCF incierto en dos negocios: ambiguo, no se adopta.
  d4 := test_doc('E320000000004');
  d5 := test_doc('E320000000004', 'b0000000-0000-0000-0000-000000000002');
  perform test_claim(d4, true);
  perform test_claim(d5, true);
  perform fn_alanube_outbox_recover_stale();
  perform test_assert(fn_alanube_adopt_uncertain('E320000000004', 'ALN-4') is null
    and outbox_status(d4) = 'uncertain' and outbox_status(d5) = 'uncertain',
    'an ambiguous e-NCF (two businesses) is never guessed');

  -- Decisión de una persona.
  begin
    perform fn_resolve_uncertain_emission(d4, 'found_in_alanube');
    raise exception 'FAIL: found without id';
  exception when others then
    perform test_assert(sqlerrm like 'ALANUBE_ID_REQUIRED%', 'found_in_alanube needs the Alanube id');
  end;
  r := fn_resolve_uncertain_emission(d4, 'found_in_alanube', 'ALN-4A', 'Visto en el portal');
  perform test_assert(r ->> 'status' = 'done'
    and (select alanube_document_id = 'ALN-4A' and ecf_status = 'sent' from fiscal_documents where id = d4),
    'found_in_alanube stores its id: done, nothing resent');
  r := fn_resolve_uncertain_emission(d5, 'not_in_alanube', null, 'No aparece en el portal');
  perform test_assert(outbox_status(d5) = 'pending'
    and (select send_started_at is null and next_attempt_at <= now() from alanube_emit_outbox
          where fiscal_document_id = d5)
    and (select ecf_status = 'pending' and ncf_number = 'E320000000004' from fiscal_documents where id = d5),
    'not_in_alanube resends with the SAME e-NCF');
  r := fn_resolve_uncertain_emission(d5, 'not_in_alanube');
  perform test_assert((r ->> 'replayed')::boolean, 'repeating the decision changes nothing');

  -- Los demás estados se conservan; un valor inventado no entra.
  begin
    update fiscal_documents set ecf_status = 'bogus' where id = d1;
    raise exception 'FAIL: bogus status accepted';
  exception when check_violation then
    perform test_assert(true, 'the status CHECK keeps the live values plus uncertain only');
  end;

  -- Emitir, conciliar o reenviar nunca toca cobros ni inventario.
  perform test_assert((select count(*) = 1 from payments) and (select count(*) = 1 from inventory_movements),
    'no emission step touched payments or inventory');
end $$;
SQL

# Permisos.
D1=$(Q -t -A -c "select id from fiscal_documents where ncf_number = 'E320000000003'")
Q -c "update alanube_emit_outbox set status = 'uncertain' where fiscal_document_id = '$D1'" >/dev/null
if QU "$CASHIER" -c "select fn_resolve_uncertain_emission('$D1', 'not_in_alanube')" >"$D/out.txt" 2>&1; then
  echo "FAIL: a cashier resolved an uncertain e-CF"; exit 1
fi
grep -q RESOLVE_DENIED "$D/out.txt" || { cat "$D/out.txt"; echo "FAIL: expected RESOLVE_DENIED"; exit 1; }
echo "ok: only an owner, admin or manager decides an uncertain e-CF"
Q <<'SQL'
do $$ begin
  perform test_assert(
    not has_function_privilege('authenticated', 'public.fn_alanube_outbox_recover_stale(interval)', 'execute')
    and not has_function_privilege('authenticated', 'public.fn_alanube_adopt_uncertain(text, text)', 'execute')
    and not has_function_privilege('anon', 'public.fn_resolve_uncertain_emission(uuid, text, text, text)', 'execute')
    and has_function_privilege('service_role', 'public.fn_alanube_outbox_recover_stale(interval)', 'execute'),
    'recovery and webhook matching are for the server only');
end $$;
SQL

Q -f "$M/20261010_0009_ecf_emission_uncertain_state_ROLLBACK.sql"
Q <<'SQL'
do $$ begin
  perform test_assert(not exists (select 1 from alanube_emit_outbox where status = 'uncertain')
    and not exists (select 1 from fiscal_documents where ecf_status = 'uncertain')
    and to_regprocedure('public.fn_resolve_uncertain_emission(uuid, text, text, text)') is null
    and not exists (select 1 from information_schema.columns
                     where table_name = 'alanube_emit_outbox' and column_name = 'send_started_at'),
    'rollback leaves no uncertain state behind and removes the new columns and functions');
  begin
    update fiscal_documents set ecf_status = 'uncertain' where ncf_number = 'E320000000001';
    raise exception 'FAIL: uncertain still allowed after rollback';
  exception when check_violation then
    perform test_assert(true, 'rollback narrows the status CHECK back');
  end;
end $$;
SQL
echo "ECF emission uncertain state: OK"
