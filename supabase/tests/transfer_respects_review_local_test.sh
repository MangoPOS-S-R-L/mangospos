#!/usr/bin/env bash
# Postgres local desechable; no toca ninguna base remota.
# Prueba 20261010_0022: transferir / unir mesa respeta las cuentas en revisión
# (20261010_0020). Línea base = fn_transfer_table_session viva del 10-oct
# (fixture): con una cuenta en revisión en el origen deja una cuenta huérfana.
# Después 0022 dos veces, los casos y la reversa (huella viva).
set -euo pipefail
REPO=$(cd "$(dirname "$0")/../.." && pwd)
M=$REPO/supabase/migrations
PG=${PG_BIN:-/opt/homebrew/opt/postgresql@15/bin}
PORT=${PG_PORT:-55467}
WORK=${1:-$(mktemp -d)}
D=$WORK/pg_transfer_respects_review
rm -rf "$D"; mkdir -p "$D"
"$PG/initdb" -D "$D/data" -U postgres --auth=trust >/dev/null
"$PG/pg_ctl" -D "$D/data" -o "-p $PORT -c listen_addresses=127.0.0.1 -c unix_socket_directories=''" -l "$D/log" start -w >/dev/null
trap '"$PG/pg_ctl" -D "$D/data" stop -m fast >/dev/null 2>&1' EXIT
Q() { "$PG/psql" -h 127.0.0.1 -p "$PORT" -U postgres -X -q -v ON_ERROR_STOP=1 "$@"; }

Q <<'SQL'
create role anon; create role authenticated; create role service_role;
create schema auth;
grant usage on schema auth to anon, authenticated, service_role;
create function auth.uid() returns uuid language sql stable as $$
  select nullif(nullif(current_setting('request.jwt.claim.sub', true), ''), '')::uuid
$$;
create type public.order_status as enum ('open','sent_to_kitchen','partially_paid','paid','void');
create type public.item_status as enum ('pending','preparing','ready','served','void','draft','paid');
create type public.order_origin as enum ('dine_in','quick','delivery','manual');
create type public.table_state as enum ('available','occupied','reserved','cleaning');
create table public.businesses(id uuid primary key, owner_id uuid);
create table public.memberships(user_id uuid not null, business_id uuid not null);
create table public.user_businesses(user_id uuid not null, business_id uuid not null,
  shared_across_branches boolean not null default false);
create table public.zones(id uuid primary key default gen_random_uuid(), business_id uuid not null,
  name text not null default 'SALON');
create table public.dining_tables(id uuid primary key default gen_random_uuid(),
  zone_id uuid not null references public.zones(id), code text not null, label text,
  shape text default 'square', capacity int default 4,
  state public.table_state not null default 'available');
create table public.employees(id uuid primary key default gen_random_uuid(), business_id uuid,
  user_id uuid, first_name text, status text not null default 'active');
create table public.profiles(id uuid primary key, full_name text);
create table public.table_sessions(id uuid primary key default gen_random_uuid(),
  table_id uuid not null references public.dining_tables(id), opened_by uuid not null,
  opened_at timestamptz not null default now(), closed_at timestamptz,
  customer_name text, note text, origin public.order_origin not null default 'dine_in',
  waiter_user_id uuid, people_count int not null default 1, business_id uuid,
  customer_id uuid, delivery_type text, opened_by_employee_id uuid,
  precheck_printed_at timestamptz, delivery_address text);
create unique index uniq_open_session_per_table on public.table_sessions (table_id) where closed_at is null;
-- business_id de la sesión desde la zona (en la base viva lo pone un trigger).
create function public.test_session_business() returns trigger language plpgsql as $$
begin
  if new.business_id is null then
    select z.business_id into new.business_id from public.dining_tables t
      join public.zones z on z.id = t.zone_id where t.id = new.table_id;
  end if;
  return new;
end $$;
create trigger set_business_id_on_table_session before insert on public.table_sessions
  for each row execute function public.test_session_business();
create table public.orders(id uuid primary key default gen_random_uuid(),
  session_id uuid not null references public.table_sessions(id),
  status text not null default 'open', total_amount numeric(12,2) default 0,
  created_at timestamptz default clock_timestamp(),
  status_ext public.order_status not null default 'open',
  subtotal numeric(12,2) not null default 0, discounts numeric(12,2) not null default 0,
  service_fee numeric(12,2) not null default 0, tax numeric(12,2) not null default 0,
  total numeric(12,2) not null default 0, closed_at timestamptz);
create table public.order_checks(id uuid primary key default gen_random_uuid(),
  order_id uuid not null references public.orders(id), label text, position int not null,
  is_closed boolean default false, closed_at timestamptz, total numeric default 0,
  unique (order_id, position));
create table public.order_items(id uuid primary key default gen_random_uuid(),
  order_id uuid references public.orders(id), check_id uuid, product_name text,
  quantity integer not null default 1, unit_price numeric(10,2) not null default 0,
  total numeric(10,2) generated always as (quantity::numeric * unit_price) stored,
  qty numeric(10,3) default 1, status public.item_status default 'draft',
  tax_mode text not null default 'exclusive', discounts numeric(12,2) default 0,
  created_at timestamptz default clock_timestamp());
create table public.order_item_modifiers(id uuid primary key default gen_random_uuid(),
  item_id uuid, price numeric default 0, qty numeric default 1);
create table public.payments(id uuid primary key default gen_random_uuid(),
  order_id uuid, amount numeric not null, status text default 'completed');
create table public.fiscal_documents(id uuid primary key default gen_random_uuid(),
  order_id uuid, status text);
-- Caja: sin caja abierta falla (test.no_cash = on).
create function public.fn_require_open_cash_session(p_user uuid) returns void language plpgsql as $$
begin
  if current_setting('test.no_cash', true) = 'on' then raise exception 'CASH_SESSION_REQUIRED'; end if;
end $$;
create function public.fn_recalc_order_totals(p_order_id uuid) returns void language sql as $$
  update public.orders o set total = coalesce((select sum(oi.total) from public.order_items oi
    where oi.order_id = o.id and oi.status::text not in ('void','paid')), 0)
  where o.id = p_order_id
$$;
create function public.test_assert(ok boolean, message text) returns void language plpgsql as $$
begin
  if not coalesce(ok, false) then raise exception 'FAIL: %', message; end if;
  raise notice 'ok: %', message;
end $$;
-- Negocio B (rosario, veras) y negocio C (outsider).
insert into businesses values ('b0000000-0000-0000-0000-000000000001', 'a0000000-0000-0000-0000-000000000009'),
                              ('b0000000-0000-0000-0000-000000000002', 'a0000000-0000-0000-0000-000000000008');
insert into user_businesses values
  ('a0000000-0000-0000-0000-000000000001', 'b0000000-0000-0000-0000-000000000001', false),
  ('a0000000-0000-0000-0000-000000000002', 'b0000000-0000-0000-0000-000000000001', false),
  ('a0000000-0000-0000-0000-000000000004', 'b0000000-0000-0000-0000-000000000002', false);
insert into zones(id, business_id) values ('c0000000-0000-0000-0000-000000000001', 'b0000000-0000-0000-0000-000000000001'),
                                          ('c0000000-0000-0000-0000-000000000002', 'b0000000-0000-0000-0000-000000000002');
create table public.test_ids(name text primary key, id uuid);
create function public.idof(p_name text) returns uuid language sql stable as $$
  select id from public.test_ids where name = p_name $$;
create function public.put(p_name text, p_id uuid) returns uuid language sql as $$
  insert into public.test_ids values (p_name, p_id)
    on conflict (name) do update set id = excluded.id returning id $$;
create function public.as_user(p_name text) returns void language sql as $$
  select set_config('request.jwt.claim.sub', case p_name
    when 'rosario' then 'a0000000-0000-0000-0000-000000000001'
    when 'veras' then 'a0000000-0000-0000-0000-000000000002'
    when 'outsider' then 'a0000000-0000-0000-0000-000000000004'
    else '' end, true) $$;
SQL
Q <<'SQL'
create function public.new_table(p_name text, p_zone uuid default 'c0000000-0000-0000-0000-000000000001')
returns uuid language plpgsql as $$
declare t uuid;
begin
  insert into public.dining_tables(zone_id, code) values (p_zone, p_name) returning id into t;
  perform public.put(p_name, t);
  return t;
end $$;
create function public.open_t(p_table text) returns uuid language plpgsql as $$
begin
  return (public.fn_open_table(public.idof(p_table), auth.uid()) ->> 'order_id')::uuid;
end $$;
create function public.add(p_order uuid, p_name text, p_price numeric) returns uuid language plpgsql as $$
declare c uuid; i uuid;
begin
  select oc.id into c from public.order_checks oc where oc.order_id = p_order order by oc.position limit 1;
  insert into public.order_items(order_id, check_id, product_name, unit_price, status)
    values (p_order, c, p_name, p_price, 'pending') returning id into i;
  return i;
end $$;
create function public.ord(p_id uuid) returns public.orders language sql stable as $$
  select * from public.orders where id = p_id $$;
create function public.session_of(p_order uuid) returns uuid language sql stable as $$
  select session_id from public.orders where id = p_order $$;
create function public.zt(p_table text) returns jsonb language plpgsql stable as $$
begin
  return (select to_jsonb(v) from public.v_zone_table_status v where v.table_id = public.idof(p_table));
end $$;
SQL

# Base viva: helpers de negocio, cierre de orden (fixture), anulación segura,
# candado de ítems 20260819_0004 y vista/fn_open_table vivas (vía la reversa).
python3 - "$REPO/supabase" "$D/base.sql" <<'PY'
from pathlib import Path
import sys
root, out = Path(sys.argv[1]), Path(sys.argv[2])
def cut(rel, start, end_marker):
    s = (root / rel).read_text()
    a = s.index(start)
    return s[a:s.index(end_marker, a) + len(end_marker)] + '\n'
out.write_text(
    cut('migrations/20260709_0001_shared_user_across_branches.sql',
        'create or replace function public.current_user_business_ids()', '$$;') +
    cut('migrations/20260709_0001_shared_user_across_branches.sql',
        'create or replace function public.is_member_of_business(p_business uuid)', '$$;') +
    cut('tests/fixtures/live_table_open_release_20261010.sql',
        'CREATE OR REPLACE FUNCTION public.fn_close_order_and_table(', '$function$;') +
    cut('migrations/20261009_0007_void_order_if_unpaid.sql',
        'create or replace function public.fn_void_order_if_unpaid(p_order_id uuid)', '$$;'))
PY
Q -f "$D/base.sql" >/dev/null
Q -f "$M/20260819_0004_no_items_on_closed_order.sql" >/dev/null
Q -c "create view public.v_zone_table_status as select 1 as placeholder; grant select on public.v_zone_table_status to authenticated; alter view public.v_zone_table_status set (security_barrier = true);"
Q -f "$M/20261010_0020_order_review_accounts_ROLLBACK.sql" >/dev/null

Q -f "$M/20261010_0020_order_review_accounts.sql" >/dev/null
python3 - "$REPO/supabase" "$D/transfer_live.sql" <<'PY2'
from pathlib import Path
import sys
root, out = Path(sys.argv[1]), Path(sys.argv[2])
s = (root / 'tests/fixtures/live_transfer_table_session_20261010.sql').read_text()
a = s.index('CREATE OR REPLACE FUNCTION public.fn_transfer_table_session(')
out.write_text(s[a:s.index('$function$;', a) + len('$function$;')] + '\n')
PY2
Q -f "$D/transfer_live.sql" >/dev/null

Q <<'SQL'
create function public.orphans() returns bigint language sql stable as $$
  select count(*) from public.orders o join public.table_sessions ts on ts.id = o.session_id
   where o.closed_at is null and o.status_ext not in ('paid','void') and ts.closed_at is not null
$$;
-- Mesa con cuenta principal (veras, con producto) y una cuenta en revisión
-- (rosario, sin conexión, con producto). Devuelve la sesión.
create function public.table_with_review(p_name text) returns uuid language plpgsql as $$
declare m uuid; r uuid;
begin
  perform as_user('veras');
  perform new_table(p_name);
  m := open_t(p_name);
  perform put(p_name || ':main', m);
  perform add(m, 'COCA', 100);
  perform as_user('rosario');
  r := (fn_open_local_table_order('local-' || p_name, idof(p_name)) ->> 'order_id')::uuid;
  perform put(p_name || ':review', r);
  perform add(r, 'PLATO', 250);
  perform as_user('veras');
  return session_of(m);
end $$;
create function public.table_with_main(p_name text) returns uuid language plpgsql as $$
declare m uuid;
begin
  perform as_user('veras');
  perform new_table(p_name);
  m := open_t(p_name);
  perform put(p_name || ':main', m);
  perform add(m, 'HEINEKEN', 150);
  return session_of(m);
end $$;
SQL

# Línea base: la transferencia viva deja una cuenta huérfana.
Q <<'SQL'
do $$
declare s uuid; before bigint;
begin
  s := table_with_review('B_SRC');
  perform table_with_main('B_DST');
  before := orphans();
  perform fn_transfer_table_session(s, idof('B_DST'));
  perform test_assert(orphans() = before + 1,
    'línea base: unir una mesa con cuenta en revisión deja una cuenta huérfana');
end $$;
SQL

Q -f "$M/20261010_0022_transfer_respects_review.sql"
Q -f "$M/20261010_0022_transfer_respects_review.sql"

Q <<'SQL'
do $$
declare s uuid; d uuid; r jsonb; v_ok boolean; before bigint; items_before bigint;
begin
  before := orphans();

  -- S1: origen con cuenta en revisión → MP412, nada cambia.
  s := table_with_review('S1_SRC');
  perform table_with_main('S1_DST');
  v_ok := false;
  begin
    perform fn_transfer_table_session(s, idof('S1_DST'));
  exception when sqlstate 'MP412' then v_ok := true;
  end;
  perform test_assert(v_ok, 'S1 unir/transferir con cuenta en revisión en el origen: MP412');
  perform test_assert((select closed_at from table_sessions where id = s) is null
    and (ord(idof('S1_SRC:main'))).closed_at is null and (ord(idof('S1_SRC:review'))).closed_at is null
    and (select count(*) from order_items where order_id = idof('S1_DST:main')) = 1,
    'S1 origen y destino intactos');

  -- S2: transferencia parcial desde un origen con cuenta en revisión → MP412.
  v_ok := false;
  begin
    perform fn_transfer_table_session(s, idof('S1_DST'),
      array[(select id from order_items where order_id = idof('S1_SRC:main') limit 1)]);
  exception when sqlstate 'MP412' then v_ok := true;
  end;
  perform test_assert(v_ok, 'S2 transferencia parcial con cuenta en revisión en el origen: MP412');

  -- S3: destino con cuenta principal + en revisión → los productos van a la principal.
  s := table_with_main('S3_SRC');
  perform add(idof('S3_SRC:main'), 'AGUA', 50);
  d := table_with_review('S3_DST');
  items_before := (select count(*) from order_items where order_id = idof('S3_DST:review'));
  r := fn_transfer_table_session(s, idof('S3_DST'));
  perform test_assert(r->>'target_order_id' = idof('S3_DST:main')::text
    and (select count(*) from order_items where order_id = idof('S3_DST:main')) = 3,
    'S3 unir con un destino que tiene cuenta en revisión: los productos van a la cuenta principal');
  perform test_assert((select count(*) from order_items where order_id = idof('S3_DST:review')) = items_before
    and (ord(idof('S3_DST:review'))).closed_at is null and (ord(idof('S3_DST:review'))).review_reason is not null,
    'S3 la cuenta en revisión del destino queda intacta');
  perform test_assert((select closed_at from table_sessions where id = s) is not null, 'S3 la mesa origen queda libre');

  -- S4: destino con SOLO la cuenta en revisión (principal cobrada).
  s := table_with_main('S4_SRC');
  d := table_with_review('S4_DST');
  perform fn_close_order_and_table(idof('S4_DST:main'), 'paid');
  r := fn_transfer_table_session(s, idof('S4_DST'));
  perform test_assert(session_of(idof('S4_SRC:main')) = d and (ord(idof('S4_SRC:main'))).closed_at is null
    and (ord(idof('S4_DST:review'))).closed_at is null,
    'S4 destino solo con cuenta en revisión: la cuenta llega como principal y la de revisión sigue');

  -- S5: transferencia normal a mesa libre: igual que antes (se reapunta la sesión).
  s := table_with_main('S5_SRC');
  perform new_table('S5_DST');
  r := fn_transfer_table_session(s, idof('S5_DST'));
  perform test_assert((select table_id from table_sessions where id = s) = idof('S5_DST')
    and r->>'mode' = 'full', 'S5 transferir a una mesa libre: sin cambios');

  -- S6: transferencia parcial normal a mesa libre: sin cambios.
  s := table_with_main('S6_SRC');
  perform add(idof('S6_SRC:main'), 'AGUA', 50);
  perform new_table('S6_DST');
  r := fn_transfer_table_session(s, idof('S6_DST'),
    array[(select id from order_items where order_id = idof('S6_SRC:main') and product_name = 'AGUA')]);
  perform test_assert(r->>'mode' = 'partial' and (r->>'items_moved')::int = 1
    and (select closed_at from table_sessions where id = s) is null,
    'S6 transferencia parcial normal: sin cambios');

  perform test_assert(orphans() = before, 'ninguna cuenta huérfana nueva con 0022');
end $$;
SQL

# Fuera del negocio: sin cambios.
Q <<'SQL'
do $$
declare s uuid; v_msg text;
begin
  s := table_with_main('S7_SRC');
  perform new_table('S7_DST');
  perform as_user('outsider');
  begin
    perform fn_transfer_table_session(s, idof('S7_DST'));
    v_msg := 'sin error';
  exception when others then v_msg := sqlerrm;
  end;
  perform test_assert(v_msg = 'NOT_AUTHORIZED', 'S7 otro negocio no transfiere');
end $$;
SQL

# Reversa: cuerpo vivo exacto.
Q -f "$M/20261010_0022_transfer_respects_review_ROLLBACK.sql"
Q <<'SQL'
do $$
begin
  perform test_assert(md5((select prosrc from pg_proc where proname = 'fn_transfer_table_session'))
      = '4eed56f3cecd3beee2273b3f94633190', 'reversa: cuerpo idéntico al vivo');
end $$;
SQL
echo 'TODO OK'
