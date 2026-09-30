#!/usr/bin/env bash
# =============================================================================
# Prueba LOCAL de «Gastables y menaje» (20260930_0051).
# Postgres 15 DESECHABLE con el esquema mínimo; corre los archivos reales:
# 0928_0001 (salida de 8 parámetros) y 0050 (rendimiento) como si ya
# estuvieran en producción, y encima la 0051.
#
#   bash supabase/tests/supplies_smallware_local_test.sh [carpeta_trabajo]
# Variables: PG_BIN (default homebrew postgresql@15), PG_PORT (default 55461).
# =============================================================================
set -u
REPO=$(cd "$(dirname "$0")/../.." && pwd)
M=$REPO/supabase/migrations
PG=${PG_BIN:-/opt/homebrew/opt/postgresql@15/bin}
PORT=${PG_PORT:-55461}
WORK=${1:-$(mktemp -d)}
D=$WORK/pg_supplies
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
# Espera que FALLE con un mensaje que contenga $2.
run_fails() {
  local label=$1 expect=$2; shift 2
  if OUT=$(Q "$@" 2>&1); then bad "$label (no falló)";
  elif echo "$OUT" | grep -q "$expect"; then ok "$label";
  else echo "$OUT" | grep ERROR; bad "$label (falló distinto)"; fi
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
  ('99999999-9999-9999-9999-999999999999','11111111-1111-1111-1111-111111111111','manager');
create function public.user_business_role(p_user uuid, p_business uuid) returns text language sql stable as $$
  select role from public.memberships where user_id = p_user and business_id = p_business $$;
create function public.user_has_business_access(p_user uuid, p_business uuid) returns boolean
language sql stable as $$ select exists (select 1 from public.memberships
  where user_id = p_user and business_id = p_business) $$;
create table public.inventory_items (id uuid primary key, business_id uuid, name text, sku text,
  unit text, cost numeric, min_stock numeric default 0, is_active boolean default true,
  item_classification text not null default 'simple');
-- El CHECK de 20260516_0003, + un valor que el repo NO conoce ('legacy_x'),
-- para probar que la 0051 lo conserva en vez de borrarlo.
alter table public.inventory_items add constraint inventory_items_classification_check
  check (item_classification in ('simple','raw_material','finished_product','combo','service','legacy_x'));
create table public.warehouses (id uuid primary key, business_id uuid, name text, is_active boolean default true);
create table public.inventory_stock (warehouse_id uuid, item_id uuid, quantity numeric, last_updated timestamptz,
  min_stock numeric, primary key (warehouse_id, item_id));
create table public.inventory_movements (id uuid primary key default gen_random_uuid(), business_id uuid,
  warehouse_id uuid, item_id uuid, movement_type public.movement_type, quantity numeric(14,4),
  cost_per_unit numeric, reference_id uuid, reference_type text, notes text, created_by uuid,
  created_at timestamptz default now());
-- reason_code con el CHECK de 20260923_0001 (con 'cleaning').
alter table public.inventory_movements add column reason_code text;
alter table public.inventory_movements add constraint inventory_movements_reason_code_check
  check (reason_code is null or reason_code in
    ('physical_count','breakage','expiration','cleaning','theft','donation','correction','other'));

create schema test;
create function test.chk(p_label text, p_ok boolean, p_detail text default '') returns void language plpgsql as $$
begin
  if p_ok is not true then raise exception 'FALLA % %', p_label, coalesce(p_detail, ''); end if;
  raise notice 'ok  %', p_label;
end $$;

insert into public.warehouses values
  ('a0000000-0000-0000-0000-000000000001','11111111-1111-1111-1111-111111111111','Principal',true),
  ('a0000000-0000-0000-0000-000000000002','11111111-1111-1111-1111-111111111111','Bar',true),
  ('a0000000-0000-0000-0000-000000000009','11111111-1111-1111-1111-111111111111','__IN_TRANSIT__',true);
insert into public.inventory_items (id, business_id, name, sku, unit, cost, min_stock) values
  ('c0000000-0000-0000-0000-000000000001','11111111-1111-1111-1111-111111111111','Leche','L-1','l',50,0),
  ('c0000000-0000-0000-0000-000000000002','11111111-1111-1111-1111-111111111111','Papel higiénico','P-1','rollo',20,48),
  ('c0000000-0000-0000-0000-000000000003','11111111-1111-1111-1111-111111111111','Copa de vino','C-1','u',150,120),
  ('c0000000-0000-0000-0000-000000000004','11111111-1111-1111-1111-111111111111','Cloro','CL-1','galón',90,4),
  ('c0000000-0000-0000-0000-000000000005','11111111-1111-1111-1111-111111111111','Olla 20 L','O-1','u',2500,2),
  ('c0000000-0000-0000-0000-000000000009','22222222-2222-2222-2222-222222222222','Ajeno','X','u',10,0);
SQL
# Trigger real de stock (20260308_0016) + fn_inventory_record_movement real (20260516_0008).
sed -n 8,41p "$M/20260308_0016_inventory_mvp.sql" | Q >/dev/null || bad "trigger de stock"
sed -n 201,283p "$M/20260516_0008_production_orders.sql" | Q >/dev/null || bad "fn_inventory_record_movement"
ok "esquema mínimo + funciones reales"

echo "== Lo que ya está en producción"
run "0928_0001 (salida de 8 parámetros)" -f "$M/20260928_0001_inventory_outflow_reason.sql"
run "0050 (rendimiento)"                 -f "$M/20260930_0050_inventory_yield_analysis.sql"

echo "== Antes de la 0051: la clase y el motivo nuevos se rechazan"
run_fails "gastable rechazado por el CHECK viejo" "inventory_items_classification_check" <<'SQL'
update public.inventory_items set item_classification = 'supply'
 where id = 'c0000000-0000-0000-0000-000000000002';
SQL

echo "== Migración real 20260930_0051"
run "aplica"         -f "$M/20260930_0051_supplies_and_smallware.sql"
run "es idempotente" -f "$M/20260930_0051_supplies_and_smallware.sql"

run "estructura" <<'SQL'
do $$ begin
  perform test.chk('CHECK de clases acepta supply y smallware y CONSERVA legacy_x',
    (select pg_get_constraintdef(oid) like '%supply%' and pg_get_constraintdef(oid) like '%smallware%'
            and pg_get_constraintdef(oid) like '%legacy_x%' and convalidated
       from pg_constraint where conname = 'inventory_items_classification_check'));
  perform test.chk('CHECK de motivos acepta internal_use, conserva cleaning y quedó validado',
    (select pg_get_constraintdef(oid) like '%internal_use%' and pg_get_constraintdef(oid) like '%cleaning%'
            and convalidated
       from pg_constraint where conname = 'inventory_movements_reason_code_check'));
  perform test.chk('columna destination',
    exists (select 1 from information_schema.columns
             where table_name = 'inventory_movements' and column_name = 'destination'));
  perform test.chk('UNA sola firma de la salida (9 parámetros)',
    (select count(*) from pg_proc where proname = 'fn_inventory_record_outflow') = 1
    and to_regprocedure('public.fn_inventory_record_outflow(uuid,uuid,uuid,numeric,text,text,numeric,uuid,text)') is not null);
  perform test.chk('authenticated ejecuta, anon no',
    has_function_privilege('authenticated', 'public.fn_inventory_supplies_overview(uuid,integer,uuid)', 'execute')
    and not has_function_privilege('anon', 'public.fn_inventory_supplies_overview(uuid,integer,uuid)', 'execute')
    and has_function_privilege('authenticated',
      'public.fn_inventory_record_outflow(uuid,uuid,uuid,numeric,text,text,numeric,uuid,text)', 'execute')
    and not has_function_privilege('anon',
      'public.fn_inventory_record_outflow(uuid,uuid,uuid,numeric,text,text,numeric,uuid,text)', 'execute'));
end $$;
SQL

echo "== Clasificar y mover"
run "datos" <<'SQL'
do $$
declare
  b  uuid := '11111111-1111-1111-1111-111111111111';
  w1 uuid := 'a0000000-0000-0000-0000-000000000001';
  w2 uuid := 'a0000000-0000-0000-0000-000000000002';
  wt uuid := 'a0000000-0000-0000-0000-000000000009';
  papel uuid := 'c0000000-0000-0000-0000-000000000002';
  copa  uuid := 'c0000000-0000-0000-0000-000000000003';
  cloro uuid := 'c0000000-0000-0000-0000-000000000004';
  leche uuid := 'c0000000-0000-0000-0000-000000000001';
begin
  update public.inventory_items set item_classification = 'supply' where id in (papel, cloro);
  update public.inventory_items set item_classification = 'smallware'
   where id in (copa, 'c0000000-0000-0000-0000-000000000005');
  perform test.chk('clases guardadas',
    (select count(*) from public.inventory_items where item_classification in ('supply','smallware')) = 4);

  -- Compras y existencia.
  insert into public.inventory_movements (business_id, warehouse_id, item_id, movement_type, quantity,
    cost_per_unit, reference_type, created_at) values
    (b, w1, papel, 'purchase', 96, 18, 'purchase_order', now() - interval '10 days'),
    (b, w2, copa,  'purchase', 100, 150, 'purchase_order', now() - interval '20 days'),
    (b, w1, copa,  'purchase', 30, 150, 'purchase_order', now() - interval '20 days'),
    (b, wt, copa,  'transfer_in', 12, null, 'transfer', now()),        -- en tránsito: no cuenta
    (b, w1, leche, 'purchase', 10, 50, 'purchase_order', now() - interval '2 days');
  update public.inventory_stock set min_stock = 90 where warehouse_id = w2 and item_id = copa;
end $$;
SQL

run "salidas por la función real" <<'SQL'
do $$
declare
  b  uuid := '11111111-1111-1111-1111-111111111111';
  w1 uuid := 'a0000000-0000-0000-0000-000000000001';
  w2 uuid := 'a0000000-0000-0000-0000-000000000002';
  papel uuid := 'c0000000-0000-0000-0000-000000000002';
  copa  uuid := 'c0000000-0000-0000-0000-000000000003';
  leche uuid := 'c0000000-0000-0000-0000-000000000001';
  k uuid := 'aaaaaaaa-0000-0000-0000-000000000001';
  r jsonb; r2 jsonb; v_msg text;
begin
  -- Consumo interno con área.
  r := public.fn_inventory_record_outflow(b, w1, papel, 24, 'internal_use',
         'Consumo interno — planta alta', null, k, '  Baños  ');
  perform test.chk('consumo interno guarda motivo, área recortada y costo del insumo',
    exists (select 1 from public.inventory_movements where id = (r->>'id')::uuid
             and reason_code = 'internal_use' and destination = 'Baños' and quantity = -24
             and cost_per_unit = 20), r::text);
  perform test.chk('devuelve el área', r->>'destination' = 'Baños', r::text);
  -- Reintento con la misma llave: no resta otra vez y devuelve el área.
  r2 := public.fn_inventory_record_outflow(b, w1, papel, 24, 'internal_use',
          'Consumo interno — planta alta', null, k, 'Baños');
  perform test.chk('replay', (r2->>'replayed')::boolean and r2->>'id' = r->>'id'
                             and r2->>'destination' = 'Baños', r2::text);
  perform test.chk('stock del papel 96 - 24 = 72',
    (select quantity from public.inventory_stock where warehouse_id = w1 and item_id = papel) = 72);

  r := public.fn_inventory_record_outflow(b, w1, papel, 12, 'internal_use', 'Consumo interno', null,
         gen_random_uuid(), 'Cocina');
  r := public.fn_inventory_record_outflow(b, w1, papel, 6, 'internal_use', 'Consumo interno', null,
         gen_random_uuid(), null);
  -- Un rollo mojado: rotura, NO consumo. El área se ignora fuera de internal_use.
  r := public.fn_inventory_record_outflow(b, w1, papel, 2, 'breakage', 'Rotura / dañado — se mojó', null,
         gen_random_uuid(), 'Baños');
  perform test.chk('el área se ignora en una rotura',
    (select destination is null from public.inventory_movements where id = (r->>'id')::uuid));
  -- App vieja: 8 parámetros por nombre, sin área.
  r := public.fn_inventory_record_outflow(p_business_id => b, p_warehouse_id => w1, p_item_id => papel,
         p_quantity => 1, p_reason_code => 'internal_use', p_notes => 'Consumo interno',
         p_cost_per_unit => null, p_reference_id => gen_random_uuid());
  perform test.chk('llamada de 8 parámetros sigue funcionando', r ? 'id', r::text);

  -- Menaje: roturas y faltante en el Bar; conteo que encuentra 3 copas menos.
  r := public.fn_inventory_record_outflow(b, w2, copa, 6, 'breakage', 'Rotura / dañado', null, gen_random_uuid());
  r := public.fn_inventory_record_outflow(b, w2, copa, 2, 'theft', 'Faltante / robo', null, gen_random_uuid());
  insert into public.inventory_movements (business_id, warehouse_id, item_id, movement_type, quantity,
    cost_per_unit, reference_type, notes, reason_code) values
    (b, w2, copa, 'adjustment', -3, 150, 'adjustment', 'Conteo', 'physical_count'),
    -- Un conteo con «Vencido» en la nota sigue siendo conteo.
    (b, w1, copa, 'adjustment', -1, 150, 'adjustment', 'Vencido — mal escrito', 'physical_count');

  -- Comida: un consumo interno (comida del personal) y una merma.
  r := public.fn_inventory_record_outflow(b, w1, leche, 1, 'internal_use', 'Consumo interno', null,
         gen_random_uuid(), 'Personal');
  r := public.fn_inventory_record_outflow(b, w1, leche, 2, 'expiration', 'Vencido', null, gen_random_uuid());

  -- Motivo que no es salida.
  begin
    perform public.fn_inventory_record_outflow(b, w1, papel, 1, 'other', null, null, null, null);
    perform test.chk('debió fallar', false);
  exception when others then v_msg := sqlerrm; end;
  perform test.chk('motivo inválido', v_msg like 'INVALID_OUTFLOW_REASON%', v_msg);
end $$;
SQL

echo "== Panel de gastables y menaje"
run "todo el negocio" <<'SQL'
do $$
declare
  r jsonb; papel jsonb; copa jsonb; olla jsonb; v_msg text;
begin
  r := public.fn_inventory_supplies_overview('11111111-1111-1111-1111-111111111111', 30, null);
  perform test.chk('solo gastables y menaje activos (4), sin la leche',
    jsonb_array_length(r->'items') = 4
    and not exists (select 1 from jsonb_array_elements(r->'items') e where e->>'item_name' = 'Leche'),
    (r->'items')::text);
  select e into papel from jsonb_array_elements(r->'items') e where e->>'item_name' = 'Papel higiénico';
  select e into copa  from jsonb_array_elements(r->'items') e where e->>'item_name' = 'Copa de vino';
  select e into olla  from jsonb_array_elements(r->'items') e where e->>'item_name' = 'Olla 20 L';

  perform test.chk('papel: clase supply', papel->>'classification' = 'supply');
  perform test.chk('papel: compra 96 a 18', (papel->>'purchased_qty')::numeric = 96
    and (papel->>'purchased_value')::numeric = 1728, papel::text);
  perform test.chk('papel: consumo interno 24+12+6+1 = 43 a 20',
    (papel->>'used_qty')::numeric = 43 and (papel->>'used_value')::numeric = 860, papel::text);
  perform test.chk('papel: el rollo mojado es rotura, no consumo', (papel->>'broken_qty')::numeric = 2);
  perform test.chk('papel: existencia 96 - 43 - 2 = 51', (papel->>'stock')::numeric = 51, papel::text);
  perform test.chk('papel: mínimo del insumo (48)', (papel->>'min_stock')::numeric = 48
    and papel->>'min_source' = 'insumo');

  perform test.chk('copa: clase smallware', copa->>'classification' = 'smallware');
  perform test.chk('copa: existencia sin tránsito 130 - 6 - 2 - 3 - 1 = 118',
    (copa->>'stock')::numeric = 118, copa::text);
  perform test.chk('copa: rotas 6 (900)', (copa->>'broken_qty')::numeric = 6
    and (copa->>'broken_value')::numeric = 900);
  perform test.chk('copa: faltante 2', (copa->>'lost_qty')::numeric = 2);
  perform test.chk('copa: diferencias de conteo -4 (el «Vencido» en la nota no la vuelve merma)',
    (copa->>'count_adjust_qty')::numeric = -4 and (copa->>'other_out_qty')::numeric = 0, copa::text);
  perform test.chk('copa: por bodega, sin la de tránsito',
    jsonb_array_length(copa->'by_warehouse') = 2
    and not exists (select 1 from jsonb_array_elements(copa->'by_warehouse') w
                     where w->>'warehouse_name' = '__IN_TRANSIT__'), (copa->'by_warehouse')::text);
  perform test.chk('olla sin movimientos también aparece (contra su par)',
    olla is not null and (olla->>'stock')::numeric = 0 and (olla->>'min_stock')::numeric = 2, olla::text);

  perform test.chk('consumo por área: Baños 480, Cocina 240, sin área 140 (6+1 rollos)',
    (select jsonb_agg(jsonb_build_array(d->>'destination', (d->>'value')::numeric) order by (d->>'value')::numeric desc)
       from jsonb_array_elements(r->'by_destination') d)
    = '[["Baños", 480], ["Cocina", 240], [null, 140]]'::jsonb,
    (r->'by_destination')::text);

  -- Negocio ajeno.
  begin
    perform public.fn_inventory_supplies_overview('22222222-2222-2222-2222-222222222222', 30, null);
    perform test.chk('debió negar', false);
  exception when others then v_msg := sqlerrm; end;
  perform test.chk('negocio ajeno negado', v_msg like 'NOT_AUTHORIZED%', v_msg);
end $$;
SQL

run "una bodega: el par del Bar" <<'SQL'
do $$
declare r jsonb; copa jsonb;
begin
  r := public.fn_inventory_supplies_overview('11111111-1111-1111-1111-111111111111', 30,
         'a0000000-0000-0000-0000-000000000002');
  select e into copa from jsonb_array_elements(r->'items') e where e->>'item_name' = 'Copa de vino';
  perform test.chk('copa en el Bar: 100 - 6 - 2 - 3 = 89', (copa->>'stock')::numeric = 89, copa::text);
  perform test.chk('par del almacén (90), no el del insumo (120)',
    (copa->>'min_stock')::numeric = 90 and copa->>'min_source' = 'almacen', copa::text);
  perform test.chk('el consumo de papel es de Principal: en el Bar no hay', not exists (
    select 1 from jsonb_array_elements(r->'by_destination')));
end $$;
SQL

echo "== Rendimiento (0050 reemplazada)"
run "solo comida; consumo interno es consumo" <<'SQL'
do $$
declare r jsonb; leche jsonb;
begin
  r := public.fn_inventory_yield_analysis('11111111-1111-1111-1111-111111111111', 30, null);
  perform test.chk('sin gastables ni menaje',
    not exists (select 1 from jsonb_array_elements(r->'items') e
                 where e->>'item_name' in ('Papel higiénico', 'Copa de vino')), (r->'items')::text);
  select e into leche from jsonb_array_elements(r->'items') e where e->>'item_name' = 'Leche';
  perform test.chk('leche: la comida del personal es consumo (1), no merma',
    (leche->>'consumed_qty')::numeric = 1, leche::text);
  perform test.chk('leche: merma solo el vencido (2)', (leche->>'waste_qty')::numeric = 2
    and not (leche->'waste_by_reason' ? 'internal_use'), leche::text);
  perform test.chk('resumen por motivo sin internal_use',
    not exists (select 1 from jsonb_array_elements(r->'by_reason') x where x->>'reason' = 'internal_use'),
    (r->'by_reason')::text);
end $$;
SQL

echo "== Rollback"
run_fails "se niega con datos de la 0051" "ROLLBACK_BLOCKED" \
  -f "$M/20260930_0051_supplies_and_smallware_ROLLBACK.sql"
Q -c "update public.inventory_items set item_classification = 'simple'
       where item_classification in ('supply','smallware');
      delete from public.inventory_movements where reason_code = 'internal_use';" \
  || bad "limpiar datos"
run "aplica sin datos" -f "$M/20260930_0051_supplies_and_smallware_ROLLBACK.sql"
run "vuelve al estado anterior" <<'SQL'
do $$ begin
  perform test.chk('sin el panel', to_regprocedure('public.fn_inventory_supplies_overview(uuid,integer,uuid)') is null);
  perform test.chk('salida de 8 parámetros de vuelta, sola',
    (select count(*) from pg_proc where proname = 'fn_inventory_record_outflow') = 1
    and to_regprocedure('public.fn_inventory_record_outflow(uuid,uuid,uuid,numeric,text,text,numeric,uuid)') is not null);
  perform test.chk('CHECK de clases sin los nuevos, conserva legacy_x',
    (select pg_get_constraintdef(oid) not like '%supply%' and pg_get_constraintdef(oid) like '%legacy_x%'
       from pg_constraint where conname = 'inventory_items_classification_check'));
  perform test.chk('CHECK de motivos sin internal_use, con cleaning',
    (select pg_get_constraintdef(oid) not like '%internal_use%' and pg_get_constraintdef(oid) like '%cleaning%'
       from pg_constraint where conname = 'inventory_movements_reason_code_check'));
  perform test.chk('sin columna destination', not exists (select 1 from information_schema.columns
    where table_name = 'inventory_movements' and column_name = 'destination'));
  perform test.chk('rendimiento de la 0050 de vuelta',
    (select obj_description('public.fn_inventory_yield_analysis(uuid,integer,uuid)'::regprocedure)
       like '%Ver 20260930_0050.'));
end $$;
SQL
run "se puede volver a aplicar" -f "$M/20260930_0051_supplies_and_smallware.sql"

echo
if [ "$FAIL" = 0 ]; then echo "TODO OK"; else echo "HAY FALLAS"; fi
exit $FAIL
