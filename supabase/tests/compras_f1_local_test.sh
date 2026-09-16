#!/usr/bin/env bash
# =============================================================================
# Prueba LOCAL de Compras F1 (20260915_0004, fn_purchase_projection).
# Postgres 15 DESECHABLE: esquema mínimo + las migraciones REALES de F0 y F1.
#   bash supabase/tests/compras_f1_local_test.sh [carpeta_trabajo]
# Variables: PG_BIN (default homebrew postgresql@15), PG_PORT (default 55439).
# =============================================================================
set -u
REPO=$(cd "$(dirname "$0")/../.." && pwd)
M=$REPO/supabase/migrations
PG=${PG_BIN:-/opt/homebrew/opt/postgresql@15/bin}
PORT=${PG_PORT:-55439}
WORK=${1:-$(mktemp -d)}
D=$WORK/pg_compras_f1
rm -rf "$D"; mkdir -p "$D"
"$PG/initdb" -D "$D/data" -U postgres --auth=trust >/dev/null || exit 1
"$PG/pg_ctl" -D "$D/data" -o "-p $PORT -c listen_addresses=127.0.0.1 -c unix_socket_directories=''" \
  -l "$D/log" start -w >/dev/null || { cat "$D/log"; exit 1; }
trap '"$PG/pg_ctl" -D "$D/data" stop -m fast >/dev/null 2>&1' EXIT
Q() { "$PG/psql" -h 127.0.0.1 -p "$PORT" -U postgres -X -q -v ON_ERROR_STOP=1 "$@"; }
FAIL=0
ok()  { echo "  ok     $1"; }
bad() { echo "  FALLA  $1"; FAIL=1; }

echo "== Esquema mínimo"
Q <<'SQL' || { bad "esquema"; exit 1; }
create role authenticated; create role anon;
create schema auth;
create function auth.uid() returns uuid language sql stable as $$ select null::uuid $$;
create type public.purchase_status as enum ('draft','sent','partial','received','cancelled');
create type public.movement_type as enum ('purchase','sale','adjustment','transfer_in','transfer_out','waste','return','production_in','production_out');
create table public.businesses (id uuid primary key, name text);
create table public.warehouses (id uuid primary key, business_id uuid, name text, is_active boolean default true);
create table public.suppliers (id uuid primary key, business_id uuid, name text, lead_time_days smallint, is_active boolean default true);
create table public.inventory_items (id uuid primary key, business_id uuid, name text, sku text, unit text default 'unidad',
  cost numeric default 0, min_stock numeric default 0, purchase_unit text, pack_size numeric default 1,
  is_active boolean default true, item_classification text default 'simple');
create table public.inventory_stock (warehouse_id uuid, item_id uuid, quantity numeric default 0, min_stock numeric,
  primary key (warehouse_id, item_id));
create table public.supplier_items (id uuid primary key default gen_random_uuid(), business_id uuid not null,
  supplier_id uuid not null, inventory_item_id uuid not null, supplier_code text, purchase_unit text, pack_size numeric,
  last_price numeric, min_order_qty numeric, notes text, is_active boolean not null default true,
  created_at timestamptz not null default now(), updated_at timestamptz not null default now(),
  unique (supplier_id, inventory_item_id));
create table public.purchase_orders (id uuid primary key default gen_random_uuid(), business_id uuid not null,
  supplier_id uuid, warehouse_id uuid, order_number text not null, status public.purchase_status default 'draft',
  subtotal numeric default 0, tax numeric default 0, total numeric default 0, notes text, expected_date date,
  received_date date, created_by uuid, created_at timestamptz default now());
create table public.purchase_order_items (id uuid primary key default gen_random_uuid(),
  purchase_order_id uuid not null references public.purchase_orders(id) on delete cascade, inventory_item_id uuid,
  description text, quantity_ordered numeric not null, quantity_received numeric default 0, unit_cost numeric not null,
  tax_rate numeric default 18, total numeric not null);
create table public.inventory_movements (id bigserial primary key, business_id uuid, warehouse_id uuid, item_id uuid,
  movement_type public.movement_type, quantity numeric, cost_per_unit numeric, reference_id uuid, reference_type text,
  created_at timestamptz default now());
create table public.direct_receipts (id uuid primary key, business_id uuid, warehouse_id uuid, supplier_id uuid);
create table public.purchase_receptions (id uuid primary key, business_id uuid, warehouse_id uuid, supplier_id uuid);
create table public.purchase_reception_lines (id uuid primary key, reception_id uuid, item_id uuid, quantity_received numeric);
create table public.stock_transfers (id uuid primary key, business_id uuid, from_warehouse_id uuid, to_warehouse_id uuid,
  status text not null default 'sent');
create table public.stock_transfer_items (id uuid primary key default gen_random_uuid(), stock_transfer_id uuid not null,
  item_id uuid not null, quantity_sent numeric not null, quantity_received numeric, target_item_id uuid);
create schema test;
create function test.chk(p_label text, p_ok boolean, p_detail text default '') returns void language plpgsql as $$
begin
  if p_ok is not true then raise exception 'FALLA % %', p_label, coalesce(p_detail, ''); end if;
  raise notice 'ok  %', p_label;
end $$;
SQL
ok "esquema"

echo "== Migraciones (F1 exige F0 primero)"
OUT=$(Q -f "$M/20260915_0004_compras_f1_proyeccion.sql" 2>&1)
echo "$OUT" | grep -q "Falta aplicar 20260915_0003" && ok "sin F0, la F1 no se aplica" || { bad "guardia de F1"; echo "$OUT" | tail -3; }
Q -f "$M/20260915_0003_compras_f0_orden_atomica_y_suplidor.sql" >/dev/null 2>&1 \
  && Q -f "$M/20260915_0004_compras_f1_proyeccion.sql" >/dev/null 2>&1 \
  && Q -f "$M/20260915_0004_compras_f1_proyeccion.sql" >/dev/null 2>&1 \
  && ok "F0 + F1 aplicadas (F1 dos veces)" || { bad "aplicar"; Q -f "$M/20260915_0004_compras_f1_proyeccion.sql" 2>&1 | tail -5; exit 1; }
Q -f "$M/20260915_0006_compras_existencia_negativa.sql" >/dev/null 2>&1 \
  && Q -f "$M/20260915_0006_compras_existencia_negativa.sql" >/dev/null 2>&1 \
  && ok "0006 (negativo cuenta como 0) aplicada dos veces" || { bad "0006"; Q -f "$M/20260915_0006_compras_existencia_negativa.sql" 2>&1 | tail -5; exit 1; }

echo "== Semilla"
Q <<'SQL' >/dev/null || { bad "semilla"; exit 1; }
-- B = Penda. MAIN y COC cuentan; TRANSITO e INACTIVO no.
insert into public.businesses values ('35c5076a-bd85-4a1b-8d1c-ce719c4f9ae6','Penda'), ('22222222-2222-2222-2222-222222222222','Otro');
insert into public.warehouses (id, business_id, name, is_active) values
 ('a0000000-0000-0000-0000-000000000001','35c5076a-bd85-4a1b-8d1c-ce719c4f9ae6','MAIN', true),
 ('a0000000-0000-0000-0000-000000000002','35c5076a-bd85-4a1b-8d1c-ce719c4f9ae6','COC', true),
 ('a0000000-0000-0000-0000-000000000003','35c5076a-bd85-4a1b-8d1c-ce719c4f9ae6','__IN_TRANSIT__', true),
 ('a0000000-0000-0000-0000-000000000004','35c5076a-bd85-4a1b-8d1c-ce719c4f9ae6','INACTIVO', false),
 ('a0000000-0000-0000-0000-0000000000ff','22222222-2222-2222-2222-222222222222','OTRO', true);
insert into public.suppliers (id, business_id, name, lead_time_days) values
 ('b0000000-0000-0000-0000-00000000000b','35c5076a-bd85-4a1b-8d1c-ce719c4f9ae6','SB', 5);
insert into public.inventory_items (id, business_id, name, unit, cost, min_stock, purchase_unit, pack_size, item_classification, is_active) values
 ('c0000000-0000-0000-0000-00000000000a','35c5076a-bd85-4a1b-8d1c-ce719c4f9ae6','Refresco','unidad',30,0,'Caja',24,'simple',true),
 ('c0000000-0000-0000-0000-00000000000b','35c5076a-bd85-4a1b-8d1c-ce719c4f9ae6','Queso','lb',200,5,null,1,'raw_material',true),
 ('c0000000-0000-0000-0000-00000000000c','35c5076a-bd85-4a1b-8d1c-ce719c4f9ae6','Delivery','unidad',0,0,null,1,'service',true),
 ('c0000000-0000-0000-0000-00000000000d','35c5076a-bd85-4a1b-8d1c-ce719c4f9ae6','Harina','lb',0,0,null,1,'simple',false),
 ('c0000000-0000-0000-0000-00000000000e','35c5076a-bd85-4a1b-8d1c-ce719c4f9ae6','Pan','unidad',5,0,null,1,'simple',true),
 ('c0000000-0000-0000-0000-00000000000f','35c5076a-bd85-4a1b-8d1c-ce719c4f9ae6','Salsa','lb',50,5,null,1,'simple',true),
 ('c0000000-0000-0000-0000-0000000000ff','22222222-2222-2222-2222-222222222222','Refresco cola 12oz','unidad',1,0,null,1,'simple',true),
 ('c0000000-0000-0000-0000-0000000000fe','22222222-2222-2222-2222-222222222222','  PAN ','unidad',1,0,null,1,'simple',true),
 ('c0000000-0000-0000-0000-0000000000fd','22222222-2222-2222-2222-222222222222','Exótico','unidad',1,0,null,1,'simple',true);
-- Entre negocios se casa como al recibir: SKU (sin mayúsculas ni espacios) y luego nombre.
update public.inventory_items set sku = 'ref-24'   where id = 'c0000000-0000-0000-0000-00000000000a';
update public.inventory_items set sku = ' REF-24 ' where id = 'c0000000-0000-0000-0000-0000000000ff';
-- Existencias. Lo del almacén inactivo y el de tránsito NO cuenta.
insert into public.inventory_stock (warehouse_id, item_id, quantity, min_stock) values
 ('a0000000-0000-0000-0000-000000000001','c0000000-0000-0000-0000-00000000000a', 10, null),
 ('a0000000-0000-0000-0000-000000000002','c0000000-0000-0000-0000-00000000000a',  0, 12),
 ('a0000000-0000-0000-0000-000000000004','c0000000-0000-0000-0000-00000000000a',100, null),
 ('a0000000-0000-0000-0000-000000000001','c0000000-0000-0000-0000-00000000000b',  5, null),
 ('a0000000-0000-0000-0000-000000000002','c0000000-0000-0000-0000-00000000000b',  3, null),
 ('a0000000-0000-0000-0000-000000000003','c0000000-0000-0000-0000-00000000000b',  2, null),
 -- Salsa en −10: consumo sin su entrada registrada.
 ('a0000000-0000-0000-0000-000000000001','c0000000-0000-0000-0000-00000000000f',-10, null);

-- Refresco (MAIN): primera compra hace ~10 días (orden recibida de SB a 22) y 60 vendidos → 6 por día.
insert into public.purchase_orders (id, business_id, supplier_id, warehouse_id, order_number, status) values
 ('d0000000-0000-0000-0000-00000000000b','35c5076a-bd85-4a1b-8d1c-ce719c4f9ae6','b0000000-0000-0000-0000-00000000000b','a0000000-0000-0000-0000-000000000001','H-1','received');
insert into public.inventory_movements (business_id, warehouse_id, item_id, movement_type, quantity, cost_per_unit, reference_id, reference_type, created_at)
select '35c5076a-bd85-4a1b-8d1c-ce719c4f9ae6','a0000000-0000-0000-0000-000000000001','c0000000-0000-0000-0000-00000000000a',
       'purchase', 24, 22, 'd0000000-0000-0000-0000-00000000000b', 'purchase_order', now() - interval '10 days' + interval '1 hour';
insert into public.inventory_movements (business_id, warehouse_id, item_id, movement_type, quantity, reference_type, created_at)
select '35c5076a-bd85-4a1b-8d1c-ce719c4f9ae6','a0000000-0000-0000-0000-000000000001','c0000000-0000-0000-0000-00000000000a',
       'sale', -10, 'order', now() - make_interval(days => g) from generate_series(1, 6) g;

-- Queso (MAIN): historia de 40 días. En la ventana de 30: vendido 19, devuelto 1, merma 4, producción 1 = 23.
-- NO cuentan: la venta de hace 35 días, la transferencia y el ajuste.
insert into public.inventory_movements (business_id, warehouse_id, item_id, movement_type, quantity, reference_type, created_at) values
 ('35c5076a-bd85-4a1b-8d1c-ce719c4f9ae6','a0000000-0000-0000-0000-000000000001','c0000000-0000-0000-0000-00000000000b','purchase',   50,'initial_stock',   now() - interval '40 days'),
 ('35c5076a-bd85-4a1b-8d1c-ce719c4f9ae6','a0000000-0000-0000-0000-000000000001','c0000000-0000-0000-0000-00000000000b','sale',      -10,'order',           now() - interval '35 days'),
 ('35c5076a-bd85-4a1b-8d1c-ce719c4f9ae6','a0000000-0000-0000-0000-000000000001','c0000000-0000-0000-0000-00000000000b','sale',      -19,'order',           now() - interval '5 days'),
 ('35c5076a-bd85-4a1b-8d1c-ce719c4f9ae6','a0000000-0000-0000-0000-000000000001','c0000000-0000-0000-0000-00000000000b','sale',        1,'order',           now() - interval '4 days'),
 ('35c5076a-bd85-4a1b-8d1c-ce719c4f9ae6','a0000000-0000-0000-0000-000000000001','c0000000-0000-0000-0000-00000000000b','waste',      -4,'manual_outflow',  now() - interval '3 days'),
 ('35c5076a-bd85-4a1b-8d1c-ce719c4f9ae6','a0000000-0000-0000-0000-000000000001','c0000000-0000-0000-0000-00000000000b','transfer_out',-3,'stock_transfer', now() - interval '2 days'),
 ('35c5076a-bd85-4a1b-8d1c-ce719c4f9ae6','a0000000-0000-0000-0000-000000000001','c0000000-0000-0000-0000-00000000000b','adjustment',-100,'stock_adjustment',now() - interval '1 day'),
 ('35c5076a-bd85-4a1b-8d1c-ce719c4f9ae6','a0000000-0000-0000-0000-000000000001','c0000000-0000-0000-0000-00000000000b','production_out',-1,'production', now() - interval '1 day'),
 -- venta del Queso en COCINA: cuenta para el negocio, no para MAIN.
 ('35c5076a-bd85-4a1b-8d1c-ce719c4f9ae6','a0000000-0000-0000-0000-000000000002','c0000000-0000-0000-0000-00000000000b','sale',      -50,'order',           now() - interval '2 days');

-- En tránsito hacia MAIN: 2 lb de Queso (interna); de otro negocio, todavía sin target_item_id:
-- 5 Refrescos (casan por SKU), 4 Panes (por nombre) y 9 de algo que aquí no existe.
insert into public.stock_transfers values
 ('e0000000-0000-0000-0000-000000000001','35c5076a-bd85-4a1b-8d1c-ce719c4f9ae6','a0000000-0000-0000-0000-000000000002','a0000000-0000-0000-0000-000000000001','sent'),
 ('e0000000-0000-0000-0000-000000000002','22222222-2222-2222-2222-222222222222','a0000000-0000-0000-0000-0000000000ff','a0000000-0000-0000-0000-000000000001','sent'),
 ('e0000000-0000-0000-0000-000000000003','35c5076a-bd85-4a1b-8d1c-ce719c4f9ae6','a0000000-0000-0000-0000-000000000002','a0000000-0000-0000-0000-000000000001','received');
insert into public.stock_transfer_items (stock_transfer_id, item_id, quantity_sent, target_item_id) values
 ('e0000000-0000-0000-0000-000000000001','c0000000-0000-0000-0000-00000000000b', 2, null),
 ('e0000000-0000-0000-0000-000000000002','c0000000-0000-0000-0000-0000000000ff', 5, null),
 ('e0000000-0000-0000-0000-000000000002','c0000000-0000-0000-0000-0000000000fe', 4, null),
 ('e0000000-0000-0000-0000-000000000002','c0000000-0000-0000-0000-0000000000fd', 9, null),
 ('e0000000-0000-0000-0000-000000000003','c0000000-0000-0000-0000-00000000000b', 7, null);

-- Ya pedido del Refresco a MAIN: enviada 24 + parcial 10 con 4 recibidos = 30. El borrador de 100 NO cuenta.
insert into public.purchase_orders (id, business_id, supplier_id, warehouse_id, order_number, status) values
 ('d1000000-0000-0000-0000-000000000001','35c5076a-bd85-4a1b-8d1c-ce719c4f9ae6','b0000000-0000-0000-0000-00000000000b','a0000000-0000-0000-0000-000000000001','OC-1','sent'),
 ('d1000000-0000-0000-0000-000000000002','35c5076a-bd85-4a1b-8d1c-ce719c4f9ae6','b0000000-0000-0000-0000-00000000000b','a0000000-0000-0000-0000-000000000001','OC-2','partial'),
 ('d1000000-0000-0000-0000-000000000003','35c5076a-bd85-4a1b-8d1c-ce719c4f9ae6','b0000000-0000-0000-0000-00000000000b','a0000000-0000-0000-0000-000000000001','OC-3','draft');
insert into public.purchase_order_items (purchase_order_id, inventory_item_id, quantity_ordered, quantity_received, unit_cost, total) values
 ('d1000000-0000-0000-0000-000000000001','c0000000-0000-0000-0000-00000000000a', 24, 0, 22, 528),
 ('d1000000-0000-0000-0000-000000000002','c0000000-0000-0000-0000-00000000000a', 10, 4, 22, 220),
 ('d1000000-0000-0000-0000-000000000003','c0000000-0000-0000-0000-00000000000a',100, 0, 22, 2200);
SQL
ok "semilla"

echo "== Proyección"
if OUT=$(Q 2>&1 <<'SQL'
do $$
declare x record; n int;
  B constant uuid := '35c5076a-bd85-4a1b-8d1c-ce719c4f9ae6';
  MAIN constant uuid := 'a0000000-0000-0000-0000-000000000001';
  COC constant uuid := 'a0000000-0000-0000-0000-000000000002';
begin
  select count(*) into n from public.fn_purchase_projection(B);
  perform test.chk('P0 solo insumos activos del negocio, sin servicios (Refresco, Queso, Pan, Salsa)', n = 4, n::text);

  -- Refresco, todo el negocio.
  select * into x from public.fn_purchase_projection(B) where item_id = 'c0000000-0000-0000-0000-00000000000a';
  perform test.chk('P1 existencia sin el almacén inactivo (10, no 110)', x.stock = 10, row_to_json(x)::text);
  perform test.chk('P1 en tránsito de otro negocio, sin resolver, casa por SKU (5)', x.in_transit = 5, row_to_json(x)::text);
  perform test.chk('P1 ya pedido = enviada 24 + parcial pendiente 6; el borrador no cuenta', x.on_order = 30, row_to_json(x)::text);
  perform test.chk('P1 ventana = 10 días de historia real, no 30', x.window_days = 10, row_to_json(x)::text);
  perform test.chk('P1 consumo 60 → 6 por día', x.consumption = 60 and x.daily_consumption = 6, row_to_json(x)::text);
  perform test.chk('P1 entrega del suplidor SB = 5 (no la de por defecto)', x.lead_time_days = 5 and not x.lead_time_is_default, row_to_json(x)::text);
  perform test.chk('P1 objetivo = 6 × (5 + 7) + 0 = 72', x.target = 72, row_to_json(x)::text);
  perform test.chk('P1 sugerido = 72 − (10 + 5 + 30) = 27', x.suggested_base = 27, row_to_json(x)::text);
  perform test.chk('P1 cubre 45 ÷ 6 = 7.5 días', x.days_of_supply = 7.5, row_to_json(x)::text);
  perform test.chk('P1 mínimo sugerido = 6 × (5 + 3) = 48', x.suggested_min_stock = 48, row_to_json(x)::text);
  perform test.chk('P1 caja de 24, costo 22 de la última compra, estimado 27 × 22 = 594',
    x.purchase_unit = 'Caja' and x.pack_size = 24 and x.unit_cost_base = 22 and x.estimated_cost = 594, row_to_json(x)::text);

  -- Queso, solo MAIN.
  select * into x from public.fn_purchase_projection(B, MAIN) where item_id = 'c0000000-0000-0000-0000-00000000000b';
  perform test.chk('P2 consumo NETO en MAIN = 19 − 1 + 4 + 1 = 23 (sin transferencia, ajuste ni venta vieja ni cocina)',
    x.consumption = 23, row_to_json(x)::text);
  perform test.chk('P2 ventana 30 (tiene 40 días de historia)', x.window_days = 30, row_to_json(x)::text);
  perform test.chk('P2 sin suplidor → entrega por defecto 2, marcada', x.lead_time_days = 2 and x.lead_time_is_default and x.supplier_id is null, row_to_json(x)::text);
  perform test.chk('P2 existencia MAIN 5, en tránsito 2 (la recibida no cuenta)', x.stock = 5 and x.in_transit = 2, row_to_json(x)::text);
  perform test.chk('P2 mínimo del insumo (5) porque MAIN no tiene uno propio', x.min_stock = 5 and x.min_stock_source = 'insumo', row_to_json(x)::text);
  perform test.chk('P2 sugerido = 23/30 × 9 + 5 − 7 = 4.9', abs(x.suggested_base - 4.9) < 0.001, row_to_json(x)::text);

  -- Queso, todo el negocio: la venta de cocina SÍ cuenta y la existencia suma MAIN + COC (no tránsito).
  select * into x from public.fn_purchase_projection(B) where item_id = 'c0000000-0000-0000-0000-00000000000b';
  perform test.chk('P3 negocio: consumo 73, existencia 8', x.consumption = 73 and x.stock = 8, row_to_json(x)::text);

  -- Refresco en COCINA: sin movimientos ahí → consumo 0; manda el mínimo del almacén (12).
  select * into x from public.fn_purchase_projection(B, COC) where item_id = 'c0000000-0000-0000-0000-00000000000a';
  perform test.chk('P4 cocina: mínimo del almacén 12 → sugerido 12', x.min_stock = 12 and x.min_stock_source = 'almacen'
    and x.daily_consumption = 0 and x.suggested_base = 12 and x.on_order = 0 and x.in_transit = 0, row_to_json(x)::text);

  select * into x from public.fn_purchase_projection(B) where item_id = 'c0000000-0000-0000-0000-00000000000e';
  perform test.chk('P4b en tránsito de otro negocio sin SKU casa por nombre (4) y ya no hace falta pedir',
    x.in_transit = 4 and x.suggested_base = 0, row_to_json(x)::text);

  select * into x from public.fn_purchase_projection(B, MAIN) where item_id = 'c0000000-0000-0000-0000-00000000000f';
  perform test.chk('P9 existencia negativa se muestra (−10) pero cuenta como 0: sugerido 5 (el mínimo), no 15',
    x.stock = -10 and x.suggested_base = 5 and x.estimated_cost = 250 and x.days_of_supply is null, row_to_json(x)::text);

  -- Filtros.
  perform test.chk('P5 solo lo que falta: el Pan (sin consumo ni mínimo) sale',
    not exists (select 1 from public.fn_purchase_projection(B, null, 7, 30, 2, 3, null, true) where item_id = 'c0000000-0000-0000-0000-00000000000e'));
  perform test.chk('P6 por suplidor SB: solo el Refresco',
    (select count(*) from public.fn_purchase_projection(B, null, 7, 30, 2, 3, 'b0000000-0000-0000-0000-00000000000b')) = 1);
  perform test.chk('P7 más cobertura pide más: 14 días → 6 × 19 − 45 = 69',
    (select suggested_base from public.fn_purchase_projection(B, null, 14) where item_id = 'c0000000-0000-0000-0000-00000000000a') = 69);
  -- Queso en todo el negocio: 73/30 × (2 + 7) + 5 − (8 + 2) = 16.9 lb × 200 (costo del insumo) = 3,380 > 594 del Refresco.
  select * into x from public.fn_purchase_projection(B) limit 1;
  perform test.chk('P8 ordena por costo estimado: primero el Queso (3,380, costo del insumo)',
    x.item_id = 'c0000000-0000-0000-0000-00000000000b' and x.cost_source = 'insumo' and abs(x.estimated_cost - 3380) < 0.01,
    row_to_json(x)::text);
end $$;
SQL
); then echo "$OUT" | grep "NOTICE:  ok" | sed 's/^.*NOTICE:  /  /'; ok "proyección"
else echo "$OUT" | grep -E "NOTICE:  ok|ERROR" | sed 's/^.*NOTICE:  /  /; s/^psql:[^:]*:[0-9]*: //'; bad "proyección"; fi

echo "== Verificación posterior (archivo del dueño; usa el id del Almacén Principal de Penda)"
Q -c "insert into public.warehouses (id, business_id, name) values ('f0cd4394-3bd9-4889-908c-686fd9ed67d2','35c5076a-bd85-4a1b-8d1c-ce719c4f9ae6','Almacen Principal')" >/dev/null
OUT=$(Q -f "$REPO/supabase/VERIFICAR_20260915_0004_proyeccion.sql" 2>&1) && ok "VERIFICAR corre sin errores" || { echo "$OUT" | tail -4; bad "VERIFICAR"; }

echo "== ROLLBACK"
Q -f "$M/20260915_0006_compras_existencia_negativa_ROLLBACK.sql" >/dev/null 2>&1 \
  && [ "$(Q -At -c "select suggested_base from public.fn_purchase_projection('35c5076a-bd85-4a1b-8d1c-ce719c4f9ae6','a0000000-0000-0000-0000-000000000001') where item_id = 'c0000000-0000-0000-0000-00000000000f'")" = "15.0000" ] \
  && ok "rollback de 0006 vuelve a la 0004 (la Salsa pide 15)" || bad "rollback 0006"
Q -f "$M/20260915_0004_compras_f1_proyeccion_ROLLBACK.sql" >/dev/null 2>&1 \
  && [ "$(Q -At -c "select count(*) from pg_proc where proname = 'fn_purchase_projection'")" = "0" ] \
  && ok "rollback quita la función" || bad "rollback"

echo
[ $FAIL -eq 0 ] && echo "RESULTADO: TODO EN VERDE" || { echo "RESULTADO: HAY FALLAS"; exit 1; }
