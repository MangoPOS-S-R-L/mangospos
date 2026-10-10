#!/usr/bin/env bash
# Postgres local desechable; no toca ninguna base remota.
# Prueba 20261010_0001: el rol cajero recibe el flujo de mesa sin pisar lo que
# un dueño quitó a propósito, y los negocios nuevos nacen con él.
set -euo pipefail
REPO=$(cd "$(dirname "$0")/../.." && pwd)
M=$REPO/supabase/migrations
PG=${PG_BIN:-/opt/homebrew/opt/postgresql@15/bin}
PORT=${PG_PORT:-55454}
WORK=${1:-$(mktemp -d)}
D=$WORK/pg_cashier_perms
mkdir -p "$D"
"$PG/initdb" -D "$D/data" -U postgres --auth=trust >/dev/null
"$PG/pg_ctl" -D "$D/data" -o "-p $PORT -c listen_addresses=127.0.0.1 -c unix_socket_directories=''" -l "$D/log" start -w >/dev/null
trap '"$PG/pg_ctl" -D "$D/data" stop -m fast >/dev/null 2>&1' EXIT
Q() { "$PG/psql" -h 127.0.0.1 -p "$PORT" -U postgres -X -q -v ON_ERROR_STOP=1 "$@"; }

Q <<'SQL'
create role anon; create role authenticated; create role service_role;
create table public.permissions(id uuid primary key default gen_random_uuid(), code text not null unique,
  name text not null, module text not null, description text);
create table public.roles(id uuid primary key default gen_random_uuid(), business_id uuid not null,
  name text not null, description text, is_system boolean default false);
create table public.role_permissions(role_id uuid not null references public.roles(id) on delete cascade,
  permission_id uuid not null references public.permissions(id) on delete cascade,
  allow boolean default true, primary key (role_id, permission_id));
create function public.test_assert(ok boolean, message text) returns void language plpgsql as $$
begin
  if not coalesce(ok, false) then raise exception 'FAIL: %', message; end if;
  raise notice 'ok: %', message;
end $$;
create function public.test_perms(p_business uuid, p_role text) returns table(code text, allow boolean)
language sql as $$
  select p.code, rp.allow from public.roles r
  join public.role_permissions rp on rp.role_id = r.id
  join public.permissions p on p.id = rp.permission_id
  where r.business_id = p_business and r.name = p_role $$;
-- Catálogo previo: algunos códigos existen (uno con nombre propio), otros no.
insert into permissions(code, name, module) values
  ('ventas.mesas.acceso', 'Acceso a mesas', 'restaurant'),
  ('ventas.orden.ver_total', 'Ver total', 'restaurant'),
  ('ventas.orden.agregar_item', 'Nombre puesto a mano', 'restaurant'),
  ('ventas.mesas.liberar', 'Liberar mesa', 'operations'),
  ('ventas.orden.anular', 'Anular orden', 'restaurant');
-- Negocio A: cajero con lo de siempre y «liberar» quitado a propósito; gerente aparte.
insert into roles(id, business_id, name) values
  ('a0000000-0000-0000-0000-0000000000c1', 'b0000000-0000-0000-0000-00000000000a', 'cashier'),
  ('a0000000-0000-0000-0000-0000000000e1', 'b0000000-0000-0000-0000-00000000000a', 'manager'),
  ('a0000000-0000-0000-0000-0000000000c2', 'b0000000-0000-0000-0000-00000000000b', 'cashier');
insert into role_permissions(role_id, permission_id, allow)
select 'a0000000-0000-0000-0000-0000000000c1', id, code <> 'ventas.mesas.liberar'
from permissions where code in ('ventas.mesas.acceso', 'ventas.orden.ver_total', 'ventas.mesas.liberar');
insert into role_permissions(role_id, permission_id)
select 'a0000000-0000-0000-0000-0000000000e1', id from permissions where code = 'ventas.orden.anular';
SQL
Q -f "$M/20261010_0001_cashier_default_permissions.sql"
Q -f "$M/20261010_0001_cashier_default_permissions.sql"

Q <<'SQL'
do $$
declare
  a uuid := 'b0000000-0000-0000-0000-00000000000a';
  b uuid := 'b0000000-0000-0000-0000-00000000000b';
  c uuid := 'b0000000-0000-0000-0000-00000000000c';
  wanted text[] := public.fn_cashier_default_permission_codes();
begin
  perform test_assert(cardinality(wanted) = 17, 'exactly 17 default cashier permissions');
  perform test_assert((select count(*) from permissions where code = any(wanted)) = 17,
    'missing catalog codes are created');
  perform test_assert((select name from permissions where code = 'ventas.orden.agregar_item')
    = 'Nombre puesto a mano', 'an existing catalog name is not overwritten');
  perform test_assert((select count(*) from test_perms(a, 'cashier') t
      where t.code = any(wanted) and t.allow) = 16
    and (select t.allow from test_perms(a, 'cashier') t where t.code = 'ventas.mesas.liberar') = false,
    'existing cashier gets the 16 it lacked; the permission removed on purpose stays removed');
  perform test_assert((select count(*) from test_perms(a, 'cashier') t
      where t.code in ('ventas.mesas.acceso', 'ventas.orden.ver_total') and t.allow) = 2,
    'what the cashier already had is kept');
  perform test_assert(not exists (select 1 from test_perms(a, 'cashier') t
      where t.code in ('ventas.orden.anular', 'ventas.orden.descuento_aplicar', 'ventas.orden.reabrir')),
    'no void, discount or reopen for the cashier');
  perform test_assert((select count(*) from test_perms(a, 'manager')) = 1,
    'other roles are untouched');
  perform test_assert((select count(*) from test_perms(b, 'cashier') t where t.allow) = 17,
    'a cashier role with nothing gets all 17');

  -- Negocio nuevo: el alta crea los roles y después su propio role_permissions.
  insert into roles(business_id, name) values (c, 'cashier'), (c, 'waiter');
  insert into role_permissions(role_id, permission_id, allow)
  select r.id, p.id, true from roles r join permissions p on p.code = 'ventas.mesas.acceso'
  where r.business_id = c and r.name = 'cashier'
  on conflict do nothing;
  perform test_assert((select count(*) from test_perms(c, 'cashier') t
      where t.code = any(wanted) and t.allow) = 17,
    'a new business cashier role is born with the 17');
  perform test_assert((select count(*) from test_perms(c, 'waiter')) = 0,
    'the trigger only acts on the cashier role');
end $$;
SQL

Q -f "$M/20261010_0001_cashier_default_permissions_ROLLBACK.sql"
Q <<'SQL'
do $$ begin
  insert into roles(business_id, name) values ('b0000000-0000-0000-0000-00000000000d', 'cashier');
  perform test_assert((select count(*) from test_perms('b0000000-0000-0000-0000-00000000000d', 'cashier')) = 0,
    'rollback removes the trigger for new businesses');
  perform test_assert((select count(*) from test_perms('b0000000-0000-0000-0000-00000000000b', 'cashier')) = 17,
    'rollback keeps permissions already granted');
end $$;
SQL
echo "Cashier default permissions: OK"
