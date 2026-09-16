#!/usr/bin/env bash
# =============================================================================
# Prueba LOCAL de Compras F0 (20260915_0003 + SEMBRAR_vinculos_suplidor).
# Postgres 15 DESECHABLE con el esquema mínimo; corre los archivos REALES del
# repo. No toca ninguna base real.
#
#   bash supabase/tests/compras_f0_local_test.sh [carpeta_trabajo]
# Variables: PG_BIN (default homebrew postgresql@15), PG_PORT (default 55438).
# =============================================================================
set -u
REPO=$(cd "$(dirname "$0")/../.." && pwd)
M=$REPO/supabase/migrations
PG=${PG_BIN:-/opt/homebrew/opt/postgresql@15/bin}
PORT=${PG_PORT:-55438}
WORK=${1:-$(mktemp -d)}
D=$WORK/pg_compras_f0
rm -rf "$D"; mkdir -p "$D"
"$PG/initdb" -D "$D/data" -U postgres --auth=trust >/dev/null || exit 1
"$PG/pg_ctl" -D "$D/data" -o "-p $PORT -c listen_addresses=127.0.0.1 -c unix_socket_directories=''" \
  -l "$D/log" start -w >/dev/null || { cat "$D/log"; exit 1; }
trap '"$PG/pg_ctl" -D "$D/data" stop -m fast >/dev/null 2>&1' EXIT
Q() { "$PG/psql" -h 127.0.0.1 -p "$PORT" -U postgres -X -q -v ON_ERROR_STOP=1 "$@"; }
FAIL=0
ok()  { echo "  ok     $1"; }
bad() { echo "  FALLA  $1"; FAIL=1; }
run() { # corre SQL y muestra solo los ok/FALLA de test.chk
  local label=$1; shift
  if OUT=$(Q "$@" 2>&1); then echo "$OUT" | grep -E "NOTICE:  (ok|--)" | sed 's/^.*NOTICE:  /  /'; ok "$label";
  else echo "$OUT" | grep -E "NOTICE:  ok|ERROR" | sed 's/^.*NOTICE:  /  /; s/^psql:[^:]*:[0-9]*: //'; bad "$label"; fi
}

echo "== Esquema mínimo"
Q <<'SQL' || { bad "esquema"; exit 1; }
create role authenticated; create role anon;
create schema auth;
create function auth.uid() returns uuid language sql stable as $$ select '99999999-9999-9999-9999-999999999999'::uuid $$;
create type public.purchase_status as enum ('draft','sent','partial','received','cancelled');
create type public.movement_type as enum ('purchase','sale','adjustment','transfer_in','transfer_out','waste','return');
create table public.businesses (id uuid primary key, name text);
create table public.warehouses (id uuid primary key, business_id uuid, name text);
create table public.suppliers (id uuid primary key, business_id uuid, name text, lead_time_days smallint, is_active boolean default true);
create table public.inventory_items (id uuid primary key, business_id uuid, name text, unit text default 'unidad',
  cost numeric default 0, purchase_unit text, pack_size numeric default 1, is_active boolean default true);
create table public.supplier_items (id uuid primary key default gen_random_uuid(), business_id uuid not null,
  supplier_id uuid not null, inventory_item_id uuid not null, supplier_code text, purchase_unit text, pack_size numeric,
  last_price numeric, min_order_qty numeric, notes text, is_active boolean not null default true,
  created_at timestamptz not null default now(), updated_at timestamptz not null default now(),
  constraint supplier_items_unique unique (supplier_id, inventory_item_id));
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
create table public.purchase_receptions (id uuid primary key, business_id uuid, warehouse_id uuid, supplier_id uuid, status text default 'complete');
create table public.purchase_reception_lines (id uuid primary key, reception_id uuid, item_id uuid, quantity_received numeric);
create schema test;
create function test.chk(p_label text, p_ok boolean, p_detail text default '') returns void language plpgsql as $$
begin
  if p_ok is not true then raise exception 'FALLA % %', p_label, coalesce(p_detail, ''); end if;
  raise notice 'ok  %', p_label;
end $$;

-- Negocio B (Penda) y B2 (otro). Bodegas, suplidores e insumos.
insert into public.businesses values ('35c5076a-bd85-4a1b-8d1c-ce719c4f9ae6','Penda'), ('22222222-2222-2222-2222-222222222222','Otro');
insert into public.warehouses values ('a0000000-0000-0000-0000-000000000001','35c5076a-bd85-4a1b-8d1c-ce719c4f9ae6','Principal'),
                                     ('a0000000-0000-0000-0000-000000000002','22222222-2222-2222-2222-222222222222','Otro');
insert into public.suppliers (id, business_id, name, lead_time_days) values
 ('b0000000-0000-0000-0000-00000000000a','35c5076a-bd85-4a1b-8d1c-ce719c4f9ae6','SA', null),
 ('b0000000-0000-0000-0000-00000000000b','35c5076a-bd85-4a1b-8d1c-ce719c4f9ae6','SB', 5),
 ('b0000000-0000-0000-0000-00000000000c','35c5076a-bd85-4a1b-8d1c-ce719c4f9ae6','SC', null),
 ('b0000000-0000-0000-0000-00000000000d','35c5076a-bd85-4a1b-8d1c-ce719c4f9ae6','SD', 3),
 ('b0000000-0000-0000-0000-00000000000e','35c5076a-bd85-4a1b-8d1c-ce719c4f9ae6','SE', null),
 ('b0000000-0000-0000-0000-00000000000f','35c5076a-bd85-4a1b-8d1c-ce719c4f9ae6','SF', null),
 ('b0000000-0000-0000-0000-0000000000ff','22222222-2222-2222-2222-222222222222','SX', null);
insert into public.inventory_items (id, business_id, name, unit, cost, purchase_unit, pack_size) values
 ('c0000000-0000-0000-0000-000000000001','35c5076a-bd85-4a1b-8d1c-ce719c4f9ae6','Refresco','unidad',30,'Caja',24),
 ('c0000000-0000-0000-0000-000000000002','35c5076a-bd85-4a1b-8d1c-ce719c4f9ae6','Queso','lb',200,null,1),
 ('c0000000-0000-0000-0000-000000000003','35c5076a-bd85-4a1b-8d1c-ce719c4f9ae6','Pan','unidad',4,null,1),
 ('c0000000-0000-0000-0000-000000000004','35c5076a-bd85-4a1b-8d1c-ce719c4f9ae6','Nuevo','unidad',15,null,1),
 ('c0000000-0000-0000-0000-000000000005','35c5076a-bd85-4a1b-8d1c-ce719c4f9ae6','Aceite','ml',0,null,1),
 ('c0000000-0000-0000-0000-000000000006','35c5076a-bd85-4a1b-8d1c-ce719c4f9ae6','Harina','lb',0,null,1),
 ('c0000000-0000-0000-0000-0000000000ff','22222222-2222-2222-2222-222222222222','Ajeno','unidad',1,null,1);
SQL
ok "esquema y semilla"

echo "== Migración (dos veces)"
Q -f "$M/20260915_0003_compras_f0_orden_atomica_y_suplidor.sql" >/dev/null 2>&1 \
  && Q -f "$M/20260915_0003_compras_f0_orden_atomica_y_suplidor.sql" >/dev/null 2>&1 \
  && ok "aplicada e idempotente" || { bad "migración"; Q -f "$M/20260915_0003_compras_f0_orden_atomica_y_suplidor.sql" 2>&1 | tail -5; exit 1; }

echo "== Crear orden de compra"
run "orden atómica" <<'SQL'
do $$
declare r jsonb; r2 jsonb; n int; i int;
  B constant uuid := '35c5076a-bd85-4a1b-8d1c-ce719c4f9ae6'; W constant uuid := 'a0000000-0000-0000-0000-000000000001';
  SA constant uuid := 'b0000000-0000-0000-0000-00000000000a';
begin
  r := public.fn_purchase_order_create(B, W, SA,
    '[{"inventory_item_id":"c0000000-0000-0000-0000-000000000001","description":"Refresco","quantity_ordered":48,"unit_cost":25,"tax_rate":18,"total":1200,"purchase_unit":"Caja","pack_size":24,"discount":10}]',
    'draft', '2026-09-20', '{"subtotal":1200,"tax":216,"total":1416,"notes":"prueba","invoice_number":"F-1"}');
  perform test.chk('T1 número PO-00001', r->>'order_number' = 'PO-00001', r::text);
  perform test.chk('T1 foto del empaque y descuento de la línea', exists (select 1 from purchase_order_items
    where purchase_order_id = (r->>'id')::uuid and purchase_unit = 'Caja' and pack_size = 24 and discount = 10 and quantity_ordered = 48));
  perform test.chk('T1 cabecera draft con totales, factura y creador', exists (select 1 from purchase_orders
    where id = (r->>'id')::uuid and status = 'draft' and total = 1416 and invoice_number = 'F-1' and created_by is not null));

  r := public.fn_purchase_order_create(B, W, SA, '[{"quantity_ordered":1,"unit_cost":1,"description":"libre"}]', 'sent');
  perform test.chk('T2 siguiente PO-00002 (sent, línea libre sin insumo)', r->>'order_number' = 'PO-00002', r::text);

  r := public.fn_purchase_order_create(B, W, null, '[{"quantity_ordered":1,"unit_cost":1}]', 'draft', null, '{"order_number":"FAC-9"}');
  perform test.chk('T3 número pedido y libre se respeta', r->>'order_number' = 'FAC-9', r::text);
  r := public.fn_purchase_order_create(B, W, null, '[{"quantity_ordered":1,"unit_cost":1}]', 'draft', null, '{"order_number":"PO-00001"}');
  perform test.chk('T3 número pedido OCUPADO → el siguiente', r->>'order_number' = 'PO-00003', r::text);

  select count(*) into n from purchase_orders;
  r  := public.fn_purchase_order_create(B, W, SA, '[{"quantity_ordered":2,"unit_cost":3}]', 'draft', null, '{}', 'clic-1');
  r2 := public.fn_purchase_order_create(B, W, SA, '[{"quantity_ordered":2,"unit_cost":3}]', 'draft', null, '{}', 'clic-1');
  perform test.chk('T4 doble clic devuelve la MISMA orden', r->>'id' = r2->>'id' and (r2->>'reused')::boolean, r2::text);
  perform test.chk('T4 y crea una sola', (select count(*) from purchase_orders) = n + 1);
  perform test.chk('T4 sin líneas duplicadas', (select count(*) from purchase_order_items where purchase_order_id = (r->>'id')::uuid) = 1);

  insert into purchase_orders (business_id, warehouse_id, order_number) values (B, W, 'PO-00007');
  r := public.fn_purchase_order_create(B, W, SA, '[{"quantity_ordered":1,"unit_cost":1}]');
  perform test.chk('T9 respeta la numeración existente (PO-00007 → PO-00008)', r->>'order_number' = 'PO-00008', r::text);
end $$;

-- Errores: cada uno debe fallar con su código y NO dejar nada escrito.
do $$
declare n_o int := (select count(*) from purchase_orders); n_i int := (select count(*) from purchase_order_items);
  B constant uuid := '35c5076a-bd85-4a1b-8d1c-ce719c4f9ae6'; W constant uuid := 'a0000000-0000-0000-0000-000000000001';
  msg text;
  procedure_ok boolean;
begin
  begin
    perform public.fn_purchase_order_create(B, W, null, '[{"quantity_ordered":1,"unit_cost":1}]', 'received');
    msg := 'no falló';
  exception when others then msg := sqlerrm; end;
  perform test.chk('T5 received se rechaza (B1)', msg like 'PURCHASE_ORDER_INVALID_STATUS%', msg);
  begin
    perform public.fn_purchase_order_create(B, W, null, '[{"quantity_ordered":1,"unit_cost":1}]', 'pending');
    msg := 'no falló';
  exception when others then msg := sqlerrm; end;
  perform test.chk('T5 pending (el valor de Reorden) se rechaza con motivo', msg like 'PURCHASE_ORDER_INVALID_STATUS%', msg);
  begin
    perform public.fn_purchase_order_create(B, W, null,
      '[{"inventory_item_id":"c0000000-0000-0000-0000-000000000001","quantity_ordered":5,"unit_cost":1},{"quantity_ordered":0,"unit_cost":1}]');
    msg := 'no falló';
  exception when others then msg := sqlerrm; end;
  perform test.chk('T6 línea mala → error', msg like 'PURCHASE_ORDER_LINE_INVALID%', msg);
  begin
    perform public.fn_purchase_order_create(B, W, null, '[{"inventory_item_id":"c0000000-0000-0000-0000-0000000000ff","quantity_ordered":1,"unit_cost":1}]');
    msg := 'no falló';
  exception when others then msg := sqlerrm; end;
  perform test.chk('T7 insumo de otro negocio → error', msg like 'PURCHASE_ORDER_ITEM_INVALID%', msg);
  begin
    perform public.fn_purchase_order_create(B, 'a0000000-0000-0000-0000-000000000002', null, '[{"quantity_ordered":1,"unit_cost":1}]');
    msg := 'no falló';
  exception when others then msg := sqlerrm; end;
  perform test.chk('T8 almacén de otro negocio → error', msg like 'PURCHASE_ORDER_INVALID%', msg);
  begin
    perform public.fn_purchase_order_create(B, W, null, '[]');
    msg := 'no falló';
  exception when others then msg := sqlerrm; end;
  perform test.chk('T10 sin líneas → error', msg like 'PURCHASE_ORDER_EMPTY%', msg);
  perform test.chk('T5–T10 no quedó ninguna cabecera ni línea huérfana',
    (select count(*) from purchase_orders) = n_o and (select count(*) from purchase_order_items) = n_i);
end $$;
SQL

echo "== A quién se le compra"
run "resolver de suplidor" <<'SQL'
-- Historia de compras RECIBIDAS (movimientos) por las tres puertas.
insert into public.purchase_orders (id, business_id, supplier_id, warehouse_id, order_number, status) values
 ('d0000000-0000-0000-0000-00000000000a','35c5076a-bd85-4a1b-8d1c-ce719c4f9ae6','b0000000-0000-0000-0000-00000000000a','a0000000-0000-0000-0000-000000000001','H-A','received'),
 ('d0000000-0000-0000-0000-00000000000b','35c5076a-bd85-4a1b-8d1c-ce719c4f9ae6','b0000000-0000-0000-0000-00000000000b','a0000000-0000-0000-0000-000000000001','H-B','received'),
 ('d0000000-0000-0000-0000-00000000000c','35c5076a-bd85-4a1b-8d1c-ce719c4f9ae6','b0000000-0000-0000-0000-00000000000c','a0000000-0000-0000-0000-000000000001','H-C','draft'),
 ('d0000000-0000-0000-0000-0000000000ff','22222222-2222-2222-2222-222222222222','b0000000-0000-0000-0000-0000000000ff','a0000000-0000-0000-0000-000000000002','H-X','received');
insert into public.direct_receipts values ('e0000000-0000-0000-0000-00000000000e','35c5076a-bd85-4a1b-8d1c-ce719c4f9ae6','a0000000-0000-0000-0000-000000000001','b0000000-0000-0000-0000-00000000000e');
insert into public.purchase_receptions (id, business_id, warehouse_id, supplier_id) values ('f0000000-0000-0000-0000-00000000000f','35c5076a-bd85-4a1b-8d1c-ce719c4f9ae6','a0000000-0000-0000-0000-000000000001','b0000000-0000-0000-0000-00000000000f');
insert into public.purchase_reception_lines values ('f1000000-0000-0000-0000-000000000001','f0000000-0000-0000-0000-00000000000f','c0000000-0000-0000-0000-000000000003', 10);
insert into public.inventory_movements (business_id, item_id, movement_type, quantity, cost_per_unit, reference_id, reference_type, created_at) values
 ('35c5076a-bd85-4a1b-8d1c-ce719c4f9ae6','c0000000-0000-0000-0000-000000000001','purchase',24,20,'d0000000-0000-0000-0000-00000000000a','purchase_order','2026-08-01'),
 ('35c5076a-bd85-4a1b-8d1c-ce719c4f9ae6','c0000000-0000-0000-0000-000000000001','purchase',24,22,'d0000000-0000-0000-0000-00000000000b','purchase_order','2026-09-01'),
 ('35c5076a-bd85-4a1b-8d1c-ce719c4f9ae6','c0000000-0000-0000-0000-000000000002','purchase',5,180,'d0000000-0000-0000-0000-00000000000a','purchase_order','2026-08-10'),
 ('35c5076a-bd85-4a1b-8d1c-ce719c4f9ae6','c0000000-0000-0000-0000-000000000002','purchase',5,190,'e0000000-0000-0000-0000-00000000000e','direct_receipt','2026-09-05'),
 ('35c5076a-bd85-4a1b-8d1c-ce719c4f9ae6','c0000000-0000-0000-0000-000000000003','purchase',10,6,'d0000000-0000-0000-0000-00000000000b','purchase_order','2026-09-02'),
 ('35c5076a-bd85-4a1b-8d1c-ce719c4f9ae6','c0000000-0000-0000-0000-000000000003','purchase',10,5,'f1000000-0000-0000-0000-000000000001','purchase_reception_line','2026-09-10'),
 ('35c5076a-bd85-4a1b-8d1c-ce719c4f9ae6','c0000000-0000-0000-0000-000000000006','purchase',50,10,'d0000000-0000-0000-0000-00000000000b','purchase_order','2026-09-03'),
 ('22222222-2222-2222-2222-222222222222','c0000000-0000-0000-0000-0000000000ff','purchase',1,1,'d0000000-0000-0000-0000-0000000000ff','purchase_order','2026-09-04');
-- Vínculos: Aceite con UN vínculo (lista por galón); Harina con DOS; Refresco con uno INACTIVO.
insert into public.supplier_items (business_id, supplier_id, inventory_item_id, purchase_unit, pack_size, last_price, min_order_qty, is_active) values
 ('35c5076a-bd85-4a1b-8d1c-ce719c4f9ae6','b0000000-0000-0000-0000-00000000000c','c0000000-0000-0000-0000-000000000005','Galón',3785,757,2,true),
 ('35c5076a-bd85-4a1b-8d1c-ce719c4f9ae6','b0000000-0000-0000-0000-00000000000a','c0000000-0000-0000-0000-000000000006',null,null,null,null,true),
 ('35c5076a-bd85-4a1b-8d1c-ce719c4f9ae6','b0000000-0000-0000-0000-00000000000d','c0000000-0000-0000-0000-000000000006',null,null,null,null,true),
 ('35c5076a-bd85-4a1b-8d1c-ce719c4f9ae6','b0000000-0000-0000-0000-00000000000d','c0000000-0000-0000-0000-000000000001','Caja',24,999,null,false);
-- Pan: preferido SD.
update public.inventory_items set preferred_supplier_id = 'b0000000-0000-0000-0000-00000000000d' where id = 'c0000000-0000-0000-0000-000000000003';

create temporary table r as select * from public.fn_purchase_resolve_suppliers('35c5076a-bd85-4a1b-8d1c-ce719c4f9ae6');
do $$
declare x record;
begin
  perform test.chk('R0 solo insumos del negocio (6, sin el ajeno)', (select count(*) from r) = 6, (select count(*)::text from r));
  select * into x from r where item_id = 'c0000000-0000-0000-0000-000000000001';
  perform test.chk('R1 Refresco: última compra RECIBIDA = SB, no el borrador de SC ni el vínculo inactivo',
    x.supplier_id = 'b0000000-0000-0000-0000-00000000000b' and x.supplier_source = 'ultima_compra', row_to_json(x)::text);
  perform test.chk('R1 costo de la última compra a SB (22), tiempo de entrega 5, caja de 24',
    x.unit_cost_base = 22 and x.cost_source = 'ultima_compra' and x.lead_time_days = 5 and x.purchase_unit = 'Caja' and x.pack_size = 24, row_to_json(x)::text);
  select * into x from r where item_id = 'c0000000-0000-0000-0000-000000000002';
  perform test.chk('R6 Queso: la recepción DIRECTA más reciente gana (SE, 190)',
    x.supplier_id = 'b0000000-0000-0000-0000-00000000000e' and x.unit_cost_base = 190, row_to_json(x)::text);
  select * into x from r where item_id = 'c0000000-0000-0000-0000-000000000003';
  perform test.chk('R5 Pan: el PREFERIDO manda sobre el conduce más reciente',
    x.supplier_id = 'b0000000-0000-0000-0000-00000000000d' and x.supplier_source = 'preferido', row_to_json(x)::text);
  perform test.chk('R5 sin compras a SD ni vínculo → costo del insumo (4), entrega 3',
    x.unit_cost_base = 4 and x.cost_source = 'insumo' and x.lead_time_days = 3, row_to_json(x)::text);
  select * into x from r where item_id = 'c0000000-0000-0000-0000-000000000004';
  perform test.chk('R8 Nuevo: sin suplidor, costo del insumo',
    x.supplier_id is null and x.supplier_source is null and x.unit_cost_base = 15, row_to_json(x)::text);
  select * into x from r where item_id = 'c0000000-0000-0000-0000-000000000005';
  perform test.chk('R3/R9 Aceite: único vínculo (SC), galón de 3785 mL, lista 757/galón = 0.2 por mL, mínimo 2',
    x.supplier_id = 'b0000000-0000-0000-0000-00000000000c' and x.supplier_source = 'vinculo'
    and x.purchase_unit = 'Galón' and x.pack_size = 3785 and x.unit_cost_base = 0.2
    and x.cost_source = 'lista' and x.min_order_qty = 2, row_to_json(x)::text);
  select * into x from r where item_id = 'c0000000-0000-0000-0000-000000000006';
  perform test.chk('R4 Harina: con DOS vínculos no se adivina → última compra (SB, 10)',
    x.supplier_id = 'b0000000-0000-0000-0000-00000000000b' and x.supplier_source = 'ultima_compra' and x.unit_cost_base = 10, row_to_json(x)::text);
  perform test.chk('R10 filtro por ids devuelve solo esos',
    (select count(*) from public.fn_purchase_resolve_suppliers('35c5076a-bd85-4a1b-8d1c-ce719c4f9ae6',
      array['c0000000-0000-0000-0000-000000000001','c0000000-0000-0000-0000-000000000004']::uuid[])) = 2);
end $$;
SQL

echo "== Sembrar vínculos desde las compras"
Q <<'SQL' >/dev/null
-- Casos que la siembra NO debe tocar: vínculo activo con precio a mano (Queso-SE)
-- y vínculo desactivado a mano (Pan-SB).
insert into public.supplier_items (business_id, supplier_id, inventory_item_id, last_price, is_active) values
 ('35c5076a-bd85-4a1b-8d1c-ce719c4f9ae6','b0000000-0000-0000-0000-00000000000e','c0000000-0000-0000-0000-000000000002',999,true),
 ('35c5076a-bd85-4a1b-8d1c-ce719c4f9ae6','b0000000-0000-0000-0000-00000000000b','c0000000-0000-0000-0000-000000000003',null,false);
SQL
OUT=$(Q -f "$REPO/supabase/SEMBRAR_vinculos_suplidor.sql" 2>&1) && echo "$OUT" | grep -E "\|" | sed 's/^/    /' || { echo "$OUT" | tail -5; bad "siembra"; }
run "siembra: resultados" <<'SQL'
do $$ begin
  perform test.chk('S1 Refresco-SA sembrado: 20 × caja de 24 = 480 por Caja',
    exists (select 1 from supplier_items where supplier_id = 'b0000000-0000-0000-0000-00000000000a' and inventory_item_id = 'c0000000-0000-0000-0000-000000000001'
            and last_price = 480 and purchase_unit = 'Caja' and pack_size = 24 and is_active));
  perform test.chk('S1 Refresco-SB sembrado a 528',
    exists (select 1 from supplier_items where supplier_id = 'b0000000-0000-0000-0000-00000000000b' and inventory_item_id = 'c0000000-0000-0000-0000-000000000001' and last_price = 528));
  perform test.chk('S1 Queso-SA sembrado sin empaque (180)',
    exists (select 1 from supplier_items where supplier_id = 'b0000000-0000-0000-0000-00000000000a' and inventory_item_id = 'c0000000-0000-0000-0000-000000000002' and last_price = 180 and purchase_unit is null));
  perform test.chk('S1 Pan-SF sembrado desde el conduce (5)',
    exists (select 1 from supplier_items where supplier_id = 'b0000000-0000-0000-0000-00000000000f' and inventory_item_id = 'c0000000-0000-0000-0000-000000000003' and last_price = 5));
  perform test.chk('S2 NO pisa el precio puesto a mano (Queso-SE sigue en 999)',
    exists (select 1 from supplier_items where supplier_id = 'b0000000-0000-0000-0000-00000000000e' and inventory_item_id = 'c0000000-0000-0000-0000-000000000002' and last_price = 999));
  perform test.chk('S2 NO reactiva lo desactivado a mano (Pan-SB)',
    exists (select 1 from supplier_items where supplier_id = 'b0000000-0000-0000-0000-00000000000b' and inventory_item_id = 'c0000000-0000-0000-0000-000000000003' and not is_active));
  perform test.chk('S3 el otro negocio no recibe vínculos',
    not exists (select 1 from supplier_items where business_id = '22222222-2222-2222-2222-222222222222'));
  perform test.chk('S4 respaldo con exactamente lo sembrado (5)', (select count(*) from backup_supplier_items_seed) = 5,
    (select count(*)::text from backup_supplier_items_seed));
end $$;
SQL
Q -f "$REPO/supabase/SEMBRAR_vinculos_suplidor.sql" >/dev/null 2>&1
run "siembra dos veces" <<'SQL'
do $$ begin
  perform test.chk('S5 la segunda corrida no siembra nada', (select count(*) from backup_supplier_items_seed) = 5);
end $$;
SQL
Q -c "update public.supplier_items set last_price = 530 where supplier_id = 'b0000000-0000-0000-0000-00000000000b' and inventory_item_id = 'c0000000-0000-0000-0000-000000000001'" >/dev/null
Q -f "$REPO/supabase/SEMBRAR_vinculos_suplidor_ROLLBACK.sql" >/dev/null 2>&1 || bad "rollback de la siembra"
run "rollback de la siembra" <<'SQL'
do $$ begin
  perform test.chk('S6 el rollback respeta el precio corregido después (Refresco-SB en 530)',
    exists (select 1 from supplier_items where supplier_id = 'b0000000-0000-0000-0000-00000000000b' and inventory_item_id = 'c0000000-0000-0000-0000-000000000001' and last_price = 530));
  perform test.chk('S6 y borra los otros 4 sembrados',
    not exists (select 1 from supplier_items where notes = 'Sembrado desde compras recibidas' and last_price <> 530));
  perform test.chk('S6 lo que existía antes de sembrar queda intacto (6 vínculos)',
    exists (select 1 from supplier_items where supplier_id = 'b0000000-0000-0000-0000-00000000000e' and inventory_item_id = 'c0000000-0000-0000-0000-000000000002' and last_price = 999)
    and exists (select 1 from supplier_items where supplier_id = 'b0000000-0000-0000-0000-00000000000b' and inventory_item_id = 'c0000000-0000-0000-0000-000000000003' and not is_active)
    and exists (select 1 from supplier_items where supplier_id = 'b0000000-0000-0000-0000-00000000000c' and inventory_item_id = 'c0000000-0000-0000-0000-000000000005' and purchase_unit = 'Galón')
    and exists (select 1 from supplier_items where supplier_id = 'b0000000-0000-0000-0000-00000000000d' and inventory_item_id = 'c0000000-0000-0000-0000-000000000001' and not is_active and last_price = 999)
    and (select count(*) from supplier_items where inventory_item_id = 'c0000000-0000-0000-0000-000000000006') = 2);
end $$;
SQL

echo "== ROLLBACK de la migración y reaplicar"
Q -f "$M/20260915_0003_compras_f0_orden_atomica_y_suplidor_ROLLBACK.sql" >/dev/null 2>&1 \
  && [ "$(Q -At -c "select count(*) from pg_proc where proname in ('fn_purchase_order_create','fn_purchase_resolve_suppliers')")" = "0" ] \
  && [ "$(Q -At -c "select count(*) from information_schema.columns where table_name='purchase_orders' and column_name='idempotency_key'")" = "0" ] \
  && ok "rollback quita funciones y llave" || bad "rollback de la migración"
Q -f "$M/20260915_0003_compras_f0_orden_atomica_y_suplidor.sql" >/dev/null 2>&1 && ok "se vuelve a aplicar" || bad "reaplicar"

echo "== Verificación posterior (el archivo que corre el dueño en prod)"
if OUT=$(Q -f "$REPO/supabase/VERIFICAR_20260915_0003_compras.sql" 2>&1); then
  echo "$OUT" | grep -E "\| (true|false)" | sed 's/^/    /'
  echo "$OUT" | grep -q "| false" && bad "VERIFICAR reporta una pieza faltante" || ok "VERIFICAR corre y todas las piezas están"
else echo "$OUT" | tail -5; bad "VERIFICAR falla"; fi

echo
[ $FAIL -eq 0 ] && echo "RESULTADO: TODO EN VERDE" || { echo "RESULTADO: HAY FALLAS"; exit 1; }
