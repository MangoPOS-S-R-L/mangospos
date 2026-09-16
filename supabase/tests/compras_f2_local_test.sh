#!/usr/bin/env bash
# =============================================================================
# Prueba LOCAL de Compras F2 (20260915_0005, fn_purchase_orders_create_batch).
# Postgres 15 DESECHABLE: esquema mínimo + las migraciones REALES de F0 y F2.
#   bash supabase/tests/compras_f2_local_test.sh [carpeta_trabajo]
# Variables: PG_BIN (default homebrew postgresql@15), PG_PORT (default 55440).
# =============================================================================
set -u
REPO=$(cd "$(dirname "$0")/../.." && pwd)
M=$REPO/supabase/migrations
PG=${PG_BIN:-/opt/homebrew/opt/postgresql@15/bin}
PORT=${PG_PORT:-55440}
WORK=${1:-$(mktemp -d)}
D=$WORK/pg_compras_f2
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
create schema test;
create function test.chk(p_label text, p_ok boolean, p_detail text default '') returns void language plpgsql as $$
begin
  if p_ok is not true then raise exception 'FALLA % %', p_label, coalesce(p_detail, ''); end if;
  raise notice 'ok  %', p_label;
end $$;
-- Espera un error con ese código y que NO haya quedado ninguna orden nueva.
create function test.falla_sin_dejar_nada(p_label text, p_sql text, p_code text, p_contains text default null)
returns void language plpgsql as $$
declare v_before bigint; v_after bigint; v_msg text;
begin
  select count(*) into v_before from public.purchase_orders;
  begin
    execute p_sql;
    raise exception 'FALLA % (no dio error)', p_label;
  exception when others then
    v_msg := sqlerrm;
    if v_msg like 'FALLA %' then raise; end if;
  end;
  select count(*) into v_after from public.purchase_orders;
  perform test.chk(p_label, v_msg like p_code || '%' and v_after = v_before
    and (p_contains is null or v_msg like '%' || p_contains || '%'), v_msg || ' / órdenes ' || v_before || '→' || v_after);
end $$;

insert into public.businesses values ('35c5076a-bd85-4a1b-8d1c-ce719c4f9ae6','Penda'), ('22222222-2222-2222-2222-222222222222','Otro');
insert into public.warehouses values ('a0000000-0000-0000-0000-000000000001','35c5076a-bd85-4a1b-8d1c-ce719c4f9ae6','Principal'),
                                     ('a0000000-0000-0000-0000-000000000002','22222222-2222-2222-2222-222222222222','Otro');
insert into public.suppliers (id, business_id, name) values
 ('b0000000-0000-0000-0000-00000000000a','35c5076a-bd85-4a1b-8d1c-ce719c4f9ae6','SA'),
 ('b0000000-0000-0000-0000-00000000000b','35c5076a-bd85-4a1b-8d1c-ce719c4f9ae6','SB'),
 ('b0000000-0000-0000-0000-0000000000ff','22222222-2222-2222-2222-222222222222','SX');
insert into public.inventory_items (id, business_id, name, unit, cost, purchase_unit, pack_size) values
 ('c0000000-0000-0000-0000-000000000001','35c5076a-bd85-4a1b-8d1c-ce719c4f9ae6','Refresco','unidad',30,'Caja',24),
 ('c0000000-0000-0000-0000-000000000002','35c5076a-bd85-4a1b-8d1c-ce719c4f9ae6','Queso','lb',200,null,1);
SQL
ok "esquema"

echo "== Migraciones (F2 exige F0 primero)"
OUT=$(Q -f "$M/20260915_0005_compras_f2_ordenes_en_lote.sql" 2>&1)
echo "$OUT" | grep -q "Falta aplicar 20260915_0003" && ok "sin F0, la F2 no se aplica" || { bad "guardia de F2"; echo "$OUT" | tail -3; }
Q -f "$M/20260915_0003_compras_f0_orden_atomica_y_suplidor.sql" >/dev/null 2>&1 \
  && Q -f "$M/20260915_0005_compras_f2_ordenes_en_lote.sql" >/dev/null 2>&1 \
  && Q -f "$M/20260915_0005_compras_f2_ordenes_en_lote.sql" >/dev/null 2>&1 \
  && ok "F0 + F2 aplicadas (F2 dos veces)" || { bad "aplicar"; Q -f "$M/20260915_0005_compras_f2_ordenes_en_lote.sql" 2>&1 | tail -5; exit 1; }

echo "== Lote"
if OUT=$(Q 2>&1 <<'SQL'
do $$
declare r jsonb; r2 jsonb; n bigint;
  B constant uuid := '35c5076a-bd85-4a1b-8d1c-ce719c4f9ae6';
  W constant uuid := 'a0000000-0000-0000-0000-000000000001';
  LOTE constant jsonb := '[
    {"supplier_id":"b0000000-0000-0000-0000-00000000000a","supplier_name":"SA","expected_date":"2026-09-20",
     "header":{"subtotal":1584,"tax":0,"total":1584,"notes":"Pedido sugerido"},
     "lines":[{"inventory_item_id":"c0000000-0000-0000-0000-000000000001","description":"Refresco","quantity_ordered":72,
               "unit_cost":22,"tax_rate":0,"total":1584,"purchase_unit":"Caja","pack_size":24}]},
    {"supplier_id":"b0000000-0000-0000-0000-00000000000b","supplier_name":"SB","expected_date":"2026-09-18",
     "header":{"subtotal":1000,"tax":180,"total":1180},
     "lines":[{"inventory_item_id":"c0000000-0000-0000-0000-000000000002","description":"Queso","quantity_ordered":5,
               "unit_cost":200,"tax_rate":18,"total":1000}]}
  ]';
begin
  r := public.fn_purchase_orders_create_batch(B, W, LOTE, 'draft', 'pedido-1');
  perform test.chk('L1 dos órdenes creadas, ninguna reusada', (r->>'created')::int = 2 and (r->>'reused')::int = 0, r::text);
  perform test.chk('L1 números seguidos PO-00001 y PO-00002',
    r->'orders'->0->>'order_number' = 'PO-00001' and r->'orders'->1->>'order_number' = 'PO-00002', r::text);
  perform test.chk('L1 cada resultado dice su suplidor',
    r->'orders'->0->>'supplier_id' = 'b0000000-0000-0000-0000-00000000000a'
    and r->'orders'->1->>'supplier_id' = 'b0000000-0000-0000-0000-00000000000b', r::text);
  perform test.chk('L1 borrador con fecha, totales y foto del empaque', exists (
    select 1 from public.purchase_orders po join public.purchase_order_items poi on poi.purchase_order_id = po.id
     where po.id = (r->'orders'->0->>'id')::uuid and po.status = 'draft' and po.expected_date = '2026-09-20'
       and po.total = 1584 and po.notes = 'Pedido sugerido' and poi.purchase_unit = 'Caja' and poi.pack_size = 24
       and poi.quantity_ordered = 72));
  perform test.chk('L1 llave por suplidor', exists (select 1 from public.purchase_orders
     where idempotency_key = 'pedido-1:b0000000-0000-0000-0000-00000000000b'));

  select count(*) into n from public.purchase_orders;
  r2 := public.fn_purchase_orders_create_batch(B, W, LOTE, 'draft', 'pedido-1');
  perform test.chk('L2 reintento con la misma llave: las mismas dos, reusadas, sin duplicar',
    (r2->>'created')::int = 0 and (r2->>'reused')::int = 2
    and r2->'orders'->0->>'id' = r->'orders'->0->>'id'
    and (select count(*) from public.purchase_orders) = n, r2::text);

  r2 := public.fn_purchase_orders_create_batch(B, W, LOTE, 'sent', null);
  perform test.chk('L3 sin llave crea otras dos (enviadas, PO-00003 y PO-00004)',
    (r2->>'created')::int = 2 and r2->'orders'->1->>'order_number' = 'PO-00004'
    and (select count(*) from public.purchase_orders where status = 'sent') = 2, r2::text);
end $$;

select test.falla_sin_dejar_nada('L4 una línea mala en la SEGUNDA orden no deja ni la primera (y dice cuál)',
  $q$select public.fn_purchase_orders_create_batch('35c5076a-bd85-4a1b-8d1c-ce719c4f9ae6','a0000000-0000-0000-0000-000000000001',
    '[{"supplier_id":"b0000000-0000-0000-0000-00000000000a","lines":[{"quantity_ordered":1,"unit_cost":1}]},
      {"supplier_id":"b0000000-0000-0000-0000-00000000000b","supplier_name":"SB","lines":[{"quantity_ordered":0,"unit_cost":1}]}]')$q$,
  'PURCHASE_ORDER_LINE_INVALID', 'SB (orden 2 de 2)');
select test.falla_sin_dejar_nada('L5 suplidor repetido',
  $q$select public.fn_purchase_orders_create_batch('35c5076a-bd85-4a1b-8d1c-ce719c4f9ae6','a0000000-0000-0000-0000-000000000001',
    '[{"supplier_id":"b0000000-0000-0000-0000-00000000000a","lines":[{"quantity_ordered":1,"unit_cost":1}]},
      {"supplier_id":"b0000000-0000-0000-0000-00000000000a","supplier_name":"SA","lines":[{"quantity_ordered":1,"unit_cost":1}]}]')$q$,
  'PURCHASE_BATCH_DUPLICATE_SUPPLIER');
select test.falla_sin_dejar_nada('L6 orden sin suplidor',
  $q$select public.fn_purchase_orders_create_batch('35c5076a-bd85-4a1b-8d1c-ce719c4f9ae6','a0000000-0000-0000-0000-000000000001',
    '[{"lines":[{"quantity_ordered":1,"unit_cost":1}]}]')$q$,
  'PURCHASE_BATCH_SUPPLIER_REQUIRED');
select test.falla_sin_dejar_nada('L7 lote vacío',
  $q$select public.fn_purchase_orders_create_batch('35c5076a-bd85-4a1b-8d1c-ce719c4f9ae6','a0000000-0000-0000-0000-000000000001','[]')$q$,
  'PURCHASE_BATCH_EMPTY');
select test.falla_sin_dejar_nada('L8 un lote no nace recibido (eso mueve stock)',
  $q$select public.fn_purchase_orders_create_batch('35c5076a-bd85-4a1b-8d1c-ce719c4f9ae6','a0000000-0000-0000-0000-000000000001',
    '[{"supplier_id":"b0000000-0000-0000-0000-00000000000a","lines":[{"quantity_ordered":1,"unit_cost":1}]}]','received')$q$,
  'PURCHASE_ORDER_INVALID_STATUS');
select test.falla_sin_dejar_nada('L9 suplidor de otro negocio en la segunda orden',
  $q$select public.fn_purchase_orders_create_batch('35c5076a-bd85-4a1b-8d1c-ce719c4f9ae6','a0000000-0000-0000-0000-000000000001',
    '[{"supplier_id":"b0000000-0000-0000-0000-00000000000a","lines":[{"quantity_ordered":1,"unit_cost":1}]},
      {"supplier_id":"b0000000-0000-0000-0000-0000000000ff","lines":[{"quantity_ordered":1,"unit_cost":1}]}]')$q$,
  'PURCHASE_ORDER_INVALID', 'orden 2 de 2');
SQL
); then echo "$OUT" | grep "NOTICE:  ok" | sed 's/^.*NOTICE:  /  /'; ok "lote"
else echo "$OUT" | grep -E "NOTICE:  ok|ERROR" | sed 's/^.*NOTICE:  /  /; s/^psql:[^:]*:[0-9]*: //'; bad "lote"; fi

echo "== ROLLBACK"
Q -f "$M/20260915_0005_compras_f2_ordenes_en_lote_ROLLBACK.sql" >/dev/null 2>&1 \
  && [ "$(Q -At -c "select count(*) from pg_proc where proname = 'fn_purchase_orders_create_batch'")" = "0" ] \
  && [ "$(Q -At -c "select count(*) from public.purchase_orders")" = "4" ] \
  && ok "rollback quita la función y deja las órdenes creadas" || bad "rollback"

echo
[ $FAIL -eq 0 ] && echo "RESULTADO: TODO EN VERDE" || { echo "RESULTADO: HAY FALLAS"; exit 1; }
