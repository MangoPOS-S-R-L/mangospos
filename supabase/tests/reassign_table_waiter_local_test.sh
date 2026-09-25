#!/usr/bin/env bash
# =============================================================================
# Prueba LOCAL de "asignar una mesa a otro mesero" (20260924_0001).
# Postgres 15 DESECHABLE con el esquema mínimo; corre el archivo REAL del repo.
# No toca ninguna base real.
#
#   bash supabase/tests/reassign_table_waiter_local_test.sh [carpeta_trabajo]
# Variables: PG_BIN (default homebrew postgresql@15), PG_PORT (default 55443).
# =============================================================================
set -u
REPO=$(cd "$(dirname "$0")/../.." && pwd)
M=$REPO/supabase/migrations
PG=${PG_BIN:-/opt/homebrew/opt/postgresql@15/bin}
PORT=${PG_PORT:-55443}
WORK=${1:-$(mktemp -d)}
D=$WORK/pg_reassign
rm -rf "$D"; mkdir -p "$D"
"$PG/initdb" -D "$D/data" -U postgres --auth=trust >/dev/null || exit 1
"$PG/pg_ctl" -D "$D/data" -o "-p $PORT -c listen_addresses=127.0.0.1 -c unix_socket_directories=''" \
  -l "$D/log" start -w >/dev/null || { cat "$D/log"; exit 1; }
trap '"$PG/pg_ctl" -D "$D/data" stop -m fast >/dev/null 2>&1' EXIT
Q() { "$PG/psql" -h 127.0.0.1 -p "$PORT" -U postgres -X -q -v ON_ERROR_STOP=1 "$@"; }
FAIL=0
ok()  { echo "  ok     $1"; }
bad() { echo "  FALLA  $1"; FAIL=1; }
run() {
  local label=$1; shift
  if OUT=$(Q "$@" 2>&1); then echo "$OUT" | grep -E "NOTICE:  (ok|--)" | sed 's/^.*NOTICE:  /  /'; ok "$label";
  else echo "$OUT" | grep -E "NOTICE:  ok|ERROR" | sed 's/^.*NOTICE:  /  /; s/^psql:[^:]*:[0-9]*: //'; bad "$label"; fi
}

echo "== Esquema mínimo"
Q <<'SQL' || { bad "esquema"; exit 1; }
create role authenticated; create role anon;
create schema auth;
create table auth.users (id uuid primary key);
insert into auth.users values
  ('99999999-9999-9999-9999-999999999999'),  -- dueño
  ('88888888-8888-8888-8888-888888888888'),  -- mesero (rol waiter)
  ('77777777-7777-7777-7777-777777777777');  -- tablet compartida (cajera)

create function auth.uid() returns uuid language sql stable as $$
  select coalesce(nullif(current_setting('test.uid', true), ''),
                  '99999999-9999-9999-9999-999999999999')::uuid
$$;

create type public.order_origin as enum ('dine_in','takeout','delivery');

create table public.businesses (id uuid primary key, name text);
create table public.zones (id uuid primary key, business_id uuid, name text);
create table public.dining_tables (id uuid primary key, zone_id uuid, code text, state text);
create table public.employees (id uuid primary key, business_id uuid, user_id uuid,
  first_name text, last_name text, status text default 'active');
create table public.table_sessions (id uuid primary key default gen_random_uuid(),
  table_id uuid not null, opened_by uuid not null, opened_at timestamptz default now(),
  closed_at timestamptz, origin public.order_origin default 'dine_in',
  waiter_user_id uuid, people_count integer default 1, business_id uuid,
  opened_by_employee_id uuid);
create table public.orders (id uuid primary key default gen_random_uuid(),
  session_id uuid not null, status text default 'open', closed_at timestamptz);
create table public.order_items (id uuid primary key default gen_random_uuid(),
  order_id uuid, product_name text, qty numeric default 1, subtotal numeric default 0,
  created_by_employee_id uuid);

create table public.permissions (id uuid primary key default gen_random_uuid(), code text unique not null,
  name text, module text, description text);
create table public.roles (id uuid primary key default gen_random_uuid(), name text, is_system boolean default false);
create table public.role_permissions (role_id uuid, permission_id uuid, allow boolean default true,
  primary key (role_id, permission_id));
insert into public.roles (name, is_system) values
  ('owner', true), ('admin', true), ('manager', true), ('cashier', true), ('waiter', true);

create table public.memberships (user_id uuid, business_id uuid, role text);
insert into public.memberships values
  ('99999999-9999-9999-9999-999999999999','11111111-1111-1111-1111-111111111111','owner'),
  ('88888888-8888-8888-8888-888888888888','11111111-1111-1111-1111-111111111111','waiter'),
  ('77777777-7777-7777-7777-777777777777','11111111-1111-1111-1111-111111111111','cashier');

create function public.user_business_role(p_user uuid, p_business uuid) returns text
language sql stable as $$ select role from public.memberships where user_id=p_user and business_id=p_business $$;
create function public.user_has_business_access(p_user uuid, p_business uuid) returns boolean
language sql stable as $$ select exists (select 1 from public.memberships where user_id=p_user and business_id=p_business) $$;
create function public.user_has_business_permission(p_business uuid, p_code text) returns boolean
language sql stable as $$ select false $$;

create schema test;
create function test.chk(p_label text, p_ok boolean, p_detail text default '') returns void language plpgsql as $$
begin
  if p_ok is not true then raise exception 'FALLA % %', p_label, coalesce(p_detail, ''); end if;
  raise notice 'ok  %', p_label;
end $$;

-- Reproduce la atribución REAL del reporte (fn_sales_by_waiter,
-- 20260919_0004): por ÍTEM, coalesce(item, dueño de la mesa).
create function test.sales_by_waiter(p_emp uuid) returns numeric
language sql stable as $$
  select coalesce(sum(oi.subtotal), 0)
    from public.order_items oi
    join public.orders o on o.id = oi.order_id
    join public.table_sessions ts on ts.id = o.session_id
   where coalesce(oi.created_by_employee_id, ts.opened_by_employee_id) = p_emp
$$;

-- Nombre del salón/precuenta: opened_by_employee_id manda (v_zone_table_status).
create function test.salon_name(p_session uuid) returns text
language sql stable as $$
  select coalesce(
    (select e.first_name from public.employees e where e.id = ts.opened_by_employee_id),
    (select e.first_name from public.employees e
      where e.user_id = ts.waiter_user_id and e.business_id = ts.business_id limit 1))
    from public.table_sessions ts where ts.id = p_session
$$;

insert into public.businesses values ('11111111-1111-1111-1111-111111111111','Bar');
insert into public.zones values ('22222222-2222-2222-2222-222222222222','11111111-1111-1111-1111-111111111111','Salon');
insert into public.dining_tables values
  ('33333333-3333-3333-3333-333333333333','22222222-2222-2222-2222-222222222222','12','occupied');
insert into public.employees (id, business_id, user_id, first_name, last_name) values
  ('e0000000-0000-0000-0000-00000000000a','11111111-1111-1111-1111-111111111111',
   '88888888-8888-8888-8888-888888888888','Claudia','Perez'),
  ('e0000000-0000-0000-0000-00000000000b','11111111-1111-1111-1111-111111111111',
   null,'Pedro','Gomez'),
  ('e0000000-0000-0000-0000-00000000000c','11111111-1111-1111-1111-111111111111',
   '77777777-7777-7777-7777-777777777777','Ana','Cajera');
-- Mesero de OTRO negocio, para probar el cerrojo.
insert into public.businesses values ('44444444-4444-4444-4444-444444444444','Otro');
insert into public.employees (id, business_id, first_name, last_name) values
  ('e0000000-0000-0000-0000-0000000000ff','44444444-4444-4444-4444-444444444444','Ajeno','Externo');
-- Mesero inactivo.
insert into public.employees (id, business_id, first_name, last_name, status) values
  ('e0000000-0000-0000-0000-0000000000dd','11111111-1111-1111-1111-111111111111','Ex','Mesero','inactive');

-- Arma una mesa abierta con items. p_author null = item sin autor propio.
create function test.seed_session(p_opener_emp uuid, p_opened_by uuid)
returns uuid language plpgsql as $$
declare v_s uuid; v_o uuid;
begin
  insert into public.table_sessions (table_id, opened_by, waiter_user_id, business_id,
    opened_by_employee_id)
  values ('33333333-3333-3333-3333-333333333333', p_opened_by, p_opened_by,
          '11111111-1111-1111-1111-111111111111', p_opener_emp)
  returning id into v_s;
  insert into public.orders (session_id) values (v_s) returning id into v_o;
  return v_s;
end $$;

create function test.add_item(p_session uuid, p_name text, p_amount numeric, p_author uuid)
returns void language plpgsql as $$
declare v_o uuid;
begin
  select id into v_o from public.orders where session_id = p_session limit 1;
  insert into public.order_items (order_id, product_name, subtotal, created_by_employee_id)
  values (v_o, p_name, p_amount, p_author);
end $$;
SQL
ok "esquema mínimo + atribución real del reporte"

echo "== Migración real 20260924_0001"
run "aplica"          -f "$M/20260924_0001_reassign_table_waiter.sql"
run "es idempotente"  -f "$M/20260924_0001_reassign_table_waiter.sql"

echo "== Comportamiento"
run "casos" <<'SQL'
do $$
declare
  v_s uuid; v_res jsonb; v_msg text;
  CLAUDIA uuid := 'e0000000-0000-0000-0000-00000000000a';
  PEDRO   uuid := 'e0000000-0000-0000-0000-00000000000b';
  ANA     uuid := 'e0000000-0000-0000-0000-00000000000c';
  AJENO   uuid := 'e0000000-0000-0000-0000-0000000000ff';
  INACT   uuid := 'e0000000-0000-0000-0000-0000000000dd';
begin
  -- ── 1. Lo ya consumido NO se mueve; la mesa sí ──
  v_s := test.seed_session(CLAUDIA, '88888888-8888-8888-8888-888888888888');
  perform test.add_item(v_s, 'Cerveza', 1000, CLAUDIA);   -- digitado por Claudia
  perform test.add_item(v_s, 'Ron',     2400, null);      -- sin autor: cuelga del dueño
  perform test.chk('1 antes: Claudia tiene los 3,400',
                   test.sales_by_waiter(CLAUDIA) = 3400,
                   test.sales_by_waiter(CLAUDIA)::text);

  v_res := public.fn_reassign_table_waiter(v_s, PEDRO, 'cambio de turno');

  perform test.chk('1 Claudia CONSERVA lo que ya se consumio',
                   test.sales_by_waiter(CLAUDIA) = 3400,
                   test.sales_by_waiter(CLAUDIA)::text);
  perform test.chk('1 Pedro arranca en 0',
                   test.sales_by_waiter(PEDRO) = 0,
                   test.sales_by_waiter(PEDRO)::text);
  perform test.chk('1 la mesa ya es de Pedro',
                   (select opened_by_employee_id from public.table_sessions where id=v_s) = PEDRO);
  perform test.chk('1 el salon y la precuenta dicen Pedro',
                   test.salon_name(v_s) = 'Pedro', test.salon_name(v_s));
  perform test.chk('1 congelo el item sin autor',
                   (v_res->>'items_frozen')::int = 1, v_res::text);
  perform test.chk('1 lo reporta como cambiado', (v_res->>'changed')::boolean, v_res::text);

  -- ── 2. Lo que Pedro agregue DESPUES sí es de Pedro ──
  perform test.add_item(v_s, 'Whisky', 5000, PEDRO);
  perform test.chk('2 lo nuevo es de Pedro', test.sales_by_waiter(PEDRO) = 5000,
                   test.sales_by_waiter(PEDRO)::text);
  perform test.chk('2 Claudia sigue igual', test.sales_by_waiter(CLAUDIA) = 3400,
                   test.sales_by_waiter(CLAUDIA)::text);

  -- ── 3. Un item nuevo SIN autor ya cuelga de Pedro (es su mesa) ──
  perform test.add_item(v_s, 'Agua', 100, null);
  perform test.chk('3 lo nuevo sin autor cuelga del dueno nuevo',
                   test.sales_by_waiter(PEDRO) = 5100,
                   test.sales_by_waiter(PEDRO)::text);

  -- ── 4. Bitácora ──
  perform test.chk('4 quedo bitacora de quien a quien',
                   (select count(*) from public.table_session_waiter_changes
                     where session_id=v_s and from_employee_id=CLAUDIA and to_employee_id=PEDRO) = 1);
  perform test.chk('4 guarda el motivo',
                   (select reason from public.table_session_waiter_changes
                     where session_id=v_s limit 1) = 'cambio de turno');
  perform test.chk('4 guarda quien lo hizo',
                   (select changed_by from public.table_session_waiter_changes
                     where session_id=v_s limit 1) = '99999999-9999-9999-9999-999999999999');

  -- ── 5. Reasignar al mismo mesero no hace nada ──
  v_res := public.fn_reassign_table_waiter(v_s, PEDRO);
  perform test.chk('5 al mismo mesero no cambia nada',
                   (v_res->>'changed')::boolean is false, v_res::text);
  perform test.chk('5 y no ensucia la bitacora',
                   (select count(*) from public.table_session_waiter_changes where session_id=v_s) = 1);

  -- ── 6. Mesa abierta SIN PIN (por la cajera): congela en su empleado ──
  v_s := test.seed_session(null, '77777777-7777-7777-7777-777777777777');
  perform test.add_item(v_s, 'Picadera', 800, null);
  v_res := public.fn_reassign_table_waiter(v_s, PEDRO, 'la tomo la cajera');
  perform test.chk('6 lo consumido queda en la cajera, no en Pedro',
                   (select created_by_employee_id from public.order_items oi
                     join public.orders o on o.id=oi.order_id
                    where o.session_id=v_s limit 1) = ANA);
  perform test.chk('6 la mesa pasa a Pedro',
                   (select opened_by_employee_id from public.table_sessions where id=v_s) = PEDRO);

  -- ── 7. Rechazos ──
  v_s := test.seed_session(CLAUDIA, '88888888-8888-8888-8888-888888888888');

  begin
    perform public.fn_reassign_table_waiter(v_s, AJENO);
    perform test.chk('7 debio rechazar mesero de otro negocio', false);
  exception when others then
    get stacked diagnostics v_msg = message_text;
    perform test.chk('7 rechaza un mesero de otro negocio',
                     v_msg like 'EMPLOYEE_NOT_IN_BUSINESS%', v_msg);
  end;

  begin
    perform public.fn_reassign_table_waiter(v_s, INACT);
    perform test.chk('7 debio rechazar mesero inactivo', false);
  exception when others then
    get stacked diagnostics v_msg = message_text;
    perform test.chk('7 rechaza un mesero inactivo',
                     v_msg like 'EMPLOYEE_NOT_IN_BUSINESS%', v_msg);
  end;

  begin
    perform public.fn_reassign_table_waiter(gen_random_uuid(), PEDRO);
    perform test.chk('7 debio rechazar sesion inexistente', false);
  exception when others then
    get stacked diagnostics v_msg = message_text;
    perform test.chk('7 rechaza una sesion que no existe', v_msg like 'SESSION_NOT_FOUND%', v_msg);
  end;

  -- Mesa ya cobrada.
  update public.table_sessions set closed_at = now() where id = v_s;
  begin
    perform public.fn_reassign_table_waiter(v_s, PEDRO);
    perform test.chk('7 debio rechazar mesa cerrada', false);
  exception when others then
    get stacked diagnostics v_msg = message_text;
    perform test.chk('7 rechaza una mesa ya cobrada', v_msg like 'SESSION_CLOSED%', v_msg);
  end;
  update public.table_sessions set closed_at = null where id = v_s;

  -- ── 8. Un mesero no puede reasignarse mesas solo ──
  perform set_config('test.uid', '88888888-8888-8888-8888-888888888888', true);
  begin
    perform public.fn_reassign_table_waiter(v_s, PEDRO);
    perform test.chk('8 debio rechazar al mesero', false);
  exception when others then
    get stacked diagnostics v_msg = message_text;
    perform test.chk('8 un mesero no puede reasignar mesas', v_msg like 'REASSIGN_DENIED%', v_msg);
  end;

  -- La cajera SÍ puede (es quien anda en el salón resolviendo).
  perform set_config('test.uid', '77777777-7777-7777-7777-777777777777', true);
  v_res := public.fn_reassign_table_waiter(v_s, PEDRO, 'la cajera resuelve');
  perform test.chk('8 la cajera si puede', (v_res->>'changed')::boolean, v_res::text);
  perform set_config('test.uid', '', true);

  -- ── 9. Congelar una mesa NO toca los items de otra ──
  -- Dos mesas con items sin autor; se reasigna solo la primera.
  declare
    v_a uuid; v_b uuid;
  begin
    v_a := test.seed_session(CLAUDIA, '88888888-8888-8888-8888-888888888888');
    v_b := test.seed_session(CLAUDIA, '88888888-8888-8888-8888-888888888888');
    perform test.add_item(v_a, 'Mesa A sin autor', 500, null);
    perform test.add_item(v_b, 'Mesa B sin autor', 700, null);

    perform public.fn_reassign_table_waiter(v_a, PEDRO, 'solo la A');

    perform test.chk('9 la mesa reasignada congelo SU item',
                     (select oi.created_by_employee_id from public.order_items oi
                        join public.orders o on o.id = oi.order_id
                       where o.session_id = v_a limit 1) = CLAUDIA);
    perform test.chk('9 la otra mesa quedo intacta',
                     (select oi.created_by_employee_id from public.order_items oi
                        join public.orders o on o.id = oi.order_id
                       where o.session_id = v_b limit 1) is null);
    perform test.chk('9 y la otra mesa sigue siendo de Claudia',
                     (select opened_by_employee_id from public.table_sessions where id = v_b) = CLAUDIA);
  end;

  -- ── 10. El permiso quedó en el catálogo (si no, es decorativo) ──
  perform test.chk('10 el permiso existe en el catalogo',
                   (select count(*) from public.permissions
                     where code='ventas.mesas.reasignar_mesero') = 1);
  perform test.chk('10 lo tienen owner/admin/manager/cashier',
                   (select count(*) from public.role_permissions rp
                     join public.roles r on r.id = rp.role_id
                     join public.permissions p on p.id = rp.permission_id
                    where p.code='ventas.mesas.reasignar_mesero' and r.is_system) = 4);
end $$;
SQL

echo
if [ "$FAIL" = 0 ]; then echo "TODO OK"; else echo "HAY FALLAS"; fi
exit $FAIL
