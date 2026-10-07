#!/bin/bash
# Ensayo de la carga de CAFETERIA MARICELA contra un Postgres 15 local.
# Arrancar antes: initdb -D <dir> -U postgres --auth=trust
#   pg_ctl -D <dir> -o "-p 5447 -c listen_addresses=127.0.0.1 -c unix_socket_directories=''" -w start
set -u
B=/opt/homebrew/opt/postgresql@15/bin
S="$(cd "$(dirname "$0")" && pwd)"
R="$(cd "$S/.." && pwd)"
OUT="${TMPDIR:-/tmp}/ensayo_1971ae49"
BIZ=1971ae49-935c-464a-9bfc-131d76a63be3
export PGHOST=127.0.0.1 PGPORT=${PGPORT:-5447} PGUSER=postgres PGCLIENTENCODING=UTF8
PSQL="$B/psql -X -q -v ON_ERROR_STOP=1"
mkdir -p "$OUT"

sql()  { $PSQL -d "$1" -Atc "$2"; }
run()  { $PSQL -d "$1" -f "$2" > "$OUT/$3.log" 2>&1; local rc=$?; echo "   $(basename "$2") exit=$rc"; grep -E "NOTICE|ERROR" "$OUT/$3.log" | grep -v skipping | cut -c1-300 | sed 's/^/   /'; }
# Negocio nuevo: solo ITBIS 18% y las áreas de sistema; sin menú ni catálogo.
base() { $B/dropdb --if-exists "$1" 2>/dev/null; $B/createdb "$1"; $PSQL -d "$1" -f "$S/stub.sql" >/dev/null
         sql "$1" "insert into businesses (id, business_name, business_type) values ('$BIZ','CAFETERIA MARICELA','Restaurante');
                   insert into business_settings (business_id) values ('$BIZ');
                   insert into taxes (business_id, name, rate) values ('$BIZ','ITBIS',18);
                   insert into print_areas (business_id, name, code) values
                     ('$BIZ','Caja','cashier'),('$BIZ','Fiscal','fiscal'),('$BIZ','Cierre de caja','cash_close');" >/dev/null; }
imp()  { run "$1" "$R/IMPORT_COMPLETO.sql" "$2"; }
rb()   { run "$1" "$R/99_rollback.sql" "$2"; }
counts() { echo "   $(sql "$1" "select 'productos='||(select count(*) from menu_items)
  ||' cat='||(select count(*) from categories)
  ||' taxes='||(select count(*) from menu_item_taxes)
  ||' nm='||(select count(*) from menu_item_print_areas)
  ||' links='||(select count(*) from menu_item_links)
  ||' menus='||(select count(*) from menus)
  ||' areas='||(select string_agg(code, ',' order by code) from print_areas)")"; }
report() { echo "   reporte: $(grep -c '✓' "$OUT/$1.log") ✓ / $(grep -c '✗' "$OUT/$1.log") ✗"; grep '✗' "$OUT/$1.log" | sed 's/^/     /'; }

echo "== S1 negocio vacío: diagnóstico + carga (crea Cocina y Bar sin impresora)"
base s1; counts s1
run s1 "$R/00_diagnostico.sql" s1_diag
imp s1 s1_import; counts s1; report s1_import
sql s1 "select '   '||c.name||'('||c.position||'): '||count(*)||' → '||string_agg(distinct mi.print_area_code, ',') from menu_items mi join categories c on c.id=mi.category_id group by c.name,c.position order by c.position"
sql s1 "select '   '||mi.sku||' '||mi.name||' \$'||mi.price||' costo='||mi.cost||' bebida='||mi.is_beverage||' área='||mi.print_area_code||' imp='||(select string_agg(t.name,'+') from menu_item_taxes x join taxes t on t.id=x.tax_id where x.item_id=mi.id) from menu_items mi where mi.sku in ('000098','000107','000046','000132','1','000138','000012')"
tail -18 "$OUT/s1_import.log"

echo "== S2 segunda corrida (no duplica)"
imp s1 s2_rerun; counts s1; report s2_rerun

echo "== S3 rollback (sin ventas) y re-import"
rb s1 s3_rb; counts s1; tail -3 "$OUT/s3_rb.log"
imp s1 s3_reimp; counts s1; report s3_reimp

echo "== S4 una venta y el rollback aborta"
sql s1 "insert into order_items (product_id) select id from menu_items where sku='000011'"
rb s1 s4_rb; counts s1

echo "== S5 catálogo previo: COCINA (kitchen_hot) y BARRA (barra) con impresora, menú, LEY,"
echo "   'Blody Marry' con LEY en 'Bebidas', 'Corona' vendida, categoría 'cerveZas'"
base s5
sql s5 "insert into taxes (business_id, name, rate) values ('$BIZ','LEY',10);
        insert into print_areas (business_id,name,code) values ('$BIZ','COCINA','kitchen_hot'),('$BIZ','BARRA','barra');
        insert into print_area_printers select id, gen_random_uuid() from print_areas where code in ('kitchen_hot','barra');
        insert into menus (id,business_id,name) values (gen_random_uuid(),'$BIZ','MENU PRINCIPAL');
        insert into categories (id,business_id,name,position) values (gen_random_uuid(),'$BIZ','Bebidas',0),(gen_random_uuid(),'$BIZ','cerveZas',5);
        insert into menu_items (business_id,category_id,name,price,print_area_code)
          select '$BIZ', c.id, n, 100, 'kitchen_hot' from categories c, (values ('Blody Marry'),('Corona')) v(n) where c.name='Bebidas';
        insert into menu_item_taxes select mi.id, t.id from menu_items mi, taxes t;
        insert into menu_item_print_areas (menu_item_id, print_area_id) select mi.id, a.id from menu_items mi, print_areas a where a.code='kitchen_hot';
        insert into menu_item_links (menu_id,item_id) select m.id, mi.id from menus m, menu_items mi;
        insert into order_items (product_id) select id from menu_items where name='Corona';" >/dev/null
imp s5 s5_import; counts s5; report s5_import
sql s5 "select '   '||mi.name||' sku='||mi.sku||' \$'||mi.price||' cat='||c.name||' área='||mi.print_area_code||' imp='||(select string_agg(t.name,'+') from menu_item_taxes x join taxes t on t.id=x.tax_id where x.item_id=mi.id)||' nm='||(select string_agg(a.code,',') from menu_item_print_areas x join print_areas a on a.id=x.print_area_id where x.menu_item_id=mi.id) from menu_items mi join categories c on c.id=mi.category_id where mi.sku in ('000107','000005')"
sql s5 "select '   categorías: '||string_agg(name||'('||position||')', ', ' order by position, name) from categories"

echo "== S6 choque: un producto 'Prueba' ya usa el sku 000037 → aborta"
base s6
sql s6 "insert into menu_items (business_id,name,price,sku) values ('$BIZ','Prueba',10,'000037')"
imp s6 s6_import; counts s6

echo "== S7 dos 'Nachos' en el catálogo → aborta"
base s7
sql s7 "insert into menu_items (business_id,name,price) values ('$BIZ','Nachos',10),('$BIZ','NACHOS',10)"
imp s7 s7_import; counts s7

echo "== S8 cocina apagada: sin áreas"
base s8
sql s8 "update business_settings set kitchen_enabled=false"
imp s8 s8_import; counts s8; report s8_import

echo "== S9 sin ITBIS → aborta"
base s9
sql s9 "delete from taxes"
imp s9 s9_import; counts s9

echo "== S10 dos menús activos → aborta"
base s10
sql s10 "insert into menus (id,business_id,name) values (gen_random_uuid(),'$BIZ','A'),(gen_random_uuid(),'$BIZ','B')"
imp s10 s10_import; counts s10

echo "== S11 Ley por orden encendida: carga, pero la fila 5 sale ✗"
base s11
sql s11 "update business_settings set service_fee_enabled=true"
imp s11 s11_import; report s11_import
