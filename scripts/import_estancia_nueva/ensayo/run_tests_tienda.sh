#!/bin/bash
# Ensayo de IMPORT_TIENDA.sql / 99_rollback_tienda.sql contra un Postgres 15
# DESECHABLE con stub_tienda.sql. No toca ninguna base real.
#   PY=<python con openpyxl> bash ensayo/run_tests_tienda.sh [carpeta_trabajo]
set -u
B=${PG_BIN:-/opt/homebrew/opt/postgresql@15/bin}
PORT=${PG_PORT:-55472}
PY=${PY:-python3}
S="$(cd "$(dirname "$0")" && pwd)"
R="$(cd "$S/.." && pwd)"
W=${1:-$(mktemp -d)}
BIZ=40b0fa9d-9ce6-4e17-902d-6f5f37cc58ab
mkdir -p "$W/gen" "$W/log"
rm -rf "$W/pg"
$B/initdb -D "$W/pg" -U postgres --auth=trust >/dev/null || exit 1
$B/pg_ctl -D "$W/pg" -o "-p $PORT -c listen_addresses=127.0.0.1 -c unix_socket_directories=''" \
  -l "$W/pg.log" -w start >/dev/null || { cat "$W/pg.log"; exit 1; }
trap '$B/pg_ctl -D "$W/pg" stop -m fast >/dev/null 2>&1' EXIT
export PGHOST=127.0.0.1 PGPORT=$PORT PGUSER=postgres PGCLIENTENCODING=UTF8
PSQL="$B/psql -X -q -v ON_ERROR_STOP=1"
( cd "$R" && $PY build_import_tienda.py --out "$W/gen" ) || exit 1

FAIL=0
fresh()  { $B/dropdb --if-exists "$1" 2>/dev/null; $B/createdb "$1"; $PSQL -d "$1" -f "$S/stub_tienda.sql" >/dev/null; }
sql()    { $PSQL -d "$1" -Atc "$2"; }
imp()    { $PSQL -d "$1" -f "$W/gen/IMPORT_TIENDA.sql" > "$W/log/$2.log" 2>&1; echo "   exit=$?"; grep -E "NOTICE|ERROR" "$W/log/$2.log" | sed 's/^.*\(NOTICE\|ERROR\)/   \1/'; }
rb()     { $PSQL -d "$1" -f "$W/gen/99_rollback_tienda.sql" > "$W/log/$2.log" 2>&1; echo "   exit=$?"; grep -E "NOTICE|ERROR" "$W/log/$2.log" | sed 's/^.*\(NOTICE\|ERROR\)/   \1/'; }
counts() { sql "$1" "select 'productos='||(select count(*) from menu_items)
  ||' activos='||(select count(*) from menu_items where is_active)
  ||' cat='||(select count(*) from categories)
  ||' insumos='||(select count(*) from inventory_items)
  ||' movs='||(select count(*) from inventory_movements)
  ||' taxes='||(select count(*) from menu_item_taxes)
  ||' nm='||(select count(*) from menu_item_print_areas)
  ||' legacy='||(select count(*) from menu_items where print_area_code is not null)
  ||' links='||(select count(*) from menu_item_links)
  ||' menus='||(select count(*) from menus)
  ||' mode='||(select inventory_mode from business_settings)
  ||' tracked='||(select count(*) from menu_items where is_inventory_tracked)
  ||' neg='||(select count(*) from menu_items where allow_negative_sale)"; }
expect() { if [ "$2" = "$3" ]; then echo "   ok     $1"; else echo "   FALLA  $1"; echo "          obtenido: $2"; echo "          esperado: $3"; FAIL=1; fi; }
report() { local ok bad want=${3:-0}; ok=$(grep -c '✓' "$W/log/$1.log"); bad=$(grep -c '✗' "$W/log/$1.log")
  expect "reporte $1: $2 ✓ y $want ✗" "$ok/$bad" "$2/$want"; grep '✗' "$W/log/$1.log" | sed 's/^/          /'; }

VACIO='productos=1 activos=1 cat=0 insumos=0 movs=0 taxes=0 nm=0 legacy=0 links=0 menus=0 mode=none tracked=0 neg=0'
CARGADO='productos=354 activos=342 cat=4 insumos=344 movs=0 taxes=353 nm=0 legacy=0 links=353 menus=1 mode=basic tracked=344 neg=353'

echo "== T1 tienda con cocina APAGADA (lo normal): carga"
fresh t1; imp t1 t1
expect "conteos (353 + el producto de prueba, que no se toca)" "$(counts t1)" "$CARGADO"
report t1 14
expect "producto previo intacto" "$(sql t1 "select name||' '||price||' '||is_active from menu_items where sku='X-1'")" "PRODUCTO DE PRUEBA 100.00 true"
expect "categorías" "$(sql t1 "select string_agg(name||'='||(select count(*) from menu_items m where m.category_id=c.id), ' ' order by position) from categories c")" \
  "Pádel=54 Fútbol=216 Ropa y accesorios=74 Servicios del club=9"
expect "precios de muestra" \
  "$(sql t1 "select string_agg(sku||'='||price||(case when is_active then '+' else '-' end), ' ' order by sku)
             from menu_items where sku in ('110000100416','1017','110000100009','1228','110000100489','110000100488','1020')")" \
  "1017=2700.00+ 1020=0.00- 110000100009=2400.00+ 110000100416=8501.00+ 110000100488=8500.00+ 110000100489=0.00- 1228=200.00+"
expect "pala en dólares sin costo; pala con costo en dólares sin costo" \
  "$(sql t1 "select string_agg(sku||'='||coalesce(cost::text,'null'), ' ' order by sku) from menu_items where sku in ('110000100489','110000100488','1229')")" \
  "110000100488=null 110000100489=null 1229=5490.1300"
expect "servicios sin inventario" "$(sql t1 "select count(*) filter (where is_inventory_tracked)||'/'||count(*) from menu_items mi join categories c on c.id=mi.category_id where c.name='Servicios del club'")" "0/9"
expect "pelotas Wilson: barcode, insumo por código, stock 0" \
  "$(sql t1 "select mi.barcode||' '||ii.sku||' '||coalesce((select sum(quantity) from inventory_stock where item_id=ii.id),0) from menu_items mi join inventory_items ii on ii.id=mi.inventory_item_id where mi.sku='097512831048'")" \
  "097512831048 097512831048 0"

echo "== T2 segunda corrida (no duplica)"
imp t1 t2; expect "conteos" "$(counts t1)" "$CARGADO"; report t2 14

echo "== T3 cocina ENCENDIDA y sin áreas → aborta sin escribir"
fresh t3; sql t3 "update business_settings set kitchen_enabled=true"; imp t3 t3; expect "no escribió" "$(counts t3)" "$VACIO"

echo "== T4 cocina encendida con UNA área (Caja) → todo a esa"
fresh t4; sql t4 "update business_settings set kitchen_enabled=true; insert into print_areas (business_id,name,code) values ('$BIZ','CAJA','caja')"
imp t4 t4; expect "conteos" "$(counts t4)" "${CARGADO/nm=0 legacy=0/nm=353 legacy=353}"; report t4 14

echo "== T5 cocina encendida, áreas BAR y TIENDA → usa tienda"
fresh t5; sql t5 "update business_settings set kitchen_enabled=true; insert into print_areas (business_id,name,code) values ('$BIZ','BAR','bar'),('$BIZ','TIENDA','tienda')"
imp t5 t5; expect "área" "$(sql t5 "select string_agg(distinct print_area_code, ',') from menu_items where sku<>'X-1'")" "tienda"; report t5 14

echo "== T6 cocina encendida, áreas BAR y COCINA (sin tienda) → aborta"
fresh t6; sql t6 "update business_settings set kitchen_enabled=true; insert into print_areas (business_id,name,code) values ('$BIZ','BAR','bar'),('$BIZ','COCINA','cocina')"
imp t6 t6; expect "no escribió" "$(counts t6)" "$VACIO"

echo "== T7 la tienda ya tenía PELOTAS WILSON NEGRAS cargada a mano (mismo código de barras)"
fresh t7; sql t7 "insert into menu_items (business_id,name,price,barcode,is_active) values ('$BIZ','Pelotas wilson (mía)',600,'097512831048',true)"
imp t7 t7
expect "se actualizó la suya, sin duplicar" "$(sql t7 "select count(*)||' '||max(name)||' '||max(price)||' '||max(sku) from menu_items where barcode='097512831048'")" "1 Pelotas wilson (mía) 650.00 097512831048"
expect "conteos (la adoptó: 354, no 355)" "$(counts t7)" "$CARGADO"

echo "== T8 rollback limpio: deja solo lo que había"
fresh t8; imp t8 t8i >/dev/null; rb t8 t8
expect "conteos" "$(counts t8)" "${VACIO/menus=0 mode=none/menus=1 mode=basic}"

echo "== T9 rollback con una venta → aborta"
fresh t9; imp t9 t9i >/dev/null; sql t9 "insert into order_items (product_id) select id from menu_items where sku='1017'"
rb t9 t9; expect "no borró" "$(sql t9 "select count(*) from menu_items")" "354"

echo
[ $FAIL = 0 ] && echo "TODO OK" || echo "HAY FALLAS"
exit $FAIL
