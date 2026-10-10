#!/usr/bin/env bash
# Postgres 15 desechable; no toca ninguna base remota.
# Prueba 20261010_0010 (T07): dos conciliaciones de inventario de la MISMA
# orden a la vez no asientan dos veces la misma diferencia. Usa el cuerpo REAL
# de consume_inventory_from_order (20260915_0002, UNIFICADA). Primero muestra
# el doble descuento SIN el candado y después que el candado lo evita.
set -euo pipefail
REPO=$(cd "$(dirname "$0")/../.." && pwd)
M=$REPO/supabase/migrations
PG=${PG_BIN:-/opt/homebrew/opt/postgresql@15/bin}
PORT=${PG_PORT:-55473}
WORK=${1:-$(mktemp -d)}
D=$WORK/pg_consume_lock
mkdir -p "$D"
"$PG/initdb" -D "$D/data" -U postgres --auth=trust >/dev/null
"$PG/pg_ctl" -D "$D/data" -o "-p $PORT -c listen_addresses=127.0.0.1 -c unix_socket_directories=''" -l "$D/log" start -w >/dev/null
trap '"$PG/pg_ctl" -D "$D/data" stop -m fast >/dev/null 2>&1' EXIT
Q() { "$PG/psql" -h 127.0.0.1 -p "$PORT" -U postgres -X -q -v ON_ERROR_STOP=1 "$@"; }

Q <<'SQL'
create role anon; create role authenticated; create role service_role;
create schema test;
create type public.order_status as enum ('open', 'closed', 'paid', 'void');
create type public.movement_type as enum ('purchase', 'sale', 'adjustment');
create table public.businesses (id uuid primary key, business_name text);
create table public.business_settings (business_id uuid primary key, inventory_mode text);
create table public.warehouses (id uuid primary key, business_id uuid, name text,
  is_main boolean default false, is_active boolean default true, created_at timestamptz,
  shows_in_pos boolean default false);
create table public.inventory_items (id uuid primary key, business_id uuid, name text);
create table public.inventory_stock (item_id uuid, warehouse_id uuid, quantity numeric default 0,
  primary key (item_id, warehouse_id));
create table public.inventory_movements (id bigserial primary key, business_id uuid, warehouse_id uuid,
  item_id uuid, movement_type public.movement_type, quantity numeric, reference_id uuid,
  reference_type text, notes text, created_at timestamptz default now());
create table public.menu_items (id uuid primary key, business_id uuid, name text,
  item_type text default 'product', is_inventory_tracked boolean default false, inventory_item_id uuid);
create table public.recipes (id uuid primary key default gen_random_uuid(), menu_item_id uuid,
  inventory_item_id uuid);
create table public.recipe_ingredients (id uuid primary key default gen_random_uuid(), recipe_id uuid,
  inventory_item_id uuid, quantity numeric, unit text);
create table public.table_sessions (id uuid primary key, business_id uuid);
create table public.orders (id uuid primary key, session_id uuid, status text default 'open',
  status_ext public.order_status default 'open');
create table public.order_items (id uuid primary key default gen_random_uuid(), order_id uuid,
  product_id uuid, qty numeric, quantity int, status text default 'active');
create table public.order_item_modifiers (id uuid primary key default gen_random_uuid(), item_id uuid,
  name text, qty numeric default 1, menu_item_id uuid, modifier_id uuid);
create table public.modifiers (id uuid primary key, name text);
create table public.modifier_ingredients (id uuid primary key default gen_random_uuid(),
  modifier_id uuid, inventory_item_id uuid, quantity numeric, unit text);
create function public.fn_resolve_area_warehouse(p_business_id uuid, p_menu_item_id uuid)
returns uuid language sql stable as $$ select null::uuid $$;
insert into public.businesses values ('b0000000-0000-0000-0000-000000000001', 'Test');
insert into public.business_settings values ('b0000000-0000-0000-0000-000000000001', 'advanced');
insert into public.warehouses values ('a0000000-0000-0000-0000-000000000001',
  'b0000000-0000-0000-0000-000000000001', 'MAIN', true, true, '2020-01-01', true);
insert into public.inventory_items values ('c0000000-0000-0000-0000-000000000003',
  'b0000000-0000-0000-0000-000000000001', 'REFRESCO');
insert into public.menu_items values ('d0000000-0000-0000-0000-000000000002',
  'b0000000-0000-0000-0000-000000000001', 'REFRESCO', 'product', true, 'c0000000-0000-0000-0000-000000000003');
insert into public.table_sessions values ('f0000000-0000-0000-0000-000000000001',
  'b0000000-0000-0000-0000-000000000001');
create function test.sale_count(p_order uuid) returns bigint language sql stable as $$
  select count(*) from public.inventory_movements
   where reference_id = p_order and movement_type = 'sale'
$$;
create function test.new_order(p_order uuid) returns void language sql as $$
  insert into public.orders (id, session_id) values (p_order, 'f0000000-0000-0000-0000-000000000001');
  insert into public.order_items (order_id, product_id, qty, quantity)
  values (p_order, 'd0000000-0000-0000-0000-000000000002', 1, 1);
$$;
SQL

python3 - "$M/20260915_0002_consume_unified.sql" "$D/consume.sql" <<'PY'
import sys
src, out = sys.argv[1], sys.argv[2]
s = open(src).read()
a = s.index('create or replace function public.consume_inventory_from_order(_order_id uuid)')
b = s.index('$function$;', a) + len('$function$;')
open(out, 'w').write(s[a:b] + '\n')
PY
Q -f "$D/consume.sql" >/dev/null

# Dos conciliaciones de la misma orden a la vez (KDS + cobro, por ejemplo).
race() {
  local order=$1
  Q -c "select test.new_order('$order')" >/dev/null
  Q -c "begin; select public.consume_inventory_from_order('$order'); select pg_sleep(1.5); commit;" >/dev/null &
  local first=$!
  sleep 0.4
  Q -c "begin; select public.consume_inventory_from_order('$order'); commit;" >/dev/null
  wait "$first"
  Q -t -A -c "select test.sale_count('$order')"
}

n=$(race 00000000-0000-0000-0000-0000000000b1)
[ "$n" = "2" ] || { echo "FAIL: expected the double deduction without the lock (got $n)"; exit 1; }
echo "ok: without the lock, two concurrent reconciliations deduct the same line twice (the bug)"

Q -f "$M/20261010_0010_consume_inventory_order_lock.sql"
Q -f "$M/20261010_0010_consume_inventory_order_lock.sql"
echo "ok: 20261010_0010 applies and re-applies"

n=$(race 00000000-0000-0000-0000-0000000000b2)
[ "$n" = "1" ] || { echo "FAIL: concurrent reconciliations still deduct twice ($n)"; exit 1; }
echo "ok: with the lock, the second reconciliation waits and finds nothing left to deduct"

Q -c "select public.consume_inventory_from_order('00000000-0000-0000-0000-0000000000b2')" >/dev/null
n=$(Q -t -A -c "select test.sale_count('00000000-0000-0000-0000-0000000000b2')")
[ "$n" = "1" ] || { echo "FAIL: a sequential repeat deducted again ($n)"; exit 1; }
echo "ok: a sequential repeat (print/kitchen/payment retry) still deducts nothing"

r=$(Q -t -A -c "select pg_get_functiondef('public.consume_inventory_from_order(uuid)'::regprocedure) like '%UNIFICADA 20260915_0002%'")
[ "$r" = "t" ] || { echo "FAIL: the wrapper lost the marker old guards look for"; exit 1; }
r=$(Q -t -A -c "select has_function_privilege('authenticated', 'public.consume_inventory_from_order(uuid)', 'execute')
  and not has_function_privilege('authenticated', 'public.consume_inventory_from_order_unlocked(uuid)', 'execute')")
[ "$r" = "t" ] || { echo "FAIL: privileges"; exit 1; }
echo "ok: the wrapper keeps the marker; only the wrapper is executable"

# Si alguien reemplaza la función después, re-aplicar se detiene.
Q -c "create or replace function public.consume_inventory_from_order(_order_id uuid) returns void
  language plpgsql as \$\$ begin null; end \$\$;" >/dev/null
if Q -f "$M/20261010_0010_consume_inventory_order_lock.sql" >"$D/out.txt" 2>&1; then
  echo "FAIL: re-applying put the old body back over a newer one"; exit 1
fi
grep -q "revisar a mano" "$D/out.txt" || { cat "$D/out.txt"; echo "FAIL: expected the guard"; exit 1; }
echo "ok: re-applying over a newer body stops instead of restoring the old one"
Q -f "$D/consume.sql" >/dev/null
Q -c "drop function public.consume_inventory_from_order_unlocked(uuid)" >/dev/null
Q -f "$M/20261010_0010_consume_inventory_order_lock.sql" >/dev/null

Q -f "$M/20261010_0010_consume_inventory_order_lock_ROLLBACK.sql"
r=$(Q -t -A -c "select to_regprocedure('public.consume_inventory_from_order_unlocked(uuid)') is null
  and pg_get_functiondef('public.consume_inventory_from_order(uuid)'::regprocedure) not like '%advisory%'")
[ "$r" = "t" ] || { echo "FAIL: rollback"; exit 1; }
echo "ok: rollback gives the live function its name back"
echo "Consume inventory order lock: OK"
