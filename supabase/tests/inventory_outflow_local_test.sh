#!/usr/bin/env bash
# =============================================================================
# Prueba LOCAL de Salidas / Mermas (20260928_0001, revisión 2026-09-30).
# Postgres 15 DESECHABLE con el esquema mínimo y la fn_inventory_record_movement
# REAL (20260516_0008); corre el archivo real del repo. No toca ninguna base.
#
#   bash supabase/tests/inventory_outflow_local_test.sh [carpeta_trabajo]
# Variables: PG_BIN (default homebrew postgresql@15), PG_PORT (default 55445).
# =============================================================================
set -u
REPO=$(cd "$(dirname "$0")/../.." && pwd)
M=$REPO/supabase/migrations
PG=${PG_BIN:-/opt/homebrew/opt/postgresql@15/bin}
PORT=${PG_PORT:-55445}
WORK=${1:-$(mktemp -d)}
D=$WORK/pg_outflow
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
create function auth.uid() returns uuid language sql stable as $$
  select coalesce(nullif(current_setting('test.uid', true), ''),
                  '99999999-9999-9999-9999-999999999999')::uuid $$;
create type public.movement_type as enum ('purchase','sale','adjustment','transfer_in','transfer_out',
  'waste','return','production_in','production_out');
create table public.memberships (user_id uuid, business_id uuid, role text);
insert into public.memberships values
  ('99999999-9999-9999-9999-999999999999','11111111-1111-1111-1111-111111111111','manager'),
  ('88888888-8888-8888-8888-888888888888','11111111-1111-1111-1111-111111111111','cashier');
create function public.user_business_role(p_user uuid, p_business uuid) returns text language sql stable as $$
  select role from public.memberships where user_id = p_user and business_id = p_business $$;
create table public.inventory_items (id uuid primary key, business_id uuid, name text, cost numeric, unit text);
create table public.warehouses (id uuid primary key, business_id uuid, name text, is_active boolean default true);
create table public.inventory_stock (warehouse_id uuid, item_id uuid, quantity numeric, last_updated timestamptz,
  primary key (warehouse_id, item_id));
create table public.inventory_movements (id uuid primary key default gen_random_uuid(), business_id uuid,
  warehouse_id uuid, item_id uuid, movement_type public.movement_type, quantity numeric(14,4),
  cost_per_unit numeric, reference_id uuid, reference_type text, notes text, created_by uuid,
  created_at timestamptz default now());
-- reason_code con el CHECK VIEJO (20260513_0017, sin 'cleaning').
alter table public.inventory_movements add column reason_code text;
alter table public.inventory_movements add constraint inventory_movements_reason_code_check
  check (reason_code is null or reason_code in
    ('physical_count','breakage','expiration','theft','donation','correction','other'));

insert into public.inventory_items values
  ('33333333-3333-3333-3333-333333333333','11111111-1111-1111-1111-111111111111','Leche',50,'l'),
  ('44444444-4444-4444-4444-444444444444','11111111-1111-1111-1111-111111111111','Hielo',null,'kg');
insert into public.warehouses values
  ('22222222-2222-2222-2222-222222222222','11111111-1111-1111-1111-111111111111','Principal',true);
insert into public.inventory_stock values
  ('22222222-2222-2222-2222-222222222222','33333333-3333-3333-3333-333333333333',10,now());

create schema test;
create function test.chk(p_label text, p_ok boolean, p_detail text default '') returns void language plpgsql as $$
begin
  if p_ok is not true then raise exception 'FALLA % %', p_label, coalesce(p_detail, ''); end if;
  raise notice 'ok  %', p_label;
end $$;
create function test.stock() returns numeric language sql as $$
  select quantity from public.inventory_stock
   where item_id = '33333333-3333-3333-3333-333333333333' $$;

-- La primera versión (7 parámetros), como si ya se hubiera aplicado.
create function public.fn_inventory_record_outflow(
  p_business_id uuid, p_warehouse_id uuid, p_item_id uuid, p_quantity numeric,
  p_reason_code text, p_notes text default null, p_cost_per_unit numeric default null)
returns jsonb language sql as $$ select '{}'::jsonb $$;
SQL
# Trigger real de stock (20260308_0016) + fn_inventory_record_movement real (20260516_0008).
sed -n 8,41p "$M/20260308_0016_inventory_mvp.sql" | Q >/dev/null || bad "trigger de stock"
sed -n 201,283p "$M/20260516_0008_production_orders.sql" | Q >/dev/null || bad "fn_inventory_record_movement"
ok "esquema mínimo + funciones reales"

echo "== Migración real 20260928_0001"
run "aplica sobre la versión de 7 parámetros" -f "$M/20260928_0001_inventory_outflow_reason.sql"
run "es idempotente"                          -f "$M/20260928_0001_inventory_outflow_reason.sql"

echo "== Comportamiento"
run "casos" <<'SQL'
do $$
declare
  v_biz uuid := '11111111-1111-1111-1111-111111111111';
  v_wh  uuid := '22222222-2222-2222-2222-222222222222';
  v_it  uuid := '33333333-3333-3333-3333-333333333333';
  v_it2 uuid := '44444444-4444-4444-4444-444444444444';
  v_key uuid := 'aaaaaaaa-0000-0000-0000-000000000001';
  v_res jsonb; v_res2 jsonb; v_msg text;
begin
  perform test.chk('1 queda UNA sola firma (8 parámetros)',
    (select count(*) from pg_proc where proname = 'fn_inventory_record_outflow') = 1
    and to_regprocedure('public.fn_inventory_record_outflow(uuid,uuid,uuid,numeric,text,text,numeric,uuid)') is not null);

  -- ── 2. Salida con llave: resta, guarda motivo, costo del insumo y llave ──
  v_res := public.fn_inventory_record_outflow(v_biz, v_wh, v_it, 2.5, 'expiration',
             'Vencido — nevera 2', null, v_key);
  perform test.chk('2 resta 2.5', test.stock() = 7.5, test.stock()::text);
  perform test.chk('2 motivo, costo del insumo y llave guardados',
    exists (select 1 from public.inventory_movements
             where id = (v_res->>'id')::uuid and movement_type = 'waste' and quantity = -2.5
               and reason_code = 'expiration' and cost_per_unit = 50
               and reference_type = 'manual_outflow' and reference_id = v_key));
  perform test.chk('2 no es replay', (v_res->>'replayed')::boolean = false, v_res::text);

  -- ── 3. Reintento con la MISMA llave (respuesta perdida): no resta otra vez ──
  v_res2 := public.fn_inventory_record_outflow(v_biz, v_wh, v_it, 2.5, 'expiration',
              'Vencido — nevera 2', null, v_key);
  perform test.chk('3 replay', (v_res2->>'replayed')::boolean, v_res2::text);
  perform test.chk('3 devuelve el mismo movimiento', v_res2->>'id' = v_res->>'id');
  perform test.chk('3 stock intacto', test.stock() = 7.5, test.stock()::text);
  perform test.chk('3 un solo movimiento con esa llave',
    (select count(*) from public.inventory_movements where reference_id = v_key) = 1);

  -- ── 4. Costo explícito se respeta ──
  v_res := public.fn_inventory_record_outflow(v_biz, v_wh, v_it, 1, 'breakage', 'Rotura', 42, gen_random_uuid());
  perform test.chk('4 costo de la app', (select cost_per_unit from public.inventory_movements
                                          where id = (v_res->>'id')::uuid) = 42);

  -- ── 5. Insumo sin costo: queda NULL (no inventa un 0) ──
  v_res := public.fn_inventory_record_outflow(v_biz, v_wh, v_it2, 1, 'breakage', null, null, null);
  perform test.chk('5 sin costo conocido queda NULL', (select cost_per_unit from public.inventory_movements
                                                        where id = (v_res->>'id')::uuid) is null);

  -- ── 6. Sin llave (app vieja): funciona igual que antes ──
  v_res := public.fn_inventory_record_outflow(v_biz, v_wh, v_it, 1, 'theft', 'Faltante', null);
  perform test.chk('6 sin llave resta', test.stock() = 5.5, test.stock()::text);

  -- ── 7. 'cleaning' con el CHECK viejo: la salida queda, el motivo va en la nota ──
  v_res := public.fn_inventory_record_outflow(v_biz, v_wh, v_it, 0.5, 'cleaning', 'Limpieza', null, gen_random_uuid());
  perform test.chk('7 resta aunque el CHECK no conozca el motivo', test.stock() = 5, test.stock()::text);
  perform test.chk('7 reason_code NULL, costo sí', (select reason_code is null and cost_per_unit = 50
                                                     from public.inventory_movements where id = (v_res->>'id')::uuid));

  -- ── 8. Motivo que no es salida ──
  begin
    perform public.fn_inventory_record_outflow(v_biz, v_wh, v_it, 1, 'other', null, null, null);
    perform test.chk('8 debió fallar', false);
  exception when others then v_msg := sqlerrm; end;
  perform test.chk('8 motivo inválido', v_msg like 'INVALID_OUTFLOW_REASON%', v_msg);

  -- ── 9. Cajero: sin acceso, y un replay NO le sirve para ver la salida ajena ──
  perform set_config('test.uid', '88888888-8888-8888-8888-888888888888', true);
  begin
    perform public.fn_inventory_record_outflow(v_biz, v_wh, v_it, 1, 'breakage', null, null, gen_random_uuid());
    perform test.chk('9 debió fallar', false);
  exception when others then v_msg := sqlerrm; end;
  perform set_config('test.uid', '', true);
  perform test.chk('9 rol exigido', v_msg like 'INVENTORY_ACCESS_DENIED%', v_msg);
  perform test.chk('9 stock intacto', test.stock() = 5, test.stock()::text);
end $$;
SQL

echo "== Permisos de ejecución"
run "authenticated sí, anon no" <<'SQL'
do $$ begin
  perform test.chk('authenticated puede ejecutar', has_function_privilege('authenticated',
    'public.fn_inventory_record_outflow(uuid,uuid,uuid,numeric,text,text,numeric,uuid)', 'execute'));
  perform test.chk('anon no puede ejecutar', not has_function_privilege('anon',
    'public.fn_inventory_record_outflow(uuid,uuid,uuid,numeric,text,text,numeric,uuid)', 'execute'));
end $$;
SQL

echo "== Rollback"
run "rollback aplica" -f "$M/20260928_0001_inventory_outflow_reason_ROLLBACK.sql"
run "no queda ninguna firma" <<'SQL'
do $$ begin
  perform test.chk('sin fn_inventory_record_outflow',
    (select count(*) from pg_proc where proname = 'fn_inventory_record_outflow') = 0);
end $$;
SQL

echo
if [ "$FAIL" = 0 ]; then echo "TODO OK"; else echo "HAY FALLAS"; fi
exit $FAIL
