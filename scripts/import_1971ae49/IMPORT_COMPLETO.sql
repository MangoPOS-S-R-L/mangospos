-- ============================================================================
-- CAFETERIA MARICELA — CARGA DEL CATÁLOGO
-- Business 1971ae49-935c-464a-9bfc-131d76a63be3
--
-- Fuente: "Reporte General de Inventarios" del sistema anterior
-- (ReportInventarios_Todos.pdf, 06/10/2026 2:31 p. m.), 111 productos.
-- Este archivo lo arma build_import_1971ae49.py. No lo edites a mano.
-- ============================================================================
--
-- QUÉ CARGA
--   111 productos en 17 categorías: 73 de comida (van a la COCINA) y 38
--   bebidas (van al BAR). El código del sistema viejo queda como SKU y el
--   costo en menu_items.cost. Sin insumos ni existencias.
--
-- PRECIOS (ITBIS 18% INCLUIDO, sin Ley 10%)
--   tax_mode = 'inclusive': lo que dice la lista es lo que paga el cliente.
--   * 22 precios del PDF eran el NETO de un precio redondo (254.24 × 1.18 =
--     300.00): el sistema viejo les sumaba el ITBIS por fuera. Se cargan al
--     precio final (Aperol 300, Corona 225, Presidente 180...).
--   * QUESILLO 169.92 → 200 y DULCE DE PIÑA CON LECHE 127.81 → 150.
--   * CERDO ASADO + CASABE va en 533.33 como en el PDF: falta que el dueño
--     confirme el precio.
--
-- NOMBRES
--   9 errores de tipeo se corrigen (BLODY MARRY → BLOODY MARY, MUSCOW MULE →
--   MOSCOW MULE, RUN PUNCH → RUM PUNCH, CASAAMIGOS → CASAMIGOS...).
--
-- CÓMO CORRERLO
--   Corre antes 00_diagnostico.sql. Después pega este entero en el SQL
--   Editor de Supabase y dale Run. La tabla que sale al final es el reporte:
--   todas las filas deben decir ✓.
--
-- TODO O NADA
--   Va en UNA transacción. Primero comprueba todo (negocio, ITBIS, menú,
--   áreas, choques con el catálogo actual) y después, antes del commit,
--   verifica los 111 uno por uno. Si algo no cuadra lanza excepción y
--   REVIERTE ENTERO.
--
-- SE PUEDE RE-CORRER
--   Empareja por SKU (el código del PDF) o por nombre, sin mayúsculas ni
--   tildes. El que ya existe se ACTUALIZA (precio, costo, categoría,
--   impuestos, área) y el que falta se INSERTA. Para corregir un precio:
--   cámbialo en catalogo.py, corre build_import_1971ae49.py y vuelve a
--   correr este archivo.
--
-- IMPUESTOS
--   menu_item_taxes es la ÚNICA fuente del impuesto por producto: sin fila ahí
--   la factura sale con ITBIS 0.00. Cada producto queda con el ITBIS 18% y
--   nada más (si tenía la Ley u otro impuesto vinculado, se le quita).
--
-- ÁREAS DE COMANDA (cómo las escoge)
--   * cocina apagada en Ajustes (kitchen_enabled = false): ninguna;
--   * COCINA: un área activa con code cocina / kitchen / kitchen_hot / comida
--     (o que se llame así); si no, reactiva una apagada, o CREA "Cocina"
--     (code `cocina`) SIN impresora;
--   * BAR: un área activa con code bar / barra (o que se llame así); si no,
--     reactiva una apagada, o CREA "Bar" (code `bar`) SIN impresora;
--   * nunca usa las áreas de sistema (cashier, fiscal, cash_close).
--   Un área creada aquí sale ✗ en el reporte hasta que le vincules la
--   impresora en la app.
--   Escribe LOS DOS mecanismos: menu_item_print_areas (N:M) y el legacy
--   menu_items.print_area_code, que fn_add_item_from_menu copia al
--   order_item. Sin el legacy, un bache de red manda la comanda a otro lado.
--
-- MENÚ
--   La caja filtra los productos por menú (menu_item_links). Se reusa el menú
--   activo que hay; si no hay ninguno se crea "Menú Principal"; si hay más de
--   uno, ABORTA.
-- ============================================================================

begin;

-- Nombre normalizado: sin mayúsculas, sin tildes, sin espacios repetidos.
create or replace function pg_temp.norm(t text) returns text
language sql immutable as $f$
  select translate(lower(regexp_replace(btrim(t), '\s+', ' ', 'g')),
                   'áéíóúüñÁÉÍÓÚÜÑ', 'aeiouunaeiouun')
$f$;

-- ---------------------------------------------------------------------------
-- 0) La lista. Tablas temporales de la sesión: el reporte de abajo las usa.
-- ---------------------------------------------------------------------------

drop table if exists _mc_categorias;
create temp table _mc_categorias (
  name     text not null,
  posicion int  not null,
  area     text not null check (area in ('cocina', 'bar'))
);

insert into _mc_categorias (name, posicion, area) values
  ('PICADERAS', 10, 'cocina'),
  ('BANDEJAS', 11, 'cocina'),
  ('HAMBURGUESAS', 12, 'cocina'),
  ('SANDWICHES Y TOSTADAS', 13, 'cocina'),
  ('MEXICANO', 14, 'cocina'),
  ('MOFONGOS', 15, 'cocina'),
  ('POLLO', 16, 'cocina'),
  ('CARNES', 17, 'cocina'),
  ('MARISCOS Y PESCADOS', 18, 'cocina'),
  ('COMIDA CRIOLLA', 19, 'cocina'),
  ('PASTAS', 20, 'cocina'),
  ('SOPAS Y ENSALADAS', 21, 'cocina'),
  ('POSTRES', 22, 'cocina'),
  ('COCTELES', 30, 'bar'),
  ('CERVEZAS', 31, 'bar'),
  ('LICORES Y VINOS', 32, 'bar'),
  ('BEBIDAS', 33, 'bar')
;

drop table if exists _mc_productos;
create temp table _mc_productos (
  code        text not null,
  name        text not null,
  nombre_pdf  text not null,
  categoria   text not null,
  price       numeric(12,2) not null,
  cost        numeric not null,
  posicion    int not null
);

insert into _mc_productos (code, name, nombre_pdf, categoria, price, cost, posicion) values
  ('000037', 'ALITAS DE POLLO', 'ALITAS DE POLLO', 'PICADERAS', 395.00, 200.00, 1),
  ('000008', 'AROS DE CEBOLLA', 'AROS DE CEBOLLA', 'PICADERAS', 195.00, 15.00, 2),
  ('000009', 'BROCHETAS MIXTAS', 'BROCHETAS MIXTAS', 'PICADERAS', 330.00, 15.00, 3),
  ('000007', 'CROQUETAS DE POLLO', 'CROQUETAS DE POLLO', 'PICADERAS', 220.00, 15.00, 4),
  ('000006', 'MOZZARELLA STICKS', 'MOZZARELLA STICKS', 'PICADERAS', 350.00, 15.00, 5),
  ('000011', 'NACHOS', 'NACHOS', 'PICADERAS', 325.00, 15.00, 6),
  ('0000010', 'PAPAS SAZONADAS', 'PAPAS SAZONADAS', 'PICADERAS', 250.00, 15.00, 7),
  ('000076', 'PATACON', 'PATACON', 'PICADERAS', 370.00, 185.00, 8),
  ('000050', 'SALCHIPAPA', 'SALCHIPAPA', 'PICADERAS', 275.00, 100.00, 9),
  ('000020', 'BANDEJA DE 4 PERSONAS MIXTAS', 'BANDEJA DE 4 PERSONAS MIXTAS', 'BANDEJAS', 1500.00, 700.00, 1),
  ('000109', 'BANDEJA PARA 2 PERSONAS', 'BANDEJA PARA 2 PERSONAS', 'BANDEJAS', 850.00, 300.00, 2),
  ('000021', 'BANDEJA PARA 6 PERSONAS MIXTAS', 'BANDEJA PARA 6 PERSONAS MIXTAS', 'BANDEJAS', 2000.00, 950.00, 3),
  ('000022', 'BANDEJA PARA 8 PERSONAS MIXTAS', 'BANDEJA PARA 8 PERSONAS MIXTAS', 'BANDEJAS', 2800.00, 2650.00, 4),
  ('000063', 'BACON CHEESE BURGER', 'BACON CHESSE BURGER', 'HAMBURGUESAS', 400.00, 150.00, 1),
  ('000059', 'BURGER CLASICA ANGUS', 'BURGER CLASICA ANGUS', 'HAMBURGUESAS', 375.00, 150.00, 2),
  ('000060', 'BURGER CLASICA POLLO', 'BURGER CLASICA POLLO', 'HAMBURGUESAS', 300.00, 120.00, 3),
  ('000061', 'DOMINICANA BURGER', 'DOMINICANA BURGER', 'HAMBURGUESAS', 485.00, 120.00, 4),
  ('000062', 'EXTRANJERA BURGER', 'EXTRANJERA BURGER', 'HAMBURGUESAS', 650.00, 250.00, 5),
  ('000064', 'MARICELAS BURGER', 'MARICELAS BURGER', 'HAMBURGUESAS', 550.00, 150.00, 6),
  ('000052', 'CLUB SANDWICH', 'CLUB SANDWICH', 'SANDWICHES Y TOSTADAS', 390.00, 150.00, 1),
  ('000058', 'CUBANO', 'CUBANO', 'SANDWICHES Y TOSTADAS', 320.00, 120.00, 2),
  ('000051', 'HOTDOG', 'HOTDOG', 'SANDWICHES Y TOSTADAS', 150.00, 75.00, 3),
  ('000057', 'SANDWICH DE PIERNA', 'SANDWICH DE PIERNA', 'SANDWICHES Y TOSTADAS', 225.00, 80.00, 4),
  ('000055', 'SANDWICH DE POLLO', 'SANDWICH DE POLLO', 'SANDWICHES Y TOSTADAS', 200.00, 65.00, 5),
  ('000056', 'SANDWICH JAMON Y QUESO', 'SANDWICH JAMON Y QUESO', 'SANDWICHES Y TOSTADAS', 120.00, 75.00, 6),
  ('000053', 'TOSTADAS DE JAMON Y QUESO', 'TOSTADAS DE JAMON Y QUESO', 'SANDWICHES Y TOSTADAS', 60.00, 45.00, 7),
  ('000054', 'TOSTADAS DE POLLO', 'TOSTADAS DE POLLO', 'SANDWICHES Y TOSTADAS', 80.00, 55.00, 8),
  ('000069', 'BURRITO DE PIERNA', 'BURRITO DE PIERNA', 'MEXICANO', 330.00, 150.00, 1),
  ('000067', 'BURRITO DE POLLO', 'BURRITO DE POLLO', 'MEXICANO', 300.00, 150.00, 2),
  ('000068', 'BURRITO DE RES', 'BURRITO DE RES', 'MEXICANO', 300.00, 120.00, 3),
  ('000070', 'BURRITO MIXTO', 'BURRITO MIXTO', 'MEXICANO', 350.00, 175.00, 4),
  ('000073', 'QUESADILLA DE PIERNA', 'QUESADILLA DE PIERNA', 'MEXICANO', 340.00, 125.00, 5),
  ('000071', 'QUESADILLA DE POLLO', 'QUESADILLA DE POLLO', 'MEXICANO', 340.00, 130.00, 6),
  ('000072', 'QUESADILLA DE RES', 'QUESADILLA DE RES', 'MEXICANO', 340.00, 120.00, 7),
  ('000074', 'QUESADILLA MIXTA', 'QUESADILLA MIXTA', 'MEXICANO', 300.00, 150.00, 8),
  ('000075', 'TRIO DE TACOS', 'TRIO DE TACOS', 'MEXICANO', 350.00, 125.00, 9),
  ('000035', 'MOFONGO DE CAMARONES', 'MOFONGO DE CAMARONES', 'MOFONGOS', 595.00, 200.00, 1),
  ('000034', 'MOFONGO DE CHICHARRON REBOZADO', 'MOFONGO DE CHICHARRON REBOZADO', 'MOFONGOS', 495.00, 200.00, 2),
  ('000033', 'MOFONGO DE POLLO', 'MOFONGO DE POLLO', 'MOFONGOS', 450.00, 350.00, 3),
  ('000036', 'MOFONGO MIXTO', 'MOFONGO MIXTO', 'MOFONGOS', 550.00, 250.00, 4),
  ('000039', 'PECHUGA A LA CREMA', 'PECHUGA A LA CREMA', 'POLLO', 475.00, 200.00, 1),
  ('000038', 'PECHUGA A LA PLANCHA', 'PECHUGA A LA PLANCHA', 'POLLO', 420.00, 250.00, 2),
  ('000040', 'PECHUGA A LA TROPICAL', 'PECHUGA A LA TROPICAL', 'POLLO', 600.00, 200.00, 3),
  ('000041', 'PECHUGA CORDON BLEU', 'PECHUGA CORDON BLEU', 'POLLO', 650.00, 250.00, 4),
  ('000132', 'CERDO ASADO + CASABE', 'CERDO ASADO + CASABE', 'CARNES', 533.33, 366.67, 1),
  ('000045', 'CHURRASCO ANGUS', 'CHURRASCO ANGUS', 'CARNES', 1300.00, 500.00, 2),
  ('000042', 'COSTILLA BBQ', 'COSTILLA BBQ', 'CARNES', 600.00, 210.00, 3),
  ('000044', 'FILETE DE CERDO', 'FILETE DE CERDO', 'CARNES', 600.00, 250.00, 4),
  ('000043', 'FILETE DE RES', 'FILETE DE RES', 'CARNES', 750.00, 350.00, 5),
  ('000024', 'CAMARONES A LA CREMA', 'CAMARONES A LA CREMA', 'MARISCOS Y PESCADOS', 675.00, 400.00, 1),
  ('000025', 'CAMARONES A LA CRIOLLA', 'CAMARONES A LA CRIOLLA', 'MARISCOS Y PESCADOS', 675.00, 400.00, 2),
  ('000026', 'CAMARONES A LA DIABLA', 'CAMARONES A LA DIABLA', 'MARISCOS Y PESCADOS', 595.00, 350.00, 3),
  ('000023', 'CAMARONES AL AJILLO', 'CAMARONES AL AJILLO', 'MARISCOS Y PESCADOS', 675.00, 400.00, 4),
  ('000029', 'MERO A LA CRIOLLA', 'MERO A LA CRIOLLA', 'MARISCOS Y PESCADOS', 450.00, 10.00, 5),
  ('000027', 'MERO A LA PLANCHA', 'MERO A LA PLANCHA', 'MARISCOS Y PESCADOS', 450.00, 300.00, 6),
  ('000028', 'MERO FRITO', 'MERO FRITO', 'MARISCOS Y PESCADOS', 450.00, 350.00, 7),
  ('000030', 'PESCADO FRITO', 'PESCADO FRITO', 'MARISCOS Y PESCADOS', 500.00, 300.00, 8),
  ('000065', 'CARNE SALADA', 'CARNE SALADA', 'COMIDA CRIOLLA', 375.00, 100.00, 1),
  ('000032', 'CHIVO GUISADO', 'CHIVO GUISADO', 'COMIDA CRIOLLA', 620.00, 350.00, 2),
  ('000066', 'LONGANIZA', 'LONGANIZA', 'COMIDA CRIOLLA', 350.00, 100.00, 3),
  ('000014', 'MONDONGO', 'MONDONGO', 'COMIDA CRIOLLA', 350.00, 50.00, 4),
  ('000031', 'RABO ENCENDIDO', 'RABO ENCENDIDO', 'COMIDA CRIOLLA', 600.00, 300.00, 5),
  ('000048', 'YAROA DE PAPA', 'YAROA DE PAPA', 'COMIDA CRIOLLA', 350.00, 150.00, 6),
  ('000049', 'YAROA DE PLATANO MADURO', 'YAROA DE PLATANO MADURO', 'COMIDA CRIOLLA', 350.00, 150.00, 7),
  ('000016', 'PASTA ALFREDO', 'PASTA ALFREDO', 'PASTAS', 500.00, 150.00, 1),
  ('000017', 'PASTA CARBONARA', 'PASTA CARBONARA', 'PASTAS', 495.00, 100.00, 2),
  ('000019', 'PASTA CON CAMARONES', 'PASTA CON CAMARONES', 'PASTAS', 550.00, 150.00, 3),
  ('000018', 'PASTA CUATRO QUESOS', 'PASTA CUATRO QUESO', 'PASTAS', 495.00, 150.00, 4),
  ('000012', 'ENSALADA CESAR', 'ENSALADA CESAR', 'SOPAS Y ENSALADAS', 325.00, 15.00, 1),
  ('000015', 'SOPA DE CAMARONES', 'SOPA DE CAMARONES', 'SOPAS Y ENSALADAS', 600.00, 15.00, 2),
  ('000013', 'SOPA DE POLLO', 'SOPA DE POLLO', 'SOPAS Y ENSALADAS', 220.00, 20.00, 3),
  ('000047', 'DULCE DE PIÑA CON LECHE', 'DULCE DE PIÑA CON LECHE', 'POSTRES', 150.00, 100.00, 1),
  ('000046', 'QUESILLO', 'QUESILLO', 'POSTRES', 200.00, 45.00, 2),
  ('000098', 'APEROL SPRITZ CLASICO', 'APEROL SPRITZ CLASICO', 'COCTELES', 300.00, 120.00, 1),
  ('000107', 'BLOODY MARY', 'BLODY MARRY', 'COCTELES', 320.00, 150.00, 2),
  ('000095', 'BLUE LAGOON TROPICAL', 'BLUE LAGON TROPICAL', 'COCTELES', 290.00, 125.00, 3),
  ('000084', 'CASAMIGOS PINEAPPLE FIZZ', 'CASAAMIGOS PINEAPPLE FIZZ', 'COCTELES', 495.00, 150.00, 4),
  ('000082', 'CASAMIGOS SANDIA SMASH', 'CASA AMIGOS SANDIA SMASH', 'COCTELES', 485.00, 220.00, 5),
  ('000093', 'COSMOPOLITAN', 'COSMOPOLITAN', 'COCTELES', 320.00, 150.00, 6),
  ('000091', 'EL DIABLO', 'EL DIABLO', 'COCTELES', 395.00, 130.00, 7),
  ('000085', 'MARGARITA DE CHINOLA', 'MARGARITA DE CHINOLA', 'COCTELES', 350.00, 150.00, 8),
  ('000086', 'MARGARITA TRADICIONAL', 'MARGARITA TRADICIONAL', 'COCTELES', 300.00, 150.00, 9),
  ('000090', 'MARICELAS MARGARITA', 'MARICELAS MARGARITA', 'COCTELES', 370.00, 120.00, 10),
  ('000089', 'MEXICAN MULE', 'MEXICAN MULE', 'COCTELES', 350.00, 120.00, 11),
  ('000080', 'MOJITO DE CHINOLA', 'MOJITO DE CHINOLA', 'COCTELES', 260.00, 75.00, 12),
  ('000078', 'MOJITO DE COCO', 'MOJITO DE COCO', 'COCTELES', 275.00, 75.00, 13),
  ('000077', 'MOJITO DE FRESA', 'MOJITO DE FRESA', 'COCTELES', 275.00, 100.00, 14),
  ('000079', 'MOJITO DE LIMON', 'MOJITO DE LIMON', 'COCTELES', 320.00, 100.00, 15),
  ('000097', 'MOSCOW MULE', 'MUSCOW MULE', 'COCTELES', 320.00, 120.00, 16),
  ('000083', 'PALOMA CASAMIGOS', 'PALOMA CASAAMIGOS', 'COCTELES', 455.00, 10.00, 17),
  ('000081', 'PIÑA COLADA', 'PIÑA COLADA', 'COCTELES', 255.00, 120.00, 18),
  ('000096', 'RASPBERRY RUM FIZZ', 'RASPBERRY RUM FIZZ', 'COCTELES', 320.00, 125.00, 19),
  ('000094', 'RUM PUNCH', 'RUN PUNCH', 'COCTELES', 280.00, 150.00, 20),
  ('000003', 'SANTO LIBRE', 'SANTO LIBRE', 'COCTELES', 270.00, 80.00, 21),
  ('000088', 'TEQUILA SOUR', 'TEQUILA SOUR', 'COCTELES', 350.00, 150.00, 22),
  ('000087', 'TEQUILA SUNRISE', 'TEQUILA SUNRISE', 'COCTELES', 300.00, 125.00, 23),
  ('000092', 'ZOMBIE', 'ZOMBIE', 'COCTELES', 350.00, 200.00, 24),
  ('000005', 'CORONA', 'CORONA', 'CERVEZAS', 225.00, 120.00, 1),
  ('000002', 'PRESIDENTE LIGHT', 'PRESIDENTE LIGHT', 'CERVEZAS', 180.00, 89.58, 2),
  ('1', 'PRESIDENTE NORMAL', 'PRESIDENTE NORMAL', 'CERVEZAS', 180.00, 89.58, 3),
  ('000104', 'COPA DE VINO PRIMALROOTS', 'COPA DE VINO PRIMALROOTS', 'LICORES Y VINOS', 330.00, 138.83, 1),
  ('000106', 'JACK DANIEL HONEY', 'JACK DANIEL HONEY', 'LICORES Y VINOS', 310.00, 187.50, 2),
  ('000114', 'JACK DANIEL OLD NO.7', 'JACK DANIEL OLD NO.7', 'LICORES Y VINOS', 315.00, 187.50, 3),
  ('000113', 'OLD PARR', 'OLD PARR', 'LICORES Y VINOS', 320.00, 179.46, 4),
  ('000004', 'SMIRNOFF', 'SMIRNOFF', 'LICORES Y VINOS', 230.00, 138.00, 5),
  ('000138', 'TITO''S VODKA', 'TITO''S VODKA', 'LICORES Y VINOS', 2055.00, 1300.00, 6),
  ('000135', 'VINO FRONTERA', 'VINO FRONTERA', 'LICORES Y VINOS', 1150.00, 500.00, 7),
  ('000105', 'AGUA CARBONATADA', 'AGUA CARBONATADA', 'BEBIDAS', 50.00, 35.00, 1),
  ('0000100', 'BOTELLA DE AGUA', 'BOTELLA DE AGUA', 'BEBIDAS', 25.00, 7.00, 2),
  ('000099', 'JUGOS NATURALES', 'JUGOS NATURALES', 'BEBIDAS', 110.00, 45.00, 3),
  ('000101', 'REFRESCO', 'REFRESCO', 'BEBIDAS', 60.00, 25.00, 4)
;

do $$
declare
  v_business  uuid := '1971ae49-935c-464a-9bfc-131d76a63be3';
  v_esperados int;
  v_itbis_id  uuid;
  v_kitchen   boolean;
  v_cocina_id   uuid;
  v_cocina_code text;
  v_bar_id      uuid;
  v_bar_code    text;
  v_menu_id   uuid;
  v_menus     int;
  v_n         int;
  v_list      text;
begin
  select count(*) into v_esperados from _mc_productos;

  -- =========================================================================
  -- 1) GUARDAS: se comprueba todo ANTES de escribir una sola fila.
  -- =========================================================================

  -- 1a) El negocio existe.
  if not exists (select 1 from public.businesses where id = v_business) then
    raise exception 'El negocio % no existe.', v_business;
  end if;

  -- 1b) La lista no trae un código ni un nombre dos veces, ni una categoría
  --     que no exista.
  select string_agg(n, ', ') into v_list
  from (select pg_temp.norm(name) as n from _mc_productos
        group by 1 having count(*) > 1
        union all
        select code from _mc_productos group by 1 having count(*) > 1) d;
  if v_list is not null then
    raise exception 'La lista trae códigos o nombres repetidos: %', v_list;
  end if;

  if exists (select 1 from _mc_productos p
             where not exists (select 1 from _mc_categorias c where c.name = p.categoria)) then
    raise exception 'Hay productos con una categoría que no está en _mc_categorias.';
  end if;

  -- 1c) Un ITBIS 18% activo, y uno solo, sin is_service_fee.
  select count(*) into v_n
  from public.taxes t
  where t.business_id = v_business
    and t.name ilike '%itbis%'
    and t.rate = 18
    and coalesce(t.is_active, true);

  if v_n <> 1 then
    select string_agg(format('%s %s%% (%s)', t.name, t.rate,
             case when coalesce(t.is_active, true) then 'activo' else 'INACTIVO' end),
           ', ')
      into v_list
    from public.taxes t
    where t.business_id = v_business;

    raise exception
      'Debe haber UN ITBIS 18%% activo y hay % (impuestos del negocio: %).',
      v_n, coalesce(v_list, 'ninguno');
  end if;

  select t.id into v_itbis_id
  from public.taxes t
  where t.business_id = v_business
    and t.name ilike '%itbis%'
    and t.rate = 18
    and coalesce(t.is_active, true);

  if exists (select 1 from public.taxes
             where id = v_itbis_id and coalesce(is_service_fee, false)) then
    raise exception
      'El ITBIS tiene is_service_fee = true: la factura lo cobraría DOS veces.';
  end if;

  -- 1d) Emparejamiento con el catálogo actual: por SKU (código del PDF) o por
  --     nombre (el corregido o el del PDF). Cada renglón de la lista puede
  --     caer en UN producto como mucho, y cada producto en UN renglón.
  drop table if exists _mc_cand;
  create temp table _mc_cand on commit drop as
  select p.code, mi.id as item_id, mi.name as item_name,
         (btrim(coalesce(mi.sku, '')) = p.code) as por_sku,
         (pg_temp.norm(mi.name) in (pg_temp.norm(p.name), pg_temp.norm(p.nombre_pdf))) as por_nombre
  from _mc_productos p
  join public.menu_items mi
    on mi.business_id = v_business
   and (btrim(coalesce(mi.sku, '')) = p.code
        or pg_temp.norm(mi.name) in (pg_temp.norm(p.name), pg_temp.norm(p.nombre_pdf)));

  select string_agg(format('%s → %s', code, nombres), '; ') into v_list
  from (select code, string_agg(item_name, ' / ' order by item_name) as nombres
        from _mc_cand group by code having count(*) > 1) d;
  if v_list is not null then
    raise exception
      'Estos renglones caen en VARIOS productos del catálogo, no sé cuál actualizar: %', v_list;
  end if;

  select string_agg(format('%s ← %s', item_name, codes), '; ') into v_list
  from (select item_name, string_agg(code, ', ' order by code) as codes
        from _mc_cand group by item_id, item_name having count(*) > 1) d;
  if v_list is not null then
    raise exception
      'Estos productos del catálogo caen en VARIOS renglones de la lista: %', v_list;
  end if;

  -- Mismo SKU pero otro nombre: el código del sistema viejo ya se usó para
  -- otra cosa. No se pisa.
  select string_agg(format('%s (sku %s) vs lista "%s"', c.item_name, c.code, p.name), '; ')
    into v_list
  from _mc_cand c
  join _mc_productos p on p.code = c.code
  where c.por_sku and not c.por_nombre;
  if v_list is not null then
    raise exception
      'Estos productos tienen el SKU de la lista pero OTRO nombre, no los piso: %', v_list;
  end if;

  -- 1e) Menú: 0 se crea, 1 se reusa, más de 1 aborta.
  select count(*) into v_menus
  from public.menus
  where business_id = v_business and coalesce(is_active, true);

  if v_menus > 1 then
    select string_agg(name, ', ' order by created_at) into v_list
    from public.menus
    where business_id = v_business and coalesce(is_active, true);

    raise exception
      'El negocio tiene % menús activos (%). Dime a cuál van los productos.',
      v_menus, v_list;
  end if;

  -- 1f) Áreas de comanda (ver encabezado).
  select coalesce(bs.kitchen_enabled, true) into v_kitchen
  from public.business_settings bs
  where bs.business_id = v_business;
  v_kitchen := coalesce(v_kitchen, true);

  if v_kitchen then
    -- COCINA
    select a.id, a.code into v_cocina_id, v_cocina_code
    from public.print_areas a
    where a.business_id = v_business
      and a.is_active
      and (a.code in ('cocina', 'kitchen', 'kitchen_hot', 'comida')
           or pg_temp.norm(a.name) in ('cocina', 'kitchen', 'comida'))
    order by (a.code = 'cocina') desc, (a.code = 'kitchen') desc, a.created_at
    limit 1;

    if v_cocina_id is null then
      select a.id, a.code into v_cocina_id, v_cocina_code
      from public.print_areas a
      where a.business_id = v_business
        and (a.code in ('cocina', 'kitchen', 'kitchen_hot', 'comida')
             or pg_temp.norm(a.name) in ('cocina', 'kitchen', 'comida'))
      order by (a.code = 'cocina') desc, a.created_at
      limit 1;

      if v_cocina_id is not null then
        update public.print_areas set is_active = true where id = v_cocina_id;
      elsif exists (select 1 from public.print_areas
                    where business_id = v_business and code = 'cocina') then
        raise exception 'Ya hay un área con code "cocina" que no se reconoce. Revísala.';
      else
        v_cocina_id   := gen_random_uuid();
        v_cocina_code := 'cocina';
        insert into public.print_areas (id, business_id, name, code, is_active)
        values (v_cocina_id, v_business, 'Cocina', v_cocina_code, true);
      end if;
    end if;

    -- BAR
    select a.id, a.code into v_bar_id, v_bar_code
    from public.print_areas a
    where a.business_id = v_business
      and a.is_active
      and (a.code in ('bar', 'barra') or pg_temp.norm(a.name) in ('bar', 'barra'))
    order by (a.code = 'bar') desc, a.created_at
    limit 1;

    if v_bar_id is null then
      select a.id, a.code into v_bar_id, v_bar_code
      from public.print_areas a
      where a.business_id = v_business
        and (a.code in ('bar', 'barra') or pg_temp.norm(a.name) in ('bar', 'barra'))
      order by (a.code = 'bar') desc, a.created_at
      limit 1;

      if v_bar_id is not null then
        update public.print_areas set is_active = true where id = v_bar_id;
      elsif exists (select 1 from public.print_areas
                    where business_id = v_business and code = 'bar') then
        raise exception 'Ya hay un área con code "bar" que no se reconoce. Revísala.';
      else
        v_bar_id   := gen_random_uuid();
        v_bar_code := 'bar';
        insert into public.print_areas (id, business_id, name, code, is_active)
        values (v_bar_id, v_business, 'Bar', v_bar_code, true);
      end if;
    end if;

    if v_cocina_id = v_bar_id then
      raise exception 'La cocina y el bar cayeron en la MISMA área (%). Revísalas.', v_bar_code;
    end if;
  end if;

  -- =========================================================================
  -- 2) MENÚ
  -- =========================================================================

  select id into v_menu_id
  from public.menus
  where business_id = v_business and coalesce(is_active, true)
  order by created_at
  limit 1;

  if v_menu_id is null then
    v_menu_id := gen_random_uuid();
    insert into public.menus (id, business_id, name, is_active)
    values (v_menu_id, v_business, 'Menú Principal', true);
  end if;

  -- =========================================================================
  -- 3) CATEGORÍAS: crea las que falten; las que ya existen se respetan
  --    (nombre y posición), solo se reactivan.
  -- =========================================================================

  insert into public.categories (id, business_id, name, position, is_active)
  select gen_random_uuid(), v_business, c.name, c.posicion, true
  from _mc_categorias c
  where not exists (
    select 1 from public.categories x
    where x.business_id = v_business
      and pg_temp.norm(x.name) = pg_temp.norm(c.name)
  );

  update public.categories x
  set is_active = true
  from _mc_categorias c
  where x.business_id = v_business
    and pg_temp.norm(x.name) = pg_temp.norm(c.name)
    and not x.is_active;

  -- =========================================================================
  -- 4) PRODUCTOS: actualiza los que ya existen, inserta los que faltan.
  --    print_area_code se escribe aquí mismo. El nombre del que ya existe se
  --    respeta, salvo que sea el del PDF con el error de tipeo.
  -- =========================================================================

  drop table if exists _mc_dest;
  create temp table _mc_dest on commit drop as
  select p.code, cat.id as category_id, c.area,
         case c.area when 'cocina' then v_cocina_code else v_bar_code end as area_code,
         case c.area when 'cocina' then v_cocina_id   else v_bar_id   end as area_id
  from _mc_productos p
  join _mc_categorias c on c.name = p.categoria
  cross join lateral (
    select x.id from public.categories x
    where x.business_id = v_business
      and pg_temp.norm(x.name) = pg_temp.norm(p.categoria)
    order by x.is_active desc, x.created_at
    limit 1
  ) cat;

  update public.menu_items mi
  set name            = case when pg_temp.norm(mi.name) = pg_temp.norm(p.nombre_pdf)
                              and pg_temp.norm(p.nombre_pdf) <> pg_temp.norm(p.name)
                             then p.name else mi.name end,
      sku             = p.code,
      price           = p.price,
      cost            = p.cost,
      category_id     = d.category_id,
      tax_mode        = 'inclusive',
      is_active       = true,
      is_beverage     = (d.area = 'bar'),
      position        = p.posicion,
      print_area_code = d.area_code,
      updated_at      = now()
  from _mc_cand c
  join _mc_productos p on p.code = c.code
  join _mc_dest d on d.code = c.code
  where mi.id = c.item_id;

  insert into public.menu_items (
    id, business_id, category_id, name, sku, price, cost,
    tax_mode, is_active, is_beverage, position, print_area_code
  )
  select gen_random_uuid(), v_business, d.category_id, p.name, p.code, p.price, p.cost,
         'inclusive', true, (d.area = 'bar'), p.posicion, d.area_code
  from _mc_productos p
  join _mc_dest d on d.code = p.code
  where not exists (select 1 from _mc_cand c where c.code = p.code);

  drop table if exists _mc_ids;
  create temp table _mc_ids on commit drop as
  select mi.id, p.code
  from public.menu_items mi
  join _mc_productos p on p.code = btrim(mi.sku)
  where mi.business_id = v_business;

  -- =========================================================================
  -- 5) IMPUESTOS: solo el ITBIS 18%.
  -- =========================================================================

  delete from public.menu_item_taxes mit
  using _mc_ids i
  where mit.item_id = i.id
    and mit.tax_id <> v_itbis_id;

  insert into public.menu_item_taxes (item_id, tax_id)
  select i.id, v_itbis_id
  from _mc_ids i
  where not exists (
    select 1 from public.menu_item_taxes x
    where x.item_id = i.id and x.tax_id = v_itbis_id
  );

  -- =========================================================================
  -- 6) ÁREA DE COMANDA (N:M). El legacy ya quedó escrito en el paso 4.
  --    Se borran asignaciones a otras áreas: si no, el producto saldría por
  --    DOS impresoras. Con cocina apagada no queda ninguna.
  -- =========================================================================

  delete from public.menu_item_print_areas x
  using _mc_ids i
  join _mc_dest d on d.code = i.code
  where x.menu_item_id = i.id
    and x.print_area_id is distinct from d.area_id;

  insert into public.menu_item_print_areas (menu_item_id, print_area_id)
  select i.id, d.area_id
  from _mc_ids i
  join _mc_dest d on d.code = i.code
  where d.area_id is not null
    and not exists (
      select 1 from public.menu_item_print_areas x
      where x.menu_item_id = i.id and x.print_area_id = d.area_id
    );

  -- =========================================================================
  -- 7) ENLACE AL MENÚ: sin esto el producto no aparece en la caja.
  -- =========================================================================

  insert into public.menu_item_links (menu_id, item_id, position)
  select v_menu_id, i.id, p.posicion
  from _mc_ids i
  join _mc_productos p on p.code = i.code
  where not exists (
    select 1 from public.menu_item_links l
    where l.menu_id = v_menu_id and l.item_id = i.id
  );

  -- =========================================================================
  -- 8) VERIFICACIÓN DENTRO DE LA TRANSACCIÓN: cualquier fallo revierte TODO.
  -- =========================================================================

  select count(*) into v_n
  from _mc_productos p
  where (select count(*) from _mc_ids i
         join public.menu_items mi on mi.id = i.id
         where i.code = p.code and mi.is_active) <> 1;
  if v_n > 0 or (select count(*) from _mc_ids) <> v_esperados then
    raise exception '% productos de la lista no quedaron (o quedaron repetidos). Revertido.', v_n;
  end if;

  select count(*) into v_n
  from _mc_ids i
  join public.menu_items mi on mi.id = i.id
  join _mc_productos p on p.code = i.code
  join _mc_dest d on d.code = i.code
  where mi.price <> p.price
     or mi.cost is distinct from p.cost
     or mi.tax_mode <> 'inclusive'
     or mi.category_id is distinct from d.category_id
     or mi.is_beverage <> (d.area = 'bar');
  if v_n > 0 then
    raise exception '% productos con precio, costo, impuesto o categoría incorrectos. Revertido.', v_n;
  end if;

  select count(*) into v_n
  from _mc_ids i
  where not exists (select 1 from public.menu_item_taxes x
                    where x.item_id = i.id and x.tax_id = v_itbis_id)
     or exists (select 1 from public.menu_item_taxes x
                where x.item_id = i.id and x.tax_id <> v_itbis_id);
  if v_n > 0 then
    raise exception '% productos con un juego de impuestos distinto a solo ITBIS. Revertido.', v_n;
  end if;

  select count(*) into v_n
  from _mc_ids i
  join public.menu_items mi on mi.id = i.id
  join _mc_dest d on d.code = i.code
  where mi.print_area_code is distinct from d.area_code
     or (select count(*) from public.menu_item_print_areas x
         where x.menu_item_id = i.id) <> case when d.area_id is null then 0 else 1 end
     or (d.area_id is not null
         and not exists (select 1 from public.menu_item_print_areas x
                         where x.menu_item_id = i.id and x.print_area_id = d.area_id));
  if v_n > 0 then
    raise exception '% productos sin área de comanda o con legacy y N:M en desacuerdo. Revertido.', v_n;
  end if;

  select count(*) into v_n
  from _mc_ids i
  where not exists (select 1 from public.menu_item_links l
                    where l.menu_id = v_menu_id and l.item_id = i.id);
  if v_n > 0 then
    raise exception '% productos fuera del menú: no saldrían en la caja. Revertido.', v_n;
  end if;

  raise notice 'OK: % productos (% ya existían), cocina=%, bar=%. Commit.',
    v_esperados, (select count(*) from _mc_cand),
    coalesce(v_cocina_code, 'ninguna (cocina apagada)'),
    coalesce(v_bar_code, 'ninguna (cocina apagada)');
end $$;

commit;

-- ============================================================================
-- REPORTE: todas las filas deben decir ✓
-- ============================================================================

with
biz as (
  select '1971ae49-935c-464a-9bfc-131d76a63be3'::uuid as id
),
esperados as (
  select count(*)::int as n from _mc_productos
),
items as (
  select mi.*, p.price as precio_lista, p.cost as costo_lista, c.area
  from public.menu_items mi
  join biz on mi.business_id = biz.id
  join _mc_productos p on p.code = btrim(mi.sku)
  join _mc_categorias c on c.name = p.categoria
  where mi.is_active
),
itbis as (
  select t.* from public.taxes t, biz
  where t.business_id = biz.id
    and t.name ilike '%itbis%' and t.rate = 18 and coalesce(t.is_active, true)
  limit 1
),
juegos as (
  select i.id,
         coalesce((select string_agg(format('%s %s%%', t.name, t.rate), ' + '
                                     order by t.rate desc, t.name)
                   from public.menu_item_taxes x
                   join public.taxes t on t.id = x.tax_id
                   where x.item_id = i.id), 'SIN IMPUESTO') as juego
  from items i
),
ajustes as (
  select coalesce((s.j->>'kitchen_enabled')::boolean, true) as cocina_encendida,
         coalesce((s.j->>'service_fee_enabled')::boolean, false) as ley_por_orden
  from (select to_jsonb(bs) as j from public.business_settings bs, biz
        where bs.business_id = biz.id
        union all
        select '{}'::jsonb
        where not exists (select 1 from public.business_settings bs, biz
                          where bs.business_id = biz.id)) s
),
ruta as (
  select i.area, a.id as area_id, a.name, a.code
  from items i
  join public.menu_item_print_areas x on x.menu_item_id = i.id
  join public.print_areas a on a.id = x.print_area_id
),
r(orden, concepto, encontrado, esperado, ok) as (
  select 1, 'Productos de la lista (activos)',
         (select count(*) from items)::text, (select n from esperados)::text,
         (select count(*) from items) = (select n from esperados)
  union all
  select 2, 'Con precio o costo distinto a la lista',
         (select count(*) from items
          where price <> precio_lista or cost is distinct from costo_lista)::text, '0',
         (select count(*) from items
          where price <> precio_lista or cost is distinct from costo_lista) = 0
  union all
  select 3, 'Con ITBIS incluido (inclusive)',
         (select count(*) from items where tax_mode = 'inclusive')::text,
         (select n from esperados)::text,
         (select count(*) from items where tax_mode = 'inclusive') = (select n from esperados)
  union all
  select 4, 'Juego de impuestos (solo ITBIS 18%)',
         (select string_agg(format('%s (%s)', juego, n), ' · ')
          from (select juego, count(*) as n from juegos group by juego) g),
         'ITBIS 18% en todos',
         (select count(*) from juegos j
          where exists (select 1 from public.menu_item_taxes x join itbis t on t.id = x.tax_id
                        where x.item_id = j.id)
            and (select count(*) from public.menu_item_taxes x where x.item_id = j.id) = 1)
         = (select n from esperados)
  union all
  select 5, 'Ley 10% por orden (service_fee_enabled)',
         case when (select ley_por_orden from ajustes) then 'ENCENDIDA' else 'apagada' end,
         'apagada',
         not (select ley_por_orden from ajustes)
  union all
  select 6, 'Ejemplo: Aperol Spritz $300',
         (select format('base %s + ITBIS %s = %s',
                        round(i.price / 1.18, 2), i.price - round(i.price / 1.18, 2), i.price)
          from items i where i.sku = '000098'),
         'base 254.24 + ITBIS 45.76 = 300.00',
         (select i.price = 300 from items i where i.sku = '000098')
  union all
  select 7, 'Comida → área: ' || case
            when not (select cocina_encendida from ajustes) then 'ninguna (cocina apagada)'
            else coalesce((select string_agg(distinct name || ' (' || code || ')', ', ')
                           from ruta where area = 'cocina'), '—') end,
         (select count(distinct x.menu_item_id) from public.menu_item_print_areas x
          join items i on i.id = x.menu_item_id where i.area = 'cocina')::text,
         case when (select cocina_encendida from ajustes)
              then (select count(*) from items where area = 'cocina')::text else '0' end,
         case when (select cocina_encendida from ajustes)
              then (select count(distinct x.menu_item_id) from public.menu_item_print_areas x
                    join items i on i.id = x.menu_item_id where i.area = 'cocina')
                   = (select count(*) from items where area = 'cocina')
                   and (select count(distinct area_id) from ruta where area = 'cocina') = 1
              else not exists (select 1 from ruta) end
  union all
  select 8, 'Bebidas → área: ' || case
            when not (select cocina_encendida from ajustes) then 'ninguna (cocina apagada)'
            else coalesce((select string_agg(distinct name || ' (' || code || ')', ', ')
                           from ruta where area = 'bar'), '—') end,
         (select count(distinct x.menu_item_id) from public.menu_item_print_areas x
          join items i on i.id = x.menu_item_id where i.area = 'bar')::text,
         case when (select cocina_encendida from ajustes)
              then (select count(*) from items where area = 'bar')::text else '0' end,
         case when (select cocina_encendida from ajustes)
              then (select count(distinct x.menu_item_id) from public.menu_item_print_areas x
                    join items i on i.id = x.menu_item_id where i.area = 'bar')
                   = (select count(*) from items where area = 'bar')
                   and (select count(distinct area_id) from ruta where area = 'bar') = 1
              else not exists (select 1 from ruta) end
  union all
  select 9, 'Legacy print_area_code igual a la N:M',
         (select count(*) from items i
          where i.print_area_code is not distinct from (
            select a.code from public.menu_item_print_areas x
            join public.print_areas a on a.id = x.print_area_id
            where x.menu_item_id = i.id limit 1))::text, (select n from esperados)::text,
         (select count(*) from items i
          where i.print_area_code is not distinct from (
            select a.code from public.menu_item_print_areas x
            join public.print_areas a on a.id = x.print_area_id
            where x.menu_item_id = i.id limit 1)) = (select n from esperados)
  union all
  select 10, 'Enlazados al menú de la caja',
         (select count(*) from items i where exists (
            select 1 from public.menu_item_links l where l.item_id = i.id))::text,
         (select n from esperados)::text,
         (select count(*) from items i where exists (
            select 1 from public.menu_item_links l where l.item_id = i.id))
         = (select n from esperados)
  union all
  select 11, 'Impresoras en el área de la cocina',
         case when not (select cocina_encendida from ajustes) then 'no aplica'
              else (select count(*) from public.print_area_printers p
                    where p.area_id in (select area_id from ruta where area = 'cocina'))::text end,
         '1 o más',
         not (select cocina_encendida from ajustes)
         or (select count(*) from public.print_area_printers p
             where p.area_id in (select area_id from ruta where area = 'cocina')) > 0
  union all
  select 12, 'Impresoras en el área del bar',
         case when not (select cocina_encendida from ajustes) then 'no aplica'
              else (select count(*) from public.print_area_printers p
                    where p.area_id in (select area_id from ruta where area = 'bar'))::text end,
         '1 o más',
         not (select cocina_encendida from ajustes)
         or (select count(*) from public.print_area_printers p
             where p.area_id in (select area_id from ruta where area = 'bar')) > 0
  union all
  select 13, 'ITBIS en mesa / rápida / llevar / delivery',
         coalesce((select concat_ws(' / ',
                     case when apply_on_zone     then 'sí' else 'NO' end,
                     case when apply_on_quick    then 'sí' else 'NO' end,
                     case when apply_on_takeout  then 'sí' else 'NO' end,
                     case when apply_on_delivery then 'sí' else 'NO' end) from itbis), '—'),
         'sí / sí / sí / sí',
         coalesce((select apply_on_zone and apply_on_quick
                          and apply_on_takeout and apply_on_delivery from itbis), false)
  union all
  select 14, 'Categorías con productos de la lista',
         (select count(distinct category_id) from items)::text,
         (select count(*) from _mc_categorias)::text,
         (select count(distinct category_id) from items) = (select count(*) from _mc_categorias)
)
select concepto, encontrado, esperado,
       case when ok then '✓' else '✗ REVISAR' end as estado
from r
order by orden;
