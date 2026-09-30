#!/usr/bin/env bash
# =============================================================================
# Prueba LOCAL de "Anular compra registrada" (20260929_0050).
# Postgres 15 DESECHABLE con el esquema mínimo; corre los archivos REALES del
# repo (primero la edición 20260923_0002, porque la anulación tiene que
# deshacer también lo que una corrección movió). No toca ninguna base real.
#
#   bash supabase/tests/purchase_order_cancel_local_test.sh [carpeta_trabajo]
# Variables: PG_BIN (default homebrew postgresql@15), PG_PORT (default 55443).
# =============================================================================
set -u
REPO=$(cd "$(dirname "$0")/../.." && pwd)
M=$REPO/supabase/migrations
PG=${PG_BIN:-/opt/homebrew/opt/postgresql@15/bin}
PORT=${PG_PORT:-55443}
WORK=${1:-$(mktemp -d)}
D=$WORK/pg_po_cancel
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
  ('88888888-8888-8888-8888-888888888888');  -- mesero sin permiso

-- auth.uid() conmutable, para probar el gate de permisos.
create function auth.uid() returns uuid language sql stable as $$
  select coalesce(nullif(current_setting('test.uid', true), ''),
                  '99999999-9999-9999-9999-999999999999')::uuid
$$;

create type public.purchase_status as enum ('draft','sent','partial','received','cancelled');
create type public.movement_type as enum ('purchase','sale','adjustment','transfer_in','transfer_out','waste','return');

create table public.businesses (id uuid primary key, name text);
create table public.warehouses (id uuid primary key, business_id uuid, name text);
create table public.suppliers (id uuid primary key, business_id uuid, name text, is_active boolean default true);
create table public.inventory_items (id uuid primary key, business_id uuid, name text, unit text default 'unidad',
  cost numeric default 0, is_active boolean default true);

create table public.purchase_orders (id uuid primary key default gen_random_uuid(), business_id uuid not null,
  supplier_id uuid, warehouse_id uuid, order_number text not null, status public.purchase_status default 'draft',
  subtotal numeric default 0, tax numeric default 0, total numeric default 0, notes text, expected_date date,
  received_date date, created_by uuid, created_at timestamptz default now());
create table public.purchase_order_items (id uuid primary key default gen_random_uuid(),
  purchase_order_id uuid not null references public.purchase_orders(id) on delete cascade, inventory_item_id uuid,
  description text, quantity_ordered numeric not null, quantity_received numeric default 0, unit_cost numeric not null,
  tax_rate numeric default 18, total numeric not null);

create table public.inventory_movements (id uuid primary key default gen_random_uuid(), business_id uuid,
  warehouse_id uuid not null, item_id uuid not null, movement_type public.movement_type not null, quantity numeric not null,
  cost_per_unit numeric, reference_id uuid, reference_type text, notes text, created_by uuid,
  created_at timestamptz default now());
create table public.inventory_stock (id uuid primary key default gen_random_uuid(), warehouse_id uuid, item_id uuid,
  quantity numeric default 0, last_updated timestamptz, unique (warehouse_id, item_id));

create table public.purchase_receptions (id uuid primary key default gen_random_uuid(), business_id uuid,
  warehouse_id uuid, purchase_order_id uuid, supplier_id uuid, status text default 'complete');
create table public.purchase_reception_lines (id uuid primary key default gen_random_uuid(), reception_id uuid,
  purchase_order_item_id uuid references public.purchase_order_items(id), item_id uuid,
  quantity_received numeric, actual_unit_cost numeric);

create table public.supplier_credits (id uuid primary key default gen_random_uuid(), business_id uuid not null,
  supplier_id uuid not null, purchase_order_id uuid references public.purchase_orders(id), invoice_number text,
  original_amount numeric not null check (original_amount > 0), balance numeric not null, due_date date,
  status text not null default 'pending', notes text, created_by uuid, created_at timestamptz not null default now());
create table public.supplier_credit_payments (id uuid primary key default gen_random_uuid(),
  supplier_credit_id uuid not null references public.supplier_credits(id) on delete cascade,
  amount numeric not null check (amount > 0), created_at timestamptz not null default now());

create table public.permissions (id uuid primary key default gen_random_uuid(), code text unique not null,
  name text, module text, description text);
create table public.roles (id uuid primary key default gen_random_uuid(), business_id uuid, name text,
  is_system boolean default false);
create table public.role_permissions (role_id uuid, permission_id uuid, allow boolean default true,
  primary key (role_id, permission_id));
insert into public.roles (name, is_system) values ('owner', true), ('admin', true), ('manager', true), ('waiter', true);

-- Membresías: el dueño es owner de B; el mesero no tiene rol elevado.
create table public.memberships (user_id uuid, business_id uuid, role text);
insert into public.memberships values
  ('99999999-9999-9999-9999-999999999999','11111111-1111-1111-1111-111111111111','owner'),
  ('88888888-8888-8888-8888-888888888888','11111111-1111-1111-1111-111111111111','waiter');

create function public.user_business_role(p_user uuid, p_business uuid) returns text
language sql stable as $$ select role from public.memberships where user_id=p_user and business_id=p_business $$;
create function public.user_has_business_access(p_user uuid, p_business uuid) returns boolean
language sql stable as $$ select exists (select 1 from public.memberships where user_id=p_user and business_id=p_business) $$;
-- En la prueba nadie tiene el permiso suelto: el gate se decide por rol.
create function public.user_has_business_permission(p_business uuid, p_code text) returns boolean
language sql stable as $$ select false $$;

-- Triggers reales del inventario (20260308_0016 + 20260714_0001), copiados
-- para que el efecto sobre stock y costo maestro sea el de producción.
create function public.fn_sync_inventory_stock_on_movement() returns trigger
language plpgsql as $$
begin
  insert into public.inventory_stock (warehouse_id, item_id, quantity, last_updated)
  values (new.warehouse_id, new.item_id, new.quantity, now())
  on conflict (warehouse_id, item_id) do update
    set quantity = public.inventory_stock.quantity + excluded.quantity, last_updated = now();
  return new;
end $$;
create trigger trg_inventory_stock_sync after insert on public.inventory_movements
for each row execute function public.fn_sync_inventory_stock_on_movement();

create function public.fn_inventory_movement_recost() returns trigger
language plpgsql as $$
begin
  if new.movement_type <> 'purchase' then return new; end if;
  if new.cost_per_unit is null or new.cost_per_unit <= 0 then return new; end if;
  if new.quantity is null or new.quantity <= 0 then return new; end if;
  update public.inventory_items set cost = round(new.cost_per_unit::numeric, 4)
   where id = new.item_id and business_id = new.business_id;
  return new;
end $$;
create trigger trg_inventory_movement_recost after insert on public.inventory_movements
for each row execute function public.fn_inventory_movement_recost();

create schema test;
create function test.chk(p_label text, p_ok boolean, p_detail text default '') returns void language plpgsql as $$
begin
  if p_ok is not true then raise exception 'FALLA % %', p_label, coalesce(p_detail, ''); end if;
  raise notice 'ok  %', p_label;
end $$;

-- Datos: negocio, dos bodegas, un suplidor, dos insumos.
insert into public.businesses values ('11111111-1111-1111-1111-111111111111','Bar');
insert into public.warehouses values
  ('a0000000-0000-0000-0000-000000000001','11111111-1111-1111-1111-111111111111','Principal'),
  ('a0000000-0000-0000-0000-000000000002','11111111-1111-1111-1111-111111111111','Bodega 2');
insert into public.suppliers (id, business_id, name) values
  ('b0000000-0000-0000-0000-00000000000a','11111111-1111-1111-1111-111111111111','Peralta'),
  ('b0000000-0000-0000-0000-00000000000b','11111111-1111-1111-1111-111111111111','Servifria');
insert into public.inventory_items (id, business_id, name, cost) values
  ('c0000000-0000-0000-0000-000000000001','11111111-1111-1111-1111-111111111111','Ron Barcelo', 500),
  ('c0000000-0000-0000-0000-000000000002','11111111-1111-1111-1111-111111111111','Presidente', 85);

-- Helper: arma una orden RECIBIDA (líneas + stock + conduce), como en prod.
create function test.seed_order(p_num text, p_qty numeric, p_cost numeric)
returns uuid language plpgsql as $$
declare v_po uuid; v_poi uuid; v_rec uuid;
begin
  insert into public.purchase_orders (business_id, supplier_id, warehouse_id, order_number, status,
    subtotal, tax, total, expected_date, received_date)
  values ('11111111-1111-1111-1111-111111111111','b0000000-0000-0000-0000-00000000000a',
          'a0000000-0000-0000-0000-000000000001', p_num, 'received',
          p_qty*p_cost, p_qty*p_cost*0.18, p_qty*p_cost*1.18, current_date, current_date)
  returning id into v_po;
  insert into public.purchase_order_items (purchase_order_id, inventory_item_id, description,
    quantity_ordered, quantity_received, unit_cost, tax_rate, total)
  values (v_po, 'c0000000-0000-0000-0000-000000000001', 'Ron Barcelo', p_qty, p_qty, p_cost, 18, p_qty*p_cost)
  returning id into v_poi;
  insert into public.purchase_receptions (business_id, warehouse_id, purchase_order_id, supplier_id)
  values ('11111111-1111-1111-1111-111111111111','a0000000-0000-0000-0000-000000000001', v_po,
          'b0000000-0000-0000-0000-00000000000a') returning id into v_rec;
  insert into public.purchase_reception_lines (reception_id, purchase_order_item_id, item_id,
    quantity_received, actual_unit_cost)
  values (v_rec, v_poi, 'c0000000-0000-0000-0000-000000000001', p_qty, p_cost);
  insert into public.inventory_movements (business_id, warehouse_id, item_id, movement_type, quantity,
    cost_per_unit, reference_id, reference_type)
  values ('11111111-1111-1111-1111-111111111111','a0000000-0000-0000-0000-000000000001',
          'c0000000-0000-0000-0000-000000000001','purchase', p_qty, p_cost, v_poi, 'purchase_reception_line');
  return v_po;
end $$;

create function test.line_of(p_po uuid) returns uuid language sql as $$
  select id from public.purchase_order_items where purchase_order_id = p_po order by id limit 1 $$;
create function test.stock(p_wh uuid, p_item uuid) returns numeric language sql as $$
  select coalesce(quantity, 0) from public.inventory_stock where warehouse_id=p_wh and item_id=p_item $$;
SQL
ok "esquema mínimo + triggers reales"

echo "== Migraciones reales: 20260923_0002 (edición) + 20260929_0050 (anulación)"
run "aplica la edición"      -f "$M/20260923_0002_purchase_order_edit.sql"
run "aplica la anulación"    -f "$M/20260929_0050_purchase_order_cancel.sql"
run "anulación idempotente"  -f "$M/20260929_0050_purchase_order_cancel.sql"

echo "== Comportamiento"
run "casos" <<'SQL'
-- Helpers propios de la anulación.
-- En producción (fn_receive_purchase_order_v2 / conduce) el movimiento apunta a
-- la LÍNEA DEL CONDUCE, no a la línea de la orden: la anulación depende de eso.
create or replace function test.seed_order(p_num text, p_qty numeric, p_cost numeric)
returns uuid language plpgsql as $$
declare v_po uuid; v_poi uuid; v_rec uuid; v_prl uuid;
begin
  insert into public.purchase_orders (business_id, supplier_id, warehouse_id, order_number, status,
    subtotal, tax, total, expected_date, received_date)
  values ('11111111-1111-1111-1111-111111111111','b0000000-0000-0000-0000-00000000000a',
          'a0000000-0000-0000-0000-000000000001', p_num, 'received',
          p_qty*p_cost, p_qty*p_cost*0.18, p_qty*p_cost*1.18, current_date, current_date)
  returning id into v_po;
  insert into public.purchase_order_items (purchase_order_id, inventory_item_id, description,
    quantity_ordered, quantity_received, unit_cost, tax_rate, total)
  values (v_po, 'c0000000-0000-0000-0000-000000000001', 'Ron Barcelo', p_qty, p_qty, p_cost, 18, p_qty*p_cost)
  returning id into v_poi;
  insert into public.purchase_receptions (business_id, warehouse_id, purchase_order_id, supplier_id)
  values ('11111111-1111-1111-1111-111111111111','a0000000-0000-0000-0000-000000000001', v_po,
          'b0000000-0000-0000-0000-00000000000a') returning id into v_rec;
  insert into public.purchase_reception_lines (reception_id, purchase_order_item_id, item_id,
    quantity_received, actual_unit_cost)
  values (v_rec, v_poi, 'c0000000-0000-0000-0000-000000000001', p_qty, p_cost) returning id into v_prl;
  insert into public.inventory_movements (business_id, warehouse_id, item_id, movement_type, quantity,
    cost_per_unit, reference_id, reference_type)
  values ('11111111-1111-1111-1111-111111111111','a0000000-0000-0000-0000-000000000001',
          'c0000000-0000-0000-0000-000000000001','purchase', p_qty, p_cost, v_prl, 'purchase_reception_line');
  return v_po;
end $$;
-- En producción cada compra/edición es SU transacción y trae su propia hora;
-- aquí todos los casos corren en un solo DO, y con now() todos los movimientos
-- empatarían y "la última compra" saldría al azar.
alter table public.inventory_movements alter column created_at set default clock_timestamp();

-- Sin fila de stock = 0 (el helper de la edición devolvía NULL).
create or replace function test.stock(p_wh uuid, p_item uuid) returns numeric language sql as $$
  select coalesce((select quantity from public.inventory_stock
                    where warehouse_id=p_wh and item_id=p_item), 0) $$;
create function test.set_cost(p_item uuid, p_cost numeric) returns void language sql as $$
  update public.inventory_items set cost = p_cost where id = p_item $$;
create function test.cost(p_item uuid) returns numeric language sql as $$
  select cost from public.inventory_items where id = p_item $$;
-- Compra recibida por el camino VIEJO (fn_receive_purchase_order):
-- movimiento con reference_type='purchase_order' y reference_id = la orden.
create function test.seed_legacy(p_num text, p_item uuid, p_qty numeric, p_cost numeric)
returns uuid language plpgsql as $$
declare v_po uuid;
begin
  insert into public.purchase_orders (business_id, supplier_id, warehouse_id, order_number, status,
    subtotal, tax, total, expected_date, received_date)
  values ('11111111-1111-1111-1111-111111111111','b0000000-0000-0000-0000-00000000000a',
          'a0000000-0000-0000-0000-000000000001', p_num, 'received',
          p_qty*p_cost, 0, p_qty*p_cost, current_date, current_date)
  returning id into v_po;
  insert into public.purchase_order_items (purchase_order_id, inventory_item_id, description,
    quantity_ordered, quantity_received, unit_cost, tax_rate, total)
  values (v_po, p_item, 'linea', p_qty, p_qty, p_cost, 0, p_qty*p_cost);
  insert into public.inventory_movements (business_id, warehouse_id, item_id, movement_type, quantity,
    cost_per_unit, reference_id, reference_type)
  values ('11111111-1111-1111-1111-111111111111','a0000000-0000-0000-0000-000000000001',
          p_item,'purchase', p_qty, p_cost, v_po, 'purchase_order');
  return v_po;
end $$;

do $$
declare
  v_po uuid; v_po2 uuid; v_poi uuid; v_res jsonb; v_msg text; v_n int; v_credit uuid;
  v_wh1 uuid := 'a0000000-0000-0000-0000-000000000001';
  v_wh2 uuid := 'a0000000-0000-0000-0000-000000000002';
  v_it1 uuid := 'c0000000-0000-0000-0000-000000000001';
  v_it2 uuid := 'c0000000-0000-0000-0000-000000000002';
  v_base1 numeric; v_base2 numeric; v_mov int;
begin
  -- ── 1. Compra con conduce: vista previa NO escribe nada ──
  perform test.seed_legacy('PO-OLD', v_it1, 5, 480);        -- compra anterior válida
  v_po := test.seed_order('PO-00001', 12, 500);              -- la que se va a anular
  perform test.chk('1 costo maestro lo fijó la última compra', test.cost(v_it1) = 500,
                   test.cost(v_it1)::text);
  v_base1 := test.stock(v_wh1, v_it1);
  select count(*) into v_mov from public.inventory_movements;
  v_res := public.fn_purchase_order_cancel(v_po, null, null, true);
  perform test.chk('1 preview: no crea movimientos',
                   (select count(*) from public.inventory_movements) = v_mov);
  perform test.chk('1 preview: la orden sigue Recibida',
                   (select status::text from public.purchase_orders where id=v_po) = 'received');
  perform test.chk('1 preview: devolvería 12 del Principal',
                   jsonb_array_length(v_res->'lines') = 1
                   and (v_res->'lines'->0->>'quantity')::numeric = 12
                   and (v_res->'lines'->0->>'warehouse_id')::uuid = v_wh1, v_res::text);
  perform test.chk('1 preview: existencia antes/después',
                   (v_res->'lines'->0->>'stock_before')::numeric = v_base1
                   and (v_res->'lines'->0->>'stock_after')::numeric = v_base1 - 12, v_res::text);
  perform test.chk('1 preview: sin negativos', (v_res->>'negative_items')::int = 0);
  perform test.chk('1 preview: 1 conduce por anular', (v_res->>'receptions_to_cancel')::int = 1);

  -- ── 2. Sin motivo no se anula ──
  begin
    perform public.fn_purchase_order_cancel(v_po, '  ', null, false);
    perform test.chk('2 sin motivo debió fallar', false);
  exception when others then v_msg := sqlerrm; end;
  perform test.chk('2 motivo obligatorio', v_msg like 'PURCHASE_ORDER_CANCEL_REASON_REQUIRED%', v_msg);

  -- ── 3. Mesero sin rol ni permiso: rechazado ──
  perform set_config('test.uid', '88888888-8888-8888-8888-888888888888', true);
  begin
    perform public.fn_purchase_order_cancel(v_po, 'Factura duplicada', null, false);
    perform test.chk('3 el mesero no debió poder', false);
  exception when others then v_msg := sqlerrm; end;
  perform set_config('test.uid', '', true);
  perform test.chk('3 permiso exigido', v_msg like 'PURCHASE_ORDER_CANCEL_DENIED%', v_msg);

  -- ── 4. Anular: devuelve la mercancía, restaura costo, cancela conduce ──
  v_res := public.fn_purchase_order_cancel(v_po, 'Factura duplicada', 'key-4', false);
  perform test.chk('4 stock vuelve exacto', test.stock(v_wh1, v_it1) = v_base1 - 12,
                   format('stock=%s base=%s', test.stock(v_wh1, v_it1), v_base1));
  perform test.chk('4 un movimiento de reversa', (v_res->>'movements_created')::int = 1, v_res::text);
  perform test.chk('4 la reversa es purchase NEGATIVA con referencia a la orden',
                   exists (select 1 from public.inventory_movements
                            where reference_type='purchase_order_cancel' and reference_id=v_po
                              and movement_type='purchase' and quantity = -12 and cost_per_unit = 500));
  perform test.chk('4 costo maestro vuelve a la compra válida anterior', test.cost(v_it1) = 480,
                   test.cost(v_it1)::text);
  perform test.chk('4 costo restaurado informado', (v_res->>'costs_restored')::int = 1, v_res::text);
  perform test.chk('4 conduce anulado',
                   (select status from public.purchase_receptions where purchase_order_id=v_po) = 'cancelled');
  perform test.chk('4 orden anulada con quién/cuándo/por qué',
                   (select status::text = 'cancelled' and cancel_reason = 'Factura duplicada'
                           and cancelled_by = '99999999-9999-9999-9999-999999999999'
                           and cancelled_at is not null
                      from public.purchase_orders where id=v_po));
  perform test.chk('4 las líneas NO se tocan',
                   (select quantity_received from public.purchase_order_items where purchase_order_id=v_po) = 12);
  perform test.chk('4 bitácora action=cancel con antes/después',
                   (select count(*) from public.purchase_order_edits
                     where purchase_order_id=v_po and action='cancel' and idempotency_key='key-4'
                       and before_snapshot->'order'->>'status' = 'received'
                       and after_snapshot->'order'->>'status' = 'cancelled') = 1);

  -- ── 5. Doble toque: no hace nada más ──
  select count(*) into v_mov from public.inventory_movements;
  v_res := public.fn_purchase_order_cancel(v_po, 'Factura duplicada', 'key-4', false);
  perform test.chk('5 replay', (v_res->>'replayed')::boolean, v_res::text);
  perform test.chk('5 sin movimientos nuevos', (select count(*) from public.inventory_movements) = v_mov);
  perform test.chk('5 una sola bitácora',
                   (select count(*) from public.purchase_order_edits where purchase_order_id=v_po and action='cancel') = 1);

  -- ── 6. Orden EDITADA y movida de almacén: se devuelve de donde quedó ──
  v_base1 := test.stock(v_wh1, v_it1);
  v_base2 := test.stock(v_wh2, v_it1);
  v_po := test.seed_order('PO-00006', 12, 500);
  v_poi := test.line_of(v_po);
  perform public.fn_purchase_order_update(
    v_po,
    jsonb_build_array(jsonb_build_object('id', v_poi, 'inventory_item_id', v_it1,
      'description','Ron Barcelo','quantity_ordered',10,'unit_cost',540,'tax_rate',18,'total',5400)),
    jsonb_build_object('warehouse_id', v_wh2, 'subtotal',5400,'tax',972,'total',6372));
  perform test.chk('6 tras editar: 10 en Bodega 2, nada nuevo en Principal',
                   test.stock(v_wh2, v_it1) = v_base2 + 10 and test.stock(v_wh1, v_it1) = v_base1,
                   format('wh1=%s wh2=%s', test.stock(v_wh1, v_it1), test.stock(v_wh2, v_it1)));
  v_res := public.fn_purchase_order_cancel(v_po, 'Era de otro local', null, false);
  perform test.chk('6 Principal intacto', test.stock(v_wh1, v_it1) = v_base1,
                   format('wh1=%s base=%s', test.stock(v_wh1, v_it1), v_base1));
  perform test.chk('6 Bodega 2 vuelve a su base', test.stock(v_wh2, v_it1) = v_base2,
                   format('wh2=%s base=%s', test.stock(v_wh2, v_it1), v_base2));
  perform test.chk('6 una sola reversa (neto por almacén)', (v_res->>'movements_created')::int = 1, v_res::text);
  perform test.chk('6 reversa valorada al costo corregido',
                   (v_res->'lines'->0->>'unit_cost')::numeric = 540, v_res::text);
  perform test.chk('6 costo maestro vuelve a 480 (PO-00001 anulada no cuenta)',
                   test.cost(v_it1) = 480, test.cost(v_it1)::text);

  -- ── 7. Línea BORRADA por una edición: no se devuelve dos veces ──
  v_base1 := test.stock(v_wh1, v_it1);
  v_base2 := test.stock(v_wh1, v_it2);
  v_po := test.seed_order('PO-00007', 6, 500);
  v_poi := test.line_of(v_po);
  -- agrega Presidente (entra completa) y luego la borra (se revierte)
  perform public.fn_purchase_order_update(v_po,
    jsonb_build_array(
      jsonb_build_object('id', v_poi, 'inventory_item_id', v_it1, 'quantity_ordered',6,'unit_cost',500,'total',3000),
      jsonb_build_object('inventory_item_id', v_it2, 'quantity_ordered',24,'unit_cost',90,'total',2160)),
    '{}'::jsonb);
  perform public.fn_purchase_order_update(v_po,
    jsonb_build_array(
      jsonb_build_object('id', v_poi, 'inventory_item_id', v_it1, 'quantity_ordered',6,'unit_cost',500,'total',3000)),
    '{}'::jsonb);
  perform test.chk('7 Presidente volvió a su base tras borrar la línea', test.stock(v_wh1, v_it2) = v_base2);
  v_res := public.fn_purchase_order_cancel(v_po, 'Duplicada', null, false);
  perform test.chk('7 Ron vuelve a su base', test.stock(v_wh1, v_it1) = v_base1,
                   format('stock=%s base=%s', test.stock(v_wh1, v_it1), v_base1));
  perform test.chk('7 Presidente NO se descuenta otra vez', test.stock(v_wh1, v_it2) = v_base2,
                   format('stock=%s base=%s', test.stock(v_wh1, v_it2), v_base2));
  perform test.chk('7 solo se revierte el Ron', (v_res->>'movements_created')::int = 1, v_res::text);

  -- ── 8. CxP sin abonos: se cancela con la compra ──
  v_po := test.seed_order('PO-00008', 3, 500);
  insert into public.supplier_credits (business_id, supplier_id, purchase_order_id, original_amount, balance)
  values ('11111111-1111-1111-1111-111111111111','b0000000-0000-0000-0000-00000000000a', v_po, 1770, 1770)
  returning id into v_credit;
  v_res := public.fn_purchase_order_cancel(v_po, null, null, true);
  perform test.chk('8 preview: tiene CxP y no bloquea',
                   (v_res->>'has_payable')::boolean and v_res->>'blocked_reason' is null, v_res::text);
  v_res := public.fn_purchase_order_cancel(v_po, 'Proveedor se la llevó', null, false);
  perform test.chk('8 CxP cancelada con saldo 0',
                   (select status = 'cancelled' and balance = 0 and notes like '%PO-00008%'
                      from public.supplier_credits where id = v_credit));
  perform test.chk('8 informado', (v_res->>'payable_cancelled')::boolean, v_res::text);

  -- ── 9. CxP CON abonos: se rechaza y no cambia NADA ──
  v_po := test.seed_order('PO-00009', 4, 500);
  insert into public.supplier_credits (business_id, supplier_id, purchase_order_id, original_amount, balance, status)
  values ('11111111-1111-1111-1111-111111111111','b0000000-0000-0000-0000-00000000000a', v_po, 2360, 1360, 'partial')
  returning id into v_credit;
  insert into public.supplier_credit_payments (supplier_credit_id, amount) values (v_credit, 1000);
  v_res := public.fn_purchase_order_cancel(v_po, null, null, true);
  perform test.chk('9 preview avisa el bloqueo',
                   v_res->>'blocked_reason' = 'PURCHASE_ORDER_PAYABLE_HAS_PAYMENTS'
                   and (v_res->>'payable_paid')::numeric = 1000, v_res::text);
  v_base1 := test.stock(v_wh1, v_it1);
  begin
    perform public.fn_purchase_order_cancel(v_po, 'Intento', null, false);
    perform test.chk('9 debió rechazarse', false);
  exception when others then v_msg := sqlerrm; end;
  perform test.chk('9 rechazo por abonos', v_msg like 'PURCHASE_ORDER_PAYABLE_HAS_PAYMENTS%', v_msg);
  perform test.chk('9 stock intacto', test.stock(v_wh1, v_it1) = v_base1);
  perform test.chk('9 orden sigue Recibida',
                   (select status::text from public.purchase_orders where id=v_po) = 'received');
  perform test.chk('9 CxP intacta',
                   (select status = 'partial' and balance = 1360 from public.supplier_credits where id=v_credit));

  -- ── 10. Orden sin recibir: se anula sin tocar el kardex ──
  insert into public.purchase_orders (business_id, supplier_id, warehouse_id, order_number, status, total)
  values ('11111111-1111-1111-1111-111111111111','b0000000-0000-0000-0000-00000000000a', v_wh1,
          'PO-00010', 'sent', 100) returning id into v_po;
  insert into public.purchase_order_items (purchase_order_id, inventory_item_id, quantity_ordered,
    quantity_received, unit_cost, total)
  values (v_po, v_it1, 2, 0, 50, 100);
  v_res := public.fn_purchase_order_cancel(v_po, 'Ya no se pide', null, false);
  perform test.chk('10 sin movimientos', (v_res->>'movements_created')::int = 0, v_res::text);
  perform test.chk('10 anulada', (select status::text from public.purchase_orders where id=v_po) = 'cancelled');

  -- ── 11. Mercancía ya vendida: queda en negativo y se AVISA ──
  insert into public.inventory_items (id, business_id, name, cost)
  values ('c0000000-0000-0000-0000-000000000003','11111111-1111-1111-1111-111111111111','Hielo', 0);
  v_po := test.seed_legacy('PO-00011', 'c0000000-0000-0000-0000-000000000003', 12, 30);
  insert into public.inventory_movements (business_id, warehouse_id, item_id, movement_type, quantity)
  values ('11111111-1111-1111-1111-111111111111', v_wh1, 'c0000000-0000-0000-0000-000000000003', 'sale', -10);
  v_res := public.fn_purchase_order_cancel(v_po, null, null, true);
  perform test.chk('11 preview avisa 1 negativo', (v_res->>'negative_items')::int = 1
                   and (v_res->'lines'->0->>'stock_after')::numeric = -10, v_res::text);
  v_res := public.fn_purchase_order_cancel(v_po, 'Mal digitada', null, false);
  perform test.chk('11 camino viejo (reference=orden) también se revierte',
                   test.stock(v_wh1, 'c0000000-0000-0000-0000-000000000003') = -10,
                   test.stock(v_wh1, 'c0000000-0000-0000-0000-000000000003')::text);
  perform test.chk('11 sin compra anterior, el costo se deja', test.cost('c0000000-0000-0000-0000-000000000003') = 30);

  -- ── 12. Costo maestro NO se toca si alguien lo cambió después, ni si hay
  --        una compra más nueva de otra orden ──
  perform test.seed_legacy('PO-12A', v_it2, 10, 95);         -- base 95
  v_po := test.seed_legacy('PO-12B', v_it2, 10, 100);        -- fija 100
  perform test.set_cost(v_it2, 111);                         -- cambio manual
  perform public.fn_purchase_order_cancel(v_po, 'Prueba manual', null, false);
  perform test.chk('12a cambio manual se respeta', test.cost(v_it2) = 111, test.cost(v_it2)::text);
  v_po := test.seed_legacy('PO-12C', v_it2, 10, 120);        -- fija 120
  v_po2 := test.seed_legacy('PO-12D', v_it2, 10, 130);       -- más nueva: fija 130
  perform public.fn_purchase_order_cancel(v_po, 'Prueba nueva', null, false);
  perform test.chk('12b una compra más nueva manda', test.cost(v_it2) = 130, test.cost(v_it2)::text);
  perform public.fn_purchase_order_cancel(v_po2, 'Prueba anterior', null, false);
  perform test.chk('12c al anular la más nueva vuelve a la última VÁLIDA (95, no 120/100 anuladas)',
                   test.cost(v_it2) = 95, test.cost(v_it2)::text);

  -- ── 13. Permiso en el catálogo ──
  perform test.chk('13 compras.ordenes.anular para owner/admin/manager',
                   (select count(*) from public.role_permissions rp
                     join public.roles r on r.id = rp.role_id
                     join public.permissions p on p.id = rp.permission_id
                    where p.code='compras.ordenes.anular' and r.is_system) = 3);
end $$;
SQL

echo "== Rollback"
run "rollback aplica"   -f "$M/20260929_0050_purchase_order_cancel_ROLLBACK.sql"
run "la función ya no existe" <<'SQL'
do $$ begin
  perform test.chk('rollback quitó la función',
    to_regprocedure('public.fn_purchase_order_cancel(uuid,text,text,boolean)') is null);
  perform test.chk('rollback conserva la auditoría',
    exists (select 1 from information_schema.columns
             where table_name='purchase_orders' and column_name='cancel_reason'));
end $$;
SQL

echo
if [ "$FAIL" = 0 ]; then echo "TODO OK"; else echo "HAY FALLAS"; fi
exit $FAIL
