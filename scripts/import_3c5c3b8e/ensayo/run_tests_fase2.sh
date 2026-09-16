#!/bin/bash
# Ensayo de la FASE 2 de 007 BAR & SNACK contra un Postgres 15 local con stub.
# La salida de psql va a archivos: NUNCA por `head` (SIGPIPE mata psql antes
# del commit y parece un bug del SQL).
set -u
B=/opt/homebrew/opt/postgresql@15/bin
S="$(cd "$(dirname "$0")" && pwd)"
OUT="${TMPDIR:-/tmp}/ensayo_3c5c3b8e_fase2"
R="$(cd "$S/.." && pwd)"
BIZ=3c5c3b8e-28e6-45f0-8dc7-85e3efe8d30c
export PGHOST=127.0.0.1 PGPORT=${PGPORT:-5433} PGUSER=postgres PGCLIENTENCODING=UTF8
PSQL="$B/psql -X -q -v ON_ERROR_STOP=1"
mkdir -p "$OUT"

fresh()  { $B/dropdb --if-exists "$1" 2>/dev/null; $B/createdb "$1"; $PSQL -d "$1" -f "$S/stub.sql" >/dev/null; }
# Como está prod: cocina encendida, una sola área CAJA con impresora.
prod()   { fresh "$1"; sql "$1" "update business_settings set kitchen_enabled=true;
  insert into print_areas (business_id,name,code) values ('$BIZ','CAJA','caja');
  insert into print_area_printers select id, gen_random_uuid() from print_areas where code='caja'"; }
sql()    { $PSQL -d "$1" -Atc "$2"; }
run()    { $PSQL -d "$1" -f "$R/$2" > "$OUT/$3.log" 2>&1; echo "   $2 exit=$?"; grep -E "NOTICE|ERROR" "$OUT/$3.log" | grep -v skipping | cut -c1-400 | sed 's/^/   /'; }
f1()     { run "$1" IMPORT_COMPLETO.sql "$2"; }
f2()     { run "$1" IMPORT_FASE2.sql "$2"; }
rb2()    { run "$1" 99_rollback_fase2.sql "$2"; }
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

echo "== F1 como prod: fase 1, una venta, diagnóstico y fase 2"
prod f1
f1 f1 f1_fase1; counts f1
sql f1 "insert into order_items (product_id) select id from menu_items where sku='7622201776664';
  insert into inventory_movements (business_id,warehouse_id,item_id,movement_type,quantity,reference_type)
  select '$BIZ', w.id, mi.inventory_item_id, 'sale', -2, 'order' from warehouses w, menu_items mi where mi.sku='7622201776664'"
run f1 00_diagnostico_fase2.sql f1_diag
f2 f1 f1_fase2; counts f1; report f1_fase2
echo "   muestras:"
sql f1 "select '   '||mi.name||' | '||c.name||' | \$'||mi.price||' | costo='||coalesce(mi.cost::text,'null')||' | sku=['||mi.sku||'] | bc='||coalesce(mi.barcode,'—')
        ||' | área='||coalesce(mi.print_area_code,'—')||' | stock='||coalesce(st.quantity,0)||' | neg='||mi.allow_negative_sale||' | pos='||mi.position
        from menu_items mi join categories c on c.id=mi.category_id
        left join inventory_stock st on st.item_id=mi.inventory_item_id
        where mi.sku in ('74601561','004','   7622201776664','7622201776664','08780936','579','1019') order by mi.sku"
sql f1 "select '   categorías: '||string_agg(name||'('||position||')', ', ' order by position) from categories"
echo "   Cervezas en orden de caja (position, name):"
sql f1 "select '     '||mi.position||' '||mi.name from menu_items mi join categories c on c.id=mi.category_id
        where c.name='Cervezas' order by mi.position, mi.name limit 12"
sql f1 "select '   empates de posición dentro de una categoría: '||count(*) from (
          select category_id, position from menu_items group by 1,2 having count(*)>1) z"

echo "== F2 segunda corrida de la fase 2 (no duplica, no vuelve a sumar existencia)"
f2 f1 f2_rerun; counts f1; report f2_rerun

echo "== F3 rollback de la fase 2 y re-import"
rb2 f1 f3_rollback; counts f1
sql f1 "select '   categorías que quedan: '||count(*)||' · posición de TRIDENT MENTA: '||(select position from menu_items where sku='7622201776664') from categories"
f2 f1 f3_reimport; counts f1; report f3_reimport

echo "== F4 PRESIDENTE LIGHT creado a mano, con insumo propio y vendido → se actualiza, existencia sin tocar"
prod f4; f1 f4 f4_fase1 >/dev/null
sql f4 "insert into inventory_items (business_id,sku,name,cost) values ('$BIZ',null,'Presidente mío',100);
  insert into menu_items (business_id,category_id,name,price,barcode,inventory_item_id,is_inventory_tracked)
    select '$BIZ', null, 'Presidente Light (mío)', 200, '74601561', id, true from inventory_items where name='Presidente mío';
  insert into inventory_movements (business_id,warehouse_id,item_id,movement_type,quantity,reference_type)
    select '$BIZ', w.id, ii.id, 'sale', -5, 'order' from warehouses w, inventory_items ii where ii.name='Presidente mío';
  insert into order_items (product_id) select id from menu_items where name='Presidente Light (mío)'"
f2 f4 f4_fase2; counts f4; report f4_fase2
sql f4 "select '   '||mi.name||' | \$'||mi.price||' | sku='||mi.sku||' | '||c.name||' | stock='||coalesce(st.quantity,0)||' | links='||(select count(*) from menu_item_links l where l.item_id=mi.id)
        from menu_items mi join categories c on c.id=mi.category_id left join inventory_stock st on st.item_id=mi.inventory_item_id where mi.barcode='74601561'"

echo "== F5 un producto de la fase 1 con código de barras de la fase 2 → aborta sin escribir"
prod f5; f1 f5 f5_fase1 >/dev/null
sql f5 "update menu_items set barcode='74601561' where sku='7622201776664'"
counts f5; f2 f5 f5_fase2; counts f5

echo "== F6 fase 2 sin fase 1 → aborta"
prod f6; f2 f6 f6; counts f6

echo "== F7 rollback con una venta en un producto de la fase 2 → aborta"
prod f7; f1 f7 f7a >/dev/null; f2 f7 f7b >/dev/null
sql f7 "insert into order_items (product_id) select id from menu_items where sku='74601561'"
rb2 f7 f7_rb; counts f7

echo "== F8 tienda con cocina apagada → sin área"
fresh f8; f1 f8 f8_fase1 >/dev/null; f2 f8 f8_fase2; counts f8; report f8_fase2

echo "== F9 alguien movió un producto de la fase 1 de categoría → no se renumera"
prod f9; f1 f9 f9a >/dev/null
sql f9 "update menu_items set category_id=(select id from categories where name='Misceláneos'), position=77 where sku='7622201776664'"
f2 f9 f9_fase2; report f9_fase2
sql f9 "select '   TRIDENT MENTA sigue en pos '||position||' (esperado 77)' from menu_items where sku='7622201776664'"

echo "== F10 como la tabla del 16/09: CERVEZAS renombrada (pos 0), 3 de la fase 1 borrados, 1 movido, 1 creado a mano"
prod f10; f1 f10 f10a >/dev/null
sql f10 "update categories set name='CERVEZAS', position=0 where name='Cervezas';
  delete from menu_item_links where item_id in (select id from menu_items where sku in ('8414771852881','8000040002509','7804320303178'));
  delete from menu_item_taxes where item_id in (select id from menu_items where sku in ('8414771852881','8000040002509','7804320303178'));
  delete from menu_item_print_areas where menu_item_id in (select id from menu_items where sku in ('8414771852881','8000040002509','7804320303178'));
  delete from menu_items where sku in ('8414771852881','8000040002509','7804320303178');
  update menu_items set category_id=(select id from categories where name='CERVEZAS') where sku='8410161711257';
  insert into menu_items (business_id,category_id,name,price) select '$BIZ', id, 'PRESIDENTE JUMBO (a mano)', 250 from categories where name='CERVEZAS'"
run f10 00_diagnostico_fase2.sql f10_diag
grep -E '^ [0-9]\.' "$OUT/f10_diag.log" | grep -v '5. Categoría' | cut -c1-200 | sed 's/^/   /'
f2 f10 f10_fase2; counts f10; report f10_fase2
sql f10 "select '   categorías: '||count(*)||' · con nombre cervezas: '||count(*) filter (where lower(name)='cervezas') from categories"
sql f10 "select '   PRESIDENTE LIGHT 650 ML en: '||c.name from menu_items mi join categories c on c.id=mi.category_id where mi.sku='74601561'"
sed -n '/concepto/,$p' "$OUT/f10_fase2.log" | grep -E 'Fase 1' | sed 's/^/   /'
