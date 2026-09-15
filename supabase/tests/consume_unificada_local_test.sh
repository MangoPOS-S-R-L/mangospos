#!/usr/bin/env bash
# =============================================================================
# Prueba LOCAL de 20260915_0002 (consumo unificado) y de las guardias de rama.
#
# Levanta un Postgres 15 DESECHABLE, arma el esquema mínimo que toca
# consume_inventory_from_order, y corre las migraciones REALES del repo
# (los bloques de consumo con su guardia, la unificada y su ROLLBACK).
# No toca ninguna base real.
#
#   bash supabase/tests/consume_unificada_local_test.sh [carpeta_trabajo]
#
# Variables: PG_BIN (default homebrew postgresql@15), PG_PORT (default 55434).
# El resolvedor de área es un STUB (tabla test_area_map): se prueba el
# consumo, no la resolución de áreas de 20260901_0006.
# =============================================================================
set -u
REPO=$(cd "$(dirname "$0")/../.." && pwd)
M=$REPO/supabase/migrations
PG=${PG_BIN:-/opt/homebrew/opt/postgresql@15/bin}
PORT=${PG_PORT:-55434}
WORK=${1:-$(mktemp -d)}
D=$WORK/pg_consume_unificada
rm -rf "$D"; mkdir -p "$D"

"$PG/initdb" -D "$D/data" -U postgres --auth=trust >/dev/null || exit 1
"$PG/pg_ctl" -D "$D/data" \
  -o "-p $PORT -c listen_addresses=127.0.0.1 -c unix_socket_directories=''" \
  -l "$D/log" start -w >/dev/null || { cat "$D/log"; exit 1; }
trap '"$PG/pg_ctl" -D "$D/data" stop -m fast >/dev/null 2>&1' EXIT

Q() { "$PG/psql" -h 127.0.0.1 -p "$PORT" -U postgres -X -q -v ON_ERROR_STOP=1 "$@"; }
FAIL=0
ok()  { echo "  ok     $1"; }
bad() { echo "  FALLA  $1"; FAIL=1; }
# Bloque de consumo con guardia de una migración (entre las marcas ASCII).
block() { awk '/CONSUME-GUARD-DESDE/{on=1} on{print} /CONSUME-GUARD-HASTA/{exit}' "$1" > "$D/block.sql"; echo "$D/block.sql"; }
live()  { Q -At -c "select coalesce((select pg_get_functiondef(p.oid) from pg_proc p join pg_namespace n on n.oid=p.pronamespace where n.nspname='public' and p.proname='consume_inventory_from_order' limit 1), '')"; }
has()   { live | grep -q -- "$1"; }

echo "== Esquema mínimo"
Q <<'SQL'
create schema test;
create type public.order_status as enum ('open', 'closed', 'paid', 'void');
create type public.movement_type as enum ('purchase', 'sale', 'adjustment');
create table public.businesses (id uuid primary key, business_name text);
create table public.business_settings (business_id uuid primary key, inventory_mode text);
create table public.warehouses (
  id uuid primary key, business_id uuid, name text, is_main boolean default false,
  is_active boolean default true, created_at timestamptz, shows_in_pos boolean default false);
create table public.inventory_items (id uuid primary key, business_id uuid, name text);
create table public.inventory_stock (item_id uuid, warehouse_id uuid, quantity numeric default 0,
  primary key (item_id, warehouse_id));
create table public.inventory_movements (
  id bigserial primary key, business_id uuid, warehouse_id uuid, item_id uuid,
  movement_type public.movement_type, quantity numeric, reference_id uuid,
  reference_type text, notes text, created_at timestamptz default now());
create function test.apply_movement() returns trigger language plpgsql as $$
begin
  insert into public.inventory_stock (item_id, warehouse_id, quantity)
  values (new.item_id, new.warehouse_id, new.quantity)
  on conflict (item_id, warehouse_id)
  do update set quantity = public.inventory_stock.quantity + excluded.quantity;
  return new;
end $$;
create trigger trg_apply_movement after insert on public.inventory_movements
  for each row execute function test.apply_movement();
create table public.menu_items (
  id uuid primary key, business_id uuid, name text, item_type text default 'product',
  is_inventory_tracked boolean default false, inventory_item_id uuid);
create table public.recipes (id uuid primary key default gen_random_uuid(), menu_item_id uuid, inventory_item_id uuid);
create table public.recipe_ingredients (id uuid primary key default gen_random_uuid(),
  recipe_id uuid, inventory_item_id uuid, quantity numeric, unit text);
create table public.table_sessions (id uuid primary key, business_id uuid);
create table public.orders (id uuid primary key, session_id uuid,
  status text default 'open', status_ext public.order_status default 'open');
create table public.order_items (id uuid primary key default gen_random_uuid(), order_id uuid,
  product_id uuid, qty numeric, quantity int, status text default 'active');
create table public.order_item_modifiers (id uuid primary key default gen_random_uuid(),
  item_id uuid, name text, qty numeric default 1, menu_item_id uuid);
create table public.modifiers (id uuid primary key, name text);
-- Stub del resolvedor de área (20260901_0006).
create table public.test_area_map (business_id uuid, menu_item_id uuid, warehouse_id uuid);
create function public.fn_resolve_area_warehouse(p_business_id uuid, p_menu_item_id uuid)
returns uuid language sql stable as $$
  select warehouse_id from public.test_area_map
   where business_id = p_business_id and menu_item_id = p_menu_item_id limit 1 $$;
-- Como en prod: tocar un renglón reconcilia la orden.
create function test.oi_reconcile() returns trigger language plpgsql as $$
begin
  perform public.consume_inventory_from_order(coalesce(new.order_id, old.order_id));
  return null;
end $$;
create trigger trg_order_items_reconcile after update or delete on public.order_items
  for each row execute function test.oi_reconcile();

create function test.chk(p_label text, p_got numeric, p_want numeric) returns void
language plpgsql as $$
begin
  if p_got is distinct from p_want then
    raise exception 'FALLA % -> obtuvo %, esperaba %', p_label, p_got, p_want;
  end if;
  raise notice 'ok  % = %', p_label, p_got;
end $$;
create function test.stock(i uuid, w uuid) returns numeric language sql as $$
  select coalesce((select quantity from public.inventory_stock where item_id = i and warehouse_id = w), 0) $$;
create function test.movs(o uuid) returns numeric language sql as $$
  select count(*)::numeric from public.inventory_movements where reference_id = o $$;

-- Semilla: un negocio, bodegas MAIN y NEVERA en la POS, COCINA por área.
insert into public.businesses values ('b0000000-0000-0000-0000-000000000001', 'Test');
insert into public.business_settings values ('b0000000-0000-0000-0000-000000000001', 'advanced');
insert into public.warehouses values
  ('a0000000-0000-0000-0000-000000000001', 'b0000000-0000-0000-0000-000000000001', 'MAIN',   true,  true, '2020-01-01', true),
  ('a0000000-0000-0000-0000-000000000002', 'b0000000-0000-0000-0000-000000000001', 'NEVERA', false, true, '2021-01-01', true),
  ('a0000000-0000-0000-0000-000000000003', 'b0000000-0000-0000-0000-000000000001', 'COCINA', false, true, '2022-01-01', false);
insert into public.inventory_items values
  ('c0000000-0000-0000-0000-000000000001', 'b0000000-0000-0000-0000-000000000001', 'PAN'),
  ('c0000000-0000-0000-0000-000000000002', 'b0000000-0000-0000-0000-000000000001', 'QUESO'),
  ('c0000000-0000-0000-0000-000000000003', 'b0000000-0000-0000-0000-000000000001', 'REFRESCO'),
  ('c0000000-0000-0000-0000-000000000004', 'b0000000-0000-0000-0000-000000000001', 'PAN INTEGRAL');
insert into public.menu_items values
  ('d0000000-0000-0000-0000-000000000001', 'b0000000-0000-0000-0000-000000000001', 'HAMBURGUESA', 'product', true, null),
  ('d0000000-0000-0000-0000-000000000002', 'b0000000-0000-0000-0000-000000000001', 'REFRESCO', 'product', true, 'c0000000-0000-0000-0000-000000000003'),
  ('d0000000-0000-0000-0000-000000000003', 'b0000000-0000-0000-0000-000000000001', 'COMBO', 'combo', false, null),
  ('d0000000-0000-0000-0000-000000000004', 'b0000000-0000-0000-0000-000000000001', 'ENSALADA', 'product', false, null);
insert into public.recipes (id, menu_item_id) values ('90000000-0000-0000-0000-000000000001', 'd0000000-0000-0000-0000-000000000001');
insert into public.recipe_ingredients (recipe_id, inventory_item_id, quantity) values
  ('90000000-0000-0000-0000-000000000001', 'c0000000-0000-0000-0000-000000000001', 1),
  ('90000000-0000-0000-0000-000000000001', 'c0000000-0000-0000-0000-000000000002', 50);
insert into public.test_area_map values
  ('b0000000-0000-0000-0000-000000000001', 'd0000000-0000-0000-0000-000000000001', 'a0000000-0000-0000-0000-000000000003');
insert into public.table_sessions values ('f0000000-0000-0000-0000-000000000001', 'b0000000-0000-0000-0000-000000000001');
insert into public.inventory_movements (business_id, warehouse_id, item_id, movement_type, quantity, reference_type) values
  ('b0000000-0000-0000-0000-000000000001', 'a0000000-0000-0000-0000-000000000003', 'c0000000-0000-0000-0000-000000000001', 'purchase', 20,   'initial'),
  ('b0000000-0000-0000-0000-000000000001', 'a0000000-0000-0000-0000-000000000003', 'c0000000-0000-0000-0000-000000000002', 'purchase', 1000, 'initial'),
  ('b0000000-0000-0000-0000-000000000001', 'a0000000-0000-0000-0000-000000000003', 'c0000000-0000-0000-0000-000000000004', 'purchase', 5,    'initial'),
  ('b0000000-0000-0000-0000-000000000001', 'a0000000-0000-0000-0000-000000000001', 'c0000000-0000-0000-0000-000000000003', 'purchase', 6,    'initial'),
  ('b0000000-0000-0000-0000-000000000001', 'a0000000-0000-0000-0000-000000000002', 'c0000000-0000-0000-0000-000000000003', 'purchase', 10,   'initial');
-- O0: venta con la versión A, antes de la unificada.
insert into public.orders (id, session_id) values ('00000000-0000-0000-0000-0000000000a0', 'f0000000-0000-0000-0000-000000000001');
insert into public.order_items (order_id, product_id, qty, quantity) values
  ('00000000-0000-0000-0000-0000000000a0', 'd0000000-0000-0000-0000-000000000001', 2, 2),
  ('00000000-0000-0000-0000-0000000000a0', 'd0000000-0000-0000-0000-000000000002', 3, 3);
SQL
[ $? -eq 0 ] && ok "esquema y semilla" || { bad "esquema"; exit 1; }

echo "== 1. La viva es la versión A (se instala con el bloque guardado de 20260901_0006)"
Q -f "$(block "$M/20260901_0006_pos_multi_warehouse.sql")" >/dev/null 2>&1 \
  && has fn_resolve_area_warehouse && ! has modifier_ingredients \
  && ok "A instalada (base vacía: la guardia deja pasar)" || bad "instalar A"
Q -c "select public.consume_inventory_from_order('00000000-0000-0000-0000-0000000000a0')" >/dev/null \
  && Q -c "do \$\$ begin
    perform test.chk('A: PAN en COCINA', test.stock('c0000000-0000-0000-0000-000000000001','a0000000-0000-0000-0000-000000000003'), 18);
    perform test.chk('A: QUESO en COCINA', test.stock('c0000000-0000-0000-0000-000000000002','a0000000-0000-0000-0000-000000000003'), 900);
    perform test.chk('A: REFRESCO en MAIN', test.stock('c0000000-0000-0000-0000-000000000003','a0000000-0000-0000-0000-000000000001'), 3);
  end \$\$" >/dev/null && ok "venta O0 con A" || bad "venta O0 con A"

echo "== 2. La unificada NO se aplica si faltan 20260907_0001/0002"
OUT=$(Q -f "$M/20260915_0002_consume_unified.sql" 2>&1)
if echo "$OUT" | grep -q "No se aplicó nada" && ! has "UNIFICADA 20260915_0002"; then
  ok "aborta y deja A intacta: $(echo "$OUT" | grep -o 'Falta aplicar antes:.*' | cut -c1-110)"
else bad "la guardia de requisitos no frenó"; echo "$OUT" | tail -3; fi

echo "== 3. Con A viva, los bloques guardados de la rama B se SALTAN"
Q <<'SQL' >/dev/null
create table public.modifier_ingredients (id uuid primary key default gen_random_uuid(),
  modifier_id uuid, inventory_item_id uuid, quantity numeric, unit text);
alter table public.order_item_modifiers add column modifier_id uuid;
SQL
for f in 20260907_0003_consume_modifier_ingredients.sql 20260910_0002_consume_skip_voided_orders.sql; do
  OUT=$(Q -f "$(block "$M/$f")" 2>&1)
  if echo "$OUT" | grep -q "Guardia de rama" && has fn_resolve_area_warehouse && ! has modifier_ingredients; then
    ok "$f se saltó sin borrar A"
  else bad "$f pisó la versión A"; fi
done

echo "== 4. Aplicar la unificada (dos veces) y regresión contra A"
Q -f "$M/20260915_0002_consume_unified.sql" >/dev/null 2>&1 && Q -f "$M/20260915_0002_consume_unified.sql" >/dev/null 2>&1 \
  && has "UNIFICADA 20260915_0002" && ok "aplicada e idempotente" || bad "aplicar la unificada"
Q -c "select public.consume_inventory_from_order('00000000-0000-0000-0000-0000000000a0')" >/dev/null
Q -c "do \$\$ begin perform test.chk('regresión: O0 sin movimientos nuevos', test.movs('00000000-0000-0000-0000-0000000000a0'), 3); end \$\$" >/dev/null \
  && ok "lo vendido con A no se mueve al cambiar de versión" || bad "regresión O0"

echo "== 5. Escenarios con la unificada"
Q <<'SQL' 2>&1 | grep -E "ok  |FALLA|ERROR" | sed 's/^psql:[^:]*:[0-9]*: //; s/^NOTICE:  /  /'
insert into public.modifiers values
  ('e0000000-0000-0000-0000-000000000001', 'Queso extra'),
  ('e0000000-0000-0000-0000-000000000002', 'Sin queso'),
  ('e0000000-0000-0000-0000-000000000003', 'Pan integral');
insert into public.modifier_ingredients (modifier_id, inventory_item_id, quantity) values
  ('e0000000-0000-0000-0000-000000000001', 'c0000000-0000-0000-0000-000000000002',  30),
  ('e0000000-0000-0000-0000-000000000002', 'c0000000-0000-0000-0000-000000000002', -50),
  ('e0000000-0000-0000-0000-000000000003', 'c0000000-0000-0000-0000-000000000004',   1),
  ('e0000000-0000-0000-0000-000000000003', 'c0000000-0000-0000-0000-000000000001',  -1);

create function test.sell(p_order uuid, p_product uuid, p_qty numeric, p_modifier uuid default null,
                          p_mod_qty numeric default 1, p_status_ext public.order_status default 'open')
returns void language plpgsql as $$
declare v_line uuid;
begin
  insert into public.orders (id, session_id, status_ext)
    values (p_order, 'f0000000-0000-0000-0000-000000000001', p_status_ext) on conflict do nothing;
  insert into public.order_items (order_id, product_id, qty, quantity)
    values (p_order, p_product, p_qty, p_qty::int) returning id into v_line;
  if p_modifier is not null then
    insert into public.order_item_modifiers (item_id, name, qty, modifier_id)
      values (v_line, 'mod', p_mod_qty, p_modifier);
  end if;
  perform public.consume_inventory_from_order(p_order);
end $$;

do $$
declare
  PAN constant uuid := 'c0000000-0000-0000-0000-000000000001';
  QUESO constant uuid := 'c0000000-0000-0000-0000-000000000002';
  REF constant uuid := 'c0000000-0000-0000-0000-000000000003';
  PINT constant uuid := 'c0000000-0000-0000-0000-000000000004';
  MAIN constant uuid := 'a0000000-0000-0000-0000-000000000001';
  NEV constant uuid := 'a0000000-0000-0000-0000-000000000002';
  COC constant uuid := 'a0000000-0000-0000-0000-000000000003';
  BURGER constant uuid := 'd0000000-0000-0000-0000-000000000001';
  M_REF constant uuid := 'd0000000-0000-0000-0000-000000000002';
  COMBO constant uuid := 'd0000000-0000-0000-0000-000000000003';
  ENSALADA constant uuid := 'd0000000-0000-0000-0000-000000000004';
  v_line uuid;
begin
  -- T1 receta por área + modificador positivo
  perform test.sell('00000000-0000-0000-0000-0000000000a1', BURGER, 1, 'e0000000-0000-0000-0000-000000000001');
  perform test.chk('T1 PAN en COCINA', test.stock(PAN, COC), 17);
  perform test.chk('T1 QUESO receta 50 + extra 30', test.stock(QUESO, COC), 820);
  -- T2 idempotencia
  perform public.consume_inventory_from_order('00000000-0000-0000-0000-0000000000a1');
  perform test.chk('T2 sin movimientos nuevos', test.movs('00000000-0000-0000-0000-0000000000a1'), 2);
  -- T3 «sin queso» anula la receta
  perform test.sell('00000000-0000-0000-0000-0000000000a2', BURGER, 1, 'e0000000-0000-0000-0000-000000000002');
  perform test.chk('T3 QUESO anulado', test.stock(QUESO, COC), 820);
  perform test.chk('T3 PAN sí', test.stock(PAN, COC), 16);
  -- T4 recorte: «sin queso» ×2 no crea stock
  perform test.sell('00000000-0000-0000-0000-0000000000a3', BURGER, 1, 'e0000000-0000-0000-0000-000000000002', 2);
  perform test.chk('T4 QUESO no sube (recorte a 0)', test.stock(QUESO, COC), 820);
  -- T5 cambio de pan: +1 integral, -1 normal
  perform test.sell('00000000-0000-0000-0000-0000000000a4', BURGER, 1, 'e0000000-0000-0000-0000-000000000003');
  perform test.chk('T5 PAN normal no baja', test.stock(PAN, COC), 15);
  perform test.chk('T5 PAN INTEGRAL baja', test.stock(PINT, COC), 4);
  perform test.chk('T5 QUESO de la receta', test.stock(QUESO, COC), 770);
  -- T6 cascada MAIN → NEVERA
  perform test.sell('00000000-0000-0000-0000-0000000000a5', M_REF, 10);
  perform test.chk('T6 MAIN se vacía', test.stock(REF, MAIN), 0);
  perform test.chk('T6 NEVERA pone el resto', test.stock(REF, NEV), 3);
  perform public.consume_inventory_from_order('00000000-0000-0000-0000-0000000000a5');
  perform test.chk('T7 cascada idempotente', test.movs('00000000-0000-0000-0000-0000000000a5'), 2);
end $$;

-- T8 anular devuelve (trigger)
update public.orders set status = 'canceled', status_ext = 'void'
 where id = '00000000-0000-0000-0000-0000000000a5';
do $$ begin
  perform test.chk('T8 MAIN devuelto', test.stock('c0000000-0000-0000-0000-000000000003', 'a0000000-0000-0000-0000-000000000001'), 3);
  perform test.chk('T8 NEVERA devuelto', test.stock('c0000000-0000-0000-0000-000000000003', 'a0000000-0000-0000-0000-000000000002'), 10);
  perform test.chk('T8 nota de anulación', (select count(*)::numeric from public.inventory_movements
    where reference_id = '00000000-0000-0000-0000-0000000000a5' and notes = 'Devolución por anulación de la orden'), 2);
end $$;
-- T9 editar un renglón de la anulada no revive
update public.order_items set qty = 12, quantity = 12 where order_id = '00000000-0000-0000-0000-0000000000a5';
do $$ begin
  perform test.chk('T9 edición no revive', test.stock('c0000000-0000-0000-0000-000000000003', 'a0000000-0000-0000-0000-000000000002'), 10);
end $$;
-- T10 resucitar vuelve a descontar (ahora 12)
update public.orders set status = 'open', status_ext = 'open'
 where id = '00000000-0000-0000-0000-0000000000a5';
do $$ begin
  perform test.chk('T10 MAIN', test.stock('c0000000-0000-0000-0000-000000000003', 'a0000000-0000-0000-0000-000000000001'), 0);
  perform test.chk('T10 NEVERA', test.stock('c0000000-0000-0000-0000-000000000003', 'a0000000-0000-0000-0000-000000000002'), 1);
end $$;

do $$
declare v_line uuid;
begin
  -- T11 combo: el componente descuenta en su área
  insert into public.orders (id, session_id) values ('00000000-0000-0000-0000-0000000000a6', 'f0000000-0000-0000-0000-000000000001');
  insert into public.order_items (order_id, product_id, qty, quantity)
    values ('00000000-0000-0000-0000-0000000000a6', 'd0000000-0000-0000-0000-000000000003', 1, 1) returning id into v_line;
  insert into public.order_item_modifiers (item_id, name, qty, menu_item_id)
    values (v_line, 'Hamburguesa', 1, 'd0000000-0000-0000-0000-000000000001');
  perform public.consume_inventory_from_order('00000000-0000-0000-0000-0000000000a6');
  perform test.chk('T11 combo PAN en COCINA', test.stock('c0000000-0000-0000-0000-000000000001', 'a0000000-0000-0000-0000-000000000003'), 14);
  perform test.chk('T11 combo QUESO en COCINA', test.stock('c0000000-0000-0000-0000-000000000002', 'a0000000-0000-0000-0000-000000000003'), 720);
  -- T12 modificador en producto sin inventario ni área: cae a la cascada, la última queda debiendo
  perform test.sell('00000000-0000-0000-0000-0000000000a7', 'd0000000-0000-0000-0000-000000000004', 1, 'e0000000-0000-0000-0000-000000000001');
  perform test.chk('T12 QUESO debe la última de la cascada', test.stock('c0000000-0000-0000-0000-000000000002', 'a0000000-0000-0000-0000-000000000002'), -30);
  -- T13 status_ext NULL NO es anulada
  perform test.sell('00000000-0000-0000-0000-0000000000a8', 'd0000000-0000-0000-0000-000000000002', 1, null, 1, null);
  perform test.chk('T13 NULL descuenta normal', test.stock('c0000000-0000-0000-0000-000000000003', 'a0000000-0000-0000-0000-000000000002'), 0);
end $$;
SQL
[ "${PIPESTATUS[0]}" -eq 0 ] && ok "escenarios T1–T13" || bad "escenarios (ver arriba)"

echo "== 6. Con la unificada viva, las migraciones viejas no la borran"
for f in 20260901_0006_pos_multi_warehouse.sql 20260907_0003_consume_modifier_ingredients.sql 20260910_0002_consume_skip_voided_orders.sql; do
  OUT=$(Q -f "$(block "$M/$f")" 2>&1)
  echo "$OUT" | grep -q "Guardia de rama" && has "UNIFICADA 20260915_0002" && ok "$f se saltó" || bad "$f pisó la unificada"
done
for f in 20260901_0006_pos_multi_warehouse_ROLLBACK.sql 20260907_0003_consume_modifier_ingredients_ROLLBACK.sql 20260910_0002_consume_skip_voided_orders_ROLLBACK.sql; do
  [ -f "$M/$f" ] || { echo "  (no existe $f)"; continue; }
  OUT=$(Q -f "$M/$f" 2>&1)
  echo "$OUT" | grep -q "Guardia de rama" && has "UNIFICADA 20260915_0002" && ok "$f abortó" || bad "$f revirtió la unificada"
done

echo "== 7. ROLLBACK de la unificada → vuelve A y se va el trigger"
Q -f "$M/20260915_0002_consume_unified_ROLLBACK.sql" >/dev/null 2>&1 \
  && has fn_resolve_area_warehouse && ! has "UNIFICADA" && ! has modifier_ingredients \
  && [ "$(Q -At -c "select count(*) from pg_trigger where tgname='trg_orders_reconcile_inventory_on_status'")" = "0" ] \
  && ok "restaurada A, sin trigger" || bad "ROLLBACK unificada"
OUT=$(Q -f "$M/20260915_0002_consume_unified_ROLLBACK.sql" 2>&1)
echo "$OUT" | grep -q "no hay nada que revertir" && ok "segundo ROLLBACK no hace nada" || bad "segundo ROLLBACK"

echo "== 8. Orden inverso: la viva es la rama B y llega 20260901_0006"
Q -c "drop function public.consume_inventory_from_order(uuid)" >/dev/null
Q -f "$(block "$M/20260907_0003_consume_modifier_ingredients.sql")" >/dev/null 2>&1 && has modifier_ingredients \
  && ok "B instalada" || bad "instalar B"
OUT=$(Q -f "$(block "$M/20260901_0006_pos_multi_warehouse.sql")" 2>&1)
echo "$OUT" | grep -q "Guardia de rama" && has modifier_ingredients && ! has fn_resolve_area_warehouse \
  && ok "20260901_0006 se saltó sin borrar B" || bad "20260901_0006 pisó B"
Q -f "$M/20260915_0002_consume_unified.sql" >/dev/null 2>&1 && has "UNIFICADA 20260915_0002" \
  && ok "unificada sobre B" || bad "unificada sobre B"
Q -c "select public.consume_inventory_from_order('00000000-0000-0000-0000-0000000000a1')" >/dev/null
Q -c "do \$\$ begin perform test.chk('sobre B: O1 sin movimientos nuevos', test.movs('00000000-0000-0000-0000-0000000000a1'), 2); end \$\$" >/dev/null \
  && ok "O1 intacta tras pasar por B" || bad "O1 tras B"

echo
[ $FAIL -eq 0 ] && echo "RESULTADO: TODO EN VERDE" || { echo "RESULTADO: HAY FALLAS"; exit 1; }
