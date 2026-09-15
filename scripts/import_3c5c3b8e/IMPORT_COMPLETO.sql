-- ============================================================================
-- 007 BAR & SNACK, SRL — CARGA COMPLETA DEL CATÁLOGO
-- Business 3c5c3b8e-28e6-45f0-8dc7-85e3efe8d30c
--
-- Fuente: "PRODUCTOS 007.pdf", listado de artículos del sistema anterior
-- (14/09/2026 18:29, 828 artículos).
--
-- ⚠ ARCHIVO GENERADO por build_import_3c5c3b8e.py desde _tpl_import.sql.
--   No lo edites a mano: cambia el .py (o la plantilla) y regenera.
-- ============================================================================
--
-- QUÉ CARGA
--   828 productos en 20 categorías: 822 activos y 6 inactivos.
--   771 con código de barras. Todos llevan el código del listado en `sku`,
--   que la pistola también lee.
--   822 inventariables. 181 con existencia inicial: 2955 unidades,
--   RD$247,332.65 a costo.
--
-- CÓMO CORRERLO
--   Corre antes 00_diagnostico.sql. Después pega este archivo entero en el SQL
--   Editor de Supabase y dale Run. La tabla del final es el reporte: todas las
--   filas deben decir ✓.
--
-- TODO O NADA
--   Va en UNA transacción. Primero comprueba todo (negocio, ITBIS, Ley, menú,
--   bodega, área, códigos repetidos) y, antes del commit, verifica los
--   828 uno por uno. Si algo no cuadra, lanza excepción y REVIERTE ENTERO.
--
-- SE PUEDE RE-CORRER
--   Empareja por CÓDIGO del listado (sku o código de barras), no por nombre:
--   el listado trae 8 nombres repetidos con códigos distintos.
--   El producto que ya existe se actualiza en precio, costo, categoría, ITBIS,
--   código de barras y área. Conserva el nombre y no se reactiva si lo apagaste
--   en la app. El que falta se inserta.
--   La existencia inicial entra UNA sola vez por insumo: correrlo de nuevo no
--   la vuelve a sumar.
--
-- DECISIONES DEL DUEÑO (15/09/2026)
--   * ITBIS 18% INCLUIDO en el precio (tax_mode = 'inclusive'), sin Ley 10%.
--     Trident Menta a $30 = base 25.42 + ITBIS 4.58. menu_item_taxes es la
--     ÚNICA fuente del impuesto: sin la fila, la factura sale con ITBIS 0.00.
--   * Inventario 1:1 con link directo (vendes 1, descuenta 1), sin recetas.
--     La existencia positiva del listado entra como movimiento 'purchase' con
--     reference_type 'initial_stock' en la bodega de la que descuenta la venta.
--     Los 39 negativos entran en 0: hay que contarlos.
--     allow_negative_sale = true: 608 productos arrancan en 0 y el conteo del
--     listado no es confiable. Que el sistema no los esconda al venderlos.
--   * 6 renglones que no son mercancía entran INACTIVOS y sin inventario:
--     RENTA DE LOCAL, BOTELLAS VACIAS, EMBUDO USO INTERNO, REFRIGERIO,JUGOS,
--     AMPICILLIN y SANTA CXAROLINA MERLOT RESERVA (precio 0).
--
-- ÁREA DE COMANDA — cómo la escoge el script
--   * Cocina apagada (business_settings.kitchen_enabled = false, el preset de
--     tienda): NINGUNA. La venta pasa directo a "listo" sin comanda.
--   * Cocina encendida: el área `bar`/`barra` si existe; si no, la única área
--     activa; si no hay ninguna o hay varias, ABORTA y explica.
--   Se escriben los DOS mecanismos (menu_item_print_areas y el legacy
--   print_area_code) para que no queden en desacuerdo.
--
-- MENÚ
--   La caja filtra por menú (menu_item_links). Sin menú se crea "Menú
--   Principal"; con uno se reusa; con más de uno, ABORTA.
-- ============================================================================

begin;

-- ---------------------------------------------------------------------------
-- 0) El listado, en tablas temporales que mueren con la transacción.
-- ---------------------------------------------------------------------------

create temp table _p007 (
  codigo        text primary key,     -- "Articulo" del listado
  name          text not null,
  categoria     text not null,
  price         numeric(12,2) not null,
  cost          numeric,              -- null si el listado dice 0.0000
  qty           numeric not null,     -- existencia inicial (negativos → 0)
  qty_listado   numeric not null,     -- lo que dice el listado, tal cual
  barcode       text,                 -- null si el código no es GTIN
  is_bev        boolean not null,
  activo        boolean not null,
  inventariable boolean not null,
  posicion      int not null
) on commit drop;

-- filas 1–200
insert into _p007 (codigo, name, categoria, price, cost, qty, qty_listado, barcode, is_bev, activo, inventariable, posicion) values
  ('8594003352331', 'BERNARD AMBER LAGER', 'Cervezas', 390.00, 220.3300, 5.00, 5.00, '8594003352331', true, true, true, 1),
  ('8594003351815', 'BERNARD BOHEMIAN ALE', 'Cervezas', 490.00, 290.0000, 5.00, 5.00, '8594003351815', true, true, true, 2),
  ('8594003352614', 'BERNARD CELEBRATION LAGER', 'Cervezas', 390.00, 220.3300, 0.00, -2.00, '8594003352614', true, true, true, 3),
  ('8594003352522', 'BERNARD DARK LAGER', 'Cervezas', 390.00, 220.3300, 6.00, 6.00, '8594003352522', true, true, true, 4),
  ('8412598005862', 'BLACK COUPAGE 1906', 'Cervezas', 210.00, 114.0536, 3.00, 3.00, '8412598005862', true, true, true, 5),
  ('8500001270089', 'BUCANERO CERVEZA PEQ.', 'Cervezas', 110.00, 65.1800, 0.00, 0.00, '8500001270089', true, true, true, 6),
  ('8690582723200', 'CARLSBERG 330ML', 'Cervezas', 120.00, 66.2692, 0.00, 0.00, '8690582723200', true, true, true, 7),
  ('8690582722203', 'CARLSBERG LATA 330ML', 'Cervezas', 85.00, null, 0.00, 0.00, '8690582722203', true, true, true, 8),
  ('87120103', 'CERV. HEINEKEN LATA PEQ', 'Cervezas', 100.00, 59.6250, 44.00, 44.00, '87120103', true, true, true, 9),
  ('8714800001793', 'CERVEZA HOLLANDIA 330ML', 'Cervezas', 85.00, 49.0819, 0.00, 0.00, '8714800001793', true, true, true, 10),
  ('8423453910535', 'CERVEZA REPUBLICA DE BOTELLA', 'Cervezas', 125.00, 75.0000, 0.00, 0.00, '8423453910535', true, true, true, 11),
  ('8423453910566', 'CERVEZA REPUBLICA LATA', 'Cervezas', 115.00, 62.7800, 0.00, 0.00, '8423453910566', true, true, true, 12),
  ('8412598005831', 'ESTRELLA GALICIA', 'Cervezas', 180.00, 102.0480, 17.00, 17.00, '8412598005831', true, true, true, 13),
  ('8712000030582', 'HEINEKEN GRANDE', 'Cervezas', 265.00, 148.3333, 152.00, 152.00, '8712000030582', true, true, true, 14),
  ('8712000900045', 'HEINEKEN LATA GRANDE', 'Cervezas', 190.00, 106.0833, 20.00, 20.00, '8712000900045', true, true, true, 15),
  ('8714800014212', 'HOLANDIA 650 ML', 'Cervezas', 120.00, 80.2200, 0.00, 0.00, '8714800014212', true, true, true, 16),
  ('8714800007580', 'HOLLANDIA 500ML', 'Cervezas', 75.00, 53.6700, 0.00, 0.00, '8714800007580', true, true, true, 17),
  ('8714800031127', 'HOLLANDIA LIMON', 'Cervezas', 85.00, 61.3600, 0.00, 0.00, '8714800031127', true, true, true, 18),
  ('851621000043', 'KRONENBOURG BLANC 1664', 'Cervezas', 175.00, 105.3300, 0.00, 0.00, '851621000043', true, true, true, 19),
  ('8411327001076', 'MAHOU 5 ESTRELLA BOTELLA', 'Cervezas', 175.00, 98.7083, 3.00, 3.00, '8411327001076', true, true, true, 20),
  ('8411327003308', 'MAHOU 5 ESTRELLA EIGHT RADLER LATA', 'Cervezas', 145.00, 87.6600, 0.00, 0.00, '8411327003308', true, true, true, 21),
  ('8411327008419', 'MAHOU 5 STRELLAS', 'Cervezas', 180.00, 98.7083, 6.00, 6.00, '8411327008419', true, true, true, 22),
  ('8411327001717', 'MAHOU CERVEZA SIN ALCOHOL', 'Cervezas', 80.00, 47.3700, 0.00, 0.00, '8411327001717', true, true, true, 23),
  ('8411327001960', 'MAHOU MAESTRA', 'Cervezas', 210.00, 113.0000, 0.00, -3.00, '8411327001960', true, true, true, 24),
  ('8001435310018', 'MORETTI REGULAR 330ML BOTELLA', 'Cervezas', 180.00, 107.3400, 0.00, 0.00, '8001435310018', true, true, true, 25),
  ('8423453909980', 'OCHO CERO NUEVE', 'Cervezas', 95.00, 57.1900, 0.00, 0.00, '8423453909980', true, true, true, 26),
  ('8594006931090', 'PRIMATO 24 DOUBLE 500.M.L', 'Cervezas', 380.00, 220.0000, 0.00, 0.00, '8594006931090', true, true, true, 27),
  ('8594006931328', 'PRIMATOR WEIZEN PSENICNE 500.ML', 'Cervezas', 270.00, 150.0000, 0.00, 0.00, '8594006931328', true, true, true, 28),
  ('8712000051945', 'RED STRIPE', 'Cervezas', 100.00, 40.0000, 26.00, 26.00, '8712000051945', true, true, true, 29),
  ('876529000476', 'ROGUE BATSQUATCH LATA', 'Cervezas', 245.00, 143.7800, 0.00, 0.00, '876529000476', true, true, true, 30),
  ('876529000421', 'ROGUE OUTTA LINE LATA', 'Cervezas', 245.00, 143.7800, 0.00, 0.00, '876529000421', true, true, true, 31),
  ('84692204045', 'ALIZE WIL PASSION 750ML', 'Licores', 1275.00, 843.1500, 0.00, 0.00, '084692204045', true, true, true, 1),
  ('8004747005535', 'ANTICA SAMBUCA CLASSIC 70CLS.', 'Licores', 700.00, 480.0000, 0.00, 0.00, '8004747005535', true, true, true, 2),
  ('796020140504', 'BARCELO DORADO 750ML', 'Licores', 320.00, 185.0000, 0.00, 0.00, '796020140504', true, true, true, 3),
  ('796020100508', 'BARCELO IMPERIAL 700ML', 'Licores', 690.00, 683.1200, 0.00, 0.00, '796020100508', true, true, true, 4),
  ('804884', 'BOMBAY SAPPHIRE MINIATURA', 'Licores', 200.00, 114.4000, 0.00, 0.00, null, true, true, true, 5),
  ('8414771852881', 'BRANDY NAPOLEON RESERVE 12-70C', 'Licores', 600.00, 458.3333, 0.00, 0.00, '8414771852881', true, true, true, 6),
  ('8000040002509', 'CAMPARI-BITTER 75CL', 'Licores', 620.00, 412.0000, 1.00, 1.00, '8000040002509', true, true, true, 7),
  ('8410161711257', 'CARDENAL MENDOZA BRANDY DE JEREZ', 'Licores', 2995.00, 2500.0000, 0.00, 0.00, '8410161711257', true, true, true, 8),
  ('796020010029', 'CARTA REAL', 'Licores', 250.00, 175.0000, 0.00, 0.00, '796020010029', true, true, true, 9),
  ('796020010128', 'CARTA REAL 350ML', 'Licores', 125.00, 68.8600, 0.00, 0.00, '796020010128', true, true, true, 10),
  ('8000020000365', 'CINZANO BIANCO', 'Licores', 540.00, 360.0000, 2.00, 2.00, '8000020000365', true, true, true, 11),
  ('8000020000396', 'CINZANO ROSE', 'Licores', 540.00, 358.0000, 1.00, 1.00, '8000020000396', true, true, true, 12),
  ('796020600022', 'COLUMBUS BLANCO', 'Licores', 320.00, 232.4000, 0.00, 0.00, '796020600022', true, true, true, 13),
  ('796020600008', 'COLUMBUS RON AÑEJO 750ML', 'Licores', 320.00, 233.2000, 0.00, 0.00, '796020600008', true, true, true, 14),
  ('7640171032054', 'DEWARS MINI', 'Licores', 180.00, 84.7457, 8.00, 8.00, '7640171032054', true, true, true, 15),
  ('796020100515', 'DUBAR IMPERIAL', 'Licores', 999.00, 738.7000, 0.00, 0.00, '796020100515', true, true, true, 16),
  ('8410414000466', 'ERISTOFF VODKA 750ML', 'Licores', 600.00, 406.1800, 0.00, 0.00, '8410414000466', true, true, true, 17),
  ('8410557900203', 'IMPERIAL TOLEDANA CHERRY', 'Licores', 230.00, 153.3333, 0.00, 0.00, '8410557900203', true, true, true, 18),
  ('8414771853208', 'IRISH CREAM 70CL', 'Licores', 875.00, 473.0000, 0.00, 0.00, '8414771853208', true, true, true, 19),
  ('8411705100230', 'LAS LLAVES AVELLANA', 'Licores', 200.00, 133.0000, 0.00, 0.00, '8411705100230', true, true, true, 20),
  ('8411705100223', 'LAS LLAVES MANZANA 70CL', 'Licores', 200.00, 133.0000, 0.00, 0.00, '8411705100223', true, true, true, 21),
  ('8411705100216', 'LAS LLAVES MELOCOTON 70 CL', 'Licores', 200.00, 133.0000, 0.00, 0.00, '8411705100216', true, true, true, 22),
  ('811538010801', 'OUR TEQUILA', 'Licores', 1860.00, 1124.8900, 0.00, 0.00, '811538010801', true, true, true, 23),
  ('860012986828', 'OZAMA RON DOMINICANO . AÑEJO', 'Licores', 1500.00, 874.0000, 1.00, 1.00, '860012986828', true, true, true, 24),
  ('860012986811', 'OZAMA RON DOMINICANO BLANCO', 'Licores', 1400.00, 806.0000, 1.00, 1.00, '860012986811', true, true, true, 25),
  ('860012986835', 'OZAMA RON GRAN AÑEJO 700.M.L', 'Licores', 1900.00, 1097.4576, 2.00, 2.00, '860012986835', true, true, true, 26),
  ('8005713144258', 'ROMANA SAMBUVCA 75 CL', 'Licores', 1100.00, 705.2700, 0.00, 0.00, '8005713144258', true, true, true, 27),
  ('888', 'SOMETHING SPECIAL MINIATURA', 'Licores', 100.00, 62.5000, 0.00, 0.00, null, true, true, true, 28),
  ('7640171034058', 'WHISKY DEWARS CARRIBEAN SMOOTH', 'Licores', 1850.00, 1105.5700, 3.00, 3.00, '7640171034058', true, true, true, 29),
  ('8011822008220', '50 SFUMATURE PASSERINA BLANCO', 'Vinos y espumantes', 950.00, 450.0000, 3.00, 3.00, '8011822008220', true, true, true, 1),
  ('8437003674976', 'AROMAZ VINO DE LA TIERRA DE', 'Vinos y espumantes', 750.00, 317.6200, 0.00, 0.00, '8437003674976', true, true, true, 2),
  ('8436006393006', 'BRIEGO RESERVA', 'Vinos y espumantes', 2000.00, 1101.7000, 0.00, 0.00, '8436006393006', true, true, true, 3),
  ('7804330312108', 'CABERNET SAUVIGNON 375ML', 'Vinos y espumantes', 250.00, 165.0000, 0.00, 0.00, '7804330312108', true, true, true, 4),
  ('854620', 'CARLOS ROSSI BLUSH 3L', 'Vinos y espumantes', 1300.00, 211.8642, 0.00, 0.00, null, true, true, true, 5),
  ('8003030008819', 'CARUSO BLANCO', 'Vinos y espumantes', 450.00, 250.0000, 0.00, 0.00, '8003030008819', true, true, true, 6),
  ('8003030008826', 'CARUSO TINTO', 'Vinos y espumantes', 450.00, 250.0000, 0.00, 0.00, '8003030008826', true, true, true, 7),
  ('7804320303178', 'CASILLERO DEL DIABLO CARB-SA 750ML', 'Vinos y espumantes', 1200.00, 762.1300, 0.00, 0.00, '7804320303178', true, true, true, 8),
  ('7804320985633', 'CASILLERO DEL DIABLO MERLOT 750ML', 'Vinos y espumantes', 1150.00, 685.0000, 5.00, 5.00, '7804320985633', true, true, true, 9),
  ('7804320301174', 'CASILLERO DEL DIABLO SAV-BLAN', 'Vinos y espumantes', 650.00, 586.1600, 0.00, 0.00, '7804320301174', true, true, true, 10),
  ('7804320510170', 'CASILLERO DEL DIABLO SHIRAZ', 'Vinos y espumantes', 850.00, 550.0000, 0.00, 0.00, '7804320510170', true, true, true, 11),
  ('8420209032510', 'CASTILLO DE ROSSI', 'Vinos y espumantes', 600.00, 319.0000, 9.00, 9.00, '8420209032510', true, true, true, 12),
  ('8420209039007', 'CASTILLO DE ROSSI WHITE WINE', 'Vinos y espumantes', 650.00, 320.0000, 4.00, 4.00, '8420209039007', true, true, true, 13),
  ('8420209032527', 'CASTILLO ROSSI ROSADO', 'Vinos y espumantes', 650.00, 319.0000, 7.00, 7.00, '8420209032527', true, true, true, 14),
  ('8008513064016', 'CELEBRATION SPUMANTE ROSE', 'Vinos y espumantes', 350.00, 200.8200, 0.00, 0.00, '8008513064016', true, true, true, 15),
  ('7804330004614', 'COLECCION PRIVADA SANTA RITA', 'Vinos y espumantes', 700.00, 496.0000, 0.00, 0.00, '7804330004614', true, true, true, 16),
  ('7804320046044', 'CONCHA Y TORO CABERT 375ML', 'Vinos y espumantes', 180.00, 124.0000, 0.00, 0.00, '7804320046044', true, true, true, 17),
  ('7804320688480', 'CONCHA Y TORO CABERT 375ML', 'Vinos y espumantes', 210.00, 150.0000, 0.00, 0.00, '7804320688480', true, true, true, 18),
  ('7804320384382', 'CONCHA Y TORO SERIE RIBERAS GRAN', 'Vinos y espumantes', 1100.00, 733.3300, 0.00, 0.00, '7804320384382', true, true, true, 19),
  ('8012769232037', 'DOLCE GIULIETTA', 'Vinos y espumantes', 825.00, 488.7000, 0.00, 0.00, '8012769232037', true, true, true, 20),
  ('7804320520162', 'DULZINO MOSCATO 750 ML', 'Vinos y espumantes', 750.00, 305.4400, 0.00, 0.00, '7804320520162', true, true, true, 21),
  ('7804320523958', 'DULZINO ROSADO', 'Vinos y espumantes', 400.00, 304.1700, 0.00, 0.00, '7804320523958', true, true, true, 22),
  ('7804320574707', 'DULZINO SWEET RED', 'Vinos y espumantes', 450.00, 305.4383, 0.00, 0.00, '7804320574707', true, true, true, 23),
  ('8425021000068', 'ELEMENTOS TEMPRANILLO', 'Vinos y espumantes', 550.00, 325.0000, 0.00, 0.00, '8425021000068', true, true, true, 24),
  ('8425021000051', 'ELEMENTOS VINO BLANCO', 'Vinos y espumantes', 1000.00, 325.0000, 0.00, 0.00, '8425021000051', true, true, true, 25),
  ('8425021000075', 'ELEMENTOS VINO TIERRA TINTO', 'Vinos y espumantes', 800.00, 325.0000, 0.00, 0.00, '8425021000075', true, true, true, 26),
  ('7804345003145', 'FRESITA CHAMPAGNF 750ML', 'Vinos y espumantes', 615.00, 495.0000, 0.00, 0.00, '7804345003145', true, true, true, 27),
  ('7804345001882', 'FRESITA CHAMPAÑET 200ML', 'Vinos y espumantes', 250.00, 150.0000, 0.00, 0.00, '7804345001882', true, true, true, 28),
  ('7804320628165', 'FRONTERA AFTER MIDNIGHT CONCHA Y', 'Vinos y espumantes', 900.00, 529.9500, 5.00, 5.00, '7804320628165', true, true, true, 29),
  ('7804320559001', 'FRONTERA CABERNET SAUVIGNON', 'Vinos y espumantes', 900.00, 529.9500, 9.00, 9.00, '7804320559001', true, true, true, 30),
  ('7804320642277', 'FRONTERA CHARDONAL 750ML', 'Vinos y espumantes', 550.00, 325.0000, 1.00, 1.00, '7804320642277', true, true, true, 31),
  ('7804320706009', 'FRONTERA MERLOT 750ML', 'Vinos y espumantes', 750.00, 408.4745, 1.00, 1.00, '7804320706009', true, true, true, 32),
  ('7804320483115', 'FRONTERA MERLOT ROSE 750ML', 'Vinos y espumantes', 650.00, 368.6400, 0.00, 0.00, '7804320483115', true, true, true, 33),
  ('7804320556000', 'FRONTERA SAUVIGNON BLANCO 750ML', 'Vinos y espumantes', 600.00, 388.4100, 0.00, 0.00, '7804320556000', true, true, true, 34),
  ('7804320269160', 'FRONTERA SHIRAZ CONCHA Y TORO 750', 'Vinos y espumantes', 550.00, 350.0000, 0.00, 0.00, '7804320269160', true, true, true, 35),
  ('7804320626994', 'FRONTERA SWEET RED', 'Vinos y espumantes', 850.00, 475.0000, 4.00, 4.00, '7804320626994', true, true, true, 36),
  ('7804300010645', 'GATO BLANCO S. BLACK', 'Vinos y espumantes', 380.00, 253.0000, 0.00, 0.00, '7804300010645', true, true, true, 37),
  ('7804300010638', 'GATO NEGRO CABERNET SAUVIGÑON', 'Vinos y espumantes', 360.00, 240.0000, 0.00, 0.00, '7804300010638', true, true, true, 38),
  ('7804300120603', 'GATO NEGRO MERLOT', 'Vinos y espumantes', 380.00, 253.0000, 0.00, 0.00, '7804300120603', true, true, true, 39),
  ('7804300123697', 'GATO NEGRO SHIRAZ', 'Vinos y espumantes', 225.00, 150.0000, 0.00, 0.00, '7804300123697', true, true, true, 40),
  ('8414606856534', 'GIK LIVE VINO', 'Vinos y espumantes', 1100.00, 500.0000, 1.00, 1.00, '8414606856534', true, true, true, 41),
  ('8437007129984', 'GIMENEZ DE TAU TINTO', 'Vinos y espumantes', 800.00, 430.0000, 0.00, 0.00, '8437007129984', true, true, true, 42),
  ('8410351000000', 'GLORIOSO SELECCION ESPECIAL 100', 'Vinos y espumantes', 1500.00, 933.3333, 0.00, 0.00, '8410351000000', true, true, true, 43),
  ('8003030993177', 'ITRIGO NERO DE AVOLA', 'Vinos y espumantes', 850.00, 450.0000, 0.00, 0.00, '8003030993177', true, true, true, 44),
  ('8011822009975', 'KUNEN ROSSO CONERO', 'Vinos y espumantes', 750.00, 450.0000, 0.00, 0.00, '8011822009975', true, true, true, 45),
  ('8411079501930', 'LA GAITA SIDRA', 'Vinos y espumantes', 210.00, 127.1000, 0.00, 0.00, '8411079501930', true, true, true, 46),
  ('8411079381037', 'LA GAITA SIDRA ROSADA', 'Vinos y espumantes', 210.00, 127.1000, 0.00, 0.00, '8411079381037', true, true, true, 47),
  ('8410869450014', 'MARQUES DE RISCAL RIOJA RESERVAS', 'Vinos y espumantes', 2125.00, 1475.0000, 0.00, 0.00, '8410869450014', true, true, true, 48),
  ('8410869451240', 'MARQUEZ DEL RISCAL PROXIMO RIOJO', 'Vinos y espumantes', 800.00, 222.4583, 0.00, 0.00, '8410869451240', true, true, true, 49),
  ('8410866430019', 'MARQUEZ DEL RISCAL RUEDA BLANCO', 'Vinos y espumantes', 850.00, 531.0000, 0.00, 0.00, '8410866430019', true, true, true, 50),
  ('8410866430477', 'MARQUEZ DEL RISCAL TEMPRANILLO 750', 'Vinos y espumantes', 850.00, 572.0400, 0.00, 0.00, '8410866430477', true, true, true, 51),
  ('8001540002228', 'MASCHINO PROSECCO', 'Vinos y espumantes', 985.00, 655.0000, 0.00, 0.00, '8001540002228', true, true, true, 52),
  ('7804330121205', 'MEDLLA REAL GRAN RESERVA', 'Vinos y espumantes', 1525.00, 1016.0000, 0.00, 0.00, '7804330121205', true, true, true, 53),
  ('8414771620022', 'MIGUEL DE MARCH 750ML', 'Vinos y espumantes', 280.00, 186.5000, 0.00, 0.00, '8414771620022', true, true, true, 54),
  ('8412424325225', 'MONT-BLAU SEKT SIDRA', 'Vinos y espumantes', 250.00, 131.2500, 0.00, 0.00, '8412424325225', true, true, true, 55),
  ('7804449104014', 'MORANDE PIONERO CABERNET', 'Vinos y espumantes', 490.00, 301.7200, 0.00, 0.00, '7804449104014', true, true, true, 56),
  ('7804449104021', 'MORANDE PIONERO MERLOT', 'Vinos y espumantes', 495.00, 301.7200, 0.00, 0.00, '7804449104021', true, true, true, 57),
  ('7804449103017', 'MORANDE RESERVA CABERNET', 'Vinos y espumantes', 695.00, 452.5800, 0.00, 0.00, '7804449103017', true, true, true, 58),
  ('7804449103024', 'MORANDE RESERVA MERLOT 2009', 'Vinos y espumantes', 695.00, 452.5800, 0.00, 0.00, '7804449103024', true, true, true, 59),
  ('8414542100104', 'MUGA RESERVA', 'Vinos y espumantes', 2700.00, 1052.0000, 1.00, 1.00, '8414542100104', true, true, true, 60),
  ('7804320485515', 'PALO ALTO RESERV. MERLOT', 'Vinos y espumantes', 1000.00, null, 0.00, 0.00, '7804320485515', true, true, true, 61),
  ('8437008952147', 'PASION BLUE', 'Vinos y espumantes', 1000.00, 450.0000, 1.00, 1.00, '8437008952147', true, true, true, 62),
  ('8000428026257', 'PERLINO', 'Vinos y espumantes', 750.00, 432.0000, 0.00, 0.00, '8000428026257', true, true, true, 63),
  ('8420342001039', 'PROTOS CRIANZA 2004 750ML', 'Vinos y espumantes', 1700.00, 1420.8300, 0.00, 0.00, '8420342001039', true, true, true, 64),
  ('8420342001022', 'PROTOS RESERVAS 2009 RIVERA DEL', 'Vinos y espumantes', 3200.00, 2225.0000, 0.00, 0.00, '8420342001022', true, true, true, 65),
  ('8420342002012', 'PROTOS ROBLE RIVERA DUERO', 'Vinos y espumantes', 1300.00, 872.2050, 0.00, 0.00, '8420342002012', true, true, true, 66),
  ('8420342203013', 'PROTOS VERDEJO', 'Vinos y espumantes', 975.00, 626.6800, 0.00, 0.00, '8420342203013', true, true, true, 67),
  ('8420209040706', 'PYA RED BLEND', 'Vinos y espumantes', 780.00, 472.3800, 0.00, 0.00, '8420209040706', true, true, true, 68),
  ('80516130545', 'RIUNITE STRAWBERRY 750ML', 'Vinos y espumantes', 390.00, 260.0000, 0.00, 0.00, '080516130545', true, true, true, 69),
  ('7804350596366', 'SANTA CAROLINA BLANCO RESERVAS', 'Vinos y espumantes', 670.00, 468.2200, 0.00, 0.00, '7804350596366', true, true, true, 70),
  ('7804350600148', 'SANTA CAROLINA CABERNET S.375ML', 'Vinos y espumantes', 220.00, 182.0000, 0.00, 0.00, '7804350600148', true, true, true, 71),
  ('7804350596335', 'SANTA CAROLINA CABERNET S.750ML', 'Vinos y espumantes', 600.00, 470.8334, 0.00, 0.00, '7804350596335', true, true, true, 72),
  ('7804350600391', 'SANTA CAROLINA CABERNET S.MERL', 'Vinos y espumantes', 420.00, 240.1133, 0.00, 0.00, '7804350600391', true, true, true, 73),
  ('7804350701364', 'SANTA CAROLINA CABERNET SA-PQ', 'Vinos y espumantes', 160.00, 113.0000, 0.00, 0.00, '7804350701364', true, true, true, 74),
  ('7804350174700', 'SANTA CAROLINA CABERT-ROSE', 'Vinos y espumantes', 500.00, 338.9833, 0.00, 0.00, '7804350174700', true, true, true, 75),
  ('7804350600285', 'SANTA CAROLINA CARB SAUVIGNON', 'Vinos y espumantes', 230.00, 167.0000, 0.00, 0.00, '7804350600285', true, true, true, 76),
  ('7804350596342', 'SANTA CAROLINA CHARDONNAY', 'Vinos y espumantes', 430.00, 323.0000, 0.00, 0.00, '7804350596342', true, true, true, 77),
  ('7804350008661', 'SANTA CAROLINA GRA RESERVA', 'Vinos y espumantes', 1590.00, 961.8600, 0.00, 0.00, '7804350008661', true, true, true, 78),
  ('7804350600384', 'SANTA CAROLINA GRAN RESERVA 750ML', 'Vinos y espumantes', 1100.00, 866.6666, 0.00, 0.00, '7804350600384', true, true, true, 79),
  ('7804350701661', 'SANTA CAROLINA GRAN RESERVAS', 'Vinos y espumantes', 1200.00, 841.6667, 0.00, 0.00, '7804350701661', true, true, true, 80),
  ('7804350600353', 'SANTA CAROLINA MERLOT', 'Vinos y espumantes', 765.00, 462.5730, 3.00, 3.00, '7804350600353', true, true, true, 81),
  ('7804350000054', 'SANTA CAROLINA PREMIO 750 ML', 'Vinos y espumantes', 825.00, 448.0000, 6.00, 6.00, '7804350000054', true, true, true, 82),
  ('7804350000061', 'SANTA CAROLINA PREMIO BLANCO', 'Vinos y espumantes', 425.00, 308.3334, 2.00, 2.00, '7804350000061', true, true, true, 83),
  ('7804350596359', 'SANTA CAROLINA RESERVA CABERNET', 'Vinos y espumantes', 1050.00, 625.3500, 0.00, 0.00, '7804350596359', true, true, true, 84),
  ('7804350600070', 'SANTA CAROLINA S. B. SEMILLON', 'Vinos y espumantes', 475.00, 240.0000, 4.00, 4.00, '7804350600070', true, true, true, 85),
  ('7804350596328', 'SANTA CAROLINA SAUVIGNON BLANC', 'Vinos y espumantes', 450.00, 314.2650, 0.00, 0.00, '7804350596328', true, true, true, 86),
  ('7804350600155', 'SANTA CAROLINA SAUVIGNON BLANC', 'Vinos y espumantes', 195.00, 122.0000, 0.00, 0.00, '7804350600155', true, true, true, 87),
  ('7804350000528', 'SANTA CAROLINA SYRAH VARIETAL', 'Vinos y espumantes', 500.00, 378.5320, 0.00, 0.00, '7804350000528', true, true, true, 88),
  ('784350600391', 'SANTA CAROLINA VISTAÑA C.', 'Vinos y espumantes', 350.00, 258.6200, 0.00, 0.00, '784350600391', true, true, true, 89),
  ('7804350600360', 'SANTA CXAROLINA MERLOT RESERVA', 'Vinos y espumantes', 0.00, 446.1000, 0.00, 0.00, '7804350600360', true, false, false, 90),
  ('7804330983445', 'SANTA RITA 120 1/2 CABERNET', 'Vinos y espumantes', 200.00, 125.0000, 0.00, 0.00, '7804330983445', true, true, true, 91),
  ('7804330983438', 'SANTA RITA 120 1/2 SAUVIGNON BANC', 'Vinos y espumantes', 175.00, 460.4500, 0.00, 0.00, '7804330983438', true, true, true, 92),
  ('7804330321209', 'SANTA RITA 120 SAUVIGNON BLANC', 'Vinos y espumantes', 900.00, 549.9300, 0.00, 0.00, '7804330321209', true, true, true, 93),
  ('7804330311101', 'SANTA RITA CABERNET SAUVIGNON', 'Vinos y espumantes', 1050.00, 623.4600, 5.00, 5.00, '7804330311101', true, true, true, 94),
  ('7804330351206', 'SANTA RITA CHARDONNAY 750ML', 'Vinos y espumantes', 495.00, 349.5766, 0.00, 0.00, '7804330351206', true, true, true, 95),
  ('7804330111107', 'SANTA RITA MEDALLA REAL 750ML', 'Vinos y espumantes', 1450.00, 965.7483, 0.00, 0.00, '7804330111107', true, true, true, 96),
  ('7804330341108', 'SANTA RITA MERLOT 750ML', 'Vinos y espumantes', 950.00, 549.9300, 2.00, 2.00, '7804330341108', true, true, true, 97),
  ('7804330221202', 'SANTA RITA RESERVA BLANCO 750ML', 'Vinos y espumantes', 1300.00, 670.9042, 0.00, 0.00, '7804330221202', true, true, true, 98),
  ('7804330211104', 'SANTA RITA RESERVA CABERT 750M', 'Vinos y espumantes', 1300.00, 840.0000, 0.00, 0.00, '7804330211104', true, true, true, 99),
  ('7804330001835', 'SANTA RITA RESERVA SYRAH 750ML', 'Vinos y espumantes', 1100.00, 681.6700, 0.00, 0.00, '7804330001835', true, true, true, 100),
  ('7804330212101', 'SANTA RITA RESERVAS CAVERNET', 'Vinos y espumantes', 1100.00, 681.6700, 0.00, 0.00, '7804330212101', true, true, true, 101),
  ('7804330211203', 'SANTA RITA RESERVAS-MERLOT 750ML', 'Vinos y espumantes', 1050.00, 681.6700, 0.00, 0.00, '7804330211203', true, true, true, 102),
  ('7804330361106', 'SANTA RITA ROSADO CABERT 750ML', 'Vinos y espumantes', 800.00, 456.7700, 0.00, 0.00, '7804330361106', true, true, true, 103),
  ('7804330322206', 'SANTA RITA SAUVIGNON BLANC 375ML', 'Vinos y espumantes', 195.00, 130.0000, 0.00, 0.00, '7804330322206', true, true, true, 104),
  ('7804330001088', 'SANTA RITA SHIRAZ 750ML', 'Vinos y espumantes', 350.00, 230.0000, 0.00, 0.00, '7804330001088', true, true, true, 105),
  ('7804330006724', 'SANTA RITA TRES MEDALLAS', 'Vinos y espumantes', 570.00, 385.0000, 0.00, 0.00, '7804330006724', true, true, true, 106),
  ('7804330006717', 'SANTA RITA TRES MEDALLAS CABERNET', 'Vinos y espumantes', 670.00, 385.0000, 0.00, 0.00, '7804330006717', true, true, true, 107),
  ('8004385032207', 'SANTEROFRAGOLA', 'Vinos y espumantes', 750.00, 486.0000, 0.00, 0.00, '8004385032207', true, true, true, 108),
  ('8410428330047', 'SEGURA VIUDA RESERVA CAVA', 'Vinos y espumantes', 1050.00, 935.0000, 0.00, 0.00, '8410428330047', true, true, true, 109),
  ('8411079391012', 'SIDRA EL GAITERO 70CL', 'Vinos y espumantes', 160.00, 102.5000, 0.00, 0.00, '8411079391012', true, true, true, 110),
  ('8413481014206', 'SIDRA EL MAYU MANZANA ROSEE', 'Vinos y espumantes', 175.00, 91.8083, 0.00, 0.00, '8413481014206', true, true, true, 111),
  ('8410635004014', 'SIDRA JAI-ALAI', 'Vinos y espumantes', 225.00, 154.1666, 0.00, 0.00, '8410635004014', true, true, true, 112),
  ('8410635001013', 'SIDRA JAI-ALAI 25ML', 'Vinos y espumantes', 50.00, 20.0000, 0.00, 0.00, '8410635001013', true, true, true, 113),
  ('8011822007032', 'SOLEIL ROSADO', 'Vinos y espumantes', 650.00, 300.0000, 1.00, 1.00, '8011822007032', true, true, true, 114),
  ('8011822009036', 'SOLEIL TINTO', 'Vinos y espumantes', 650.00, 300.0000, 4.00, 4.00, '8011822009036', true, true, true, 115),
  ('8008513003756', 'SPERONE CHILL ESPUMANTE', 'Vinos y espumantes', 550.00, 347.6725, 0.00, 0.00, '8008513003756', true, true, true, 116),
  ('8008513008058', 'SPERONE CHILL ESPUMANTE ROSE', 'Vinos y espumantes', 550.00, 347.6725, 0.00, 0.00, '8008513008058', true, true, true, 117),
  ('8008513008485', 'SPRITZ APERITIVO', 'Vinos y espumantes', 755.00, 457.3100, 0.00, 0.00, '8008513008485', true, true, true, 118),
  ('8003030991418', 'SYRAH SICILIANO', 'Vinos y espumantes', 950.00, 325.0000, 2.00, 2.00, '8003030991418', true, true, true, 119),
  ('8437015144115', 'TAOZ RESERVA', 'Vinos y espumantes', 950.00, 550.0000, 0.00, 0.00, '8437015144115', true, true, true, 120),
  ('8437015144306', 'TAOZ ROSADO', 'Vinos y espumantes', 900.00, 495.0000, 0.00, 0.00, '8437015144306', true, true, true, 121),
  ('8410702010344', 'VALDEPLATA CABERNET SAUVIGNON', 'Vinos y espumantes', 225.00, 112.7688, 0.00, 0.00, '8410702010344', true, true, true, 122),
  ('8410702010399', 'VALDEPLATA VINO', 'Vinos y espumantes', 395.00, 300.0000, 0.00, 0.00, '8410702010399', true, true, true, 123),
  ('8424718113111', 'VALDRUERO CRIANZA 750ML', 'Vinos y espumantes', 1400.00, 827.0000, 0.00, 0.00, '8424718113111', true, true, true, 124),
  ('8427894026503', 'VEGA ROBLEDO RED', 'Vinos y espumantes', 450.00, 264.1200, 1.00, 1.00, '8427894026503', true, true, true, 125),
  ('8427894026497', 'VEGA ROBLEDO ROSA', 'Vinos y espumantes', 450.00, 264.1200, 1.00, 1.00, '8427894026497', true, true, true, 126),
  ('8427021000352', 'VEGADULCE CAVA', 'Vinos y espumantes', 550.00, 311.0000, 1.00, 1.00, '8427021000352', true, true, true, 127),
  ('8413004050117', 'VERRUGON ROSADO VINO 750ML', 'Vinos y espumantes', 495.00, 130.0000, 0.00, 0.00, '8413004050117', true, true, true, 128),
  ('8437007129953', 'VICIOUS 2020 BLANCO 750ML', 'Vinos y espumantes', 1600.00, 944.0000, 1.00, 1.00, '8437007129953', true, true, true, 129),
  ('8437007129939', 'VICIOUS 2020 TINTO 750ML', 'Vinos y espumantes', 2100.00, 1020.0000, 1.00, 1.00, '8437007129939', true, true, true, 130),
  ('8004385030395', 'VILLA JOLANDA', 'Vinos y espumantes', 930.00, 630.0000, 0.00, 0.00, '8004385030395', true, true, true, 131),
  ('796020310501', 'VINO MOSCATEL CABALLO BLANCO', 'Vinos y espumantes', 160.00, 106.2500, 0.00, 0.00, '796020310501', true, true, true, 132),
  ('8410388003531', 'VINO MURVIEDRO COLECCION PETIT', 'Vinos y espumantes', 800.00, 532.6500, 2.00, 2.00, '8410388003531', true, true, true, 133),
  ('7804320288826', 'VINO PALO ALTO BLANCO', 'Vinos y espumantes', 900.00, 529.6600, 0.00, 0.00, '7804320288826', true, true, true, 134),
  ('7804320214085', 'VINO PALO ALTO CABERNET SAUVIGNON', 'Vinos y espumantes', 900.00, 533.1900, 0.00, 0.00, '7804320214085', true, true, true, 135),
  ('818838009818', 'VINO TETICA CABERNET SAUVIGNON', 'Vinos y espumantes', 1100.00, 516.9491, 3.00, 3.00, '818838009818', true, true, true, 136),
  ('818838009825', 'VINO TETICA MERLOT', 'Vinos y espumantes', 1100.00, 516.9491, 3.00, 3.00, '818838009825', true, true, true, 137),
  ('8420209028520', 'VIRTUOSO CABERNET SAUVIGNON', 'Vinos y espumantes', 300.00, 167.7500, 0.00, 0.00, '8420209028520', true, true, true, 138),
  ('8420209028506', 'VIRTUOSO CHARDONAY', 'Vinos y espumantes', 300.00, 167.7500, 0.00, 0.00, '8420209028506', true, true, true, 139),
  ('8420209028537', 'VIRTUOSO MERLOT', 'Vinos y espumantes', 300.00, 167.7500, 0.00, 0.00, '8420209028537', true, true, true, 140);

-- filas 201–400
insert into _p007 (codigo, name, categoria, price, cost, qty, qty_listado, barcode, is_bev, activo, inventariable, posicion) values
  ('8420209028513', 'VIRTUOSO TEMPRANILLO ROSADO', 'Vinos y espumantes', 300.00, 167.7500, 0.00, 0.00, '8420209028513', true, true, true, 141),
  ('7804320169699', 'VIÑA MAIPO MERLOT', 'Vinos y espumantes', 425.00, 275.2600, 0.00, 0.00, '7804320169699', true, true, true, 142),
  ('7804320063010', 'VIÑA MAIPO SAUVIGNON', 'Vinos y espumantes', 650.00, 388.0000, 0.00, 0.00, '7804320063010', true, true, true, 143),
  ('839743001483', 'YELLOW BIG BOLD RED', 'Vinos y espumantes', 850.00, 585.0043, 0.00, 0.00, '839743001483', true, true, true, 144),
  ('764009045577', 'ADAN Y EVA FRUTO ROJOS', 'Premix y cócteles', 140.00, 76.9800, 0.00, 0.00, '764009045577', true, true, true, 1),
  ('764009024497', 'BAMBBOO DAIQUIRI FRESA 350.ML', 'Premix y cócteles', 150.00, 81.4900, 0.00, 0.00, '764009024497', true, true, true, 2),
  ('764009011671', 'BAMBBOO MOJITO 350.ML', 'Premix y cócteles', 150.00, 81.4900, 0.00, 0.00, '764009011671', true, true, true, 3),
  ('764009047984', 'BAMBOO PIÑA COLADA .350.ML', 'Premix y cócteles', 150.00, 81.4900, 0.00, -1.00, '764009047984', true, true, true, 4),
  ('850035474082', 'BUZZ BALK CHILI MANGO', 'Premix y cócteles', 310.00, 172.1398, 2.00, 2.00, '850035474082', true, true, true, 5),
  ('850035474037', 'BUZZ BALK CHOC TEASE', 'Premix y cócteles', 310.00, 172.1398, 21.00, 21.00, '850035474037', true, true, true, 6),
  ('850035474068', 'BUZZ BALK ESPRESO MARTINI', 'Premix y cócteles', 310.00, 172.1398, 22.00, 22.00, '850035474068', true, true, true, 7),
  ('850035474051', 'BUZZ BALK LOTTA COLADA', 'Premix y cócteles', 310.00, 172.1398, 27.00, 27.00, '850035474051', true, true, true, 8),
  ('850035474464', 'BUZZ BALK PASSIONFRUIT MARTINI', 'Premix y cócteles', 310.00, 172.1398, 25.00, 25.00, '850035474464', true, true, true, 9),
  ('850035474105', 'BUZZ BALK STRAWBERRY RITA', 'Premix y cócteles', 310.00, 172.1398, 0.00, -3.00, '850035474105', true, true, true, 10),
  ('850035474006', 'BUZZ BALK TEQUILA RITA', 'Premix y cócteles', 310.00, 172.1398, 26.00, 26.00, '850035474006', true, true, true, 11),
  ('849806002319', 'FOUR LOKO BLUE', 'Premix y cócteles', 360.00, 204.0960, 0.00, 0.00, '849806002319', true, true, true, 12),
  ('849806001756', 'FOUR LOKO GOLD', 'Premix y cócteles', 360.00, 204.0960, 1.00, 1.00, '849806001756', true, true, true, 13),
  ('849806001855', 'FOUR LOKO GREEN', 'Premix y cócteles', 360.00, 204.0960, 7.00, 7.00, '849806001855', true, true, true, 14),
  ('849806003859', 'FOUR LOKO MANGO', 'Premix y cócteles', 320.00, 190.6700, 0.00, 0.00, '849806003859', true, true, true, 15),
  ('849806004962', 'FOUR LOKO MARACUYA', 'Premix y cócteles', 360.00, 204.0960, 4.00, 4.00, '849806004962', true, true, true, 16),
  ('849806001220', 'FOUR LOKO PONCHE DE FRUTAS', 'Premix y cócteles', 360.00, 204.0960, 2.00, 2.00, '849806001220', true, true, true, 17),
  ('849806002746', 'FOUR LOKO PURPLE', 'Premix y cócteles', 360.00, 204.0960, 0.00, 0.00, '849806002746', true, true, true, 18),
  ('849806001206', 'FOUR LOKO SANDIA', 'Premix y cócteles', 360.00, 204.0960, 2.00, 2.00, '849806001206', true, true, true, 19),
  ('849806005754', 'FOUR LOKO WHITE', 'Premix y cócteles', 360.00, 204.0960, 0.00, 0.00, '849806005754', true, true, true, 20),
  ('7898605253012', 'MIKES JUGO DE LIMON Y VODKA', 'Premix y cócteles', 120.00, 56.6500, 1.00, 1.00, '7898605253012', true, true, true, 21),
  ('780380', '7UP LATA', 'Refrescos y energizantes', 55.00, 28.2400, 0.00, 0.00, null, true, true, true, 1),
  ('830207000707', 'CICLON GRANDE', 'Refrescos y energizantes', 150.00, 87.5700, 2.00, 2.00, '830207000707', true, true, true, 2),
  ('830207010706', 'CICLON PEQUENO', 'Refrescos y energizantes', 115.00, 67.0903, 31.00, 31.00, '830207010706', true, true, true, 3),
  ('830207000301', 'CICLON X2 16.6 ONZ GRANDE', 'Refrescos y energizantes', 160.00, 91.8079, 37.00, 37.00, '830207000301', true, true, true, 4),
  ('815934000107', 'COCO RICO 12OZ LATA', 'Refrescos y energizantes', 45.00, 17.3400, 0.00, 0.00, '815934000107', true, true, true, 5),
  ('789120', 'CRUSH GRAPE REFRESCO LATA', 'Refrescos y energizantes', 35.00, 21.5833, 0.00, 0.00, null, true, true, true, 6),
  ('783150', 'DR PEPPER 12 OZ. LATA', 'Refrescos y energizantes', 70.00, 40.9600, 0.00, -1.00, null, true, true, true, 7),
  ('790330050508', 'FIRE ENERGY UP. DRINK', 'Refrescos y energizantes', 50.00, 20.0000, 0.00, 0.00, '790330050508', true, true, true, 8),
  ('8053626292788', 'GO & FUN GREEN ENERGY DRINK', 'Refrescos y energizantes', 80.00, 58.0000, 0.00, 0.00, '8053626292788', true, true, true, 9),
  ('7702090048643', 'HATSU SODA FRAMBUESA Y ROSAS', 'Refrescos y energizantes', 100.00, 1.0000, 0.00, 0.00, '7702090048643', true, true, true, 10),
  ('784000', 'HAWALLAN PUNCH LATA 333OZ', 'Refrescos y energizantes', 35.00, 19.4210, 0.00, 0.00, null, true, true, true, 11),
  ('831384000504', 'MABI TAINO SEYBANO', 'Refrescos y energizantes', 30.00, 17.0000, 0.00, 0.00, '831384000504', true, true, true, 12),
  ('7702354251673', 'PREDATOR MANZANA', 'Refrescos y energizantes', 65.00, 33.8985, 0.00, 0.00, '7702354251673', true, true, true, 13),
  ('7702354251666', 'PREDATOR ORIGINAL', 'Refrescos y energizantes', 65.00, 27.1187, 0.00, 0.00, '7702354251666', true, true, true, 14),
  ('850003560410', 'PRIME LIME', 'Refrescos y energizantes', 375.00, 200.0000, 0.00, 0.00, '850003560410', true, true, true, 15),
  ('850003560441', 'PRIME PUNCH', 'Refrescos y energizantes', 375.00, 200.0000, 0.00, 0.00, '850003560441', true, true, true, 16),
  ('850003560458', 'PRIME RASPBERRY', 'Refrescos y energizantes', 375.00, 200.0000, 0.00, 0.00, '850003560458', true, true, true, 17),
  ('9002490212148', 'RED BULL 12.ONZ', 'Refrescos y energizantes', 175.00, 99.0000, 99.00, 99.00, '9002490212148', true, true, true, 18),
  ('9002490291709', 'RED BULL COCO 250.M.L', 'Refrescos y energizantes', 120.00, 69.0000, 15.00, 15.00, '9002490291709', true, true, true, 19),
  ('9002490267544', 'RED BULL GRANDE.16 ONZ', 'Refrescos y energizantes', 240.00, 133.1300, 30.00, 30.00, '9002490267544', true, true, true, 20),
  ('9002490204006', 'RED BULL MEDIANO 8 OZ', 'Refrescos y energizantes', 120.00, 69.0000, 0.00, -4.00, '9002490204006', true, true, true, 21),
  ('9002490266288', 'RED BULL ROJO.250.M.L', 'Refrescos y energizantes', 120.00, 69.0000, 5.00, 5.00, '9002490266288', true, true, true, 22),
  ('9002490206710', 'RED BULL SUGARFREE.250.M.L', 'Refrescos y energizantes', 120.00, 69.0000, 16.00, 16.00, '9002490206710', true, true, true, 23),
  ('9002490268657', 'RED BULL TROPICAL.250.M.L', 'Refrescos y energizantes', 120.00, 69.0000, 30.00, 30.00, '9002490268657', true, true, true, 24),
  ('84233299812184', 'REFRESCOS VARIADOS 20 ONZ', 'Refrescos y energizantes', 35.00, 22.0000, 0.00, 0.00, '84233299812184', true, true, true, 25),
  ('78250004321', 'SPARKS PLUS ENERGISANTE NARANJA', 'Refrescos y energizantes', 100.00, 76.0000, 0.00, 0.00, '078250004321', true, true, true, 26),
  ('782740', 'SUNKIST NARANJA', 'Refrescos y energizantes', 35.00, 19.4210, 0.00, 0.00, null, true, true, true, 27),
  ('782850', 'SUNKIST UVA', 'Refrescos y energizantes', 35.00, 19.4210, 0.00, 0.00, null, true, true, true, 28),
  ('7702354253776', 'VIVE.100.ROJO.GRANDE', 'Refrescos y energizantes', 70.00, 40.8333, 0.00, -10.00, '7702354253776', true, true, true, 29),
  ('7702354253769', 'VIVE.100.VERDE.GRANDE', 'Refrescos y energizantes', 70.00, 40.8333, 32.00, 32.00, '7702354253769', true, true, true, 30),
  ('859710000011', 'XS ENERGY DRINK CITRUS BLAST', 'Refrescos y energizantes', 190.00, 91.7650, 0.00, 0.00, '859710000011', true, true, true, 31),
  ('859710000004', 'XS ENERGY DRINK CRANBERRY GRAPE', 'Refrescos y energizantes', 190.00, 91.7645, 0.00, 0.00, '859710000004', true, true, true, 32),
  ('893504860702', 'AGUA DE COCO CON PULPA', 'Jugos, tés y lácteos', 125.00, 75.0000, 0.00, 0.00, '893504860702', true, true, true, 1),
  ('893504860696', 'AGUA DE COCO ORIGINAL', 'Jugos, tés y lácteos', 125.00, 75.0000, 0.00, 0.00, '893504860696', true, true, true, 2),
  ('8809125063011', 'ALOE PURE PLUS', 'Jugos, tés y lácteos', 140.00, 42.3733, 0.00, 0.00, '8809125063011', true, true, true, 3),
  ('884394007391', 'ALOE STRAWBERRY', 'Jugos, tés y lácteos', 140.00, 77.1185, 28.00, 28.00, '884394007391', true, true, true, 4),
  ('884394007285', 'ALOE VERA ORIGINAL 500ML', 'Jugos, tés y lácteos', 140.00, 66.7375, 36.00, 36.00, '884394007285', true, true, true, 5),
  ('884394007377', 'ALOE VERAS PIÑA 500 ML', 'Jugos, tés y lácteos', 140.00, 77.1185, 39.00, 39.00, '884394007377', true, true, true, 6),
  ('8936020049793', 'CHIA PASSION FRUIT', 'Jugos, tés y lácteos', 80.00, 46.8140, 0.00, 0.00, '8936020049793', true, true, true, 7),
  ('8936020049786', 'CHIA STRABERRY', 'Jugos, tés y lácteos', 80.00, 46.8134, 0.00, 0.00, '8936020049786', true, true, true, 8),
  ('790330008080', 'CHOCO RICA 10 OZ', 'Jugos, tés y lácteos', 40.00, 22.8800, 0.00, -5.00, '790330008080', true, true, true, 9),
  ('790330008028', 'CHOCO RICA 16 ONZ', 'Jugos, tés y lácteos', 60.00, 33.0500, 0.00, 0.00, '790330008028', true, true, true, 10),
  ('790330004587', 'CHOCO RICA 500', 'Jugos, tés y lácteos', 70.00, 41.2800, 0.00, -1.00, '790330004587', true, true, true, 11),
  ('790330002323', 'CHOCORICA 200 ML', 'Jugos, tés y lácteos', 40.00, 21.9900, 59.00, 59.00, '790330002323', true, true, true, 12),
  ('884394000538', 'COCONUT DRINK COCO ORIGINAL 16.9', 'Jugos, tés y lácteos', 90.00, 55.5000, 0.00, 0.00, '884394000538', true, true, true, 13),
  ('7703186031303', 'ENSURE ADVANCE CHOCOLATE', 'Jugos, tés y lácteos', 215.00, 130.0000, 0.00, 0.00, '7703186031303', true, true, true, 14),
  ('8710428019509', 'ENSURE VAINILLAS', 'Jugos, tés y lácteos', 160.00, 96.0400, 0.00, 0.00, '8710428019509', true, true, true, 15),
  ('8410635024029', 'EVA WHITE GRAPE JUICE', 'Jugos, tés y lácteos', 250.00, 191.2222, 0.00, 0.00, '8410635024029', true, true, true, 16),
  ('7707362397672', 'HATSU TE AMARILLO', 'Jugos, tés y lácteos', 135.00, 81.9100, 0.00, 0.00, '7707362397672', true, true, true, 17),
  ('7709990350463', 'HATSU TE AZUL', 'Jugos, tés y lácteos', 135.00, 81.9100, 0.00, 0.00, '7709990350463', true, true, true, 18),
  ('7707362390079', 'HATSU TE BLANCO', 'Jugos, tés y lácteos', 135.00, 81.9100, 0.00, 0.00, '7707362390079', true, true, true, 19),
  ('7709990350470', 'HATSU TE ROSAS', 'Jugos, tés y lácteos', 135.00, 81.9100, 0.00, 0.00, '7709990350470', true, true, true, 20),
  ('790330021461', 'JUGO DE NARANJA DE LA GRANJA', 'Jugos, tés y lácteos', 35.00, 18.7800, 0.00, 0.00, '790330021461', true, true, true, 21),
  ('790330021454', 'JUGO DE NARANJA DE LA GRANJA 10OZ', 'Jugos, tés y lácteos', 20.00, 12.5300, 0.00, 0.00, '790330021454', true, true, true, 22),
  ('8687', 'KOOL-AID JUGO VARIADO CON SOLVETE', 'Jugos, tés y lácteos', 35.00, 19.0600, 0.00, 0.00, null, true, true, true, 23),
  ('790330002118', 'LA VAQUITA 16 ONZ', 'Jugos, tés y lácteos', 30.00, 18.0000, 0.00, 0.00, '790330002118', true, true, true, 24),
  ('790330021584', 'LIMONADA RICA 16 OZ', 'Jugos, tés y lácteos', 55.00, 31.1100, 0.00, 0.00, '790330021584', true, true, true, 25),
  ('87328431846', 'LOTUS DE CRAMBERRY 64 ONZ', 'Jugos, tés y lácteos', 180.00, 133.5700, 0.00, 0.00, '087328431846', true, true, true, 26),
  ('876063005951', 'MUSCLE MILK', 'Jugos, tés y lácteos', 220.00, 141.6666, 0.00, 0.00, '876063005951', true, true, true, 27),
  ('876063005968', 'MUSCLE MILK', 'Jugos, tés y lácteos', 220.00, 141.6666, 0.00, 0.00, '876063005968', true, true, true, 28),
  ('876063002035', 'MUSCLE MILK BANANA CREME', 'Jugos, tés y lácteos', 190.00, 141.6666, 0.00, 0.00, '876063002035', true, true, true, 29),
  ('876063002011', 'MUSCLE MILK CHOCOLATE 14 OZ', 'Jugos, tés y lácteos', 260.00, 158.3300, 0.00, 0.00, '876063002011', true, true, true, 30),
  ('876063002042', 'MUSCLE MILK COOKIES N CREME', 'Jugos, tés y lácteos', 260.00, 158.3300, 0.00, 0.00, '876063002042', true, true, true, 31),
  ('876063002028', 'MUSCLE MILK VAINILLA', 'Jugos, tés y lácteos', 260.00, 158.3300, 0.00, 0.00, '876063002028', true, true, true, 32),
  ('790330005096', 'NARANJA PIÑA', 'Jugos, tés y lácteos', 100.00, 56.9300, 0.00, 0.00, '790330005096', true, true, true, 33),
  ('790330050676', 'NECTAR MANGO', 'Jugos, tés y lácteos', 30.00, 16.1800, 0.00, 0.00, '790330050676', true, true, true, 34),
  ('786273040041', 'PARADISE NECTAR DE MANZANA LATA', 'Jugos, tés y lácteos', 30.00, 15.0000, 0.00, 0.00, '786273040041', true, true, true, 35),
  ('786273040034', 'PARADISE NECTAR DE PERA LATA', 'Jugos, tés y lácteos', 30.00, 15.0000, 0.00, 0.00, '786273040034', true, true, true, 36),
  ('8710428020215', 'PEDIASURE POTE VAINILLA', 'Jugos, tés y lácteos', 160.00, 97.4500, 0.00, 0.00, '8710428020215', true, true, true, 37),
  ('888849008100', 'QUEST CHOCOLATE PROTEINA LIQUIDO', 'Jugos, tés y lácteos', 380.00, 203.0000, 7.00, 7.00, '888849008100', true, true, true, 38),
  ('888849014460', 'QUEST PROTEIN SHAKE', 'Jugos, tés y lácteos', 340.00, 203.0000, 6.00, 6.00, '888849014460', true, true, true, 39),
  ('888849008117', 'QUEST PROTEIN VAINILLA', 'Jugos, tés y lácteos', 380.00, 203.0000, 3.00, 3.00, '888849008117', true, true, true, 40),
  ('790330050614', 'RICA COCTEL DE NECTARES', 'Jugos, tés y lácteos', 30.00, 16.1800, 1.00, 1.00, '790330050614', true, true, true, 41),
  ('790330021256', 'RICA DE PERA 10 OZ', 'Jugos, tés y lácteos', 30.00, 16.9300, 0.00, -3.00, '790330021256', true, true, true, 42),
  ('790330021249', 'RICA DE PERA 16 ONZ', 'Jugos, tés y lácteos', 50.00, 28.0500, 20.00, 20.00, '790330021249', true, true, true, 43),
  ('790330030029', 'RICA FRUIT PUNCH 1/2 GALON', 'Jugos, tés y lácteos', 170.00, 102.0000, 7.00, 7.00, '790330030029', true, true, true, 44),
  ('790330021263', 'RICA FRUIT PUNCH 32 OZ', 'Jugos, tés y lácteos', 90.00, 54.0800, 7.00, 7.00, '790330021263', true, true, true, 45),
  ('790330050669', 'RICA FRUIT PUNCH CON SOLVETE 10 OZ', 'Jugos, tés y lácteos', 30.00, 16.1800, 136.00, 136.00, '790330050669', true, true, true, 46),
  ('790330021270', 'RICA FRUIT PUNCH ONZ 16 ONZ', 'Jugos, tés y lácteos', 50.00, 28.0500, 60.00, 60.00, '790330021270', true, true, true, 47),
  ('790330050058', 'RICA GUAYABA', 'Jugos, tés y lácteos', 90.00, 52.5400, 0.00, 0.00, '790330050058', true, true, true, 48),
  ('79033050072', 'RICA JUGO DE MANZANA LITRO', 'Jugos, tés y lácteos', 85.00, 52.5400, 0.00, -1.00, null, true, true, true, 49),
  ('790330050645', 'RICA KIWI FRESA', 'Jugos, tés y lácteos', 30.00, 16.1800, 11.00, 11.00, '790330050645', true, true, true, 50),
  ('790330005003', 'RICA MANZANA 1.5 LITRO', 'Jugos, tés y lácteos', 160.00, 116.0000, 0.00, 0.00, '790330005003', true, true, true, 51),
  ('790330021188', 'RICA MANZANA 10 OZ', 'Jugos, tés y lácteos', 30.00, 16.9300, 16.00, 16.00, '790330021188', true, true, true, 52),
  ('790330021171', 'RICA MANZANA 16 ONZ', 'Jugos, tés y lácteos', 45.00, 28.0500, 47.00, 47.00, '790330021171', true, true, true, 53),
  ('790330005300', 'RICA MANZANA 1LITRO', 'Jugos, tés y lácteos', 115.00, 65.2500, 0.00, 0.00, '790330005300', true, true, true, 54),
  ('790330050621', 'RICA MANZANA 250 ML.', 'Jugos, tés y lácteos', 30.00, 16.1800, 22.00, 22.00, '790330050621', true, true, true, 55),
  ('790330021164', 'RICA MANZANA 32 OZ', 'Jugos, tés y lácteos', 80.00, 49.0000, 0.00, 0.00, '790330021164', true, true, true, 56),
  ('790330050386', 'RICA MANZANA 500ML', 'Jugos, tés y lácteos', 50.00, 28.8100, 0.00, 0.00, '790330050386', true, true, true, 57),
  ('790330030012', 'RICA MANZANA 64 ONZ', 'Jugos, tés y lácteos', 150.00, 91.5200, 0.00, 0.00, '790330030012', true, true, true, 58),
  ('790330050072', 'RICA MANZANA LITRO', 'Jugos, tés y lácteos', 90.00, 52.5400, 0.00, 0.00, '790330050072', true, true, true, 59),
  ('790330021973', 'RICA MANZANA SIN AZUCAR', 'Jugos, tés y lácteos', 45.00, 43.2200, 0.00, -1.00, '790330021973', true, true, true, 60),
  ('790330021126', 'RICA NARANJA %100 SIN AZUCAR 32 OZ', 'Jugos, tés y lácteos', 170.00, 100.3100, 9.00, 9.00, '790330021126', true, true, true, 61),
  ('790330021003', 'RICA NARANJA 10 OZ', 'Jugos, tés y lácteos', 35.00, 21.5800, 0.00, -4.00, '790330021003', true, true, true, 62),
  ('790330021225', 'RICA NARANJA 100 % SIN AZUCAR 1/2', 'Jugos, tés y lácteos', 320.00, 193.8500, 8.00, 8.00, '790330021225', true, true, true, 63),
  ('790330021089', 'RICA NARANJA 100% 16 ONZ', 'Jugos, tés y lácteos', 75.00, 44.1500, 14.00, 14.00, '790330021089', true, true, true, 64),
  ('790330021133', 'RICA NARANJA 100% 296 ML', 'Jugos, tés y lácteos', 55.00, 28.3600, 0.00, -2.00, '790330021133', true, true, true, 65),
  ('790330021119', 'RICA NARANJA 100% C/A', 'Jugos, tés y lácteos', 275.00, 163.3400, 5.00, 5.00, '790330021119', true, true, true, 66),
  ('790330021072', 'RICA NARANJA 100/% 32 OZ', 'Jugos, tés y lácteos', 140.00, 84.2100, 10.00, 10.00, '790330021072', true, true, true, 67),
  ('790330004655', 'RICA NARANJA 200ML SIN AZUCAR', 'Jugos, tés y lácteos', 40.00, 19.0100, 0.00, -1.00, '790330004655', true, true, true, 68),
  ('790330004600', 'RICA NARANJA 33.8', 'Jugos, tés y lácteos', 150.00, 90.6800, 0.00, 0.00, '790330004600', true, true, true, 69),
  ('790330004617', 'RICA NARANJA 33.8 OZ SIN AZUCAR', 'Jugos, tés y lácteos', 130.00, 66.3900, 0.00, 0.00, '790330004617', true, true, true, 70),
  ('790330005133', 'RICA NARANJA BANANA', 'Jugos, tés y lácteos', 100.00, 56.9300, 0.00, 0.00, '790330005133', true, true, true, 71),
  ('790330021805', 'RICA NARANJA BANANA', 'Jugos, tés y lácteos', 40.00, 26.6600, 0.00, 0.00, '790330021805', true, true, true, 72),
  ('790330051109', 'RICA NARANJA BANANA SORBETE', 'Jugos, tés y lácteos', 35.00, 21.1900, 0.00, 0.00, '790330051109', true, true, true, 73),
  ('790330005171', 'RICA NARANJA CHINOLA LT PLASTICO', 'Jugos, tés y lácteos', 140.00, 72.0300, 0.00, 0.00, '790330005171', true, true, true, 74),
  ('790330021027', 'RICA NARANJA DEL CAMPO', 'Jugos, tés y lácteos', 60.00, 32.2900, 26.00, 26.00, '790330021027', true, true, true, 75),
  ('790330021898', 'RICA NARANJA PINA', 'Jugos, tés y lácteos', 70.00, 43.2200, 0.00, 0.00, '790330021898', true, true, true, 76),
  ('790330021140', 'RICA NARANJA SIN AZUCAR 16 OZ', 'Jugos, tés y lácteos', 85.00, 51.7800, 62.00, 62.00, '790330021140', true, true, true, 77),
  ('790330021157', 'RICA NARANJA SIN AZUCAR PEQ.', 'Jugos, tés y lácteos', 55.00, 32.6000, 0.00, -1.00, '790330021157', true, true, true, 78),
  ('790330050065', 'RICA NECTAR DE GUAYABA', 'Jugos, tés y lácteos', 20.00, 11.4800, 0.00, 0.00, '790330050065', true, true, true, 79),
  ('790330050607', 'RICA NECTAR DE GUAYABA', 'Jugos, tés y lácteos', 30.00, 16.1800, 1.00, 1.00, '790330050607', true, true, true, 80),
  ('790330050140', 'RICA NECTAR DE MANGO 250 ML', 'Jugos, tés y lácteos', 20.00, 12.4800, 0.00, 0.00, '790330050140', true, true, true, 81),
  ('790330050133', 'RICA NECTAR DE MANGO LITRO', 'Jugos, tés y lácteos', 80.00, 55.9300, 0.00, 0.00, '790330050133', true, true, true, 82),
  ('790330050041', 'RICA NECTAR DE PERA 250 ML.', 'Jugos, tés y lácteos', 20.00, 20.9400, 0.00, 0.00, '790330050041', true, true, true, 83),
  ('790330050034', 'RICA NECTAR DE PERA LITRO', 'Jugos, tés y lácteos', 55.00, 20.4400, 0.00, 0.00, '790330050034', true, true, true, 84),
  ('790330021928', 'RICA ORANGE MANGO', 'Jugos, tés y lácteos', 27.00, 16.7800, 0.00, 0.00, '790330021928', true, true, true, 85),
  ('790330021935', 'RICA ORANGE MANO', 'Jugos, tés y lácteos', 40.00, 26.6600, 0.00, 0.00, '790330021935', true, true, true, 86),
  ('790330021881', 'RICA ORANGE PIÑA', 'Jugos, tés y lácteos', 30.00, 16.7800, 0.00, 0.00, '790330021881', true, true, true, 87),
  ('790330021515', 'RICA PERA 64 ONZ', 'Jugos, tés y lácteos', 75.00, 51.0000, 0.00, -2.00, '790330021515', true, true, true, 88),
  ('790330021232', 'RICA PERA LITRO', 'Jugos, tés y lácteos', 80.00, 49.5800, 0.00, 0.00, '790330021232', true, true, true, 89),
  ('790330050447', 'RICA PERA NECTAR 330ML', 'Jugos, tés y lácteos', 40.00, 14.3400, 0.00, -2.00, '790330050447', true, true, true, 90),
  ('790330050652', 'RICA PERA NECTAR CON SOLVETE', 'Jugos, tés y lácteos', 30.00, 16.1800, 13.00, 13.00, '790330050652', true, true, true, 91),
  ('790330005324', 'RICA PINEABLE 1 LIT', 'Jugos, tés y lácteos', 140.00, 85.0000, 0.00, 0.00, '790330005324', true, true, true, 92),
  ('790330022017', 'RICA PIÑA', 'Jugos, tés y lácteos', 70.00, 43.2200, 0.00, 0.00, '790330022017', true, true, true, 93),
  ('790330050638', 'RICA PIÑA GUAYABA 250 ML.', 'Jugos, tés y lácteos', 30.00, 16.1800, 1.00, 1.00, '790330050638', true, true, true, 94),
  ('790330021294', 'RICA PIÑA GUAYABA 32 OZ.', 'Jugos, tés y lácteos', 60.00, 55.9300, 0.00, 0.00, '790330021294', true, true, true, 95),
  ('790330022024', 'RICA PIÑA SIN AZUCAL GRANDE.59.OZ', 'Jugos, tés y lácteos', 280.00, 170.9700, 1.00, 1.00, '790330022024', true, true, true, 96),
  ('790330014333', 'RICA TAMARINDO', 'Jugos, tés y lácteos', 90.00, 52.5400, 0.00, 0.00, '790330014333', true, true, true, 97),
  ('790330006741', 'RICA YOGURT FRESA', 'Jugos, tés y lácteos', 55.00, 31.7600, 18.00, 18.00, '790330006741', true, true, true, 98),
  ('790330006703', 'RICA YOGURT NATURAL', 'Jugos, tés y lácteos', 50.00, 31.7600, 4.00, 4.00, '790330006703', true, true, true, 99),
  ('790330006789', 'RICA YOGURT VAINILLA', 'Jugos, tés y lácteos', 50.00, 27.5200, 0.00, 0.00, '790330006789', true, true, true, 100),
  ('777', 'TE FRIO DE MAQUINA', 'Jugos, tés y lácteos', 50.00, 25.0000, 0.00, 0.00, null, true, true, true, 101),
  ('796025000025', 'AGUA CRISTAL BOTELLA', 'Aguas', 15.00, 8.9900, 0.00, 0.00, '796025000025', true, true, true, 1),
  ('796025000483', 'AGUA CRYSTAL LITRO', 'Aguas', 35.00, 20.8300, 0.00, 0.00, '796025000483', true, true, true, 2),
  ('8020141152002', 'AGUA MIA', 'Aguas', 25.00, 15.6400, 0.00, 0.00, '8020141152002', true, true, true, 3),
  ('8003430100656', 'AGUA MINERAL S. BERNARDO..500.C.L', 'Aguas', 90.00, 58.6170, 3.00, 3.00, '8003430100656', true, true, true, 4),
  ('8003430100311', 'AGUA MINERAL S. BERNARDO..750.C.L', 'Aguas', 120.00, 61.2900, 2.00, 2.00, '8003430100311', true, true, true, 5),
  ('8002270015991', 'AGUA S.PELLEGRINO', 'Aguas', 85.00, 58.3210, 0.00, 0.00, '8002270015991', true, true, true, 6),
  ('8020141214007', 'AGUA SANT ANNA', 'Aguas', 30.00, 18.2812, 0.00, 0.00, '8020141214007', true, true, true, 7),
  ('8020141204008', 'AGUA SANT ANNA LITRO', 'Aguas', 80.00, 44.8300, 0.00, 0.00, '8020141204008', true, true, true, 8),
  ('765066747367', 'AQUALY AGUA MINERAL', 'Aguas', 45.00, 27.1186, 102.00, 102.00, '765066747367', true, true, true, 9),
  ('893919001301', 'ICE LANDIC GLACIAL', 'Aguas', 280.00, 162.0000, 7.00, 7.00, '893919001301', true, true, true, 10),
  ('893919001608', 'ICE.PH8.4 LANDIC GLACIAL', 'Aguas', 115.00, 80.4600, 4.00, 4.00, '893919001608', true, true, true, 11),
  ('8004192102209', 'LAURETANA AGUA CON GAS', 'Aguas', 160.00, 94.7500, 0.00, 0.00, '8004192102209', true, true, true, 12),
  ('8002270136559', 'S. PELLECRINO', 'Aguas', 135.00, 81.2000, 0.00, 0.00, '8002270136559', true, true, true, 13),
  ('8002270536472', 'S.PELLEGRINO 500ML', 'Aguas', 120.00, 67.1000, 0.00, 0.00, '8002270536472', true, true, true, 14),
  ('8002270000188', 'S.PELLEGRINO 750', 'Aguas', 150.00, 84.7900, 0.00, 0.00, '8002270000188', true, true, true, 15),
  ('8020141101307', 'SANT ANNA SPARKLING 75.M.L', 'Aguas', 200.00, 108.8333, 4.00, 4.00, '8020141101307', true, true, true, 16),
  ('8007601001049', 'SANTA VITTORIA AGUA MINERAL', 'Aguas', 30.00, 19.5833, 0.00, 0.00, '8007601001049', true, true, true, 17),
  ('7862126331641', 'BANANASTO,GO PLANTAIN STRIPS', 'Snacks salados', 230.00, 135.5100, 0.00, 0.00, '7862126331641', false, true, true, 1),
  ('853240003023', 'BRUSCHETTINI BLACK AND GREEN', 'Snacks salados', 240.00, 155.4167, 0.00, 0.00, '853240003023', false, true, true, 2),
  ('853240003009', 'BRUSCHETTINI CLASICO', 'Snacks salados', 240.00, 155.4167, 0.00, 0.00, '853240003009', false, true, true, 3),
  ('853240003153', 'BRUSCHETTINI GARLIC & PARSLEY', 'Snacks salados', 240.00, 155.4167, 0.00, 0.00, '853240003153', false, true, true, 4),
  ('853240003016', 'BRUSCHETTINI ROSEMARY & OLIVE OIL', 'Snacks salados', 240.00, 155.4167, 0.00, 0.00, '853240003016', false, true, true, 5),
  ('7750168001687', 'CLUB SOCIAL INTEGRAL GALLETA', 'Snacks salados', 15.00, 8.1000, 0.00, -4.00, '7750168001687', false, true, true, 6),
  ('7622300375713', 'CLUB SOCIAL INTEGRAL PAQUETES', 'Snacks salados', 180.00, 110.0000, 3.00, 3.00, '7622300375713', false, true, true, 7),
  ('7622300051327', 'CLUB SOCIAL PAQ', 'Snacks salados', 60.00, 2.4200, 0.00, -1.00, '7622300051327', false, true, true, 8),
  ('7622210101273', 'CLUB SOCIAL SABOR A NACHO', 'Snacks salados', 10.00, 8.2640, 0.00, 0.00, '7622210101273', false, true, true, 9),
  ('7622210101396', 'CLUB SOCIAL SABOR QUESO CEBOLLA', 'Snacks salados', 10.00, 4.5200, 0.00, 0.00, '7622210101396', false, true, true, 10),
  ('894185000852', 'CRISPS ASIAN PEAR REAL SLICED', 'Snacks salados', 70.00, 45.0000, 0.00, 0.00, '894185000852', false, true, true, 11),
  ('894185000494', 'CRISPS STRAWEBERRY BANANA', 'Snacks salados', 70.00, 45.0000, 0.00, 0.00, '894185000494', false, true, true, 12),
  ('852109004034', 'ENLIGHTENED BBQ', 'Snacks salados', 65.00, 36.6666, 0.00, 0.00, '852109004034', false, true, true, 13),
  ('852109004003', 'ENLIGHTENED SEA SALT', 'Snacks salados', 65.00, 36.6666, 0.00, 0.00, '852109004003', false, true, true, 14),
  ('853240003238', 'FOCACCIBITES AJO & PEREGIL', 'Snacks salados', 240.00, 150.9375, 0.00, 0.00, '853240003238', false, true, true, 15),
  ('853240003214', 'FOCACCIBITES OLIVE OIL SEA SALT', 'Snacks salados', 240.00, 150.9375, 0.00, 0.00, '853240003214', false, true, true, 16),
  ('853240003221', 'FOCACCIBITIES TOMATE Y OREGANO', 'Snacks salados', 240.00, 150.9375, 0.00, 0.00, '853240003221', false, true, true, 17),
  ('811387010281', 'FRUIT CRISPS CHILDREND', 'Snacks salados', 70.00, 45.0000, 0.00, 0.00, '811387010281', false, true, true, 18),
  ('811387010274', 'FRUIT CRISPS REAL SLICED APPLES', 'Snacks salados', 70.00, 45.9700, 0.00, 0.00, '811387010274', false, true, true, 19),
  ('811387010298', 'FRUIT CRISPS STRAWBERRIES &', 'Snacks salados', 70.00, 45.0000, 0.00, 0.00, '811387010298', false, true, true, 20),
  ('894185000487', 'FUJI APPLE CRISPS', 'Snacks salados', 70.00, 45.0000, 0.00, 0.00, '894185000487', false, true, true, 21),
  ('850126007045', 'HIPPEAS FAR OUT FAJITAS', 'Snacks salados', 90.00, 65.0000, 0.00, 0.00, '850126007045', false, true, true, 22),
  ('850126007090', 'HIPPEAS SRIACHA SUNSHINE', 'Snacks salados', 90.00, 65.0000, 0.00, 0.00, '850126007090', false, true, true, 23),
  ('765857349893', 'KIKABONI PITA CHIPS MORINGA', 'Snacks salados', 60.00, 36.9225, 0.00, 0.00, '765857349893', false, true, true, 24),
  ('765857349909', 'KIKABONI PITA CHIPS QUINOA CRUNCHY', 'Snacks salados', 60.00, 36.9225, 0.00, 0.00, '765857349909', false, true, true, 25);

-- filas 401–600
insert into _p007 (codigo, name, categoria, price, cost, qty, qty_listado, barcode, is_bev, activo, inventariable, posicion) values
  ('856414002174', 'LULU MADURITOS DULCE 2.11', 'Snacks salados', 35.00, 18.9700, 0.00, 0.00, '856414002174', false, true, true, 26),
  ('856414001023', 'MADURITOS MAYTE LULU 85GM', 'Snacks salados', 50.00, 24.1100, 0.00, 0.00, '856414001023', false, true, true, 27),
  ('7798151950468', 'MANI KING GARRAPIÑA', 'Snacks salados', 20.00, 10.0000, 0.00, 0.00, '7798151950468', false, true, true, 28),
  ('856414001078', 'MAYTE MADURITOS NATURAL 5.0', 'Snacks salados', 70.00, 40.4000, 0.00, 0.00, '856414001078', false, true, true, 29),
  ('856414001085', 'MAYTE PLATANITOS LEMON 5.0', 'Snacks salados', 70.00, 48.0000, 0.00, 0.00, '856414001085', false, true, true, 30),
  ('856414001139', 'MAYTE PLATANITOS SALTED NATURAL', 'Snacks salados', 70.00, 48.0000, 0.00, 0.00, '856414001139', false, true, true, 31),
  ('873617005245', 'NUTRI SNACKS ENERGY', 'Snacks salados', 65.00, 38.1300, 0.00, 0.00, '873617005245', false, true, true, 32),
  ('873617001759', 'NUTRI SNACKS LIMA LIMON', 'Snacks salados', 85.00, 42.5000, 8.00, 8.00, '873617001759', false, true, true, 33),
  ('873617000165', 'NUTRI SNACKS MACADAMIA', 'Snacks salados', 80.00, 42.5000, 0.00, -8.00, '873617000165', false, true, true, 34),
  ('8801043008525', 'ONION RINGS SNACK', 'Snacks salados', 60.00, 44.6200, 0.00, 0.00, '8801043008525', false, true, true, 35),
  ('850000725287', 'ORIGINAL TOSTONES', 'Snacks salados', 295.00, 171.6250, 4.00, 4.00, '850000725287', false, true, true, 36),
  ('7750168001694', 'PAQUETE CLUB SOCIAL INTEGRAL 9/1', 'Snacks salados', 60.00, 58.1700, 0.00, 0.00, '7750168001694', false, true, true, 37),
  ('856414001160', 'PLATANITOS CHILE LULU', 'Snacks salados', 35.00, 17.5200, 0.00, 0.00, '856414001160', false, true, true, 38),
  ('856414001108', 'PLATANITOS LIMON CHIPS MAYTE', 'Snacks salados', 50.00, 25.0000, 0.00, 0.00, '856414001108', false, true, true, 39),
  ('856414001191', 'PLATANITOS LIMON LULU', 'Snacks salados', 35.00, 17.5200, 0.00, 0.00, '856414001191', false, true, true, 40),
  ('856414001054', 'PLATANITOS LIMON MAYTE', 'Snacks salados', 50.00, 48.0000, 0.00, 0.00, '856414001054', false, true, true, 41),
  ('856414001184', 'PLATANITOS LULU CHIPS SALADO', 'Snacks salados', 35.00, 17.5200, 0.00, 0.00, '856414001184', false, true, true, 42),
  ('856414001207', 'PLATANITOS LULU CON AJO BNATURAL', 'Snacks salados', 35.00, 17.5200, 0.00, 0.00, '856414001207', false, true, true, 43),
  ('856414001092', 'PLATANITOS MAYTE NATURAL', 'Snacks salados', 50.00, 24.4000, 0.00, 0.00, '856414001092', false, true, true, 44),
  ('856414001016', 'PLATANITOS MAYTE SALADO', 'Snacks salados', 50.00, 21.2000, 0.00, 0.00, '856414001016', false, true, true, 45),
  ('856414002167', 'PLATANITOS SALADO LULU', 'Snacks salados', 35.00, 21.2000, 0.00, 0.00, '856414002167', false, true, true, 46),
  ('893594002112', 'POPCORNERS', 'Snacks salados', 240.00, 145.4800, 0.00, 0.00, '893594002112', false, true, true, 47),
  ('7622300124526', 'RITZ CON QUESO 4 GALLETA', 'Snacks salados', 25.00, 11.6900, 0.00, 0.00, '7622300124526', false, true, true, 48),
  ('764090053710', 'SNCKS MAS-MAS-MANI CON PASAS', 'Snacks salados', 35.00, 19.5546, 4.00, 4.00, '764090053710', false, true, true, 49),
  ('850000725249', 'SWEET CHILI TOSTONES', 'Snacks salados', 295.00, 171.6250, 9.00, 9.00, '850000725249', false, true, true, 50),
  ('850000725263', 'TOSTONES ABANEROS', 'Snacks salados', 295.00, 171.6250, 9.00, 9.00, '850000725263', false, true, true, 51),
  ('850000725256', 'TOSTONES BAR B QUE', 'Snacks salados', 295.00, 171.6250, 1.00, 1.00, '850000725256', false, true, true, 52),
  ('7862106721882', 'TOSTONES BY CHIFLETON TANJIN', 'Snacks salados', 450.00, 274.0000, 0.00, -1.00, '7862106721882', false, true, true, 53),
  ('850000725270', 'TOSTONES LIME', 'Snacks salados', 295.00, 171.6250, 8.00, 8.00, '850000725270', false, true, true, 54),
  ('7862126330989', 'TOSTONES TO-GO-PREMIUM GARLIC', 'Snacks salados', 210.00, 129.3600, 0.00, 0.00, '7862126330989', false, true, true, 55),
  ('7862126330972', 'TOSTONES TO.GO', 'Snacks salados', 225.00, 129.3600, 1.00, 1.00, '7862126330972', false, true, true, 56),
  ('771', 'TRULULU SNACK', 'Snacks salados', 75.00, 23.6500, 0.00, 0.00, null, false, true, true, 57),
  ('8690481004714', 'AFFIX HAZAL VISNELI ISLAK', 'Galletas y bizcochos', 15.00, 7.8200, 0.00, 0.00, '8690481004714', false, true, true, 1),
  ('8690481003267', 'ANITA HAZAL GALLETAS KANSIK', 'Galletas y bizcochos', 25.00, 14.2500, 0.00, 0.00, '8690481003267', false, true, true, 2),
  ('8690481002437', 'ANITA HAZAL SANDWICH BISCUIT', 'Galletas y bizcochos', 15.00, 8.4300, 0.00, 0.00, '8690481002437', false, true, true, 3),
  ('7790040930407', 'BAGLEY GALLETA AMOR', 'Galletas y bizcochos', 30.00, 15.0000, 0.00, 0.00, '7790040930407', false, true, true, 4),
  ('7790040930209', 'BAGLEY GALLETA MELLIZAS', 'Galletas y bizcochos', 30.00, 15.2777, 0.00, -1.00, '7790040930209', false, true, true, 5),
  ('77903518', 'BAGLEY GALLETA OPERA', 'Galletas y bizcochos', 30.00, 16.2500, 0.00, 0.00, '77903518', false, true, true, 6),
  ('7790040930506', 'BAGLEY GALLETA RUMBA', 'Galletas y bizcochos', 30.00, 15.7700, 0.00, 0.00, '7790040930506', false, true, true, 7),
  ('7790040999404', 'BAGLEY GALLETA SALVADO FIBRA', 'Galletas y bizcochos', 45.00, 23.6111, 0.00, 0.00, '7790040999404', false, true, true, 8),
  ('80752981', 'BALCONI MIX MAX COCO', 'Galletas y bizcochos', 40.00, 20.0000, 6.00, 6.00, '80752981', false, true, true, 9),
  ('7790040726505', 'BAYLEY SALVADO ORIGINAL 230G', 'Galletas y bizcochos', 40.00, 27.0000, 0.00, 0.00, '7790040726505', false, true, true, 10),
  ('8410368000970', 'BIZCOCHO GRANDE', 'Galletas y bizcochos', 190.00, 79.0000, 0.00, -3.00, '8410368000970', false, true, true, 11),
  ('8410368040082', 'BIZCOCHO INTEGRAL 0%', 'Galletas y bizcochos', 115.00, 63.9900, 0.00, 0.00, '8410368040082', false, true, true, 12),
  ('8410368039611', 'BIZCOCHOS INTEGRAL 0% AZUCAR', 'Galletas y bizcochos', 35.00, 23.0000, 0.00, 0.00, '8410368039611', false, true, true, 13),
  ('8410014378330', 'BOCADITOS CHOCO', 'Galletas y bizcochos', 20.00, 7.9600, 0.00, 0.00, '8410014378330', false, true, true, 14),
  ('8410014317070', 'BOCADITOS LIMON', 'Galletas y bizcochos', 20.00, 7.9600, 0.00, 0.00, '8410014317070', false, true, true, 15),
  ('765066783532', 'BROWNIE', 'Galletas y bizcochos', 90.00, 50.0000, 0.00, -3.00, '765066783532', false, true, true, 16),
  ('8410368033329', 'CAJAS D MINI CONCHAS', 'Galletas y bizcochos', 130.00, 75.0000, 0.00, 0.00, '8410368033329', false, true, true, 17),
  ('7750243004534', 'CASINO GALLETAS VARIADAS', 'Galletas y bizcochos', 45.00, 1.0000, 0.00, 0.00, '7750243004534', false, true, true, 18),
  ('7622300268633', 'CHIPS AHOY CHISPA CHOCOLATE', 'Galletas y bizcochos', 40.00, 22.1600, 0.00, 0.00, '7622300268633', false, true, true, 19),
  ('7622210259004', 'CHIPS AHOY GALLETAS 38 G', 'Galletas y bizcochos', 20.00, 5.9325, 0.00, -1.00, '7622210259004', false, true, true, 20),
  ('8080', 'CHIPS AHOY GRANDES 3 PAQ.', 'Galletas y bizcochos', 1300.00, 805.0000, 1.00, 1.00, null, false, true, true, 21),
  ('787692834617', 'CHOCOLATE CHIP COOKIE', 'Galletas y bizcochos', 260.00, 150.0000, 0.00, 0.00, '787692834617', false, true, true, 22),
  ('787692835416', 'COMPLETE COOKIE PEANUT BUTTER', 'Galletas y bizcochos', 260.00, 150.0000, 0.00, 0.00, '787692835416', false, true, true, 23),
  ('787692835386', 'COOKIE COCONUT CHOCOLATE CHIP', 'Galletas y bizcochos', 150.00, 100.0000, 0.00, 0.00, '787692835386', false, true, true, 24),
  ('787692835430', 'COOKIE COMPLETE APPLE PIE', 'Galletas y bizcochos', 200.00, 108.3300, 0.00, 0.00, '787692835430', false, true, true, 25),
  ('787692835331', 'COOKIE DOUBLE CHOCOLATE', 'Galletas y bizcochos', 260.00, 150.0000, 0.00, 0.00, '787692835331', false, true, true, 26),
  ('787692835355', 'COOKIE SNICKEDOODLE', 'Galletas y bizcochos', 240.00, 141.6600, 0.00, 0.00, '787692835355', false, true, true, 27),
  ('8904006206058', 'CREAM FRESH STRAWBERRY GALLETA', 'Galletas y bizcochos', 20.00, 8.2740, 0.00, 0.00, '8904006206058', false, true, true, 28),
  ('8904006206072', 'CREAM FRESH VANILLA GALLETA', 'Galletas y bizcochos', 20.00, 7.9558, 0.00, 0.00, '8904006206072', false, true, true, 29),
  ('8906001385028', 'CREMICA GLUCOSE GALLETA', 'Galletas y bizcochos', 10.00, 3.5308, 0.00, 0.00, '8906001385028', false, true, true, 30),
  ('810010660886', 'CREMICA KOKO', 'Galletas y bizcochos', 10.00, 4.1100, 1.00, 1.00, '810010660886', false, true, true, 31),
  ('8906001386001', 'CREMICA MALT N MILK', 'Galletas y bizcochos', 10.00, 3.5311, 0.00, 0.00, '8906001386001', false, true, true, 32),
  ('8906001386278', 'CREMICA NICE SABOR A COCO', 'Galletas y bizcochos', 10.00, 3.5311, 0.00, 0.00, '8906001386278', false, true, true, 33),
  ('8906001385387', 'CREMITA COCONUT CRUNCHIES', 'Galletas y bizcochos', 10.00, 3.5309, 0.00, 0.00, '8906001385387', false, true, true, 34),
  ('8902335028884', 'DANISH BUTTER COOKIES 12OZ', 'Galletas y bizcochos', 200.00, 95.3391, 0.00, 0.00, '8902335028884', false, true, true, 35),
  ('8901972057493', 'DANISH GALLETAS PREMIUM', 'Galletas y bizcochos', 190.00, 120.3800, 0.00, 0.00, '8901972057493', false, true, true, 36),
  ('8901972073592', 'DANISH PRIDE GALLETA DE LUJO', 'Galletas y bizcochos', 175.00, 98.8700, 0.00, 0.00, '8901972073592', false, true, true, 37),
  ('8904006230077', 'DYNAS GALLETA SANDWICCH CREAM', 'Galletas y bizcochos', 20.00, 10.0000, 0.00, 0.00, '8904006230077', false, true, true, 38),
  ('8901972068666', 'GALLETA BUTTER COOKIES', 'Galletas y bizcochos', 100.00, 44.1400, 0.00, -1.00, '8901972068666', false, true, true, 39),
  ('781718687720', 'GALLETA CHOCO CHIP', 'Galletas y bizcochos', 60.00, 25.0000, 0.00, 0.00, '781718687720', false, true, true, 40),
  ('8902335013163', 'GALLETA DANESA GRANDE', 'Galletas y bizcochos', 165.00, 98.8700, 0.00, 0.00, '8902335013163', false, true, true, 41),
  ('8902335013156', 'GALLETA DANESA PEQ', 'Galletas y bizcochos', 110.00, 56.4900, 0.00, 0.00, '8902335013156', false, true, true, 42),
  ('781718687737', 'GALLETA DE AVENA', 'Galletas y bizcochos', 60.00, 41.3000, 0.00, -18.00, '781718687737', false, true, true, 43),
  ('8901972071888', 'GALLETAS BUTTER COOKIES', 'Galletas y bizcochos', 125.00, null, 0.00, 0.00, '8901972071888', false, true, true, 44),
  ('8902335006189', 'GALLETAS DANISH REGALIA 4.0 OZ', 'Galletas y bizcochos', 100.00, 49.4300, 0.00, 0.00, '8902335006189', false, true, true, 45),
  ('8902335005236', 'GALLETAS NAVIDEÑAS VAINILLA', 'Galletas y bizcochos', 50.00, 22.0692, 0.00, 0.00, '8902335005236', false, true, true, 46),
  ('765351901221', 'GINA GALLETA CHEESE', 'Galletas y bizcochos', 15.00, 8.3863, 0.00, 0.00, '765351901221', false, true, true, 47),
  ('888109010683', 'HOSTESS TWINKIES SPOGE', 'Galletas y bizcochos', 40.00, 26.3593, 0.00, 0.00, '888109010683', false, true, true, 48),
  ('7896071021210', 'KELLI GALLETAS VARIADAS', 'Galletas y bizcochos', 30.00, 23.0000, 0.00, 0.00, '7896071021210', false, true, true, 49),
  ('809552099283', 'LLENITAS DE CHOCOLATES', 'Galletas y bizcochos', 5.00, 2.5425, 0.00, 0.00, '809552099283', false, true, true, 50),
  ('809552088708', 'LLENITAS DE LIMON', 'Galletas y bizcochos', 5.00, 2.5425, 0.00, -1.00, '809552088708', false, true, true, 51),
  ('8095520099247', 'LLENITAS DE VANILLAS', 'Galletas y bizcochos', 5.00, 2.5425, 0.00, 0.00, '8095520099247', false, true, true, 52),
  ('8410120500038', 'MARIA GALLETAS CUETARA 200G', 'Galletas y bizcochos', 50.00, 40.0000, 0.00, 0.00, '8410120500038', false, true, true, 53),
  ('797936000470', 'MARIA LIDO GALLETA 135G', 'Galletas y bizcochos', 30.00, 14.0000, 0.00, 0.00, '797936000470', false, true, true, 54),
  ('7896003701180', 'MARILAN GALLETA WAFER BAUNY', 'Galletas y bizcochos', 35.00, 23.2550, 0.00, 0.00, '7896003701180', false, true, true, 55),
  ('8904006291009', 'MINEES RICH CHOCOLATE', 'Galletas y bizcochos', 5.00, 3.0000, 0.00, 0.00, '8904006291009', false, true, true, 56),
  ('8904006291016', 'MINEES RICH VANILLA MORADA', 'Galletas y bizcochos', 5.00, 3.0000, 0.00, 0.00, '8904006291016', false, true, true, 57),
  ('8904006291047', 'MINEES SANDWICH COOKIES', 'Galletas y bizcochos', 5.00, 3.0000, 0.00, 0.00, '8904006291047', false, true, true, 58),
  ('8904006291030', 'MINEES STRAWBERRY CREMA', 'Galletas y bizcochos', 5.00, 3.0000, 0.00, 0.00, '8904006291030', false, true, true, 59),
  ('8904006291023', 'MINEES VANILLA CHOCOLATE RICH', 'Galletas y bizcochos', 5.00, 3.0000, 0.00, 0.00, '8904006291023', false, true, true, 60),
  ('8410368033848', 'MINI CONCHAS DUOCAO', 'Galletas y bizcochos', 25.00, 13.0000, 0.00, 0.00, '8410368033848', false, true, true, 61),
  ('8410368033312', 'MINI CONCHAS ORIGINAL', 'Galletas y bizcochos', 35.00, 13.0000, 0.00, 0.00, '8410368033312', false, true, true, 62),
  ('7702189041197', 'MINIS QUAKER', 'Galletas y bizcochos', 25.00, 14.0100, 0.00, 0.00, '7702189041197', false, true, true, 63),
  ('80602316', 'MIXMAX', 'Galletas y bizcochos', 35.00, 20.0000, 6.00, 6.00, '80602316', false, true, true, 64),
  ('7702011003881', 'MOMENTS GALLETAS 280G', 'Galletas y bizcochos', 70.00, 44.0000, 0.00, 0.00, '7702011003881', false, true, true, 65),
  ('787692834624', 'OATMEAL RAISIN COOKIE', 'Galletas y bizcochos', 260.00, 150.0000, 0.00, 0.00, '787692834624', false, true, true, 66),
  ('7702133009037', 'OREO CAKESTERS', 'Galletas y bizcochos', 40.00, 21.0000, 0.00, -3.00, '7702133009037', false, true, true, 67),
  ('7750168002240', 'OREO CHOCOLATE', 'Galletas y bizcochos', 15.00, 15.0000, 0.00, 0.00, '7750168002240', false, true, true, 68),
  ('7622202217579', 'OREO ROLLO REG. EXTRA CONTENIDO', 'Galletas y bizcochos', 70.00, 41.1300, 0.00, 0.00, '7622202217579', false, true, true, 69),
  ('787692835324', 'PUMPKIN SPICE COMPLETE COOKIE', 'Galletas y bizcochos', 150.00, 100.0000, 0.00, 0.00, '787692835324', false, true, true, 70),
  ('7702025182329', 'RECREO GALLETAS', 'Galletas y bizcochos', 5.00, 2.0000, 0.00, 0.00, '7702025182329', false, true, true, 71),
  ('7702025182305', 'RECREO GALLETAS PACKS', 'Galletas y bizcochos', 70.00, 50.0000, 0.00, 0.00, '7702025182305', false, true, true, 72),
  ('8410368002936', 'RIZADA INTEGRALES 3/1', 'Galletas y bizcochos', 30.00, 15.2100, 0.00, 0.00, '8410368002936', false, true, true, 73),
  ('8410368000390', 'ROBIN RELLENO CREMA UNIDAD', 'Galletas y bizcochos', 35.00, 18.7500, 0.00, 0.00, '8410368000390', false, true, true, 74),
  ('8410368034678', 'ROBIN RELLENO DE CREMA PAQ.', 'Galletas y bizcochos', 130.00, 75.0000, 0.00, 0.00, '8410368034678', false, true, true, 75),
  ('80661641', 'ROLLINO COCOA', 'Galletas y bizcochos', 40.00, 24.0000, 2.00, 2.00, '80661641', false, true, true, 76),
  ('8001585010103', 'ROLLINO PISTACCHO', 'Galletas y bizcochos', 45.00, 26.0000, 0.00, 0.00, '8001585010103', false, true, true, 77),
  ('80633051', 'ROLLINO PISTACCHO', 'Galletas y bizcochos', 45.00, 26.0000, 4.00, 4.00, '80633051', false, true, true, 78),
  ('781718687713', 'ROLLO DE CANELA', 'Galletas y bizcochos', 75.00, 30.0000, 0.00, 0.00, '781718687713', false, true, true, 79),
  ('7702011048301', 'SULITIDAS NAVIDEÑAS GALLETAS 8.45G', 'Galletas y bizcochos', 80.00, 53.0000, 0.00, 0.00, '7702011048301', false, true, true, 80),
  ('7702011003553', 'SULTIDA HAPPY HOLIDAYS GALLETAS', 'Galletas y bizcochos', 70.00, 40.0000, 0.00, 0.00, '7702011003553', false, true, true, 81),
  ('7702011014184', 'SULTIDA NAVIDEÑAS GALLETA 240G', 'Galletas y bizcochos', 80.00, 54.0000, 0.00, 0.00, '7702011014184', false, true, true, 82),
  ('8904006205082', 'TREFF CHOCO VANILLA PQ', 'Galletas y bizcochos', 15.00, 10.0000, 0.00, 0.00, '8904006205082', false, true, true, 83),
  ('8904006206065', 'TREFF CREAN FRESH CHOCOLATE', 'Galletas y bizcochos', 35.00, 8.9935, 0.00, 0.00, '8904006206065', false, true, true, 84),
  ('8904006291054', 'TREFF MINEES 10 PAKS GALLETA', 'Galletas y bizcochos', 60.00, 40.0000, 0.00, 0.00, '8904006291054', false, true, true, 85),
  ('80633044', 'TRONCCETTO BALCONI GALLETA', 'Galletas y bizcochos', 15.00, 8.0000, 0.00, 0.00, '80633044', false, true, true, 86),
  ('7891962005553', 'VISCONTI GALL-VARIADO 140G', 'Galletas y bizcochos', 35.00, 25.0000, 0.00, 0.00, '7891962005553', false, true, true, 87),
  ('787692838349', 'WHITE CHOCOLATE MACADAMIA', 'Galletas y bizcochos', 260.00, 150.0000, 0.00, 0.00, '787692838349', false, true, true, 88),
  ('7702993042311', 'BIANCHI CARAMELO Y MANI', 'Chocolates', 40.00, 23.6400, 0.00, 0.00, '7702993042311', false, true, true, 1),
  ('7702993022283', 'CHOCOLATE BLANCO BIANCHI', 'Chocolates', 120.00, 64.7800, 0.00, 0.00, '7702993022283', false, true, true, 2),
  ('776', 'CHOCOLATE CON ALCOHOLMINIATURA', 'Chocolates', 15.00, 10.2600, 0.00, 0.00, null, false, true, true, 3),
  ('764090052515', 'CORTES ALMENDRA', 'Chocolates', 45.00, 27.7777, 0.00, 0.00, '764090052515', false, true, true, 4),
  ('764090052478', 'CORTES PREMIUM CONO CREAM', 'Chocolates', 45.00, 27.7777, 0.00, 0.00, '764090052478', false, true, true, 5),
  ('764090052454', 'CORTES WAFFLE', 'Chocolates', 45.00, 27.7777, 0.00, 0.00, '764090052454', false, true, true, 6),
  ('764090052119', 'CRACHI CHOCOLATE', 'Chocolates', 25.00, 16.0417, 0.00, 0.00, '764090052119', false, true, true, 7),
  ('7891000369371', 'CRUNCH CHOCOLATE', 'Chocolates', 190.00, 112.0231, 3.00, 3.00, '7891000369371', false, true, true, 8),
  ('8690997158611', 'ECLAINS ASSRTED CHOCOLATE', 'Chocolates', 330.00, 235.6900, 0.00, 0.00, '8690997158611', false, true, true, 9),
  ('869302920023', 'ELVAN ICEBERG CHOCOLTE 50G', 'Chocolates', 220.00, 170.0000, 0.00, 0.00, '869302920023', false, true, true, 10),
  ('7891233', 'GAROTO CHOCOLATE 7 G', 'Chocolates', 5.00, 5.0000, 0.00, 0.00, null, false, true, true, 11),
  ('8690997111753', 'GIFT CHOCOLATES SULTIDOS', 'Chocolates', 160.00, 106.0000, 0.00, 0.00, '8690997111753', false, true, true, 12),
  ('7899970401206', 'HERSHEY,S CHOCO TUBES', 'Chocolates', 40.00, 25.0000, 1.00, 1.00, '7899970401206', false, true, true, 13),
  ('7891000248768', 'KIT KAT DARK', 'Chocolates', 105.00, 62.1470, 51.00, 51.00, '7891000248768', false, true, true, 14),
  ('7891000249239', 'KIT KAT WHITE BLANCO', 'Chocolates', 105.00, 62.1470, 4.00, 4.00, '7891000249239', false, true, true, 15),
  ('8746197756475', 'MANI CON CHOCOLATE', 'Chocolates', 55.00, 35.0000, 0.00, 0.00, '8746197756475', false, true, true, 16),
  ('764090052157', 'MAS-MAS CHOCOLATE', 'Chocolates', 50.00, 27.9000, 0.00, -16.00, '764090052157', false, true, true, 17),
  ('764090052133', 'MILK CHOCOLATE BARRA', 'Chocolates', 50.00, 27.9000, 0.00, -15.00, '764090052133', false, true, true, 18),
  ('764090052430', 'PREMIUM CHOCOLATE CACAO', 'Chocolates', 40.00, 30.0000, 0.00, 0.00, '764090052430', false, true, true, 19),
  ('764090052416', 'PREMIUM CHOCOLATE CAFE', 'Chocolates', 45.00, 27.7777, 0.00, 0.00, '764090052416', false, true, true, 20),
  ('764090053703', 'ROCKY ALMENDRAS TOSTADAS', 'Chocolates', 65.00, 35.8563, 5.00, 5.00, '764090053703', false, true, true, 21),
  ('764090052171', 'ROCKY KID CHOCOLATE', 'Chocolates', 25.00, 16.0417, 0.00, 0.00, '764090052171', false, true, true, 22),
  ('8413725004062', 'SAN ANDRES TURRONES', 'Chocolates', 100.00, 52.6666, 0.00, 0.00, '8413725004062', false, true, true, 23),
  ('8412704007308', 'TURRON IMPERIAL DON RODRIGO', 'Chocolates', 100.00, 31.7800, 0.00, -1.00, '8412704007308', false, true, true, 24),
  ('840004098302', 'AVENGERS MARTILLO DULCE', 'Chicles y caramelos', 75.00, 105.0000, 0.00, 0.00, '840004098302', false, true, true, 1),
  ('7702133853265', 'CERTS AQUA SANDIA', 'Chicles y caramelos', 15.00, 15.0000, 0.00, 0.00, '7702133853265', false, true, true, 2),
  ('7702133100130', 'CHICLETS ADANS EXTEND DUKA WOS', 'Chicles y caramelos', 20.00, 6.3300, 0.00, 0.00, '7702133100130', false, true, true, 3),
  ('7891200001637', 'COQUI', 'Chicles y caramelos', 85.00, 49.5000, 0.00, 0.00, '7891200001637', false, true, true, 4),
  ('7777', 'DULCE CON JUEGUETE', 'Chicles y caramelos', 50.00, 15.0000, 11.00, 11.00, null, false, true, true, 5),
  ('8410525116759', 'FINI JELLY BANANAS', 'Chicles y caramelos', 60.00, 43.0000, 0.00, 0.00, '8410525116759', false, true, true, 6),
  ('8410525143403', 'FINI PASTEQUE', 'Chicles y caramelos', 60.00, 43.0000, 0.00, 0.00, '8410525143403', false, true, true, 7),
  ('8410525211065', 'FINI SOUR LACES', 'Chicles y caramelos', 70.00, 40.0000, 0.00, 0.00, '8410525211065', false, true, true, 8),
  ('7896058593839', 'FRUTINAS GOMITAS', 'Chicles y caramelos', 60.00, null, 0.00, 0.00, '7896058593839', false, true, true, 9),
  ('763061080892', 'FUN FACTORY JEEP', 'Chicles y caramelos', 125.00, 72.5000, 0.00, 0.00, '763061080892', false, true, true, 10),
  ('7896451908575', 'GOMITAS NAVIDEÑAS', 'Chicles y caramelos', 190.00, 118.6400, 0.00, 0.00, '7896451908575', false, true, true, 11),
  ('7891151017404', 'GOMUTCHO GOMITAS', 'Chicles y caramelos', 10.00, 4.0000, 0.00, 0.00, '7891151017404', false, true, true, 12),
  ('7622210427045', 'HALLS BARRA CHERRY', 'Chicles y caramelos', 30.00, 13.0374, 55.00, 55.00, '7622210427045', false, true, true, 13),
  ('7622210427076', 'HALLS MENTHOL LYPTUS BARRAS', 'Chicles y caramelos', 30.00, 13.0374, 45.00, 45.00, '7622210427076', false, true, true, 14),
  ('7622202015212', 'HALLS STRONG BARRAS', 'Chicles y caramelos', 30.00, 13.0374, 44.00, 44.00, '7622202015212', false, true, true, 15),
  ('872635001802', 'HELLO KITTY HEADULIGHT POP', 'Chicles y caramelos', 50.00, 33.0000, 0.00, 0.00, '872635001802', false, true, true, 16),
  ('872635001246', 'HELLO KITTY MARSHMALLOW POPS', 'Chicles y caramelos', 100.00, 68.5000, 0.00, 0.00, '872635001246', false, true, true, 17),
  ('8850197580951', 'HUEVO KING EGG', 'Chicles y caramelos', 100.00, 15.0000, 13.00, 13.00, '8850197580951', false, true, true, 18),
  ('7896286601900', 'ICEKISS MENTHOLYPTUS', 'Chicles y caramelos', 20.00, 6.5375, 0.00, 0.00, '7896286601900', false, true, true, 19),
  ('840004097466', 'LAPTOP CAR C/DULCE', 'Chicles y caramelos', 125.00, 63.2600, 0.00, 0.00, '840004097466', false, true, true, 20),
  ('7801615692283', 'MENTITAS FRESCOLI', 'Chicles y caramelos', 15.00, 10.0000, 0.00, 0.00, '7801615692283', false, true, true, 21),
  ('78925281', 'MENTOS FRESA 12', 'Chicles y caramelos', 45.00, 8.7200, 0.00, 0.00, '78925281', false, true, true, 22),
  ('78914681', 'MENTOS MENTA', 'Chicles y caramelos', 60.00, 16.8785, 0.00, 0.00, '78914681', false, true, true, 23),
  ('78930643', 'MENTOS TUTTI FRUTTI 12', 'Chicles y caramelos', 35.00, 19.0000, 0.00, 0.00, '78930643', false, true, true, 24),
  ('7896262304306', 'MENTOS VARIADOS', 'Chicles y caramelos', 50.00, 22.5047, 0.00, 0.00, '7896262304306', false, true, true, 25),
  ('763061082001', 'MILITARY HUMMER/ARMY', 'Chicles y caramelos', 110.00, 72.5000, 0.00, 0.00, '763061082001', false, true, true, 26),
  ('816251010428', 'MOTO 9P FANTASY TOYS', 'Chicles y caramelos', 160.00, 101.8333, 0.00, 0.00, '816251010428', false, true, true, 27),
  ('787545004914', 'OLI GELATINA', 'Chicles y caramelos', 35.00, 19.4200, 480.00, 480.00, '787545004914', false, true, true, 28),
  ('7702402057615', 'PALETA TOSH', 'Chicles y caramelos', 65.00, 37.1243, 4.00, 4.00, '7702402057615', false, true, true, 29),
  ('871478617225', 'PRINCESA POP TOY PIZARRA', 'Chicles y caramelos', 150.00, 100.0000, 0.00, 0.00, '871478617225', false, true, true, 30),
  ('854929006557', 'SOUR BELTS TIRAS ACIDAS', 'Chicles y caramelos', 15.00, 7.3100, 2.00, 2.00, '854929006557', false, true, true, 31),
  ('7702133879494', 'SPARKIES BUBBALOO ADAMS', 'Chicles y caramelos', 20.00, 6.5601, 0.00, 0.00, '7702133879494', false, true, true, 32),
  ('7622201801229', 'TRIDEN SPLASH VAINILLA', 'Chicles y caramelos', 50.00, 25.2800, 0.00, 0.00, '7622201801229', false, true, true, 33),
  ('7622202212062', 'TRIDENT BOTELLA SPLASH', 'Chicles y caramelos', 200.00, 120.6000, 0.00, 0.00, '7622202212062', false, true, true, 34),
  ('7622210171115', 'TRIDENT CHIQUITO', 'Chicles y caramelos', 10.00, 4.2900, 0.00, 0.00, '7622210171115', false, true, true, 35),
  ('7622201776664', 'TRIDENT MENTA', 'Chicles y caramelos', 30.00, 16.2973, 73.00, 73.00, '7622201776664', false, true, true, 36),
  ('7702133862793', 'TRIDENT SANDIA', 'Chicles y caramelos', 25.00, 9.1500, 0.00, 0.00, '7702133862793', false, true, true, 37),
  ('7622210973436', 'TRIDENT VUP FRESA', 'Chicles y caramelos', 55.00, 31.9100, 0.00, 0.00, '7622210973436', false, true, true, 38),
  ('7622210461674', 'TRIDENT WHITE FRESA', 'Chicles y caramelos', 25.00, 9.7700, 0.00, 0.00, '7622210461674', false, true, true, 39),
  ('7622210461704', 'TRIDENT WHITE MENTA', 'Chicles y caramelos', 25.00, 9.1500, 0.00, 0.00, '7622210461704', false, true, true, 40),
  ('7622210461728', 'TRIDENT WHITE MIORA AZUL + OFERTA', 'Chicles y caramelos', 25.00, 5.4800, 0.00, 0.00, '7622210461728', false, true, true, 41),
  ('7622210461742', 'TRIDENT WHITE YERBABUENA', 'Chicles y caramelos', 25.00, 13.0000, 0.00, -1.00, '7622210461742', false, true, true, 42),
  ('7622202395130', 'TRIDENT X SPLASH SANDIA', 'Chicles y caramelos', 60.00, 30.2661, 0.00, -9.00, '7622202395130', false, true, true, 43),
  ('7622202395536', 'TRIDENT.X YERBABUENA.17.1.G', 'Chicles y caramelos', 60.00, 30.2661, 14.00, 14.00, '7622202395536', false, true, true, 44),
  ('7622210938282', 'TRIDENTE VAL U PARK CANELA', 'Chicles y caramelos', 50.00, 27.1800, 0.00, 0.00, '7622210938282', false, true, true, 45),
  ('7622202394799', 'TRIDENTX SPLASH FRESA', 'Chicles y caramelos', 60.00, 30.2661, 22.00, 22.00, '7622202394799', false, true, true, 46),
  ('763061080700', 'YOYO CANDY TOYS', 'Chicles y caramelos', 80.00, 50.0000, 0.00, 0.00, '763061080700', false, true, true, 47),
  ('820', 'D.R PAQUETE DE BANDEJA DE', 'Dulces típicos', 155.00, 90.0000, 5.00, 5.00, null, false, true, true, 1),
  ('819', 'D.R PAQUETE DE COCADA', 'Dulces típicos', 190.00, 105.0000, 5.00, 5.00, null, false, true, true, 2),
  ('818', 'D.R PAQUETE DE JALAO', 'Dulces típicos', 190.00, 105.0000, 5.00, 5.00, null, false, true, true, 3),
  ('821', 'D.R PAQUETE DE PALETAS RODRIGUEZ', 'Dulces típicos', 70.00, 40.0000, 20.00, 20.00, null, false, true, true, 4),
  ('815', 'D.R PAQUETE DE RAPADURA PEQ.', 'Dulces típicos', 195.00, 105.0000, 5.00, 5.00, null, false, true, true, 5),
  ('816', 'D.R PAQUETE DE RAPADURA.FAMILIAR', 'Dulces típicos', 210.00, 125.0000, 5.00, 5.00, null, false, true, true, 6),
  ('817', 'D.R PAQUETE DE SANDWICH', 'Dulces típicos', 190.00, 105.0000, 5.00, 5.00, null, false, true, true, 7),
  ('812', 'D.R PASTA DE COCO LECHE Y PIÑA', 'Dulces típicos', 190.00, 105.0000, 3.00, 3.00, null, false, true, true, 8),
  ('810', 'D.R PASTA DE LECHE RELL. NARANJA', 'Dulces típicos', 190.00, 105.0000, 4.00, 4.00, null, false, true, true, 9);

-- filas 601–800
insert into _p007 (codigo, name, categoria, price, cost, qty, qty_listado, barcode, is_bev, activo, inventariable, posicion) values
  ('811', 'D.R PASTA DE LECHE Y COCO GDE', 'Dulces típicos', 190.00, 105.0000, 3.00, 3.00, null, false, true, true, 10),
  ('814', 'D.R PASTA DE NARANJA', 'Dulces típicos', 195.00, 110.0000, 5.00, 5.00, null, false, true, true, 11),
  ('813', 'D.R PASTA DE PANELA', 'Dulces típicos', 225.00, 130.0000, 8.00, 8.00, null, false, true, true, 12),
  ('8031', 'DR PILON', 'Dulces típicos', 155.00, 110.0000, 0.00, 0.00, null, false, true, true, 13),
  ('8025', 'DR. DULCE DE AJONJOLI', 'Dulces típicos', 95.00, 65.0000, 0.00, 0.00, null, false, true, true, 14),
  ('8029', 'DR. PALO NAVIDEÑO', 'Dulces típicos', 180.00, 125.0000, 0.00, 0.00, null, false, true, true, 15),
  ('8026', 'DR.CONCON DE LECHE G.DE', 'Dulces típicos', 195.00, 110.0000, 0.00, 0.00, null, false, true, true, 16),
  ('8028', 'DR.DULCE TRES EN UNO', 'Dulces típicos', 160.00, 90.0000, 0.00, 0.00, null, false, true, true, 17),
  ('8023', 'DR.PASTA DE COCO Y LECHE G.DE', 'Dulces típicos', 180.00, 105.0000, 5.00, 5.00, null, false, true, true, 18),
  ('8024', 'DR.PASTA DE COCO,LECHE Y PIÑA G.DE', 'Dulces típicos', 180.00, 105.0000, 0.00, -1.00, null, false, true, true, 19),
  ('8030', 'DR.PASTA DE GUAYABA GDE', 'Dulces típicos', 180.00, 105.0000, 0.00, 0.00, null, false, true, true, 20),
  ('8021', 'DR.PASTA DE LECHE RELL CON', 'Dulces típicos', 180.00, 105.0000, 5.00, 5.00, null, false, true, true, 21),
  ('8022', 'DR.PASTA DE LECHE RELL DE NARANJA', 'Dulces típicos', 180.00, 105.0000, 2.00, 2.00, null, false, true, true, 22),
  ('8020', 'DR.PASTA DE LECHE SOLA GRANDE', 'Dulces típicos', 180.00, 105.0000, 5.00, 5.00, null, false, true, true, 23),
  ('8027', 'DR.SANDWICH FAMILIAR', 'Dulces típicos', 200.00, 110.0000, 0.00, 0.00, null, false, true, true, 24),
  ('888849006038', '153.21QUEST PEANUT BUTTER', 'Barras de proteína', 345.00, 171.6666, 10.00, 10.00, '888849006038', false, true, true, 1),
  ('888849000494', 'BARRA PROTEINA VAINILLA ALMENDRA', 'Barras de proteína', 170.00, 116.0000, 0.00, 0.00, '888849000494', false, true, true, 2),
  ('888849000630', 'QUEST BAR APPLE PIE', 'Barras de proteína', 345.00, 171.0000, 0.00, 0.00, '888849000630', false, true, true, 3),
  ('888849005956', 'QUEST BAR CAKE', 'Barras de proteína', 380.00, 199.5833, 12.00, 12.00, '888849005956', false, true, true, 4),
  ('888849004621', 'QUEST BAR CHOCOLATE CHIP', 'Barras de proteína', 380.00, 199.5833, 13.00, 13.00, '888849004621', false, true, true, 5),
  ('888849000432', 'QUEST BAR CINNAMON ROLL', 'Barras de proteína', 180.00, 63.2300, 0.00, 0.00, '888849000432', false, true, true, 6),
  ('888849000234', 'QUEST BAR DOUBLE CHOCOLATE', 'Barras de proteína', 340.00, 199.5833, 10.00, 10.00, '888849000234', false, true, true, 7),
  ('888849000005', 'QUEST BAR PROTEIN BAR 4G NET', 'Barras de proteína', 340.00, 199.5833, 11.00, 11.00, '888849000005', false, true, true, 8),
  ('888849012244', 'QUEST BARTHDAY CAKE', 'Barras de proteína', 340.00, 199.5833, 0.00, 0.00, '888849012244', false, true, true, 9),
  ('888849005994', 'QUEST CHOCOLE CHIP COOKE', 'Barras de proteína', 345.00, 171.6666, 13.00, 13.00, '888849005994', false, true, true, 10),
  ('888849006014', 'QUEST DOUBLE CHOCOLE CHIP COOKE', 'Barras de proteína', 345.00, 171.6666, 0.00, 0.00, '888849006014', false, true, true, 11),
  ('888849006069', 'QUEST OATMEAL RAISIN COOKE', 'Barras de proteína', 155.00, 102.1800, 0.00, 0.00, '888849006069', false, true, true, 12),
  ('888849006397', 'QUEST PEANUT BETTER BAR', 'Barras de proteína', 200.00, 144.2600, 0.00, 0.00, '888849006397', false, true, true, 13),
  ('888849008049', 'QUEST PEANUT CHOC. CHIP', 'Barras de proteína', 345.00, 171.6666, 5.00, 5.00, '888849008049', false, true, true, 14),
  ('888849000418', 'QUEST PROTEIN BAR CHOCOLATE', 'Barras de proteína', 325.00, 199.5833, 11.00, 11.00, '888849000418', false, true, true, 15),
  ('888849000456', 'QUEST PROTEIN BAR CHOCOLATE', 'Barras de proteína', 215.00, 130.7800, 0.00, 0.00, '888849000456', false, true, true, 16),
  ('888849003495', 'QUEST PROTEIN CARAMELO', 'Barras de proteína', 345.00, 171.0000, 0.00, 0.00, '888849003495', false, true, true, 17),
  ('888849010103', 'QUEST PROTEIN CARAMELO', 'Barras de proteína', 380.00, 203.0000, 7.00, 7.00, '888849010103', false, true, true, 18),
  ('888849010646', 'QUEST SNACK BAR CHOCOLATE MIXED', 'Barras de proteína', 200.00, 122.9000, 0.00, 0.00, '888849010646', false, true, true, 19),
  ('888849010707', 'QUEST SNACK CARAMEL ALMOND', 'Barras de proteína', 200.00, 122.9000, 0.00, 0.00, '888849010707', false, true, true, 20),
  ('888849000012', 'QUESTBAR CHOCOLATE CHIP', 'Barras de proteína', 340.00, 199.5833, 10.00, 10.00, '888849000012', false, true, true, 21),
  ('888849000210', 'QUESTBAR CHOCOLATE RASBERRY', 'Barras de proteína', 285.00, 172.3458, 1.00, 1.00, '888849000210', false, true, true, 22),
  ('8888490000470', 'QUESTBAR COCONUT CASHEW', 'Barras de proteína', 170.00, 98.9567, 0.00, 0.00, '8888490000470', false, true, true, 23),
  ('888849001224', 'QUESTBAR SMORE', 'Barras de proteína', 380.00, 203.0000, 0.00, -1.00, '888849001224', false, true, true, 24),
  ('8410667020174', 'ACEITUNA RELLENA DE JAMON', 'Despensa', 225.00, 120.7627, 20.00, 20.00, '8410667020174', false, true, true, 1),
  ('8410667020419', 'ACEITUNA RELLENO DE JALAPEÑO', 'Despensa', 225.00, 120.7627, 16.00, 16.00, '8410667020419', false, true, true, 2),
  ('8437001130474', 'ACEITUNAS ANCHOAS', 'Despensa', 130.00, 77.6800, 0.00, 0.00, '8437001130474', false, true, true, 3),
  ('8480013190219', 'ACEITUNAS MANZANILLA RELLENAS', 'Despensa', 160.00, 81.2100, 0.00, 0.00, '8480013190219', false, true, true, 4),
  ('8437001130450', 'ACEITUNAS PIMIENTOS', 'Despensa', 130.00, 77.6800, 0.00, 0.00, '8437001130450', false, true, true, 5),
  ('8480013190127', 'ACEITUNAS RELLENAS ANCHOA', 'Despensa', 140.00, 84.7400, 0.00, 0.00, '8480013190127', false, true, true, 6),
  ('8480013190226', 'ACEITUNAS RELLENAS DE PIMIENTO', 'Despensa', 150.00, 90.4000, 0.00, 0.00, '8480013190226', false, true, true, 7),
  ('866213', 'BUMBLE BEE EN ACEITE', 'Despensa', 80.00, 42.3729, 0.00, 0.00, null, false, true, true, 8),
  ('866203', 'BUMBLE BEE LIHT TUNA', 'Despensa', 75.00, 47.6696, 0.00, 0.00, null, false, true, true, 9),
  ('8701471', 'CARDO DE POLLO', 'Despensa', 1800.00, 1262.7100, 1.00, 1.00, null, false, true, true, 10),
  ('8411916202150', 'CELORIO ACERTUNAS RELLENA DE', 'Despensa', 85.00, 56.5000, 0.00, 0.00, '8411916202150', false, true, true, 11),
  ('8852021298445', 'CHERRSTAR ATUN EN ACEITE VEGETAL', 'Despensa', 90.00, 62.0000, 0.00, 0.00, '8852021298445', false, true, true, 12),
  ('8852021002233', 'CHERRYSTAR LIGTH MEAT TUNA', 'Despensa', 90.00, 62.0000, 0.00, 0.00, '8852021002233', false, true, true, 13),
  ('8410159044329', 'FIGARO ACEITUNAS RELLENAS', 'Despensa', 110.00, 56.4973, 0.00, 0.00, '8410159044329', false, true, true, 14),
  ('8410667005706', 'JOLCA ANCHOA', 'Despensa', 155.00, 50.4900, 0.00, 0.00, '8410667005706', false, true, true, 15),
  ('8423329813311', 'LA PEDRIZA ACERTUNA RELLENA DE', 'Despensa', 80.00, 53.0000, 0.00, 0.00, '8423329813311', false, true, true, 16),
  ('7788', 'NESCAFE COOKIS CREAN', 'Despensa', 1000.00, 1632.8200, 0.00, 0.00, null, false, true, true, 17),
  ('7702024004943', 'NESCAFE TRADICION', 'Despensa', 1400.00, 1320.0000, 0.00, 0.00, '7702024004943', false, true, true, 18),
  ('7891000372609', 'NESCAU DE NESTLE', 'Despensa', 2000.00, 1632.8200, 0.00, 0.00, '7891000372609', false, true, true, 19),
  ('8850468611377', 'SARDINAS CHERRY STAR', 'Despensa', 45.00, 24.5900, 0.00, 0.00, '8850468611377', false, true, true, 20),
  ('8410344151504', 'SERPIS ACEITUNA CON ANCHOA', 'Despensa', 135.00, 60.0283, 0.00, 0.00, '8410344151504', false, true, true, 21),
  ('8410344700030', 'SERPIS ACEITUNA PIMIENTO', 'Despensa', 125.00, 60.0283, 0.00, 0.00, '8410344700030', false, true, true, 22),
  ('8410344111508', 'SERPIS ACEITUNAS RELLENAS DE', 'Despensa', 40.00, 25.0000, 0.00, 0.00, '8410344111508', false, true, true, 23),
  ('8434165488663', 'SURTIDO EL AUTENTICO', 'Despensa', 150.00, 84.3800, 0.00, 0.00, '8434165488663', false, true, true, 24),
  ('90000', 'VINAGRE VALSAMICO', 'Despensa', 140.00, 118.0000, 1.00, 1.00, null, false, true, true, 25),
  ('84233299812189', 'HELADOS BON 1 PINTA VARIADOS', 'Comida y helados', 210.00, 81.6650, 0.00, 0.00, '84233299812189', false, true, true, 1),
  ('900', 'HOD-DOG', 'Comida y helados', 65.00, 45.0000, 0.00, 0.00, null, false, true, true, 2),
  ('843182100577', 'A. FUENTE CHATEEAU CIGARRO', 'Cigarrillos y tabaco', 825.00, 450.0000, 0.00, 0.00, '843182100577', false, true, true, 1),
  ('843182100607', 'ARTURO FUENTE', 'Cigarrillos y tabaco', 850.00, 450.0000, 4.00, 4.00, '843182100607', false, true, true, 2),
  ('88', 'CIGARROS TABACOS DOMINICANOS', 'Cigarrillos y tabaco', 125.00, 73.7290, 0.00, 0.00, null, false, true, true, 3),
  ('790690070154', 'CONSTANZA MENTOL GRANDE', 'Cigarrillos y tabaco', 95.00, 115.2540, 0.00, 0.00, '790690070154', false, true, true, 4),
  ('78019423', 'DUNHILL BLONDE BLEND', 'Cigarrillos y tabaco', 200.00, 129.6600, 0.00, 0.00, '78019423', false, true, true, 5),
  ('78019416', 'DUNHILL MASTER BLEND /20', 'Cigarrillos y tabaco', 120.00, 115.2540, 0.00, 0.00, '78019416', false, true, true, 6),
  ('78018662', 'DUNHILL PEQ.', 'Cigarrillos y tabaco', 185.00, 110.7600, 0.00, 0.00, '78018662', false, true, true, 7),
  ('853195000467', 'EAGLE TORCHA', 'Cigarrillos y tabaco', 250.00, 145.0000, 19.00, 19.00, '853195000467', false, true, true, 8),
  ('850043075103', 'ENCENDEDORAS TIPO TORCH POD', 'Cigarrillos y tabaco', 380.00, 200.0000, 2.00, 2.00, '850043075103', false, true, true, 9),
  ('853195000498', 'ENSENDEDORAS DE TABACO EAGLE', 'Cigarrillos y tabaco', 250.00, 150.0000, 0.00, 0.00, '853195000498', false, true, true, 10),
  ('762446440009', 'LONGHORN AZUL', 'Cigarrillos y tabaco', 250.00, 175.0000, 0.00, 0.00, '762446440009', false, true, true, 11),
  ('762446450008', 'LONGHORN NATURAL', 'Cigarrillos y tabaco', 280.00, 175.0000, 0.00, 0.00, '762446450008', false, true, true, 12),
  ('762446420001', 'LONGHORN ROJO', 'Cigarrillos y tabaco', 250.00, 175.0000, 0.00, 0.00, '762446420001', false, true, true, 13),
  ('762446400003', 'LONGHORN WINTERGREEN', 'Cigarrillos y tabaco', 250.00, 175.0000, 0.00, 0.00, '762446400003', false, true, true, 14),
  ('78020856', 'LUCKY STRIKE BLUE GRANDE', 'Cigarrillos y tabaco', 120.00, 80.0000, 0.00, 0.00, '78020856', false, true, true, 15),
  ('78018464', 'LUCKY STRIKE COVERTIBLES', 'Cigarrillos y tabaco', 65.00, 45.0000, 0.00, 0.00, '78018464', false, true, true, 16),
  ('78018068', 'LUCKY STRIKE FRESH CIG. /10', 'Cigarrillos y tabaco', 110.00, 72.0340, 0.00, 0.00, '78018068', false, true, true, 17),
  ('78018501', 'LUCKY STRIKE ORIGINAL CIG /10', 'Cigarrillos y tabaco', 60.00, 43.0085, 0.00, 0.00, '78018501', false, true, true, 18),
  ('78014626', 'LUCKY STRIKE RED GDE.', 'Cigarrillos y tabaco', 100.00, 82.3333, 0.00, 0.00, '78014626', false, true, true, 19),
  ('78014633', 'LUCKY STRIKE SILVER GDE.', 'Cigarrillos y tabaco', 120.00, 83.7933, 0.00, 0.00, '78014633', false, true, true, 20),
  ('810134310650', 'PLASENCIA CIGARROS', 'Cigarrillos y tabaco', 675.00, 355.0000, 0.00, 0.00, '810134310650', false, true, true, 21),
  ('844111003839', 'QUESADA CUBITA ROBUSTO', 'Cigarrillos y tabaco', 350.00, 134.7500, 13.00, 13.00, '844111003839', false, true, true, 22),
  ('762446820009', 'RED MAN', 'Cigarrillos y tabaco', 240.00, 185.0000, 0.00, 0.00, '762446820009', false, true, true, 23),
  ('89012001182', 'SKOAL TABACO VARIADOS', 'Cigarrillos y tabaco', 150.00, 130.0000, 0.00, 0.00, '089012001182', false, true, true, 24),
  ('762446730001', 'WOLF APPLE', 'Cigarrillos y tabaco', 280.00, 185.0000, 0.00, 0.00, '762446730001', false, true, true, 25),
  ('762446703005', 'WOLF COOL WINTERGREEN', 'Cigarrillos y tabaco', 280.00, 185.0000, 0.00, 0.00, '762446703005', false, true, true, 26),
  ('762446706006', 'WOLF MINT', 'Cigarrillos y tabaco', 280.00, 185.0000, 0.00, 0.00, '762446706006', false, true, true, 27),
  ('762446710003', 'WOLF PEACH', 'Cigarrillos y tabaco', 280.00, 185.0000, 0.00, 0.00, '762446710003', false, true, true, 28),
  ('7707200947311', 'VASE GO 5000. MENTHOL ICE', 'Vapes', 720.00, 416.9487, 0.00, 0.00, '7707200947311', false, true, true, 1),
  ('7751201001602', 'VEEV NOW BLUE RASPBERRY.8000', 'Vapes', 1050.00, 600.0000, 0.00, 0.00, '7751201001602', false, true, true, 2),
  ('7702303182898', 'VUSE GO 3000 APPLE SOUR', 'Vapes', 600.00, 345.0000, 0.00, -1.00, '7702303182898', false, true, true, 3),
  ('7702303936590', 'VUSE GO 3000 BLUE RASPBERRY', 'Vapes', 600.00, 345.0000, 17.00, 17.00, '7702303936590', false, true, true, 4),
  ('7702303023221', 'VUSE GO 3000 MENTHOL', 'Vapes', 600.00, 345.0000, 0.00, 0.00, '7702303023221', false, true, true, 5),
  ('7707200941951', 'VUSE GO 8000 BLUEBERRY', 'Vapes', 900.00, 555.9320, 2.00, 2.00, '7707200941951', false, true, true, 6),
  ('7707200941661', 'VUSE GO 8000 GREEN APPLE', 'Vapes', 900.00, 555.9320, 2.00, 2.00, '7707200941661', false, true, true, 7),
  ('7707200942835', 'VUSE GO 8000 MENTHOL ICE', 'Vapes', 900.00, 555.9320, 0.00, 0.00, '7707200942835', false, true, true, 8),
  ('7707200940282', 'VUSE GO 8000 WATERMELON ICE', 'Vapes', 900.00, 555.9320, 0.00, 0.00, '7707200940282', false, true, true, 9),
  ('7702303809511', 'VUSE GO BERRY WAT FRUTOS R', 'Vapes', 520.00, 312.7100, 0.00, 0.00, '7702303809511', false, true, true, 10),
  ('7702303404068', 'VUSE GO MANGO', 'Vapes', 520.00, 312.7100, 0.00, 0.00, '7702303404068', false, true, true, 11),
  ('7702303721387', 'VUSE GO MENTA ICE', 'Vapes', 520.00, 312.7100, 0.00, 0.00, '7702303721387', false, true, true, 12),
  ('7702303401944', 'VUSE GO SANDIA', 'Vapes', 520.00, 312.7100, 0.00, 0.00, '7702303401944', false, true, true, 13),
  ('7702303142427', 'VUSE GO STRAWBERRY ICE ... FRESA', 'Vapes', 520.00, 312.7100, 0.00, 0.00, '7702303142427', false, true, true, 14),
  ('7702303246743', 'VUSE GOBERRY BLEN FRUTOS R', 'Vapes', 520.00, 312.7100, 0.00, 0.00, '7702303246743', false, true, true, 15),
  ('7702303027878', 'VUSEGO MAX GRAPE ICE 1500', 'Vapes', 865.00, 521.0000, 0.00, 0.00, '7702303027878', false, true, true, 16),
  ('7702303915199', 'VUSEGO MAX MENTHOL ICE', 'Vapes', 865.00, 521.0000, 0.00, 0.00, '7702303915199', false, true, true, 17),
  ('7702303617000', 'VUSEGO MAX WATERMELON 1500', 'Vapes', 865.00, 521.0000, 0.00, 0.00, '7702303617000', false, true, true, 18),
  ('7702303923477', 'VUSESE GO ARANDANOS', 'Vapes', 520.00, 312.7100, 0.00, 0.00, '7702303923477', false, true, true, 19),
  ('8904169416899', 'AMPICILLIN', 'Farmacia, higiene y hogar', 30.00, null, 0.00, 0.00, '8904169416899', false, false, false, 1),
  ('857424000341', 'ASSEPTGEL HAND SANITIZER 2 ONZ', 'Farmacia, higiene y hogar', 60.00, 40.0000, 0.00, 0.00, '857424000341', false, true, true, 2),
  ('8906101702589', 'BOSSMAN PRESERVATIVOS ECO', 'Farmacia, higiene y hogar', 70.00, 25.0000, 11.00, 11.00, '8906101702589', false, true, true, 3),
  ('84233299812166', 'DRAMANOL 50MG', 'Farmacia, higiene y hogar', 20.00, 9.6000, 0.00, 0.00, '84233299812166', false, true, true, 4),
  ('808829032079', 'LUCKY LIQUID SOAP ALMOND', 'Farmacia, higiene y hogar', 85.00, 56.5000, 0.00, 0.00, '808829032079', false, true, true, 5),
  ('808829032130', 'LUCKY LIQUID SOAP MELON', 'Farmacia, higiene y hogar', 85.00, 56.5000, 0.00, 0.00, '808829032130', false, true, true, 6),
  ('7702027041020', 'NOSOTRAS INVISIBLES UNIDAD', 'Farmacia, higiene y hogar', 15.00, 6.3600, 7.00, 7.00, '7702027041020', false, true, true, 7),
  ('7702027494901', 'NOSOTRAS PLUS TELA 60 TOALLAS', 'Farmacia, higiene y hogar', 20.00, 7.0000, 106.00, 106.00, '7702027494901', false, true, true, 8),
  ('7702027044168', 'NOSOTRAS PROTECTOR DIARIO 120', 'Farmacia, higiene y hogar', 15.00, 6.3600, 0.00, 0.00, '7702027044168', false, true, true, 9),
  ('7702027402777', 'NOSOTRAS TOALLAS NATURAL', 'Farmacia, higiene y hogar', 15.00, 32.3000, 0.00, -13.00, '7702027402777', false, true, true, 10),
  ('84233299812177', 'NUBELUZ-SERVILLETAS PQ', 'Farmacia, higiene y hogar', 20.00, 7.0000, 0.00, 0.00, '84233299812177', false, true, true, 11),
  ('8010052120009', 'PALILLOS SUPER', 'Farmacia, higiene y hogar', 10.00, 5.0000, 0.00, 0.00, '8010052120009', false, true, true, 12),
  ('7702026016616', 'PAPEL DE BAÑOFAMILIA 2EN 1', 'Farmacia, higiene y hogar', 25.00, 38.1358, 0.00, 0.00, '7702026016616', false, true, true, 13),
  ('84115560', 'PECTOL EUCALIPTUS', 'Farmacia, higiene y hogar', 25.00, 16.2971, 0.00, 0.00, '84115560', false, true, true, 14),
  ('7702035372154', 'SINUTA CONGESTION Y GRIPE CALIENTE', 'Farmacia, higiene y hogar', 40.00, 25.0000, 0.00, 0.00, '7702035372154', false, true, true, 15),
  ('7702134372208', 'SINUTAB PASTILLA', 'Farmacia, higiene y hogar', 10.00, 5.0000, 0.00, 0.00, '7702134372208', false, true, true, 16),
  ('7702031787570', 'STAYFREE ESPECIAL 2X3', 'Farmacia, higiene y hogar', 120.00, 85.0000, 0.00, 0.00, '7702031787570', false, true, true, 17),
  ('8901790682938', 'SUNLIN ANTIGRIPAL CAPLETA', 'Farmacia, higiene y hogar', 10.00, 5.0000, 0.00, 0.00, '8901790682938', false, true, true, 18),
  ('7702418004825', 'VITAMINA C CEBION 500.MG', 'Farmacia, higiene y hogar', 250.00, 145.0000, 2.00, 2.00, '7702418004825', false, true, true, 19),
  ('826942010088', 'ALFOMBRA METRO CREMA', 'Automotriz', 450.00, 290.8900, 0.00, 0.00, '826942010088', false, true, true, 1),
  ('826942010026', 'ALFOMBRA METRO GRIS', 'Automotriz', 450.00, 290.8900, 0.00, 0.00, '826942010026', false, true, true, 2),
  ('826942010033', 'ALFOMBRA METRO GRIS RATON', 'Automotriz', 450.00, 279.7000, 0.00, 0.00, '826942010033', false, true, true, 3),
  ('826942010071', 'ALFOMBRA METRO MARRON', 'Automotriz', 450.00, 279.7000, 0.00, 0.00, '826942010071', false, true, true, 4),
  ('826942010019', 'ALFOMBRA METRO NEGRA', 'Automotriz', 450.00, 290.8900, 0.00, 0.00, '826942010019', false, true, true, 5),
  ('826942654909', 'ALFOMBRA MOTOR TREND GRIS', 'Automotriz', 1150.00, 772.5000, 0.00, 0.00, '826942654909', false, true, true, 6),
  ('826942654893', 'ALFOMBRA MOTOR TREND NEGRA', 'Automotriz', 1150.00, 772.5000, 0.00, 0.00, '826942654893', false, true, true, 7),
  ('826942654916', 'ALFOMBRE DE GOMA BEIGE 4PIECES', 'Automotriz', 1150.00, 733.8700, 0.00, 0.00, '826942654916', false, true, true, 8),
  ('84121130068', 'AMBIENTADOR MONEY CANELA', 'Automotriz', 100.00, 64.0000, 0.00, 0.00, '084121130068', false, true, true, 9),
  ('84121130013', 'AMBIENTADOR MONEY HOUSE', 'Automotriz', 100.00, 64.0000, 0.00, 0.00, '084121130013', false, true, true, 10),
  ('84121130044', 'AMBIENTADOR MONEY PATPOURRI', 'Automotriz', 100.00, 64.0000, 0.00, 0.00, '084121130044', false, true, true, 11),
  ('84233299812161', 'CORREA ROULUNDS 03PK0540R', 'Automotriz', 120.00, 76.0000, 0.00, 0.00, '84233299812161', false, true, true, 12),
  ('84233299812162', 'CORREA ROULUNDS 3K 0550', 'Automotriz', 120.00, 77.0000, 0.00, 0.00, '84233299812162', false, true, true, 13),
  ('84233299812159', 'CORREA ROULUNDS 3K 1050', 'Automotriz', 160.00, 125.0000, 0.00, 0.00, '84233299812159', false, true, true, 14),
  ('84233299812157', 'CORREA ROULUNDS 3K 1150', 'Automotriz', 190.00, 134.0000, 0.00, 0.00, '84233299812157', false, true, true, 15),
  ('84233299812160', 'CORREA ROULUNDS 6K 2415', 'Automotriz', 650.00, 475.0000, 0.00, 0.00, '84233299812160', false, true, true, 16),
  ('84233299812156', 'CORREA ROULUNDS A4PKK1295R', 'Automotriz', 250.00, 190.0000, 0.00, 0.00, '84233299812156', false, true, true, 17),
  ('89269000457', 'CYCLO ACONDICIONADOR DE', 'Automotriz', 145.00, 105.0000, 0.00, 0.00, '089269000457', false, true, true, 18),
  ('89269000198', 'CYCLO MOTOR FLUSH 15 ONZ', 'Automotriz', 120.00, 83.0000, 0.00, 0.00, '089269000198', false, true, true, 19),
  ('8000', 'EMBUDO USO INTERNO', 'Automotriz', 68.00, 120.0000, 0.00, 0.00, null, false, false, false, 20),
  ('8877', 'FORRO DE GUIA SURTIDO', 'Automotriz', 230.00, 146.6757, 0.00, 0.00, null, false, true, true, 21),
  ('80', 'GRAPA DE TRIA VEHICULO', 'Automotriz', 50.00, 30.0000, 0.00, 0.00, null, false, true, true, 22),
  ('842071002657', 'HALVOLINE 10W40 1/4', 'Automotriz', 200.00, 143.3617, 0.00, 0.00, '842071002657', false, true, true, 23),
  ('842071002381', 'HAVOLINE 10W30 1/4', 'Automotriz', 260.00, 167.4093, 0.00, 0.00, '842071002381', false, true, true, 24),
  ('842071002411', 'HAVOLINE 20-W-50', 'Automotriz', 275.00, 167.4093, 0.00, 0.00, '842071002411', false, true, true, 25),
  ('842071002428', 'HAVOLINE 20W-50 GALON', 'Automotriz', 850.00, 553.4000, 0.00, 0.00, '842071002428', false, true, true, 26),
  ('842071002442', 'HAVOLINE ATF TRANSMISION', 'Automotriz', 260.00, 155.0835, 0.00, 0.00, '842071002442', false, true, true, 27),
  ('7705808449169', 'HAVOLINE OUT BOART 2T PQ', 'Automotriz', 160.00, 92.5275, 0.00, 0.00, '7705808449169', false, true, true, 28),
  ('842071002725', 'HAVOLINE OUT BOART GD 2T', 'Automotriz', 260.00, 161.0333, 0.00, 0.00, '842071002725', false, true, true, 29),
  ('842071003302', 'HAVOLINE SAE 50 1/4', 'Automotriz', 250.00, 154.5000, 0.00, 0.00, '842071003302', false, true, true, 30),
  ('810822013313', 'JUICE AIR CHERRY AMBIENTADOR', 'Automotriz', 140.00, 87.5000, 0.00, 0.00, '810822013313', false, true, true, 31),
  ('810822013252', 'JUICE AIR POMEGRANATE', 'Automotriz', 140.00, 87.5000, 0.00, 0.00, '810822013252', false, true, true, 32),
  ('810822013306', 'JUICE COCONUT VENT STICK', 'Automotriz', 140.00, 87.5000, 0.00, 0.00, '810822013306', false, true, true, 33),
  ('810822014860', 'JUICE FRESH LIMEN SLIN SPRAY', 'Automotriz', 125.00, 71.1000, 0.00, 0.00, '810822014860', false, true, true, 34),
  ('810822013276', 'JUICE FRESH LINEN VENT STICK', 'Automotriz', 140.00, 87.5000, 0.00, 0.00, '810822013276', false, true, true, 35),
  ('810822013283', 'JUICE LAVENDER VANILLA VENT STICK', 'Automotriz', 140.00, 87.5000, 0.00, 0.00, '810822013283', false, true, true, 36),
  ('810822014853', 'JUICE MIDNIGHT SLIN SPRAY', 'Automotriz', 125.00, 71.1000, 0.00, 0.00, '810822014853', false, true, true, 37),
  ('810822013290', 'JUICE MIDNIGHT VENT STICK', 'Automotriz', 140.00, 87.5000, 0.00, 0.00, '810822013290', false, true, true, 38),
  ('810822013269', 'JUICE NEW CAR NENT STICK', 'Automotriz', 140.00, 87.5000, 0.00, 0.00, '810822013269', false, true, true, 39),
  ('810822014846', 'JUICE STRAWBERRY SLIM SPRAY', 'Automotriz', 125.00, 87.5000, 0.00, 0.00, '810822014846', false, true, true, 40),
  ('810822013245', 'JUICE STRAWBERRY VENT STICK', 'Automotriz', 140.00, 87.5000, 0.00, 0.00, '810822013245', false, true, true, 41),
  ('769848100746', 'KWIK LIMPIADOR USO EN ESPUMA', 'Automotriz', 210.00, 134.0000, 0.00, 0.00, '769848100746', false, true, true, 42),
  ('79238046180', 'LEXOR ESCOBILLA 18', 'Automotriz', 330.00, 219.0000, 0.00, 0.00, '079238046180', false, true, true, 43),
  ('84233299812175', 'LION SILICON CLEAR', 'Automotriz', 150.00, 85.0000, 0.00, 0.00, '84233299812175', false, true, true, 44),
  ('84233299812165', 'LION SILICON GRIS', 'Automotriz', 160.00, 91.0000, 0.00, 0.00, '84233299812165', false, true, true, 45),
  ('84233299812194', 'LLAVE RUEDA EN CRUZ REFORZADA', 'Automotriz', 350.00, 215.0000, 0.00, 0.00, '84233299812194', false, true, true, 46),
  ('79191514009', 'OIL FILTER GRANDES', 'Automotriz', 160.00, 86.0000, 0.00, 0.00, '079191514009', false, true, true, 47),
  ('76333113939', 'OIL FILTRO PURALATOR L12222', 'Automotriz', 370.00, 277.0000, 0.00, 0.00, '076333113939', false, true, true, 48),
  ('859196130080', 'PRECISA COOLANT ROJO 1GL', 'Automotriz', 190.00, 92.0062, 0.00, 0.00, '859196130080', false, true, true, 49),
  ('797496878892', 'PRESTONE BUG WASH GALON', 'Automotriz', 395.00, 250.5867, 0.00, 0.00, '797496878892', false, true, true, 50),
  ('797496863362', 'PRESTONE CARB & CHOKE CLEANER', 'Automotriz', 190.00, 80.0000, 0.00, 0.00, '797496863362', false, true, true, 51),
  ('797496871541', 'PRESTONE COOLANT GALON', 'Automotriz', 800.00, 519.5500, 0.00, 0.00, '797496871541', false, true, true, 52),
  ('797496861573', 'PRESTONE DESENGRASADOR DE', 'Automotriz', 160.00, 105.0000, 0.00, 0.00, '797496861573', false, true, true, 53),
  ('797496865632', 'PRESTONE DEX - COOL', 'Automotriz', 850.00, 506.0000, 0.00, 0.00, '797496865632', false, true, true, 54),
  ('797496860606', 'PRESTONE INTERIIOR CLEANER 18 OZ', 'Automotriz', 280.00, 177.0200, 0.00, 0.00, '797496860606', false, true, true, 55),
  ('797496871343', 'PRESTONE LIMPIADOR DE CARBURADOR', 'Automotriz', 190.00, 121.8888, 0.00, 0.00, '797496871343', false, true, true, 56),
  ('797496861559', 'PRESTONE LIMPIADOR DE INTERIORES', 'Automotriz', 210.00, 140.0000, 0.00, 0.00, '797496861559', false, true, true, 57),
  ('797496658128', 'PRESTONE OIL ADITIVO', 'Automotriz', 120.00, 110.0000, 0.00, 0.00, '797496658128', false, true, true, 58),
  ('797496875723', 'PRESTONE POWER STEERING AMARILLO', 'Automotriz', 125.00, 69.1740, 0.00, 0.00, '797496875723', false, true, true, 59),
  ('797496865489', 'PRESTONE WHEEL LIMPIADOR DE ARO', 'Automotriz', 170.00, 115.0000, 0.00, 0.00, '797496865489', false, true, true, 60),
  ('853313006012', 'REPARADOR Y ACONDICIONADOR DE', 'Automotriz', 250.00, 199.9100, 0.00, 0.00, '853313006012', false, true, true, 61),
  ('8081', 'SILICON GUNK', 'Automotriz', 325.00, null, 0.00, 0.00, null, false, true, true, 62),
  ('7805040751126', 'SILICONA MAXIMA PROTECCION 400CC', 'Automotriz', 220.00, 159.0000, 0.00, 0.00, '7805040751126', false, true, true, 63),
  ('797496862341', 'TRANS TAPA-FUGAS', 'Automotriz', 100.00, 1464.7490, 0.00, 0.00, '797496862341', false, true, true, 64),
  ('842071002527', 'URSA 40 1/4', 'Automotriz', 260.00, 175.0000, 0.00, 0.00, '842071002527', false, true, true, 65),
  ('842071002565', 'URSA 50 1/4', 'Automotriz', 260.00, 175.0000, 0.00, 0.00, '842071002565', false, true, true, 66),
  ('842071002534', 'URSA GALON', 'Automotriz', 850.00, 499.1417, 0.00, 0.00, '842071002534', false, true, true, 67),
  ('842071002664', 'URSA HD 15W40 GALON', 'Automotriz', 795.00, 499.1417, 0.00, 0.00, '842071002664', false, true, true, 68);

-- filas 801–828
insert into _p007 (codigo, name, categoria, price, cost, qty, qty_listado, barcode, is_bev, activo, inventariable, posicion) values
  ('769848100722', 'WEST ESPUMA LOCA 19 ONZ', 'Automotriz', 430.00, 285.0000, 0.00, 0.00, '769848100722', false, true, true, 69),
  ('769848100708', 'WEST-PINESPUMA 20 ONZ', 'Automotriz', 430.00, 285.0000, 0.00, 0.00, '769848100708', false, true, true, 70),
  ('769848100715', 'WEST-PINESPUMA 4 ONZ', 'Automotriz', 190.00, 159.0000, 0.00, 0.00, '769848100715', false, true, true, 71),
  ('79238011133', 'WIPER BLADE #13', 'Automotriz', 100.00, 75.0000, 0.00, 0.00, '079238011133', false, true, true, 72),
  ('79238011164', 'WIPER BLADE #16', 'Automotriz', 100.00, 66.0000, 0.00, 0.00, '079238011164', false, true, true, 73),
  ('79238011188', 'WIPER BLADE #18', 'Automotriz', 100.00, 67.0000, 0.00, 0.00, '079238011188', false, true, true, 74),
  ('79238011508', 'WIPER BLADE #19', 'Automotriz', 120.00, 78.0000, 0.00, 0.00, '079238011508', false, true, true, 75),
  ('79238011225', 'WIPER BLADE #22', 'Automotriz', 110.00, 78.0000, 0.00, 0.00, '079238011225', false, true, true, 76),
  ('79238011478', 'WIPER BLADE 17', 'Automotriz', 120.00, 75.0000, 0.00, 0.00, '079238011478', false, true, true, 77),
  ('79238011492', 'WIPER BLADE 20', 'Automotriz', 150.00, 100.0000, 0.00, 0.00, '079238011492', false, true, true, 78),
  ('79238011157', 'WIPER BLANDE #15', 'Automotriz', 100.00, 66.0000, 0.00, 0.00, '079238011157', false, true, true, 79),
  ('84233299812153', 'BOLSA DE REGALO VARIADAS', 'Misceláneos', 35.00, 19.0000, 0.00, 0.00, '84233299812153', false, true, true, 1),
  ('8409730014714', 'BOLSA PARA BOT. BRILLANTE S-4256', 'Misceláneos', 50.00, 15.0000, 0.00, 0.00, '8409730014714', false, true, true, 2),
  ('801', 'BOTELLAS VACIAS', 'Misceláneos', 2.00, null, 0.00, 0.00, null, false, false, false, 3),
  ('77', 'CINTA PEGANTE PQ', 'Misceláneos', 30.00, 12.0000, 0.00, 0.00, null, false, true, true, 4),
  ('84233299812171', 'CINTA PERGANTE GD', 'Misceláneos', 40.00, 19.0000, 0.00, 0.00, '84233299812171', false, true, true, 5),
  ('801248667334', 'CORDON LLAVERO BANDERA', 'Misceláneos', 175.00, 75.0000, 10.00, 10.00, '801248667334', false, true, true, 6),
  ('783094020115', 'FOCOS RAYOVAC', 'Misceláneos', 125.00, 75.0000, 0.00, 0.00, '783094020115', false, true, true, 7),
  ('800', 'HUACALES CERVECERIA', 'Misceláneos', 135.00, 100.0000, 0.00, 0.00, null, false, true, true, 8),
  ('850051002009', 'POLAOID CAMARA DESECHABLE', 'Misceláneos', 330.00, 220.0000, 0.00, 0.00, '850051002009', false, true, true, 9),
  ('7878', 'REFRIGERIO,JUGOS', 'Misceláneos', 1375.00, 8442.9900, 0.00, 0.00, null, false, false, false, 10),
  ('8888', 'RENTA DE LOCAL', 'Misceláneos', 30000.00, null, 0.00, 0.00, null, false, false, false, 11),
  ('8606004528650', 'SHOPPING REF. CFMM29', 'Misceláneos', 60.00, 14.4100, 0.00, 0.00, '8606004528650', false, true, true, 12),
  ('802141257264', 'SHOPPING REF.RR-8013-S-S', 'Misceláneos', 45.00, 15.0000, 0.00, 0.00, '802141257264', false, true, true, 13),
  ('818043000013', 'SINGLE USE CAMERA 24EXP.', 'Misceláneos', 290.00, 1.0000, 0.00, 0.00, '818043000013', false, true, true, 14),
  ('84233299812193', 'STRIPE LINES CINTA DECORATIVA', 'Misceláneos', 70.00, 45.0000, 0.00, 0.00, '84233299812193', false, true, true, 15),
  ('840034240313', 'THERMO 40 ONZ', 'Misceláneos', 400.00, 240.0000, 0.00, 0.00, '840034240313', false, true, true, 16),
  ('8714786213760', 'TIVETY ABANICO', 'Misceláneos', 300.00, 208.9166, 0.00, 0.00, '8714786213760', false, true, true, 17);

create temp table _p007_categorias (
  name     text primary key,
  posicion int  not null
) on commit drop;

insert into _p007_categorias (name, posicion) values
  ('Cervezas', 10),
  ('Licores', 20),
  ('Vinos y espumantes', 30),
  ('Premix y cócteles', 40),
  ('Refrescos y energizantes', 50),
  ('Jugos, tés y lácteos', 60),
  ('Aguas', 70),
  ('Snacks salados', 80),
  ('Galletas y bizcochos', 90),
  ('Chocolates', 100),
  ('Chicles y caramelos', 110),
  ('Dulces típicos', 120),
  ('Barras de proteína', 130),
  ('Despensa', 140),
  ('Comida y helados', 150),
  ('Cigarrillos y tabaco', 160),
  ('Vapes', 170),
  ('Farmacia, higiene y hogar', 180),
  ('Automotriz', 190),
  ('Misceláneos', 200);

do $$
declare
  v_business     uuid := '3c5c3b8e-28e6-45f0-8dc7-85e3efe8d30c';
  v_total        int  := 828;
  v_tax_id       uuid;
  v_menu_id      uuid;
  v_menus        int;
  v_kitchen      boolean;
  v_mode         text;
  v_area_id      uuid;
  v_area_code    text;
  v_wh_id        uuid;
  v_wh_name      text;
  v_wh_active    boolean;
  v_n            int;
  v_list         text;
  v_nuevos       int;
  v_actualizados int;
  v_insumos      int;
  v_movs         int;
begin
  -- =========================================================================
  -- 1) GUARDAS — se comprueba todo ANTES de escribir una sola fila.
  -- =========================================================================

  -- 1a) El negocio existe.
  if not exists (select 1 from public.businesses where id = v_business) then
    raise exception 'El negocio % no existe.', v_business;
  end if;

  -- 1b) Un ITBIS 18%% activo, y uno solo.
  select count(*) into v_n
  from public.taxes t
  where t.business_id = v_business
    and t.name ilike '%itbis%'
    and t.rate = 18
    and coalesce(t.is_active, true);

  if v_n = 0 then
    select string_agg(format('%s %s%% (%s)', t.name, t.rate,
             case when coalesce(t.is_active, true) then 'activo' else 'INACTIVO' end),
           ', ')
      into v_list
    from public.taxes t
    where t.business_id = v_business;

    raise exception
      'No hay un ITBIS 18%% activo en este negocio (impuestos que tiene: %). '
      'Créalo en Ajustes → Impuestos y vuelve a correr.',
      coalesce(v_list, 'ninguno');
  elsif v_n > 1 then
    raise exception
      'Hay % impuestos ITBIS 18%% activos. Deja uno solo antes de cargar.', v_n;
  end if;

  select t.id into v_tax_id
  from public.taxes t
  where t.business_id = v_business
    and t.name ilike '%itbis%'
    and t.rate = 18
    and coalesce(t.is_active, true);

  -- 1c) is_service_fee apagado: encendido, la factura lo cobra DOS veces.
  if exists (select 1 from public.taxes
             where id = v_tax_id and coalesce(is_service_fee, false)) then
    raise exception
      'El ITBIS tiene is_service_fee = true: la factura lo cobraría DOS veces. '
      'Apágalo antes de cargar.';
  end if;

  -- 1d) Ajustes del negocio: la fila existe y no hay propina por orden.
  select coalesce(bs.kitchen_enabled, true), coalesce(bs.inventory_mode, 'none')
    into v_kitchen, v_mode
  from public.business_settings bs
  where bs.business_id = v_business;

  if not found then
    raise exception
      'El negocio no tiene fila en business_settings. Entra una vez a Ajustes '
      'en la app y vuelve a correr.';
  end if;

  if exists (select 1 from public.business_settings
             where business_id = v_business
               and coalesce(service_fee_enabled, false)) then
    raise exception
      'business_settings.service_fee_enabled está en true: cobraría un 10%% '
      'por orden que este negocio no cobra. Apágalo primero.';
  end if;

  -- 1e) Ningún código del listado apunta a VARIOS productos o insumos: no
  --     sabría cuál actualizar.
  select string_agg(format('%s (%s productos)', p.codigo, x.n), ', ')
    into v_list
  from _p007 p
  cross join lateral (
    select count(*) as n
    from public.menu_items mi
    where mi.business_id = v_business
      and (mi.sku = p.codigo or mi.barcode = p.codigo
           or (p.barcode is not null and mi.barcode = p.barcode))
  ) x
  where x.n > 1;

  if v_list is not null then
    raise exception
      'Códigos del listado que ya tienen VARIOS productos, no sé cuál '
      'actualizar: %', v_list;
  end if;

  select string_agg(format('%s (%s insumos)', p.codigo, x.n), ', ')
    into v_list
  from _p007 p
  cross join lateral (
    select count(*) as n
    from public.inventory_items ii
    where ii.business_id = v_business
      and (ii.sku = p.codigo or ii.barcode = p.codigo
           or (p.barcode is not null and ii.barcode = p.barcode))
  ) x
  where x.n > 1;

  if v_list is not null then
    raise exception
      'Códigos del listado que ya tienen VARIOS insumos, no sé cuál usar: %',
      v_list;
  end if;

  -- 1f) Menú: 0 se crea, 1 se reusa, más de 1 aborta.
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

  -- 1g) Bodega: la MISMA que escoge consume_inventory_from_order al vender
  --     (mismo ORDER BY). Si la existencia entra en otra, la venta descuenta
  --     de una bodega vacía.
  select w.id, w.name, coalesce(w.is_active, true)
    into v_wh_id, v_wh_name, v_wh_active
  from public.warehouses w
  where w.business_id = v_business
  order by w.is_main desc, w.created_at asc nulls first, w.id asc
  limit 1;

  if v_wh_id is null then
    raise exception
      'El negocio no tiene bodega. Créala en Inventario → Bodegas, márcala '
      'como principal y vuelve a correr.';
  end if;

  if not v_wh_active or v_wh_name = '__IN_TRANSIT__' then
    raise exception
      'La bodega de la que descuenta la venta es "%" (desactivada o de '
      'tránsito). Marca la bodega real como principal y vuelve a correr.',
      v_wh_name;
  end if;

  -- 1h) Área de comanda (ver encabezado).
  if v_kitchen then
    select count(*), string_agg(format('%s (%s)', name, code), ', ')
      into v_n, v_list
    from public.print_areas
    where business_id = v_business
      and is_active
      and code not in ('cashier', 'fiscal', 'cash_close');

    select id, code into v_area_id, v_area_code
    from public.print_areas
    where business_id = v_business
      and is_active
      and code in ('bar', 'barra')
    order by case code when 'bar' then 0 else 1 end
    limit 1;

    if v_area_id is null then
      if v_n = 1 then
        select id, code into v_area_id, v_area_code
        from public.print_areas
        where business_id = v_business
          and is_active
          and code not in ('cashier', 'fiscal', 'cash_close');
      elsif v_n = 0 then
        raise exception
          'Cocina está ENCENDIDA (kitchen_enabled) y no hay ninguna área de '
          'comanda: cada venta fallaría al mandar a cocina. Si es una tienda, '
          'apaga Cocina en Ajustes y vuelve a correr (los productos pasan '
          'directo, sin comanda). Si sí quieren comanda, crea el área "Barra" '
          'en Ajustes → Impresoras.';
      else
        raise exception
          'Cocina está encendida y hay % áreas de comanda activas (%), '
          'ninguna "bar"/"barra". Dime a cuál van los productos.', v_n, v_list;
      end if;
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
  -- 3) CATEGORÍAS — crea las que falten; las que ya existen se respetan.
  -- =========================================================================

  insert into public.categories (id, business_id, name, position, is_active)
  select gen_random_uuid(), v_business, c.name, c.posicion, true
  from _p007_categorias c
  where not exists (
    select 1 from public.categories x
    where x.business_id = v_business
      and lower(btrim(x.name)) = lower(c.name)
  );

  -- =========================================================================
  -- 4) PRODUCTOS — por código. Actualiza los que existen, inserta los demás.
  -- =========================================================================

  create temp table _p007_ids (
    codigo text primary key,
    id     uuid not null,
    nuevo  boolean not null
  ) on commit drop;

  insert into _p007_ids (codigo, id, nuevo)
  select p.codigo, mi.id, false
  from _p007 p
  join public.menu_items mi
    on mi.business_id = v_business
   and (mi.sku = p.codigo or mi.barcode = p.codigo
        or (p.barcode is not null and mi.barcode = p.barcode));

  -- Un mismo producto calzando con DOS códigos del listado: no sé cuál es.
  select string_agg(format('%s ← %s', mi.name, z.codigos), '; ')
    into v_list
  from (
    select id, string_agg(codigo, ', ') as codigos
    from _p007_ids group by id having count(*) > 1
  ) z
  join public.menu_items mi on mi.id = z.id;

  if v_list is not null then
    raise exception
      'Productos que calzan con varios códigos del listado a la vez: %', v_list;
  end if;

  update public.menu_items mi
  set category_id         = cat.id,
      price               = p.price,
      cost                = p.cost,
      tax_mode            = 'inclusive',
      sku                 = p.codigo,
      barcode             = coalesce(p.barcode, mi.barcode),
      is_beverage         = p.is_bev,
      is_active           = case when p.activo then mi.is_active else false end,
      position            = p.posicion,
      print_area_code     = v_area_code,
      allow_negative_sale = true,
      updated_at          = now()
  from _p007_ids i
  join _p007 p on p.codigo = i.codigo
  cross join lateral (
    select c.id from public.categories c
    where c.business_id = v_business
      and lower(btrim(c.name)) = lower(p.categoria)
    order by c.created_at
    limit 1
  ) cat
  where mi.id = i.id;
  get diagnostics v_actualizados = row_count;

  insert into public.menu_items (
    id, business_id, category_id, name, price, cost, tax_mode, sku, barcode,
    is_active, is_beverage, position, print_area_code, allow_negative_sale
  )
  select gen_random_uuid(), v_business, cat.id, p.name, p.price, p.cost,
         'inclusive', p.codigo, p.barcode, p.activo, p.is_bev, p.posicion,
         v_area_code, true
  from _p007 p
  cross join lateral (
    select c.id from public.categories c
    where c.business_id = v_business
      and lower(btrim(c.name)) = lower(p.categoria)
    order by c.created_at
    limit 1
  ) cat
  where not exists (select 1 from _p007_ids i where i.codigo = p.codigo);
  get diagnostics v_nuevos = row_count;

  insert into _p007_ids (codigo, id, nuevo)
  select p.codigo, mi.id, true
  from _p007 p
  join public.menu_items mi
    on mi.business_id = v_business
   and mi.sku = p.codigo
  where not exists (select 1 from _p007_ids i where i.codigo = p.codigo);

  -- =========================================================================
  -- 5) IMPUESTOS — exactamente el ITBIS. Otro impuesto vinculado (una Ley de
  --    antes) se quita: este negocio no la cobra.
  -- =========================================================================

  delete from public.menu_item_taxes mit
  using _p007_ids i
  where mit.item_id = i.id
    and mit.tax_id <> v_tax_id;

  insert into public.menu_item_taxes (item_id, tax_id)
  select i.id, v_tax_id
  from _p007_ids i
  where not exists (
    select 1 from public.menu_item_taxes x
    where x.item_id = i.id and x.tax_id = v_tax_id
  );

  -- =========================================================================
  -- 6) ÁREA DE COMANDA (N:M). El legacy ya quedó escrito en el paso 4.
  --    Sin área (cocina apagada) se borran las asignaciones que hubiera; con
  --    área, se borran las de otras áreas para no imprimir por DOS lados.
  -- =========================================================================

  delete from public.menu_item_print_areas x
  using _p007_ids i
  where x.menu_item_id = i.id
    and (v_area_id is null or x.print_area_id <> v_area_id);

  if v_area_id is not null then
    insert into public.menu_item_print_areas (menu_item_id, print_area_id)
    select i.id, v_area_id
    from _p007_ids i
    where not exists (
      select 1 from public.menu_item_print_areas x
      where x.menu_item_id = i.id and x.print_area_id = v_area_id
    );
  end if;

  -- =========================================================================
  -- 7) ENLACE AL MENÚ — sin esto el producto no aparece en la caja.
  -- =========================================================================

  insert into public.menu_item_links (menu_id, item_id, position)
  select v_menu_id, i.id, p.posicion
  from _p007_ids i
  join _p007 p on p.codigo = i.codigo
  where not exists (
    select 1 from public.menu_item_links l
    where l.menu_id = v_menu_id and l.item_id = i.id
  );

  -- =========================================================================
  -- 8) INVENTARIO — un insumo por producto, emparejado por CÓDIGO.
  --    Por nombre no: hay 8 nombres repetidos y cruzarían los descuentos
  --    (vender un MUSCLE MILK descontaría el otro).
  --    DML directo y no fn_menu_item_set_inventory_tracked: esa función exige
  --    auth.uid() con rol, y desde el SQL Editor es null (INSUFFICIENT_ROLE).
  -- =========================================================================

  create temp table _p007_insumos (
    codigo  text primary key,
    item_id uuid
  ) on commit drop;

  -- 8a) El insumo que el producto ya tenga enlazado, o uno que calce por código.
  insert into _p007_insumos (codigo, item_id)
  select p.codigo,
         coalesce(
           (select mi.inventory_item_id
              from public.menu_items mi
             where mi.id = i.id),
           (select ii.id
              from public.inventory_items ii
             where ii.business_id = v_business
               and (ii.sku = p.codigo or ii.barcode = p.codigo
                    or (p.barcode is not null and ii.barcode = p.barcode))
             limit 1)
         )
  from _p007 p
  join _p007_ids i on i.codigo = p.codigo
  where p.inventariable;

  -- 8b) Los que faltan se crean, con el mismo nombre que el producto.
  insert into public.inventory_items (
    business_id, sku, barcode, name, unit, cost, is_active
  )
  select v_business, p.codigo, p.barcode, p.name, 'unidad',
         coalesce(p.cost, 0), true
  from _p007 p
  join _p007_insumos s on s.codigo = p.codigo
  where s.item_id is null;
  get diagnostics v_insumos = row_count;

  update _p007_insumos s
  set item_id = ii.id
  from public.inventory_items ii
  where s.item_id is null
    and ii.business_id = v_business
    and ii.sku = s.codigo;

  -- 8c) Link directo + tracking.
  update public.menu_items mi
  set inventory_item_id    = s.item_id,
      is_inventory_tracked = true
  from _p007_ids i
  join _p007_insumos s on s.codigo = i.codigo
  where mi.id = i.id
    and (mi.inventory_item_id is distinct from s.item_id
         or not coalesce(mi.is_inventory_tracked, false));

  -- 8d) Existencia inicial, UNA sola vez por insumo. trg_inventory_stock_sync
  --     suma inventory_stock y trg_inventory_movement_recost deja el costo del
  --     insumo en el costo del listado.
  insert into public.inventory_movements (
    business_id, warehouse_id, item_id, movement_type, quantity,
    cost_per_unit, reference_type, notes
  )
  select v_business, v_wh_id, s.item_id, 'purchase'::public.movement_type,
         p.qty, p.cost, 'initial_stock',
         'Existencia inicial del listado del sistema anterior (14/09/2026) — '
           || p.name
  from _p007 p
  join _p007_insumos s on s.codigo = p.codigo
  where p.qty > 0
    and not exists (
      select 1 from public.inventory_movements m
      where m.item_id = s.item_id and m.reference_type = 'initial_stock'
    );
  get diagnostics v_movs = row_count;

  -- 8e) Encender el motor: en 'none' la venta no descuenta nada.
  if v_mode = 'none' then
    update public.business_settings
    set inventory_mode = 'basic'
    where business_id = v_business;
  end if;

  -- =========================================================================
  -- 9) VERIFICACIÓN DENTRO DE LA TRANSACCIÓN — cualquier fallo revierte TODO.
  -- =========================================================================

  -- 9a) Cada código con exactamente un producto.
  select count(*) into v_n
  from _p007 p
  where (select count(*) from public.menu_items mi
         where mi.business_id = v_business and mi.sku = p.codigo) <> 1;
  if v_n > 0
     or (select count(*) from _p007_ids) <> v_total
     or (select count(distinct id) from _p007_ids) <> v_total then
    raise exception '% códigos sin producto o con más de uno. Revertido.', v_n;
  end if;

  -- 9b) Precio, ITBIS incluido, categoría y código de barras del listado.
  select count(*) into v_n
  from _p007_ids i
  join public.menu_items mi on mi.id = i.id
  join _p007 p on p.codigo = i.codigo
  left join public.categories c on c.id = mi.category_id
  where mi.price <> p.price
     or mi.tax_mode <> 'inclusive'
     or c.id is null
     or lower(btrim(c.name)) <> lower(p.categoria)
     or (p.barcode is not null and mi.barcode is distinct from p.barcode);
  if v_n > 0 then
    raise exception '% productos con precio, impuesto, categoría o código de barras incorrectos. Revertido.', v_n;
  end if;

  -- 9c) Los 6 que no son mercancía, apagados.
  select count(*) into v_n
  from _p007_ids i
  join public.menu_items mi on mi.id = i.id
  join _p007 p on p.codigo = i.codigo
  where not p.activo and mi.is_active;
  if v_n > 0 then
    raise exception '% renglones que deben quedar inactivos siguen activos. Revertido.', v_n;
  end if;

  -- 9d) Exactamente el ITBIS: sin él factura 0.00; con otro, cobra de más.
  select count(*) into v_n
  from _p007_ids i
  where not exists (select 1 from public.menu_item_taxes x
                    where x.item_id = i.id and x.tax_id = v_tax_id)
     or exists (select 1 from public.menu_item_taxes x
                where x.item_id = i.id and x.tax_id <> v_tax_id);
  if v_n > 0 then
    raise exception '% productos sin ITBIS o con otro impuesto. Revertido.', v_n;
  end if;

  -- 9e) Área: legacy y N:M de acuerdo.
  select count(*) into v_n
  from _p007_ids i
  join public.menu_items mi on mi.id = i.id
  where mi.print_area_code is distinct from v_area_code
     or (v_area_id is null and exists (
           select 1 from public.menu_item_print_areas x
           where x.menu_item_id = i.id))
     or (v_area_id is not null and (
           (select count(*) from public.menu_item_print_areas x
             where x.menu_item_id = i.id) <> 1
           or not exists (select 1 from public.menu_item_print_areas x
                          where x.menu_item_id = i.id
                            and x.print_area_id = v_area_id)));
  if v_n > 0 then
    raise exception '% productos con el área de comanda en desacuerdo. Revertido.', v_n;
  end if;

  -- 9f) Todos en el menú de la caja.
  select count(*) into v_n
  from _p007_ids i
  where not exists (select 1 from public.menu_item_links l
                    where l.menu_id = v_menu_id and l.item_id = i.id);
  if v_n > 0 then
    raise exception '% productos fuera del menú: no saldrían en la caja. Revertido.', v_n;
  end if;

  -- 9g) Inventariables enlazados a un insumo del negocio.
  select count(*) into v_n
  from _p007 p
  join _p007_ids i on i.codigo = p.codigo
  join public.menu_items mi on mi.id = i.id
  left join public.inventory_items ii
    on ii.id = mi.inventory_item_id and ii.business_id = v_business
  where p.inventariable
    and (not coalesce(mi.is_inventory_tracked, false) or ii.id is null);
  if v_n > 0 then
    raise exception '% productos inventariables sin insumo: se venderían sin descontar. Revertido.', v_n;
  end if;

  -- 9h) Ningún insumo compartido por dos productos del listado.
  select count(*) into v_n
  from (select item_id from _p007_insumos
        group by item_id having count(*) > 1) z;
  if v_n > 0 then
    raise exception '% insumos compartidos por varios productos: descontarían cruzado. Revertido.', v_n;
  end if;

  -- 9i) Existencia inicial registrada para cada uno que la trae.
  select count(*) into v_n
  from _p007 p
  join _p007_insumos s on s.codigo = p.codigo
  where p.qty > 0
    and not exists (select 1 from public.inventory_movements m
                    where m.item_id = s.item_id
                      and m.reference_type = 'initial_stock');
  if v_n > 0 then
    raise exception '% productos sin su existencia inicial. Revertido.', v_n;
  end if;

  select count(*) into v_n
  from _p007 p
  join _p007_insumos s on s.codigo = p.codigo
  where p.qty > 0
    and not exists (select 1 from public.inventory_movements m
                    where m.item_id = s.item_id
                      and m.reference_type = 'initial_stock'
                      and m.quantity = p.qty);
  if v_n > 0 then
    raise notice '% insumos ya tenían una existencia inicial DISTINTA a la del listado: no se tocó (ajústala con un conteo).', v_n;
  end if;

  -- 9j) El motor de inventario encendido.
  if (select inventory_mode from public.business_settings
      where business_id = v_business) not in ('basic', 'advanced') then
    raise exception 'inventory_mode no quedó en basic/advanced. Revertido.';
  end if;

  -- 9k) Ningún código de barras repetido en productos activos del negocio:
  --     la pistola traería el producto equivocado.
  select count(*), string_agg(bc, ', ')
    into v_n, v_list
  from (
    select mi.barcode as bc
    from public.menu_items mi
    where mi.business_id = v_business
      and mi.is_active
      and nullif(btrim(mi.barcode), '') is not null
    group by mi.barcode
    having count(*) > 1
  ) z;
  if v_n > 0 then
    raise exception 'Códigos de barras repetidos en productos activos (%). Revertido.', v_list;
  end if;

  raise notice 'OK — % productos (% nuevos, % actualizados) · % insumos nuevos · % existencias iniciales en "%" · área: % · Commit.',
    v_total, v_nuevos, v_actualizados, v_insumos, v_movs, v_wh_name,
    coalesce(v_area_code, 'ninguna (cocina apagada)');
end $$;

commit;

-- ============================================================================
-- REPORTE — todas las filas deben decir ✓
-- ============================================================================

with codigos as (
  select unnest(string_to_array(
    '8594003352331,8594003351815,8594003352614,8594003352522,8412598005862,8500001270089,8690582723200,8690582722203,87120103,8714800001793,8423453910535,8423453910566,8412598005831,8712000030582,8712000900045,8714800014212,8714800007580,8714800031127,851621000043,8411327001076,8411327003308,8411327008419,8411327001717,8411327001960,8001435310018,8423453909980,8594006931090,8594006931328,8712000051945,876529000476,876529000421,84692204045,8004747005535,796020140504,796020100508,804884,8414771852881,8000040002509,8410161711257,796020010029,796020010128,8000020000365,8000020000396,796020600022,796020600008,7640171032054,796020100515,8410414000466,8410557900203,8414771853208,8411705100230,8411705100223,8411705100216,811538010801,860012986828,860012986811,860012986835,8005713144258,888,7640171034058,8011822008220,8437003674976,8436006393006,7804330312108,854620,8003030008819,8003030008826,7804320303178,7804320985633,7804320301174,7804320510170,8420209032510,8420209039007,8420209032527,8008513064016,7804330004614,7804320046044,7804320688480,7804320384382,8012769232037,7804320520162,7804320523958,7804320574707,8425021000068,8425021000051,8425021000075,7804345003145,7804345001882,7804320628165,7804320559001,7804320642277,7804320706009,7804320483115,7804320556000,7804320269160,7804320626994,7804300010645,7804300010638,7804300120603,7804300123697,8414606856534,8437007129984,8410351000000,8003030993177,8011822009975,8411079501930,8411079381037,8410869450014,8410869451240,8410866430019,8410866430477,8001540002228,7804330121205,8414771620022,8412424325225,7804449104014,7804449104021,7804449103017,7804449103024,8414542100104,7804320485515,8437008952147,8000428026257,8420342001039,8420342001022,8420342002012,8420342203013,8420209040706,80516130545,7804350596366,7804350600148,7804350596335,7804350600391,7804350701364,7804350174700,7804350600285,7804350596342,7804350008661,7804350600384,7804350701661,7804350600353,7804350000054,7804350000061,7804350596359,7804350600070,7804350596328,7804350600155,7804350000528,784350600391,7804350600360,7804330983445,7804330983438,7804330321209,7804330311101,7804330351206,7804330111107,7804330341108,7804330221202,7804330211104,7804330001835,7804330212101,7804330211203,7804330361106,7804330322206,7804330001088,7804330006724,7804330006717,8004385032207,8410428330047,8411079391012,8413481014206,8410635004014,8410635001013,8011822007032,8011822009036,8008513003756,8008513008058,8008513008485,8003030991418,8437015144115,8437015144306,8410702010344,8410702010399,8424718113111,8427894026503,8427894026497,8427021000352,8413004050117,8437007129953,8437007129939,8004385030395,796020310501,8410388003531,7804320288826,7804320214085,818838009818,818838009825,8420209028520,8420209028506,8420209028537,8420209028513,7804320169699,7804320063010,839743001483,764009045577,764009024497,764009011671,764009047984,850035474082,850035474037,850035474068,850035474051,850035474464,850035474105,850035474006,849806002319,849806001756,849806001855,849806003859,849806004962,849806001220,849806002746,849806001206,849806005754,7898605253012,780380,830207000707,830207010706,830207000301,815934000107,789120,783150,790330050508,8053626292788,7702090048643,784000,831384000504,7702354251673,7702354251666,850003560410,850003560441,850003560458,9002490212148,9002490291709,9002490267544,9002490204006,9002490266288,9002490206710,9002490268657,84233299812184,78250004321,782740,782850,7702354253776,7702354253769,859710000011,859710000004,893504860702,893504860696,8809125063011,884394007391,884394007285,884394007377,8936020049793,8936020049786,790330008080,790330008028,790330004587,790330002323,884394000538,7703186031303,8710428019509,8410635024029,7707362397672,7709990350463,7707362390079,7709990350470,790330021461,790330021454,8687,790330002118,790330021584,87328431846,876063005951,876063005968,876063002035,876063002011,876063002042,876063002028,790330005096,790330050676,786273040041,786273040034,8710428020215,888849008100,888849014460,888849008117,790330050614,790330021256,790330021249,790330030029,790330021263,790330050669,790330021270,790330050058,79033050072,790330050645,790330005003,790330021188,790330021171,790330005300,790330050621,790330021164,790330050386,790330030012,790330050072,790330021973,790330021126,790330021003,790330021225,790330021089,790330021133,790330021119,790330021072,790330004655,790330004600,790330004617,790330005133,790330021805,790330051109,790330005171,790330021027,790330021898,790330021140,790330021157,790330050065,790330050607,790330050140,790330050133,790330050041,790330050034,790330021928,790330021935,790330021881,790330021515,790330021232,790330050447,790330050652,790330005324,790330022017,790330050638,790330021294,790330022024,790330014333,790330006741,790330006703,790330006789,777,796025000025,796025000483,8020141152002,8003430100656,8003430100311,8002270015991,8020141214007,8020141204008,765066747367,893919001301,893919001608,8004192102209,8002270136559,8002270536472,8002270000188,8020141101307,8007601001049,7862126331641,853240003023,853240003009,853240003153,853240003016,7750168001687,7622300375713,7622300051327,7622210101273,7622210101396,894185000852,894185000494,852109004034,852109004003,853240003238,853240003214,853240003221,811387010281,811387010274,811387010298,894185000487,850126007045,850126007090,765857349893,765857349909,856414002174,856414001023,7798151950468,856414001078,856414001085,856414001139,873617005245,873617001759,873617000165,8801043008525,850000725287,7750168001694,856414001160,856414001108,856414001191,856414001054,856414001184,856414001207,856414001092,856414001016,856414002167,893594002112,7622300124526,764090053710,850000725249,850000725263,850000725256,7862106721882,850000725270,7862126330989,7862126330972,771,8690481004714,8690481003267,8690481002437,7790040930407,7790040930209,77903518,7790040930506,7790040999404,80752981,7790040726505,8410368000970,8410368040082,8410368039611,8410014378330,8410014317070,765066783532,8410368033329,7750243004534,7622300268633,7622210259004,8080,787692834617,787692835416,787692835386,787692835430,787692835331,787692835355,8904006206058,8904006206072,8906001385028,810010660886,8906001386001,8906001386278,8906001385387,8902335028884,8901972057493,8901972073592,8904006230077,8901972068666,781718687720,8902335013163,8902335013156,781718687737,8901972071888,8902335006189,8902335005236,765351901221,888109010683,7896071021210,809552099283,809552088708,8095520099247,8410120500038,797936000470,7896003701180,8904006291009,8904006291016,8904006291047,8904006291030,8904006291023,8410368033848,8410368033312,7702189041197,80602316,7702011003881,787692834624,7702133009037,7750168002240,7622202217579,787692835324,7702025182329,7702025182305,8410368002936,8410368000390,8410368034678,80661641,8001585010103,80633051,781718687713,7702011048301,7702011003553,7702011014184,8904006205082,8904006206065,8904006291054,80633044,7891962005553,787692838349,7702993042311,7702993022283,776,764090052515,764090052478,764090052454,764090052119,7891000369371,8690997158611,869302920023,7891233,8690997111753,7899970401206,7891000248768,7891000249239,8746197756475,764090052157,764090052133,764090052430,764090052416,764090053703,764090052171,8413725004062,8412704007308,840004098302,7702133853265,7702133100130,7891200001637,7777,8410525116759,8410525143403,8410525211065,7896058593839,763061080892,7896451908575,7891151017404,7622210427045,7622210427076,7622202015212,872635001802,872635001246,8850197580951,7896286601900,840004097466,7801615692283,78925281,78914681,78930643,7896262304306,763061082001,816251010428,787545004914,7702402057615,871478617225,854929006557,7702133879494,7622201801229,7622202212062,7622210171115,7622201776664,7702133862793,7622210973436,7622210461674,7622210461704,7622210461728,7622210461742,7622202395130,7622202395536,7622210938282,7622202394799,763061080700,820,819,818,821,815,816,817,812,810,811,814,813,8031,8025,8029,8026,8028,8023,8024,8030,8021,8022,8020,8027,888849006038,888849000494,888849000630,888849005956,888849004621,888849000432,888849000234,888849000005,888849012244,888849005994,888849006014,888849006069,888849006397,888849008049,888849000418,888849000456,888849003495,888849010103,888849010646,888849010707,888849000012,888849000210,8888490000470,888849001224,8410667020174,8410667020419,8437001130474,8480013190219,8437001130450,8480013190127,8480013190226,866213,866203,8701471,8411916202150,8852021298445,8852021002233,8410159044329,8410667005706,8423329813311,7788,7702024004943,7891000372609,8850468611377,8410344151504,8410344700030,8410344111508,8434165488663,90000,84233299812189,900,843182100577,843182100607,88,790690070154,78019423,78019416,78018662,853195000467,850043075103,853195000498,762446440009,762446450008,762446420001,762446400003,78020856,78018464,78018068,78018501,78014626,78014633,810134310650,844111003839,762446820009,89012001182,762446730001,762446703005,762446706006,762446710003,7707200947311,7751201001602,7702303182898,7702303936590,7702303023221,7707200941951,7707200941661,7707200942835,7707200940282,7702303809511,7702303404068,7702303721387,7702303401944,7702303142427,7702303246743,7702303027878,7702303915199,7702303617000,7702303923477,8904169416899,857424000341,8906101702589,84233299812166,808829032079,808829032130,7702027041020,7702027494901,7702027044168,7702027402777,84233299812177,8010052120009,7702026016616,84115560,7702035372154,7702134372208,7702031787570,8901790682938,7702418004825,826942010088,826942010026,826942010033,826942010071,826942010019,826942654909,826942654893,826942654916,84121130068,84121130013,84121130044,84233299812161,84233299812162,84233299812159,84233299812157,84233299812160,84233299812156,89269000457,89269000198,8000,8877,80,842071002657,842071002381,842071002411,842071002428,842071002442,7705808449169,842071002725,842071003302,810822013313,810822013252,810822013306,810822014860,810822013276,810822013283,810822014853,810822013290,810822013269,810822014846,810822013245,769848100746,79238046180,84233299812175,84233299812165,84233299812194,79191514009,76333113939,859196130080,797496878892,797496863362,797496871541,797496861573,797496865632,797496860606,797496871343,797496861559,797496658128,797496875723,797496865489,853313006012,8081,7805040751126,797496862341,842071002527,842071002565,842071002534,842071002664,769848100722,769848100708,769848100715,79238011133,79238011164,79238011188,79238011508,79238011225,79238011478,79238011492,79238011157,84233299812153,8409730014714,801,77,84233299812171,801248667334,783094020115,800,850051002009,7878,8888,8606004528650,802141257264,818043000013,84233299812193,840034240313,8714786213760', ',')) as codigo
),
items as (
  select mi.*
  from public.menu_items mi
  join codigos c on c.codigo = mi.sku
  where mi.business_id = '3c5c3b8e-28e6-45f0-8dc7-85e3efe8d30c'::uuid
),
itbis as (
  select t.* from public.taxes t
  where t.business_id = '3c5c3b8e-28e6-45f0-8dc7-85e3efe8d30c'::uuid
    and t.name ilike '%itbis%' and t.rate = 18 and coalesce(t.is_active, true)
  limit 1
),
bs as (
  select * from public.business_settings
  where business_id = '3c5c3b8e-28e6-45f0-8dc7-85e3efe8d30c'::uuid
),
areas as (
  select distinct mipa.print_area_id as id
  from public.menu_item_print_areas mipa
  join items i on i.id = mipa.menu_item_id
),
iniciales as (
  select m.*
  from public.inventory_movements m
  join items i on i.inventory_item_id = m.item_id
  where m.reference_type = 'initial_stock'
),
r(orden, concepto, encontrado, esperado, ok) as (
  select 1, 'Productos del listado',
         (select count(*) from items)::text, '828',
         (select count(*) from items) = 828
  union all
  select 2, 'Activos / inactivos',
         (select count(*) filter (where is_active) || ' / ' ||
                 count(*) filter (where not is_active) from items),
         '822 / 6',
         (select count(*) filter (where not is_active) from items) = 6
  union all
  select 3, 'Con ITBIS incluido (inclusive)',
         (select count(*) from items where tax_mode = 'inclusive')::text, '828',
         (select count(*) from items where tax_mode = 'inclusive') = 828
  union all
  select 4, 'Vinculados SOLO al ITBIS 18%',
         (select count(*) from items i
           where exists (select 1 from public.menu_item_taxes x
                         join itbis t on t.id = x.tax_id where x.item_id = i.id)
             and not exists (select 1 from public.menu_item_taxes x
                             where x.item_id = i.id
                               and x.tax_id not in (select id from itbis)))::text,
         '828',
         (select count(*) from items i
           where exists (select 1 from public.menu_item_taxes x
                         join itbis t on t.id = x.tax_id where x.item_id = i.id)
             and not exists (select 1 from public.menu_item_taxes x
                             where x.item_id = i.id
                               and x.tax_id not in (select id from itbis))) = 828
  union all
  select 5, 'Enlazados al menú de la caja',
         (select count(*) from items i where exists (
            select 1 from public.menu_item_links l where l.item_id = i.id))::text,
         '828',
         (select count(*) from items i where exists (
            select 1 from public.menu_item_links l where l.item_id = i.id)) = 828
  union all
  select 6, 'Área de comanda: ' || coalesce((
            select string_agg(a.name || ' (' || a.code || ')', ', ')
            from public.print_areas a where a.id in (select id from areas)),
            'ninguna'),
         case when (select coalesce(kitchen_enabled, true) from bs)
              then 'cocina encendida'
              else 'cocina apagada' end,
         'cocina apagada y sin área, o una sola área',
         case when (select coalesce(kitchen_enabled, true) from bs)
              then (select count(*) from areas) = 1
                   and (select count(*) from items i where exists (
                          select 1 from public.menu_item_print_areas x
                          where x.menu_item_id = i.id)) = 828
              else (select count(*) from areas) = 0
                   and (select count(*) from items
                        where print_area_code is not null) = 0
         end
  union all
  select 7, 'Inventariables con su insumo',
         (select count(*) from items i
           where i.is_inventory_tracked and i.inventory_item_id is not null)::text,
         '822',
         (select count(*) from items i
           where i.is_inventory_tracked and i.inventory_item_id is not null) = 822
  union all
  select 8, 'Con existencia inicial',
         (select count(distinct item_id) from iniciales)::text, '181',
         (select count(distinct item_id) from iniciales) = 181
  union all
  select 9, 'Unidades de existencia inicial',
         coalesce((select sum(quantity) from iniciales), 0)::text, '2955',
         coalesce((select sum(quantity) from iniciales), 0) = 2955
  union all
  select 10, 'Valor de la existencia a costo (RD$)',
         to_char(coalesce((select sum(quantity * coalesce(cost_per_unit, 0))
                           from iniciales), 0), 'FM999,999,990.00'),
         '247,332.65',
         round(coalesce((select sum(quantity * coalesce(cost_per_unit, 0))
                         from iniciales), 0), 2) = 247332.65
  union all
  select 11, 'Modo de inventario',
         (select inventory_mode from bs), 'basic o advanced',
         (select inventory_mode from bs) in ('basic', 'advanced')
  union all
  select 12, 'Con código de barras',
         (select count(*) from items where nullif(btrim(barcode), '') is not null)::text,
         '771 o más',
         (select count(*) from items where nullif(btrim(barcode), '') is not null) >= 771
  union all
  select 13, 'Códigos de barras repetidos (activos, todo el negocio)',
         (select count(*) from (
            select barcode from public.menu_items
            where business_id = '3c5c3b8e-28e6-45f0-8dc7-85e3efe8d30c'::uuid
              and is_active and nullif(btrim(barcode), '') is not null
            group by barcode having count(*) > 1) z)::text,
         '0',
         (select count(*) from (
            select barcode from public.menu_items
            where business_id = '3c5c3b8e-28e6-45f0-8dc7-85e3efe8d30c'::uuid
              and is_active and nullif(btrim(barcode), '') is not null
            group by barcode having count(*) > 1) z) = 0
  union all
  select 14, 'ITBIS se cobra en venta rápida',
         coalesce((select case when apply_on_quick then 'sí' else 'NO' end from itbis), '—'),
         'sí',
         coalesce((select apply_on_quick from itbis), false)
  union all
  select 15, 'Impresoras en el área de comanda',
         case when (select count(*) from areas) = 0 then 'no aplica'
              else (select count(*) from public.print_area_printers p
                    where p.area_id in (select id from areas))::text end,
         'no aplica, o 1 o más',
         (select count(*) from areas) = 0
         or (select count(*) from public.print_area_printers p
             where p.area_id in (select id from areas)) > 0
)
select concepto, encontrado, esperado,
       case when ok then '✓' else '✗ REVISAR' end as estado
from r
order by orden;
