#!/usr/bin/env bash
# =============================================================================
# Prueba LOCAL de "Editar compra registrada" (20260923_0002).
# Postgres 15 DESECHABLE con el esquema mínimo; corre el archivo REAL del repo.
# No toca ninguna base real.
#
#   bash supabase/tests/purchase_order_edit_local_test.sh [carpeta_trabajo]
# Variables: PG_BIN (default homebrew postgresql@15), PG_PORT (default 55441).
# =============================================================================
set -u
REPO=$(cd "$(dirname "$0")/../.." && pwd)
M=$REPO/supabase/migrations
PG=${PG_BIN:-/opt/homebrew/opt/postgresql@15/bin}
PORT=${PG_PORT:-55441}
WORK=${1:-$(mktemp -d)}
D=$WORK/pg_po_edit
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

echo "== Migración real 20260923_0002"
run "aplica"           -f "$M/20260923_0002_purchase_order_edit.sql"
run "es idempotente"   -f "$M/20260923_0002_purchase_order_edit.sql"

echo "== Comportamiento"
run "casos" <<'SQL'
do $$
declare
  v_po uuid; v_poi uuid; v_res jsonb; v_wh1 uuid := 'a0000000-0000-0000-0000-000000000001';
  v_wh2 uuid := 'a0000000-0000-0000-0000-000000000002';
  v_it1 uuid := 'c0000000-0000-0000-0000-000000000001';
  v_it2 uuid := 'c0000000-0000-0000-0000-000000000002';
  v_base numeric; v_n int; v_credit uuid; v_msg text;
begin
  -- ── 1. Editar solo el NCF: no se toca el kardex ──
  v_po := test.seed_order('PO-00001', 12, 500);
  v_poi := test.line_of(v_po);
  v_base := test.stock(v_wh1, v_it1);
  v_res := public.fn_purchase_order_update(
    v_po,
    jsonb_build_array(jsonb_build_object('id', v_poi, 'inventory_item_id', v_it1,
      'description','Ron Barcelo','quantity_ordered',12,'unit_cost',500,'tax_rate',18,'total',6000)),
    jsonb_build_object('ncf','B0100000123','invoice_number','F-1','subtotal',6000,'tax',1080,'total',7080));
  perform test.chk('1 editar NCF no mueve stock', test.stock(v_wh1, v_it1) = v_base,
                   format('stock=%s base=%s', test.stock(v_wh1,v_it1), v_base));
  perform test.chk('1 editar NCF no crea movimientos', (v_res->>'movements_created')::int = 0, v_res::text);
  perform test.chk('1 el NCF quedo guardado',
                   (select ncf from public.purchase_orders where id=v_po) = 'B0100000123');
  perform test.chk('1 sigue Recibida', (v_res->>'status') = 'received', v_res::text);

  -- ── 2. Bajar cantidad 12 → 10 en línea recibida completa ──
  v_base := test.stock(v_wh1, v_it1);
  v_res := public.fn_purchase_order_update(
    v_po,
    jsonb_build_array(jsonb_build_object('id', v_poi, 'inventory_item_id', v_it1,
      'description','Ron Barcelo','quantity_ordered',10,'unit_cost',500,'tax_rate',18,'total',5000)),
    jsonb_build_object('subtotal',5000,'tax',900,'total',5900));
  perform test.chk('2 stock baja exactamente 2', test.stock(v_wh1, v_it1) = v_base - 2,
                   format('stock=%s base=%s', test.stock(v_wh1,v_it1), v_base));
  perform test.chk('2 recibido sigue a la edicion',
                   (select quantity_received from public.purchase_order_items where id=v_poi) = 10);
  perform test.chk('2 reversa + reentrada = 2 movimientos', (v_res->>'movements_created')::int = 2, v_res::text);
  perform test.chk('2 la orden sigue Recibida', (v_res->>'status') = 'received');
  perform test.chk('2 el total quedo corregido',
                   (select total from public.purchase_orders where id=v_po) = 5900);

  -- ── 3. Corregir el costo: el costo maestro queda en el corregido ──
  v_base := test.stock(v_wh1, v_it1);
  v_res := public.fn_purchase_order_update(
    v_po,
    jsonb_build_array(jsonb_build_object('id', v_poi, 'inventory_item_id', v_it1,
      'description','Ron Barcelo','quantity_ordered',10,'unit_cost',540,'tax_rate',18,'total',5400)),
    jsonb_build_object('subtotal',5400,'tax',972,'total',6372));
  perform test.chk('3 el stock no cambia al corregir solo el costo', test.stock(v_wh1, v_it1) = v_base,
                   format('stock=%s base=%s', test.stock(v_wh1,v_it1), v_base));
  perform test.chk('3 costo maestro = costo corregido',
                   (select cost from public.inventory_items where id=v_it1) = 540,
                   (select cost::text from public.inventory_items where id=v_it1));

  -- ── 4. Agregar una línea a una orden ya recibida: entra completa ──
  v_res := public.fn_purchase_order_update(
    v_po,
    jsonb_build_array(
      jsonb_build_object('id', v_poi, 'inventory_item_id', v_it1,
        'description','Ron Barcelo','quantity_ordered',10,'unit_cost',540,'tax_rate',18,'total',5400),
      jsonb_build_object('inventory_item_id', v_it2,
        'description','Presidente','quantity_ordered',24,'unit_cost',90,'tax_rate',18,'total',2160)),
    jsonb_build_object('subtotal',7560,'tax',1360.8,'total',8920.8));
  perform test.chk('4 la linea agregada entra al almacen', test.stock(v_wh1, v_it2) = 24,
                   format('stock=%s', test.stock(v_wh1, v_it2)));
  perform test.chk('4 queda recibida completa',
                   (select quantity_received from public.purchase_order_items
                     where purchase_order_id=v_po and inventory_item_id=v_it2) = 24);
  perform test.chk('4 la orden sigue Recibida', (v_res->>'status') = 'received', v_res::text);

  -- ── 5. Quitar esa línea: devuelve todo su stock ──
  v_res := public.fn_purchase_order_update(
    v_po,
    jsonb_build_array(jsonb_build_object('id', v_poi, 'inventory_item_id', v_it1,
      'description','Ron Barcelo','quantity_ordered',10,'unit_cost',540,'tax_rate',18,'total',5400)),
    jsonb_build_object('subtotal',5400,'tax',972,'total',6372));
  perform test.chk('5 el stock de la linea quitada vuelve a 0', test.stock(v_wh1, v_it2) = 0,
                   format('stock=%s', test.stock(v_wh1, v_it2)));
  perform test.chk('5 la linea ya no esta en la orden',
                   (select count(*) from public.purchase_order_items
                     where purchase_order_id=v_po and inventory_item_id=v_it2) = 0);

  -- ── 6. Mover la compra de almacén ──
  v_base := test.stock(v_wh1, v_it1);
  v_res := public.fn_purchase_order_update(
    v_po,
    jsonb_build_array(jsonb_build_object('id', v_poi, 'inventory_item_id', v_it1,
      'description','Ron Barcelo','quantity_ordered',10,'unit_cost',540,'tax_rate',18,'total',5400)),
    jsonb_build_object('warehouse_id', v_wh2, 'subtotal',5400,'tax',972,'total',6372));
  perform test.chk('6 sale del almacen viejo', test.stock(v_wh1, v_it1) = v_base - 10,
                   format('stock=%s base=%s', test.stock(v_wh1,v_it1), v_base));
  perform test.chk('6 entra al almacen nuevo', test.stock(v_wh2, v_it1) = 10,
                   format('stock=%s', test.stock(v_wh2, v_it1)));

  -- ── 7. Conduce intacto tras borrar la línea de la orden ──
  perform test.chk('7 la recepcion conserva su linea',
                   (select count(*) from public.purchase_reception_lines
                     where item_id = v_it1 and quantity_received = 12) = 1);

  -- ── 8. Línea parcial: entraron 5 de 12, se corrige a 3 ──
  v_po := test.seed_order('PO-00002', 12, 100);
  v_poi := test.line_of(v_po);
  update public.purchase_order_items set quantity_received = 5 where id = v_poi;
  update public.purchase_orders set status = 'partial' where id = v_po;
  update public.inventory_stock set quantity = 5 where warehouse_id=v_wh1 and item_id=v_it1;
  v_res := public.fn_purchase_order_update(
    v_po,
    jsonb_build_array(jsonb_build_object('id', v_poi, 'inventory_item_id', v_it1,
      'description','Ron Barcelo','quantity_ordered',3,'unit_cost',100,'tax_rate',18,'total',300)),
    jsonb_build_object('subtotal',300,'tax',54,'total',354));
  perform test.chk('8 lo recibido se recorta a lo pedido',
                   (select quantity_received from public.purchase_order_items where id=v_poi) = 3,
                   (select quantity_received::text from public.purchase_order_items where id=v_poi));
  perform test.chk('8 la orden pasa a Recibida (ya no falta nada)', (v_res->>'status') = 'received', v_res::text);
  perform test.chk('8 el stock quedo en 3', test.stock(v_wh1, v_it1) = 3,
                   format('stock=%s', test.stock(v_wh1, v_it1)));

  -- ── 9. CxP sin abonos: se ajusta al nuevo total ──
  v_po := test.seed_order('PO-00003', 10, 100);
  v_poi := test.line_of(v_po);
  insert into public.supplier_credits (business_id, supplier_id, purchase_order_id, invoice_number,
    original_amount, balance)
  values ('11111111-1111-1111-1111-111111111111','b0000000-0000-0000-0000-00000000000a', v_po, 'F-9',
          1180, 1180) returning id into v_credit;
  v_res := public.fn_purchase_order_update(
    v_po,
    jsonb_build_array(jsonb_build_object('id', v_poi, 'inventory_item_id', v_it1,
      'description','Ron Barcelo','quantity_ordered',8,'unit_cost',100,'tax_rate',18,'total',800)),
    jsonb_build_object('subtotal',800,'tax',144,'total',944));
  perform test.chk('9 la CxP se ajusta al nuevo total',
                   (select balance from public.supplier_credits where id=v_credit) = 944,
                   (select balance::text from public.supplier_credits where id=v_credit));
  perform test.chk('9 lo dice en la respuesta', (v_res->>'payable_adjusted')::boolean, v_res::text);

  -- ── 10. CxP CON abonos y total distinto: se rechaza y no cambia nada ──
  insert into public.supplier_credit_payments (supplier_credit_id, amount) values (v_credit, 500);
  v_base := test.stock(v_wh1, v_it1);
  begin
    perform public.fn_purchase_order_update(
      v_po,
      jsonb_build_array(jsonb_build_object('id', v_poi, 'inventory_item_id', v_it1,
        'description','Ron Barcelo','quantity_ordered',5,'unit_cost',100,'tax_rate',18,'total',500)),
      jsonb_build_object('subtotal',500,'tax',90,'total',590));
    perform test.chk('10 debio rechazar con abonos', false);
  exception when others then
    get stacked diagnostics v_msg = message_text;
    perform test.chk('10 rechaza con abonos', v_msg like 'PURCHASE_ORDER_PAYABLE_HAS_PAYMENTS%', v_msg);
  end;
  perform test.chk('10 el stock no se movio', test.stock(v_wh1, v_it1) = v_base,
                   format('stock=%s base=%s', test.stock(v_wh1,v_it1), v_base));
  perform test.chk('10 la cantidad no se movio',
                   (select quantity_ordered from public.purchase_order_items where id=v_poi) = 8);

  -- ── 11. Idempotencia: doble clic no postea dos veces ──
  v_po := test.seed_order('PO-00004', 10, 100);
  v_poi := test.line_of(v_po);
  v_base := test.stock(v_wh1, v_it1);
  v_res := public.fn_purchase_order_update(
    v_po,
    jsonb_build_array(jsonb_build_object('id', v_poi, 'inventory_item_id', v_it1,
      'description','Ron Barcelo','quantity_ordered',6,'unit_cost',100,'tax_rate',18,'total',600)),
    jsonb_build_object('subtotal',600,'tax',108,'total',708), 'se conto mal', 'clave-abc');
  v_res := public.fn_purchase_order_update(
    v_po,
    jsonb_build_array(jsonb_build_object('id', v_poi, 'inventory_item_id', v_it1,
      'description','Ron Barcelo','quantity_ordered',6,'unit_cost',100,'tax_rate',18,'total',600)),
    jsonb_build_object('subtotal',600,'tax',108,'total',708), 'se conto mal', 'clave-abc');
  perform test.chk('11 el reenvio responde replayed', (v_res->>'replayed')::boolean, v_res::text);
  perform test.chk('11 el stock bajo 4 una sola vez', test.stock(v_wh1, v_it1) = v_base - 4,
                   format('stock=%s base=%s', test.stock(v_wh1,v_it1), v_base));
  perform test.chk('11 la bitacora tiene una sola fila',
                   (select count(*) from public.purchase_order_edits where purchase_order_id=v_po) = 1);

  -- ── 12. La bitácora guarda el antes y el después ──
  perform test.chk('12 el antes tiene la cantidad vieja',
                   (select (before_snapshot->'lines'->0->>'quantity_ordered')::numeric
                      from public.purchase_order_edits where purchase_order_id=v_po) = 10);
  perform test.chk('12 el despues tiene la corregida',
                   (select (after_snapshot->'lines'->0->>'quantity_ordered')::numeric
                      from public.purchase_order_edits where purchase_order_id=v_po) = 6);
  perform test.chk('12 guarda el motivo',
                   (select reason from public.purchase_order_edits where purchase_order_id=v_po) = 'se conto mal');

  -- ── 13. Rechazos ──
  v_po := test.seed_order('PO-00005', 4, 100);
  v_poi := test.line_of(v_po);
  begin
    perform public.fn_purchase_order_update(v_po, '[]'::jsonb, '{}'::jsonb);
    perform test.chk('13 debio rechazar sin lineas', false);
  exception when others then
    get stacked diagnostics v_msg = message_text;
    perform test.chk('13 rechaza una orden sin lineas', v_msg like 'PURCHASE_ORDER_EMPTY%', v_msg);
  end;

  begin
    perform public.fn_purchase_order_update(v_po,
      jsonb_build_array(jsonb_build_object('id', v_poi, 'inventory_item_id', v_it1,
        'quantity_ordered', 0, 'unit_cost', 100, 'total', 0)), '{}'::jsonb);
    perform test.chk('13 debio rechazar cantidad 0', false);
  exception when others then
    get stacked diagnostics v_msg = message_text;
    perform test.chk('13 rechaza cantidad 0', v_msg like 'PURCHASE_ORDER_LINE_INVALID%', v_msg);
  end;

  update public.purchase_orders set status='cancelled' where id=v_po;
  begin
    perform public.fn_purchase_order_update(v_po,
      jsonb_build_array(jsonb_build_object('id', v_poi, 'inventory_item_id', v_it1,
        'quantity_ordered', 4, 'unit_cost', 100, 'total', 400)), '{}'::jsonb);
    perform test.chk('13 debio rechazar cancelada', false);
  exception when others then
    get stacked diagnostics v_msg = message_text;
    perform test.chk('13 rechaza una orden cancelada', v_msg like 'PURCHASE_ORDER_CANCELLED%', v_msg);
  end;
  update public.purchase_orders set status='received' where id=v_po;

  -- Almacén de otro negocio.
  begin
    perform public.fn_purchase_order_update(v_po,
      jsonb_build_array(jsonb_build_object('id', v_poi, 'inventory_item_id', v_it1,
        'quantity_ordered', 4, 'unit_cost', 100, 'total', 400)),
      jsonb_build_object('warehouse_id','a0000000-0000-0000-0000-0000000000ff'));
    perform test.chk('13 debio rechazar almacen ajeno', false);
  exception when others then
    get stacked diagnostics v_msg = message_text;
    perform test.chk('13 rechaza un almacen que no es del negocio', v_msg like 'PURCHASE_ORDER_INVALID%', v_msg);
  end;

  -- ── 14. Gate de permisos ──
  perform set_config('test.uid', '88888888-8888-8888-8888-888888888888', true);
  begin
    perform public.fn_purchase_order_update(v_po,
      jsonb_build_array(jsonb_build_object('id', v_poi, 'inventory_item_id', v_it1,
        'quantity_ordered', 4, 'unit_cost', 100, 'total', 400)), '{}'::jsonb);
    perform test.chk('14 debio rechazar al mesero', false);
  exception when others then
    get stacked diagnostics v_msg = message_text;
    perform test.chk('14 un mesero no puede editar compras', v_msg like 'PURCHASE_ORDER_EDIT_DENIED%', v_msg);
  end;
  perform set_config('test.uid', '', true);

  -- ── 15. El permiso quedó en el catálogo (si no, es decorativo) ──
  perform test.chk('15 el permiso existe en el catalogo',
                   (select count(*) from public.permissions where code='compras.ordenes.editar') = 1);
  perform test.chk('15 owner/admin/manager lo tienen',
                   (select count(*) from public.role_permissions rp
                     join public.roles r on r.id = rp.role_id
                     join public.permissions p on p.id = rp.permission_id
                    where p.code='compras.ordenes.editar' and r.is_system) = 3);
end $$;
SQL

echo
if [ "$FAIL" = 0 ]; then echo "TODO OK"; else echo "HAY FALLAS"; fi
exit $FAIL
