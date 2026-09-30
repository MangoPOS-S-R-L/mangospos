#!/usr/bin/env bash
# =============================================================================
# Prueba LOCAL de "Rendimiento por insumo" (20260930_0050).
# Postgres 15 DESECHABLE con el esquema mínimo; corre el archivo real.
#
#   bash supabase/tests/inventory_yield_local_test.sh [carpeta_trabajo]
# Variables: PG_BIN (default homebrew postgresql@15), PG_PORT (default 55451).
# =============================================================================
set -u
REPO=$(cd "$(dirname "$0")/../.." && pwd)
M=$REPO/supabase/migrations
PG=${PG_BIN:-/opt/homebrew/opt/postgresql@15/bin}
PORT=${PG_PORT:-55451}
WORK=${1:-$(mktemp -d)}
D=$WORK/pg_yield
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
create table public.memberships (user_id uuid, business_id uuid);
insert into public.memberships values
  ('99999999-9999-9999-9999-999999999999','11111111-1111-1111-1111-111111111111');
create function public.user_has_business_access(p_user uuid, p_business uuid) returns boolean
language sql stable as $$ select exists (select 1 from public.memberships
  where user_id = p_user and business_id = p_business) $$;
create table public.inventory_items (id uuid primary key, business_id uuid, name text, sku text,
  unit text, cost numeric, is_active boolean default true);
create table public.warehouses (id uuid primary key, business_id uuid, name text, is_active boolean default true);
create table public.inventory_stock (warehouse_id uuid, item_id uuid, quantity numeric,
  primary key (warehouse_id, item_id));
create table public.inventory_movements (id uuid primary key default gen_random_uuid(), business_id uuid,
  warehouse_id uuid, item_id uuid, movement_type public.movement_type, quantity numeric,
  cost_per_unit numeric, reference_id uuid, reference_type text, notes text,
  created_at timestamptz default now());

create schema test;
create function test.chk(p_label text, p_ok boolean, p_detail text default '') returns void language plpgsql as $$
begin
  if p_ok is not true then raise exception 'FALLA % %', p_label, coalesce(p_detail, ''); end if;
  raise notice 'ok  %', p_label;
end $$;

insert into public.warehouses values
  ('a0000000-0000-0000-0000-000000000001','11111111-1111-1111-1111-111111111111','Principal',true),
  ('a0000000-0000-0000-0000-000000000002','11111111-1111-1111-1111-111111111111','Cocina',true);
insert into public.inventory_items values
  ('c0000000-0000-0000-0000-000000000001','11111111-1111-1111-1111-111111111111','Leche','L-1','l',50),
  ('c0000000-0000-0000-0000-000000000002','11111111-1111-1111-1111-111111111111','Queso','Q-1','lb',100),
  ('c0000000-0000-0000-0000-000000000003','11111111-1111-1111-1111-111111111111','Sin movimiento','S-1','u',10),
  ('c0000000-0000-0000-0000-000000000009','22222222-2222-2222-2222-222222222222','Ajeno','X','u',10);
insert into public.inventory_stock values
  ('a0000000-0000-0000-0000-000000000001','c0000000-0000-0000-0000-000000000001', 7);
SQL
ok "esquema mínimo"

echo "== Migración real 20260930_0050"
run "aplica"         -f "$M/20260930_0050_inventory_yield_analysis.sql"
run "es idempotente" -f "$M/20260930_0050_inventory_yield_analysis.sql"

echo "== Movimientos de prueba"
Q <<'SQL' || bad "datos"
do $$
declare
  b uuid := '11111111-1111-1111-1111-111111111111';
  w1 uuid := 'a0000000-0000-0000-0000-000000000001';
  w2 uuid := 'a0000000-0000-0000-0000-000000000002';
  leche uuid := 'c0000000-0000-0000-0000-000000000001';
  queso uuid := 'c0000000-0000-0000-0000-000000000002';
begin
  insert into public.inventory_movements (business_id, warehouse_id, item_id, movement_type, quantity,
    cost_per_unit, reference_type, notes, reason_code, created_at) values
  -- compra 20 l a 48 (costo del MOVIMIENTO, no el del insumo)
  (b, w1, leche, 'purchase', 20, 48, 'purchase_order', null, null, now() - interval '5 days'),
  -- corrección de la compra: -2 (reversa de editar)
  (b, w1, leche, 'purchase', -2, 48, 'purchase_order_edit_reversal', null, null, now() - interval '4 days'),
  -- ventas: -10, y un producto quitado de la cuenta devuelve +1
  (b, w1, leche, 'sale', -10, null, 'order', null, null, now() - interval '3 days'),
  (b, w1, leche, 'sale', 1, null, 'order', null, null, now() - interval '3 days'),
  -- producción consume 1
  (b, w1, leche, 'production_out', -1, null, 'production_order', null, null, now() - interval '2 days'),
  -- merma con motivo guardado
  (b, w1, leche, 'waste', -2, null, 'manual_outflow', 'Vencido — nevera', 'expiration', now() - interval '1 day'),
  -- merma vieja: motivo solo en la nota
  (b, w1, leche, 'waste', -1, null, 'manual_outflow', 'Rotura / dañado — caja', null, now() - interval '1 day'),
  -- producto quitado ya preparado
  (b, w1, leche, 'waste', -0.5, null, 'order_item_removal', 'Merma: devuelto (Café)', null, now()),
  -- ajuste NEGATIVO con motivo de salida = merma
  (b, w1, leche, 'adjustment', -1, null, 'adjustment', 'Rotura', 'breakage', now()),
  -- ajuste de conteo = aparte
  (b, w1, leche, 'adjustment', -0.5, null, 'adjustment', 'Conteo', 'physical_count', now()),
  -- transferencia interna (se cancela en todo el negocio)
  (b, w1, leche, 'transfer_out', -3, null, 'transfer', null, null, now()),
  (b, w2, leche, 'transfer_in', 3, null, 'transfer', null, null, now()),
  -- merma sin motivo en otro insumo
  (b, w1, queso, 'waste', -1, null, 'manual_outflow', 'se cayó', null, now()),
  -- FUERA del período (40 días)
  (b, w1, leche, 'waste', -100, null, 'manual_outflow', 'Vencido', 'expiration', now() - interval '40 days'),
  -- OTRO negocio
  ('22222222-2222-2222-2222-222222222222', w1, 'c0000000-0000-0000-0000-000000000009', 'waste', -5, null,
   'manual_outflow', null, 'theft', now());
end $$;
SQL

echo "== Comportamiento"
run "casos" <<'SQL'
do $$
declare
  r jsonb; leche jsonb; queso jsonb; v_msg text;
begin
  r := public.fn_inventory_yield_analysis('11111111-1111-1111-1111-111111111111', 30, null);
  perform test.chk('período de 30 días', (r->>'days')::int = 30 and jsonb_array_length(r->'daily') = 30, r->>'days');

  select e into leche from jsonb_array_elements(r->'items') e where e->>'item_name' = 'Leche';
  select e into queso from jsonb_array_elements(r->'items') e where e->>'item_name' = 'Queso';
  perform test.chk('solo insumos con movimiento',
    jsonb_array_length(r->'items') = 2, jsonb_array_length(r->'items')::text);

  perform test.chk('compra NETA (20 - 2 de la corrección)', (leche->>'purchased_qty')::numeric = 18, leche::text);
  perform test.chk('compra valorada al costo del movimiento (18 × 48)',
    (leche->>'purchased_value')::numeric = 864, leche->>'purchased_value');
  perform test.chk('consumo neto: ventas 10 - 1 devuelto + 1 producción = 10',
    (leche->>'consumed_qty')::numeric = 10, leche->>'consumed_qty');
  perform test.chk('consumo sin costo del movimiento usa el del insumo (10 × 50)',
    (leche->>'consumed_value')::numeric = 500, leche->>'consumed_value');
  perform test.chk('merma = 2 vencido + 1 rotura (nota) + 0.5 quitado + 1 ajuste rotura',
    (leche->>'waste_qty')::numeric = 4.5, leche->>'waste_qty');
  perform test.chk('merma valorada', (leche->>'waste_value')::numeric = 225, leche->>'waste_value');
  perform test.chk('por motivo: vencido 2',
    (leche->'waste_by_reason'->'expiration'->>'qty')::numeric = 2, (leche->'waste_by_reason')::text);
  perform test.chk('por motivo: rotura 2 (nota vieja + ajuste)',
    (leche->'waste_by_reason'->'breakage'->>'qty')::numeric = 2
    and (leche->'waste_by_reason'->'breakage'->>'count')::int = 2);
  perform test.chk('por motivo: producto quitado 0.5',
    (leche->'waste_by_reason'->'order_removal'->>'qty')::numeric = 0.5);
  perform test.chk('ajuste de conteo aparte (-0.5), no es merma',
    (leche->>'count_adjust_qty')::numeric = -0.5);
  perform test.chk('transferencias se cancelan en todo el negocio',
    (leche->>'transfer_qty')::numeric = 0);
  perform test.chk('lo de hace 40 días no cuenta', (leche->>'waste_qty')::numeric < 100);
  perform test.chk('existencia actual', (leche->>'current_stock')::numeric = 7);
  perform test.chk('sin motivo → unspecified', queso->'waste_by_reason' ? 'unspecified', queso::text);
  perform test.chk('orden: más merma en dinero primero',
    (r->'items'->0->>'item_name') = 'Leche');

  perform test.chk('resumen por motivo: rotura 2 + vencido 2 + quitado + sin motivo',
    jsonb_array_length(r->'by_reason') = 4, (r->'by_reason')::text);
  perform test.chk('el día de hoy trae la merma de hoy (0.5+1 leche = 75, queso 100)',
    ((r->'daily'->29)->>'waste_value')::numeric = 175, (r->'daily'->29)::text);

  -- Por bodega: la cocina solo ve la transferencia entrante.
  r := public.fn_inventory_yield_analysis('11111111-1111-1111-1111-111111111111', 30,
         'a0000000-0000-0000-0000-000000000002');
  perform test.chk('filtro por bodega', jsonb_array_length(r->'items') = 0
    or ((r->'items'->0->>'waste_qty')::numeric = 0), (r->'items')::text);

  -- 7 días: la compra de hace 5 días sigue; 3 días: ya no.
  r := public.fn_inventory_yield_analysis('11111111-1111-1111-1111-111111111111', 3, null);
  select e into leche from jsonb_array_elements(r->'items') e where e->>'item_name' = 'Leche';
  perform test.chk('3 días: sin la compra de hace 5', (leche->>'purchased_qty')::numeric = 0, leche::text);

  -- Otro negocio: sin acceso.
  begin
    perform public.fn_inventory_yield_analysis('22222222-2222-2222-2222-222222222222', 30, null);
    perform test.chk('debió negar', false);
  exception when others then v_msg := sqlerrm; end;
  perform test.chk('negocio ajeno negado', v_msg like 'NOT_AUTHORIZED%', v_msg);
end $$;
SQL

echo "== Permisos y rollback"
run "anon no ejecuta" <<'SQL'
do $$ begin
  perform test.chk('authenticated sí', has_function_privilege('authenticated',
    'public.fn_inventory_yield_analysis(uuid,integer,uuid)', 'execute'));
  perform test.chk('anon no', not has_function_privilege('anon',
    'public.fn_inventory_yield_analysis(uuid,integer,uuid)', 'execute'));
end $$;
SQL
run "rollback" -f "$M/20260930_0050_inventory_yield_analysis_ROLLBACK.sql"

echo
if [ "$FAIL" = 0 ]; then echo "TODO OK"; else echo "HAY FALLAS"; fi
exit $FAIL
