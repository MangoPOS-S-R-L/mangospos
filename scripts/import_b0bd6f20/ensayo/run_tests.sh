#!/bin/bash
# Ensayo de la carga de LA COCINA MEXICANA AUTENTICA (b0bd6f20) contra un
# Postgres 15 local, sobre la réplica del estado de prod (replica.sql, sacada
# del diagnóstico del 07-oct-2026).
# Arrancar antes: initdb -D <dir> -U postgres --auth=trust -E UTF8
#   pg_ctl -D <dir> -o "-p 5449 -c listen_addresses=127.0.0.1 -c unix_socket_directories=''" -w start
set -u
B=/opt/homebrew/opt/postgresql@15/bin
S="$(cd "$(dirname "$0")" && pwd)"
R="$(cd "$S/.." && pwd)"
OUT="${TMPDIR:-/tmp}/ensayo_b0bd6f20"
BIZ=b0bd6f20-850c-4e9a-85ae-4cd619e1a0ee
AGORA=6e18428f-fdd6-4c58-af0e-dae2403fbf1d
export PGHOST=127.0.0.1 PGPORT=${PGPORT:-5449} PGUSER=postgres PGCLIENTENCODING=UTF8
PSQL="$B/psql -X -q -v ON_ERROR_STOP=1"
mkdir -p "$OUT"

sql()  { $PSQL -d "$1" -Atc "$2"; }
run()  { $PSQL -d "$1" -f "$2" > "$OUT/$3.log" 2>&1; local rc=$?; echo "   $(basename "$2") exit=$rc"; grep -E "NOTICE|ERROR" "$OUT/$3.log" | grep -v skipping | cut -c1-420 | sed 's/^/   /'; }
base() { $B/dropdb --if-exists "$1" 2>/dev/null; $B/createdb "$1"
         $PSQL -d "$1" -f "$S/stub.sql" >/dev/null; $PSQL -d "$1" -f "$S/replica.sql" >/dev/null; }
imp()  { run "$1" "$R/IMPORT_COMPLETO.sql" "$2"; }
rb()   { run "$1" "$R/99_rollback.sql" "$2"; }
report() { echo "   reporte: $(grep -c '✓' "$OUT/$1.log") ✓ / $(grep -c '✗' "$OUT/$1.log") ✗"; grep '✗' "$OUT/$1.log" | cut -c1-260 | sed 's/^/     /'; }
counts() { echo "   $(sql "$1" "select 'productos='||(select count(*) from menu_items where business_id='$BIZ')
  ||' activos='||(select count(*) from menu_items where business_id='$BIZ' and is_active)
  ||' cat='||(select count(*) from categories where business_id='$BIZ')
  ||' taxes='||(select count(*) from menu_item_taxes)||' nm='||(select count(*) from menu_item_print_areas)
  ||' links='||(select count(*) from menu_item_links)||' grupos='||(select count(*) from modifier_groups)
  ||' opciones='||(select count(*) from modifiers)||' mig='||(select count(*) from menu_item_groups)
  ||' áreas='||coalesce((select string_agg(code,',' order by code) from print_areas where business_id='$BIZ'),'—')
  ||' impuestos='||(select string_agg(name||' '||rate,',' order by rate) from taxes where business_id='$BIZ')
  ||' presets='||(select delivery_fee_presets::text from business_settings where business_id='$BIZ')")"; }
ver() { sql "$1" "select '   '||rpad(mi.name,30)||lpad(mi.price::text,9)||' '||rpad(mi.tax_mode,9)||' act='||mi.is_active::text
  ||' cat='||coalesce(c.name,'—')||' área='||coalesce(mi.print_area_code,'—')
  ||' imp='||coalesce((select string_agg(t.name,'+' order by t.rate desc) from menu_item_taxes x join taxes t on t.id=x.tax_id where x.item_id=mi.id),'—')
  ||' grupos='||coalesce((select string_agg(g.name,', ') from menu_item_groups y join modifier_groups g on g.id=y.group_id where y.menu_item_id=mi.id),'—')
  from menu_items mi left join categories c on c.id=mi.category_id
  where mi.business_id='$BIZ' and mi.name in ($2) order by mi.name"; }

echo "== S0 diagnóstico sobre la réplica"; base s0; run s0 "$R/00_diagnostico.sql" s0
grep -E "6 Resumen" "$OUT/s0.log" | cut -c1-200 | sed 's/^/   /'

echo "== S1 carga sobre la réplica"; base s1; imp s1 s1; report s1; counts s1
ver s1 "'BURRITO','AGUA','TOSTADAS','ENCHILADA','ENCHILADA SUIZA','SODA CAN','REFRESCOS','JARRITOS','DELIVERY 100','Extra Queso','TACO DOBLE DECKERS','GANSITO MARINELA GRANDE','Carne Cocida Natural xlb','CANTARITO 1800','PIÑA COLADA','CORONA'"
sql s1 "select '   Ley copiada: '||name||' '||rate||' include_in_ecf='||include_in_ecf||' llevar='||apply_on_takeout||' mesa='||apply_on_zone from taxes where business_id='$BIZ' and rate=10"
sql s1 "select '   categorías: '||string_agg(name||'('||position||')', ', ' order by position) from categories where business_id='$BIZ'"

echo "== S2 re-corrida"; imp s1 s2; report s2; counts s1
echo "== S3 rollback"; rb s1 s3; counts s1
ver s1 "'BURRITO','SODA CAN','DELIVERY 100','Extra Queso','TOSTADAS'"
echo "== S4 re-import tras el rollback (la Ley ya existe)"; imp s1 s4; report s4

echo "== S5 una venta de un producto nuevo → el rollback aborta"
sql s1 "insert into order_items (product_id) select id from menu_items where name = 'CHURROS'"; rb s1 s5

echo "== S6 apareció un producto nuevo después del diagnóstico → aborta"; base s6
sql s6 "insert into menu_items (business_id, name, price, tax_mode) values ('$BIZ', 'PIZZA', 400, 'inclusive')"; imp s6 s6

echo "== S7 Ágora sin Ley → aborta"; base s7; sql s7 "delete from taxes where business_id='$AGORA' and rate=10"; imp s7 s7

echo "== S8 la Ley de Ágora trae un uuid en otra columna → aborta"; base s8
sql s8 "alter table taxes add column account_id uuid; update taxes set account_id = gen_random_uuid() where business_id='$AGORA' and rate=10"; imp s8 s8

echo "== S9 Ley por orden encendida → aborta"; base s9; sql s9 "update business_settings set service_fee_enabled = true"; imp s9 s9

echo "== S10 con impresoras vinculadas y la Ley creada a mano → solo Carne Cocida ✗"; base s10
sql s10 "insert into taxes (business_id, name, rate) values ('$BIZ','LEY',10);
  insert into print_areas (business_id, name, code) values ('$BIZ','COCINA','cocina'),('$BIZ','BARRA','barra');
  insert into print_area_printers select id, gen_random_uuid() from print_areas where business_id='$BIZ'"
imp s10 s10; report s10
