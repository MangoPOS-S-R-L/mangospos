#!/bin/bash
# Ensayo de la carga de 007 BAR & SNACK contra un Postgres 15 local con stub.
# La salida de psql va a archivos: NUNCA por `head` (SIGPIPE mata psql antes
# del commit y parece un bug del SQL).
set -u
B=/opt/homebrew/opt/postgresql@15/bin
S="$(cd "$(dirname "$0")" && pwd)"
# Postgres 15 local por TCP (un socket bajo una ruta larga pasa de 103 bytes).
# Arrancar antes:  initdb -D <dir> -U postgres --auth=trust
#   pg_ctl -D <dir> -o "-p 5433 -c listen_addresses=127.0.0.1 -c unix_socket_directories=''" -w start
OUT="${TMPDIR:-/tmp}/ensayo_3c5c3b8e"
R="$(cd "$S/.." && pwd)"
BIZ=3c5c3b8e-28e6-45f0-8dc7-85e3efe8d30c
export PGHOST=127.0.0.1 PGPORT=5433 PGUSER=postgres PGCLIENTENCODING=UTF8
PSQL="$B/psql -X -q -v ON_ERROR_STOP=1"
mkdir -p "$OUT"

fresh()  { $B/dropdb --if-exists "$1" 2>/dev/null; $B/createdb "$1"; $PSQL -d "$1" -f "$S/stub.sql" >/dev/null; }
sql()    { $PSQL -d "$1" -Atc "$2"; }
imp()    { $PSQL -d "$1" -f "$R/IMPORT_COMPLETO.sql" > "$OUT/$2.log" 2>&1; echo "   exit=$?"; grep -E "NOTICE|ERROR" "$OUT/$2.log" | sed 's/^/   /'; }
rb()     { $PSQL -d "$1" -f "$R/99_rollback.sql" > "$OUT/$2.log" 2>&1; echo "   exit=$?"; grep -E "NOTICE|ERROR" "$OUT/$2.log" | sed 's/^/   /'; }
counts() { echo "   $(sql "$1" "select 'productos='||(select count(*) from menu_items)
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
  ||' tracked='||(select count(*) from menu_items where is_inventory_tracked)")"; }
report() { echo "   reporte: $(grep -c '✓' "$OUT/$1.log") ✓ / $(grep -c '✗' "$OUT/$1.log") ✗"; grep '✗' "$OUT/$1.log" | sed 's/^/     /'; }

echo "== S1 negocio vacío, tienda (cocina apagada)"
fresh s1; imp s1 s1_import; counts s1; report s1_import
echo "   muestras:"
sql s1 "select '   '||name||' | $'||price||' | '||tax_mode||' | activo='||is_active||' | sku='||sku||' | bc='||coalesce(barcode,'—')||' | neg='||allow_negative_sale
        from menu_items where sku in ('7622201776664','8888','76333113939','79033050072','8020') order by sku"
sql s1 "select '   '||mi.name||' ('||mi.sku||') → insumo '||ii.sku||' costo '||ii.cost||' stock '||coalesce(st.quantity,0)
        from menu_items mi join inventory_items ii on ii.id=mi.inventory_item_id
        left join inventory_stock st on st.item_id=ii.id
        where mi.sku in ('8712000030582','876063005951','876063005968','9002490204006') order by mi.sku"
sql s1 "select '   categorías: '||string_agg(name||'('||position||')', ', ' order by position) from categories"
sql s1 "select '   ITBIS: base '||round(30/1.18,2)||' + '||round(30-30/1.18,2)||' (Trident \$30)'"

echo "== S2 segunda corrida sobre S1 (no duplica, no vuelve a sumar existencia)"
imp s1 s2_rerun; counts s1; report s2_rerun

echo "== S3 rollback sobre S1, y re-import"
rb s1 s3_rollback; counts s1
imp s1 s3_reimport; counts s1; report s3_reimport

echo "== S4 cocina ENCENDIDA y sin áreas → aborta sin escribir"
fresh s4; sql s4 "update business_settings set kitchen_enabled=true"
imp s4 s4; counts s4

echo "== S5 cocina encendida + áreas bar y cocina → todo a bar"
fresh s5; sql s5 "update business_settings set kitchen_enabled=true;
  insert into print_areas (business_id,name,code) values ('$BIZ','Barra','bar'),('$BIZ','Cocina','cocina')"
imp s5 s5; counts s5; report s5
sql s5 "select '   áreas usadas: '||string_agg(distinct a.code, ',') from menu_item_print_areas x join print_areas a on a.id=x.print_area_id"

echo "== S6 cocina encendida + una sola área (juguera) → la usa"
fresh s6; sql s6 "update business_settings set kitchen_enabled=true;
  insert into print_areas (business_id,name,code) values ('$BIZ','Juguera','juguera')"
imp s6 s6; counts s6; report s6

echo "== S7 cocina encendida + dos áreas sin bar → aborta"
fresh s7; sql s7 "update business_settings set kitchen_enabled=true;
  insert into print_areas (business_id,name,code) values ('$BIZ','Juguera','juguera'),('$BIZ','Cocina','cocina')"
imp s7 s7; counts s7

echo "== S8 sin ITBIS → aborta"
fresh s8; sql s8 "delete from taxes"; imp s8 s8; counts s8

echo "== S9 service_fee_enabled → aborta"
fresh s9; sql s9 "update business_settings set service_fee_enabled=true"; imp s9 s9; counts s9

echo "== S10 dos menús activos → aborta"
fresh s10; sql s10 "insert into menus (id,business_id,name) values (gen_random_uuid(),'$BIZ','A'),(gen_random_uuid(),'$BIZ','B')"
imp s10 s10; counts s10

echo "== S11 sin bodega → aborta"
fresh s11; sql s11 "delete from warehouses"; imp s11 s11; counts s11

echo "== S12 bodega principal desactivada → aborta"
fresh s12; sql s12 "update warehouses set is_active=false"; imp s12 s12; counts s12

echo "== S13 catálogo previo: TRIDENT MENTA a \$25 con Ley, área bar, insumo propio y VENDIDO"
fresh s13
sql s13 "insert into taxes (business_id,name,rate) values ('$BIZ','Ley',10);
  insert into categories (id,business_id,name) values (gen_random_uuid(),'$BIZ','GOLOSINAS');
  insert into print_areas (business_id,name,code) values ('$BIZ','Barra','bar');
  insert into inventory_items (business_id,sku,name,cost) values ('$BIZ','7622201776664','Trident viejo',10);
  insert into menu_items (business_id,category_id,name,price,barcode,print_area_code)
    select '$BIZ',id,'Trident Menta (mío)',25,'7622201776664','bar' from categories where name='GOLOSINAS';
  insert into menu_item_taxes select mi.id,t.id from menu_items mi, taxes t where t.name='Ley';
  insert into menu_item_print_areas (menu_item_id,print_area_id) select mi.id,a.id from menu_items mi, print_areas a where a.code='bar';
  insert into order_items (product_id) select id from menu_items"
imp s13 s13; counts s13; report s13
sql s13 "select '   '||mi.name||' | $'||mi.price||' | '||c.name||' | impuestos='||(select string_agg(t.name,',') from menu_item_taxes x join taxes t on t.id=x.tax_id where x.item_id=mi.id)
         ||' | nm='||(select count(*) from menu_item_print_areas where menu_item_id=mi.id)||' | legacy='||coalesce(mi.print_area_code,'null')
         ||' | insumo='||ii.name from menu_items mi join categories c on c.id=mi.category_id join inventory_items ii on ii.id=mi.inventory_item_id where mi.sku='7622201776664'"
echo "   rollback con venta:"; rb s13 s13_rb; counts s13

echo "== S14 dos productos previos con el mismo código de barras → aborta"
fresh s14
sql s14 "insert into menu_items (business_id,name,price,barcode) values ('$BIZ','A',1,'7622201776664'),('$BIZ','B',1,'7622201776664')"
imp s14 s14; counts s14

echo "== S15 inventory_mode advanced se respeta"
fresh s15; sql s15 "update business_settings set inventory_mode='advanced'"; imp s15 s15; counts s15

echo "== S16 rollback con un movimiento de venta en un insumo → aborta"
fresh s16; imp s16 s16 >/dev/null
sql s16 "insert into inventory_movements (business_id,warehouse_id,item_id,movement_type,quantity,reference_type)
  select '$BIZ', w.id, ii.id, 'sale', -1, 'order' from warehouses w, inventory_items ii where ii.sku='8712000030582'"
rb s16 s16_rb; counts s16
