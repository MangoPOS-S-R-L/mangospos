#!/usr/bin/env bash
# =============================================================================
# Prueba LOCAL de Compras F3 (20260915_0007, fn_inventory_set_min_stock_bulk).
# Postgres 15 DESECHABLE con esquema mínimo y usuarios simulados (auth.uid()
# lee `test.uid`). Corre la migración REAL del repo.
#   bash supabase/tests/compras_f3_local_test.sh [carpeta_trabajo]
# Variables: PG_BIN (default homebrew postgresql@15), PG_PORT (default 55443).
# =============================================================================
set -u
REPO=$(cd "$(dirname "$0")/../.." && pwd)
M=$REPO/supabase/migrations
MIG=$M/20260915_0007_compras_f3_minimos_en_lote.sql
PG=${PG_BIN:-/opt/homebrew/opt/postgresql@15/bin}
PORT=${PG_PORT:-55443}
WORK=${1:-$(mktemp -d)}
D=$WORK/pg_compras_f3
rm -rf "$D"; mkdir -p "$D"
"$PG/initdb" -D "$D/data" -U postgres --auth=trust >/dev/null || exit 1
"$PG/pg_ctl" -D "$D/data" -o "-p $PORT -c listen_addresses=127.0.0.1 -c unix_socket_directories=''" \
  -l "$D/log" start -w >/dev/null || { cat "$D/log"; exit 1; }
trap '"$PG/pg_ctl" -D "$D/data" stop -m fast >/dev/null 2>&1' EXIT
Q() { "$PG/psql" -h 127.0.0.1 -p "$PORT" -U postgres -X -q -v ON_ERROR_STOP=1 "$@"; }
FAIL=0
ok()  { echo "  ok     $1"; }
bad() { echo "  FALLA  $1"; FAIL=1; }

echo "== Esquema mínimo (sin las funciones de permiso todavía)"
Q <<'SQL' || { bad "esquema"; exit 1; }
create role authenticated; create role anon;
create schema auth;
create function auth.uid() returns uuid language sql stable as
  $$ select nullif(current_setting('test.uid', true), '')::uuid $$;
create table public.warehouses (id uuid primary key, business_id uuid, name text, is_active boolean default true);
create table public.inventory_items (id uuid primary key, business_id uuid, name text, min_stock numeric default 0, max_stock numeric);
create table public.inventory_stock (id uuid primary key default gen_random_uuid(), warehouse_id uuid not null, item_id uuid not null,
  quantity numeric default 0, last_updated timestamptz default now(), min_stock numeric, unique (warehouse_id, item_id));
create table public.test_roles (user_id uuid, business_id uuid, role text);
create table public.test_perms (user_id uuid, business_id uuid, code text);
create schema test;
create function test.chk(p_label text, p_ok boolean, p_detail text default '') returns void language plpgsql as $$
begin
  if p_ok is not true then raise exception 'FALLA % %', p_label, coalesce(p_detail, ''); end if;
  raise notice 'ok  %', p_label;
end $$;
-- Huella de los datos: si un intento fallido cambia algo, cambia la huella.
create function test.huella() returns text language sql as $$
  select md5(coalesce((select string_agg(id || ':' || coalesce(min_stock::text, '∅'), ',' order by id) from public.inventory_items), '')
          || '|' || coalesce((select string_agg(warehouse_id || ':' || item_id || ':' || quantity || ':' || coalesce(min_stock::text, '∅'), ',' order by warehouse_id, item_id) from public.inventory_stock), ''))
$$;
create function test.falla_sin_cambiar(p_label text, p_sql text, p_code text) returns void language plpgsql as $$
declare v_before text := test.huella(); v_msg text;
begin
  begin
    execute p_sql;
    raise exception 'FALLA % (no dio error)', p_label;
  exception when others then
    v_msg := sqlerrm;
    if v_msg like 'FALLA %' then raise; end if;
  end;
  perform test.chk(p_label, v_msg like p_code || '%' and test.huella() = v_before, v_msg);
end $$;
SQL
ok "esquema"

echo "== Guardia"
OUT=$(Q -f "$MIG" 2>&1)
echo "$OUT" | grep -q "Falta public.user_has_business_permission" && ok "sin las funciones de permiso no se aplica" || { bad "guardia"; echo "$OUT" | tail -3; }

Q <<'SQL' >/dev/null || { bad "funciones de permiso"; exit 1; }
create function public.user_business_role(p_user uuid, p_business uuid) returns text language sql stable as
  $$ select role from public.test_roles where user_id = p_user and business_id = p_business $$;
create function public.user_has_business_permission(p_business uuid, p_code text) returns boolean language sql stable as
  $$ select exists (select 1 from public.test_perms where user_id = auth.uid() and business_id = p_business and code = p_code) $$;
SQL
Q -f "$MIG" >/dev/null 2>&1 && Q -f "$MIG" >/dev/null 2>&1 && ok "aplicada dos veces" || { bad "aplicar"; Q -f "$MIG" 2>&1 | tail -5; exit 1; }

echo "== Semilla"
Q <<'SQL' >/dev/null || { bad "semilla"; exit 1; }
-- B = Penda; O = otro negocio.
-- Usuarios: 1 dueño de B, 2 cajero de B SIN permiso, 3 cajero de B CON permiso, 4 dueño de O.
insert into public.test_roles values
 ('10000000-0000-0000-0000-000000000001','35c5076a-bd85-4a1b-8d1c-ce719c4f9ae6','owner'),
 ('10000000-0000-0000-0000-000000000002','35c5076a-bd85-4a1b-8d1c-ce719c4f9ae6','cashier'),
 ('10000000-0000-0000-0000-000000000003','35c5076a-bd85-4a1b-8d1c-ce719c4f9ae6','cashier'),
 ('10000000-0000-0000-0000-000000000004','22222222-2222-2222-2222-222222222222','owner');
insert into public.test_perms values
 ('10000000-0000-0000-0000-000000000003','35c5076a-bd85-4a1b-8d1c-ce719c4f9ae6','inventario.productos.crear_editar');
insert into public.warehouses (id, business_id, name) values
 ('a0000000-0000-0000-0000-000000000001','35c5076a-bd85-4a1b-8d1c-ce719c4f9ae6','Principal'),
 ('a0000000-0000-0000-0000-000000000003','35c5076a-bd85-4a1b-8d1c-ce719c4f9ae6','__IN_TRANSIT__'),
 ('a0000000-0000-0000-0000-0000000000ff','22222222-2222-2222-2222-222222222222','Otro');
insert into public.inventory_items (id, business_id, name, min_stock) values
 ('c0000000-0000-0000-0000-000000000001','35c5076a-bd85-4a1b-8d1c-ce719c4f9ae6','Queso', 5),
 ('c0000000-0000-0000-0000-000000000002','35c5076a-bd85-4a1b-8d1c-ce719c4f9ae6','Latas', 0),
 ('c0000000-0000-0000-0000-000000000003','35c5076a-bd85-4a1b-8d1c-ce719c4f9ae6','Harina', null),
 ('c0000000-0000-0000-0000-0000000000ff','22222222-2222-2222-2222-222222222222','Ajeno', 1);
-- Queso ya tiene fila en Principal con existencia 7 y mínimo propio 4.
insert into public.inventory_stock (warehouse_id, item_id, quantity, min_stock) values
 ('a0000000-0000-0000-0000-000000000001','c0000000-0000-0000-0000-000000000001', 7, 4);
SQL
ok "semilla"

echo "== Mínimos en lote"
if OUT=$(Q 2>&1 <<'SQL'
do $$
declare r jsonb;
  B constant uuid := '35c5076a-bd85-4a1b-8d1c-ce719c4f9ae6';
  W constant uuid := 'a0000000-0000-0000-0000-000000000001';
begin
  perform set_config('test.uid', '10000000-0000-0000-0000-000000000001', false);

  -- General.
  r := public.fn_inventory_set_min_stock_bulk(B, null,
    '[{"item_id":"c0000000-0000-0000-0000-000000000001","min_stock":12.5},
      {"item_id":"c0000000-0000-0000-0000-000000000002","min_stock":24},
      {"item_id":"C0000000-0000-0000-0000-000000000003","min_stock":0}]');
  perform test.chk('G1 general: 3 cambios (el uuid en mayúsculas sirve), la Harina null → 0 cuenta',
    (r->>'updated')::int = 3 and (r->>'unchanged')::int = 0 and r->>'scope' = 'general', r::text);
  perform test.chk('G1 valores guardados', (select min_stock from inventory_items where id = 'c0000000-0000-0000-0000-000000000001') = 12.5
    and (select min_stock from inventory_items where id = 'c0000000-0000-0000-0000-000000000002') = 24);

  r := public.fn_inventory_set_min_stock_bulk(B, null,
    '[{"item_id":"c0000000-0000-0000-0000-000000000001","min_stock":12.5},
      {"item_id":"c0000000-0000-0000-0000-000000000002","min_stock":null}]');
  perform test.chk('G2 lo igual no se reescribe; quitar el general deja 0',
    (r->>'updated')::int = 1 and (r->>'unchanged')::int = 1
    and (select min_stock from inventory_items where id = 'c0000000-0000-0000-0000-000000000002') = 0, r::text);
  perform test.chk('G2 el general no toca inventory_stock',
    (select min_stock from inventory_stock where item_id = 'c0000000-0000-0000-0000-000000000001') = 4);

  -- Almacén.
  r := public.fn_inventory_set_min_stock_bulk(B, W,
    '[{"item_id":"c0000000-0000-0000-0000-000000000001","min_stock":9},
      {"item_id":"c0000000-0000-0000-0000-000000000002","min_stock":6},
      {"item_id":"c0000000-0000-0000-0000-000000000003","min_stock":null}]');
  perform test.chk('A1 almacén: cambia el propio del Queso y crea el de las Latas; quitar lo que no existe no crea fila',
    (r->>'updated')::int = 2 and (r->>'unchanged')::int = 1 and r->>'scope' = 'almacen'
    and not exists (select 1 from inventory_stock where item_id = 'c0000000-0000-0000-0000-000000000003'), r::text);
  perform test.chk('A1 la existencia no se toca (Queso sigue en 7; Latas nace en 0)',
    exists (select 1 from inventory_stock where item_id = 'c0000000-0000-0000-0000-000000000001' and quantity = 7 and min_stock = 9)
    and exists (select 1 from inventory_stock where item_id = 'c0000000-0000-0000-0000-000000000002' and quantity = 0 and min_stock = 6));

  r := public.fn_inventory_set_min_stock_bulk(B, W,
    '[{"item_id":"c0000000-0000-0000-0000-000000000001","min_stock":null}]');
  perform test.chk('A2 quitar el propio lo deja en null (rige el general) y conserva la fila',
    (r->>'updated')::int = 1
    and exists (select 1 from inventory_stock where item_id = 'c0000000-0000-0000-0000-000000000001' and min_stock is null and quantity = 7), r::text);

  -- Cajero CON el permiso de editar insumos.
  perform set_config('test.uid', '10000000-0000-0000-0000-000000000003', false);
  r := public.fn_inventory_set_min_stock_bulk(B, null,
    '[{"item_id":"c0000000-0000-0000-0000-000000000003","min_stock":2}]');
  perform test.chk('P1 un empleado con inventario.productos.crear_editar puede', (r->>'updated')::int = 1, r::text);
end $$;

select set_config('test.uid', '10000000-0000-0000-0000-000000000002', false);
select test.falla_sin_cambiar('P2 cajero SIN permiso: rechazado y nada cambia',
  $q$select public.fn_inventory_set_min_stock_bulk('35c5076a-bd85-4a1b-8d1c-ce719c4f9ae6', null,
     '[{"item_id":"c0000000-0000-0000-0000-000000000001","min_stock":1}]')$q$, 'MIN_STOCK_BULK_ACCESS_DENIED');
select set_config('test.uid', '10000000-0000-0000-0000-000000000004', false);
select test.falla_sin_cambiar('P3 dueño de OTRO negocio: rechazado',
  $q$select public.fn_inventory_set_min_stock_bulk('35c5076a-bd85-4a1b-8d1c-ce719c4f9ae6', null,
     '[{"item_id":"c0000000-0000-0000-0000-000000000001","min_stock":1}]')$q$, 'MIN_STOCK_BULK_ACCESS_DENIED');
select set_config('test.uid', '', false);
select test.falla_sin_cambiar('P4 sin sesión: rechazado',
  $q$select public.fn_inventory_set_min_stock_bulk('35c5076a-bd85-4a1b-8d1c-ce719c4f9ae6', null,
     '[{"item_id":"c0000000-0000-0000-0000-000000000001","min_stock":1}]')$q$, 'AUTH_REQUIRED');

select set_config('test.uid', '10000000-0000-0000-0000-000000000001', false);
select test.falla_sin_cambiar('V1 un insumo de otro negocio al final: no se guarda NI el primero',
  $q$select public.fn_inventory_set_min_stock_bulk('35c5076a-bd85-4a1b-8d1c-ce719c4f9ae6', null,
     '[{"item_id":"c0000000-0000-0000-0000-000000000001","min_stock":99},
       {"item_id":"c0000000-0000-0000-0000-0000000000ff","min_stock":1}]')$q$, 'MIN_STOCK_BULK_ITEM_INVALID');
select test.falla_sin_cambiar('V2 mínimo negativo',
  $q$select public.fn_inventory_set_min_stock_bulk('35c5076a-bd85-4a1b-8d1c-ce719c4f9ae6', null,
     '[{"item_id":"c0000000-0000-0000-0000-000000000001","min_stock":-1}]')$q$, 'MIN_STOCK_BULK_LINE_INVALID');
select test.falla_sin_cambiar('V3 mínimo como texto',
  $q$select public.fn_inventory_set_min_stock_bulk('35c5076a-bd85-4a1b-8d1c-ce719c4f9ae6', null,
     '[{"item_id":"c0000000-0000-0000-0000-000000000001","min_stock":"5"}]')$q$, 'MIN_STOCK_BULK_LINE_INVALID');
select test.falla_sin_cambiar('V4 sin la clave min_stock',
  $q$select public.fn_inventory_set_min_stock_bulk('35c5076a-bd85-4a1b-8d1c-ce719c4f9ae6', null,
     '[{"item_id":"c0000000-0000-0000-0000-000000000001"}]')$q$, 'MIN_STOCK_BULK_LINE_INVALID');
select test.falla_sin_cambiar('V5 id que no es uuid',
  $q$select public.fn_inventory_set_min_stock_bulk('35c5076a-bd85-4a1b-8d1c-ce719c4f9ae6', null,
     '[{"item_id":"queso","min_stock":1}]')$q$, 'MIN_STOCK_BULK_LINE_INVALID');
select test.falla_sin_cambiar('V6 insumo repetido (aunque cambie mayúsculas)',
  $q$select public.fn_inventory_set_min_stock_bulk('35c5076a-bd85-4a1b-8d1c-ce719c4f9ae6', null,
     '[{"item_id":"c0000000-0000-0000-0000-000000000001","min_stock":1},
       {"item_id":"C0000000-0000-0000-0000-000000000001","min_stock":2}]')$q$, 'MIN_STOCK_BULK_DUPLICATE');
select test.falla_sin_cambiar('V7 almacén de otro negocio',
  $q$select public.fn_inventory_set_min_stock_bulk('35c5076a-bd85-4a1b-8d1c-ce719c4f9ae6', 'a0000000-0000-0000-0000-0000000000ff',
     '[{"item_id":"c0000000-0000-0000-0000-000000000001","min_stock":1}]')$q$, 'MIN_STOCK_BULK_INVALID');
select test.falla_sin_cambiar('V8 el almacén de tránsito no tiene mínimos',
  $q$select public.fn_inventory_set_min_stock_bulk('35c5076a-bd85-4a1b-8d1c-ce719c4f9ae6', 'a0000000-0000-0000-0000-000000000003',
     '[{"item_id":"c0000000-0000-0000-0000-000000000001","min_stock":1}]')$q$, 'MIN_STOCK_BULK_INVALID');
select test.falla_sin_cambiar('V9 lote vacío',
  $q$select public.fn_inventory_set_min_stock_bulk('35c5076a-bd85-4a1b-8d1c-ce719c4f9ae6', null, '[]')$q$, 'MIN_STOCK_BULK_EMPTY');

do $$
begin
  perform test.chk('S1 EXECUTE: authenticated sí; anon y public no',
    has_function_privilege('authenticated', 'public.fn_inventory_set_min_stock_bulk(uuid,uuid,jsonb)', 'execute')
    and not has_function_privilege('anon', 'public.fn_inventory_set_min_stock_bulk(uuid,uuid,jsonb)', 'execute'));
  perform test.chk('S2 SECURITY DEFINER con lock_timeout propio',
    (select prosecdef and proconfig @> array['lock_timeout=5s'] from pg_proc where proname = 'fn_inventory_set_min_stock_bulk'));
end $$;
SQL
); then echo "$OUT" | grep "NOTICE:  ok" | sed 's/^.*NOTICE:  /  /'; ok "mínimos en lote"
else echo "$OUT" | grep -E "NOTICE:  ok|ERROR" | sed 's/^.*NOTICE:  /  /; s/^psql:[^:]*:[0-9]*: //'; bad "mínimos en lote"; fi

echo "== ROLLBACK"
Q -f "$M/20260915_0007_compras_f3_minimos_en_lote_ROLLBACK.sql" >/dev/null 2>&1 \
  && [ "$(Q -At -c "select count(*) from pg_proc where proname = 'fn_inventory_set_min_stock_bulk'")" = "0" ] \
  && [ "$(Q -At -c "select min_stock from public.inventory_items where id = 'c0000000-0000-0000-0000-000000000003'")" = "2" ] \
  && ok "rollback quita la función y deja los mínimos guardados" || bad "rollback"

echo
[ $FAIL -eq 0 ] && echo "RESULTADO: TODO EN VERDE" || { echo "RESULTADO: HAY FALLAS"; exit 1; }
