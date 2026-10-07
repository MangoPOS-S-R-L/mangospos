#!/bin/bash
# Ensayo de 02_modificadores_foodtropolis.sql: réplica de prod + IMPORT_COMPLETO
# (como quedó en prod el 07-oct) + réplica de Foodtropolis.
set -u
B=/opt/homebrew/opt/postgresql@15/bin
S="$(cd "$(dirname "$0")" && pwd)"
R="$(cd "$S/.." && pwd)"
OUT="${TMPDIR:-/tmp}/ensayo_b0bd6f20"
BIZ=b0bd6f20-850c-4e9a-85ae-4cd619e1a0ee
export PGHOST=127.0.0.1 PGPORT=${PGPORT:-5449} PGUSER=postgres PGCLIENTENCODING=UTF8
PSQL="$B/psql -X -q -v ON_ERROR_STOP=1"
mkdir -p "$OUT"
sql()  { $PSQL -d "$1" -Atc "$2"; }
run()  { $PSQL -d "$1" -f "$2" > "$OUT/$3.log" 2>&1; local rc=$?; echo "   $(basename "$2") exit=$rc"; grep -E "NOTICE|ERROR" "$OUT/$3.log" | grep -v skipping | cut -c1-300 | sed 's/^/   /'; }
base() { $B/dropdb --if-exists "$1" 2>/dev/null; $B/createdb "$1"
         $PSQL -d "$1" -f "$S/stub.sql" >/dev/null; $PSQL -d "$1" -f "$S/replica.sql" >/dev/null
         $PSQL -d "$1" -f "$S/replica_foodtropolis.sql" >/dev/null
         $PSQL -d "$1" -f "$R/IMPORT_COMPLETO.sql" >/dev/null 2>&1; }
report() { echo "   reporte: $(grep -c '| ✓' "$OUT/$1.log") ✓ / $(grep -c '⚠' "$OUT/$1.log") ⚠ / $(grep -c '✗' "$OUT/$1.log") ✗"
           grep -E '⚠|✗' "$OUT/$1.log" | cut -c1-260 | sed 's/^/     /'; }
ver() { sql "$1" "select '   '||rpad(mi.name,26)||lpad(mi.price::text,8)||' act='||mi.is_active::text||' ← '||coalesce((select string_agg(g.name,', ' order by g.sort_order, g.name) from menu_item_groups y join modifier_groups g on g.id=y.group_id where y.menu_item_id=mi.id),'—')
  from menu_items mi where mi.business_id='$BIZ' and mi.name in ($2) order by mi.name"; }
counts() { echo "   $(sql "$1" "select 'grupos='||(select count(*) from modifier_groups where business_id='$BIZ')||' opciones='||(select count(*) from modifiers where business_id='$BIZ')||' ligas='||(select count(*) from menu_item_groups y join menu_items mi on mi.id=y.menu_item_id where mi.business_id='$BIZ')||' productos='||(select count(*) from menu_items where business_id='$BIZ')||' activos='||(select count(*) from menu_items where business_id='$BIZ' and is_active)")"; }

echo "== T1 prod tras el IMPORT + 02"; base t1; counts t1; run t1 "$R/02_modificadores_foodtropolis.sql" t1; report t1; counts t1
ver t1 "'BURRITO','TACOS','TOSTADAS','UNIDAD DE TACO','SODA CAN','REFRESCOS','JUGOS NATURALES','JARRITOS','ENCHILADA','FAJITAS','CANTARITO 1800','ARIZONA','REFRESCO','JUGO DE CEREZA'"
sql t1 "select '   Extras: '||string_agg(m.name||' '||m.price_delta, ', ' order by m.sort_order) from modifiers m join modifier_groups g on g.id=m.group_id where g.business_id='$BIZ' and g.name='Extras'"
sql t1 "select '   Sabor Soda: '||string_agg(m.name||' '||m.price_delta, ', ' order by m.sort_order) from modifiers m join modifier_groups g on g.id=m.group_id where g.business_id='$BIZ' and g.name='Sabor Soda'"
echo "== T2 re-corrida del 02"; run t1 "$R/02_modificadores_foodtropolis.sql" t2; report t2; counts t1
echo "== T3 re-correr el IMPORT después del 02 → aborta"; run t1 "$R/IMPORT_COMPLETO.sql" t3
echo "== T4 REFRESCO y una opción de Extras ya vendidos → se desactivan, no se borran"; base t4
sql t4 "insert into order_items (id, product_id) select gen_random_uuid(), id from menu_items where business_id='$BIZ' and name='REFRESCO';
  insert into order_item_modifiers (item_id, name, price, modifier_id)
  select oi.id, m.name, m.price_delta, m.id from order_items oi, modifiers m join modifier_groups g on g.id=m.group_id
  where g.business_id='$BIZ' and g.name='Extras' and m.name='Otro extra' limit 1"
run t4 "$R/02_modificadores_foodtropolis.sql" t4; report t4
sql t4 "select '   '||name||' activo='||is_active from menu_items where business_id='$BIZ' and name='REFRESCO'
  union all select '   opción '||m.name||' activa='||m.is_active from modifiers m join modifier_groups g on g.id=m.group_id where g.business_id='$BIZ' and g.name='Extras' and m.name='Otro extra'"
echo "== T5 SODA CAN no vale 0 en Foodtropolis → aborta"; base t5
sql t5 "update menu_items set price = 100 where business_id='800e4643-d35a-4795-b9c3-f70c71bc1187' and name='SODA CAN'"; run t5 "$R/02_modificadores_foodtropolis.sql" t5
