#!/bin/bash
# Ensayo de la carga de comida de AZOTEA 046 contra un Postgres 15 local.
# Arrancar antes: initdb -D <dir> -U postgres --auth=trust
#   pg_ctl -D <dir> -o "-p 5433 -c listen_addresses=127.0.0.1 -c unix_socket_directories=''" -w start
set -u
B=/opt/homebrew/opt/postgresql@15/bin
S="$(cd "$(dirname "$0")" && pwd)"
R="$(cd "$S/.." && pwd)"
C="$(cd "$R/.." && pwd)"   # scripts de los cócteles
OUT="${TMPDIR:-/tmp}/ensayo_e7a63240_comida"
export PGHOST=127.0.0.1 PGPORT=${PGPORT:-5433} PGUSER=postgres PGCLIENTENCODING=UTF8
PSQL="$B/psql -X -q -v ON_ERROR_STOP=1"
mkdir -p "$OUT"

sql()  { $PSQL -d "$1" -Atc "$2"; }
run()  { $PSQL -d "$1" -f "$2" > "$OUT/$3.log" 2>&1; echo "   $(basename "$2") exit=$?"; grep -E "NOTICE|ERROR" "$OUT/$3.log" | grep -v skipping | cut -c1-300 | sed 's/^/   /'; }
# Como prod hoy: réplica + los 21 cócteles ya cargados.
prod() { $B/dropdb --if-exists "$1" 2>/dev/null; $B/createdb "$1"; $PSQL -d "$1" -f "$S/stub.sql" >/dev/null
         $PSQL -d "$1" -f "$C/IMPORT_COMPLETO.sql" > "$OUT/$1_cocteles.log" 2>&1 || echo "   ✗ cócteles fallaron"; }
imp()  { run "$1" "$R/IMPORT_COMIDA.sql" "$2"; }
rb()   { run "$1" "$R/99_rollback_comida.sql" "$2"; }
counts() { echo "   $(sql "$1" "select 'productos='||(select count(*) from menu_items)
  ||' cat='||(select count(*) from categories)
  ||' taxes='||(select count(*) from menu_item_taxes)
  ||' nm='||(select count(*) from menu_item_print_areas)
  ||' links='||(select count(*) from menu_item_links)
  ||' areas='||(select string_agg(code, ',' order by code) from print_areas)
  ||' brisa_coctel='||(select price||'/'||print_area_code from menu_items where name='Brisa Tropical')")"; }
report() { echo "   reporte: $(grep -c '✓' "$OUT/$1.log") ✓ / $(grep -c '✗' "$OUT/$1.log") ✗"; grep '✗' "$OUT/$1.log" | sed 's/^/     /'; }

echo "== S1 como prod (sin área de cocina): diagnóstico + carga"
prod s1; counts s1
run s1 "$R/00_diagnostico_comida.sql" s1_diag
imp s1 s1_import; counts s1; report s1_import
sql s1 "select '   '||c.name||'('||c.position||'): '||count(*) from menu_items mi join categories c on c.id=mi.category_id where not mi.is_beverage group by c.name,c.position order by c.position"
sql s1 "select '   '||mi.name||' \$'||mi.price||' área='||mi.print_area_code||' imp='||(select string_agg(t.name,'+' order by t.rate desc) from menu_item_taxes x join taxes t on t.id=x.tax_id where x.item_id=mi.id) from menu_items mi where mi.name in ('Brisa Tropical (Entrada)','T-Bone al Grill','Batata Frita')"
cat "$OUT/s1_import.log" | tail -16

echo "== S2 segunda corrida (no duplica)"
imp s1 s2_rerun; counts s1; report s2_rerun

echo "== S3 rollback (sin ventas) y re-import"
rb s1 s3_rb; counts s1; tail -3 "$OUT/s3_rb.log"
imp s1 s3_reimp; counts s1; report s3_reimp

echo "== S4 una venta y rollback aborta"
sql s1 "insert into order_items (product_id) select id from menu_items where name='Nachos'"
rb s1 s4_rb; counts s1

echo "== S5 área Cocina con impresora ya existente (code kitchen_hot, nombre COCINA)"
prod s5
sql s5 "insert into print_areas (business_id,name,code) values ('e7a63240-6492-4ed5-8057-319ab91a748c','COCINA','kitchen_hot');
        insert into print_area_printers select id, gen_random_uuid() from print_areas where code='kitchen_hot'"
imp s5 s5_import; counts s5; report s5_import

echo "== S6 choque: la lista trae 'Brisa Tropical' a secas → aborta sin tocar el cóctel"
prod s6
sed "s/'Brisa Tropical (Entrada)'/'Brisa Tropical'/" "$R/IMPORT_COMIDA.sql" > "$OUT/choque.sql"
run s6 "$OUT/choque.sql" s6_import; counts s6

echo "== S7 cocina apagada → ninguna área"
prod s7; sql s7 "update business_settings set kitchen_enabled=false"
imp s7 s7_import; counts s7; report s7_import

echo "== S8 producto previo en MAYÚSCULAS sin tilde en otra categoría de comida (se actualiza)"
prod s8
sql s8 "insert into menu_items (business_id, name, price) values ('e7a63240-6492-4ed5-8057-319ab91a748c','SALMON AL GRILL',800)"
imp s8 s8_import; counts s8; report s8_import
sql s8 "select '   '||name||' \$'||price from menu_items where name ilike 'salm%'"
