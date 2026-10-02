-- ============================================================================
-- ESTANCIA NUEVA SPORT · CAFETERÍA — CARGA DEL CATÁLOGO
-- Business 85924083-2e8e-4e64-8192-808ee24674ed
--
-- Fuente: "ARTICULOS DE INVENTARIO.csv" del sistema anterior, dividido el
-- 21/09/2026 (build_estancia_nueva.py). Precios: ProIsa_lista.csv (sin ITBIS ×1.18 al peso; 24 ya finales) (624 con precio).
--
-- ⚠ ARCHIVO GENERADO por build_import_cafeteria.py desde _tpl_import_cafeteria.sql.
--   No lo edites a mano: cambia el .py (o la plantilla) y regenera.
-- ============================================================================
--
-- QUÉ CARGA
--   636 productos en 15 categorías, todos en el menú de la caja,
--   con ITBIS 18% INCLUIDO en el precio. 414 con código de barras; el código
--   del sistema viejo va siempre en `sku`.
--   624 con precio → ACTIVOS. Los demás entran INACTIVOS y en RD$0: no salen
--   en la caja hasta que tengan precio (en un producto en $0 la caja cobraría gratis).
--   635 inventariables 1:1 (vendes 1, descuenta 1) con su insumo, todos con
--   stock en CERO y "Vender aunque esté agotado" (allow_negative_sale).
--   12 insumos de cocina (leche, queso, salsas…): solo insumos, no se venden.
--   Comanda: Comida y Pizzas a COCINA (58), todo lo demás a BAR (578).
--   La OFERTA 3x2 de Michelob entra inactiva y sin inventario: se configura en Ofertas.
--
-- CÓMO CORRERLO
--   Pega este archivo entero en el SQL Editor de Supabase y dale Run. La tabla
--   del final es el reporte: todas las filas deben decir ✓.
--
-- TODO O NADA
--   Una transacción. Primero comprueba todo (negocio, ITBIS, menú, bodega,
--   áreas, códigos repetidos) y antes del commit verifica producto por
--   producto. Si algo no cuadra, lanza excepción y REVIERTE ENTERO.
--
-- SE PUEDE RE-CORRER (así se cargan los precios cuando lleguen)
--   Empareja por CÓDIGO (sku o código de barras), no por nombre. El que ya
--   existe se actualiza en precio, costo, categoría, ITBIS, código de barras y
--   área; conserva el nombre. Un producto en $0 e inactivo que ahora trae
--   precio SE ACTIVA; uno con precio que apagaste en la app NO se reactiva.
--   El stock NO se toca al re-correr: solo arranca en cero la primera vez.
--   Activos en $0 (ACTIVAR_todos_cafeteria.sql, 01/10/2026) no bloquean:
--   salen como aviso ✗ en la fila 2 del reporte hasta que tengan precio.
-- ============================================================================

begin;

-- ---------------------------------------------------------------------------
-- 0) La lista, en tablas temporales que mueren con la transacción.
-- ---------------------------------------------------------------------------

create temp table _pen (
  codigo        text primary key,     -- código del sistema viejo → sku
  name          text not null,
  categoria     text not null,
  price         numeric(12,2),        -- null = todavía sin precio
  cost          numeric,              -- null si el sistema viejo no lo tenía
  barcode       text,                 -- null si el código no es GTIN
  is_bev        boolean not null,
  vendible      boolean not null,     -- false = la OFERTA: nunca se activa
  inventariable boolean not null,
  area          text not null check (area in ('bar', 'cocina')),
  posicion      int not null
) on commit drop;

-- filas 1–200
insert into _pen (codigo, name, categoria, price, cost, barcode, is_bev, vendible, inventariable, area, posicion) values
  ('4014086096518', '5,0 ORIGINAL CRAFT BEER', 'Cervezas', 200.00, 110.0000, '4014086096518', true, true, true, 'bar', 1),
  ('4014086096334', '5,0 ORIGINAL LAGER BEER', 'Cervezas', 200.00, 97.2400, '4014086096334', true, true, true, 'bar', 2),
  ('4014086096365', '5,0 ORIGINAL PILS BEER', 'Cervezas', 200.00, 110.0000, '4014086096365', true, true, true, 'bar', 3),
  ('4014086096303', '5,0 ORIGINAL WEISS BEER', 'Cervezas', 65.00, 45.8300, '4014086096303', true, true, true, 'bar', 4),
  ('1215', 'ALHAMBRA RESERVA 1925 BOTELLA', 'Cervezas', 250.00, 141.5500, null, true, true, true, 'bar', 5),
  ('8412598005862', 'CERVEZA 1906 BLACK COUPAGE', 'Cervezas', 165.00, 110.0000, '8412598005862', true, true, true, 'bar', 6),
  ('8412598004964', 'CERVEZA 1906 LA MIL NUEVE', 'Cervezas', 200.00, 115.0000, '8412598004964', true, true, true, 'bar', 7),
  ('8412598006074', 'CERVEZA 1906 LA PELIRROJA', 'Cervezas', 175.00, 129.8000, '8412598006074', true, true, true, 'bar', 8),
  ('8412598005879', 'CERVEZA 1906 RED VINTAGE', 'Cervezas', 175.00, 129.8000, '8412598005879', true, true, true, 'bar', 9),
  ('08787337', 'CERVEZA BLUE MOON BELGIAN WHITE', 'Cervezas', 250.00, 145.8300, '08787337', true, true, true, 'bar', 10),
  ('110000100619', 'CERVEZA ERDINGER', 'Cervezas', 350.00, 233.3300, null, true, true, true, 'bar', 11),
  ('4002103248248', 'CERVEZA ERDINGER WEISSBIER', 'Cervezas', 350.00, 196.5000, '4002103248248', true, true, true, 'bar', 12),
  ('08374189', 'CERVEZA GROLSCH', 'Cervezas', 350.00, 225.0000, '08374189', true, true, true, 'bar', 13),
  ('87120103', 'CERVEZA HEINEKEN LATA', 'Cervezas', null, 55.6300, '87120103', true, true, true, 'bar', 14),
  ('8712000900045', 'CERVEZA HEINEKEN LATA GRANDE', 'Cervezas', null, 107.0000, '8712000900045', true, true, true, 'bar', 15),
  ('072890006189', 'CERVEZA HEINEKEN LATA SIN ALCOHOL', 'Cervezas', null, 105.0000, '072890006189', true, true, true, 'bar', 16),
  ('752245123005', 'CERVEZA HELLES', 'Cervezas', 400.00, 255.0000, '752245123005', true, true, true, 'bar', 17),
  ('8410793181947', 'CERVEZA KELER', 'Cervezas', 90.00, 63.5600, '8410793181947', true, true, true, 'bar', 18),
  ('03456217', 'CERVEZA MILLER BOTELLA 12OZ', 'Cervezas', 250.00, 108.7700, '03456217', true, true, true, 'bar', 19),
  ('4066600303336', 'CERVEZA PAULANER DUNKEL 500 ML', 'Cervezas', 275.00, 225.0000, '4066600303336', true, true, true, 'bar', 20),
  ('4066600060741', 'CERVEZA PAULANER WEISSBIER RUBIA 500ML', 'Cervezas', 275.00, 220.0000, '4066600060741', true, true, true, 'bar', 21),
  ('1231', 'CERVEZA PERONI CERO 21/330 ML', 'Cervezas', 215.00, 146.7600, null, true, true, true, 'bar', 22),
  ('74601561', 'CERVEZA PRESIDENTE LIGHT GRANDE', 'Cervezas', 190.00, 112.0000, '74601561', true, true, true, 'bar', 23),
  ('110000100474', 'CERVEZA REPUBLICA 5.0 LATA GRANDE', 'Cervezas', 145.00, 81.2500, null, true, true, true, 'bar', 24),
  ('8423453915547', 'CERVEZA REPUBLICA LA TUYA (BOTELLA)', 'Cervezas', 120.00, 77.1600, '8423453915547', true, true, true, 'bar', 25),
  ('087975903550', 'CERVEZA SAPPORO LIGHT', 'Cervezas', 275.00, 180.0000, '087975903550', true, true, true, 'bar', 26),
  ('087975003502', 'CERVEZA SAPPORO NORMAL', 'Cervezas', 275.00, 180.0000, '087975003502', true, true, true, 'bar', 27),
  ('74601325', 'CERVEZA THE ONE', 'Cervezas', 130.00, 84.4500, '74601325', true, true, true, 'bar', 28),
  ('07199044', 'COORS LIGHT BOTELLA', 'Cervezas', 185.00, 107.0400, '07199044', true, true, true, 'bar', 29),
  ('08780538', 'COORS LIGHT LATA 10OZ', 'Cervezas', 85.00, 58.2600, '08780538', true, true, true, 'bar', 30),
  ('08780936', 'COORS ORIGINAL BANQUET BOTELLA 12OZ', 'Cervezas', 250.00, 120.8500, '08780936', true, true, true, 'bar', 31),
  ('7503044233180', 'CORONA CERO 355ML', 'Cervezas', 250.00, 80.0200, '7503044233180', true, true, true, 'bar', 32),
  ('110000100542', 'CORONA DE LATA', 'Cervezas', 110.00, 68.6100, null, true, true, true, 'bar', 33),
  ('7503034941200', 'CORONA EXTRA 330ML', 'Cervezas', 250.00, 115.8300, '7503034941200', true, true, true, 'bar', 34),
  ('7503034941217', 'CORONITA EXTRA', 'Cervezas', 110.00, 80.9700, '7503034941217', true, true, true, 'bar', 35),
  ('8410793153135', 'DAMM LEMON CERVEZA & LIMON', 'Cervezas', 125.00, 84.7500, '8410793153135', true, true, true, 'bar', 36),
  ('8410793156136', 'DAMM LEMON LATA', 'Cervezas', 145.00, 80.0000, '8410793156136', true, true, true, 'bar', 37),
  ('3155930006015', 'DESPERADO BOTELLA', 'Cervezas', 250.00, 133.0500, '3155930006015', true, true, true, 'bar', 38),
  ('4002103248323', 'ERDINGER PIKANTUS', 'Cervezas', 300.00, 197.7400, '4002103248323', true, true, true, 'bar', 39),
  ('8410793282934', 'ESTRELLA DAMM', 'Cervezas', 175.00, 111.2500, '8410793282934', true, true, true, 'bar', 40),
  ('8712000030582', 'HEINEKEN BOTELLA GRANDE', 'Cervezas', null, 150.0000, '8712000030582', true, true, true, 'bar', 41),
  ('072890004994', 'HEINEKEN BOTELLA PEQUEÑA 330 ML', 'Cervezas', 250.00, 129.5500, '072890004994', true, true, true, 'bar', 42),
  ('072890006196', 'HEINEKEN BOTELLA SIN ALCOHOL', 'Cervezas', 250.00, 124.9800, '072890006196', true, true, true, 'bar', 43),
  ('01833225', 'MICHELOB ULTRA 330 ML', 'Cervezas', 250.00, 101.2200, '01833225', true, true, true, 'bar', 44),
  ('034100005610', 'MILLER DE LATA', 'Cervezas', 180.00, 61.5000, '034100005610', true, true, true, 'bar', 45),
  ('75031589', 'MODELO NEGRA 330 ML', 'Cervezas', 250.00, 128.5000, '75031589', true, true, true, 'bar', 46),
  ('7463172802996', 'MODELO RUBIA ESPECIAL 330ML', 'Cervezas', 250.00, 145.0000, '7463172802996', true, true, true, 'bar', 47),
  ('1219', 'OFERTA CERVEZA MICHELOB ULTRA 3X2', 'Cervezas', 400.00, 101.2100, null, true, false, false, 'bar', 48),
  ('8008440222008', 'PERONI 330 ML', 'Cervezas', 300.00, 162.9900, '8008440222008', true, true, true, 'bar', 49),
  ('7463172803764', 'PRESIDENTE BLACK', 'Cervezas', 200.00, 86.6400, '7463172803764', true, true, true, 'bar', 50),
  ('7463172803665', 'PRESIDENTE DE LATA LIGHT', 'Cervezas', 250.00, 85.4200, '7463172803665', true, true, true, 'bar', 51),
  ('7463172803672', 'PRESIDENTE DE LATA REGULAR', 'Cervezas', 175.00, 85.4200, '7463172803672', true, true, true, 'bar', 52),
  ('74621774', 'PRESIDENTE LIGHT 12OZ', 'Cervezas', 250.00, 93.9800, '74621774', true, true, true, 'bar', 53),
  ('74621767', 'PRESIDENTE REGULAR 12 OZ', 'Cervezas', 250.00, 93.9800, '74621767', true, true, true, 'bar', 54),
  ('74601554', 'PRESIDENTE REGULAR GRANDE', 'Cervezas', 190.00, 112.0000, '74601554', true, true, true, 'bar', 55),
  ('7501064199141', 'STELLA ARTOIS 330 ML', 'Cervezas', 250.00, 128.4000, '7501064199141', true, true, true, 'bar', 56),
  ('8002230000302', 'BOTELLA APEROL', 'Licores y vinos', 1590.00, 1110.0000, '8002230000302', true, true, true, 'bar', 1),
  ('5000329002230', 'BOTELLA BEEFEATER LONDON', 'Licores y vinos', 1845.00, 1400.0000, '5000329002230', true, true, true, 'bar', 2),
  ('5000299618073', 'BOTELLA BEEFEATER PINK STRAWBERRY', 'Licores y vinos', 1845.00, 1300.0000, '5000299618073', true, true, true, 'bar', 3),
  ('7460736960086', 'BOTELLA LAGRANGE 700ML', 'Licores y vinos', null, 745.0000, '7460736960086', true, true, true, 'bar', 4),
  ('1049', 'BOTELLA LICOR FERNET BRANCA', 'Licores y vinos', 2950.00, 1285.0000, null, true, true, true, 'bar', 5),
  ('4750021000157', 'BOTELLA STOLI', 'Licores y vinos', 1815.00, 900.0000, '4750021000157', true, true, true, 'bar', 6),
  ('7460855234990', 'BRUGAL EXTRA VIEJO 700ML', 'Licores y vinos', null, null, '7460855234990', true, true, true, 'bar', 7),
  ('5000299225028', 'CHIVAS 18 BOTELLA', 'Licores y vinos', 7076.00, 4520.4400, '5000299225028', true, true, true, 'bar', 8),
  ('7460855233498', 'DOBLE RESERVA BOTELLA', 'Licores y vinos', 1660.00, 865.0000, '7460855233498', true, true, true, 'bar', 9),
  ('744607002301', 'EL JIMADOR', 'Licores y vinos', null, 1605.0000, '744607002301', true, true, true, 'bar', 10),
  ('8001968005047', 'ESPUMANTE CASA BURTI MILLESIMATO', 'Licores y vinos', 800.00, 475.0000, '8001968005047', true, true, true, 'bar', 11),
  ('3263280120470', 'ESPUMANTE JP CHENET FIZZY ROSE LATA 250', 'Licores y vinos', 385.00, 195.0000, '3263280120470', true, true, true, 'bar', 12),
  ('110000100585', 'EXTRA VIEJO BOTELLA', 'Licores y vinos', 1072.00, null, null, true, true, true, 'bar', 13),
  ('3147690060703', 'GIBSON''S LONDON DRY GIN', 'Licores y vinos', 1750.00, 946.9600, '3147690060703', true, true, true, 'bar', 14),
  ('3147699118344', 'GIBSON''S PINK PREMIUM GIN', 'Licores y vinos', 1850.00, 983.5600, '3147699118344', true, true, true, 'bar', 15),
  ('7503018819501', 'OJO DE TIGRE 750ML', 'Licores y vinos', null, 2350.0000, '7503018819501', true, true, true, 'bar', 16),
  ('8410702039628', 'PROVENTO JAUME SERRA CAVA BRUT', 'Licores y vinos', 1400.00, 670.0000, '8410702039628', true, true, true, 'bar', 17),
  ('110000100566', 'RON 1888 BOTELLA', 'Licores y vinos', 3115.00, null, null, true, true, true, 'bar', 18),
  ('7460736904721', 'RON MACORIX BLANCO 700ML', 'Licores y vinos', 1000.00, 510.0000, '7460736904721', true, true, true, 'bar', 19),
  ('1232', 'SIBONEY 1920 BOTELLA 700 ML', 'Licores y vinos', 1800.00, 1076.1600, null, true, true, true, 'bar', 20),
  ('3263285152896', 'TEQUILA AGAVITA', 'Licores y vinos', 1800.00, 1075.0000, '3263285152896', true, true, true, 'bar', 21),
  ('1050', 'TEQUILA DON JULIO REPOSADO', 'Licores y vinos', null, 4850.0000, null, true, true, true, 'bar', 22),
  ('7460855238066', 'TRIPLE RESERVA BOTELLA', 'Licores y vinos', 1595.00, null, '7460855238066', true, true, true, 'bar', 23),
  ('5000267107776', 'WHISKY JOHNNIE GOLD BOTELLA', 'Licores y vinos', 6486.00, null, '5000267107776', true, true, true, 'bar', 24),
  ('5000267190150', 'WHISKY JOHNNIE NEGRO BOTELLA', 'Licores y vinos', 3678.00, 2175.0000, '5000267190150', true, true, true, 'bar', 25),
  ('5011166081104', 'WHITLEY NEILL GIN BLOOD ORANGE', 'Licores y vinos', 2500.00, 1521.8500, '5011166081104', true, true, true, 'bar', 26),
  ('5011166068020', 'WHITLEY NEILL GIN BLUE DISTILLER''S', 'Licores y vinos', 2500.00, 1521.8500, '5011166068020', true, true, true, 'bar', 27),
  ('5011166081128', 'WHITLEY NEILL GIN RHUBARB', 'Licores y vinos', 2500.00, 1521.8400, '5011166081128', true, true, true, 'bar', 28),
  ('110000100496', 'BEBIDA APEROL', 'Tragos y cócteles', 400.00, null, null, true, true, true, 'bar', 1),
  ('110000100454', 'COCTEL BUZZBALL CHILI MANGO 200ML', 'Tragos y cócteles', 250.00, 175.0000, null, true, true, true, 'bar', 2),
  ('110000100455', 'COCTEL BUZZBALLZ CHOC TEASE 200ML', 'Tragos y cócteles', 250.00, 175.0000, null, true, true, true, 'bar', 3),
  ('110000100456', 'COCTEL BUZZBALLZ ESPRESSO MARTINI 200ML', 'Tragos y cócteles', 250.00, 175.0000, null, true, true, true, 'bar', 4),
  ('110000100457', 'COCTEL BUZZBALLZ PIÑA COLADA 200ML', 'Tragos y cócteles', 250.00, 175.0000, null, true, true, true, 'bar', 5),
  ('110000100458', 'COCTEL BUZZBALLZ STRAWBERRY RITA 200ML', 'Tragos y cócteles', 250.00, 175.0000, null, true, true, true, 'bar', 6),
  ('110000100459', 'COCTEL BUZZBALLZ TEQUILA RITA 20ML', 'Tragos y cócteles', 250.00, 175.0000, null, true, true, true, 'bar', 7),
  ('110000100555', 'DAIQUIRI', 'Tragos y cócteles', 220.00, null, null, true, true, true, 'bar', 8),
  ('110000100662', 'FROZEN BEBIDA', 'Tragos y cócteles', 180.00, null, null, true, true, true, 'bar', 9),
  ('110000100554', 'FROZEN CHINOLA', 'Tragos y cócteles', 225.00, null, null, true, true, true, 'bar', 10),
  ('110000100552', 'FROZEN FRESA', 'Tragos y cócteles', 295.00, null, null, true, true, true, 'bar', 11),
  ('110000100553', 'FROZEN LIMONADA', 'Tragos y cócteles', 290.00, null, null, true, true, true, 'bar', 12),
  ('110000100560', 'PALOMA', 'Tragos y cócteles', 395.00, null, null, true, true, true, 'bar', 13),
  ('110000100556', 'SANGRIA', 'Tragos y cócteles', 395.00, null, null, true, true, true, 'bar', 14),
  ('082000727477', 'SMIRNOFF ICE GREEN APPLE', 'Tragos y cócteles', 250.00, 125.0000, '082000727477', true, true, true, 'bar', 15),
  ('082000723844', 'SMIRNOFF ICE ORIGINAL 355 ML', 'Tragos y cócteles', 250.00, 125.0000, '082000723844', true, true, true, 'bar', 16),
  ('110000100568', 'TRAGO CHIVAS 18', 'Tragos y cócteles', 575.00, null, null, true, true, true, 'bar', 17),
  ('110000100685', 'TRAGO DE GIN TANQUERAY', 'Tragos y cócteles', 550.00, null, null, true, true, true, 'bar', 18),
  ('110000100582', 'TRAGO DOBLE RESERVA', 'Tragos y cócteles', 325.00, null, null, true, true, true, 'bar', 19),
  ('110000100584', 'TRAGO EXTRA VIEJO', 'Tragos y cócteles', 175.00, null, null, true, true, true, 'bar', 20),
  ('110000100691', 'TRAGO FERNET', 'Tragos y cócteles', 450.00, null, null, true, true, true, 'bar', 21),
  ('110000100653', 'TRAGO GIN TONIC BEEFEATER', 'Tragos y cócteles', 450.00, null, null, true, true, true, 'bar', 22),
  ('110000100693', 'TRAGO GIN TONIC BEEFEATER PINK', 'Tragos y cócteles', 450.00, null, null, true, true, true, 'bar', 23),
  ('110000100655', 'TRAGO MARGARITA', 'Tragos y cócteles', 425.00, null, null, true, true, true, 'bar', 24),
  ('110000100656', 'TRAGO MOJITO', 'Tragos y cócteles', 425.00, null, null, true, true, true, 'bar', 25),
  ('110000100654', 'TRAGO PALOMA', 'Tragos y cócteles', 450.00, null, null, true, true, true, 'bar', 26),
  ('110000100565', 'TRAGO RON 1888', 'Tragos y cócteles', 325.00, null, null, true, true, true, 'bar', 27),
  ('110000100498', 'TRAGO VODKA STOLI', 'Tragos y cócteles', 500.00, null, null, true, true, true, 'bar', 28),
  ('110000100563', 'TRAGO WHISKY JOHNNIE GOLD', 'Tragos y cócteles', 450.00, null, null, true, true, true, 'bar', 29),
  ('110000100561', 'TRAGO WHISKY JOHNNIE NEGRO', 'Tragos y cócteles', 450.00, null, null, true, true, true, 'bar', 30),
  ('785249462429', 'TRIPPIN ANIMAL LIMONADA ROSADA', 'Tragos y cócteles', 550.00, 454.3000, '785249462429', true, true, true, 'bar', 31),
  ('679065252237', 'TRIPPING ANIMAL INFINITE BLOOM', 'Tragos y cócteles', 500.00, 345.0000, '679065252237', true, true, true, 'bar', 32),
  ('635985500018', 'WHITE CLAW BLACK CHERRY LATA', 'Tragos y cócteles', 200.00, 150.0000, '635985500018', true, true, true, 'bar', 33),
  ('7463172803320', '7 UP REFRESCO', 'Refrescos', 30.00, 14.1700, '7463172803320', true, true, true, 'bar', 1),
  ('8002270676819', 'AGUA SAN PELLEGRINO ARANCIATA', 'Refrescos', 150.00, 89.3900, '8002270676819', true, true, true, 'bar', 2),
  ('8002270696831', 'AGUA SAN PELLEGRINO ARANCIATA ROSSA', 'Refrescos', 150.00, 89.3900, '8002270696831', true, true, true, 'bar', 3),
  ('8002270726828', 'AGUA SAN PELLEGRINO MELOGRANO', 'Refrescos', 150.00, 89.3900, '8002270726828', true, true, true, 'bar', 4),
  ('7463172803733', 'AGUA TONICA ENRIQUILLO', 'Refrescos', 50.00, 32.4500, '7463172803733', true, true, true, 'bar', 5),
  ('7465383000321', 'CANADA DRY AGUA TONICA', 'Refrescos', 40.00, 25.3300, '7465383000321', true, true, true, 'bar', 6),
  ('07811102', 'CANADA DRY GINGER ALE BLACKBERRY 24/12', 'Refrescos', 100.00, 45.8300, '07811102', true, true, true, 'bar', 7),
  ('07844508', 'CANADA DRY GINGER ALE FRUIT SPLASH', 'Refrescos', 100.00, 45.8300, '07844508', true, true, true, 'bar', 8),
  ('07811403', 'CANADA DRY GINGER ALE LATA 24 /12', 'Refrescos', 100.00, 45.8300, '07811403', true, true, true, 'bar', 9),
  ('7465383000307', 'CANADA DRY SODA 400ML', 'Refrescos', 65.00, 25.3300, '7465383000307', true, true, true, 'bar', 10),
  ('07811801', 'CANADA GINGER ALE ZERO', 'Refrescos', 100.00, 45.8300, '07811801', true, true, true, 'bar', 11),
  ('049000006209', 'COCA COLA 591ML', 'Refrescos', 55.00, 41.0000, '049000006209', true, true, true, 'bar', 12),
  ('049000071993', 'COCA COLA SIN AZUCAR', 'Refrescos', 30.00, 25.0000, '049000071993', true, true, true, 'bar', 13),
  ('049000057638', 'COCA-COLA 400ML', 'Refrescos', 35.00, 25.0000, '049000057638', true, true, true, 'bar', 14),
  ('049000057676', 'COUNTRY CLUB FRAMBUESA 400ML', 'Refrescos', 30.00, 20.3300, '049000057676', true, true, true, 'bar', 15),
  ('049000550733', 'COUNTRY CLUB MANZANA', 'Refrescos', 30.00, 17.0800, '049000550733', true, true, true, 'bar', 16),
  ('049000057669', 'COUNTRY CLUB MERENGUE 400ML', 'Refrescos', 30.00, 20.3300, '049000057669', true, true, true, 'bar', 17),
  ('049000550412', 'COUNTRY CLUB NARANJA 400 ML', 'Refrescos', 30.00, 20.3300, '049000550412', true, true, true, 'bar', 18),
  ('049000547870', 'COUNTRY CLUB PIÑA', 'Refrescos', 30.00, 17.0800, '049000547870', true, true, true, 'bar', 19),
  ('049000057683', 'COUNTRY CLUB UVA 400 ML', 'Refrescos', 30.00, 20.3300, '049000057683', true, true, true, 'bar', 20),
  ('090478410036', 'JARRITOS FRUIT PUNCH', 'Refrescos', 145.00, null, '090478410036', true, true, true, 'bar', 21),
  ('090478410012', 'JARRITOS MANDARINA', 'Refrescos', 145.00, null, '090478410012', true, true, true, 'bar', 22),
  ('090478410029', 'JARRITOS TAMARINDO', 'Refrescos', 145.00, null, '090478410029', true, true, true, 'bar', 23),
  ('073360377518', 'LA CROIX LEMON', 'Refrescos', 65.00, 32.9100, '073360377518', true, true, true, 'bar', 24),
  ('073360237515', 'LA CROIX LIME', 'Refrescos', 65.00, 32.9100, '073360237515', true, true, true, 'bar', 25),
  ('073360617515', 'LA CROIX ORANGE', 'Refrescos', 65.00, 32.9100, '073360617515', true, true, true, 'bar', 26),
  ('012000130311', 'MOUNTAIN DEW BAJA BLAST', 'Refrescos', 150.00, 125.0000, '012000130311', true, true, true, 'bar', 27),
  ('01208500', 'MOUNTAIN DEW VERDE REGULAR', 'Refrescos', 125.00, 58.3300, '01208500', true, true, true, 'bar', 28),
  ('012000028632', 'MOUNTAIN DEW VOLTAJE', 'Refrescos', 150.00, 125.0000, '012000028632', true, true, true, 'bar', 29),
  ('7463172803467', 'RED ROCK FRAMBUESA', 'Refrescos', 30.00, 14.1700, '7463172803467', true, true, true, 'bar', 30),
  ('7463172803528', 'RED ROCK MERENGUE', 'Refrescos', 30.00, 14.1700, '7463172803528', true, true, true, 'bar', 31),
  ('7463172803580', 'RED ROCK UVA', 'Refrescos', 30.00, 14.1700, '7463172803580', true, true, true, 'bar', 32),
  ('7441003530232', 'REFRESCO LATA SPRITE', 'Refrescos', 55.00, 41.6700, '7441003530232', true, true, true, 'bar', 33),
  ('7461136665007', 'REFRESCO TOP TOP FRAMBUESA 450ML', 'Refrescos', 30.00, 15.4200, '7461136665007', true, true, true, 'bar', 34),
  ('7461136665014', 'REFRESCO TOP TOP MANZANA 450ML', 'Refrescos', 30.00, 15.4200, '7461136665014', true, true, true, 'bar', 35),
  ('7461136665038', 'REFRESCO TOP TOP PIÑA 450ML', 'Refrescos', 30.00, 15.4200, '7461136665038', true, true, true, 'bar', 36),
  ('8002270916588', 'SAN PELLEGRINO TONICA', 'Refrescos', 200.00, 140.0000, '8002270916588', true, true, true, 'bar', 37),
  ('016571910303', 'SPARKLING ICE BLACK RASPBERRY', 'Refrescos', 175.00, 85.0600, '016571910303', true, true, true, 'bar', 38),
  ('016571952105', 'SPARKLING ICE BLACKBERRY', 'Refrescos', 90.00, 68.0000, '016571952105', true, true, true, 'bar', 39),
  ('016571950842', 'SPARKLING ICE CHERRY LIMEADE', 'Refrescos', 175.00, 68.0000, '016571950842', true, true, true, 'bar', 40),
  ('016571940355', 'SPARKLING ICE CLASSIC LEMONADE', 'Refrescos', 175.00, 68.0000, '016571940355', true, true, true, 'bar', 41),
  ('016571940331', 'SPARKLING ICE COCONUT PINEAPPLE', 'Refrescos', 175.00, 68.0000, '016571940331', true, true, true, 'bar', 42),
  ('016571954369', 'SPARKLING ICE FRUIT PUNCH', 'Refrescos', 175.00, 85.0600, '016571954369', true, true, true, 'bar', 43),
  ('016571952679', 'SPARKLING ICE GRAPE RASPBERRY', 'Refrescos', 175.00, 68.0000, '016571952679', true, true, true, 'bar', 44),
  ('016571910327', 'SPARKLING ICE KIWI STRAWBERRY', 'Refrescos', 175.00, 85.0600, '016571910327', true, true, true, 'bar', 45),
  ('016571911256', 'SPARKLING ICE LEMON LIME', 'Refrescos', 175.00, 85.0600, '016571911256', true, true, true, 'bar', 46),
  ('016571910310', 'SPARKLING ICE ORANGE MANGO', 'Refrescos', 175.00, 68.0000, '016571910310', true, true, true, 'bar', 47),
  ('016571940348', 'SPARKLING ICE PEACH NECTARINE', 'Refrescos', 90.00, 68.0000, '016571940348', true, true, true, 'bar', 48),
  ('016571910372', 'SPARKLING ICE PINK GRAPEFRUIT', 'Refrescos', 175.00, 68.0000, '016571910372', true, true, true, 'bar', 49),
  ('016571950293', 'SPARKLING ICE STRAWBERRY LEMONADE', 'Refrescos', 175.00, 68.0000, '016571950293', true, true, true, 'bar', 50),
  ('016571950859', 'SPARKLING ICE STRAWBERRY WATERMELON', 'Refrescos', 175.00, 68.0000, '016571950859', true, true, true, 'bar', 51),
  ('016571953867', 'SPARKLING LATA BLACK RASPBERRY', 'Refrescos', 175.00, 92.4300, '016571953867', true, true, true, 'bar', 52),
  ('016571953843', 'SPARKLING LATA BLUE RASPBERRY', 'Refrescos', 175.00, 92.4300, '016571953843', true, true, true, 'bar', 53),
  ('016571955144', 'SPARKLING LATA CHERRY VANILLA', 'Refrescos', 175.00, 92.4300, '016571955144', true, true, true, 'bar', 54),
  ('016571953829', 'SPARKLING LATA CITRUS TWIST', 'Refrescos', 175.00, 92.4300, '016571953829', true, true, true, 'bar', 55),
  ('016571952839', 'SPARKLING LATA STRAWBERRY CITRUS', 'Refrescos', 175.00, 92.4300, '016571952839', true, true, true, 'bar', 56),
  ('016571952822', 'SPARKLING LATA TROPICAL PUNCH', 'Refrescos', 175.00, 92.4300, '016571952822', true, true, true, 'bar', 57),
  ('016571957438', 'SPARKLING LATA WATERMELON LEMONADE', 'Refrescos', 175.00, 92.4300, '016571957438', true, true, true, 'bar', 58),
  ('049000057690', 'SPRITE 400 ML', 'Refrescos', 30.00, 20.3300, '049000057690', true, true, true, 'bar', 59),
  ('1239', 'SPRITE SIN AZUCAR 400 ML', 'Refrescos', 30.00, 20.3300, null, true, true, true, 'bar', 60),
  ('049000551808', 'AGUA DASANI PEQUEÑA', 'Aguas', 25.00, 12.3000, '049000551808', true, true, true, 'bar', 1),
  ('061314000032', 'AGUA EVIAN', 'Aguas', 135.00, 81.0000, '061314000032', true, true, true, 'bar', 2),
  ('079298000078', 'AGUA EVIAN GRANDE', 'Aguas', 200.00, 118.5900, '079298000078', true, true, true, 'bar', 3),
  ('632565000029', 'AGUA FIJI 1 LITRO', 'Aguas', 250.00, 172.0800, '632565000029', true, true, true, 'bar', 4),
  ('632565000012', 'AGUA FIJI 500ML', 'Aguas', 150.00, 88.9600, '632565000012', true, true, true, 'bar', 5),
  ('8002270966576', 'AGUA PANNA PEQUEÑA 500ML', 'Aguas', 150.00, 80.8300, '8002270966576', true, true, true, 'bar', 6),
  ('8000815355250', 'AGUA PANNA TUSCANY 1 LT', 'Aguas', 210.00, 139.1700, '8000815355250', true, true, true, 'bar', 7),
  ('701891100014', 'AGUA PLANETA AZUL 16 ONZ', 'Aguas', 25.00, 8.0000, '701891100014', true, true, true, 'bar', 8),
  ('7461136665069', 'AGUA PUREZA SANA', 'Aguas', 25.00, 7.0000, '7461136665069', true, true, true, 'bar', 9),
  ('893919001301', 'ICELANDIC AGUA MINERAL 1 LT', 'Aguas', 250.00, 162.0000, '893919001301', true, true, true, 'bar', 10),
  ('1063', 'ICELANDIC AGUA MINERAL 500ML', 'Aguas', 125.00, 90.8300, null, true, true, true, 'bar', 11),
  ('893919001509', 'ICELANDIC AGUA MINERAL 750ML CHUPI', 'Aguas', 275.00, 183.3300, '893919001509', true, true, true, 'bar', 12),
  ('1061', 'PERRIER', 'Aguas', 110.00, 79.1700, null, true, true, true, 'bar', 13),
  ('1060', 'SAN PELLEGRINO 250ML', 'Aguas', 120.00, 73.2700, null, true, true, true, 'bar', 14),
  ('893504860702', 'AGUA DE COCO CON PULPA', 'Jugos y lácteos', 145.00, 81.2500, '893504860702', true, true, true, 'bar', 1),
  ('735051000630', 'COMPOTA HEINZ BABY FRUITAS', 'Jugos y lácteos', 50.00, 27.9700, '735051000630', true, true, true, 'bar', 2),
  ('735051000562', 'COMPOTA HEINZ BABY MANZANA', 'Jugos y lácteos', 50.00, 27.9700, '735051000562', true, true, true, 'bar', 3),
  ('735051000579', 'COMPOTA HEINZ BABY PERA', 'Jugos y lácteos', 50.00, 27.9700, '735051000579', true, true, true, 'bar', 4),
  ('612197211260', 'ENTEREX TOTAL FRESA 8Z', 'Jugos y lácteos', 265.00, 152.3100, '612197211260', true, true, true, 'bar', 5),
  ('612197211161', 'ENTEREX TOTAL VAINILLA 8Z', 'Jugos y lácteos', 265.00, 152.3100, '612197211161', true, true, true, 'bar', 6),
  ('7466442630046', 'FRUIT PARADISE CEREZA', 'Jugos y lácteos', 90.00, 58.0000, '7466442630046', true, true, true, 'bar', 7),
  ('7466442630039', 'FRUIT PARADISE CHINOLA', 'Jugos y lácteos', 100.00, 65.0000, '7466442630039', true, true, true, 'bar', 8),
  ('7466442630060', 'FRUIT PARADISE FRESA', 'Jugos y lácteos', 100.00, 65.0000, '7466442630060', true, true, true, 'bar', 9);

-- filas 201–400
insert into _pen (codigo, name, categoria, price, cost, barcode, is_bev, vendible, inventariable, area, posicion) values
  ('7466442630145', 'FRUIT PARADISE FRUIT PUNCH', 'Jugos y lácteos', 90.00, 58.0000, '7466442630145', true, true, true, 'bar', 10),
  ('7466442630053', 'FRUIT PARADISE LIMON', 'Jugos y lácteos', 90.00, 58.0000, '7466442630053', true, true, true, 'bar', 11),
  ('7466442630107', 'FRUIT PARADISE PIÑA', 'Jugos y lácteos', 90.00, 58.0000, '7466442630107', true, true, true, 'bar', 12),
  ('110000100274', 'JUGO 100% SIN AZUCAR PEQUEÑO', 'Jugos y lácteos', 50.00, 38.6800, null, true, true, true, 'bar', 13),
  ('1110', 'JUGO CLAMATO 5.5 OZ', 'Jugos y lácteos', 70.00, 47.5000, null, true, true, true, 'bar', 14),
  ('096619204212', 'JUGO KIRKLAND ACAI BLUEBERRY', 'Jugos y lácteos', 100.00, 48.0000, '096619204212', true, true, true, 'bar', 15),
  ('096619204205', 'JUGO KIRKLAND DRAGON FRUIT', 'Jugos y lácteos', 100.00, 48.3300, '096619204205', true, true, true, 'bar', 16),
  ('096619192328', 'JUGO KIRKLAND LEMONADE', 'Jugos y lácteos', 100.00, 48.3300, '096619192328', true, true, true, 'bar', 17),
  ('096619204014', 'JUGO KIRKLAND TROPICAL MANGO', 'Jugos y lácteos', 100.00, 48.3300, '096619204014', true, true, true, 'bar', 18),
  ('110000100559', 'JUGO NATURAL DE CHINOLA', 'Jugos y lácteos', 120.00, null, null, true, true, true, 'bar', 19),
  ('110000100558', 'JUGO NATURAL DE LIMON', 'Jugos y lácteos', 120.00, null, null, true, true, true, 'bar', 20),
  ('024474007211', 'JUGO PETIT DURAZNO', 'Jugos y lácteos', 50.00, null, '024474007211', true, true, true, 'bar', 21),
  ('024474007020', 'JUGO PETIT MANZANA', 'Jugos y lácteos', 50.00, null, '024474007020', true, true, true, 'bar', 22),
  ('024474007068', 'JUGO PETIT PERA', 'Jugos y lácteos', 50.00, null, '024474007068', true, true, true, 'bar', 23),
  ('024474007174', 'JUGO PETIT PIÑA', 'Jugos y lácteos', 50.00, null, '024474007174', true, true, true, 'bar', 24),
  ('110000100303', 'JUGO RICA DE PERA', 'Jugos y lácteos', 60.00, 33.1000, null, true, true, true, 'bar', 25),
  ('790330021270', 'JUGO RICA FRUIT PUNCH', 'Jugos y lácteos', 75.00, 33.1000, '790330021270', true, true, true, 'bar', 26),
  ('110000100712', 'JUGO RICA LIMON', 'Jugos y lácteos', 60.00, 31.1100, null, true, true, true, 'bar', 27),
  ('790330021171', 'JUGO RICA MANZANA', 'Jugos y lácteos', 60.00, 33.1000, '790330021171', true, true, true, 'bar', 28),
  ('790330021089', 'JUGO RICA NARANJA 100% CON AZUCAR', 'Jugos y lácteos', 75.00, 52.1000, '790330021089', true, true, true, 'bar', 29),
  ('790330021140', 'JUGO RICA NARANJA 100% SIN AZUCAR', 'Jugos y lácteos', 90.00, 61.0900, '790330021140', true, true, true, 'bar', 30),
  ('790330021249', 'JUGO RICA PERA', 'Jugos y lácteos', 60.00, 33.1000, '790330021249', true, true, true, 'bar', 31),
  ('790330002323', 'LECHE CHOCORICA', 'Jugos y lácteos', 35.00, 25.3500, '790330002323', true, true, true, 'bar', 32),
  ('031200008091', 'OCEAN SPRAY DE ARANDANOS', 'Jugos y lácteos', 110.00, 67.4500, '031200008091', true, true, true, 'bar', 33),
  ('7462275402812', 'V8 SPLASH', 'Jugos y lácteos', 105.00, 87.0000, '7462275402812', true, true, true, 'bar', 34),
  ('041800490004', 'WELCH''S FRUIT PUNCH', 'Jugos y lácteos', 65.00, 39.8300, '041800490004', true, true, true, 'bar', 35),
  ('041800326006', 'WELCH''S GRAPE', 'Jugos y lácteos', 65.00, 39.8300, '041800326006', true, true, true, 'bar', 36),
  ('041800317004', 'WELCH''S ORANGE', 'Jugos y lácteos', 65.00, 39.8300, '041800317004', true, true, true, 'bar', 37),
  ('842595135534', 'C4 ENERGY BITTEN CITRUS', 'Deportivas y energizantes', 240.00, 156.2500, '842595135534', true, true, true, 'bar', 1),
  ('842595121766', 'C4 ENERGY COSMIC RAINBOW', 'Deportivas y energizantes', 240.00, 156.2500, '842595121766', true, true, true, 'bar', 2),
  ('842595106596', 'C4 ENERGY FROZEN BOMBSICLE', 'Deportivas y energizantes', 240.00, 156.2500, '842595106596', true, true, true, 'bar', 3),
  ('842595136050', 'C4 ENERGY GUMMY SPLASH', 'Deportivas y energizantes', 240.00, 156.2500, '842595136050', true, true, true, 'bar', 4),
  ('842595109368', 'C4 ENERGY ORANGE', 'Deportivas y energizantes', 240.00, 156.2500, '842595109368', true, true, true, 'bar', 5),
  ('9002490204006', 'ENERGIZANTE RED BULL 250 ML PEQUEÑO', 'Deportivas y energizantes', 130.00, 84.1300, '9002490204006', true, true, true, 'bar', 6),
  ('9002490212148', 'ENERGIZANTE RED BULL 355ML MED', 'Deportivas y energizantes', 200.00, 105.0000, '9002490212148', true, true, true, 'bar', 7),
  ('9002490267544', 'ENERGIZANTE RED BULL 473ML GRANDE', 'Deportivas y energizantes', 260.00, 172.5000, '9002490267544', true, true, true, 'bar', 8),
  ('7460548000130', 'GATORADE AZUL/ BLUE GRANDE 600ML', 'Deportivas y energizantes', 75.00, 41.2400, '7460548000130', true, true, true, 'bar', 9),
  ('7460548000147', 'GATORADE DE MELON GRANDE FIERCE 600ML', 'Deportivas y energizantes', 75.00, 43.3100, '7460548000147', true, true, true, 'bar', 10),
  ('7460548002660', 'GATORADE FRESA SANDIA 600 ML', 'Deportivas y energizantes', 75.00, 41.2500, '7460548002660', true, true, true, 'bar', 11),
  ('7460548000178', 'GATORADE LEMON LIME', 'Deportivas y energizantes', 75.00, 42.4400, '7460548000178', true, true, true, 'bar', 12),
  ('7460548000161', 'GATORADE MORADO UVA GRANDE 600ML', 'Deportivas y energizantes', 75.00, 42.4400, '7460548000161', true, true, true, 'bar', 13),
  ('7460548000185', 'GATORADE NARANJA ORANGE GRANDE 600ML', 'Deportivas y energizantes', 75.00, 41.2500, '7460548000185', true, true, true, 'bar', 14),
  ('7460548000017', 'GATORADE PEQUEÑO AZUL/ BLUE COOL 350ML', 'Deportivas y energizantes', 50.00, 26.1800, '7460548000017', true, true, true, 'bar', 15),
  ('7460548000048', 'GATORADE PEQUEÑO NARANJA 350 ML', 'Deportivas y energizantes', 50.00, 25.0000, '7460548000048', true, true, true, 'bar', 16),
  ('7460548000024', 'GATORADE PEQUEÑO ROJO/ FRUIT PUNCH 350ML', 'Deportivas y energizantes', 50.00, 27.5600, '7460548000024', true, true, true, 'bar', 17),
  ('7460548000031', 'GATORADE PEQUEÑO UVA 350 ML', 'Deportivas y energizantes', 50.00, 27.5600, '7460548000031', true, true, true, 'bar', 18),
  ('7460548000154', 'GATORADE ROJO GRANDE/FRUIT PUNCH 600ML', 'Deportivas y energizantes', 75.00, 42.4400, '7460548000154', true, true, true, 'bar', 19),
  ('7460548002127', 'GATORADE ZERO AZUL BERRY BLUE 500ML', 'Deportivas y energizantes', 70.00, 34.0900, '7460548002127', true, true, true, 'bar', 20),
  ('7460548002134', 'GATORADE ZERO ROJO 500 ML', 'Deportivas y energizantes', 70.00, 34.0900, '7460548002134', true, true, true, 'bar', 21),
  ('7460548002141', 'GATORLIT MORA AZUL 12/591 ML', 'Deportivas y energizantes', 150.00, 53.5700, '7460548002141', true, true, true, 'bar', 22),
  ('7460548002158', 'GATORLIT RECOVER COCO 12/591ML', 'Deportivas y energizantes', 150.00, 53.5700, '7460548002158', true, true, true, 'bar', 23),
  ('7460548002189', 'GATORLIT RECOVER FRESA KIWI', 'Deportivas y energizantes', 150.00, 53.5700, '7460548002189', true, true, true, 'bar', 24),
  ('7460548002172', 'GATORLIT RECOVER NARANJA', 'Deportivas y energizantes', 150.00, 53.5700, '7460548002172', true, true, true, 'bar', 25),
  ('7460548002165', 'GATORLIT RECOVER UVA 12/591ML', 'Deportivas y energizantes', 150.00, 53.5800, '7460548002165', true, true, true, 'bar', 26),
  ('052000049008', 'GATORLYTE CHERRY LIME', 'Deportivas y energizantes', 150.00, 77.5100, '052000049008', true, true, true, 'bar', 27),
  ('052000050820', 'GATORLYTE MIXED BERRY', 'Deportivas y energizantes', 150.00, 77.5100, '052000050820', true, true, true, 'bar', 28),
  ('052000047905', 'GATORLYTE NARANJA', 'Deportivas y energizantes', 150.00, 77.5100, '052000047905', true, true, true, 'bar', 29),
  ('052000050622', 'GATORLYTE SANDIA', 'Deportivas y energizantes', 150.00, 74.1700, '052000050622', true, true, true, 'bar', 30),
  ('052000047912', 'GATORLYTE STRAWBERRY KIWI', 'Deportivas y energizantes', 150.00, 77.5100, '052000047912', true, true, true, 'bar', 31),
  ('070847029106', 'MONSTER ENERGY', 'Deportivas y energizantes', 125.00, 76.6900, '070847029106', true, true, true, 'bar', 32),
  ('650240070495', 'SUEROX COCO', 'Deportivas y energizantes', 265.00, 165.8300, '650240070495', true, true, true, 'bar', 33),
  ('650240063213', 'SUEROX FRESA-KIWI', 'Deportivas y energizantes', 265.00, 150.4500, '650240063213', true, true, true, 'bar', 34),
  ('650240069192', 'SUEROX FRUTOS ROJOS TROPICALES', 'Deportivas y energizantes', 265.00, 150.4500, '650240069192', true, true, true, 'bar', 35),
  ('650240069208', 'SUEROX LIMA LIMON', 'Deportivas y energizantes', 265.00, 150.4500, '650240069208', true, true, true, 'bar', 36),
  ('650240063220', 'SUEROX MANZANA', 'Deportivas y energizantes', 265.00, 150.4500, '650240063220', true, true, true, 'bar', 37),
  ('650240063244', 'SUEROX MORA AZUL-HIERBABUENA', 'Deportivas y energizantes', 265.00, 141.2400, '650240063244', true, true, true, 'bar', 38),
  ('650240061325', 'SUEROX UVA', 'Deportivas y energizantes', 265.00, 141.2400, '650240061325', true, true, true, 'bar', 39),
  ('110000100313', 'VITARAIN BLUEBERRY', 'Deportivas y energizantes', 50.00, 37.7800, null, true, true, true, 'bar', 40),
  ('110000100312', 'VITARAIN DRAGON FRUIT', 'Deportivas y energizantes', 50.00, 37.7800, null, true, true, true, 'bar', 41),
  ('110000100314', 'VITARAIN LEMONADE', 'Deportivas y energizantes', 50.00, 37.7800, null, true, true, true, 'bar', 42),
  ('110000100315', 'VITARAIN TROP. MANGO', 'Deportivas y energizantes', 50.00, 37.7800, null, true, true, true, 'bar', 43),
  ('1058', 'CHOCOLATE FRIO SNICKERS', 'Café', 349.00, 204.1700, null, true, true, true, 'bar', 1),
  ('1057', 'CHOCOLATE FRIO TWIX', 'Café', 349.00, 204.1700, null, true, true, true, 'bar', 2),
  ('01264904', 'FRAPPUCCINO MOCHA', 'Café', 250.00, 163.3300, '01264904', true, true, true, 'bar', 3),
  ('1059', 'FRAPPUCCINO VAINILLA', 'Café', 279.00, 163.3400, null, true, true, true, 'bar', 4),
  ('110000100696', 'NESCAFE AGUA CALIENTE', 'Café', 60.00, 25.0000, null, true, true, true, 'bar', 5),
  ('110000100703', 'NESCAFE AMERICANO', 'Café', 75.00, 35.0000, null, true, true, true, 'bar', 6),
  ('110000100320', 'NESCAFE CAFE CON LECHE', 'Café', 110.00, 42.4500, null, true, true, true, 'bar', 7),
  ('110000100702', 'NESCAFE CAFE LARGO', 'Café', 50.00, 18.5400, null, true, true, true, 'bar', 8),
  ('110000100323', 'NESCAFE CAPUCHINO', 'Café', 125.00, 52.7000, null, true, true, true, 'bar', 9),
  ('110000100324', 'NESCAFE CAPUCHINO DE VAINILLA', 'Café', 125.00, 52.7000, null, true, true, true, 'bar', 10),
  ('110000100700', 'NESCAFE CAPUCHINO DE VAINILLA FRIO', 'Café', 185.00, 80.0000, null, true, true, true, 'bar', 11),
  ('110000100699', 'NESCAFE CAPUCHINO FRIO', 'Café', 180.00, 80.0000, null, true, true, true, 'bar', 12),
  ('110000100698', 'NESCAFE CHOCO-VAINILLA', 'Café', 125.00, 59.5500, null, true, true, true, 'bar', 13),
  ('110000100697', 'NESCAFE CHOCOLATE', 'Café', 110.00, 52.7800, null, true, true, true, 'bar', 14),
  ('110000100322', 'NESCAFE CORTADITO', 'Café', 90.00, 25.2500, null, true, true, true, 'bar', 15),
  ('110000100704', 'NESCAFE DOBLE EXPRESO', 'Café', 90.00, 30.0000, null, true, true, true, 'bar', 16),
  ('110000100326', 'NESCAFE ESTILO DOMINICANO', 'Café', 70.00, 35.7300, null, true, true, true, 'bar', 17),
  ('110000100327', 'NESCAFE EXPRESO', 'Café', 65.00, 30.0000, null, true, true, true, 'bar', 18),
  ('110000100325', 'NESCAFE MOKACCINO', 'Café', 125.00, 55.6400, null, true, true, true, 'bar', 19),
  ('110000100701', 'NESCAFE MOKACCINO FRIO', 'Café', 190.00, 85.0000, null, true, true, true, 'bar', 20),
  ('1181', 'INGREDIENTES ADICIONALES PIZZA', 'Pizzas', 100.00, null, null, false, true, true, 'cocina', 1),
  ('1180', 'PIZZA DE BACON', 'Pizzas', 450.00, 320.0000, null, false, true, true, 'cocina', 2),
  ('1179', 'PIZZA DE JAMON Y QUESO', 'Pizzas', 400.00, 320.0000, null, false, true, true, 'cocina', 3),
  ('1183', 'PIZZA DE MAIZ', 'Pizzas', 350.00, 210.0000, null, false, true, true, 'cocina', 4),
  ('1046', 'PIZZA DE PEPERONI', 'Pizzas', 350.00, 280.0000, null, false, true, true, 'cocina', 5),
  ('1045', 'PIZZA DE QUESO', 'Pizzas', 350.00, 237.2900, null, false, true, true, 'cocina', 6),
  ('1047', 'PIZZA DE QUESO DE CABRA CON MIEL', 'Pizzas', 400.00, 320.0000, null, false, true, true, 'cocina', 7),
  ('1178', 'PIZZA NAPOLITANA (TOMATE Y ALBAHACA)', 'Pizzas', 400.00, 320.0000, null, false, true, true, 'cocina', 8),
  ('1048', 'PIZZA ULTRA SALAMI PICANTE', 'Pizzas', 400.00, 320.0000, null, false, true, true, 'cocina', 9),
  ('1177', 'SLIDE DE PIZZA', 'Pizzas', 70.00, 50.0000, null, false, true, true, 'cocina', 10),
  ('1055', 'ALITAS BBQ', 'Comida', 470.00, null, null, false, true, true, 'cocina', 1),
  ('1070', 'ARROZ FRITO', 'Comida', 545.00, null, null, false, true, true, 'cocina', 2),
  ('110000100570', 'CASABE', 'Comida', 125.00, null, null, false, true, true, 'cocina', 3),
  ('110000100687', 'CROISSANT JAMON Y QUESO', 'Comida', 345.00, 270.0000, null, false, true, true, 'cocina', 4),
  ('110000100532', 'CROQUETAS DE POLLO', 'Comida', 50.00, 20.0000, null, false, true, true, 'cocina', 5),
  ('1217', 'EMPANADA CATIBIA POLLO PAQUETE DE 3', 'Comida', 200.00, 90.0000, null, false, true, true, 'cocina', 6),
  ('1218', 'EMPANADA CATIBIA QUESO PAQUETE DE 3', 'Comida', 200.00, 90.0000, null, false, true, true, 'cocina', 7),
  ('110000100280', 'EMPANADA DE PIZZA', 'Comida', 100.00, 59.0000, null, false, true, true, 'cocina', 8),
  ('110000100281', 'EMPANADA DE POLLO CREMA', 'Comida', 100.00, 59.0000, null, false, true, true, 'cocina', 9),
  ('1120', 'EMPANADA DE POLLO MAIZ', 'Comida', 100.00, 59.0000, null, false, true, true, 'cocina', 10),
  ('1119', 'EMPANADA DE POLLO PUERRO', 'Comida', 100.00, 59.0000, null, false, true, true, 'cocina', 11),
  ('110000100282', 'EMPANADA DE QUESO', 'Comida', 100.00, 59.0000, null, false, true, true, 'cocina', 12),
  ('110000100283', 'EMPANADA DE RES', 'Comida', 100.00, 59.0000, null, false, true, true, 'cocina', 13),
  ('110000100461', 'EMPANADAS DE YUKA PEQUEÑAS', 'Comida', 100.00, 60.0000, null, false, true, true, 'cocina', 14),
  ('110000100464', 'EMPANADITAS CATIVIA', 'Comida', 50.00, 30.0000, null, false, true, true, 'cocina', 15),
  ('110000100331', 'HAMBURGUESA', 'Comida', 450.00, null, null, false, true, true, 'cocina', 16),
  ('110000100663', 'HAMBURGUESA DEL EVENTO', 'Comida', 400.00, 106.2000, null, false, true, true, 'cocina', 17),
  ('1216', 'HAMBURGUESA SMASH', 'Comida', 500.00, null, null, false, true, true, 'cocina', 18),
  ('110000100615', 'HOT DOG SALCHICHA ITALIANA', 'Comida', 175.00, null, null, false, true, true, 'cocina', 19),
  ('110000100332', 'HOT DOG SALCHICHA TRADICIONAL', 'Comida', 150.00, null, null, false, true, true, 'cocina', 20),
  ('021000010875', 'MAC & CHEESE MACARRONES', 'Comida', 125.00, 82.9200, '021000010875', false, true, true, 'cocina', 21),
  ('110000100317', 'NACHOS MARIA', 'Comida', 200.00, 74.7500, null, false, true, true, 'cocina', 22),
  ('110000100334', 'PAPAS FRITAS', 'Comida', 150.00, null, null, false, true, true, 'cocina', 23),
  ('110000100569', 'PASTA DE POLLO', 'Comida', 250.00, null, null, false, true, true, 'cocina', 24),
  ('1182', 'PASTA TRES QUESO', 'Comida', 550.00, 270.0000, null, false, true, true, 'cocina', 25),
  ('110000100551', 'PECHUGA A LA PLANCHA', 'Comida', 550.00, null, null, false, true, true, 'cocina', 26),
  ('1064', 'PLATO DE MANGU DE GUINEITO', 'Comida', 275.00, null, null, false, true, true, 'cocina', 27),
  ('110000100277', 'PORCION CARNE SALADA', 'Comida', 450.00, 114.4100, null, false, true, true, 'cocina', 28),
  ('1132', 'PORCION DE ALAS', 'Comida', null, 200.0000, null, false, true, true, 'cocina', 29),
  ('110000100339', 'PORCION PECHURINA', 'Comida', 350.00, 70.0000, null, false, true, true, 'cocina', 30),
  ('110000100308', 'QUIPE DE CABRA Y CEBOLLA CARAMELIZADA', 'Comida', 110.00, 61.3600, null, false, true, true, 'cocina', 31),
  ('110000100309', 'QUIPE DE POLLO', 'Comida', 100.00, 53.1000, null, false, true, true, 'cocina', 32),
  ('110000100310', 'QUIPE DE RES', 'Comida', 100.00, 56.6400, null, false, true, true, 'cocina', 33),
  ('110000100689', 'SANDWICH DE JAMON Y QUESO', 'Comida', 235.00, null, null, false, true, true, 'cocina', 34),
  ('110000100688', 'SANDWICH ITALIANO', 'Comida', 385.00, null, null, false, true, true, 'cocina', 35),
  ('110000100657', 'SERVICIO DE CHICHARRON', 'Comida', 600.00, 170.0000, null, false, true, true, 'cocina', 36),
  ('110000100658', 'SERVICIO DE LONGANIZA', 'Comida', 450.00, 145.0000, null, false, true, true, 'cocina', 37),
  ('110000100692', 'SERVICIO DE MOFONGO', 'Comida', 650.00, null, null, false, true, true, 'cocina', 38),
  ('110000100499', 'SERVICIO DE PAPAS', 'Comida', 150.00, null, null, false, true, true, 'cocina', 39),
  ('110000100500', 'SERVICIO DE YUKITAS', 'Comida', 170.00, null, null, false, true, true, 'cocina', 40),
  ('1034', 'SERVICIO PAPAS FRITAS SOLA', 'Comida', 125.00, null, null, false, true, true, 'cocina', 41),
  ('1186', 'SOPA ISIM POLLO', 'Comida', 75.00, 33.1600, null, false, true, true, 'cocina', 42),
  ('110000100686', 'TOSTADA DE AGUACATE', 'Comida', 280.00, null, null, false, true, true, 'cocina', 43),
  ('110000100328', 'TOSTADA DE JAMON, QUESO Y SALAMI GENOA', 'Comida', 150.00, null, null, false, true, true, 'cocina', 44),
  ('110000100330', 'TOSTADA DE QUESO', 'Comida', 180.00, null, null, false, true, true, 'cocina', 45),
  ('110000100329', 'TOSTADA JAMON Y QUESO', 'Comida', 120.00, null, null, false, true, true, 'cocina', 46),
  ('1242', 'WRAP DE POLLO PREMIUM BURRITO', 'Comida', 375.00, 200.0000, null, false, true, true, 'cocina', 47),
  ('110000100335', 'YUQUITAS FRITAS', 'Comida', 150.00, null, null, false, true, true, 'cocina', 48),
  ('110000100348', 'CARIBAS AJO', 'Snacks', 115.00, 85.4000, null, false, true, true, 'bar', 1),
  ('7460496801476', 'CARIBAS NATU MADURO PU CS', 'Snacks', 40.00, 28.9200, '7460496801476', false, true, true, 'bar', 2),
  ('7467113580882', 'CARLES MADURITOS', 'Snacks', 65.00, 39.8300, '7467113580882', false, true, true, 'bar', 3),
  ('7451011040425', 'CARLES PLATANITOS CHIP', 'Snacks', 55.00, 39.8300, '7451011040425', false, true, true, 'bar', 4),
  ('7467113580974', 'CARLES PLATANITOS LIMON', 'Snacks', 65.00, 39.8300, '7467113580974', false, true, true, 'bar', 5),
  ('7451011041149', 'CARLES PLATANITOS PICANTITOS', 'Snacks', 65.00, 39.8300, '7451011041149', false, true, true, 'bar', 6),
  ('7451011040289', 'CARLES TAJADITAS', 'Snacks', 65.00, 39.8300, '7451011040289', false, true, true, 'bar', 7),
  ('7451011041132', 'CARLES YUKITAS PICANTITAS', 'Snacks', 65.00, 39.8300, '7451011041132', false, true, true, 'bar', 8),
  ('7451011040043', 'CARLES YUQUITA', 'Snacks', 65.00, 39.8300, '7451011040043', false, true, true, 'bar', 9),
  ('7460496804286', 'CHEETOS CRUNCHY CS', 'Snacks', 25.00, 12.4000, '7460496804286', false, true, true, 'bar', 10),
  ('1081', 'CHEETOS CRUNCHY GRANDE', 'Snacks', 145.00, 103.1300, null, false, true, true, 'bar', 11),
  ('7460496805214', 'CHEETOS GARRITAS SABOR CHEDDAR', 'Snacks', 25.00, 12.4000, '7460496805214', false, true, true, 'bar', 12),
  ('7460496804293', 'CHEETOS HAMBURGUESA CS', 'Snacks', 25.00, 12.4000, '7460496804293', false, true, true, 'bar', 13),
  ('7460496803685', 'CHEETOS QUESO BLANCO', 'Snacks', 25.00, 12.4000, '7460496803685', false, true, true, 'bar', 14),
  ('721282411123', 'CHEETOS SWAP', 'Snacks', 20.00, 12.4000, '721282411123', false, true, true, 'bar', 15),
  ('7465619163011', 'CHEMILO', 'Snacks', 35.00, 17.7000, '7465619163011', false, true, true, 'bar', 16),
  ('7460496805573', 'CHICHARRON FLAMIN FRITO LAY', 'Snacks', 35.00, 20.0000, '7460496805573', false, true, true, 'bar', 17),
  ('7464113824121', 'CHICHARRON LIMON', 'Snacks', 45.00, 28.9200, '7464113824121', false, true, true, 'bar', 18),
  ('1082', 'CHICHARRON LIMON GRANDE', 'Snacks', 145.00, 103.1300, null, false, true, true, 'bar', 19),
  ('1203', 'CORNETAS', 'Snacks', 50.00, 32.1100, null, false, true, true, 'bar', 20),
  ('7460496805672', 'DETODITO MOFONGO', 'Snacks', 50.00, 33.0500, '7460496805672', false, true, true, 'bar', 21),
  ('7460496805498', 'DORITOS DINAMITA ROC CS', 'Snacks', 25.00, 16.5200, '7460496805498', false, true, true, 'bar', 22),
  ('7460496805016', 'DORITOS FLAMIN HOT DR CS', 'Snacks', 40.00, 21.0200, '7460496805016', false, true, true, 'bar', 23),
  ('1118', 'DORITOS MOFONGO DR', 'Snacks', 41.00, 33.0500, null, false, true, true, 'bar', 24),
  ('7460496803999', 'DORITOS NACHO CS', 'Snacks', 35.00, 24.8000, '7460496803999', false, true, true, 'bar', 25),
  ('1083', 'DORITOS NACHOS GRANDES', 'Snacks', 145.00, 103.1300, null, false, true, true, 'bar', 26),
  ('7460496804002', 'DORITOS PM CS', 'Snacks', 35.00, 24.8000, '7460496804002', false, true, true, 'bar', 27),
  ('721282411109', 'DORITOS SWAP', 'Snacks', 40.00, 24.7900, '721282411109', false, true, true, 'bar', 28),
  ('7460496806068', 'HOJUELITA TOCINETA', 'Snacks', 20.00, 12.7400, '7460496806068', false, true, true, 'bar', 29),
  ('7460496803623', 'HOJUELITAS BBQ CS', 'Snacks', 25.00, 12.7400, '7460496803623', false, true, true, 'bar', 30),
  ('1087', 'HOJUELITAS BBQ GRANDE', 'Snacks', 145.00, 103.1300, null, false, true, true, 'bar', 31),
  ('7460496803616', 'HOJUELITAS DE QUESO CS', 'Snacks', 25.00, 12.7400, '7460496803616', false, true, true, 'bar', 32),
  ('7460496806105', 'HOJUELITAS FH CS', 'Snacks', 25.00, 12.7400, '7460496806105', false, true, true, 'bar', 33),
  ('1088', 'HOJUELITAS QUESO GRANDE', 'Snacks', 145.00, 103.1300, null, false, true, true, 'bar', 34),
  ('7460496806143', 'LAYS ASADO DR CS', 'Snacks', 45.00, 28.9200, '7460496806143', false, true, true, 'bar', 35),
  ('7460496804811', 'LAYS BBQ', 'Snacks', 41.00, 28.9200, '7460496804811', false, true, true, 'bar', 36),
  ('7460496803944', 'LAYS CLASICAS', 'Snacks', 50.00, 24.5100, '7460496803944', false, true, true, 'bar', 37),
  ('1089', 'LAYS CLASICAS GRANDES', 'Snacks', 145.00, 103.1300, null, false, true, true, 'bar', 38),
  ('7460496803968', 'LAYS LIMON', 'Snacks', 45.00, 26.0300, '7460496803968', false, true, true, 'bar', 39),
  ('1090', 'LAYS LIMON GRANDE', 'Snacks', 145.00, 103.1300, null, false, true, true, 'bar', 40),
  ('7460496803951', 'LAYS QUESO BLANCO', 'Snacks', 45.00, 26.0300, '7460496803951', false, true, true, 'bar', 41),
  ('1117', 'LAYS SAL DR32GX', 'Snacks', 45.00, 28.9200, null, false, true, true, 'bar', 42),
  ('721282411055', 'LAYS SWAP DR', 'Snacks', 45.00, 28.9200, '721282411055', false, true, true, 'bar', 43),
  ('7460496806204', 'LAYS TACO DR CS', 'Snacks', 45.00, 28.9200, '7460496806204', false, true, true, 'bar', 44),
  ('1230', 'NATUCHIPS AJO', 'Snacks', 45.00, 28.9200, null, false, true, true, 'bar', 45),
  ('1092', 'NATUCHIPS GRANDES', 'Snacks', 155.00, 103.1300, null, false, true, true, 'bar', 46),
  ('1206', 'NATUCHIPS LIMON DR', 'Snacks', 45.00, 28.9200, null, false, true, true, 'bar', 47),
  ('7460496800523', 'NATUCHIPS PL ORIGINAL RD', 'Snacks', 45.00, 28.9200, '7460496800523', false, true, true, 'bar', 48),
  ('1204', 'NATUCHIPS YUCA CS', 'Snacks', 45.00, 28.9200, null, false, true, true, 'bar', 49),
  ('1205', 'NATUCHIPS YUCA QUESO CS', 'Snacks', 45.00, 28.9200, null, false, true, true, 'bar', 50),
  ('607766702652', 'PALOMITAS', 'Snacks', 75.00, 35.0000, '607766702652', false, true, true, 'bar', 51);

-- filas 401–600
insert into _pen (codigo, name, categoria, price, cost, barcode, is_bev, vendible, inventariable, area, posicion) values
  ('029000017931', 'PLANTERS MANI', 'Snacks', 60.00, 37.0800, '029000017931', false, true, true, 'bar', 52),
  ('7460496800530', 'PLATANITOS SAL CS', 'Snacks', 25.00, 16.5300, '7460496800530', false, true, true, 'bar', 53),
  ('038000183737', 'PRINGLES BBQ', 'Snacks', 65.00, 41.3700, '038000183737', false, true, true, 'bar', 54),
  ('038000183713', 'PRINGLES BBQ LATA GRANDE', 'Snacks', 300.00, 150.0000, '038000183713', false, true, true, 'bar', 55),
  ('1113', 'PRINGLES CANTINITA PEQ', 'Snacks', 50.00, 23.7900, null, false, true, true, 'bar', 56),
  ('038000184949', 'PRINGLES CEBOLLA LATA GRANDE', 'Snacks', 300.00, 150.0000, '038000184949', false, true, true, 'bar', 57),
  ('038000846748', 'PRINGLES CREMA Y CEBOLLA', 'Snacks', 75.00, 53.7500, '038000846748', false, true, true, 'bar', 58),
  ('038000184956', 'PRINGLES DE QUESO LATA GRANDE', 'Snacks', 300.00, 150.0000, '038000184956', false, true, true, 'bar', 59),
  ('038000846731', 'PRINGLES ORIGINAL', 'Snacks', 75.00, 53.7500, '038000846731', false, true, true, 'bar', 60),
  ('038000184932', 'PRINGLES ORIGINAL LATA GRANDE', 'Snacks', 300.00, 160.0000, '038000184932', false, true, true, 'bar', 61),
  ('038000138638', 'PRINGLES PIZZA LATA GRANDE', 'Snacks', 300.00, 150.0000, '038000138638', false, true, true, 'bar', 62),
  ('038000846755', 'PRINGLES QUESO', 'Snacks', 75.00, 53.7500, '038000846755', false, true, true, 'bar', 63),
  ('20788124', 'RABITOS INOA', 'Snacks', 50.00, null, '20788124', false, true, true, 'bar', 64),
  ('1170', 'RANC BUTFFE RANC PEQ', 'Snacks', 40.00, 16.6800, null, false, true, true, 'bar', 65),
  ('750894614301', 'RANCH BUFFE RANCH', 'Snacks', 40.00, 16.6700, '750894614301', false, true, true, 'bar', 66),
  ('1149', 'RANCH EXCITANT GRANDE', 'Snacks', 130.00, 71.6300, null, false, true, true, 'bar', 67),
  ('1653265', 'RANCH NACH EXCITANT PEQ.', 'Snacks', 40.00, 16.6700, null, false, true, true, 'bar', 68),
  ('750894603404', 'RANCH NACH PIZZA PEQ.', 'Snacks', 40.00, 16.6700, '750894603404', false, true, true, 'bar', 69),
  ('750894614288', 'RANCH NACHO QUESO PEQ.', 'Snacks', 40.00, 16.6700, '750894614288', false, true, true, 'bar', 70),
  ('750894606399', 'RANCHITA DE QUESO GRANDE', 'Snacks', 130.00, 71.6200, '750894606399', false, true, true, 'bar', 71),
  ('110000100343', 'RANCHITAS NATURALES', 'Snacks', 115.00, 65.6600, null, false, true, true, 'bar', 72),
  ('721282402770', 'RUFFLES CARNE ASADA CS', 'Snacks', 40.00, 24.8000, '721282402770', false, true, true, 'bar', 73),
  ('721282402787', 'RUFFLES CHEDDAR CS', 'Snacks', 40.00, 24.8000, '721282402787', false, true, true, 'bar', 74),
  ('7460496805627', 'RUFFLES XTRA CRUNCH DR CS', 'Snacks', 40.00, 21.0200, '7460496805627', false, true, true, 'bar', 75),
  ('757528048075', 'TAKIS FUEGO MEDIANO', 'Snacks', 150.00, 40.7600, '757528048075', false, true, true, 'bar', 76),
  ('757528048532', 'TAKIS FUEGO PEQUEÑO', 'Snacks', 60.00, 40.7600, '757528048532', false, true, true, 'bar', 77),
  ('154545845', 'TAQUERITOS CHILE TOREADO', 'Snacks', 55.00, 16.6700, null, false, true, true, 'bar', 78),
  ('750894609505', 'TAQUERITOS CHILE TOREADO GRANDE', 'Snacks', 130.00, 88.0000, '750894609505', false, true, true, 'bar', 79),
  ('750894612550', 'TAQUERITOS CHILE TOREADO PEQ', 'Snacks', 40.00, 20.8300, '750894612550', false, true, true, 'bar', 80),
  ('750894613212', 'TAQUERITOS DRAGON FUEGO GRANDE', 'Snacks', 130.00, 88.1300, '750894613212', false, true, true, 'bar', 81),
  ('750894613236', 'TAQUERITOS DRAGON HIELO PEQ', 'Snacks', 40.00, 16.6700, '750894613236', false, true, true, 'bar', 82),
  ('1185', 'TAQUERITOS QUESO FUSION 34G', 'Snacks', 32.00, 16.6600, null, false, true, true, 'bar', 83),
  ('1094', 'TOSTONES MADURITO RIPE', 'Snacks', 200.00, 135.5900, null, false, true, true, 'bar', 84),
  ('014113911856', 'WONDERFUL PISTACHIOS', 'Snacks', 65.00, 52.2900, '014113911856', false, true, true, 'bar', 85),
  ('750894671007', 'YUMMI NUTS MANI CON LIMON GRANDE', 'Snacks', 60.00, 39.1600, '750894671007', false, true, true, 'bar', 86),
  ('750894671151', 'YUMMI NUTS MANI JAPONES', 'Snacks', 30.00, 12.5000, '750894671151', false, true, true, 'bar', 87),
  ('750894671458', 'YUMMI NUTS MANI JAPONES CHILE', 'Snacks', 30.00, 12.5000, '750894671458', false, true, true, 'bar', 88),
  ('110000100434', 'YUMMI NUTS MANI LIMON', 'Snacks', 30.00, 8.3300, null, false, true, true, 'bar', 89),
  ('110000100432', 'YUMMI NUTS MANI SAL', 'Snacks', 30.00, 8.3300, null, false, true, true, 'bar', 90),
  ('750894671229', 'YUMMI NUTS MIX DE ALMENDRAS, MARAÑON, M', 'Snacks', 25.00, 12.5000, '750894671229', false, true, true, 'bar', 91),
  ('1172', 'YUMMI NUTS MIX SEMILLAS FRUTAS', 'Snacks', 30.00, 12.5000, null, false, true, true, 'bar', 92),
  ('750894671243', 'YUMMI OMEGA MIX MANI GRANDE', 'Snacks', 270.00, 191.6700, '750894671243', false, true, true, 'bar', 93),
  ('750894612215', 'YUMMI POPS NACHO JALAPEÑO PEQ', 'Snacks', 40.00, 20.8400, '750894612215', false, true, true, 'bar', 94),
  ('750894614059', 'YUMMI POPS PALOMITAS DRA PEQ', 'Snacks', 40.00, 16.6700, '750894614059', false, true, true, 'bar', 95),
  ('750894611645', 'YUMMIPOP QUESO PEQ.', 'Snacks', 40.00, 16.6700, '750894611645', false, true, true, 'bar', 96),
  ('1184', 'ZAMBOS PICOSITOS FAM 24', 'Snacks', 138.00, 100.1800, null, false, true, true, 'bar', 97),
  ('750894610822', 'ZAMBOS PLATANO CEVICHE GRANDE', 'Snacks', 150.00, 100.1800, '750894610822', false, true, true, 'bar', 98),
  ('750894610709', 'ZAMBOS PLATANO CEVICHE PEQ.', 'Snacks', 40.00, 20.8300, '750894610709', false, true, true, 'bar', 99),
  ('750894607181', 'ZAMBOS PLATANO MADURITO GRANDE', 'Snacks', 150.00, 100.1800, '750894607181', false, true, true, 'bar', 100),
  ('750894602131', 'ZAMBOS PLATANO MADURITO PEQ.', 'Snacks', 40.00, 20.8300, '750894602131', false, true, true, 'bar', 101),
  ('750894602780', 'ZAMBOS PLATANO ORIGINAL GRANDE', 'Snacks', 150.00, 100.1800, '750894602780', false, true, true, 'bar', 102),
  ('750894602988', 'ZAMBOS PLATANO ORIGINAL PEQ.', 'Snacks', 40.00, 20.8300, '750894602988', false, true, true, 'bar', 103),
  ('750894613571', 'ZAMBOS PLATANO TAJIN PEQ', 'Snacks', 40.00, 20.8300, '750894613571', false, true, true, 'bar', 104),
  ('750894614097', 'ZAMBOS YUQUITA AJO PARMESANO GRANDE', 'Snacks', 150.00, 100.1800, '750894614097', false, true, true, 'bar', 105),
  ('750894614103', 'ZAMBOS YUQUITA AJO PARMESANO PEQ', 'Snacks', 40.00, 20.8300, '750894614103', false, true, true, 'bar', 106),
  ('1164', 'ZIBAS PAPA CHILETOREADO PEQ', 'Snacks', 40.00, 20.8300, null, false, true, true, 'bar', 107),
  ('750894606719', 'ZIBAS PAPA CLASICAS PEQ.', 'Snacks', 40.00, 20.8300, '750894606719', false, true, true, 'bar', 108),
  ('750894611805', 'ZIBAS PAPA CREMA / ESPECIAS PEQ.', 'Snacks', 40.00, 20.8300, '750894611805', false, true, true, 'bar', 109),
  ('1222', 'ZIBAS PAPA JALAPEÑA PEQ', 'Snacks', 40.00, 20.8300, null, false, true, true, 'bar', 110),
  ('750894611812', 'ZIBAS PAPA MIEL MOSTAZA PEQ', 'Snacks', 40.00, 20.8300, '750894611812', false, true, true, 'bar', 111),
  ('750894611799', 'ZIBAS PAPA QUESO PEQ', 'Snacks', 40.00, 20.8300, '750894611799', false, true, true, 'bar', 112),
  ('7441136201641', 'ALL INKLUSIVE BARRA CEREAL CON PASA', 'Galletas y repostería', 40.00, 24.0600, '7441136201641', false, true, true, 'bar', 1),
  ('016000264694', 'BARRAS NATURE VALLEY', 'Galletas y repostería', 75.00, 33.0000, '016000264694', false, true, true, 'bar', 2),
  ('016000439894', 'BARRAS NATURE VALLEY CHEWY FRUIT NUT', 'Galletas y repostería', 75.00, 13.5600, '016000439894', false, true, true, 'bar', 3),
  ('6223005595812', 'BISKO TAW', 'Galletas y repostería', 25.00, 10.8300, '6223005595812', false, true, true, 'bar', 4),
  ('110000100526', 'BIZCOCHO CON PASAS MUFFIN', 'Galletas y repostería', 95.00, null, null, false, true, true, 'bar', 5),
  ('110000100525', 'BIZCOCHO DE CHOCOLATE MUFFIN', 'Galletas y repostería', 125.00, null, null, false, true, true, 'bar', 6),
  ('110000100462', 'BROWNIES BIZCOCHO', 'Galletas y repostería', 150.00, null, null, false, true, true, 'bar', 7),
  ('653981779009', 'BROWNIES TIOLA', 'Galletas y repostería', 55.00, 40.0000, '653981779009', false, true, true, 'bar', 8),
  ('110000100641', 'CAPACILLOS DE VAINILLA', 'Galletas y repostería', 50.00, 23.7500, null, false, true, true, 'bar', 9),
  ('7591039504957', 'CHOCOLATE FLIPS', 'Galletas y repostería', 55.00, 37.0000, '7591039504957', false, true, true, 'bar', 10),
  ('7500478002580', 'CHOKIS BLACK', 'Galletas y repostería', 65.00, 42.0400, '7500478002580', false, true, true, 'bar', 11),
  ('721282410102', 'CHOKIS CHOCOBASE CAM', 'Galletas y repostería', 70.00, 49.5600, '721282410102', false, true, true, 'bar', 12),
  ('7500478008926', 'CHOKIS CLASICA', 'Galletas y repostería', 70.00, 49.6100, '7500478008926', false, true, true, 'bar', 13),
  ('721282410560', 'CHOKIS CLASICA CAM PEQUEÑA', 'Galletas y repostería', 35.00, 24.8000, '721282410560', false, true, true, 'bar', 14),
  ('7500478001200', 'CHOKIS MIX CHOCOLATE', 'Galletas y repostería', 70.00, 49.6100, '7500478001200', false, true, true, 'bar', 15),
  ('7501000604685', 'CHOKIS RELLENA', 'Galletas y repostería', 70.00, 49.6100, '7501000604685', false, true, true, 'bar', 16),
  ('013087803204', 'CINNAMON ROLL', 'Galletas y repostería', 110.00, 83.9200, '013087803204', false, true, true, 'bar', 17),
  ('764090052850', 'CRACHI MAS MAS ROCKY', 'Galletas y repostería', 25.00, 13.6700, '764090052850', false, true, true, 'bar', 18),
  ('7500478027118', 'CRACKETS MINISW CAM', 'Galletas y repostería', 60.00, 41.3000, '7500478027118', false, true, true, 'bar', 19),
  ('110000100708', 'CROISSANT CHOCOLATE', 'Galletas y repostería', 125.00, null, null, false, true, true, 'bar', 20),
  ('110000100709', 'CROISSANT INTEGRAL', 'Galletas y repostería', 110.00, null, null, false, true, true, 'bar', 21),
  ('110000100589', 'CROISSANT PLAIN PQ', 'Galletas y repostería', 100.00, 37.8000, null, false, true, true, 'bar', 22),
  ('110000100278', 'CROSTATA DE CANELA FIORA', 'Galletas y repostería', 150.00, 120.0000, null, false, true, true, 'bar', 23),
  ('110000100279', 'CROSTATA DE GUAYABA FIORA', 'Galletas y repostería', 150.00, 120.0000, null, false, true, true, 'bar', 24),
  ('753079000418', 'DINO CHOCOLATE', 'Galletas y repostería', 25.00, 11.0000, '753079000418', false, true, true, 'bar', 25),
  ('753079000456', 'DINO FRESA', 'Galletas y repostería', 25.00, 11.0000, '753079000456', false, true, true, 'bar', 26),
  ('753079000470', 'DINO VAINILLA', 'Galletas y repostería', 25.00, 11.0000, '753079000470', false, true, true, 'bar', 27),
  ('110000100340', 'DONAS', 'Galletas y repostería', 100.00, null, null, false, true, true, 'bar', 28),
  ('7500478013609', 'EMPERADOR CHOCOLATE BEE CAM', 'Galletas y repostería', 60.00, 41.3000, '7500478013609', false, true, true, 'bar', 29),
  ('7500478012398', 'EMPERADOR CHOCOLATE BEE CAM PEQUEÑA', 'Galletas y repostería', 35.00, 19.3300, '7500478012398', false, true, true, 'bar', 30),
  ('7500478013616', 'EMPERADOR VAINILLA CAM', 'Galletas y repostería', 60.00, 41.3000, '7500478013616', false, true, true, 'bar', 31),
  ('7500478012404', 'EMPERADOR VAINILLA CS PEQUEÑA', 'Galletas y repostería', 35.00, 19.3300, '7500478012404', false, true, true, 'bar', 32),
  ('7501000601745', 'FLORENTINA DULCE DE LECHE CAJETA', 'Galletas y repostería', 65.00, 49.6100, '7501000601745', false, true, true, 'bar', 33),
  ('7501000601738', 'FLORENTINAS FRESA', 'Galletas y repostería', 70.00, 49.6100, '7501000601738', false, true, true, 'bar', 34),
  ('7501000634118', 'GALLETA AVENA QUAKER DE ALMEN/GRANOLA DR', 'Galletas y repostería', 45.00, 28.9200, '7501000634118', false, true, true, 'bar', 35),
  ('7501000634132', 'GALLETA AVENA QUAKER FRESA ROJAS', 'Galletas y repostería', 45.00, 28.9200, '7501000634132', false, true, true, 'bar', 36),
  ('7501000634125', 'GALLETA AVENA QUAKER MANZANA CANELA VER', 'Galletas y repostería', 45.00, 28.9200, '7501000634125', false, true, true, 'bar', 37),
  ('110000100639', 'GALLETA DE CHOCOLATE', 'Galletas y repostería', 25.00, 38.8200, null, false, true, true, 'bar', 38),
  ('647697659069', 'GALLETA DE COCO MARTIN MEDIANA', 'Galletas y repostería', 60.00, 29.5000, '647697659069', false, true, true, 'bar', 39),
  ('110000100291', 'GALLETA JENGIBRE GRANDE', 'Galletas y repostería', 175.00, 125.0000, null, false, true, true, 'bar', 40),
  ('110000100269', 'GALLETA JOLIE FRESH CHOCOLATE CHIP', 'Galletas y repostería', 200.00, 155.0000, null, false, true, true, 'bar', 41),
  ('787692834624', 'GALLETA LENNY AND LARRYS GRANDE OATMEAL', 'Galletas y repostería', 215.00, 139.1500, '787692834624', false, true, true, 'bar', 42),
  ('044000020071', 'GALLETA MINI CHIPS AHOY', 'Galletas y repostería', 50.00, 36.2500, '044000020071', false, true, true, 'bar', 43),
  ('044000020170', 'GALLETA MINI OREO', 'Galletas y repostería', 50.00, 36.2500, '044000020170', false, true, true, 'bar', 44),
  ('044000020187', 'GALLETA NUTTER BUTTER BITES', 'Galletas y repostería', 50.00, 36.2500, '044000020187', false, true, true, 'bar', 45),
  ('110000100723', 'GALLETA RICURITA TIOLA', 'Galletas y repostería', 80.00, 41.3000, null, false, true, true, 'bar', 46),
  ('044000020255', 'GALLETA RITZ BITS CHEESE', 'Galletas y repostería', 45.00, 36.2500, '044000020255', false, true, true, 'bar', 47),
  ('044000020361', 'GALLETA TEDDY GRAHAMS', 'Galletas y repostería', 50.00, 36.2500, '044000020361', false, true, true, 'bar', 48),
  ('1085', 'GALLETAS BUTTER', 'Galletas y repostería', 15.00, 7.8100, null, false, true, true, 'bar', 49),
  ('044000043148', 'GALLETAS CHIPS AHOY', 'Galletas y repostería', 70.00, 43.3000, '044000043148', false, true, true, 'bar', 50),
  ('7466564881142', 'GALLETAS CON SUSPIRO GRANDE', 'Galletas y repostería', 175.00, 135.0000, '7466564881142', false, true, true, 'bar', 51),
  ('1135', 'GALLETAS CUQUI AVENA CON COCO', 'Galletas y repostería', 50.00, 30.0000, null, false, true, true, 'bar', 52),
  ('1136', 'GALLETAS CUQUI CHOCOLOSCHI', 'Galletas y repostería', 50.00, 30.0000, null, false, true, true, 'bar', 53),
  ('1133', 'GALLETAS CUQUI SALUDABLE VAINILLA', 'Galletas y repostería', 50.00, 30.0000, null, false, true, true, 'bar', 54),
  ('110000100612', 'GALLETAS DE AVENA', 'Galletas y repostería', 25.00, 18.3300, null, false, true, true, 'bar', 55),
  ('653981779023', 'GALLETAS DE AVENA TIOLA', 'Galletas y repostería', 50.00, 35.0000, '653981779023', false, true, true, 'bar', 56),
  ('110000100294', 'GALLETAS DE COCO MARTIN PEQUEÑA', 'Galletas y repostería', 50.00, 20.0000, null, false, true, true, 'bar', 57),
  ('014100077602', 'GALLETAS GOLDFISH CHEDDAR', 'Galletas y repostería', 50.00, 28.2400, '014100077602', false, true, true, 'bar', 58),
  ('110000100295', 'GALLETAS JENGIBRE MEDIANA', 'Galletas y repostería', 125.00, 80.0000, null, false, true, true, 'bar', 59),
  ('110000100296', 'GALLETAS JENGIBRE PEQUEÑA', 'Galletas y repostería', 50.00, 20.0000, null, false, true, true, 'bar', 60),
  ('027800072723', 'GALLETAS KEEBLER CHIPS DELUXE', 'Galletas y repostería', 65.00, 41.6700, '027800072723', false, true, true, 'bar', 61),
  ('110000100297', 'GALLETAS MARTIN COCO PEQUEÑAS', 'Galletas y repostería', 60.00, 29.6700, null, false, true, true, 'bar', 62),
  ('1086', 'GALLETAS MINI M Y M', 'Galletas y repostería', 113.00, 75.0000, null, false, true, true, 'bar', 63),
  ('044000011703', 'GALLETAS MINI OREO CHOCOLATE', 'Galletas y repostería', 50.00, 28.8100, '044000011703', false, true, true, 'bar', 64),
  ('044000061494', 'GALLETAS MINI OREO GOLDEN', 'Galletas y repostería', 50.00, 28.8100, '044000061494', false, true, true, 'bar', 65),
  ('7462226554010', 'GALLETAS NAPOLITANAS', 'Galletas y repostería', 50.00, 35.4000, '7462226554010', false, true, true, 'bar', 66),
  ('044000047009', 'GALLETAS OREO 6 GALLETAS', 'Galletas y repostería', 70.00, 35.0000, '044000047009', false, true, true, 'bar', 67),
  ('7590011251100', 'GALLETAS OREO PEQUEÑA', 'Galletas y repostería', 50.00, 31.6700, '7590011251100', false, true, true, 'bar', 68),
  ('1084', 'GALLETAS PRINCESA', 'Galletas y repostería', 15.00, 7.8100, null, false, true, true, 'bar', 69),
  ('1101', 'GALLETAS PRINCESAS CLUB CRACKERS', 'Galletas y repostería', null, null, null, false, true, true, 'bar', 70),
  ('7466564881159', 'GALLETAS SUSPIRO MEDIANA', 'Galletas y repostería', 150.00, 80.0000, '7466564881159', false, true, true, 'bar', 71),
  ('7460602201138', 'GALLETAS SUSPIRO PEQUEÑO MARTIN', 'Galletas y repostería', 55.00, 20.0000, '7460602201138', false, true, true, 'bar', 72),
  ('110000100302', 'GOLDFISH CHEDDAR', 'Galletas y repostería', 50.00, 27.5400, null, false, true, true, 'bar', 73),
  ('110000100521', 'JUAN BIZCOCHO', 'Galletas y repostería', 95.00, 60.0000, null, false, true, true, 'bar', 74),
  ('038000219856', 'KELLOGGS APPLE JACKS', 'Galletas y repostería', 50.00, 33.0000, '038000219856', false, true, true, 'bar', 75),
  ('038000219528', 'KELLOGGS COCOA KRISPIES', 'Galletas y repostería', 50.00, 33.0000, '038000219528', false, true, true, 'bar', 76),
  ('038000219740', 'KELLOGGS FROOT LOOPS', 'Galletas y repostería', 50.00, 33.0000, '038000219740', false, true, true, 'bar', 77),
  ('038000219634', 'KELLOGGS FROSTED FLAKES', 'Galletas y repostería', 45.00, 33.0000, '038000219634', false, true, true, 'bar', 78),
  ('038000219474', 'KELLOGGS POPS', 'Galletas y repostería', 50.00, 33.0000, '038000219474', false, true, true, 'bar', 79),
  ('9661931395', 'KIRKLAND CHOCOLATE SOFT & CHEWY', 'Galletas y repostería', 35.00, 20.1500, null, false, true, true, 'bar', 80),
  ('7501000636921', 'MAMUT 30G', 'Galletas y repostería', 30.00, 19.3300, '7501000636921', false, true, true, 'bar', 81),
  ('1091', 'MINI ANGELITOS', 'Galletas y repostería', 25.00, 7.7000, null, false, true, true, 'bar', 82),
  ('7501000610228', 'MINI CHOKIS', 'Galletas y repostería', 60.00, 41.3000, '7501000610228', false, true, true, 'bar', 83),
  ('7467515320048', 'MISSCOOKIE CLASICA', 'Galletas y repostería', 46.00, 35.0000, '7467515320048', false, true, true, 'bar', 84),
  ('1115', 'MISSCOOKIE CLASICA COCO', 'Galletas y repostería', 46.00, 35.0000, null, false, true, true, 'bar', 85),
  ('7467515320079', 'MISSCOOKIE CLASICA JENJIBRE', 'Galletas y repostería', 46.00, 35.0000, '7467515320079', false, true, true, 'bar', 86),
  ('013087047004', 'MUFFIN ARANDANOS BLUEBERRY', 'Galletas y repostería', 110.00, 83.3400, '013087047004', false, true, true, 'bar', 87),
  ('013087047059', 'MUFFIN BANANA NUT', 'Galletas y repostería', 110.00, 83.3400, '013087047059', false, true, true, 'bar', 88),
  ('110000100640', 'MUFFINS VARIADOS', 'Galletas y repostería', 50.00, 19.1800, null, false, true, true, 'bar', 89),
  ('812820020447', 'MY MOTTO CRISPY WAFER', 'Galletas y repostería', 45.00, null, '812820020447', false, true, true, 'bar', 90),
  ('016000507661', 'NATURE VALLEY PROTEIN', 'Galletas y repostería', 75.00, 51.5300, '016000507661', false, true, true, 'bar', 91),
  ('038000357213', 'NUTRI GRAIN BLUEBERRY', 'Galletas y repostería', 50.00, 20.9100, '038000357213', false, true, true, 'bar', 92),
  ('038000359217', 'NUTRI GRAIN FRESA', 'Galletas y repostería', 50.00, 24.6700, '038000359217', false, true, true, 'bar', 93),
  ('038000356216', 'NUTRI GRAIN MANZANA', 'Galletas y repostería', 50.00, 20.9100, '038000356216', false, true, true, 'bar', 94),
  ('7466762939041', 'PIRULIN', 'Galletas y repostería', 40.00, 24.4300, '7466762939041', false, true, true, 'bar', 95),
  ('7466762939959', 'PIRULIN LATA GRANDE', 'Galletas y repostería', 445.00, 286.7400, '7466762939959', false, true, true, 'bar', 96),
  ('7466762939010', 'PIRULIN LATA PEQUEÑO', 'Galletas y repostería', 260.00, 108.7600, '7466762939010', false, true, true, 'bar', 97),
  ('110000100647', 'RIP VAN WAFELS VARIEDAD', 'Galletas y repostería', 165.00, 98.2400, null, false, true, true, 'bar', 98),
  ('810291007158', 'TATES BAKE SHOP CHOCOLATE CHIP COOKIES', 'Galletas y repostería', 200.00, 150.0000, '810291007158', false, true, true, 'bar', 99),
  ('1093', 'TAW TAW', 'Galletas y repostería', 25.00, 12.2900, null, false, true, true, 'bar', 100),
  ('110000100270', 'VASO JOLIE FRESH CHOCOLATE CHIP', 'Galletas y repostería', 250.00, 210.0000, null, false, true, true, 'bar', 101),
  ('073390002022', 'AIR HEADS', 'Chocolates y dulces', 25.00, 5.8200, '073390002022', false, true, true, 'bar', 1),
  ('110000100678', 'BABY BOTTLE POP', 'Chocolates y dulces', 100.00, 68.7500, null, false, true, true, 'bar', 2),
  ('7591016851135', 'CHOCOLATE CON LECHE', 'Chocolates y dulces', 90.00, 67.9200, '7591016851135', false, true, true, 'bar', 3),
  ('03424607', 'CHOCOLATE KITKAT', 'Chocolates y dulces', 60.00, 39.1000, '03424607', false, true, true, 'bar', 4),
  ('040000000327', 'CHOCOLATE M&M AMARILLO', 'Chocolates y dulces', 135.00, 64.5000, '040000000327', false, true, true, 'bar', 5),
  ('040000000310', 'CHOCOLATE M&M MARRON', 'Chocolates y dulces', 135.00, 64.5000, '040000000310', false, true, true, 'bar', 6),
  ('040000001447', 'CHOCOLATE M&M ROJO', 'Chocolates y dulces', 135.00, 94.1700, '040000001447', false, true, true, 'bar', 7),
  ('040000602040', 'CHOCOLATE MILKYWAY', 'Chocolates y dulces', 100.00, 62.0000, '040000602040', false, true, true, 'bar', 8),
  ('040000514206', 'CHOCOLATE TWIX', 'Chocolates y dulces', 80.00, 61.0000, '040000514206', false, true, true, 'bar', 9),
  ('040000004356', 'CHOCOLATE TWIX 2 COOKIE BARS', 'Chocolates y dulces', 90.00, 63.1000, '040000004356', false, true, true, 'bar', 10),
  ('1202', 'COQUITO', 'Chocolates y dulces', 25.00, null, null, false, true, true, 'bar', 11),
  ('7591016851555', 'CRICRI', 'Chocolates y dulces', 90.00, 67.9200, '7591016851555', false, true, true, 'bar', 12),
  ('7592396004975', 'DULCE DE LECHE NATULAC', 'Chocolates y dulces', 80.00, 48.7700, '7592396004975', false, true, true, 'bar', 13),
  ('034856008187', 'GOMITAS WELCH PEQUEÑAS', 'Chocolates y dulces', 50.00, 16.2900, '034856008187', false, true, true, 'bar', 14),
  ('110000100353', 'HERSHEYS', 'Chocolates y dulces', 70.00, 58.5000, null, false, true, true, 'bar', 15),
  ('096265191911', 'KINDER BUENO', 'Chocolates y dulces', 110.00, null, '096265191911', false, true, true, 'bar', 16),
  ('00985234', 'KINDER JOY', 'Chocolates y dulces', 125.00, 90.0000, '00985234', false, true, true, 'bar', 17),
  ('854929006557', 'LENGUITAS SOUR BELTS', 'Chocolates y dulces', 20.00, 6.5100, '854929006557', false, true, true, 'bar', 18),
  ('110000100241', 'M&M''S MINI', 'Chocolates y dulces', 90.00, 65.0000, null, false, true, true, 'bar', 19),
  ('75068271', 'MENTOS AZULES', 'Chocolates y dulces', 50.00, 35.3500, '75068271', false, true, true, 'bar', 20),
  ('75068318', 'MENTOS DE FRUTAS', 'Chocolates y dulces', 50.00, 35.3500, '75068318', false, true, true, 'bar', 21),
  ('110000100675', 'NUCITA CREMA CON AVELLANAS', 'Chocolates y dulces', 25.00, 6.7800, null, false, true, true, 'bar', 22),
  ('041116005343', 'PUSHPOP', 'Chocolates y dulces', 90.00, 56.2500, '041116005343', false, true, true, 'bar', 23),
  ('110000100238', 'RING POP', 'Chocolates y dulces', 60.00, 26.7500, null, false, true, true, 'bar', 24),
  ('040000001638', 'SKITTLES AZULES', 'Chocolates y dulces', 110.00, 75.2700, '040000001638', false, true, true, 'bar', 25),
  ('1241', 'SKITTLES DULCE', 'Chocolates y dulces', 25.00, 19.7300, null, false, true, true, 'bar', 26),
  ('040000001621', 'SKITTLES MORADOS', 'Chocolates y dulces', 110.00, 75.2700, '040000001621', false, true, true, 'bar', 27),
  ('040000001607', 'SKITTLES ROJOS', 'Chocolates y dulces', 110.00, 75.2700, '040000001607', false, true, true, 'bar', 28),
  ('040000514251', 'SNICKERS', 'Chocolates y dulces', 100.00, 55.8300, '040000514251', false, true, true, 'bar', 29),
  ('040000000518', 'STARBURST', 'Chocolates y dulces', 110.00, 75.2700, '040000000518', false, true, true, 'bar', 30),
  ('009800007615', 'TIC TAC FRESH MINT', 'Chocolates y dulces', 125.00, 83.7200, '009800007615', false, true, true, 'bar', 31),
  ('034856028925', 'WELCHS FRUIT SNACKS BERRIES''N CHERRIES', 'Chocolates y dulces', 85.00, 58.0200, '034856028925', false, true, true, 'bar', 32),
  ('034856028918', 'WELCHS FRUIT SNACKS ISLAND FRUITS', 'Chocolates y dulces', 85.00, 58.0200, '034856028918', false, true, true, 'bar', 33),
  ('034856028987', 'WELCHS FRUIT SNACKS MIXED FRUIT', 'Chocolates y dulces', 85.00, 58.0200, '034856028987', false, true, true, 'bar', 34),
  ('110000100714', 'BLUE RIBBON CLASSIC VANILLA SANDWICH IC', 'Helados y paletas', 70.00, 27.5000, null, false, true, true, 'bar', 1),
  ('1250', 'COPA BON CHOCOLATE PRISCILLA', 'Helados y paletas', 125.00, null, '7468162827980', false, true, true, 'bar', 2),
  ('1140', 'COPA CHOCOLATE PRISCILA', 'Helados y paletas', 120.00, 83.3300, null, false, true, true, 'bar', 3),
  ('1139', 'COPA DE FRESA BON', 'Helados y paletas', 125.00, 83.3300, '7468162820615', false, true, true, 'bar', 4);

-- filas 601–636
insert into _pen (codigo, name, categoria, price, cost, barcode, is_bev, vendible, inventariable, area, posicion) values
  ('3415583272282', 'HELADO DAZS DE DULCE DE LECHE', 'Helados y paletas', 355.00, 166.1000, '3415583272282', false, true, true, 'bar', 5),
  ('3415581312287', 'HELADO DAZS STRAWBERRY', 'Helados y paletas', 355.00, 166.1000, '3415581312287', false, true, true, 'bar', 6),
  ('3415581311280', 'HELADO DAZS VAINILLA', 'Helados y paletas', 355.00, 166.1000, '3415581311280', false, true, true, 'bar', 7),
  ('1038', 'HELADO DE CHINOLA', 'Helados y paletas', 100.00, 70.8000, null, false, true, true, 'bar', 8),
  ('1041', 'HELADO DE CHINOLA LECHE CONDENSADA', 'Helados y paletas', 100.00, 70.8000, null, false, true, true, 'bar', 9),
  ('1043', 'HELADO DE CHOCOLATE DULCE DE LECHE', 'Helados y paletas', 100.00, 60.0000, null, false, true, true, 'bar', 10),
  ('1039', 'HELADO DE COCO CREMOSO', 'Helados y paletas', 100.00, 70.8000, null, false, true, true, 'bar', 11),
  ('1042', 'HELADO DE COCO DULCE DE LECHE', 'Helados y paletas', 100.00, 60.0000, null, false, true, true, 'bar', 12),
  ('1044', 'HELADO DE DULCE DE LECHE OREO', 'Helados y paletas', 100.00, 60.0000, null, false, true, true, 'bar', 13),
  ('1037', 'HELADO DE FRESA', 'Helados y paletas', 100.00, 64.9000, null, false, true, true, 'bar', 14),
  ('1040', 'HELADO DE FRESA LECHE CONDENSADA', 'Helados y paletas', 100.00, 70.8000, null, false, true, true, 'bar', 15),
  ('1067', 'HELADO DE FRESA NUTELLA', 'Helados y paletas', 100.00, 70.8000, null, false, true, true, 'bar', 16),
  ('1036', 'HELADO DE MANGO', 'Helados y paletas', 100.00, 60.0000, null, false, true, true, 'bar', 17),
  ('1035', 'HELADO DE TAMARINDO', 'Helados y paletas', 100.00, 60.0000, null, false, true, true, 'bar', 18),
  ('110000100671', 'ICE POPS NIEVE DE FRUTAS', 'Helados y paletas', 25.00, 8.8500, null, false, true, true, 'bar', 19),
  ('1068', 'MINI MAGNUM', 'Helados y paletas', 120.00, 80.8300, null, false, true, true, 'bar', 20),
  ('7506306417571', 'MORDISKO', 'Helados y paletas', 110.00, 54.7200, '7506306417571', false, true, true, 'bar', 21),
  ('1142', 'PALETA CHOCO CHOCO', 'Helados y paletas', 100.00, 56.6200, null, false, true, true, 'bar', 22),
  ('1143', 'PALETA CHOCO CREMA', 'Helados y paletas', 85.00, 56.6200, '7468162802321', false, true, true, 'bar', 23),
  ('3415587404054', 'PALETA DAZS CHOCOLATE', 'Helados y paletas', 254.00, 128.8100, '3415587404054', false, true, true, 'bar', 24),
  ('3415587422058', 'PALETA DAZS SALTED CARAMEL', 'Helados y paletas', 275.00, 128.8100, '3415587422058', false, true, true, 'bar', 25),
  ('3415587405051', 'PALETA DAZS STRAWBERRIES & CREAM', 'Helados y paletas', 275.00, 128.8100, '3415587405051', false, true, true, 'bar', 26),
  ('1247', 'PALETA DE CHERRY', 'Helados y paletas', 35.00, 23.3100, '7468162813501', false, true, true, 'bar', 27),
  ('1246', 'PALETA DE FRAMBUESA', 'Helados y paletas', 35.00, 23.3100, '7468162810944', false, true, true, 'bar', 28),
  ('1249', 'PALETA DE FRESA 85G', 'Helados y paletas', 75.00, 49.9700, '7468162811019', false, true, true, 'bar', 29),
  ('1248', 'PALETA DE FRESA CREMA', 'Helados y paletas', 75.00, 49.9700, '7468162813013', false, true, true, 'bar', 30),
  ('1245', 'PALETA DE MANZANA', 'Helados y paletas', 35.00, 23.3100, '7468162810968', false, true, true, 'bar', 31),
  ('1244', 'PALETA DE UVA', 'Helados y paletas', 35.00, 23.3100, '7468162810951', false, true, true, 'bar', 32),
  ('1141', 'PALETA MAGNUM ALMENDRAS 90ML', 'Helados y paletas', 160.00, 108.3300, '7506306415775', false, true, true, 'bar', 33),
  ('1251', 'PALETA MAGNUM COOKIE REMIX 85 ML', 'Helados y paletas', 160.00, null, '7506306418066', false, true, true, 'bar', 34),
  ('1138', 'SANDWICH BON VAINILLA', 'Helados y paletas', 110.00, 78.1500, '7468162813846', false, true, true, 'bar', 35),
  ('1015', 'DESCORCHE NORMAL', 'Servicios de bar', 650.00, null, null, false, true, true, 'bar', 1),
  ('1240', 'DESCORCHE PREMIUM', 'Servicios de bar', 1000.00, null, null, false, true, true, 'bar', 2),
  ('110000100349', 'FUNDA DE HIELO', 'Servicios de bar', 75.00, 35.0000, null, false, true, true, 'bar', 3),
  ('110000100341', 'VASO CON HIELO', 'Servicios de bar', 10.00, null, null, false, true, true, 'bar', 4),
  ('1016', 'VASO CON HIELO GRANDE', 'Servicios de bar', 30.00, null, null, false, true, true, 'bar', 5);

create temp table _pen_insumos (
  codigo  text primary key,
  name    text not null,
  cost    numeric,
  barcode text
) on commit drop;

insert into _pen_insumos (codigo, name, cost, barcode) values
  ('1100', 'KETCHUP SOBRE', null, null),
  ('110000100321', 'LECHE', 77.2500, null),
  ('110000100306', 'LONGANIZA', null, null),
  ('1095', 'MANTECA VEGETAL', null, null),
  ('1121', 'MIEL RINCON EXTRA HOT', 400.0000, null),
  ('1175', 'PAN MEDIA BAGUETTE', 33.8000, null),
  ('1096', 'PORCION DE SALAMI', null, null),
  ('1097', 'QUESO BLANCO DE FREIR DE LA RICA', null, null),
  ('1176', 'QUESO MOZZARELLA RICA', 4278.3500, null),
  ('1098', 'REDROT ORIGINAL GALON', null, null),
  ('110000100389', 'SALCHICHA', null, null),
  ('1099', 'SALSA BBQ', null, null);

create temp table _pen_categorias (
  name     text primary key,
  posicion int  not null
) on commit drop;

insert into _pen_categorias (name, posicion) values
  ('Cervezas', 10),
  ('Licores y vinos', 20),
  ('Tragos y cócteles', 30),
  ('Refrescos', 40),
  ('Aguas', 50),
  ('Jugos y lácteos', 60),
  ('Deportivas y energizantes', 70),
  ('Café', 80),
  ('Pizzas', 90),
  ('Comida', 100),
  ('Snacks', 110),
  ('Galletas y repostería', 120),
  ('Chocolates y dulces', 130),
  ('Helados y paletas', 140),
  ('Servicios de bar', 150);

do $$
declare
  v_business     uuid := '85924083-2e8e-4e64-8192-808ee24674ed';
  v_total        int  := 636;
  v_tax_id       uuid;
  v_menu_id      uuid;
  v_menus        int;
  v_kitchen      boolean;
  v_mode         text;
  v_bar_id       uuid;
  v_cocina_id    uuid;
  v_wh_id        uuid;
  v_wh_name      text;
  v_wh_active    boolean;
  v_n            int;
  v_list         text;
  v_nuevos       int;
  v_actualizados int;
  v_insumos      int;
  v_cocina_ins   int;
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
      'por orden. Apágalo primero si el negocio no lo cobra.';
  end if;

  -- 1e) Ningún código de la lista apunta a VARIOS productos o insumos: no
  --     sabría cuál actualizar.
  select string_agg(format('%s (%s productos)', p.codigo, x.n), ', ')
    into v_list
  from _pen p
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
      'Códigos de la lista que ya tienen VARIOS productos, no sé cuál '
      'actualizar: %', v_list;
  end if;

  select string_agg(format('%s (%s insumos)', c.codigo, x.n), ', ')
    into v_list
  from (select codigo, barcode from _pen
        union all
        select codigo, barcode from _pen_insumos) c
  cross join lateral (
    select count(*) as n
    from public.inventory_items ii
    where ii.business_id = v_business
      and (ii.sku = c.codigo or ii.barcode = c.codigo
           or (c.barcode is not null and ii.barcode = c.barcode))
  ) x
  where x.n > 1;

  if v_list is not null then
    raise exception
      'Códigos de la lista que ya tienen VARIOS insumos, no sé cuál usar: %',
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
  --     (mismo ORDER BY). Sin ella la venta no descuenta nada.
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

  -- 1h) Áreas de comanda. Con cocina encendida hacen falta las DOS: `bar` y
  --     `cocina`. Con cocina apagada la venta pasa directo, sin comanda.
  if v_kitchen then
    select id into v_bar_id from public.print_areas
     where business_id = v_business and is_active and code = 'bar';
    select id into v_cocina_id from public.print_areas
     where business_id = v_business and is_active and code = 'cocina';

    if v_bar_id is null or v_cocina_id is null then
      select string_agg(format('%s (%s)', name, code), ', ')
        into v_list
      from public.print_areas
      where business_id = v_business
        and is_active
        and code not in ('cashier', 'fiscal', 'cash_close');

      raise exception
        'Cocina está encendida y falta el área de comanda %: los productos '
        'van a BAR (bar) y la comida a COCINA (cocina). Áreas que hay: %.',
        case when v_bar_id is null and v_cocina_id is null then '"bar" y "cocina"'
             when v_bar_id is null then '"bar"' else '"cocina"' end,
        coalesce(v_list, 'ninguna');
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
  from _pen_categorias c
  where not exists (
    select 1 from public.categories x
    where x.business_id = v_business
      and lower(btrim(x.name)) = lower(c.name)
  );

  -- =========================================================================
  -- 4) PRODUCTOS — por código. Actualiza los que existen, inserta los demás.
  -- =========================================================================

  create temp table _pen_ids (
    codigo text primary key,
    id     uuid not null,
    nuevo  boolean not null
  ) on commit drop;

  insert into _pen_ids (codigo, id, nuevo)
  select p.codigo, mi.id, false
  from _pen p
  join public.menu_items mi
    on mi.business_id = v_business
   and (mi.sku = p.codigo or mi.barcode = p.codigo
        or (p.barcode is not null and mi.barcode = p.barcode));

  -- Un mismo producto calzando con DOS códigos de la lista: no sé cuál es.
  select string_agg(format('%s ← %s', mi.name, z.codigos), '; ')
    into v_list
  from (
    select id, string_agg(codigo, ', ') as codigos
    from _pen_ids group by id having count(*) > 1
  ) z
  join public.menu_items mi on mi.id = z.id;

  if v_list is not null then
    raise exception
      'Productos que calzan con varios códigos de la lista a la vez: %', v_list;
  end if;

  -- is_active: la OFERTA siempre apagada; uno que esperaba precio (en $0 e
  -- inactivo) se activa cuando la lista se lo trae; lo demás queda como esté
  -- (no se reactiva lo que apagaron a mano). mi.price/mi.is_active en el CASE
  -- son los valores de ANTES del update.
  update public.menu_items mi
  set category_id         = cat.id,
      price               = coalesce(p.price, mi.price),
      cost                = coalesce(p.cost, mi.cost),
      tax_mode            = 'inclusive',
      sku                 = p.codigo,
      barcode             = coalesce(p.barcode, mi.barcode),
      is_beverage         = p.is_bev,
      is_active           = case
                              when not p.vendible then false
                              when coalesce(p.price, 0) > 0
                                   and mi.price = 0 and not mi.is_active then true
                              else mi.is_active
                            end,
      position            = p.posicion,
      print_area_code     = case when v_kitchen then p.area end,
      allow_negative_sale = true,
      updated_at          = now()
  from _pen_ids i
  join _pen p on p.codigo = i.codigo
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
  select gen_random_uuid(), v_business, cat.id, p.name, coalesce(p.price, 0),
         p.cost, 'inclusive', p.codigo, p.barcode,
         p.vendible and coalesce(p.price, 0) > 0, p.is_bev, p.posicion,
         case when v_kitchen then p.area end, true
  from _pen p
  cross join lateral (
    select c.id from public.categories c
    where c.business_id = v_business
      and lower(btrim(c.name)) = lower(p.categoria)
    order by c.created_at
    limit 1
  ) cat
  where not exists (select 1 from _pen_ids i where i.codigo = p.codigo);
  get diagnostics v_nuevos = row_count;

  insert into _pen_ids (codigo, id, nuevo)
  select p.codigo, mi.id, true
  from _pen p
  join public.menu_items mi
    on mi.business_id = v_business
   and mi.sku = p.codigo
  where not exists (select 1 from _pen_ids i where i.codigo = p.codigo);

  -- =========================================================================
  -- 5) IMPUESTOS — exactamente el ITBIS. Sin la fila en menu_item_taxes la
  --    factura sale con ITBIS 0.00; con otro impuesto, cobra de más.
  -- =========================================================================

  delete from public.menu_item_taxes mit
  using _pen_ids i
  where mit.item_id = i.id
    and mit.tax_id <> v_tax_id;

  insert into public.menu_item_taxes (item_id, tax_id)
  select i.id, v_tax_id
  from _pen_ids i
  where not exists (
    select 1 from public.menu_item_taxes x
    where x.item_id = i.id and x.tax_id = v_tax_id
  );

  -- =========================================================================
  -- 6) ÁREA DE COMANDA (N:M). El legacy (print_area_code) ya quedó en el
  --    paso 4. Se borra cualquier otra área para no imprimir por DOS lados.
  -- =========================================================================

  delete from public.menu_item_print_areas x
  using _pen_ids i
  join _pen p on p.codigo = i.codigo
  where x.menu_item_id = i.id
    and (not v_kitchen
         or x.print_area_id <> case p.area when 'cocina' then v_cocina_id
                                           else v_bar_id end);

  if v_kitchen then
    insert into public.menu_item_print_areas (menu_item_id, print_area_id)
    select i.id, case p.area when 'cocina' then v_cocina_id else v_bar_id end
    from _pen_ids i
    join _pen p on p.codigo = i.codigo
    where not exists (
      select 1 from public.menu_item_print_areas x
      where x.menu_item_id = i.id
        and x.print_area_id = case p.area when 'cocina' then v_cocina_id
                                          else v_bar_id end
    );
  end if;

  -- =========================================================================
  -- 7) ENLACE AL MENÚ — sin esto el producto no aparece en la caja.
  -- =========================================================================

  insert into public.menu_item_links (menu_id, item_id, position)
  select v_menu_id, i.id, p.posicion
  from _pen_ids i
  join _pen p on p.codigo = i.codigo
  where not exists (
    select 1 from public.menu_item_links l
    where l.menu_id = v_menu_id and l.item_id = i.id
  );

  -- =========================================================================
  -- 8) INVENTARIO — un insumo por producto, emparejado por CÓDIGO (por
  --    nombre se cruzarían los descuentos). Stock en CERO: no se registra
  --    ninguna existencia inicial.
  --    DML directo y no fn_menu_item_set_inventory_tracked: esa función exige
  --    auth.uid() con rol, y desde el SQL Editor es null (INSUFFICIENT_ROLE).
  -- =========================================================================

  create temp table _pen_insumo_de (
    codigo  text primary key,
    item_id uuid
  ) on commit drop;

  -- 8a) El insumo que el producto ya tenga enlazado, o uno que calce por código.
  insert into _pen_insumo_de (codigo, item_id)
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
  from _pen p
  join _pen_ids i on i.codigo = p.codigo
  where p.inventariable;

  -- 8b) Los que faltan se crean, con el mismo nombre que el producto.
  insert into public.inventory_items (
    business_id, sku, barcode, name, unit, cost, is_active
  )
  select v_business, p.codigo, p.barcode, p.name, 'unidad',
         coalesce(p.cost, 0), true
  from _pen p
  join _pen_insumo_de s on s.codigo = p.codigo
  where s.item_id is null;
  get diagnostics v_insumos = row_count;

  update _pen_insumo_de s
  set item_id = ii.id
  from public.inventory_items ii
  where s.item_id is null
    and ii.business_id = v_business
    and ii.sku = s.codigo;

  -- 8c) Link directo + tracking.
  update public.menu_items mi
  set inventory_item_id    = s.item_id,
      is_inventory_tracked = true
  from _pen_ids i
  join _pen_insumo_de s on s.codigo = i.codigo
  where mi.id = i.id
    and (mi.inventory_item_id is distinct from s.item_id
         or not coalesce(mi.is_inventory_tracked, false));

  -- 8d) Insumos de cocina (no se venden): solo la ficha, en cero.
  insert into public.inventory_items (
    business_id, sku, barcode, name, unit, cost, is_active
  )
  select v_business, s.codigo, s.barcode, s.name, 'unidad',
         coalesce(s.cost, 0), true
  from _pen_insumos s
  where not exists (
    select 1 from public.inventory_items ii
    where ii.business_id = v_business
      and (ii.sku = s.codigo or ii.barcode = s.codigo
           or (s.barcode is not null and ii.barcode = s.barcode))
  );
  get diagnostics v_cocina_ins = row_count;

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
  from _pen p
  where (select count(*) from public.menu_items mi
         where mi.business_id = v_business and mi.sku = p.codigo) <> 1;
  if v_n > 0
     or (select count(*) from _pen_ids) <> v_total
     or (select count(distinct id) from _pen_ids) <> v_total then
    raise exception '% códigos sin producto o con más de uno. Revertido.', v_n;
  end if;

  -- 9b) Precio (si la lista lo trae), ITBIS incluido, categoría y código de barras.
  select count(*) into v_n
  from _pen_ids i
  join public.menu_items mi on mi.id = i.id
  join _pen p on p.codigo = i.codigo
  left join public.categories c on c.id = mi.category_id
  where (p.price is not null and mi.price <> p.price)
     or mi.tax_mode <> 'inclusive'
     or c.id is null
     or lower(btrim(c.name)) <> lower(p.categoria)
     or (p.barcode is not null and mi.barcode is distinct from p.barcode);
  if v_n > 0 then
    raise exception '% productos con precio, impuesto, categoría o código de barras incorrectos. Revertido.', v_n;
  end if;

  -- 9c) La oferta apagada. Los activos en $0 NO abortan: el dueño decidió
  --     (01/10/2026) activar todo antes de tener precios, y una carga de
  --     precios parcial no puede quedar bloqueada por eso. Salen como aviso
  --     en la fila 2 del reporte.
  select count(*), string_agg(mi.name, ', ')
    into v_n, v_list
  from _pen_ids i
  join public.menu_items mi on mi.id = i.id
  join _pen p on p.codigo = i.codigo
  where mi.is_active and not p.vendible;
  if v_n > 0 then
    raise exception '% productos que deben estar apagados siguen activos (%). Revertido.', v_n, v_list;
  end if;

  -- 9d) Exactamente el ITBIS.
  select count(*) into v_n
  from _pen_ids i
  where not exists (select 1 from public.menu_item_taxes x
                    where x.item_id = i.id and x.tax_id = v_tax_id)
     or exists (select 1 from public.menu_item_taxes x
                where x.item_id = i.id and x.tax_id <> v_tax_id);
  if v_n > 0 then
    raise exception '% productos sin ITBIS o con otro impuesto. Revertido.', v_n;
  end if;

  -- 9e) Área: legacy y N:M de acuerdo, cada uno en la suya.
  select count(*) into v_n
  from _pen_ids i
  join public.menu_items mi on mi.id = i.id
  join _pen p on p.codigo = i.codigo
  where mi.print_area_code is distinct from case when v_kitchen then p.area end
     or (not v_kitchen and exists (
           select 1 from public.menu_item_print_areas x
           where x.menu_item_id = i.id))
     or (v_kitchen and (
           (select count(*) from public.menu_item_print_areas x
             where x.menu_item_id = i.id) <> 1
           or not exists (
             select 1 from public.menu_item_print_areas x
             where x.menu_item_id = i.id
               and x.print_area_id = case p.area when 'cocina' then v_cocina_id
                                                 else v_bar_id end)));
  if v_n > 0 then
    raise exception '% productos con el área de comanda equivocada. Revertido.', v_n;
  end if;

  -- 9f) Todos en el menú de la caja.
  select count(*) into v_n
  from _pen_ids i
  where not exists (select 1 from public.menu_item_links l
                    where l.menu_id = v_menu_id and l.item_id = i.id);
  if v_n > 0 then
    raise exception '% productos fuera del menú: no saldrían en la caja. Revertido.', v_n;
  end if;

  -- 9g) Inventariables enlazados a un insumo del negocio, y todos vendibles
  --     aunque estén en cero.
  select count(*) into v_n
  from _pen p
  join _pen_ids i on i.codigo = p.codigo
  join public.menu_items mi on mi.id = i.id
  left join public.inventory_items ii
    on ii.id = mi.inventory_item_id and ii.business_id = v_business
  where (p.inventariable
         and (not coalesce(mi.is_inventory_tracked, false) or ii.id is null))
     or not mi.allow_negative_sale;
  if v_n > 0 then
    raise exception '% productos inventariables sin insumo o sin "vender aunque esté agotado". Revertido.', v_n;
  end if;

  -- 9h) Ningún insumo compartido por dos productos de la lista.
  select count(*) into v_n
  from (select item_id from _pen_insumo_de
        group by item_id having count(*) > 1) z;
  if v_n > 0 then
    raise exception '% insumos compartidos por varios productos: descontarían cruzado. Revertido.', v_n;
  end if;

  -- 9i) Los insumos de cocina, uno por código.
  select count(*) into v_n
  from _pen_insumos s
  where (select count(*) from public.inventory_items ii
         where ii.business_id = v_business
           and (ii.sku = s.codigo or ii.barcode = s.codigo)) <> 1;
  if v_n > 0 then
    raise exception '% insumos de cocina sin ficha o repetidos. Revertido.', v_n;
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

  raise notice 'OK — % productos (% nuevos, % actualizados) · % insumos de productos y % de cocina nuevos · bodega "%" · Commit.',
    v_total, v_nuevos, v_actualizados, v_insumos, v_cocina_ins, v_wh_name;
end $$;

commit;

-- ============================================================================
-- REPORTE — todas las filas deben decir ✓
-- ============================================================================

with codigos as (
  select unnest(string_to_array(
    '4014086096518,4014086096334,4014086096365,4014086096303,1215,8412598005862,8412598004964,8412598006074,8412598005879,08787337,110000100619,4002103248248,08374189,87120103,8712000900045,072890006189,752245123005,8410793181947,03456217,4066600303336,4066600060741,1231,74601561,110000100474,8423453915547,087975903550,087975003502,74601325,07199044,08780538,08780936,7503044233180,110000100542,7503034941200,7503034941217,8410793153135,8410793156136,3155930006015,4002103248323,8410793282934,8712000030582,072890004994,072890006196,01833225,034100005610,75031589,7463172802996,1219,8008440222008,7463172803764,7463172803665,7463172803672,74621774,74621767,74601554,7501064199141,8002230000302,5000329002230,5000299618073,7460736960086,1049,4750021000157,7460855234990,5000299225028,7460855233498,744607002301,8001968005047,3263280120470,110000100585,3147690060703,3147699118344,7503018819501,8410702039628,110000100566,7460736904721,1232,3263285152896,1050,7460855238066,5000267107776,5000267190150,5011166081104,5011166068020,5011166081128,110000100496,110000100454,110000100455,110000100456,110000100457,110000100458,110000100459,110000100555,110000100662,110000100554,110000100552,110000100553,110000100560,110000100556,082000727477,082000723844,110000100568,110000100685,110000100582,110000100584,110000100691,110000100653,110000100693,110000100655,110000100656,110000100654,110000100565,110000100498,110000100563,110000100561,785249462429,679065252237,635985500018,7463172803320,8002270676819,8002270696831,8002270726828,7463172803733,7465383000321,07811102,07844508,07811403,7465383000307,07811801,049000006209,049000071993,049000057638,049000057676,049000550733,049000057669,049000550412,049000547870,049000057683,090478410036,090478410012,090478410029,073360377518,073360237515,073360617515,012000130311,01208500,012000028632,7463172803467,7463172803528,7463172803580,7441003530232,7461136665007,7461136665014,7461136665038,8002270916588,016571910303,016571952105,016571950842,016571940355,016571940331,016571954369,016571952679,016571910327,016571911256,016571910310,016571940348,016571910372,016571950293,016571950859,016571953867,016571953843,016571955144,016571953829,016571952839,016571952822,016571957438,049000057690,1239,049000551808,061314000032,079298000078,632565000029,632565000012,8002270966576,8000815355250,701891100014,7461136665069,893919001301,1063,893919001509,1061,1060,893504860702,735051000630,735051000562,735051000579,612197211260,612197211161,7466442630046,7466442630039,7466442630060,7466442630145,7466442630053,7466442630107,110000100274,1110,096619204212,096619204205,096619192328,096619204014,110000100559,110000100558,024474007211,024474007020,024474007068,024474007174,110000100303,790330021270,110000100712,790330021171,790330021089,790330021140,790330021249,790330002323,031200008091,7462275402812,041800490004,041800326006,041800317004,842595135534,842595121766,842595106596,842595136050,842595109368,9002490204006,9002490212148,9002490267544,7460548000130,7460548000147,7460548002660,7460548000178,7460548000161,7460548000185,7460548000017,7460548000048,7460548000024,7460548000031,7460548000154,7460548002127,7460548002134,7460548002141,7460548002158,7460548002189,7460548002172,7460548002165,052000049008,052000050820,052000047905,052000050622,052000047912,070847029106,650240070495,650240063213,650240069192,650240069208,650240063220,650240063244,650240061325,110000100313,110000100312,110000100314,110000100315,1058,1057,01264904,1059,110000100696,110000100703,110000100320,110000100702,110000100323,110000100324,110000100700,110000100699,110000100698,110000100697,110000100322,110000100704,110000100326,110000100327,110000100325,110000100701,1181,1180,1179,1183,1046,1045,1047,1178,1048,1177,1055,1070,110000100570,110000100687,110000100532,1217,1218,110000100280,110000100281,1120,1119,110000100282,110000100283,110000100461,110000100464,110000100331,110000100663,1216,110000100615,110000100332,021000010875,110000100317,110000100334,110000100569,1182,110000100551,1064,110000100277,1132,110000100339,110000100308,110000100309,110000100310,110000100689,110000100688,110000100657,110000100658,110000100692,110000100499,110000100500,1034,1186,110000100686,110000100328,110000100330,110000100329,1242,110000100335,110000100348,7460496801476,7467113580882,7451011040425,7467113580974,7451011041149,7451011040289,7451011041132,7451011040043,7460496804286,1081,7460496805214,7460496804293,7460496803685,721282411123,7465619163011,7460496805573,7464113824121,1082,1203,7460496805672,7460496805498,7460496805016,1118,7460496803999,1083,7460496804002,721282411109,7460496806068,7460496803623,1087,7460496803616,7460496806105,1088,7460496806143,7460496804811,7460496803944,1089,7460496803968,1090,7460496803951,1117,721282411055,7460496806204,1230,1092,1206,7460496800523,1204,1205,607766702652,029000017931,7460496800530,038000183737,038000183713,1113,038000184949,038000846748,038000184956,038000846731,038000184932,038000138638,038000846755,20788124,1170,750894614301,1149,1653265,750894603404,750894614288,750894606399,110000100343,721282402770,721282402787,7460496805627,757528048075,757528048532,154545845,750894609505,750894612550,750894613212,750894613236,1185,1094,014113911856,750894671007,750894671151,750894671458,110000100434,110000100432,750894671229,1172,750894671243,750894612215,750894614059,750894611645,1184,750894610822,750894610709,750894607181,750894602131,750894602780,750894602988,750894613571,750894614097,750894614103,1164,750894606719,750894611805,1222,750894611812,750894611799,7441136201641,016000264694,016000439894,6223005595812,110000100526,110000100525,110000100462,653981779009,110000100641,7591039504957,7500478002580,721282410102,7500478008926,721282410560,7500478001200,7501000604685,013087803204,764090052850,7500478027118,110000100708,110000100709,110000100589,110000100278,110000100279,753079000418,753079000456,753079000470,110000100340,7500478013609,7500478012398,7500478013616,7500478012404,7501000601745,7501000601738,7501000634118,7501000634132,7501000634125,110000100639,647697659069,110000100291,110000100269,787692834624,044000020071,044000020170,044000020187,110000100723,044000020255,044000020361,1085,044000043148,7466564881142,1135,1136,1133,110000100612,653981779023,110000100294,014100077602,110000100295,110000100296,027800072723,110000100297,1086,044000011703,044000061494,7462226554010,044000047009,7590011251100,1084,1101,7466564881159,7460602201138,110000100302,110000100521,038000219856,038000219528,038000219740,038000219634,038000219474,9661931395,7501000636921,1091,7501000610228,7467515320048,1115,7467515320079,013087047004,013087047059,110000100640,812820020447,016000507661,038000357213,038000359217,038000356216,7466762939041,7466762939959,7466762939010,110000100647,810291007158,1093,110000100270,073390002022,110000100678,7591016851135,03424607,040000000327,040000000310,040000001447,040000602040,040000514206,040000004356,1202,7591016851555,7592396004975,034856008187,110000100353,096265191911,00985234,854929006557,110000100241,75068271,75068318,110000100675,041116005343,110000100238,040000001638,1241,040000001621,040000001607,040000514251,040000000518,009800007615,034856028925,034856028918,034856028987,110000100714,1250,1140,1139,3415583272282,3415581312287,3415581311280,1038,1041,1043,1039,1042,1044,1037,1040,1067,1036,1035,110000100671,1068,7506306417571,1142,1143,3415587404054,3415587422058,3415587405051,1247,1246,1249,1248,1245,1244,1141,1251,1138,1015,1240,110000100349,110000100341,1016', ',')) as codigo
),
items as (
  select mi.*
  from public.menu_items mi
  join codigos c on c.codigo = mi.sku
  where mi.business_id = '85924083-2e8e-4e64-8192-808ee24674ed'::uuid
),
ins_codigos as (
  select unnest(string_to_array('1100,110000100321,110000100306,1095,1121,1175,1096,1097,1176,1098,110000100389,1099', ',')) as codigo
),
itbis as (
  select t.* from public.taxes t
  where t.business_id = '85924083-2e8e-4e64-8192-808ee24674ed'::uuid
    and t.name ilike '%itbis%' and t.rate = 18 and coalesce(t.is_active, true)
  limit 1
),
bs as (
  select * from public.business_settings
  where business_id = '85924083-2e8e-4e64-8192-808ee24674ed'::uuid
),
area_de as (
  select x.menu_item_id, a.code
  from public.menu_item_print_areas x
  join public.print_areas a on a.id = x.print_area_id
  join items i on i.id = x.menu_item_id
),
r(orden, concepto, encontrado, esperado, ok) as (
  select 1, 'Productos de la lista',
         (select count(*) from items)::text, '636',
         (select count(*) from items) = 636
  union all
  select 2, 'Activos en $0 (la caja los cobra GRATIS: ponles precio)',
         (select count(*) from items where is_active and price <= 0)::text
           || ' de ' || (select count(*) filter (where is_active) from items) || ' activos',
         '0',
         (select count(*) from items where is_active and price <= 0) = 0
  union all
  select 3, 'Con precio',
         (select count(*) from items where price > 0)::text, '624 o más',
         (select count(*) from items where price > 0) >= 624
  union all
  select 4, 'Con ITBIS incluido (inclusive)',
         (select count(*) from items where tax_mode = 'inclusive')::text, '636',
         (select count(*) from items where tax_mode = 'inclusive') = 636
  union all
  select 5, 'Vinculados SOLO al ITBIS 18%',
         (select count(*) from items i
           where exists (select 1 from public.menu_item_taxes x
                         join itbis t on t.id = x.tax_id where x.item_id = i.id)
             and not exists (select 1 from public.menu_item_taxes x
                             where x.item_id = i.id
                               and x.tax_id not in (select id from itbis)))::text,
         '636',
         (select count(*) from items i
           where exists (select 1 from public.menu_item_taxes x
                         join itbis t on t.id = x.tax_id where x.item_id = i.id)
             and not exists (select 1 from public.menu_item_taxes x
                             where x.item_id = i.id
                               and x.tax_id not in (select id from itbis))) = 636
  union all
  select 6, 'Enlazados al menú de la caja',
         (select count(*) from items i where exists (
            select 1 from public.menu_item_links l where l.item_id = i.id))::text,
         '636',
         (select count(*) from items i where exists (
            select 1 from public.menu_item_links l where l.item_id = i.id)) = 636
  union all
  select 7, 'Comanda a COCINA / BAR',
         (select count(*) filter (where code = 'cocina') || ' / ' ||
                 count(*) filter (where code = 'bar') from area_de),
         case when (select coalesce(kitchen_enabled, true) from bs)
              then '58 / 578' else '0 / 0 (cocina apagada)' end,
         case when (select coalesce(kitchen_enabled, true) from bs)
              then (select count(*) filter (where code = 'cocina') from area_de) = 58
               and (select count(*) filter (where code = 'bar') from area_de) = 578
              else (select count(*) from area_de) = 0 end
  union all
  select 8, 'Inventariables con su insumo',
         (select count(*) from items i
           where i.is_inventory_tracked and i.inventory_item_id is not null)::text,
         '635',
         (select count(*) from items i
           where i.is_inventory_tracked and i.inventory_item_id is not null) = 635
  union all
  select 9, '"Vender aunque esté agotado"',
         (select count(*) from items where allow_negative_sale)::text, '636',
         (select count(*) from items where allow_negative_sale) = 636
  union all
  select 10, 'Insumos de cocina',
         (select count(*) from public.inventory_items ii
           join ins_codigos c on c.codigo = ii.sku
           where ii.business_id = '85924083-2e8e-4e64-8192-808ee24674ed'::uuid)::text, '12',
         (select count(*) from public.inventory_items ii
           join ins_codigos c on c.codigo = ii.sku
           where ii.business_id = '85924083-2e8e-4e64-8192-808ee24674ed'::uuid) = 12
  union all
  select 11, 'Existencia de lo cargado (arranca en 0; baja con ventas)',
         coalesce((select sum(st.quantity)
                     from public.inventory_stock st
                    where st.item_id in (select inventory_item_id from items)
                       or st.item_id in (select ii.id from public.inventory_items ii
                                          join ins_codigos c on c.codigo = ii.sku
                                         where ii.business_id = '85924083-2e8e-4e64-8192-808ee24674ed'::uuid)), 0)::text,
         '0 o menos',
         coalesce((select sum(st.quantity)
                     from public.inventory_stock st
                    where st.item_id in (select inventory_item_id from items)
                       or st.item_id in (select ii.id from public.inventory_items ii
                                          join ins_codigos c on c.codigo = ii.sku
                                         where ii.business_id = '85924083-2e8e-4e64-8192-808ee24674ed'::uuid)), 0) <= 0
  union all
  select 12, 'Modo de inventario',
         (select inventory_mode from bs), 'basic o advanced',
         (select inventory_mode from bs) in ('basic', 'advanced')
  union all
  select 13, 'Con código de barras',
         (select count(*) from items where nullif(btrim(barcode), '') is not null)::text,
         '414 o más',
         (select count(*) from items where nullif(btrim(barcode), '') is not null) >= 414
  union all
  select 14, 'Códigos de barras repetidos (activos, todo el negocio)',
         (select count(*) from (
            select barcode from public.menu_items
            where business_id = '85924083-2e8e-4e64-8192-808ee24674ed'::uuid
              and is_active and nullif(btrim(barcode), '') is not null
            group by barcode having count(*) > 1) z)::text,
         '0',
         (select count(*) from (
            select barcode from public.menu_items
            where business_id = '85924083-2e8e-4e64-8192-808ee24674ed'::uuid
              and is_active and nullif(btrim(barcode), '') is not null
            group by barcode having count(*) > 1) z) = 0
  union all
  select 15, 'ITBIS se cobra en venta rápida',
         coalesce((select case when apply_on_quick then 'sí' else 'NO' end from itbis), '—'),
         'sí',
         coalesce((select apply_on_quick from itbis), false)
  union all
  select 16, 'Impresoras en BAR / COCINA',
         case when not (select coalesce(kitchen_enabled, true) from bs) then 'no aplica'
              else (select count(*) from public.print_area_printers p
                      join public.print_areas a on a.id = p.area_id
                     where a.business_id = '85924083-2e8e-4e64-8192-808ee24674ed'::uuid and a.code = 'bar')
                   || ' / ' ||
                   (select count(*) from public.print_area_printers p
                      join public.print_areas a on a.id = p.area_id
                     where a.business_id = '85924083-2e8e-4e64-8192-808ee24674ed'::uuid and a.code = 'cocina') end,
         '1 o más en cada una',
         not (select coalesce(kitchen_enabled, true) from bs)
         or ((select count(*) from public.print_area_printers p
                join public.print_areas a on a.id = p.area_id
               where a.business_id = '85924083-2e8e-4e64-8192-808ee24674ed'::uuid and a.code = 'bar') > 0
             and (select count(*) from public.print_area_printers p
                    join public.print_areas a on a.id = p.area_id
                   where a.business_id = '85924083-2e8e-4e64-8192-808ee24674ed'::uuid and a.code = 'cocina') > 0)
)
select concepto, encontrado, esperado,
       case when ok then '✓' else '✗ REVISAR' end as estado
from r
order by orden;
