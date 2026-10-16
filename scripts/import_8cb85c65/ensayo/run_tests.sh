#!/bin/bash
# Ensayo de la carga del menú de EL RINCÓN DE ADDA contra un Postgres 15 local.
# Arrancar antes: initdb -D <dir> -U postgres --auth=trust
#   pg_ctl -D <dir> -o "-p 5451 -c listen_addresses=127.0.0.1 -c unix_socket_directories=''" -w start
set -u
B=/opt/homebrew/opt/postgresql@15/bin
S="$(cd "$(dirname "$0")" && pwd)"
R="$(cd "$S/.." && pwd)"
OUT="${TMPDIR:-/tmp}/ensayo_8cb85c65"
BIZ=8cb85c65-ae49-4384-a678-0d8a201a955e
export PGHOST=127.0.0.1 PGPORT=${PGPORT:-5451} PGUSER=postgres PGCLIENTENCODING=UTF8
PSQL="$B/psql -X -q -v ON_ERROR_STOP=1"
mkdir -p "$OUT"

sql()  { $PSQL -d "$1" -Atc "$2"; }
run()  { $PSQL -d "$1" -f "$2" > "$OUT/$3.log" 2>&1; local rc=$?; echo "   $(basename "$2") exit=$rc"; grep -E "NOTICE|ERROR" "$OUT/$3.log" | grep -v skipping | cut -c1-300 | sed 's/^/   /'; }
# Negocio nuevo: ITBIS 18% + LEY 10% y las áreas de sistema; sin menú ni catálogo.
base() { $B/dropdb --if-exists "$1" 2>/dev/null; $B/createdb "$1"; $PSQL -d "$1" -f "$S/stub.sql" >/dev/null
         sql "$1" "insert into businesses (id, business_name, business_type) values ('$BIZ','El Rincón de Adda','Restaurante');
                   insert into business_settings (business_id) values ('$BIZ');
                   insert into taxes (business_id, name, rate) values ('$BIZ','ITBIS',18),('$BIZ','LEY',10);
                   insert into print_areas (business_id, name, code) values
                     ('$BIZ','Caja','cashier'),('$BIZ','Fiscal','fiscal'),('$BIZ','Cierre de caja','cash_close');" >/dev/null; }
imp()  { run "$1" "$R/IMPORT_COMPLETO.sql" "$2"; }
rb()   { run "$1" "$R/99_rollback.sql" "$2"; }
counts() { echo "   $(sql "$1" "select 'productos='||(select count(*) from menu_items)
  ||' activos='||(select count(*) from menu_items where is_active)
  ||' cat='||(select count(*) from categories)
  ||' taxes='||(select count(*) from menu_item_taxes)
  ||' nm='||(select count(*) from menu_item_print_areas)
  ||' links='||(select count(*) from menu_item_links)
  ||' grupos='||(select count(*) from modifier_groups)
  ||' opciones='||(select count(*) from modifiers where is_active)||'/'||(select count(*) from modifiers)
  ||' mig='||(select count(*) from menu_item_groups)
  ||' menus='||(select count(*) from menus)
  ||' areas='||(select string_agg(code, ',' order by code) from print_areas)")"; }
report() { echo "   reporte: $(grep -c '✓' "$OUT/$1.log") ✓ / $(grep -c '✗' "$OUT/$1.log") ✗"; grep '✗' "$OUT/$1.log" | sed 's/^/     /'; }

echo "== S1 negocio vacío: diagnóstico + carga (crea Cocina y Bar sin impresora)"
base s1; counts s1
run s1 "$R/00_diagnostico.sql" s1_diag
imp s1 s1_import; counts s1; report s1_import
sql s1 "select '   '||c.name||'('||c.position||'): '||count(*)||' → '||string_agg(distinct mi.print_area_code, ',')||' bebida='||bool_and(mi.is_beverage) from menu_items mi join categories c on c.id=mi.category_id group by c.name,c.position order by c.position"
sql s1 "select '   '||mi.name||' \$'||mi.price||' imp='||(select string_agg(t.name,'+' order by t.name) from menu_item_taxes x join taxes t on t.id=x.tax_id where x.item_id=mi.id)
        ||' grupos='||coalesce((select string_agg(g.name||'#'||y.position, ', ' order by y.position) from menu_item_groups y join modifier_groups g on g.id=y.group_id where y.menu_item_id=mi.id),'—')
        from menu_items mi where mi.name in ('Pasta Marinara','Piña Colada','Ribeye Prime Importado','Camarones','Papas','19 Crimes','Focaccia','Agua')"
sql s1 "select '   '||g.name||' min='||g.min_select||' max='||g.max_select||' '||g.display_type||' req='||g.is_required||': '||string_agg(m.name||'+'||m.price_delta, ', ' order by m.sort_order) from modifier_groups g join modifiers m on m.group_id=g.id group by g.id order by g.name"
tail -23 "$OUT/s1_import.log"

echo "== S2 segunda corrida (no duplica)"
imp s1 s2_rerun; counts s1; report s2_rerun

echo "== S3 rollback (sin ventas) y re-import"
rb s1 s3_rb; counts s1; tail -3 "$OUT/s3_rb.log"
imp s1 s3_reimp; counts s1; report s3_reimp

echo "== S4 una venta y el rollback aborta"
sql s1 "insert into order_items (product_id) select id from menu_items where name='Tostones'"
rb s1 s4_rb; counts s1

echo "== S5 catálogo previo: COCINA (kitchen_hot) y BARRA (barra) con impresora, menú,"
echo "   '19 Crimemenes' con solo ITBIS y vendido, pizza 'Cuatro Quesos' (no debe caer en la pasta),"
echo "   'Término de la carne' mal armado con opción 'Azul', Pollo a la Plancha enlazado a él,"
echo "   'Pizza Pepperoni' en otra categoría con un grupo ajeno 'Extras pizza'"
base s5
sql s5 "insert into print_areas (business_id,name,code) values ('$BIZ','COCINA','kitchen_hot'),('$BIZ','BARRA','barra');
        insert into print_area_printers select id, gen_random_uuid() from print_areas where code in ('kitchen_hot','barra');
        insert into menus (id,business_id,name) values (gen_random_uuid(),'$BIZ','MENU PRINCIPAL');
        insert into categories (id,business_id,name,position) values (gen_random_uuid(),'$BIZ','Pizzas',5),(gen_random_uuid(),'$BIZ','VARIOS',50);
        insert into menu_items (business_id,category_id,name,price,tax_mode,print_area_code)
          select '$BIZ', c.id, v.n, v.p, 'exclusive', v.a
          from (values ('19 Crimemenes',2300,'VARIOS','barra'),('Cuatro Quesos',700,'Pizzas','kitchen_hot'),
                       ('Pollo a la plancha',550,'VARIOS','kitchen_hot'),('PIZZA PEPPERONI',600,'VARIOS','barra'),
                       ('Hamburguesa',400,'VARIOS','kitchen_hot')) v(n,p,c,a)
          join categories c on c.name = v.c;
        insert into menu_item_taxes select mi.id, t.id from menu_items mi, taxes t where t.name='ITBIS';
        insert into menu_item_print_areas select mi.id, a.id from menu_items mi join print_areas a on a.code=mi.print_area_code;
        insert into menu_item_links (menu_id,item_id) select m.id, mi.id from menus m, menu_items mi;
        insert into modifier_groups (id,business_id,name,min_select,max_select,display_type) values
          (gen_random_uuid(),'$BIZ','TERMINO DE LA CARNE',0,0,'multiple'),(gen_random_uuid(),'$BIZ','Extras pizza',0,0,'multiple');
        insert into modifiers (id,business_id,group_id,name,price_delta,sort_order)
          select gen_random_uuid(),'$BIZ',g.id,v.n,v.d,v.o from modifier_groups g,
          (values ('TERMINO DE LA CARNE','Azul',0,1),('TERMINO DE LA CARNE','Termino medio',25,2),('Extras pizza','Queso extra',75,1)) v(g,n,d,o)
          where g.name=v.g;
        insert into menu_item_groups (menu_item_id,group_id) select mi.id,g.id from menu_items mi, modifier_groups g
          where (mi.name='Pollo a la plancha' and g.name='TERMINO DE LA CARNE') or (mi.name='PIZZA PEPPERONI' and g.name='Extras pizza');
        insert into order_items (product_id) select id from menu_items where name='19 Crimemenes';" >/dev/null
counts s5
run s5 "$R/00_diagnostico.sql" s5_diag; grep -E "Ya existe|Grupo|Área" "$OUT/s5_diag.log" | sed 's/^/     /'
imp s5 s5_import; counts s5; report s5_import
sql s5 "select '   '||mi.name||' \$'||mi.price||' '||mi.tax_mode||' activo='||mi.is_active||' cat='||c.name||' área='||mi.print_area_code
        ||' imp='||(select string_agg(t.name,'+' order by t.name) from menu_item_taxes x join taxes t on t.id=x.tax_id where x.item_id=mi.id)
        ||' grupos='||coalesce((select string_agg(g.name, ', ') from menu_item_groups y join modifier_groups g on g.id=y.group_id where y.menu_item_id=mi.id),'—')
        from menu_items mi join categories c on c.id=mi.category_id
        where mi.name in ('19 Crimes','Cuatro Quesos','Pollo a la plancha','PIZZA PEPPERONI','Hamburguesa','Pasta Cuatro Quesos','Pizza Cuatro Quesos') order by mi.name"
sql s5 "select '   '||g.name||' min='||g.min_select||' max='||g.max_select||' '||g.display_type||': '||string_agg(m.name||'+'||m.price_delta||(case when m.is_active then '' else '(apagada)' end), ', ' order by m.sort_order) from modifier_groups g join modifiers m on m.group_id=g.id where g.name ilike 'term%' group by g.id"
sql s5 "select '   categorías: '||string_agg(name||'('||position||')', ', ' order by position) from categories"

echo "== S6 sin Ley: aborta"
base s6; sql s6 "delete from taxes where name='LEY'"
imp s6 s6_import; counts s6

echo "== S7 Ley con is_service_fee: aborta"
base s7; sql s7 "update taxes set is_service_fee=true where name='LEY'"
imp s7 s7_import; counts s7

echo "== S8 Ley por orden encendida: aborta"
base s8; sql s8 "update business_settings set service_fee_enabled=true"
imp s8 s8_import; counts s8

echo "== S9 dos menús: aborta"
base s9; sql s9 "insert into menus (id,business_id,name) values (gen_random_uuid(),'$BIZ','A'),(gen_random_uuid(),'$BIZ','B')"
imp s9 s9_import; counts s9

echo "== S10 dos 'Agua' en el catálogo: aborta"
base s10; sql s10 "insert into menu_items (business_id,name,price) values ('$BIZ','Agua',25),('$BIZ','AGUA',30)"
imp s10 s10_import; counts s10

echo "== S11 cocina apagada: sin áreas"
base s11; sql s11 "update business_settings set kitchen_enabled=false"
imp s11 s11_import; counts s11; report s11_import

echo "== S12 menu_item_groups sin columna position"
base s12; sql s12 "alter table menu_item_groups drop column position"
imp s12 s12_import; counts s12; report s12_import

echo "== S13 dos ITBIS: aborta"
base s13; sql s13 "insert into taxes (business_id,name,rate) values ('$BIZ','ITBIS 2',18)"
imp s13 s13_import; counts s13

echo "== S14 RÉPLICA DE PROD (diagnóstico del 16-oct): COCINA y BAR con 2 impresoras, LEY 10.0,"
echo "   MENU PRINCIPAL, BEBIDAS pos 0 con AGUA DASANI (vendida, ITBIS+LEY) y JUGO DE LIMON (solo ITBIS)"
base s14
sql s14 "update business_settings set inventory_mode='basic';
         update taxes set rate=10.0 where name='LEY';
         insert into print_areas (business_id,name,code) values ('$BIZ','BAR','bar'),('$BIZ','COCINA','cocina');
         insert into print_area_printers select id, gen_random_uuid() from print_areas where code in ('bar','cocina');
         insert into print_area_printers select id, gen_random_uuid() from print_areas;
         insert into menus (id,business_id,name) values (gen_random_uuid(),'$BIZ','MENU PRINCIPAL');
         insert into categories (id,business_id,name,position) values (gen_random_uuid(),'$BIZ','BEBIDAS',0);
         insert into menu_items (business_id,category_id,name,price,tax_mode,print_area_code,is_beverage)
           select '$BIZ', c.id, v.n, v.p, 'inclusive', 'bar', true
           from (values ('AGUA DASANI',50),('JUGO DE LIMON',150)) v(n,p), categories c;
         insert into menu_item_taxes select mi.id, t.id from menu_items mi, taxes t
           where t.name='ITBIS' or mi.name='AGUA DASANI';
         insert into menu_item_print_areas select mi.id, a.id from menu_items mi join print_areas a on a.code='bar';
         insert into menu_item_links (menu_id,item_id) select m.id, mi.id from menus m, menu_items mi;
         insert into order_items (product_id) select id from menu_items where name='AGUA DASANI';" >/dev/null
counts s14
run s14 "$R/00_diagnostico.sql" s14_diag; grep -E "Ya existe|Impuesto" "$OUT/s14_diag.log" | sed 's/^/     /'
imp s14 s14_import; counts s14; report s14_import
sql s14 "select '   '||mi.name||' \$'||mi.price||' cat='||c.name||'('||c.position||') pos='||mi.position||' área='||mi.print_area_code
         ||' imp='||(select string_agg(t.name,'+' order by t.name) from menu_item_taxes x join taxes t on t.id=x.tax_id where x.item_id=mi.id)
         ||' ventas='||(select count(*) from order_items oi where oi.product_id=mi.id)
         from menu_items mi join categories c on c.id=mi.category_id where c.name='BEBIDAS' order by mi.position"
imp s14 s14_rerun; counts s14; report s14_rerun
rb s14 s14_rb; counts s14
sql s14 "select '   queda: '||string_agg(mi.name||' ('||c.name||')', ', ') from menu_items mi join categories c on c.id=mi.category_id"
