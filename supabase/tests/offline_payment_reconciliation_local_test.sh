#!/usr/bin/env bash
# Postgres 15 desechable; no toca ninguna base remota.
# Prueba 20261010_0008 (T07): cobros hechos sin red que suben después.
# Funciones y disparadores REALES: fn_process_payment_v3 y el candado de cobro
# VIVOS (fixtures/), cierre de orden, emisión del comprobante (factura o nota
# de venta) y el índice único de pagos. Dobles solo para el total de las líneas
# y para generate_ncf (secuencia local, con un interruptor de falla fiscal).
set -euo pipefail
REPO=$(cd "$(dirname "$0")/../.." && pwd)
M=$REPO/supabase/migrations
F=$REPO/supabase/tests/fixtures
PG=${PG_BIN:-/opt/homebrew/opt/postgresql@15/bin}
PORT=${PG_PORT:-55471}
WORK=${1:-$(mktemp -d)}
D=$WORK/pg_offline_payment
mkdir -p "$D"
"$PG/initdb" -D "$D/data" -U postgres --auth=trust >/dev/null
"$PG/pg_ctl" -D "$D/data" -o "-p $PORT -c listen_addresses=127.0.0.1 -c unix_socket_directories=''" -l "$D/log" start -w >/dev/null
trap '"$PG/pg_ctl" -D "$D/data" stop -m fast >/dev/null 2>&1' EXIT
Q() { "$PG/psql" -h 127.0.0.1 -p "$PORT" -U postgres -X -q -v ON_ERROR_STOP=1 "$@"; }
QU() { local uid=$1; shift; PGOPTIONS="-c request.jwt.claim.sub=$uid -c request.jwt.claim.role=authenticated" Q "$@"; }
MANAGER=a0000000-0000-0000-0000-000000000001
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
create type public.order_status as enum ('open','sent_to_kitchen','partially_paid','paid','void');
create type public.item_status as enum ('pending','preparing','ready','served','void','draft','paid');
create type public.ncf_type as enum ('B01','B02','B04','E31','E32','E34');
create table public.businesses(id uuid primary key, owner_id uuid);
create table public.memberships(user_id uuid not null, business_id uuid not null);
create table public.user_businesses(user_id uuid not null, business_id uuid not null,
  shared_across_branches boolean not null default false, role text);
create table public.business_settings(id uuid default gen_random_uuid(), business_id uuid unique not null);
create table public.customers(id uuid primary key default gen_random_uuid(), business_id uuid,
  name text, tax_id text);
create table public.zones(id uuid primary key default gen_random_uuid(), business_id uuid not null);
create table public.dining_tables(id uuid primary key default gen_random_uuid(),
  zone_id uuid not null references public.zones(id), state text not null default 'occupied');
create table public.table_sessions(id uuid primary key default gen_random_uuid(),
  table_id uuid references public.dining_tables(id), business_id uuid,
  opened_at timestamptz not null default now(), closed_at timestamptz,
  customer_id uuid, customer_name text, note text, origin text not null default 'dine_in');
create table public.orders(id uuid primary key default gen_random_uuid(),
  session_id uuid not null references public.table_sessions(id), status text not null default 'open',
  status_ext public.order_status not null default 'open', created_at timestamptz default now(),
  closed_at timestamptz, subtotal numeric not null default 0, discounts numeric not null default 0,
  tax numeric not null default 0, total numeric not null default 0, service_fee numeric default 0,
  delivery_fee numeric not null default 0, tip numeric not null default 0,
  is_sales_note boolean not null default false,
  -- 20261010_0020 (cuentas en revisión).
  review_reason text, review_source_order_id uuid);
create table public.order_checks(id uuid primary key default gen_random_uuid(),
  order_id uuid not null references public.orders(id), label text not null default 'Cuenta',
  position integer not null default 1, is_closed boolean not null default false,
  closed_at timestamptz, subtotal numeric default 0, tax numeric default 0,
  service_fee numeric default 0, discounts numeric default 0, total numeric not null default 0,
  customer_id uuid, customer_name text, customer_rnc text, requested_ncf_type public.ncf_type,
  is_sales_note boolean);
create table public.order_items(id uuid primary key default gen_random_uuid(),
  order_id uuid references public.orders(id), product_id uuid default gen_random_uuid(),
  quantity numeric not null default 1, qty numeric default 1, unit_price numeric not null default 100,
  check_id uuid, product_name text default 'Producto', status public.item_status default 'draft',
  notes text, subtotal numeric, discounts numeric default 0, tax numeric default 0,
  created_at timestamptz default now());
create table public.payment_methods(id uuid primary key default gen_random_uuid(), business_id uuid,
  code text, is_active boolean default true);
create table public.cash_registers(id uuid primary key default gen_random_uuid(), business_id uuid not null,
  name text not null, is_active boolean default true);
create table public.cash_register_sessions(id uuid primary key default gen_random_uuid(),
  cash_register_id uuid not null references public.cash_registers(id), user_id uuid,
  opened_at timestamptz default now(), closed_at timestamptz, start_amount numeric default 0,
  status text default 'open');
create table public.cash_transactions(id uuid primary key default gen_random_uuid(), session_id uuid,
  amount numeric, type text, description text, related_order_id uuid, created_at timestamptz,
  reason_code text, created_by uuid);
create table public.payments(id uuid primary key default gen_random_uuid(), business_id uuid not null,
  order_id uuid, check_id uuid, fiscal_document_id uuid, payment_method_id uuid, amount numeric not null,
  reference text, change_amount numeric, status text, processed_by uuid, session_id uuid,
  created_at timestamptz default clock_timestamp(), customer_id uuid, customer_rnc text,
  requested_ncf_type public.ncf_type, split_sequence smallint not null default 0, offline_ncf text);
create table public.fiscal_settings(business_id uuid primary key,
  default_ncf_type public.ncf_type default 'B02', ecf_enabled boolean default false);
create table public.fiscal_documents(id uuid primary key default gen_random_uuid(), business_id uuid,
  order_id uuid, check_id uuid, payment_id uuid, customer_id uuid, ncf_type public.ncf_type,
  ncf_number text, ncf_sequence_id uuid, customer_name text, customer_rnc text, subtotal numeric,
  taxable_amount numeric, itbis_amount numeric, service_fee numeric, total numeric,
  status text default 'active', ecf_status text, is_electronic boolean,
  offline_issued boolean default false, created_at timestamptz default clock_timestamp(),
  constraint fiscal_documents_business_id_ncf_number_key unique (business_id, ncf_number));
create table public.ncf_sequences(id uuid default gen_random_uuid(), business_id uuid,
  ncf_type public.ncf_type, prefix text, current_number bigint default 0, range_end bigint default 10000,
  is_active boolean default true, expiration_date date, created_at timestamptz default now());
-- Doble: la secuencia local; test.fail_ncf simula la falla fiscal.
create function public.generate_ncf(p_business_id uuid, p_type public.ncf_type) returns text
language plpgsql as $$
declare v_num bigint;
begin
  if current_setting('test.fail_ncf', true) = 'on' then
    raise exception 'NCF_SEQUENCE_UNAVAILABLE';
  end if;
  update public.ncf_sequences set current_number = current_number + 1
   where business_id = p_business_id and ncf_type = p_type returning current_number into v_num;
  return p_type::text || lpad(v_num::text, 8, '0');
end $$;
-- Doble: total de la línea.
create function public.trg_test_item_totals() returns trigger language plpgsql as $$
begin
  new.subtotal := new.unit_price * coalesce(new.qty, new.quantity, 1);
  new.tax := 0;
  return new;
end $$;
create trigger trg_compute_item_totals before insert or update on public.order_items
  for each row execute function public.trg_test_item_totals();
create function public.normalize_ncf_type(p text) returns public.ncf_type language sql as $$
  select nullif(trim(coalesce(p, '')), '')::public.ncf_type
$$;
create function public.user_has_business_access(_user_id uuid, _business_id uuid) returns boolean
  language sql stable as $$ select true $$;
create function public.user_business_role(_user_id uuid, _business_id uuid) returns text
  language sql stable security definer set search_path = public as $$
  select coalesce(
    (select role from public.user_businesses where user_id = _user_id and business_id = _business_id),
    (select 'owner' from public.businesses where id = _business_id and owner_id = _user_id))
$$;
create function public.test_assert(ok boolean, message text) returns void language plpgsql as $$
begin
  if not coalesce(ok, false) then raise exception 'FAIL: %', message; end if;
  raise notice 'ok: %', message;
end $$;

insert into businesses values ('b0000000-0000-0000-0000-000000000001', 'a0000000-0000-0000-0000-000000000009');
insert into business_settings(business_id) values ('b0000000-0000-0000-0000-000000000001');
insert into user_businesses values
  ('a0000000-0000-0000-0000-000000000001', 'b0000000-0000-0000-0000-000000000001', false, 'manager'),
  ('a0000000-0000-0000-0000-000000000002', 'b0000000-0000-0000-0000-000000000001', false, 'cashier');
insert into zones(id, business_id) values ('c0000000-0000-0000-0000-000000000001', 'b0000000-0000-0000-0000-000000000001');
insert into fiscal_settings(business_id) values ('b0000000-0000-0000-0000-000000000001');
insert into ncf_sequences(business_id, ncf_type, prefix)
  select 'b0000000-0000-0000-0000-000000000001', t::public.ncf_type, t from unnest(array['B01','B02']) t;
insert into payment_methods(business_id, code)
  select 'b0000000-0000-0000-0000-000000000001', c from unnest(array['cash','card']) c;
insert into cash_registers(id, business_id, name)
  values ('d1000000-0000-0000-0000-000000000001', 'b0000000-0000-0000-0000-000000000001', 'Caja principal');
-- La caja del cobro sin red (ya cerrada) y la de hoy (abierta).
insert into cash_register_sessions(id, cash_register_id, opened_at, closed_at, status) values
  ('d0000000-0000-0000-0000-00000000000c', 'd1000000-0000-0000-0000-000000000001',
   now() - interval '1 day', now() - interval '10 hours', 'closed'),
  ('d0000000-0000-0000-0000-00000000000a', 'd1000000-0000-0000-0000-000000000001',
   now() - interval '9 hours', null, 'open');
SQL

python3 - "$REPO/supabase" "$D/base.sql" <<'PY'
from pathlib import Path
import sys
root, out = Path(sys.argv[1]), Path(sys.argv[2])
def cut(rel, start, end_marker='$$;'):
    s = (root / rel).read_text()
    a = s.index(start)
    return s[a:s.index(end_marker, a) + len(end_marker)] + '\n'
out.write_text(
    cut('migrations/20260709_0001_shared_user_across_branches.sql',
        'create or replace function public.current_user_business_ids()') +
    cut('migrations/20260709_0001_shared_user_across_branches.sql',
        'create or replace function public.is_member_of_business(p_business uuid)') +
    cut('migrations/20260624_0001_close_checks_on_order_close.sql',
        'CREATE OR REPLACE FUNCTION public.fn_close_order_and_table(', '$function$;'))
PY
Q -f "$D/base.sql" >/dev/null
# Emisión del comprobante (repo) y candado de cobro; encima, lo VIVO.
Q -f "$M/20260513_0002_fd_per_container.sql" >/dev/null
Q -f "$M/20260620_0003_fix_fiscal_document_per_check_reuse.sql" >/dev/null
Q -f "$M/20260910_0001_sales_notes.sql" >/dev/null
Q -f "$M/20261008_0002_sales_note_cash_cycle.sql" >/dev/null
Q -f "$M/20260929_0002_payment_attempt_lock.sql" >/dev/null
Q -f "$F/live_order_edit_functions_20261010.sql" >/dev/null
Q -f "$F/live_payment_fiscal_functions_20261010.sql" >/dev/null
Q -c "create unique index payments_unique_completed_per_check_method_seq on public.payments (
  order_id, coalesce(check_id, '00000000-0000-0000-0000-000000000000'::uuid), payment_method_id, split_sequence)
  where status = 'completed';"
Q -f "$M/20261010_0008_offline_payment_reconciliation.sql"
Q -f "$M/20261010_0008_offline_payment_reconciliation.sql"

Q <<'SQL'
create table public.test_ids(name text primary key, id uuid);
-- Una cuenta con una línea de p_amount. Devuelve la orden.
create function public.test_sale(p_name text, p_amount numeric default 100) returns uuid
language plpgsql as $$
declare t uuid; s uuid; o uuid;
begin
  insert into dining_tables(zone_id) values ('c0000000-0000-0000-0000-000000000001') returning id into t;
  insert into table_sessions(table_id, business_id) values (t, 'b0000000-0000-0000-0000-000000000001')
    returning id into s;
  insert into orders(session_id) values (s) returning id into o;
  insert into order_checks(order_id, position) values (o, 1);
  insert into order_items(order_id, unit_price) values (o, p_amount);
  insert into test_ids values (p_name, o);
  return o;
end $$;
create function public.tid_of(p text) returns uuid language sql stable as $$
  select id from public.test_ids where name = p
$$;
create function public.test_key(p text) returns uuid language sql immutable as $$
  select md5('payment:' || p)::uuid
$$;
-- Un cobro sin red que sube.
create function public.replay(p_key text, p_order text, p_amount numeric,
  p_session uuid default 'd0000000-0000-0000-0000-00000000000a',
  p_method text default 'cash', p_seq int default 0, p_close boolean default true,
  p_paid_at timestamptz default now() - interval '2 hours', p_change numeric default 0)
returns jsonb language sql as $$
  select public.fn_replay_offline_payment(
    public.test_key(p_key), public.tid_of(p_order), null, p_method, p_amount,
    p_cashier_session_id => p_session, p_change_amount => p_change,
    p_close_order => p_close, p_split_sequence => p_seq::smallint, p_paid_at => p_paid_at,
    p_device_id => 'tablet-A', p_origin_session_ref => 'local-cash-session-1')
$$;
create function public.payments_of(p text) returns bigint language sql stable as $$
  select count(*) from public.payments where order_id = public.tid_of(p) and status = 'completed'
$$;
create function public.cash_of(p text) returns bigint language sql stable as $$
  select count(*) from public.cash_transactions where related_order_id = public.tid_of(p)
$$;
SQL

Q <<'SQL'
do $$
declare r jsonb; r2 jsonb; v_paid_at timestamptz := now() - interval '3 hours';
  closed constant uuid := 'd0000000-0000-0000-0000-00000000000c';
  open_s constant uuid := 'd0000000-0000-0000-0000-00000000000a';
begin
  -- Respuesta perdida: el reintento devuelve el mismo resultado, sin cobrar
  -- otra vez.
  perform test_sale('lost');
  r := replay('lost', 'lost', 100, p_paid_at => v_paid_at);
  r2 := replay('lost', 'lost', 100, p_paid_at => v_paid_at);
  perform test_assert(r ->> 'status' = 'applied' and (r2 ->> 'replayed')::boolean
    and r2 ->> 'payment_id' = r ->> 'payment_id' and payments_of('lost') = 1 and cash_of('lost') = 1,
    'a repeated payment (lost reply) is recognised by its key: one payment, one cash entry');
  perform test_assert((select session_id = open_s and created_at = v_paid_at from payments
                        where id = (r ->> 'payment_id')::uuid)
    and (select created_at = v_paid_at and session_id = open_s from cash_transactions
          where related_order_id = tid_of('lost')),
    'the payment keeps its original cash session and its original date');
  perform test_assert((select status_ext = 'paid' from orders where id = tid_of('lost'))
    and exists (select 1 from fiscal_documents where order_id = tid_of('lost') and status = 'active')
    and jsonb_array_length(r -> 'money' -> 'flags') = 0,
    'the real close issues the document and the reconciliation finds nothing wrong');

  -- Caja ya cerrada: no se aplica ni se mueve sola.
  perform test_sale('late');
  r := replay('late', 'late', 100, p_session => closed, p_paid_at => v_paid_at);
  perform test_assert(r ->> 'status' = 'needs_resolution' and r ->> 'reason' = 'cash_session_closed'
    and payments_of('late') = 0 and cash_of('late') = 0
    and (select status_ext = 'open' from orders where id = tid_of('late'))
    and exists (select 1 from offline_payment_receipts where payment_key = test_key('late')
                  and status = 'needs_resolution' and cash_session_id = closed
                  and request ->> 'origin_session_ref' = 'local-cash-session-1'),
    'closed cash session: nothing is applied or moved; the receipt keeps it to resolve');
  r := replay('late', 'late', 100, p_session => closed, p_paid_at => v_paid_at);
  perform test_assert(r ->> 'status' = 'needs_resolution' and payments_of('late') = 0,
    'retrying does not move it either');
  r := fn_resolve_offline_payment(test_key('late'), 'post_to_open_session', open_s, 'Cobro de anoche');
  perform test_assert(r ->> 'status' = 'resolved' and payments_of('late') = 1
    and (select session_id = open_s and created_at = v_paid_at from payments
          where id = (r ->> 'payment_id')::uuid)
    and (select reason_code = 'late_offline_payment' and description like 'Cobro sin red de la caja d0000000%'
           from cash_transactions where related_order_id = tid_of('late'))
    and (select resolution = 'post_to_open_session' and applied_session_id = open_s
           and cash_session_id = closed from offline_payment_receipts where payment_key = test_key('late')),
    'explicit decision: posted to the open session, with its original date and the closed-session note');
  r := fn_resolve_offline_payment(test_key('late'), 'post_to_open_session', open_s);
  perform test_assert((r ->> 'replayed')::boolean and payments_of('late') = 1,
    'repeating the decision does not charge twice');

  -- Cobro parcial: dos abonos, el último cierra.
  perform test_sale('split', 100);
  r := replay('split-0', 'split', 40, p_method => 'card', p_seq => 0, p_close => false);
  perform test_assert(r ->> 'status' = 'applied'
    and (select closed_at is null from orders where id = tid_of('split'))
    and (r -> 'money' ->> 'balance')::numeric = 60,
    'a partial payment leaves the account open with its balance');
  r := replay('split-1', 'split', 60, p_method => 'cash', p_seq => 1, p_close => true);
  r2 := replay('split-0', 'split', 40, p_method => 'card', p_seq => 0, p_close => false);
  perform test_assert(r ->> 'status' = 'applied' and (r2 ->> 'replayed')::boolean
    and payments_of('split') = 2
    and (select status_ext = 'paid' from orders where id = tid_of('split'))
    and (r -> 'money' ->> 'balance')::numeric = 0
    and jsonb_array_length(r -> 'money' -> 'flags') = 0,
    'the closing payment closes the account; replaying the first one does not charge it again');

  -- Cambio de jornada: un cobro de ayer en la caja que sigue abierta.
  perform test_sale('yesterday');
  r := replay('yesterday', 'yesterday', 100, p_paid_at => now() - interval '8 hours');
  perform test_assert(r ->> 'status' = 'applied'
    and (select created_at::date = (now() - interval '8 hours')::date from payments
          where order_id = tid_of('yesterday')),
    'a payment synced the next day keeps its own date');

  -- Reloj del equipo adelantado.
  perform test_sale('future');
  r := replay('future', 'future', 100, p_paid_at => now() + interval '3 hours');
  perform test_assert(r ->> 'reason' = 'paid_at_in_future' and payments_of('future') = 0,
    'a date ahead of the server (device clock) waits for a decision');
  r := fn_resolve_offline_payment(test_key('future'), 'apply_anyway');
  perform test_assert(r ->> 'status' = 'resolved' and payments_of('future') = 1,
    'apply_anyway applies it as it was');

  -- La cuenta creció después del cobro sin red.
  perform test_sale('grew', 100);
  insert into order_items(order_id, unit_price) values (tid_of('grew'), 50);
  r := replay('grew', 'grew', 100);
  perform test_assert(r ->> 'reason' = 'order_changed' and payments_of('grew') = 0
    and (select status_ext = 'open' from orders where id = tid_of('grew')),
    'an account that grew is not closed by the old amount');
  r := fn_resolve_offline_payment(test_key('grew'), 'apply_as_partial');
  perform test_assert(r ->> 'status' = 'resolved' and payments_of('grew') = 1
    and (select closed_at is null from orders where id = tid_of('grew'))
    and (r -> 'money' ->> 'balance')::numeric = 50,
    'apply_as_partial records it as a partial payment; the balance stays to charge');

  -- Otro equipo ya cobró la cuenta.
  perform test_sale('paid_elsewhere');
  r := replay('other-device', 'paid_elsewhere', 100, p_method => 'card');
  r := replay('this-device', 'paid_elsewhere', 100);
  perform test_assert(r ->> 'reason' = 'order_already_paid' and payments_of('paid_elsewhere') = 1
    and jsonb_array_length(r -> 'detail' -> 'payments') = 1,
    'an account already paid elsewhere: this payment is not absorbed by the other one');
  r := fn_resolve_offline_payment(test_key('this-device'), 'acknowledge', null, 'El cliente pagó dos veces');
  perform test_assert(r ->> 'status' = 'acknowledged' and payments_of('paid_elsewhere') = 1
    and exists (select 1 from offline_payment_receipts where payment_key = test_key('this-device')
                  and resolution_note = 'El cliente pagó dos veces'),
    'acknowledge leaves the record without charging');

  -- Cuenta anulada sin cobros (liberada): no se confunde con «ya cobrada».
  perform test_sale('voided');
  update orders set status_ext = 'void', status = 'canceled', closed_at = now() where id = tid_of('voided');
  r := replay('voided', 'voided', 100);
  perform test_assert(r ->> 'reason' = 'order_voided' and payments_of('voided') = 0
    and (r -> 'detail' ->> 'review_order_id') is null,
    'a released (voided) account is reported as such, not as paid elsewhere');

  -- 20261010_0020: la cuenta ya cobrada recibió productos tardíos, que
  -- quedaron en una cuenta en revisión. El cobro sin red puede ir ahí, pero
  -- solo por decisión explícita.
  perform test_sale('settled', 100);
  r := replay('settled-card', 'settled', 100, p_method => 'card');
  insert into orders(session_id, review_reason, review_source_order_id)
  select session_id, 'late_items_after_settle', tid_of('settled') from orders where id = tid_of('settled');
  insert into test_ids values ('review', (select id from orders where review_source_order_id = tid_of('settled')));
  insert into order_items(order_id, unit_price) values (tid_of('review'), 50);
  r := replay('settled-late', 'settled', 50);
  perform test_assert(r ->> 'reason' = 'order_already_paid'
    and (r -> 'detail' ->> 'review_order_id')::uuid = tid_of('review') and payments_of('review') = 0,
    'the review account born from it is named, and nothing is charged by itself');
  r := fn_resolve_offline_payment(test_key('settled-late'), 'apply_to_review_order');
  perform test_assert(r ->> 'status' = 'resolved' and payments_of('review') = 1
    and payments_of('settled') = 1
    and (select status_ext = 'paid' from orders where id = tid_of('review')),
    'apply_to_review_order charges the review account, never the settled one');

  -- Mismo lugar (método y secuencia) ocupado por un cobro distinto.
  perform test_sale('slot');
  r := replay('slot-a', 'slot', 40, p_close => false);
  r := replay('slot-b', 'slot', 60, p_close => false);
  perform test_assert(r ->> 'reason' = 'payment_slot_taken' and payments_of('slot') = 1,
    'two devices with the same method and sequence are not confused');

  -- Cobro registrado antes de existir los recibos (respuesta perdida).
  perform test_sale('pre_receipt');
  perform fn_process_payment_v3(tid_of('pre_receipt'), null, 'cash', 100, null,
    p_cashier_session_id => open_s, p_paid_at => v_paid_at);
  r := replay('pre_receipt', 'pre_receipt', 100, p_paid_at => v_paid_at);
  perform test_assert(r ->> 'status' = 'applied' and payments_of('pre_receipt') = 1,
    'a payment already recorded (same identity) is adopted, not charged twice');

  -- Falla fiscal dentro del cobro: nada queda a medias.
  perform test_sale('fiscal');
  perform set_config('test.fail_ncf', 'on', true);
  begin
    perform replay('fiscal', 'fiscal', 100);
    raise exception 'FAIL: fiscal failure was swallowed';
  exception when others then
    perform test_assert(sqlerrm like '%NCF_SEQUENCE_UNAVAILABLE%', 'a fiscal failure aborts the payment');
  end;
  perform set_config('test.fail_ncf', 'off', true);
  perform test_assert(payments_of('fiscal') = 0 and cash_of('fiscal') = 0
    and not exists (select 1 from offline_payment_receipts where payment_key = test_key('fiscal')),
    'after the fiscal failure there is no payment, no cash entry and no receipt');
  r := replay('fiscal', 'fiscal', 100);
  perform test_assert(r ->> 'status' = 'applied' and payments_of('fiscal') = 1
    and exists (select 1 from fiscal_documents where order_id = tid_of('fiscal')),
    'the retry applies it once, with its document');

  -- Otro equipo está cobrando la cuenta en este momento (candado vivo).
  perform test_sale('locked');
  insert into order_payment_attempts(order_id, attempt_id, device_id, holder_label, started_at, expires_at)
  values (tid_of('locked'), gen_random_uuid(), 'pc-2', 'Caja 2', now(), now() + interval '2 minutes');
  begin
    perform replay('locked', 'locked', 100);
    raise exception 'FAIL: replay ran over another device''s payment';
  exception when others then
    perform test_assert(sqlerrm like '%PAYMENT_LOCKED_BY_OTHER_DEVICE%',
      'a payment in progress on another device makes the replay wait (retry later)');
  end;
  perform test_assert(payments_of('locked') = 0
    and not exists (select 1 from offline_payment_receipts where payment_key = test_key('locked')),
    'nothing is recorded while the other device holds the account');

  -- Conciliación: subcuenta cerrada sin cobrar y comprobante faltante.
  perform test_sale('recon', 100);
  insert into order_checks(order_id, position, is_closed) values (tid_of('recon'), 2, true);
  update order_items set check_id = (select id from order_checks where order_id = tid_of('recon') and position = 2)
   where order_id = tid_of('recon');
  update orders set status_ext = 'paid', closed_at = now() where id = tid_of('recon');
  insert into payments(business_id, order_id, payment_method_id, amount, status, session_id)
  select 'b0000000-0000-0000-0000-000000000001', tid_of('recon'), id, 100, 'completed', open_s
    from payment_methods where code = 'card';
  r := fn_order_money_state(tid_of('recon'));
  perform test_assert(r -> 'flags' ? 'check_closed_unpaid' and r -> 'flags' ? 'document_missing',
    'the reconciliation shows a closed sub-check without payment and a missing document');
  perform test_assert((select count(*) from fn_offline_payment_issues('b0000000-0000-0000-0000-000000000001'))
      >= 1,
    'pending decisions are listed for the business');
end $$;
SQL

# Reinicio a mitad del cobro: la transacción no llegó a confirmarse.
Q -c "select test_sale('crash')" >/dev/null
Q -c "begin; select replay('crash', 'crash', 100); rollback;" >/dev/null
r=$(Q -t -A -c "select count(*) from offline_payment_receipts where payment_key = test_key('crash')")
[ "$r" = "0" ] || { echo "FAIL: a rolled back replay left a receipt"; exit 1; }
r=$(Q -t -A -c "select replay('crash', 'crash', 100) ->> 'status'")
n=$(Q -t -A -c "select payments_of('crash')")
[ "$r" = "applied" ] && [ "$n" = "1" ] || { echo "FAIL: replay after restart ($r, $n)"; exit 1; }
echo "ok: a restart before commit leaves nothing; the next replay applies it once"

# Dos equipos suben el mismo cobro a la vez: uno espera al otro.
Q -c "select test_sale('race')" >/dev/null
Q -c "begin; select replay('race', 'race', 100); select pg_sleep(2); commit;" >/dev/null &
FIRST=$!
sleep 0.5
r=$(Q -t -A -c "select replay('race', 'race', 100) ->> 'replayed'")
wait "$FIRST"
n=$(Q -t -A -c "select payments_of('race')")
[ "$r" = "true" ] && [ "$n" = "1" ] || { echo "FAIL: concurrent replays charged twice ($r, $n)"; exit 1; }
echo "ok: two concurrent replays of the same payment charge it once"

# Permisos.
if QU "$CASHIER" -c "select fn_resolve_offline_payment(md5('payment:other-device')::uuid, 'acknowledge')" >"$D/out.txt" 2>&1; then
  echo "FAIL: a cashier resolved a payment"; exit 1
fi
grep -q RESOLVE_DENIED "$D/out.txt" || { cat "$D/out.txt"; echo "FAIL: expected RESOLVE_DENIED"; exit 1; }
echo "ok: only an owner, admin or manager decides"
Q <<'SQL'
do $$ begin
  perform test_assert(
    not has_function_privilege('anon', 'public.fn_replay_offline_payment(uuid, uuid, uuid, text, numeric, text, uuid, text, uuid, numeric, text, boolean, smallint, boolean, timestamptz, text, text, text)', 'execute')
    and has_function_privilege('authenticated', 'public.fn_replay_offline_payment(uuid, uuid, uuid, text, numeric, text, uuid, text, uuid, numeric, text, boolean, smallint, boolean, timestamptz, text, text, text)', 'execute')
    and not has_function_privilege('authenticated', 'public.fn_apply_offline_payment_locked(jsonb, uuid, boolean)', 'execute')
    and not has_table_privilege('authenticated', 'public.offline_payment_receipts', 'select'),
    'only the gateways are executable; receipts are not readable directly');
end $$;
SQL

Q -f "$M/20261010_0008_offline_payment_reconciliation_ROLLBACK.sql"
Q <<'SQL'
do $$ begin
  perform test_assert(to_regclass('public.offline_payment_receipts') is null
    and to_regprocedure('public.fn_order_money_state(uuid)') is null,
    'rollback removes the receipts and the gateways');
end $$;
SQL
echo "Offline payment reconciliation: OK"
