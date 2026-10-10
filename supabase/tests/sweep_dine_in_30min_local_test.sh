#!/usr/bin/env bash
# Postgres local desechable; no toca ninguna base remota.
# Prueba 20261010_0021: las mesas de salón vacías se barren a los 30 min (la
# contención 20261010_0004, aplicada, esperaba 6 h); ventas rápidas y delivery
# siguen con el plazo del llamador; las reglas de negocio (ítems vivos, 'paid'
# sin cobertura) no cambian. Línea base = 0004; aplica 0021 dos veces y su
# reversa (vuelve a 6 h).
set -euo pipefail
REPO=$(cd "$(dirname "$0")/../.." && pwd)
M=$REPO/supabase/migrations
PG=${PG_BIN:-/opt/homebrew/opt/postgresql@15/bin}
PORT=${PG_PORT:-55466}
WORK=${1:-$(mktemp -d)}
D=$WORK/pg_sweep_dine_in_30min
mkdir -p "$D"
"$PG/initdb" -D "$D/data" -U postgres --auth=trust >/dev/null
"$PG/pg_ctl" -D "$D/data" -o "-p $PORT -c listen_addresses=127.0.0.1 -c unix_socket_directories=''" -l "$D/log" start -w >/dev/null
trap '"$PG/pg_ctl" -D "$D/data" stop -m fast >/dev/null 2>&1' EXIT
Q() { "$PG/psql" -h 127.0.0.1 -p "$PORT" -U postgres -X -q -v ON_ERROR_STOP=1 "$@"; }
QU() { local uid=$1; shift; PGOPTIONS="-c request.jwt.claim.sub=$uid" Q "$@"; }
MEMBER=a0000000-0000-0000-0000-000000000001
OUTSIDER=a0000000-0000-0000-0000-000000000004

Q <<'SQL'
create role anon; create role authenticated; create role service_role;
alter default privileges in schema public grant all on functions to anon, authenticated, service_role;
create schema auth;
grant usage on schema auth to anon, authenticated, service_role;
create function auth.uid() returns uuid language sql stable as $$
  select nullif(nullif(current_setting('request.jwt.claim.sub', true), ''), '')::uuid
$$;
create type public.order_status as enum ('open','sent_to_kitchen','partially_paid','paid','void');
create type public.item_status as enum ('pending','preparing','ready','served','void','draft','paid');
create type public.order_origin as enum ('dine_in','quick','delivery','manual');
create table public.businesses(id uuid primary key, owner_id uuid);
create table public.memberships(user_id uuid not null, business_id uuid not null);
create table public.user_businesses(user_id uuid not null, business_id uuid not null,
  shared_across_branches boolean not null default false);
create table public.zones(id uuid primary key default gen_random_uuid(), business_id uuid not null);
create table public.dining_tables(id uuid primary key default gen_random_uuid(),
  zone_id uuid not null references public.zones(id), state text not null default 'occupied');
create table public.table_sessions(id uuid primary key default gen_random_uuid(),
  table_id uuid references public.dining_tables(id), business_id uuid,
  origin public.order_origin not null default 'dine_in',
  opened_at timestamptz not null default now(), closed_at timestamptz);
create table public.orders(id uuid primary key default gen_random_uuid(),
  session_id uuid not null references public.table_sessions(id), status text not null default 'open',
  status_ext public.order_status not null default 'open',
  created_at timestamptz not null default now(), closed_at timestamptz);
create table public.order_checks(id uuid primary key default gen_random_uuid(),
  order_id uuid not null references public.orders(id), total numeric not null default 0,
  is_closed boolean not null default false);
create table public.order_items(id uuid primary key default gen_random_uuid(),
  order_id uuid references public.orders(id), status public.item_status default 'draft');
create table public.payments(id uuid primary key default gen_random_uuid(),
  order_id uuid, amount numeric not null, status text default 'completed');
create function public.test_assert(ok boolean, message text) returns void language plpgsql as $$
begin
  if not coalesce(ok, false) then raise exception 'FAIL: %', message; end if;
  raise notice 'ok: %', message;
end $$;
insert into businesses values ('b0000000-0000-0000-0000-000000000001', 'a0000000-0000-0000-0000-000000000009');
insert into user_businesses values ('a0000000-0000-0000-0000-000000000001', 'b0000000-0000-0000-0000-000000000001', false);
insert into zones(id, business_id) values ('c0000000-0000-0000-0000-000000000001', 'b0000000-0000-0000-0000-000000000001');
-- Una mesa con su sesión y una orden vacía abiertas hace p_age; la orden puede
-- ser más nueva que la sesión (p_order_age).
create table public.test_ids(name text primary key, id uuid);
create function public.test_table(p_name text, p_origin public.order_origin, p_age interval,
  p_order_age interval default null)
returns uuid language plpgsql as $$
declare t uuid; s uuid; o uuid;
begin
  insert into dining_tables(zone_id) values ('c0000000-0000-0000-0000-000000000001') returning id into t;
  insert into table_sessions(table_id, business_id, origin, opened_at)
    values (t, 'b0000000-0000-0000-0000-000000000001', p_origin, now() - p_age)
    returning id into s;
  insert into orders(session_id, created_at) values (s, now() - coalesce(p_order_age, p_age))
    returning id into o;
  insert into test_ids values (p_name, o), (p_name || ':session', s), (p_name || ':table', t);
  return o;
end $$;
create function public.tid_of(p_name text) returns uuid language sql stable as $$
  select id from public.test_ids where name = p_name
$$;
create function public.session_open(p_name text) returns boolean language sql stable as $$
  select closed_at is null from public.table_sessions where id = public.tid_of(p_name || ':session')
$$;
create function public.order_state(p_name text) returns text language sql stable as $$
  select status_ext::text from public.orders where id = public.tid_of(p_name)
$$;
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
        'create or replace function public.is_member_of_business(p_business uuid)'))
PY
Q -f "$D/base.sql" >/dev/null

# Línea base: lo aplicado hoy (0004) conserva una mesa de salón vacía de 1 h.
Q -f "$M/20261010_0004_contain_auto_releases.sql"
Q <<'SQL'
do $$
begin
  perform test_table('base_dine_1h', 'dine_in', interval '1 hour');
  perform fn_release_empty_tables(20);
  perform test_assert(session_open('base_dine_1h'),
    'línea base (0004): mesa de salón vacía de 1 h sigue ocupada (naranja)');
end $$;
SQL

Q -f "$M/20261010_0021_sweep_dine_in_30min.sql"
Q -f "$M/20261010_0021_sweep_dine_in_30min.sql"

Q <<'SQL'
do $$
begin
  perform fn_release_empty_tables(20);
  perform test_assert(not session_open('base_dine_1h') and order_state('base_dine_1h') = 'void',
    'la de 1 h queda disponible sola');
  perform test_assert((select state from dining_tables where id = tid_of('base_dine_1h:table')) = 'available',
    'la mesa queda disponible');

  perform test_table('dine_25m', 'dine_in', interval '25 minutes');
  perform test_table('dine_35m', 'dine_in', interval '35 minutes');
  perform fn_release_empty_tables(20);
  perform test_assert(session_open('dine_25m'), 'mesa de salón vacía de 25 min: todavía se conserva');
  perform test_assert(not session_open('dine_35m'), 'mesa de salón vacía de 35 min: disponible sola');

  -- Sesión vieja con una orden recién creada: la orden manda.
  perform test_table('dine_old_session_new_order', 'dine_in', interval '2 hours', interval '10 minutes');
  perform fn_release_empty_tables(20);
  perform test_assert(session_open('dine_old_session_new_order'),
    'sesión de 2 h con orden de 10 min: se conserva');

  -- Ventas rápidas y delivery: el plazo del llamador, igual que antes.
  perform test_table('quick_25m', 'quick', interval '25 minutes');
  perform test_table('delivery_25m', 'delivery', interval '25 minutes');
  perform fn_release_empty_tables(20);
  perform test_assert(not session_open('quick_25m'), 'venta rápida vacía de 25 min: se barre como antes');
  perform test_assert(not session_open('delivery_25m'), 'delivery vacío de 25 min: se barre como antes');
end $$;
SQL

# Reglas de negocio intactas.
Q <<'SQL'
do $$
begin
  perform test_table('dine_1h_item', 'dine_in', interval '1 hour');
  insert into order_items(order_id, status) values (tid_of('dine_1h_item'), 'pending');
  perform test_table('dine_1h_paid_uncovered', 'dine_in', interval '1 hour');
  insert into order_items(order_id, status) values (tid_of('dine_1h_paid_uncovered'), 'paid');
  perform fn_release_empty_tables(20);
  perform test_assert(session_open('dine_1h_item') and order_state('dine_1h_item') = 'open',
    'mesa con un producto vivo: nunca se barre');
  perform test_assert(session_open('dine_1h_paid_uncovered'),
    'mesa pagada sin cobro que la cubra: queda para revisión');
end $$;
SQL

# Barrido del salón (acotado al negocio, con 15): mismo mínimo de 30 min.
Q <<'SQL'
do $$
begin
  perform test_table('salon_dine_20m', 'dine_in', interval '20 minutes');
  perform test_table('salon_dine_40m', 'dine_in', interval '40 minutes');
end $$;
SQL
QU "$MEMBER" -c "select fn_release_empty_tables(15, 'b0000000-0000-0000-0000-000000000001')" >/dev/null
Q <<'SQL'
do $$
begin
  perform test_assert(session_open('salon_dine_20m'), 'barrido del salón: mesa de 20 min se conserva');
  perform test_assert(not session_open('salon_dine_40m'), 'barrido del salón: mesa de 40 min disponible');
end $$;
SQL
if QU "$OUTSIDER" -c "select fn_release_empty_tables(15, 'b0000000-0000-0000-0000-000000000001')" >/dev/null 2>&1; then
  echo 'FAIL: alguien de fuera del negocio pudo barrer'; exit 1
fi
echo 'ok: alguien de fuera del negocio no puede barrer'

# Reversa: vuelve a 6 h.
Q -f "$M/20261010_0021_sweep_dine_in_30min_ROLLBACK.sql"
Q <<'SQL'
do $$
begin
  perform test_table('rb_dine_1h', 'dine_in', interval '1 hour');
  perform fn_release_empty_tables(20);
  perform test_assert(session_open('rb_dine_1h'), 'reversa: vuelve a conservar la mesa de 1 h (6 h)');
  perform test_assert(md5((select prosrc from pg_proc where proname = 'fn_release_empty_tables'))
      = 'f681b45052c86bb3ad2b586cf8ef93a2', 'reversa: cuerpo idéntico al aplicado (0004)');
end $$;
SQL
echo 'TODO OK'
