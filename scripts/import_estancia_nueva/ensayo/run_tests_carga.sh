#!/bin/bash
# Ensayo de IMPORT_CAFETERIA.sql / 99_rollback_cafeteria.sql contra un
# Postgres 15 DESECHABLE con stub_carga.sql. No toca ninguna base real.
#
#   PY=<python con openpyxl> bash ensayo/run_tests_carga.sh [carpeta_trabajo]
#
# Genera la carga sin precios y otra con precios de prueba en la carpeta de
# trabajo; los .sql del repo no se tocan. La salida de psql va a archivos:
# NUNCA por `head` (SIGPIPE mata psql antes del commit y parece un bug).
set -u
B=${PG_BIN:-/opt/homebrew/opt/postgresql@15/bin}
PORT=${PG_PORT:-55471}
PY=${PY:-python3}
S="$(cd "$(dirname "$0")" && pwd)"
R="$(cd "$S/.." && pwd)"
W=${1:-$(mktemp -d)}
BIZ=85924083-2e8e-4e64-8192-808ee24674ed
mkdir -p "$W/sin" "$W/con" "$W/proisa" "$W/log"

# --- Postgres propio -------------------------------------------------------
rm -rf "$W/pg"
$B/initdb -D "$W/pg" -U postgres --auth=trust >/dev/null || exit 1
$B/pg_ctl -D "$W/pg" -o "-p $PORT -c listen_addresses=127.0.0.1 -c unix_socket_directories=''" \
  -l "$W/pg.log" -w start >/dev/null || { cat "$W/pg.log"; exit 1; }
trap '$B/pg_ctl -D "$W/pg" stop -m fast >/dev/null 2>&1' EXIT
export PGHOST=127.0.0.1 PGPORT=$PORT PGUSER=postgres PGCLIENTENCODING=UTF8
PSQL="$B/psql -X -q -v ON_ERROR_STOP=1"

# --- Las dos cargas --------------------------------------------------------
( cd "$R" && $PY build_import_cafeteria.py --out "$W/sin" ) || exit 1
cat > "$W/precios.csv" <<'CSV'
codigo,precio
74601561,150
1045,"RD$ 1,250.00"
1219,300
049000006209,75
110000100331,0
CSV
( cd "$R" && $PY build_import_cafeteria.py --precios "$W/precios.csv" --out "$W/con" ) || exit 1
( cd "$R" && $PY build_import_cafeteria.py --proisa ProIsa_lista.csv --out "$W/proisa" ) || exit 1
echo "   precio con un código ajeno (insumo LECHE) → el generador se niega:"
printf 'codigo,precio\n110000100321,50\n' > "$W/malo.csv"
( cd "$R" && $PY build_import_cafeteria.py --precios "$W/malo.csv" --out "$W/malo" 2>&1 | sed 's/^/     /' )

FAIL=0
fresh()  { $B/dropdb --if-exists "$1" 2>/dev/null; $B/createdb "$1"; $PSQL -d "$1" -f "$S/stub_carga.sql" >/dev/null; }
sql()    { $PSQL -d "$1" -Atc "$2"; }
imp()    { $PSQL -d "$1" -f "$W/$2/IMPORT_CAFETERIA.sql" > "$W/log/$3.log" 2>&1; echo "   exit=$?"; grep -E "NOTICE|ERROR" "$W/log/$3.log" | sed 's/^/   /'; }
rb()     { $PSQL -d "$1" -f "$W/sin/99_rollback_cafeteria.sql" > "$W/log/$2.log" 2>&1; echo "   exit=$?"; grep -E "NOTICE|ERROR" "$W/log/$2.log" | sed 's/^/   /'; }
counts() { sql "$1" "select 'productos='||(select count(*) from menu_items)
  ||' activos='||(select count(*) from menu_items where is_active)
  ||' cat='||(select count(*) from categories)
  ||' insumos='||(select count(*) from inventory_items)
  ||' movs='||(select count(*) from inventory_movements)
  ||' stock='||coalesce((select sum(quantity) from inventory_stock),0)
  ||' taxes='||(select count(*) from menu_item_taxes)
  ||' nm='||(select count(*) from menu_item_print_areas)
  ||' legacy='||(select count(*) from menu_items where print_area_code is not null)
  ||' links='||(select count(*) from menu_item_links)
  ||' menus='||(select count(*) from menus)
  ||' mode='||(select inventory_mode from business_settings)
  ||' tracked='||(select count(*) from menu_items where is_inventory_tracked)
  ||' neg='||(select count(*) from menu_items where allow_negative_sale)"; }
expect() { # expect <label> <actual> <esperado>
  if [ "$2" = "$3" ]; then echo "   ok     $1"; else echo "   FALLA  $1"; echo "          obtenido: $2"; echo "          esperado: $3"; FAIL=1; fi; }
report() { local ok bad want=${3:-0}; ok=$(grep -c '✓' "$W/log/$1.log"); bad=$(grep -c '✗' "$W/log/$1.log")
  expect "reporte $1: $2 ✓ y $want ✗" "$ok/$bad" "$2/$want"; grep '✗' "$W/log/$1.log" | sed 's/^/          /'; }

VACIO='productos=0 activos=0 cat=0 insumos=0 movs=0 stock=0 taxes=0 nm=0 legacy=0 links=0 menus=0 mode=none tracked=0 neg=0'
CARGADO='productos=636 activos=0 cat=15 insumos=647 movs=0 stock=0 taxes=636 nm=636 legacy=636 links=636 menus=1 mode=basic tracked=635 neg=636'

echo "== S1 cafetería como en prod (vacía), carga SIN precios"
fresh s1; imp s1 sin s1
expect "conteos" "$(counts s1)" "$CARGADO"
report s1 16
expect "áreas: COCINA = Comida+Pizzas, BAR = lo demás" \
  "$(sql s1 "select string_agg(distinct c.name||'→'||a.code, ', ' order by c.name||'→'||a.code)
             from menu_items mi join categories c on c.id=mi.category_id
             join menu_item_print_areas x on x.menu_item_id=mi.id join print_areas a on a.id=x.print_area_id
             where a.code='cocina'")" "Comida→cocina, Pizzas→cocina"
expect "legacy = N:M en todos" \
  "$(sql s1 "select count(*) from menu_items mi join menu_item_print_areas x on x.menu_item_id=mi.id
             join print_areas a on a.id=x.print_area_id where a.code<>mi.print_area_code")" "0"
expect "oferta: inactiva, sin inventario" \
  "$(sql s1 "select is_active||' '||is_inventory_tracked||' '||(inventory_item_id is null) from menu_items where sku='1219'")" "false false true"
expect "Presidente Light: \$0, inclusive, barcode, insumo propio por código" \
  "$(sql s1 "select mi.price||' '||mi.tax_mode||' '||mi.barcode||' '||ii.sku||' '||ii.name||' '||ii.cost
             from menu_items mi join inventory_items ii on ii.id=mi.inventory_item_id where mi.sku='74601561'")" \
  "0.00 inclusive 74601561 74601561 CERVEZA PRESIDENTE LIGHT GRANDE 112.0000"
expect "código interno 1100001… sin barcode" \
  "$(sql s1 "select coalesce(barcode,'null') from menu_items where sku='110000100474'")" "null"
expect "insumo de cocina LECHE, sin producto de venta" \
  "$(sql s1 "select (select count(*) from inventory_items where sku='110000100321')||' '||(select count(*) from menu_items where sku='110000100321')")" "1 0"
expect "categorías en orden" \
  "$(sql s1 "select string_agg(name, '|' order by position) from categories")" \
  "Cervezas|Licores y vinos|Tragos y cócteles|Refrescos|Aguas|Jugos y lácteos|Deportivas y energizantes|Café|Pizzas|Comida|Snacks|Galletas y repostería|Chocolates y dulces|Helados y paletas|Servicios de bar"
expect "bebidas marcadas" \
  "$(sql s1 "select count(*) filter (where is_beverage)||'/'||count(*) from menu_items")" "291/636"

echo "== S2 segunda corrida igual (no duplica nada)"
imp s1 sin s2; expect "conteos" "$(counts s1)" "$CARGADO"; report s2 16

echo "== S3 llegan los precios: se re-corre CON precios sobre S1"
sql s1 "update menu_items set price=99, is_active=true where sku='110000100570'" # CASABE: precio puesto a mano en la app
imp s1 con s3
expect "conteos (3 activos de la lista + CASABE a mano)" "$(counts s1)" "${CARGADO/activos=0/activos=4}"
report s3 16
expect "precios y estado" \
  "$(sql s1 "select string_agg(sku||'='||price||(case when is_active then '+' else '-' end), ' ' order by sku)
             from menu_items where sku in ('74601561','1045','1219','049000006209','110000100331','110000100570')")" \
  "049000006209=75.00+ 1045=1250.00+ 110000100331=0.00- 110000100570=99.00+ 1219=300.00- 74601561=150.00+"

echo "== S4 Presidente apagado a mano en la app → re-correr NO lo reactiva"
sql s1 "update menu_items set is_active=false where sku='74601561'"
imp s1 con s4
expect "Presidente sigue apagado" "$(sql s1 "select is_active::text from menu_items where sku='74601561'")" "false"

echo "== S5 el dueño activa TODO en \$0 (ACTIVAR_todos_cafeteria.sql), como en prod"
fresh s5; imp s5 sin s5i >/dev/null
$PSQL -d s5 -f "$R/ACTIVAR_todos_cafeteria.sql" > "$W/log/s5_activar.log" 2>&1; echo "   exit=$?"
expect "activados / en cero" "$(grep -E '^ +[0-9]+ \| +[0-9]+' "$W/log/s5_activar.log" | tr -s ' ')" " 635 | 635"
expect "oferta sigue apagada" "$(sql s5 "select is_active::text from menu_items where sku='1219'")" "false"
echo "   re-correr SIN precios no aborta; la fila 2 avisa los 635 en \$0:"
imp s5 sin s5r; report s5r 15 1
expect "conteos" "$(counts s5)" "${CARGADO/activos=0/activos=635}"
echo "   llegan precios para 3: se ponen, siguen activos; quedan 632 en \$0:"
imp s5 con s5p; report s5p 15 1
expect "fila 2" "$(grep -o '632 de 635 activos' "$W/log/s5p.log")" "632 de 635 activos"
expect "precios" "$(sql s5 "select string_agg(sku||'='||price||(case when is_active then '+' else '-' end), ' ' order by sku)
             from menu_items where sku in ('74601561','1045','1219','049000006209')")" \
  "049000006209=75.00+ 1045=1250.00+ 1219=300.00- 74601561=150.00+"

echo "== S6 stock: una venta baja el stock a negativo; re-correr no lo toca"
sql s1 "insert into inventory_movements (business_id,warehouse_id,item_id,movement_type,quantity,reference_type)
        select '$BIZ', w.id, mi.inventory_item_id, 'sale', -2, 'order' from warehouses w, menu_items mi where mi.sku='049000006209'"
imp s1 con s6
expect "stock Coca 591 = -2" "$(sql s1 "select st.quantity from inventory_stock st join menu_items mi on mi.inventory_item_id=st.item_id where mi.sku='049000006209'")" "-2"
report s6 16

echo "== S7 rollback con movimiento de venta → aborta"
rb s1 s7; expect "no borró" "$(sql s1 "select count(*) from menu_items")" "636"

echo "== S8 rollback limpio sobre una carga recién hecha"
fresh s8; imp s8 sin s8i >/dev/null; rb s8 s8
expect "conteos (quedan el menú y el modo basic)" "$(counts s8)" "${VACIO/menus=0 mode=none/menus=1 mode=basic}"
expect "re-import después del rollback" "$(imp s8 sin s8r >/dev/null; counts s8)" "$CARGADO"

echo "== S9 rollback con un producto vendido → aborta"
fresh s9; imp s9 sin s9i >/dev/null
sql s9 "insert into order_items (product_id) select id from menu_items where sku='1045'"
rb s9 s9; expect "no borró" "$(sql s9 "select count(*) from menu_items")" "636"

echo "== S10 cocina encendida y SIN área cocina → aborta sin escribir"
fresh s10; sql s10 "delete from print_areas where code='cocina'"
imp s10 sin s10; expect "no escribió" "$(counts s10)" "$VACIO"

echo "== S11 cocina APAGADA → sin comanda (ni legacy ni N:M)"
fresh s11; sql s11 "update business_settings set kitchen_enabled=false"
imp s11 sin s11
expect "conteos" "$(counts s11)" "${CARGADO/nm=636 legacy=636/nm=0 legacy=0}"
report s11 16

echo "== S12 sin ITBIS → aborta"
fresh s12; sql s12 "delete from taxes"; imp s12 sin s12; expect "no escribió" "$(counts s12)" "$VACIO"

echo "== S13 dos menús activos → aborta"
fresh s13; sql s13 "insert into menus (id,business_id,name) values (gen_random_uuid(),'$BIZ','A'),(gen_random_uuid(),'$BIZ','B')"
imp s13 sin s13; expect "no escribió" "$(counts s13)" "${VACIO/menus=0/menus=2}"

echo "== S14 inventory_mode advanced se respeta"
fresh s14; sql s14 "update business_settings set inventory_mode='advanced'"
imp s14 sin s14; expect "modo" "$(sql s14 "select inventory_mode from business_settings")" "advanced"

echo "== S15 insumo previo con el código de la Coca (de otra carga) → se reusa, no se duplica"
fresh s15; sql s15 "insert into inventory_items (business_id,sku,name,cost) values ('$BIZ','049000006209','coca vieja',20)"
imp s15 sin s15
expect "insumos (647, uno reusado)" "$(sql s15 "select count(*) from inventory_items")" "647"
expect "Coca enlazada a la ficha vieja" "$(sql s15 "select ii.name from menu_items mi join inventory_items ii on ii.id=mi.inventory_item_id where mi.sku='049000006209'")" "coca vieja"

echo "== S16 precios de ProIsa sobre la carga sin precios (como en prod, SIN haber activado)"
fresh s16; imp s16 sin s16i >/dev/null; imp s16 proisa s16
expect "conteos" "$(counts s16)" "${CARGADO/activos=0/activos=624}"
report s16 16
expect "precios de muestra" \
  "$(sql s16 "select string_agg(sku||'='||price||(case when is_active then '+' else '-' end), ' ' order by sku)
             from menu_items where sku in ('01833225','049000006209','74601561','1081','1049','1143','1219','87120103','1050')")" \
  "01833225=250.00+ 049000006209=55.00+ 1049=2950.00+ 1050=0.00- 1081=145.00+ 1143=85.00+ 1219=400.00- 74601561=190.00+ 87120103=0.00-"
expect "paleta choco crema con su código de barras nuevo" \
  "$(sql s16 "select barcode from menu_items where sku='1143'")" "7468162802321"
expect "ITBIS incluido: Michelob 250 = 211.86 + 38.14" \
  "$(sql s16 "select round(price/1.18,2)||' + '||(price-round(price/1.18,2)) from menu_items where sku='01833225'")" "211.86 + 38.14"

echo "== S17 lo mismo pero HABIENDO corrido ACTIVAR_todos antes"
fresh s17; imp s17 sin s17i >/dev/null
$PSQL -d s17 -f "$R/ACTIVAR_todos_cafeteria.sql" >/dev/null 2>&1
imp s17 proisa s17
expect "conteos (635 activos: 624 con precio + 11 en \$0)" "$(counts s17)" "${CARGADO/activos=0/activos=635}"
report s17 15 1
expect "fila 2 avisa los 11" "$(grep -o '11 de 635 activos' "$W/log/s17.log")" "11 de 635 activos"

upd() { $PSQL -d "$1" -f "$W/proisa/UPDATE_precios_cafeteria.sql" > "$W/log/$2.log" 2>&1; echo "   exit=$?"; grep -E "ERROR" "$W/log/$2.log" | sed 's/^/   /'; }
# Sin la OFERTA (1219): la carga completa le pone precio (sigue apagada) y el UPDATE no la toca.
estado() { sql "$1" "select md5(string_agg(sku||'|'||price||'|'||is_active||'|'||coalesce(barcode,''), ',' order by sku)) from menu_items where sku <> '1219'"; }

echo "== S18 solo el UPDATE de precios sobre la carga sin precios (como en prod)"
fresh s18; imp s18 sin s18i >/dev/null; upd s18 s18
expect "resultado del UPDATE" "$(grep -E '^ +[0-9]+ \| +[0-9]+ \| +[0-9]+' "$W/log/s18.log" | tr -s ' ')" " 624 | 624 | 624"
expect "conteos" "$(counts s18)" "${CARGADO/activos=0/activos=624}"
expect "queda IDÉNTICO a la carga completa con precios (S16), salvo la oferta" "$(estado s18)" "$(estado s16)"
upd s18 s18b; expect "correrlo dos veces no cambia nada" "$(estado s18)" "$(estado s16)"
expect "la oferta sigue en \$0 y apagada" "$(sql s18 "select price||' '||is_active from menu_items where sku='1219'")" "0.00 false"
imp s18 proisa s18c; report s18c 16

echo "== S19 UPDATE habiendo corrido ACTIVAR_todos antes"
fresh s19; imp s19 sin s19i >/dev/null
$PSQL -d s19 -f "$R/ACTIVAR_todos_cafeteria.sql" >/dev/null 2>&1; upd s19 s19
expect "resultado del UPDATE" "$(grep -E '^ +[0-9]+ \| +[0-9]+ \| +[0-9]+' "$W/log/s19.log" | tr -s ' ')" " 624 | 624 | 624"
expect "635 activos, 11 en \$0" "$(sql s19 "select count(*) filter (where is_active)||' activos, '||count(*) filter (where is_active and price=0)||' en cero' from menu_items")" "635 activos, 11 en cero"

echo
[ $FAIL = 0 ] && echo "TODO OK" || echo "HAY FALLAS"
exit $FAIL
