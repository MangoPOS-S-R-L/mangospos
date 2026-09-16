#!/usr/bin/env bash
# =============================================================================
# Prueba LOCAL de Compras F5a (20260915_0009, presentaciones de dos niveles).
# Postgres 15 DESECHABLE; corre la migración REAL. auth.uid() lee `test.uid`.
#   bash supabase/tests/compras_f5_local_test.sh [carpeta_trabajo]
# Variables: PG_BIN (default homebrew postgresql@15), PG_PORT (default 55447).
# =============================================================================
set -u
REPO=$(cd "$(dirname "$0")/../.." && pwd)
M=$REPO/supabase/migrations
MIG=$M/20260915_0009_compras_f5_presentaciones.sql
PG=${PG_BIN:-/opt/homebrew/opt/postgresql@15/bin}
PORT=${PG_PORT:-55447}
WORK=${1:-$(mktemp -d)}
D=$WORK/pg_compras_f5
rm -rf "$D"; mkdir -p "$D"
"$PG/initdb" -D "$D/data" -U postgres --auth=trust >/dev/null || exit 1
"$PG/pg_ctl" -D "$D/data" -o "-p $PORT -c listen_addresses=127.0.0.1 -c unix_socket_directories=''" \
  -l "$D/log" start -w >/dev/null || { cat "$D/log"; exit 1; }
trap '"$PG/pg_ctl" -D "$D/data" stop -m fast >/dev/null 2>&1' EXIT
Q() { "$PG/psql" -h 127.0.0.1 -p "$PORT" -U postgres -X -q -v ON_ERROR_STOP=1 "$@"; }
FAIL=0
ok()  { echo "  ok     $1"; }
bad() { echo "  FALLA  $1"; FAIL=1; }

echo "== Esquema mínimo (sin funciones de permiso todavía)"
Q <<'SQL' || { bad "esquema"; exit 1; }
-- Las funciones de prueba nombran la tabla que crea la migración.
set check_function_bodies = off;
create role authenticated; create role anon;
create schema auth;
create function auth.uid() returns uuid language sql stable as
  $$ select nullif(current_setting('test.uid', true), '')::uuid $$;
create table public.businesses (id uuid primary key, name text);
create table public.inventory_items (id uuid primary key, business_id uuid, name text, unit text default 'unidad',
  purchase_unit text, pack_size numeric default 1);
create table public.test_perms (user_id uuid, business_id uuid, code text);
create schema test;
create function test.chk(p_label text, p_ok boolean, p_detail text default '') returns void language plpgsql as $$
begin
  if p_ok is not true then raise exception 'FALLA % %', p_label, coalesce(p_detail, ''); end if;
  raise notice 'ok  %', p_label;
end $$;
create function test.huella() returns text language sql as $$
  select md5(coalesce((select string_agg(item_id || ':' || unit || ':' || base_qty || ':' || is_purchase_default, ',' order by item_id, sort_order)
                         from public.inventory_item_presentations), '')
          || '|' || coalesce((select string_agg(id || ':' || coalesce(purchase_unit, '∅') || ':' || pack_size, ',' order by id) from public.inventory_items), ''))
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
echo "$OUT" | grep -q "Faltan user_has_business_permission" && ok "sin las funciones de permiso no se aplica" || { bad "guardia"; echo "$OUT" | tail -3; }
Q <<'SQL' >/dev/null || { bad "funciones de permiso"; exit 1; }
create function public.user_has_business_access(p_user uuid, p_business uuid) returns boolean language sql stable as $$ select true $$;
create function public.user_has_business_permission(p_business uuid, p_code text) returns boolean language sql stable as
  $$ select exists (select 1 from public.test_perms where user_id = auth.uid() and business_id = p_business and code = p_code) $$;
SQL
Q -f "$MIG" >/dev/null 2>&1 && Q -f "$MIG" >/dev/null 2>&1 && ok "aplicada dos veces" || { bad "aplicar"; Q -f "$MIG" 2>&1 | tail -5; exit 1; }

echo "== Semilla"
Q <<'SQL' >/dev/null || { bad "semilla"; exit 1; }
insert into public.businesses values ('35c5076a-bd85-4a1b-8d1c-ce719c4f9ae6','Penda'), ('22222222-2222-2222-2222-222222222222','Otro');
insert into public.test_perms values
 ('10000000-0000-0000-0000-000000000001','35c5076a-bd85-4a1b-8d1c-ce719c4f9ae6','inventario.productos.crear_editar');
insert into public.inventory_items (id, business_id, name, unit, purchase_unit, pack_size) values
 ('c0000000-0000-0000-0000-000000000001','35c5076a-bd85-4a1b-8d1c-ce719c4f9ae6','Refresco lata','ml', null, 1),
 ('c0000000-0000-0000-0000-000000000002','35c5076a-bd85-4a1b-8d1c-ce719c4f9ae6','Queso','lb', 'Caja', 10),
 ('c0000000-0000-0000-0000-0000000000ff','22222222-2222-2222-2222-222222222222','Ajeno','unidad', null, 1);
SQL
ok "semilla"

echo "== Presentaciones"
if OUT=$(Q 2>&1 <<'SQL'
do $$
declare r jsonb;
  REF constant uuid := 'c0000000-0000-0000-0000-000000000001';
  QUE constant uuid := 'c0000000-0000-0000-0000-000000000002';
begin
  perform set_config('test.uid', '10000000-0000-0000-0000-000000000001', false);

  -- Caja = 24 Lata (va primero en la lista); Lata = 355 ml. La caja es la de compra.
  r := public.fn_inventory_item_presentations_save(REF,
    '[{"unit":"Caja","contains_qty":24,"contains_unit":"lata","is_purchase_default":true},
      {"unit":"Lata","contains_qty":355,"contains_unit":null}]');
  perform test.chk('P1 dos niveles: Lata 355 ml, Caja 24 Lata = 8520 ml (el contenedor puede ir después y en minúsculas)',
    jsonb_array_length(r) = 2
    and exists (select 1 from inventory_item_presentations where item_id = REF and unit = 'Lata' and base_qty = 355 and contains_unit is null)
    and exists (select 1 from inventory_item_presentations where item_id = REF and unit = 'Caja' and base_qty = 8520
                and contains_unit = 'Lata' and contains_qty = 24 and is_purchase_default), r::text);
  perform test.chk('P1 la de compra se aplana en la ficha: Caja × 8520',
    exists (select 1 from inventory_items where id = REF and purchase_unit = 'Caja' and pack_size = 8520));

  -- Reemplazo: ahora solo la lata, y es la de compra.
  r := public.fn_inventory_item_presentations_save(REF, '[{"unit":"Lata","contains_qty":355,"is_purchase_default":true}]');
  perform test.chk('P2 guardar reemplaza el juego completo y re-aplana (Lata × 355)',
    (select count(*) from inventory_item_presentations where item_id = REF) = 1
    and exists (select 1 from inventory_items where id = REF and purchase_unit = 'Lata' and pack_size = 355), r::text);

  -- Sin presentación de compra: la ficha no se toca.
  r := public.fn_inventory_item_presentations_save(QUE,
    '[{"unit":"Bloque","contains_qty":5,"contains_unit":"LB"}]');
  perform test.chk('P3 sin «de compra» la ficha queda como estaba (Caja × 10); contains_unit igual a la base = base',
    exists (select 1 from inventory_items where id = QUE and purchase_unit = 'Caja' and pack_size = 10)
    and exists (select 1 from inventory_item_presentations where item_id = QUE and unit = 'Bloque' and base_qty = 5 and contains_unit is null), r::text);

  r := public.fn_inventory_item_presentations_save(QUE, '[]');
  perform test.chk('P4 lista vacía borra las presentaciones y no toca la ficha',
    not exists (select 1 from inventory_item_presentations where item_id = QUE)
    and exists (select 1 from inventory_items where id = QUE and purchase_unit = 'Caja' and pack_size = 10), r::text);
end $$;

select set_config('test.uid', '10000000-0000-0000-0000-000000000001', false);
select test.falla_sin_cambiar('V1 nombre repetido (sin importar mayúsculas)',
  $q$select public.fn_inventory_item_presentations_save('c0000000-0000-0000-0000-000000000001',
     '[{"unit":"Caja","contains_qty":24},{"unit":"CAJA ","contains_qty":12}]')$q$, 'PRESENTATIONS_DUPLICATE');
select test.falla_sin_cambiar('V2 igual a la unidad base',
  $q$select public.fn_inventory_item_presentations_save('c0000000-0000-0000-0000-000000000001',
     '[{"unit":"ML","contains_qty":1}]')$q$, 'PRESENTATIONS_SAME_AS_BASE');
select test.falla_sin_cambiar('V3 cantidad 0',
  $q$select public.fn_inventory_item_presentations_save('c0000000-0000-0000-0000-000000000001',
     '[{"unit":"Lata","contains_qty":0}]')$q$, 'PRESENTATIONS_LINE_INVALID');
select test.falla_sin_cambiar('V4 cantidad como texto',
  $q$select public.fn_inventory_item_presentations_save('c0000000-0000-0000-0000-000000000001',
     '[{"unit":"Lata","contains_qty":"355"}]')$q$, 'PRESENTATIONS_LINE_INVALID');
select test.falla_sin_cambiar('V5 contiene una presentación que no existe',
  $q$select public.fn_inventory_item_presentations_save('c0000000-0000-0000-0000-000000000001',
     '[{"unit":"Caja","contains_qty":24,"contains_unit":"Botella"}]')$q$, 'PRESENTATIONS_BAD_PARENT');
select test.falla_sin_cambiar('V6 tres niveles (Pallet = 50 Caja, Caja = 24 Lata)',
  $q$select public.fn_inventory_item_presentations_save('c0000000-0000-0000-0000-000000000001',
     '[{"unit":"Lata","contains_qty":355},{"unit":"Caja","contains_qty":24,"contains_unit":"Lata"},
       {"unit":"Pallet","contains_qty":50,"contains_unit":"Caja"}]')$q$, 'PRESENTATIONS_BAD_PARENT');
select test.falla_sin_cambiar('V7 se contiene a sí misma',
  $q$select public.fn_inventory_item_presentations_save('c0000000-0000-0000-0000-000000000001',
     '[{"unit":"Caja","contains_qty":2,"contains_unit":"caja"}]')$q$, 'PRESENTATIONS_BAD_PARENT');
select test.falla_sin_cambiar('V8 dos de compra por defecto',
  $q$select public.fn_inventory_item_presentations_save('c0000000-0000-0000-0000-000000000001',
     '[{"unit":"Lata","contains_qty":355,"is_purchase_default":true},{"unit":"Six pack","contains_qty":6,"contains_unit":"Lata","is_purchase_default":true}]')$q$,
  'PRESENTATIONS_DEFAULT_DUPLICATE');
select test.falla_sin_cambiar('V9 más de 5',
  $q$select public.fn_inventory_item_presentations_save('c0000000-0000-0000-0000-000000000001',
     '[{"unit":"a","contains_qty":1},{"unit":"b","contains_qty":1},{"unit":"c","contains_qty":1},
       {"unit":"d","contains_qty":1},{"unit":"e","contains_qty":1},{"unit":"f","contains_qty":1}]')$q$, 'PRESENTATIONS_TOO_MANY');
select test.falla_sin_cambiar('V10 no es lista',
  $q$select public.fn_inventory_item_presentations_save('c0000000-0000-0000-0000-000000000001', '{"unit":"Lata"}')$q$,
  'PRESENTATIONS_INVALID');

select set_config('test.uid', '10000000-0000-0000-0000-000000000002', false);
select test.falla_sin_cambiar('S1 sin el permiso de editar insumos: rechazado y nada cambia',
  $q$select public.fn_inventory_item_presentations_save('c0000000-0000-0000-0000-000000000001', '[]')$q$,
  'PRESENTATIONS_ACCESS_DENIED');
select test.falla_sin_cambiar('S2 insumo que no existe',
  $q$select public.fn_inventory_item_presentations_save('c0000000-0000-0000-0000-00000000dead', '[]')$q$,
  'PRESENTATIONS_ITEM_NOT_FOUND');
select test.falla_sin_cambiar('S3 una fila directa que apunta a un insumo de OTRO negocio',
  $q$insert into public.inventory_item_presentations (business_id, item_id, unit, contains_qty, base_qty)
     values ('35c5076a-bd85-4a1b-8d1c-ce719c4f9ae6', 'c0000000-0000-0000-0000-0000000000ff', 'Caja', 1, 1)$q$,
  'PRESENTATIONS_ITEM_BUSINESS_MISMATCH');

do $$
begin
  perform test.chk('S4 RLS encendido con sus dos policies',
    (select relrowsecurity from pg_class where oid = 'public.inventory_item_presentations'::regclass)
    and (select count(*) from pg_policies where tablename = 'inventory_item_presentations') = 2);
  perform test.chk('S5 authenticated lee y escribe la tabla; anon no',
    has_table_privilege('authenticated', 'public.inventory_item_presentations', 'select,insert,update,delete')
    and not has_table_privilege('anon', 'public.inventory_item_presentations', 'select'));
  perform test.chk('S6 la función de guardar: authenticated sí, anon no',
    has_function_privilege('authenticated', 'public.fn_inventory_item_presentations_save(uuid,jsonb)', 'execute')
    and not has_function_privilege('anon', 'public.fn_inventory_item_presentations_save(uuid,jsonb)', 'execute'));
end $$;
SQL
); then echo "$OUT" | grep "NOTICE:  ok" | sed 's/^.*NOTICE:  /  /'; ok "presentaciones"
else echo "$OUT" | grep -E "NOTICE:  ok|ERROR" | sed 's/^.*NOTICE:  /  /; s/^psql:[^:]*:[0-9]*: //'; bad "presentaciones"; fi

echo "== ROLLBACK"
Q -f "$M/20260915_0009_compras_f5_presentaciones_ROLLBACK.sql" >/dev/null 2>&1 \
  && [ "$(Q -At -c "select to_regclass('public.inventory_item_presentations') is null")" = "t" ] \
  && [ "$(Q -At -c "select purchase_unit || ':' || pack_size from public.inventory_items where id = 'c0000000-0000-0000-0000-000000000001'")" = "Lata:355" ] \
  && ok "rollback borra la tabla y deja la presentación aplanada en la ficha" || bad "rollback"

echo
[ $FAIL -eq 0 ] && echo "RESULTADO: TODO EN VERDE" || { echo "RESULTADO: HAY FALLAS"; exit 1; }
