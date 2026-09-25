#!/bin/bash
set -u
B=/opt/homebrew/opt/postgresql@15/bin
S="$(cd "$(dirname "$0")" && pwd)"; R="$(cd "$S/.." && pwd)"
OUT="${TMPDIR:-/tmp}/ensayo_d16497fa"; mkdir -p "$OUT"
export PGHOST=127.0.0.1 PGPORT=${PGPORT:-5433} PGUSER=postgres PGCLIENTENCODING=UTF8
PSQL="$B/psql -X -q -v ON_ERROR_STOP=1"
fresh() { $B/dropdb --if-exists "$1" 2>/dev/null; $B/createdb "$1"; $PSQL -d "$1" -f "$S/stub.sql" >/dev/null; }
sql()   { $PSQL -d "$1" -Atc "$2"; }
run()   { $PSQL -d "$1" -f "$2" > "$OUT/$3.log" 2>&1; echo "   $(basename "$2") exit=$?"; grep -E "NOTICE|ERROR" "$OUT/$3.log" | grep -v skipping | cut -c1-300 | sed 's/^/   /'; }
imp()   { run "$1" "$R/IMPORT_COMPLETO.sql" "$2"; }
cat_()  { sql "$1" "select '   '||rpad(c.name,13)||rpad(mi.name,24)||lpad(mi.price::text,8)||' activo='||mi.is_active
  ||' imp='||coalesce((select string_agg(t.name,'+' order by t.rate desc) from menu_item_taxes x join taxes t on t.id=x.tax_id where x.item_id=mi.id),'—')
  ||' área='||coalesce(mi.print_area_code,'—')||' acomp='||(select count(*) from menu_item_groups y where y.menu_item_id=mi.id)
  ||' ventas='||(select count(*) from order_items o where o.product_id=mi.id)
  from menu_items mi join categories c on c.id=mi.category_id order by c.position, mi.position, mi.name"; }
report(){ echo "   reporte: $(grep -c '✓' "$OUT/$1.log") ✓ / $(grep -c '✗' "$OUT/$1.log") ✗"; grep '✗' "$OUT/$1.log" | sed 's/^/     /'; }

echo "== S0 diagnóstico sobre la réplica"; fresh s1; run s1 "$R/00_diagnostico.sql" s0; grep -E "Nombre parecido|Catálogo" "$OUT/s0.log"
echo "== S1 carga"; imp s1 s1; report s1; tail -17 "$OUT/s1.log"; cat_ s1
echo "== S2 re-run"; imp s1 s2; report s2; sql s1 "select '   prod='||count(*) from menu_items"
echo "== S3 rollback"; run s1 "$R/99_rollback.sql" s3; cat_ s1; sql s1 "select '   grupos='||(select count(*) from modifier_groups)||' mods='||(select count(*) from modifiers)"
echo "== S4 re-import"; imp s1 s4; report s4
echo "== S5 venta de un nuevo → rollback aborta"; sql s1 "insert into order_items (product_id) select id from menu_items where name='Pollo Frito 8 Piezas'"; run s1 "$R/99_rollback.sql" s5
echo "== S6 Pechurina y Pechurrina 3 Piezas a la vez → aborta"; fresh s6
sql s6 "insert into menu_items (business_id,name,price) values ('d16497fa-4853-41e3-8566-4d0565511f37','Pechurrina 3 piezas',200)"; imp s6 s6
