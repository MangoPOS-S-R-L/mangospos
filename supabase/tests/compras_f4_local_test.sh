#!/usr/bin/env bash
# =============================================================================
# Prueba LOCAL de Compras F4 (20260915_0008: precio aprendido al recibir +
# comparador). Postgres 15 DESECHABLE; corre las migraciones REALES 0003 y 0008.
#   bash supabase/tests/compras_f4_local_test.sh [carpeta_trabajo]
# Variables: PG_BIN (default homebrew postgresql@15), PG_PORT (default 55445).
# =============================================================================
set -u
REPO=$(cd "$(dirname "$0")/../.." && pwd)
M=$REPO/supabase/migrations
MIG=$M/20260915_0008_compras_f4_precios.sql
PG=${PG_BIN:-/opt/homebrew/opt/postgresql@15/bin}
PORT=${PG_PORT:-55445}
WORK=${1:-$(mktemp -d)}
D=$WORK/pg_compras_f4
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
create function auth.uid() returns uuid language sql stable as $$ select '99999999-9999-9999-9999-999999999999'::uuid $$;
create type public.purchase_status as enum ('draft','sent','partial','received','cancelled');
create type public.movement_type as enum ('purchase','sale','adjustment','transfer_in','transfer_out','waste','return');
create table public.businesses (id uuid primary key, name text);
create table public.warehouses (id uuid primary key, business_id uuid, name text);
create table public.suppliers (id uuid primary key, business_id uuid, name text, lead_time_days smallint, is_active boolean default true);
create table public.inventory_items (id uuid primary key, business_id uuid, name text, unit text default 'unidad',
  cost numeric default 0, purchase_unit text, pack_size numeric default 1, is_active boolean default true);
create table public.supplier_items (id uuid primary key default gen_random_uuid(), business_id uuid not null,
  supplier_id uuid not null, inventory_item_id uuid not null, supplier_code text, purchase_unit text,
  pack_size numeric check (pack_size is null or pack_size > 0),
  last_price numeric check (last_price is null or last_price >= 0), min_order_qty numeric, notes text,
  is_active boolean not null default true,
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
create table public.direct_receipts (id uuid primary key, business_id uuid, warehouse_id uuid, supplier_id uuid,
  status text not null default 'received');
create table public.purchase_receptions (id uuid primary key, business_id uuid, warehouse_id uuid, supplier_id uuid,
  status text not null default 'complete');
create table public.purchase_reception_lines (id uuid primary key, reception_id uuid, item_id uuid, quantity_received numeric);
create schema test;
create function test.chk(p_label text, p_ok boolean, p_detail text default '') returns void language plpgsql as $$
begin
  if p_ok is not true then raise exception 'FALLA % %', p_label, coalesce(p_detail, ''); end if;
  raise notice 'ok  %', p_label;
end $$;
-- Compra: inserta el movimiento como lo haría la recepción.
create function test.compra(p_item uuid, p_ref uuid, p_ref_type text, p_qty numeric, p_cost numeric, p_at timestamptz default now())
returns void language sql as $$
  insert into public.inventory_movements (business_id, warehouse_id, item_id, movement_type, quantity, cost_per_unit, reference_id, reference_type, created_at)
  values ('35c5076a-bd85-4a1b-8d1c-ce719c4f9ae6', 'a0000000-0000-0000-0000-000000000001', p_item, 'purchase', p_qty, p_cost, p_ref, p_ref_type, p_at)
$$;
create function test.link(p_supplier uuid, p_item uuid) returns public.supplier_items language sql as $$
  select * from public.supplier_items where supplier_id = p_supplier and inventory_item_id = p_item
$$;
SQL
ok "esquema"

echo "== Migraciones"
OUT=$(Q -f "$MIG" 2>&1)
echo "$OUT" | grep -q "Falta aplicar 20260915_0003" && ok "sin F0 la F4 no se aplica" || { bad "guardia"; echo "$OUT" | tail -3; }
Q -f "$M/20260915_0003_compras_f0_orden_atomica_y_suplidor.sql" >/dev/null 2>&1 \
  && Q -f "$MIG" >/dev/null 2>&1 && Q -f "$MIG" >/dev/null 2>&1 \
  && ok "0003 + 0008 aplicadas (0008 dos veces)" || { bad "aplicar"; Q -f "$MIG" 2>&1 | tail -5; exit 1; }

echo "== Semilla"
Q <<'SQL' >/dev/null || { bad "semilla"; exit 1; }
insert into public.businesses values ('35c5076a-bd85-4a1b-8d1c-ce719c4f9ae6','Penda'), ('22222222-2222-2222-2222-222222222222','Otro');
insert into public.warehouses values ('a0000000-0000-0000-0000-000000000001','35c5076a-bd85-4a1b-8d1c-ce719c4f9ae6','Principal');
insert into public.suppliers (id, business_id, name, is_active) values
 ('b0000000-0000-0000-0000-00000000000a','35c5076a-bd85-4a1b-8d1c-ce719c4f9ae6','SA', true),
 ('b0000000-0000-0000-0000-00000000000b','35c5076a-bd85-4a1b-8d1c-ce719c4f9ae6','SB', true),
 ('b0000000-0000-0000-0000-00000000000c','35c5076a-bd85-4a1b-8d1c-ce719c4f9ae6','SC', true),
 ('b0000000-0000-0000-0000-0000000000ff','22222222-2222-2222-2222-222222222222','SX', true);
insert into public.inventory_items (id, business_id, name, unit, cost, purchase_unit, pack_size) values
 ('c0000000-0000-0000-0000-000000000001','35c5076a-bd85-4a1b-8d1c-ce719c4f9ae6','Refresco','unidad',30,'Caja',24),
 ('c0000000-0000-0000-0000-000000000002','35c5076a-bd85-4a1b-8d1c-ce719c4f9ae6','Queso','lb',200,null,1),
 ('c0000000-0000-0000-0000-000000000003','35c5076a-bd85-4a1b-8d1c-ce719c4f9ae6','Aceite','ml',0,'Galón',3785);
-- Documentos (las compras se insertan en las pruebas).
insert into public.purchase_orders (id, business_id, supplier_id, warehouse_id, order_number, status) values
 ('d0000000-0000-0000-0000-00000000000a','35c5076a-bd85-4a1b-8d1c-ce719c4f9ae6','b0000000-0000-0000-0000-00000000000a','a0000000-0000-0000-0000-000000000001','PO-1','received'),
 ('d0000000-0000-0000-0000-0000000000cc','35c5076a-bd85-4a1b-8d1c-ce719c4f9ae6','b0000000-0000-0000-0000-00000000000c','a0000000-0000-0000-0000-000000000001','PO-X','cancelled'),
 ('d0000000-0000-0000-0000-0000000000ff','35c5076a-bd85-4a1b-8d1c-ce719c4f9ae6','b0000000-0000-0000-0000-0000000000ff','a0000000-0000-0000-0000-000000000001','PO-AJENO','received');
insert into public.direct_receipts (id, business_id, warehouse_id, supplier_id, status) values
 ('e0000000-0000-0000-0000-00000000000a','35c5076a-bd85-4a1b-8d1c-ce719c4f9ae6','a0000000-0000-0000-0000-000000000001','b0000000-0000-0000-0000-00000000000a','received'),
 ('e0000000-0000-0000-0000-00000000000b','35c5076a-bd85-4a1b-8d1c-ce719c4f9ae6','a0000000-0000-0000-0000-000000000001','b0000000-0000-0000-0000-00000000000b','received'),
 ('e0000000-0000-0000-0000-0000000000cb','35c5076a-bd85-4a1b-8d1c-ce719c4f9ae6','a0000000-0000-0000-0000-000000000001','b0000000-0000-0000-0000-00000000000b','cancelled'),
 ('e0000000-0000-0000-0000-000000000000','35c5076a-bd85-4a1b-8d1c-ce719c4f9ae6','a0000000-0000-0000-0000-000000000001', null,'received');
insert into public.purchase_receptions (id, business_id, warehouse_id, supplier_id, status) values
 ('f0000000-0000-0000-0000-00000000000c','35c5076a-bd85-4a1b-8d1c-ce719c4f9ae6','a0000000-0000-0000-0000-000000000001','b0000000-0000-0000-0000-00000000000c','complete');
insert into public.purchase_reception_lines (id, reception_id, item_id, quantity_received) values
 ('f1000000-0000-0000-0000-00000000000c','f0000000-0000-0000-0000-00000000000c','c0000000-0000-0000-0000-000000000003', 3785);
SQL
ok "semilla"

echo "== El precio se aprende al recibir (D4)"
if OUT=$(Q 2>&1 <<'SQL'
do $$
declare l public.supplier_items; n bigint;
  SA constant uuid := 'b0000000-0000-0000-0000-00000000000a';
  SB constant uuid := 'b0000000-0000-0000-0000-00000000000b';
  SC constant uuid := 'b0000000-0000-0000-0000-00000000000c';
  REF constant uuid := 'c0000000-0000-0000-0000-000000000001';
  QUE constant uuid := 'c0000000-0000-0000-0000-000000000002';
  ACE constant uuid := 'c0000000-0000-0000-0000-000000000003';
begin
  -- Orden recibida de SA: 48 refrescos a 22 → vínculo nuevo, 528 por caja.
  perform test.compra(REF, 'd0000000-0000-0000-0000-00000000000a', 'purchase_order', 48, 22, now() - interval '10 days');
  l := test.link(SA, REF);
  perform test.chk('D1 orden recibida crea el vínculo con precio por caja (22 × 24 = 528)',
    l.id is not null and l.last_price = 528 and l.last_price_source = 'recepcion' and l.is_active
    and l.purchase_unit = 'Caja' and l.pack_size = 24, row_to_json(l)::text);

  -- Recepción directa de SA más nueva, a 23 → 552.
  perform test.compra(REF, 'e0000000-0000-0000-0000-00000000000a', 'direct_receipt', 24, 23, now() - interval '5 days');
  l := test.link(SA, REF);
  perform test.chk('D2 una recepción más nueva actualiza (23 × 24 = 552)', l.last_price = 552, row_to_json(l)::text);

  -- Una recepción con fecha VIEJA no pisa la más nueva.
  perform test.compra(REF, 'e0000000-0000-0000-0000-00000000000a', 'direct_receipt', 24, 10, now() - interval '30 days');
  l := test.link(SA, REF);
  perform test.chk('D3 una recepción atrasada no pisa el precio más nuevo', l.last_price = 552, row_to_json(l)::text);

  -- Cambio a mano desde la app: se sella manual.
  update public.supplier_items set last_price = 600 where id = l.id;
  l := test.link(SA, REF);
  perform test.chk('D4 un cambio a mano queda como manual y con fecha de ahora',
    l.last_price_source = 'manual' and l.last_price_at > now() - interval '1 minute', row_to_json(l)::text);

  -- Tocar otra columna sin cambiar el precio no re-sella.
  update public.supplier_items set notes = 'nota' where id = l.id;
  perform test.chk('D5 editar otra cosa no toca la fecha del precio', (test.link(SA, REF)).last_price_at = l.last_price_at);

  -- La siguiente recepción real vuelve a mandar.
  perform test.compra(REF, 'e0000000-0000-0000-0000-00000000000a', 'direct_receipt', 24, 21, now() + interval '1 second');
  l := test.link(SA, REF);
  perform test.chk('D6 la siguiente recepción pisa el manual (21 × 24 = 504)', l.last_price = 504 and l.last_price_source = 'recepcion', row_to_json(l)::text);

  -- Vínculo desactivado con presentación propia (Paquete de 12): actualiza con SU contenido y no se reactiva.
  insert into public.supplier_items (business_id, supplier_id, inventory_item_id, purchase_unit, pack_size, is_active)
  values ('35c5076a-bd85-4a1b-8d1c-ce719c4f9ae6', SB, REF, 'Paquete', 12, false);
  perform test.compra(REF, 'e0000000-0000-0000-0000-00000000000b', 'direct_receipt', 12, 25, now() - interval '3 days');
  l := test.link(SB, REF);
  perform test.chk('D7 vínculo con su presentación: 25 × 12 = 300 y sigue desactivado',
    l.last_price = 300 and not l.is_active, row_to_json(l)::text);

  -- Conduce de SC para el aceite (galón 3785 ml a 0.08/ml).
  perform test.compra(ACE, 'f1000000-0000-0000-0000-00000000000c', 'purchase_reception_line', 3785, 0.08, now() - interval '2 days');
  l := test.link(SC, ACE);
  perform test.chk('D8 recepción con conduce: 0.08 × 3785 = 302.8 por galón', l.last_price = 302.8, row_to_json(l)::text);

  -- Lo que NO aprende.
  select count(*) into n from public.supplier_items;
  perform test.compra(QUE, 'e0000000-0000-0000-0000-000000000000', 'direct_receipt', 5, 200);               -- sin suplidor
  perform test.compra(QUE, 'd0000000-0000-0000-0000-00000000000a', 'purchase_order', 5, 0);                 -- costo 0
  perform test.compra(QUE, null, 'initial_stock', 5, 200);                                                   -- carga inicial
  perform test.compra(QUE, 'd0000000-0000-0000-0000-0000000000ff', 'purchase_order', 5, 200);              -- suplidor de otro negocio
  insert into public.inventory_movements (business_id, warehouse_id, item_id, movement_type, quantity, reference_type)
  values ('35c5076a-bd85-4a1b-8d1c-ce719c4f9ae6','a0000000-0000-0000-0000-000000000001', QUE, 'sale', -3, 'order');
  perform test.chk('D9 sin suplidor, costo 0, carga inicial, suplidor ajeno o venta: no crea vínculos',
    (select count(*) from public.supplier_items) = n);
end $$;

-- Si aprender el precio falla, la recepción entra igual.
alter table public.supplier_items add constraint test_tope check (last_price < 100000);
do $$
declare n_mov bigint;
begin
  select count(*) into n_mov from public.inventory_movements;
  perform test.compra('c0000000-0000-0000-0000-000000000002', 'd0000000-0000-0000-0000-00000000000a', 'purchase_order', 1, 999999);
  perform test.chk('D10 si guardar el precio falla, el movimiento de compra entra igual y no queda vínculo',
    (select count(*) from public.inventory_movements) = n_mov + 1
    and (test.link('b0000000-0000-0000-0000-00000000000a', 'c0000000-0000-0000-0000-000000000002')).id is null);
  perform test.chk('D10 y la bandera de la transacción queda limpia',
    coalesce(current_setting('mangopos.supplier_price_from_receipt', true), '') = '');
end $$;
alter table public.supplier_items drop constraint test_tope;
SQL
); then echo "$OUT" | grep "NOTICE:  ok" | sed 's/^.*NOTICE:  /  /'; ok "aprender al recibir"
else echo "$OUT" | grep -E "NOTICE:  ok|ERROR" | sed 's/^.*NOTICE:  /  /; s/^psql:[^:]*:[0-9]*: //'; bad "aprender al recibir"; fi

echo "== Comparador"
if OUT=$(Q 2>&1 <<'SQL'
do $$
declare r record; n int;
  B constant uuid := '35c5076a-bd85-4a1b-8d1c-ce719c4f9ae6';
  SA constant uuid := 'b0000000-0000-0000-0000-00000000000a';
  SB constant uuid := 'b0000000-0000-0000-0000-00000000000b';
  SC constant uuid := 'b0000000-0000-0000-0000-00000000000c';
  REF constant uuid := 'c0000000-0000-0000-0000-000000000001';
  QUE constant uuid := 'c0000000-0000-0000-0000-000000000002';
begin
  -- Compras anuladas que NO deben contar: orden cancelada de SC a 1 y recepción directa anulada de SB a 2.
  perform test.compra(REF, 'd0000000-0000-0000-0000-0000000000cc', 'purchase_order', 24, 1, now() - interval '1 day');
  perform test.compra(REF, 'e0000000-0000-0000-0000-0000000000cb', 'direct_receipt', 24, 2, now() - interval '1 day');
  -- Un vínculo de SC para el queso sin compras: sale solo con su precio de lista.
  insert into public.supplier_items (business_id, supplier_id, inventory_item_id, last_price) values (B, SC, QUE, 190);

  -- Refresco × SA: compras a 22 (-10 d), 23 (-5 d), 10 (-30 d), 21 (+1 s). Último 21, anterior distinto 23.
  select * into r from public.fn_purchase_price_comparison(B, array[REF]) where supplier_id = SA;
  perform test.chk('C1 SA: último 21, anterior DISTINTO 23, tendencia −8.7%',
    r.last_cost_base = 21 and r.previous_cost_base = 23 and r.trend_pct = -8.7, row_to_json(r)::text);
  perform test.chk('C1 SA: ventana 90 d = 4 compras (120 u), promedio ponderado 2352/120 = 19.6, mín 10, máx 23',
    r.purchases_count = 4 and r.quantity_total = 120 and r.avg_cost_base = 19.6 and r.min_cost_base = 10 and r.max_cost_base = 23, row_to_json(r)::text);
  perform test.chk('C1 SA: caja de 24, precio de lista 504 (21/u), de recepción; es el suplidor del pedido; puesto 1',
    r.pack_size = 24 and r.purchase_unit = 'Caja' and r.list_price_pack = 504 and r.list_price_base = 21
    and r.list_price_source = 'recepcion' and r.is_resolved and r.rank_by_last = 1 and r.vs_cheapest_pct = 0, row_to_json(r)::text);

  select * into r from public.fn_purchase_price_comparison(B, array[REF]) where supplier_id = SB;
  perform test.chk('C2 SB (vínculo desactivado, pero con compra): 25, puesto 2, 19% más caro, paquete de 12',
    r.last_cost_base = 25 and r.rank_by_last = 2 and r.vs_cheapest_pct = 19.0 and r.pack_size = 12
    and r.is_linked and not r.link_active and not r.is_resolved, row_to_json(r)::text);

  perform test.chk('C3 las compras anuladas (orden cancelada de SC, recepción anulada de SB) no cuentan',
    not exists (select 1 from public.fn_purchase_price_comparison(B, array[REF]) where supplier_id = SC)
    and (select purchases_count from public.fn_purchase_price_comparison(B, array[REF]) where supplier_id = SB) = 1);

  select * into r from public.fn_purchase_price_comparison(B, array[QUE]) where supplier_id = SC;
  perform test.chk('C4 vínculo activo sin compras: sale con su precio de lista manual y sin puesto',
    r.last_cost_base is null and r.list_price_pack = 190 and r.list_price_source = 'manual' and r.rank_by_last is null
    and r.purchases_count = 0, row_to_json(r)::text);

  select count(*) into n from public.fn_purchase_price_comparison(B, null, 7);
  -- El queso × SA existe por la compra de D10: el vínculo no se guardó, pero el movimiento (el precio real) sí entró.
  perform test.chk('C5 sin filtro trae todos los pares (refresco SA/SB, aceite SC, queso SC y SA)', n = 5, n::text);
  perform test.chk('C6 ventana de 7 días: SA solo cuenta las 2 compras recientes',
    (select purchases_count from public.fn_purchase_price_comparison(B, array[REF], 7) where supplier_id = SA) = 2);
end $$;
SQL
); then echo "$OUT" | grep "NOTICE:  ok" | sed 's/^.*NOTICE:  /  /'; ok "comparador"
else echo "$OUT" | grep -E "NOTICE:  ok|ERROR" | sed 's/^.*NOTICE:  /  /; s/^psql:[^:]*:[0-9]*: //'; bad "comparador"; fi

echo "== Anular vuelve a aprender"
if OUT=$(Q 2>&1 <<'SQL'
do $$
declare l public.supplier_items; v_d6_at timestamptz;
  B constant uuid := '35c5076a-bd85-4a1b-8d1c-ce719c4f9ae6';
  SA constant uuid := 'b0000000-0000-0000-0000-00000000000a';
  SB constant uuid := 'b0000000-0000-0000-0000-00000000000b';
  SC constant uuid := 'b0000000-0000-0000-0000-00000000000c';
  REF constant uuid := 'c0000000-0000-0000-0000-000000000001';
  ACE constant uuid := 'c0000000-0000-0000-0000-000000000003';
begin
  select max(created_at) into v_d6_at from public.inventory_movements
   where reference_id = 'e0000000-0000-0000-0000-00000000000a' and cost_per_unit = 21;
  insert into public.direct_receipts (id, business_id, warehouse_id, supplier_id) values
   ('e0000000-0000-0000-0000-00000000000d', B, 'a0000000-0000-0000-0000-000000000001', SA),
   ('e0000000-0000-0000-0000-00000000000e', B, 'a0000000-0000-0000-0000-000000000001', SA);

  perform test.compra(REF, 'e0000000-0000-0000-0000-00000000000d', 'direct_receipt', 24, 30, now() + interval '2 seconds');
  perform test.chk('A1 una recepción con el costo mal digitado (30) fija 720', (test.link(SA, REF)).last_price = 720);
  update public.direct_receipts set status = 'cancelled' where id = 'e0000000-0000-0000-0000-00000000000d';
  l := test.link(SA, REF);
  perform test.chk('A1 anularla vuelve al último precio válido (21 × 24 = 504) con SU fecha',
    l.last_price = 504 and l.last_price_source = 'recepcion' and l.last_price_at = v_d6_at, row_to_json(l)::text);

  update public.supplier_items set last_price = 999 where id = l.id;
  perform test.compra(REF, 'e0000000-0000-0000-0000-00000000000e', 'direct_receipt', 24, 35, now() - interval '100 days');
  update public.direct_receipts set status = 'cancelled' where id = 'e0000000-0000-0000-0000-00000000000e';
  l := test.link(SA, REF);
  perform test.chk('A2 un precio escrito a mano no lo tocan ni una recepción vieja ni su anulación',
    l.last_price = 999 and l.last_price_source = 'manual', row_to_json(l)::text);

  update public.direct_receipts set status = 'cancelled' where id = 'e0000000-0000-0000-0000-00000000000b';
  l := test.link(SB, REF);
  perform test.chk('A3 anular la única compra válida de SB deja el vínculo sin precio (y desactivado como estaba)',
    l.last_price is null and l.last_price_source is null and l.last_price_at is null and not l.is_active, row_to_json(l)::text);

  update public.purchase_receptions set status = 'cancelled' where id = 'f0000000-0000-0000-0000-00000000000c';
  perform test.chk('A4 anular el conduce también: el aceite de SC queda sin precio', (test.link(SC, ACE)).last_price is null);

  update public.purchase_orders set notes = 'otra cosa' where id = 'd0000000-0000-0000-0000-00000000000a';
  perform test.chk('A5 editar una orden sin anularla no recalcula nada', (test.link(SA, REF)).last_price = 999);
  perform test.chk('A6 la bandera de la transacción queda limpia',
    coalesce(current_setting('mangopos.supplier_price_from_receipt', true), '') = '');
  perform test.chk('A7 relearn no la puede llamar la app',
    not has_function_privilege('authenticated', 'public.fn_supplier_items_relearn(uuid,uuid,uuid[])', 'execute'));
end $$;
SQL
); then echo "$OUT" | grep "NOTICE:  ok" | sed 's/^.*NOTICE:  /  /'; ok "anular vuelve a aprender"
else echo "$OUT" | grep -E "NOTICE:  ok|ERROR" | sed 's/^.*NOTICE:  /  /; s/^psql:[^:]*:[0-9]*: //'; bad "anular vuelve a aprender"; fi

echo "== ROLLBACK"
Q -f "$M/20260915_0008_compras_f4_precios_ROLLBACK.sql" >/dev/null 2>&1 \
  && [ "$(Q -At -c "select count(*) from pg_proc where proname in ('fn_purchase_price_comparison','fn_supplier_items_learn_from_receipt','fn_supplier_items_price_stamp','fn_supplier_items_relearn','fn_supplier_items_relearn_on_cancel')")" = "0" ] \
  && Q -c "select test.compra('c0000000-0000-0000-0000-000000000002', 'e0000000-0000-0000-0000-00000000000b', 'direct_receipt', 1, 150)" >/dev/null \
  && [ "$(Q -At -c "select count(*) from public.supplier_items where supplier_id = 'b0000000-0000-0000-0000-00000000000b' and inventory_item_id = 'c0000000-0000-0000-0000-000000000002'")" = "0" ] \
  && ok "rollback quita triggers y comparador; recibir ya no crea vínculos" || bad "rollback"

echo
[ $FAIL -eq 0 ] && echo "RESULTADO: TODO EN VERDE" || { echo "RESULTADO: HAY FALLAS"; exit 1; }
