#!/usr/bin/env bash
# Postgres local desechable; no toca ninguna base remota.
# Prueba 20261010_0024: «Mover a otra mesa» una cuenta en revisión
# (20261010_0020) y quién la tomó (mesero y mesa). Mesa libre → pasa a ser su
# cuenta, a nombre de su mesero; ocupada → se suma; el origen se libera si queda
# sin cuentas. Base = 0819 + 0020 + 0023; 0024 dos veces y reversa.
set -euo pipefail
REPO=$(cd "$(dirname "$0")/../.." && pwd)
M=$REPO/supabase/migrations
PG=${PG_BIN:-/opt/homebrew/opt/postgresql@15/bin}
PORT=${PG_PORT:-55469}
WORK=${1:-$(mktemp -d)}
D=$WORK/pg_move_review_order
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
Q -f "$M/20261010_0023_release_lock_and_orphan_heal.sql" >/dev/null

# Meseros (empleados del PIN) y perfil; la columna de autor de cada línea.
Q <<'SQL'
alter table public.order_items add column created_by_employee_id uuid;
insert into public.employees(id, business_id, user_id, first_name) values
  ('e0000000-0000-0000-0000-000000000001', 'b0000000-0000-0000-0000-000000000001',
   'a0000000-0000-0000-0000-000000000002', 'Veras Pérez'),
  ('e0000000-0000-0000-0000-000000000002', 'b0000000-0000-0000-0000-000000000001',
   null, 'Claudia');
insert into public.profiles(id, full_name) values
  ('a0000000-0000-0000-0000-000000000001', 'Rosario Gómez');
SQL

# Una cuenta en revisión creada ANTES de 0024 (sin quién la tomó): la
# migración la completa desde la bitácora.
Q <<'SQL'
do $$
declare m uuid; r uuid;
begin
  perform as_user('veras');
  perform new_table('OLD');
  m := open_t('OLD');
  perform add(m, 'COCA', 100);
  perform as_user('rosario');
  r := (fn_open_local_table_order('local-OLD', idof('OLD')) ->> 'order_id')::uuid;
  perform put('OLD:review', r);
end $$;
SQL

Q -f "$M/20261010_0024_move_review_order.sql"
Q -f "$M/20261010_0024_move_review_order.sql"

Q <<'SQL'
do $$
declare s uuid; r uuid; x uuid; i uuid; acc jsonb; res jsonb;
begin
  -- O0: la existente quedó completa desde la bitácora (subió rosario, en OLD).
  perform as_user('veras');
  acc := fn_review_accounts(session_of(idof('OLD:review'))) -> 0;
  perform test_assert(acc->>'waiter_name' = 'Rosario' and acc->>'table_code' = 'OLD',
    'O0 cuenta previa a 0024: mesero y mesa completados desde la bitácora');

  -- O1: subida con el mesero del PIN → la hoja dice quién y dónde.
  perform as_user('veras');
  perform new_table('O1');
  x := open_t('O1');
  perform add(x, 'COCA', 100);
  perform as_user('rosario');
  r := (fn_open_local_table_order('local-O1', idof('O1'), 1,
        'e0000000-0000-0000-0000-000000000002') ->> 'order_id')::uuid;
  perform add(r, 'PLATO', 250);
  perform put('O1:review', r);
  acc := fn_review_accounts(session_of(r)) -> 0;
  perform test_assert(acc->>'waiter_name' = 'Claudia' and acc->>'table_code' = 'O1'
    and jsonb_array_length(acc->'order_items') = 1,
    'O1 la cuenta en revisión dice quién la tomó (Claudia) y en qué mesa (O1)');

  -- O2: moverla a una mesa libre → llega a nombre de Claudia, no de quien mueve.
  perform as_user('veras');
  perform new_table('O2_DST');
  res := fn_move_review_order(r, idof('O2_DST'));
  s := session_of(r);
  perform test_assert(res->>'outcome' = 'moved'
    and (select opened_by_employee_id from table_sessions where id = s) = 'e0000000-0000-0000-0000-000000000002'
    and (select opened_by from table_sessions where id = s) = 'a0000000-0000-0000-0000-000000000001'
    and zt('O2_DST')->>'waiter_name' = 'Claudia',
    'O2 movida a mesa libre: la mesa queda a nombre del mesero que la tomó');
  perform test_assert((ord(r)).taken_at_table_id = idof('O1'),
    'O2 conserva la mesa donde se tomó (O1)');

  -- O3: productos tardíos de una cuenta COBRADA con la mesa libre → la mesa se
  -- abre a nombre del mesero de esa cuenta (Veras), no de quien sube.
  perform as_user('veras');
  perform new_table('O3');
  update public.dining_tables set state = 'available' where id = idof('O3');
  x := (fn_open_table(idof('O3'), 'a0000000-0000-0000-0000-000000000002', 1,
        'e0000000-0000-0000-0000-000000000001') ->> 'order_id')::uuid;
  perform add(x, 'COCA', 100);
  insert into payments(order_id, amount) values (x, 100);
  perform fn_close_order_and_table(x, 'paid');
  perform as_user('rosario');
  i := add(x, 'POSTRE', 80);
  r := (select order_id from order_items where id = i);
  perform test_assert((ord(r)).review_reason = 'late_items_after_settle'
    and (select opened_by_employee_id from table_sessions where id = session_of(r)) = 'e0000000-0000-0000-0000-000000000001'
    and zt('O3')->>'waiter_name' = 'Veras',
    'O3 productos tardíos de una cuenta cobrada: la mesa se abre a nombre de su mesero');
  perform as_user('veras');
  acc := fn_review_accounts(session_of(r)) -> 0;
  perform test_assert(acc->>'waiter_name' = 'Veras' and acc->>'table_code' = 'O3',
    'O3 la hoja dice Veras · O3');
end $$;
SQL

Q <<'SQL'
-- Mesa con cuenta principal (veras, con producto) y una cuenta en revisión
-- (rosario, sin conexión, con producto).
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
  perform add(r, 'AGUA', 50);
  perform as_user('veras');
  return r;
end $$;
SQL

Q <<'SQL'
do $$
declare r uuid; m uuid; t uuid; res jsonb; s_src uuid; v_msg text;
begin
  -- M1: a una mesa libre → pasa a ser LA cuenta de esa mesa.
  r := table_with_review('M1');
  s_src := session_of(idof('M1:main'));
  perform new_table('M1_DST');
  res := fn_move_review_order(r, idof('M1_DST'));
  perform test_assert(res->>'outcome' = 'moved' and (ord(r)).review_reason is null
    and (select table_id from table_sessions where id = session_of(r)) = idof('M1_DST')
    and (select state from dining_tables where id = idof('M1_DST')) = 'occupied',
    'M1 mesa libre: la cuenta pasa a ser la de la mesa destino');
  perform test_assert(open_t('M1_DST') = r and (ord(r)).total = 300,
    'M1 abrir la mesa destino da esa cuenta, con su total recalculado');
  perform test_assert((select closed_at from table_sessions where id = s_src) is null
    and session_of(idof('M1:main')) = s_src and (zt('M1')->>'review_orders_count')::int = 0,
    'M1 la mesa de origen sigue con su cuenta y sin cuentas en revisión');
  perform test_assert(exists (select 1 from order_review_events where order_id = r and event = 'resolved_move'),
    'M1 bitácora resolved_move');

  -- M2: a una mesa ocupada → se suma a su cuenta.
  r := table_with_review('M2');
  perform as_user('veras');
  perform new_table('M2_DST');
  m := open_t('M2_DST');
  perform add(m, 'HEINEKEN', 150);
  res := fn_move_review_order(r, idof('M2_DST'));
  perform test_assert(res->>'outcome' = 'merged' and (res->>'items_moved')::int = 2
    and res->>'target_order_id' = m::text, 'M2 mesa ocupada: se suma a su cuenta');
  perform test_assert((select count(*) from order_items where order_id = m) = 3 and (ord(m)).total = 450
    and (ord(r)).status_ext = 'void' and (ord(r)).closed_at is not null,
    'M2 productos en la cuenta destino, total recalculado; la de revisión anulada');
  perform test_assert((select closed_at from table_sessions where id = session_of(idof('M2:main'))) is null,
    'M2 la mesa de origen conserva su cuenta');

  -- M3: en el origen ya solo quedaba la de revisión → la mesa de origen se libera.
  r := table_with_review('M3');
  s_src := session_of(r);
  perform fn_close_order_and_table(idof('M3:main'), 'paid');
  perform new_table('M3_DST');
  res := fn_move_review_order(r, idof('M3_DST'));
  perform test_assert(res->>'outcome' = 'moved'
    and (select closed_at from table_sessions where id = s_src) is not null
    and (select state from dining_tables where id = idof('M3')) = 'available',
    'M3 el origen sin más cuentas: la mesa de origen queda libre');
  -- M3b: igual pero a una mesa ocupada (sumar): el origen también se libera.
  r := table_with_review('M3b');
  s_src := session_of(r);
  perform fn_close_order_and_table(idof('M3b:main'), 'paid');
  res := fn_move_review_order(r, idof('M2_DST'));
  perform test_assert(res->>'outcome' = 'merged'
    and (select closed_at from table_sessions where id = s_src) is not null,
    'M3b sumar a otra mesa sin más cuentas en el origen: la mesa de origen queda libre');

  -- M4: con cobro registrado no se mueve.
  r := table_with_review('M4');
  insert into payments(order_id, amount, status) values (r, 300, 'pending');
  perform new_table('M4_DST');
  res := fn_move_review_order(r, idof('M4_DST'));
  perform test_assert(res->>'outcome' = 'has_payments' and session_of(r) = session_of(idof('M4:main')),
    'M4 con cobro: no se mueve');
  delete from payments where order_id = r;

  -- M5: errores claros.
  begin perform fn_move_review_order(r, idof('M4')); v_msg := 'sin error';
  exception when others then v_msg := sqlerrm; end;
  perform test_assert(v_msg = 'SAME_TABLE_NOT_ALLOWED', 'M5 a la misma mesa: SAME_TABLE_NOT_ALLOWED');
  perform new_table('MX', 'c0000000-0000-0000-0000-000000000002');
  begin perform fn_move_review_order(r, idof('MX')); v_msg := 'sin error';
  exception when others then v_msg := sqlerrm; end;
  perform test_assert(v_msg = 'SAME_BUSINESS_REQUIRED', 'M5 a otro negocio: SAME_BUSINESS_REQUIRED');
  res := fn_move_review_order(idof('M4:main'), idof('M4_DST'));
  perform test_assert(res->>'outcome' = 'not_in_review', 'M5 una cuenta normal no se mueve por aquí');
  perform as_user('outsider');
  begin perform fn_move_review_order(r, idof('M4_DST')); v_msg := 'sin error';
  exception when others then v_msg := sqlerrm; end;
  perform test_assert(v_msg = 'NOT_A_MEMBER', 'M5 fuera del negocio: NOT_A_MEMBER');
end $$;
SQL

Q -f "$M/20261010_0024_move_review_order_ROLLBACK.sql"
Q <<'SQL'
do $$
begin
  perform test_assert(not exists (select 1 from pg_proc where proname in ('fn_move_review_order', 'fn_review_accounts')),
    'reversa: sin fn_move_review_order ni fn_review_accounts');
  perform test_assert(md5((select prosrc from pg_proc where proname = 'fn_open_local_table_order')) = 'd9008f1167e867d0903294bf97df46cc'
    and md5((select prosrc from pg_proc where proname = 'fn_move_closed_order_to_review')) = '2e4291ad153c6ca22e4b8f1749f7f51c'
    and md5((select prosrc from pg_proc where proname = 'fn_late_items_review_order')) = '382c1c45b167fd4438e722673aa66ea6'
    and md5((select prosrc from pg_proc where proname = 'fn_reattach_orphan_order')) = '4a5cd739415c810688c12448088872f0',
    'reversa: las cuatro funciones vuelven a su cuerpo vivo');
end $$;
SQL
echo 'TODO OK'
