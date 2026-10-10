#!/usr/bin/env bash
# Postgres local desechable; no toca ninguna base remota.
# Prueba 20261010_0020 (fase 2): la cuenta de un equipo que vuelve no
# desaparece ni se mezcla. Línea base = definiciones vivas del 10-oct
# (fixture + 20260819_0004, cargadas con la reversa); después la migración dos
# veces, los casos, la resolución y la reversa (que se niega con cuentas en
# revisión abiertas).
set -euo pipefail
REPO=$(cd "$(dirname "$0")/../.." && pwd)
M=$REPO/supabase/migrations
PG=${PG_BIN:-/opt/homebrew/opt/postgresql@15/bin}
PORT=${PG_PORT:-55465}
WORK=${1:-$(mktemp -d)}
D=$WORK/pg_order_review_accounts
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

# Línea base: con lo vivo, los productos tardíos de una cuenta liberada cuya
# mesa ya tomó otra cuenta se RECHAZAN (MP402).
Q <<'SQL'
do $$
declare x uuid; y uuid; v_ok boolean := false;
begin
  perform test_assert((select string_agg(privilege_type, ',') from information_schema.role_table_grants
     where table_name = 'v_zone_table_status' and grantee = 'authenticated') = 'SELECT'
     and (select reloptions from pg_class where oid = 'public.v_zone_table_status'::regclass) = '{security_barrier=true}',
    'reversa como cargador: la vista viva conserva permisos y opciones');
  perform as_user('rosario');
  perform new_table('T0');
  x := open_t('T0');
  perform fn_close_order_and_table(x, 'void');
  perform as_user('veras');
  y := open_t('T0');
  perform add(y, 'COCA', 100);
  perform as_user('rosario');
  begin
    perform add(x, 'PLATO', 250);
  exception when sqlstate 'MP402' then v_ok := true;
  end;
  perform test_assert(v_ok, 'línea base: producto tardío con la mesa tomada → MP402 (se atascaba)');
end $$;
SQL

Q -f "$M/20261010_0020_order_review_accounts.sql"
Q -f "$M/20261010_0020_order_review_accounts.sql"

Q <<'SQL'
do $$
declare r jsonb; r2 jsonb; m uuid; rv uuid; v_ok boolean;
begin
  perform test_assert((select string_agg(privilege_type, ',') from information_schema.role_table_grants
     where table_name = 'v_zone_table_status' and grantee = 'authenticated') = 'SELECT'
     and (select reloptions from pg_class where oid = 'public.v_zone_table_status'::regclass) = '{security_barrier=true}',
    'migración: la vista conserva permisos y opciones');

  -- S1: mesa libre → cuenta normal; reintento → la misma; sin caja también.
  perform as_user('rosario');
  perform new_table('T1');
  r := fn_open_local_table_order('local-order-1', idof('T1'));
  perform test_assert(r->>'outcome' = 'created' and not (r->>'review')::boolean, 'S1 mesa libre: cuenta normal');
  r2 := fn_open_local_table_order('local-order-1', idof('T1'));
  perform test_assert(r2->>'outcome' = 'existing' and r2->>'order_id' = r->>'order_id', 'S1 reintento: la MISMA cuenta');
  perform set_config('test.no_cash', 'on', true);
  r2 := fn_open_local_table_order('local-order-1', idof('T1'));
  perform test_assert(r2->>'order_id' = r->>'order_id', 'S1 reintento sin caja abierta: la misma cuenta');
  perform set_config('test.no_cash', 'off', true);
  perform test_assert((select table_id from table_sessions where id = (r->>'session_id')::uuid) = idof('T1')
    and (select business_id from table_sessions where id = (r->>'session_id')::uuid) = 'b0000000-0000-0000-0000-000000000001',
    'S1 sesión en la mesa y el negocio correctos');

  -- S2 (MESA4): otro mesero ya volvió a teclear → cuenta aparte en revisión.
  perform new_table('T2');
  perform as_user('veras');
  m := put('T2:main', open_t('T2'));
  perform add(m, 'PRESIDENTE', 150);
  perform add(m, 'HEINEKEN', 150);
  perform as_user('rosario');
  r := fn_open_local_table_order('local-order-2', idof('T2'));
  rv := put('T2:review', (r->>'order_id')::uuid);
  perform test_assert(r->>'outcome' = 'review' and (r->>'review')::boolean, 'S2 mesa con otra cuenta con productos: cuenta en revisión');
  perform test_assert(session_of(rv) = session_of(m) and (ord(rv)).review_reason = 'offline_conflict'
    and (ord(rv)).client_order_id = 'local-order-2', 'S2 misma sesión, offline_conflict, conserva su identidad');
  perform add(rv, 'PLATO DEL DIA', 300);
  perform test_assert((select count(*) from order_items where order_id = m) = 2
    and (select count(*) from order_items where order_id = rv) = 1, 'S2 nada se mezcla');
  perform as_user('veras');
  perform test_assert(open_t('T2') = m, 'S2 abrir la mesa da la cuenta principal, no la de revisión');
  perform test_assert((zt('T2')->>'total')::numeric = 300 and (zt('T2')->>'review_orders_count')::int = 1
    and (zt('T2')->>'review_total')::numeric = 300, 'S2 salón: total sin la de revisión; 1 cuenta en revisión de 300');
  perform test_assert(exists (select 1 from order_review_events where order_id = rv and event = 'conflict_opened' and target_order_id = m),
    'S2 bitácora conflict_opened');
  r2 := fn_open_local_table_order('local-order-2', idof('T2'));
  perform test_assert(r2->>'order_id' = rv::text and (r2->>'review')::boolean, 'S2 reintento: la misma cuenta en revisión');

  -- S3: cuenta vacía abierta por el MISMO usuario → se adopta.
  perform as_user('rosario');
  perform new_table('T3');
  m := open_t('T3');
  r := fn_open_local_table_order('local-order-3', idof('T3'));
  perform test_assert(r->>'outcome' = 'adopted' and r->>'order_id' = m::text
    and (ord(m)).client_order_id = 'local-order-3' and (ord(m)).review_reason is null,
    'S3 apertura lenta que sí se guardó (vacía, mismo usuario): se adopta');
  -- vacía pero de OTRO usuario → revisión.
  perform new_table('T3b');
  perform as_user('veras');
  m := open_t('T3b');
  perform as_user('rosario');
  r := fn_open_local_table_order('local-order-3b', idof('T3b'));
  perform test_assert(r->>'outcome' = 'review', 'S3 cuenta vacía de otro mesero: revisión, no se adopta');
  -- del mismo usuario pero con productos → revisión.
  perform new_table('T3c');
  m := open_t('T3c');
  perform add(m, 'COCA', 100);
  r := fn_open_local_table_order('local-order-3c', idof('T3c'));
  perform test_assert(r->>'outcome' = 'review', 'S3 cuenta propia con productos: revisión');
end $$;
SQL

# S4–S6: productos que llegan tarde.
Q <<'SQL'
do $$
declare x uuid; y uuid; i uuid; rv uuid; rv2 uuid; s0 uuid; v_ok boolean := false;
begin
  -- S4: cuenta liberada y mesa tomada → vuelve como cuenta en revisión.
  perform as_user('rosario');
  perform new_table('T4');
  x := put('T4:x', open_t('T4'));
  s0 := session_of(x);
  perform fn_close_order_and_table(x, 'void');
  perform as_user('veras');
  y := put('T4:main', open_t('T4'));
  perform add(y, 'COCA', 100);
  perform as_user('rosario');
  i := add(x, 'PLATO', 250);
  perform test_assert((select order_id from order_items where id = i) = x, 'S4 el producto entra en SU cuenta');
  perform test_assert(session_of(x) = session_of(y) and (ord(x)).closed_at is null
    and (ord(x)).status_ext = 'open' and (ord(x)).review_reason = 'late_items_after_release',
    'S4 la cuenta vuelve en revisión a la sesión actual');
  perform test_assert((select check_id from order_items where id = i) is not null
    and not (select is_closed from order_checks where id = (select check_id from order_items where id = i)),
    'S4 su subcuenta se reabre');
  perform test_assert(exists (select 1 from orphan_order_revivals where order_id = x and source = 'order_item_insert_review' and session_id = s0),
    'S4 bitácora de resurrección con la sesión original');
  perform as_user('veras');
  perform test_assert(open_t('T4') = y, 'S4 la mesa sigue dando la cuenta actual');
  perform test_assert((zt('T4')->>'review_orders_count')::int = 1, 'S4 salón: 1 cuenta en revisión');

  -- S5: cuenta liberada y mesa libre → se reanima como antes (sin revisión).
  perform as_user('rosario');
  perform new_table('T5');
  x := open_t('T5');
  perform fn_close_order_and_table(x, 'void');
  perform add(x, 'PLATO', 250);
  perform test_assert((ord(x)).closed_at is null and (ord(x)).review_reason is null
    and (select closed_at from table_sessions where id = session_of(x)) is null,
    'S5 mesa libre: se reanima su cuenta (como 20260819_0004)');

  -- S6: cuenta COBRADA → no se revive; el producto va a una cuenta en revisión.
  perform new_table('T6');
  x := put('T6:x', open_t('T6'));
  perform add(x, 'COCA', 100);
  insert into payments(order_id, amount) values (x, 100);
  perform fn_close_order_and_table(x, 'paid');
  i := add(x, 'POSTRE', 80);
  rv := (select order_id from order_items where id = i);
  perform put('T6:review', rv);
  perform test_assert(rv <> x and (ord(x)).status_ext = 'paid' and (ord(x)).closed_at is not null,
    'S6 la cobrada sigue cobrada y cerrada');
  perform test_assert((ord(rv)).review_reason = 'late_items_after_settle' and (ord(rv)).review_source_order_id = x
    and (select table_id from table_sessions where id = session_of(rv)) = idof('T6')
    and (select opened_by from table_sessions where id = session_of(rv)) = 'a0000000-0000-0000-0000-000000000001',
    'S6 producto en cuenta en revisión de la misma mesa, con la cobrada como origen');
  perform test_assert((select check_id from order_items where id = i) =
    (select id from order_checks where order_id = rv and position = 1), 'S6 en la subcuenta de la cuenta nueva');
  i := add(x, 'CAFE', 50);
  perform test_assert((select order_id from order_items where id = i) = rv, 'S6 un segundo producto tardío va a la MISMA cuenta en revisión');
  -- cobrada con la mesa tomada por otra cuenta → revisión en esa sesión.
  perform new_table('T6b');
  x := open_t('T6b');
  insert into payments(order_id, amount) values (x, 1);
  perform fn_close_order_and_table(x, 'paid');
  perform as_user('veras');
  y := open_t('T6b');
  perform as_user('rosario');
  i := add(x, 'POSTRE', 80);
  rv2 := (select order_id from order_items where id = i);
  perform test_assert(session_of(rv2) = session_of(y) and rv2 <> y and (ord(rv2)).review_reason = 'late_items_after_settle',
    'S6 cobrada con la mesa tomada: revisión en la sesión actual, nunca en la principal');
  -- sin JWT y mesa libre: no hay a quién atribuir la sesión → MP401 como antes.
  perform new_table('T6c');
  x := open_t('T6c');
  insert into payments(order_id, amount) values (x, 1);
  perform fn_close_order_and_table(x, 'paid');
  perform as_user('');
  begin
    perform add(x, 'POSTRE', 80);
  exception when sqlstate 'MP401' then v_ok := true;
  end;
  perform test_assert(v_ok, 'S6 sin usuario y mesa libre: MP401 (sin cambio)');
end $$;
SQL

# S7: resolver; S8: aislamiento por negocio.
Q <<'SQL'
do $$
declare r jsonb; m uuid; rv uuid; v_msg text; s uuid;
begin
  -- merge: los productos pasan a la principal; la de revisión se anula; la mesa sigue.
  perform as_user('veras');
  m := idof('T2:main'); rv := idof('T2:review');
  r := fn_resolve_review_order(rv, 'merge');
  perform test_assert(r->>'outcome' = 'merged' and (r->>'items_moved')::int = 1 and r->>'target_order_id' = m::text,
    'S7 unir: mueve el producto a la cuenta actual');
  perform test_assert((select count(*) from order_items where order_id = m) = 3 and (ord(m)).total = 600
    and (ord(rv)).status_ext = 'void' and (ord(rv)).closed_at is not null
    and (select closed_at from table_sessions where id = session_of(m)) is null,
    'S7 unir: total recalculado, la de revisión anulada, la mesa sigue abierta');
  perform test_assert((zt('T2')->>'review_orders_count')::int = 0 and (zt('T2')->>'total')::numeric = 600,
    'S7 salón: ya sin cuentas en revisión');

  -- void: motivo obligatorio; con motivo se anula.
  rv := idof('T4:x');
  begin
    perform fn_resolve_review_order(rv, 'void', '  ');
    v_msg := 'sin error';
  exception when others then v_msg := sqlerrm;
  end;
  perform test_assert(v_msg = 'REASON_REQUIRED', 'S7 anular sin motivo: REASON_REQUIRED');
  r := fn_resolve_review_order(rv, 'void', 'era duplicado de la retecleada');
  perform test_assert(r->>'outcome' = 'voided' and (ord(rv)).status_ext = 'void'
    and (select closed_at from table_sessions where id = session_of(idof('T4:main'))) is null,
    'S7 anular duplicado: anulada; la cuenta actual sigue');
  r := fn_resolve_review_order(rv, 'void', 'otra vez');
  perform test_assert(r->>'outcome' = 'not_in_review' or r->>'outcome' = 'already_closed', 'S7 resolver dos veces no rompe nada');

  -- con cobro: ni unir ni anular.
  perform as_user('rosario');
  perform new_table('T7');
  perform as_user('veras');
  m := open_t('T7');
  perform add(m, 'COCA', 100);
  perform as_user('rosario');
  rv := (fn_open_local_table_order('local-order-7', idof('T7'))->>'order_id')::uuid;
  perform add(rv, 'PLATO', 250);
  insert into payments(order_id, amount, status) values (rv, 250, 'pending');
  perform test_assert(fn_resolve_review_order(rv, 'void', 'dup')->>'outcome' = 'has_payments'
    and fn_resolve_review_order(rv, 'merge')->>'outcome' = 'has_payments'
    and (ord(rv)).closed_at is null, 'S7 cuenta en revisión con cobro: no se une ni se anula');
  delete from payments where order_id = rv;

  -- cobrar la principal no libera la mesa mientras quede una en revisión; al
  -- unir sin principal, la de revisión pasa a ser la de la mesa.
  perform as_user('veras');
  perform fn_close_order_and_table(m, 'paid');
  s := session_of(rv);
  perform test_assert((select closed_at from table_sessions where id = s) is null
    and (select state from dining_tables where id = idof('T7')) = 'occupied',
    'S7 cobrar la principal: la mesa sigue ocupada por la cuenta en revisión');
  r := fn_resolve_review_order(rv, 'merge');
  perform test_assert(r->>'outcome' = 'promoted' and (ord(rv)).review_reason is null and open_t('T7') = rv,
    'S7 sin cuenta principal: la recuperada pasa a ser la de la mesa');

  -- anular la última cuenta en revisión libera la mesa.
  perform as_user('rosario');
  perform new_table('T9');
  perform as_user('veras');
  m := open_t('T9');
  perform add(m, 'COCA', 100);
  perform as_user('rosario');
  rv := (fn_open_local_table_order('local-order-9', idof('T9'))->>'order_id')::uuid;
  perform as_user('veras');
  perform fn_close_order_and_table(m, 'paid');
  perform fn_resolve_review_order(rv, 'void', 'duplicado');
  perform test_assert((select closed_at from table_sessions where id = session_of(rv)) is not null
    and (select state from dining_tables where id = idof('T9')) = 'available',
    'S7 anular la última cuenta: la mesa queda libre');

  -- S8: fuera del negocio no se sube ni se resuelve; una identidad no cruza negocios.
  perform as_user('outsider');
  begin
    perform fn_open_local_table_order('local-order-x', idof('T1'));
    v_msg := 'sin error';
  exception when others then v_msg := sqlerrm;
  end;
  perform test_assert(v_msg = 'NOT_A_MEMBER', 'S8 otro negocio no sube a una mesa ajena');
  begin
    perform fn_resolve_review_order(idof('T6:review'), 'void', 'x');
    v_msg := 'sin error';
  exception when others then v_msg := sqlerrm;
  end;
  perform test_assert(v_msg = 'NOT_A_MEMBER', 'S8 otro negocio no resuelve cuentas ajenas');
  perform new_table('TX', 'c0000000-0000-0000-0000-000000000002');
  begin
    perform fn_open_local_table_order('local-order-1', idof('TX'));
    v_msg := 'sin error';
  exception when sqlstate 'MP411' then v_msg := 'MP411';
  end;
  perform test_assert(v_msg = 'MP411', 'S8 la misma identidad en otro negocio: MP411');
end $$;
SQL

# Reversa: se niega con cuentas en revisión abiertas; resueltas, vuelve lo vivo.
if Q -f "$M/20261010_0020_order_review_accounts_ROLLBACK.sql" >/dev/null 2>&1; then
  echo 'FAIL: la reversa corrió con cuentas en revisión abiertas'; exit 1
fi
echo 'ok: la reversa se niega con cuentas en revisión abiertas'
Q <<'SQL'
do $$
declare r record;
begin
  perform as_user('veras');
  for r in select id from orders where review_reason is not null and closed_at is null loop
    perform fn_resolve_review_order(r.id, 'void', 'limpieza de la prueba');
  end loop;
end $$;
SQL
Q -f "$M/20261010_0020_order_review_accounts_ROLLBACK.sql" >/dev/null
Q <<'SQL'
do $$
declare x uuid; y uuid; v_ok boolean := false;
begin
  perform test_assert(position('review_reason' in (select prosrc from pg_proc where proname = 'fn_open_table')) = 0
    and not exists (select 1 from pg_proc where proname in ('fn_open_local_table_order', 'fn_resolve_review_order',
      'fn_move_closed_order_to_review', 'fn_late_items_review_order'))
    and not exists (select 1 from information_schema.columns where table_name = 'v_zone_table_status' and column_name = 'review_orders_count'),
    'reversa: funciones y vista vivas otra vez');
  perform test_assert((select string_agg(privilege_type, ',') from information_schema.role_table_grants
     where table_name = 'v_zone_table_status' and grantee = 'authenticated') = 'SELECT'
     and (select reloptions from pg_class where oid = 'public.v_zone_table_status'::regclass) = '{security_barrier=true}',
    'reversa: la vista conserva permisos y opciones');
  perform test_assert(exists (select 1 from information_schema.columns where table_name = 'orders' and column_name = 'client_order_id'),
    'reversa: conserva la identidad ya guardada');
  perform as_user('rosario');
  perform new_table('TR');
  x := open_t('TR');
  perform fn_close_order_and_table(x, 'void');
  perform as_user('veras');
  y := open_t('TR');
  perform as_user('rosario');
  begin
    perform add(x, 'PLATO', 250);
  exception when sqlstate 'MP402' then v_ok := true;
  end;
  perform test_assert(v_ok, 'reversa: vuelve el MP402 vivo');
end $$;
SQL
echo 'TODO OK'
