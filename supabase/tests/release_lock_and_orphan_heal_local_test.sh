#!/usr/bin/env bash
# Postgres local desechable; no toca ninguna base remota.
# Prueba 20261010_0023: la salida de una mesa vacía toma el candado por mesa de
# fn_open_table (comprobado con una segunda conexión real, dblink) y el candado
# de ítems cura la orden viva colgada de una sesión cerrada. Línea base =
# fn_release_empty_table viva previa (reversa de 0023) + candado de 20261010_0020.
set -euo pipefail
REPO=$(cd "$(dirname "$0")/../.." && pwd)
M=$REPO/supabase/migrations
PG=${PG_BIN:-/opt/homebrew/opt/postgresql@15/bin}
PORT=${PG_PORT:-55468}
WORK=${1:-$(mktemp -d)}
D=$WORK/pg_release_lock_orphan_heal
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
python3 - "$M" "$D/release_live.sql" <<'PY2'
from pathlib import Path
import sys
m, out = Path(sys.argv[1]), Path(sys.argv[2])
# El cuerpo vivo previo a 0023 (md5 5dc47a35…) lo guarda la reversa de 0023;
# la de T02 (0030) ahora restaura la versión de 0023.
s = (m / '20261010_0023_release_lock_and_orphan_heal_ROLLBACK.sql').read_text()
a = s.index('CREATE OR REPLACE FUNCTION public.fn_release_empty_table(p_order_id uuid)')
out.write_text(s[a:s.index('$function$;', a) + len('$function$;')] + '\n')
PY2
Q -f "$D/release_live.sql" >/dev/null

Q <<'SQL'
create extension dblink;
create function public.orphans() returns bigint language sql stable as $$
  select count(*) from public.orders o join public.table_sessions ts on ts.id = o.session_id
   where o.closed_at is null and o.status_ext not in ('paid','void') and ts.closed_at is not null
$$;
-- ¿La salida espera al candado de la mesa? Otra conexión lo retiene (como una
-- apertura en curso); con lock_timeout corto, esperar = 55P03.
create function public.release_waits_for_open(p_order uuid, p_table uuid) returns boolean
language plpgsql as $$
declare v_waited boolean := false;
begin
  perform * from dblink('c1', format(
    'select 1 from (select pg_advisory_lock(hashtextextended(%L::text, 0))) s', p_table)) as t(x int);
  begin
    perform set_config('lock_timeout', '300ms', true);
    perform fn_release_empty_table(p_order);
  exception when lock_not_available then v_waited := true;
  end;
  perform set_config('lock_timeout', '0', true);
  perform * from dblink('c1', format(
    'select 1 from (select pg_advisory_unlock(hashtextextended(%L::text, 0))) s', p_table)) as t(x int);
  return v_waited;
end $$;
SQL

run() { Q -v port="$PORT" "$@"; }

# Línea base: la salida viva NO espera a una apertura en curso, y un producto
# entra a una orden colgada de una sesión cerrada sin que reaparezca la mesa.
# (La mesa se abre en su propia transacción: fn_open_table toma el candado de
# la mesa hasta el COMMIT y la otra conexión esperaría a esta.)
run <<'SQL'
select dblink_connect('c1', format('host=127.0.0.1 port=%s user=postgres dbname=postgres', :'port'));
do $$ begin perform as_user('rosario'); perform new_table('B1'); perform put('B1:x', open_t('B1')); end $$;
do $$
declare x uuid; o bigint;
begin
  perform as_user('rosario');
  perform test_assert(not release_waits_for_open(idof('B1:x'), idof('B1')),
    'línea base: la salida viva no espera a una apertura en curso (FOR UPDATE solo)');

  perform new_table('B2');
  x := open_t('B2');
  perform add(x, 'PLATO', 250);
  update table_sessions set closed_at = now() where id = session_of(x);
  o := orphans();
  perform add(x, 'COCA', 100);
  perform test_assert(orphans() = o and (select closed_at from table_sessions where id = session_of(x)) is not null,
    'línea base: el producto entra a la orden huérfana y la mesa sigue sin ella');
end $$;
SQL

Q -f "$M/20261010_0023_release_lock_and_orphan_heal.sql"
Q -f "$M/20261010_0023_release_lock_and_orphan_heal.sql"

run <<'SQL'
select dblink_connect('c1', format('host=127.0.0.1 port=%s user=postgres dbname=postgres', :'port'));
do $$ begin perform as_user('rosario'); perform new_table('S1'); perform put('S1:x', open_t('S1')); end $$;
do $$
declare x uuid; y uuid; r jsonb; s0 uuid;
begin
  -- S1: la salida espera a la apertura en curso; sin ella, libera al instante.
  perform as_user('rosario');
  x := idof('S1:x');
  perform test_assert(release_waits_for_open(x, idof('S1')),
    'S1 la salida espera el candado de la mesa (una apertura en curso)');
  perform test_assert((ord(x)).closed_at is null and (select closed_at from table_sessions where id = session_of(x)) is null,
    'S1 mientras espera, no anuló ni cerró nada');
  r := fn_release_empty_table(x);
  perform test_assert((r->>'released')::boolean and (ord(x)).status_ext = 'void'
    and (select closed_at from table_sessions where id = session_of(x)) is not null
    and (select state from dining_tables where id = idof('S1')) = 'available',
    'S1 sin aperturas en curso: salir de la mesa vacía la libera al instante (regla del dueño)');

  -- S1b: con productos no se libera (sin cambios).
  perform new_table('S1b');
  x := open_t('S1b');
  perform add(x, 'COCA', 100);
  r := fn_release_empty_table(x);
  perform test_assert(not (r->>'released')::boolean and r->>'reason' = 'order_has_items',
    'S1b con productos: no se libera (sin cambios)');

  -- S2: orden viva en sesión cerrada, mesa libre → vuelve a su mesa.
  perform new_table('S2');
  x := open_t('S2');
  perform add(x, 'PLATO', 250);
  s0 := session_of(x);
  update table_sessions set closed_at = now() where id = s0;
  update dining_tables set state = 'available' where id = idof('S2');
  perform add(x, 'COCA', 100);
  perform test_assert((select closed_at from table_sessions where id = s0) is null
    and session_of(x) = s0 and (ord(x)).review_reason is null
    and (select state from dining_tables where id = idof('S2')) = 'occupied',
    'S2 huérfana con la mesa libre: se reabre su sesión y la mesa aparece ocupada');
  perform test_assert(exists (select 1 from orphan_order_revivals where order_id = x and source = 'order_item_insert_session'),
    'S2 queda en la bitácora de resurrecciones');
  perform test_assert((select count(*) from order_items where order_id = x) = 2, 'S2 el producto entró a su cuenta');

  -- S3: orden viva en sesión cerrada y la mesa ya es de otra cuenta → revisión.
  perform new_table('S3');
  x := open_t('S3');
  perform add(x, 'PLATO', 250);
  update table_sessions set closed_at = now() where id = session_of(x);
  perform as_user('veras');
  y := open_t('S3');
  perform add(y, 'HEINEKEN', 150);
  perform as_user('rosario');
  perform add(x, 'COCA', 100);
  perform test_assert(session_of(x) = session_of(y) and (ord(x)).review_reason = 'late_items_after_release'
    and (ord(x)).closed_at is null,
    'S3 huérfana con la mesa tomada: pasa como cuenta en revisión a la sesión actual');
  perform as_user('veras');
  perform test_assert(open_t('S3') = y and (zt('S3')->>'review_orders_count')::int = 1,
    'S3 la mesa sigue dando la cuenta actual y el salón marca 1 en revisión');

  -- S4: camino normal intacto.
  perform as_user('rosario');
  perform new_table('S4');
  x := open_t('S4');
  perform add(x, 'COCA', 100);
  perform test_assert((select count(*) from order_items where order_id = x) = 1
    and (ord(x)).review_reason is null, 'S4 agregar a una cuenta normal: sin cambios');

  -- S5: cuenta CERRADA con la mesa tomada (20261010_0020) sigue igual.
  perform new_table('S5');
  x := open_t('S5');
  perform fn_close_order_and_table(x, 'void');
  perform as_user('veras');
  y := open_t('S5');
  perform as_user('rosario');
  perform add(x, 'PLATO', 250);
  perform test_assert((ord(x)).review_reason = 'late_items_after_release' and session_of(x) = session_of(y),
    'S5 cuenta cerrada con la mesa tomada: revisión como en 0020');
end $$;
SQL

# Reversa: cuerpos vivos exactos.
Q -f "$M/20261010_0023_release_lock_and_orphan_heal_ROLLBACK.sql"
Q <<'SQL'
do $$
begin
  perform test_assert(md5((select prosrc from pg_proc where proname = 'fn_release_empty_table'))
      = '5dc47a35730a22eb5a57cbb1c6029b70', 'reversa: salida idéntica a la viva');
  perform test_assert(md5((select prosrc from pg_proc where proname = 'fn_block_items_on_closed_order'))
      = '81f185d0170e12f4e7ce3b724b9cddb3', 'reversa: candado de ítems idéntico al de 0020');
  perform test_assert(not exists (select 1 from pg_proc where proname = 'fn_reattach_orphan_order'),
    'reversa: sin fn_reattach_orphan_order');
end $$;
SQL
echo 'TODO OK'
