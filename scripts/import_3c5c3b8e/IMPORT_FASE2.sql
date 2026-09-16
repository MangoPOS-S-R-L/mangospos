-- ============================================================================
-- 007 BAR & SNACK, SRL — CARGA DEL CATÁLOGO, FASE 2
-- Business 3c5c3b8e-28e6-45f0-8dc7-85e3efe8d30c
--
-- Fuente: ARTICULO.csv, el maestro de artículos del sistema anterior
-- (15/09/2026, 3,831 artículos). La fase 1 cargó los 828 de
-- "PRODUCTOS 007.pdf", que era solo el tramo de códigos 7622201776664–9002490291709.
--
-- ⚠ ARCHIVO GENERADO por build_fase2_3c5c3b8e.py desde _tpl_import_fase2.sql.
--   No lo edites a mano: cambia el .py (o la plantilla) y regenera.
-- ============================================================================
--
-- QUÉ CARGA
--   1043 productos que faltaban: los que vendieron en los últimos 12 meses o
--   tienen existencia. Quedan fuera los dormidos y los de uso interno.
--   23 categorías; se crean las que falten (Café y batidos, Helados, Souvenirs y regalos).
--   902 con código de barras. Todos llevan el código del maestro en `sku`.
--   Todos inventariables. 669 con existencia inicial: 21753 unidades,
--   RD$1,477,571.36 a costo.
--   Además renumera la POSICIÓN (orden alfabético dentro de la categoría) de los
--   828 productos de la fase 1, para que los nuevos queden intercalados en
--   orden. A esos productos no les toca nada más.
--
-- CÓMO CORRERLO
--   Corre antes 00_diagnostico_fase2.sql. Después pega este archivo entero en el
--   SQL Editor de Supabase y dale Run. La tabla del final es el reporte: todas
--   las filas deben decir ✓.
--
-- TODO O NADA
--   Va en UNA transacción. Comprueba todo antes de escribir y verifica los
--   1043 uno por uno antes del commit. Si algo no cuadra, REVIERTE ENTERO.
--
-- SE PUEDE RE-CORRER
--   Empareja por CÓDIGO (sku o código de barras), no por nombre. Si alguien ya
--   creó a mano uno de estos productos (con ese código), se actualiza: precio,
--   costo, categoría, ITBIS, código de barras y área. Conserva el nombre y no se
--   reactiva si lo apagaron. Su existencia NO se toca si el insumo ya tiene
--   movimientos (ventas, compras, conteos): sale en un aviso.
--   Aborta si un código de esta fase apunta a un producto de la FASE 1.
--
-- DECISIONES DEL DUEÑO (15 y 16/09/2026)
--   * ITBIS 18% INCLUIDO en el precio (tax_mode = 'inclusive') para TODOS, sin Ley.
--     También aguas y yogures, aunque el sistema anterior los tenía al 0% o 16%.
--   * Inventario 1:1 con link directo, también en lo elaborado y en consignación.
--     Existencia = ar_exitem del maestro; los negativos entran en 0.
--     allow_negative_sale = true: nada se esconde en caja por falta de existencia.
--   * Precio = ar_predet. Costo = ar_ultcos (último costo; en null si es 0).
-- ============================================================================

begin;

-- ---------------------------------------------------------------------------
-- 0) Los datos. _p007f2 y _p007f2_pos1 sobreviven al commit (temporales de la
--    sesión) porque el reporte del final las usa; al final se borran.
-- ---------------------------------------------------------------------------

drop table if exists _p007f2;
drop table if exists _p007f2_pos1;

create temp table _p007f2 (
  codigo        text primary key,     -- ar_codigo del maestro, tal cual
  name          text not null,
  categoria     text not null,
  price         numeric(12,2) not null,
  cost          numeric,              -- null si el maestro dice 0
  qty           numeric not null,     -- existencia inicial (negativos → 0)
  qty_listado   numeric not null,     -- ar_exitem tal cual
  barcode       text,                 -- null si el código no es GTIN
  is_bev        boolean not null,
  posicion      int not null
);

-- filas 1–200
insert into _p007f2 (codigo, name, categoria, price, cost, qty, qty_listado, barcode, is_bev, posicion) values
  ('4014086096518', '5.0 ORIGINAL CRAFT BEER 500ML', 'Cervezas', 175.00, 92.0000, 162.00, 162.00, '4014086096518', true, 1),
  ('4014086096365', '5.0 ORIGINAL NEGRA', 'Cervezas', 175.00, 92.0000, 62.00, 62.00, '4014086096365', true, 2),
  ('4014086096303', '5.0 ORIGINAL WEISS LATA 500 ML', 'Cervezas', 175.00, 92.0000, 81.00, 81.00, '4014086096303', true, 3),
  ('4014086096334', '5.0 ORIINAL LAGER BEER 500ML', 'Cervezas', 175.00, 92.0000, 57.00, 57.00, '4014086096334', true, 4),
  ('4014086090370', '9.0 ORIGINAL', 'Cervezas', 225.00, 121.8220, 25.00, 25.00, '4014086090370', true, 5),
  ('08787337', 'BLUE MOON', 'Cervezas', 210.00, 118.5415, 81.00, 81.00, '08787337', true, 11),
  ('74628711', 'BOHEMIA ESPECIAL GRANDE 650ML', 'Cervezas', 185.00, 111.0000, 7.00, 7.00, '74628711', true, 12),
  ('74618903', 'BOHEMIA ESPECIAL PEQUEÑA 355ML', 'Cervezas', 130.00, 82.3788, 0.00, 0.00, '74618903', true, 13),
  ('4260182148990', 'BRUDER HEFEWEIZEN', 'Cervezas', 165.00, 97.8333, 16.00, 16.00, '4260182148990', true, 14),
  ('4260182149003', 'BRUDER LAGER', 'Cervezas', 165.00, 97.8333, 34.00, 34.00, '4260182149003', true, 15),
  ('57089256', 'CARLSBERG PILSNER', 'Cervezas', 165.00, 73.6632, 72.00, 72.00, '57089256', true, 19),
  ('737186598624', 'CER.PONTE EN CUATRO.330.M.L', 'Cervezas', 265.00, 149.0200, 18.00, 18.00, '737186598624', true, 20),
  ('75031589', 'CERVEZA MODELO NEGRA', 'Cervezas', 180.00, 113.0000, 60.00, 60.00, '75031589', true, 23),
  ('08780936', 'COORS GOLDEN BEER', 'Cervezas', 185.00, null, 28.00, 28.00, '08780936', true, 26),
  ('08780538', 'COORS LIGHT 10OZ', 'Cervezas', 100.00, 59.2083, 24.00, 24.00, '08780538', true, 27),
  ('071990320003', 'COORS LIGHT 16 OZ', 'Cervezas', 165.00, 88.1666, 62.00, 62.00, '071990320003', true, 28),
  ('07199044', 'COORS LIGHT BOTELLA 355.ML', 'Cervezas', 175.00, 95.3333, 73.00, 73.00, '07199044', true, 29),
  ('071990300364', 'COORS LIGHT BOTELLA GRANDE', 'Cervezas', 210.00, 123.6000, 65.00, 65.00, '071990300364', true, 30),
  ('7503034941200', 'CORONA 355.M.L.21/8/2026', 'Cervezas', 180.00, 102.4011, 394.00, 394.00, '7503034941200', true, 31),
  ('7503034941217', 'CORONITA 210.ML', 'Cervezas', 120.00, 65.0000, 46.00, 46.00, '7503034941217', true, 32),
  ('3119780264537', 'DESPERADOS MOJITO', 'Cervezas', 200.00, 112.7500, 1.00, 1.00, '3119780264537', true, 33),
  ('3119783007483', 'DESPERADOS ORIGINAL', 'Cervezas', 210.00, 115.2500, 0.00, 0.00, '3119783007483', true, 34),
  ('3119783007513', 'DESPERADOS RED', 'Cervezas', 210.00, 115.2500, 3.00, 3.00, '3119783007513', true, 35),
  ('072311130110', 'DOS EQUIS AMBAR', 'Cervezas', 100.00, null, 0.00, 0.00, '072311130110', true, 36),
  ('5411681014005', 'DUVEL', 'Cervezas', 280.00, 169.4166, 7.00, 7.00, '5411681014005', true, 37),
  ('4002103248286', 'ERDINGER ALKOHOLFREI', 'Cervezas', 200.00, 112.6412, 0.00, 0.00, '4002103248286', true, 38),
  ('4002103294917', 'ERDINGER COMBO WEISSB+DUNKEL+VASO', 'Cervezas', 780.00, 425.0000, 0.00, 0.00, '4002103294917', true, 39),
  ('4002103248262', 'ERDINGER DUNKEL', 'Cervezas', 300.00, 167.3728, 0.00, 0.00, '4002103248262', true, 40),
  ('4002103248323', 'ERDINGER PIKANTUS', 'Cervezas', 360.00, 197.7401, 27.00, 27.00, '4002103248323', true, 41),
  ('4002103248248', 'ERDINGER WEIBBIER', 'Cervezas', 270.00, 165.9604, 17.00, 17.00, '4002103248248', true, 42),
  ('072890006196', 'HEINEKEN PEQ 00 SIN ALCOHOL', 'Cervezas', 185.00, 105.9166, 22.00, 22.00, '072890006196', true, 46),
  ('072890004994', 'HEINEKEN PEQ.', 'Cervezas', 195.00, 109.7916, 88.00, 88.00, '072890004994', true, 47),
  ('5410228146162', 'LEFFE BRUNE BRUIN', 'Cervezas', 180.00, 108.8900, 0.00, -4.00, '5410228146162', true, 52),
  ('5410228142089', 'LEFFE CERVEZA BLONDE', 'Cervezas', 180.00, 108.0000, 5.00, 5.00, '5410228142089', true, 53),
  ('5411681035000', 'MAREDSOUS 6 BLOND BOT 330.M.L', 'Cervezas', 300.00, 176.2083, 15.00, 15.00, '5411681035000', true, 59),
  ('7422110104967', 'MICHELOB ULTRA', 'Cervezas', 140.00, 82.3700, 153.00, 153.00, '7422110104967', true, 60),
  ('01834622', 'MICHELOB ULTRA. LATA .10.OZ', 'Cervezas', 125.00, 75.4795, 1.00, 1.00, '01834622', true, 61),
  ('03456217', 'MILLER 355 P', 'Cervezas', 185.00, 102.4166, 108.00, 108.00, '03456217', true, 62),
  ('034100005696', 'MILLER BOTELLA 22ONZA', 'Cervezas', 250.00, 137.0000, 44.00, 44.00, '034100005696', true, 63),
  ('034100005610', 'MILLER LATA 473.M.L', 'Cervezas', 150.00, 90.7916, 13.00, 13.00, '034100005610', true, 64),
  ('75031602', 'MODELO ESPECIAL PABLO DIER', 'Cervezas', 175.00, 99.7528, 65.00, 65.00, '75031602', true, 65),
  ('74601127', 'ONE CERVEZA GDE. 650ML', 'Cervezas', 190.00, 108.5805, 216.00, 216.00, '74601127', true, 68),
  ('7463172803689', 'ONE CERVEZA LATA 16.OZ', 'Cervezas', 125.00, 72.0300, 11.00, 11.00, '7463172803689', true, 69),
  ('74601325', 'ONE CERVEZA PEQ.', 'Cervezas', 135.00, 75.9180, 533.00, 533.00, '74601325', true, 70),
  ('3110', 'ONE LATA 3X1', 'Cervezas', 110.00, 55.8000, 0.00, -7.00, null, true, 71),
  (' 4014086090370', 'ORIGINAL 9.0', 'Cervezas', 200.00, 121.4600, 19.00, 19.00, null, true, 72),
  ('4101120015106', 'PADERBORNER PILSENER', 'Cervezas', 100.00, 58.0000, 0.00, -16.00, '4101120015106', true, 73),
  ('4066600303336', 'PAULANER DUNKEL', 'Cervezas', 280.00, 169.9152, 5.00, 5.00, '4066600303336', true, 74),
  ('4066600060741', 'PAULANER TRIGO RUBIA', 'Cervezas', 300.00, 169.9152, 20.00, 20.00, '4066600060741', true, 75),
  ('74601561', 'PRESIDENTE LIGHT 650 ML', 'Cervezas', 220.00, 121.8220, 555.00, 555.00, '74601561', true, 76),
  ('7463172803665', 'PRESIDENTE LIGHT LATA 16.OZ', 'Cervezas', 145.00, 85.4500, 40.00, 40.00, '7463172803665', true, 77),
  ('74621774', 'PRESIDENTE LIGHT PEQ.', 'Cervezas', 150.00, 84.0000, 352.00, 352.00, '74621774', true, 78),
  ('74601554', 'PRESIDENTE NORMAL 650ML', 'Cervezas', 220.00, 121.8220, 553.00, 553.00, '74601554', true, 79),
  ('74621767', 'PRESIDENTE NORMAL PEQ.', 'Cervezas', 150.00, 84.7500, 377.00, 377.00, '74621767', true, 80),
  ('7463172803672', 'PRESIDENTE ORIGINAL LATA 16.OZ', 'Cervezas', 145.00, 85.4500, 35.00, 35.00, '7463172803672', true, 81),
  ('75001629', 'SOL CERVEZA', 'Cervezas', 125.00, 60.4110, 0.00, 0.00, '75001629', true, 87),
  ('7501064199141', 'STELLA ARTOIS', 'Cervezas', 195.00, 112.9943, 57.00, 57.00, '7501064199141', true, 88),
  ('080432402665', '1000PIPERS SCOTCH WHISKY', 'Licores', 850.00, 504.5400, 0.00, 0.00, '080432402665', true, 1),
  ('7312040017591', 'ABSOLUT VODKA 375ML', 'Licores', 850.00, 502.1200, 0.00, 0.00, '7312040017591', true, 2),
  ('080480355401', 'BACARDI LIMON 75CL', 'Licores', 440.00, 290.0000, 1.00, 1.00, '080480355401', true, 5),
  ('080480400026', 'BACARDI-ORANGE RUM 75ML', 'Licores', 440.00, 290.0000, 1.00, 1.00, '080480400026', true, 6),
  ('5011013100194', 'BAILEYS THE ORIGINAL 375ML', 'Licores', 990.00, 589.8305, 5.00, 5.00, '5011013100194', true, 7),
  ('5011013100132', 'BAILEYS THE ORIGINAL 750ML', 'Licores', 1850.00, 1072.0000, 6.00, 6.00, '5011013100132', true, 8),
  ('080432001882', 'BALLANTINES AGED 10 YEARS', 'Licores', 1300.00, null, 0.00, 0.00, '080432001882', true, 9),
  ('7461323129237', 'BARCELO AÑEJO 700 ML', 'Licores', 665.00, 403.1100, 1.00, 1.00, '7461323129237', true, 10),
  ('7461323129350', 'BARCELO GRAN AÑEJO 700L', 'Licores', 800.00, 450.0000, 5.00, 5.00, '7461323129350', true, 12),
  ('7461323129336', 'BERCELO ORGANIC', 'Licores', 900.00, 546.5000, 1.00, 1.00, '7461323129336', true, 14),
  ('7460522300478', 'BERMUDEZ GINEBRA 350ML', 'Licores', 525.00, 291.0000, 0.00, 0.00, '7460522300478', true, 15),
  ('7460855233498', 'BRUGAL DOBLE RESERVA', 'Licores', 1310.00, 723.8700, 18.00, 18.00, '7460855233498', true, 18),
  ('7460855238967', 'BRUGAL DOBLE RESERVA.350.M.L', 'Licores', 800.00, 383.0508, 0.00, -1.00, '7460855238967', true, 19),
  ('7460855234990', 'BRUGAL EXTRA VIEJO 700.ML', 'Licores', 985.00, 522.5988, 5.00, 5.00, '7460855234990', true, 20),
  ('7460855234983', 'BRUGAL EXTRA VIEJO PEQ. 350.ML', 'Licores', 550.00, 264.8305, 23.00, 23.00, '7460855234983', true, 21),
  ('7460855208694', 'BRUGAL LEYENDA AZUL .700 ML', 'Licores', 2200.00, 1033.8983, 2.00, 2.00, '7460855208694', true, 22),
  ('7460855237991', 'BRUGAL LEYENDA DORADO', 'Licores', 2450.00, 1313.5593, 4.00, 4.00, '7460855237991', true, 23),
  ('7460855233269', 'BRUGAL LEYENDA NEGRO', 'Licores', 2200.00, 1140.0700, 2.00, 2.00, '7460855233269', true, 24),
  ('7460855238066', 'BRUGAL TRIPLE RESERVA 700.ML', 'Licores', 1460.00, 822.0338, 14.00, 14.00, '7460855238066', true, 25),
  ('7460855235263', 'BRUGAL XV', 'Licores', 560.00, 303.4957, 24.00, 24.00, '7460855235263', true, 26),
  ('7460855235270', 'BRUGAL XV 700.ML', 'Licores', 1075.00, 563.5593, 10.00, 10.00, '7460855235270', true, 27),
  ('5000196003774', 'BUCHANANS MASTER', 'Licores', 4900.00, 2750.0000, 4.00, 4.00, '5000196003774', true, 28),
  ('50196388', 'BUCHANANS WISKY 12 ANOS', 'Licores', 3600.00, 2042.3728, 4.00, 4.00, '50196388', true, 29),
  ('7462324240211', 'CAYMAN BLUE VODKA 700 ML.', 'Licores', 700.00, 467.8010, 3.00, 3.00, '7462324240211', true, 34),
  ('080432400340', 'CHIVAS REGAL 12 AÑOS MINI', 'Licores', 330.00, 175.5000, 6.00, 6.00, '080432400340', true, 35),
  ('080432400395', 'CHIVAS REGAL 12AÑOS', 'Licores', 3500.00, 1833.0000, 4.00, 4.00, '080432400395', true, 36),
  ('5000299225028', 'CHIVAS REGAL 18 AÑOS', 'Licores', 8500.00, 4500.0000, 1.00, 1.00, '5000299225028', true, 37),
  ('080432400388', 'CHIVAS REGAL WHISKY 375ML.', 'Licores', 1650.00, 974.2900, 0.00, 0.00, '080432400388', true, 38),
  ('080480230074', 'DEWARS WHITE LABEL DISPLACE', 'Licores', 190.00, 103.0000, 0.00, 0.00, '080480230074', true, 44),
  ('674545000858', 'DON JULIO TEQUILA REPOSADO 1942', 'Licores', 8500.00, 4500.0000, 3.00, 3.00, '674545000858', true, 45),
  ('088004144708', 'FIREBALL MINI', 'Licores', 225.00, 100.0000, 32.00, 32.00, '088004144708', true, 48),
  ('7467303621524', 'GINEBRA BAYAHIBE', 'Licores', 210.00, 95.0000, 1.00, 1.00, '7467303621524', true, 49),
  ('5010677715003', 'GINEBRA BOMBAY', 'Licores', 3200.00, 1397.0000, 1.00, 1.00, '5010677715003', true, 50),
  ('7460522300461', 'GINEBRA LONDON DRY GIN BERMUDEZ', 'Licores', 1050.00, 560.0000, 0.00, 0.00, '7460522300461', true, 51),
  ('7462324252528', 'GITANO 18 700ML', 'Licores', 225.00, 126.7100, 9.00, 9.00, '7462324252528', true, 52),
  ('5000281003160', 'GRAND OLD PAR 12 ANOS', 'Licores', 3400.00, 1624.3000, 6.00, 6.00, '5000281003160', true, 53),
  ('3245999484319', 'HENNESY.V.S.O.P.', 'Licores', 9300.00, 5000.0000, 3.00, 3.00, '3245999484319', true, 54),
  ('5000267197630', 'JHONNIE WALKER RESERVE NUEVO 750.M.L', 'Licores', 5750.00, 2682.2033, 5.00, 5.00, '5000267197630', true, 57),
  ('5000267096261', 'JOHNNIE NEGRO MINIATURA', 'Licores', 460.00, 274.7100, 12.00, 12.00, '5000267096261', true, 58),
  ('5000267165806', 'JOHNNIE WALKER 18 AÑOS', 'Licores', 13000.00, 5368.6440, 3.00, 3.00, '5000267165806', true, 59),
  ('5000267024608', 'JOHNNIE WALKER BLACK LABE 375', 'Licores', 2100.00, 1143.2203, 1.00, 1.00, '5000267024608', true, 60),
  ('08911108', 'JOHNNIE WALKER BLACK LABEL 50.ML', 'Licores', 550.00, 211.8644, 4.00, 4.00, '08911108', true, 61),
  ('5000267190150', 'JOHNNIE WALKER BLACK LABEL 750ML', 'Licores', 3800.00, 1796.6101, 7.00, 7.00, '5000267190150', true, 62),
  ('5000267116419', 'JOHNNIE WALKER DOUBLE BLACK', 'Licores', 4750.00, 2521.1864, 3.00, 3.00, '5000267116419', true, 63),
  ('5000267014203', 'JOHNNIE WARKER RED 700ML', 'Licores', 1850.00, 867.8000, 6.00, 6.00, '5000267014203', true, 64),
  ('7610594253121', 'KAHLUA LIQUEUR', 'Licores', 910.00, 425.0000, 4.00, 4.00, '7610594253121', true, 65),
  ('7460736905469', 'KING,S PRIDE.KANEL', 'Licores', 240.00, 133.3333, 53.00, 53.00, '7460736905469', true, 66),
  ('7460522300546', 'KINGS LABEL CHATA 350 ML', 'Licores', 420.00, 233.8963, 11.00, 11.00, '7460522300546', true, 67),
  ('7460522300829', 'KINGS LABEL NEGRO LITRO', 'Licores', 1100.00, 607.9700, 3.00, 3.00, '7460522300829', true, 68),
  ('7461592130576', 'LEGADO EL CABALLO MAYOR', 'Licores', 4050.00, 2436.0000, 1.00, 1.00, '7461592130576', true, 72),
  ('7467452220920', 'LICOR AGRICOLA GROG AGUARDIENTE', 'Licores', 125.00, 86.5100, 0.00, -1.00, '7467452220920', true, 73),
  ('7467452220579', 'LICOR AGRICOLA GROG MAMA JUANA', 'Licores', 125.00, 86.0000, 0.00, -2.00, '7467452220579', true, 74),
  ('7460736910029', 'MACK ALBERT 350ML', 'Licores', 490.00, 292.0000, 15.00, 15.00, '7460736910029', true, 75),
  ('7460736950902', 'MACORIX BLANC 750 ML.', 'Licores', 450.00, 259.6685, 2.00, 2.00, '7460736950902', true, 76),
  ('7460736950926', 'MACORIX BLANCO 375 ML', 'Licores', 230.00, 146.6900, 1.00, 1.00, '7460736950926', true, 77),
  ('7460736950919', 'MACORIX GOLD RON DORADO', 'Licores', 445.00, 259.4111, 0.00, 0.00, '7460736950919', true, 78),
  ('7460736902062', 'MACORIX REBEL 350ML', 'Licores', 240.00, 153.8000, 1.00, 1.00, '7460736902062', true, 79),
  ('658325189155', 'MAMAJUANA BACANAL 700.ML', 'Licores', 650.00, 389.6200, 2.00, 2.00, '658325189155', true, 80),
  ('737186232610', 'MAMAJUANA BACANAL.175.ML', 'Licores', 200.00, 114.0000, 0.00, 0.00, '737186232610', true, 81),
  ('7462324240655', 'PONCHE BORDAS PRIMIUM CAFE', 'Licores', 900.00, 531.7800, 0.00, 0.00, '7462324240655', true, 86),
  ('7462324240648', 'PONCHE BORDAS PRIMIUN 700ML', 'Licores', 900.00, 531.7800, 2.00, 2.00, '7462324240648', true, 87),
  ('7467303623481', 'RED RUSSIA VOCKA BLUEBERRY 750ML', 'Licores', 250.00, 166.0000, 1.00, 1.00, '7467303623481', true, 88),
  ('7461592130118', 'RIPIAO ULTRA PREMIUN', 'Licores', 3500.00, 1466.0000, 0.00, 0.00, '7461592130118', true, 89),
  ('7467325360111', 'RON SIBONEY BLANCO 700ML', 'Licores', 490.00, 293.7300, 1.00, 1.00, '7467325360111', true, 91),
  ('7467325360012', 'RON SIBONEY GRAN RESERVA 700ML', 'Licores', 600.00, 363.0700, 1.00, 1.00, '7467325360012', true, 92),
  ('3012993057012', 'SCARLETT DARK 750 ML', 'Licores', 1100.00, 624.4400, 2.00, 2.00, '3012993057012', true, 93),
  ('3012993069800', 'SCARLETT GOLD', 'Licores', 1025.00, 615.9300, 0.00, 0.00, '3012993069800', true, 94),
  ('5000299280140', 'SOMETHING SPECIAL 355 CL', 'Licores', 700.00, 371.9000, 3.00, 3.00, '5000299280140', true, 95),
  ('080432402795', 'SOMETHING SPECIAL SCOTCH WHISKY', 'Licores', 1450.00, 817.9200, 6.00, 6.00, '080432402795', true, 97),
  ('4750021000041', 'STOLI VODKA 375 M.L', 'Licores', 900.00, 529.9600, 0.00, -2.00, '4750021000041', true, 98),
  ('4750021000157', 'STOLICHNAYA VODKA.750 ML.', 'Licores', 1650.00, 790.9604, 13.00, 13.00, '4750021000157', true, 99),
  ('744607010405', 'TEQUILA HERRADURA.50.M.L', 'Licores', 350.00, 196.3300, 0.00, 0.00, '744607010405', true, 100),
  ('619947000068', 'TITO,S HANDMADE VODKA. 50.M.L', 'Licores', 320.00, 167.0197, 1.00, 1.00, '619947000068', true, 101),
  ('619947000051', 'TITO,S,HANDMADE VODKA 375.M.L', 'Licores', 1300.00, 719.3050, 6.00, 6.00, '619947000051', true, 102),
  ('619947000020', 'TITOS HAND MADE VODKA.750.M.L', 'Licores', 2100.00, 1153.3898, 5.00, 5.00, '619947000020', true, 103),
  ('088004146689', 'WHISKY FIREBALL GD', 'Licores', 2200.00, 1129.9434, 3.00, 3.00, '088004146689', true, 105),
  ('7460522300539', 'WHISKY KING''S LABEL 700ML', 'Licores', 800.00, 445.0000, 0.00, 0.00, '7460522300539', true, 106),
  ('012354004290', '19 CRIMENES CALI RED', 'Vinos y espumantes', 2350.00, 1364.9100, 8.00, 8.00, '012354004290', true, 1),
  ('012354005006', '19 CRIMENES CALI ROSE', 'Vinos y espumantes', 1950.00, 1020.3437, 0.00, 0.00, '012354005006', true, 2),
  ('012354001930', '19 CRIMENES THE UPRISING', 'Vinos y espumantes', 1900.00, 1080.5084, 1.00, 1.00, '012354001930', true, 3),
  ('012354000995', '19 CRIMES', 'Vinos y espumantes', 1900.00, 1020.3400, 0.00, 0.00, '012354000995', true, 4),
  ('012354009127', '19 CRIMES RED BLEND', 'Vinos y espumantes', 2350.00, 1364.9100, 11.00, 11.00, '012354009127', true, 5),
  ('012354001688', '19 CRIMES THE BANISSHED 750ML', 'Vinos y espumantes', 1950.00, 1080.5084, 2.00, 2.00, '012354001688', true, 6),
  ('1015', '50 SFUMATURE PASSERINA ESPUMANTE', 'Vinos y espumantes', 950.00, 520.0000, 0.00, 0.00, null, true, 8),
  ('085000001882', 'CARLO ROSSI RED 750ML', 'Vinos y espumantes', 600.00, 315.0000, 1.00, 1.00, '085000001882', true, 12),
  ('085000001875', 'CARLO ROSSI ROSADO', 'Vinos y espumantes', 600.00, 315.0000, 7.00, 7.00, '085000001875', true, 13),
  ('085000029879', 'CARLOS ROSSI DARK', 'Vinos y espumantes', 600.00, 315.0000, 2.00, 2.00, '085000029879', true, 15),
  ('085000022030', 'CARLOS ROSSI FRUITY RED', 'Vinos y espumantes', 600.00, 315.0000, 6.00, 6.00, '085000022030', true, 16),
  ('607054112019', 'CULITOS CABERNET MERLOT', 'Vinos y espumantes', 1100.00, 533.8983, 4.00, 4.00, '607054112019', true, 31),
  ('607054190239', 'CULITOS CABERNET SAUVIGNON 100%', 'Vinos y espumantes', 1100.00, 533.8983, 0.00, -2.00, '607054190239', true, 32),
  ('607054110176', 'CULITOS MERLOT', 'Vinos y espumantes', 1100.00, 533.8983, 4.00, 4.00, '607054110176', true, 33),
  ('607054190277', 'CULITOS SUPERIOR', 'Vinos y espumantes', 1100.00, 533.8983, 3.00, 3.00, '607054190277', true, 34),
  ('742832183314', 'EL JEFE VINO TINTO', 'Vinos y espumantes', 250.00, 150.0000, 1.00, 1.00, '742832183314', true, 39),
  ('1013', 'FORTUNA BLUE EDITION', 'Vinos y espumantes', 950.00, 520.0000, 2.00, 2.00, null, true, 43),
  ('3500610096662', 'JP.CHENET ICE EDITION BLANCO', 'Vinos y espumantes', 500.00, 300.0000, 0.00, 0.00, '3500610096662', true, 62),
  ('3500610096655', 'JP.CHENET ICE EDITION ROSA', 'Vinos y espumantes', 500.00, 300.0000, 1.00, 1.00, '3500610096655', true, 63),
  ('7467303622026', 'LA BENEDICTA-SIDRA 1,050ML', 'Vinos y espumantes', 225.00, null, 0.00, -1.00, '7467303622026', true, 65),
  ('7467303621494', 'LA BENEDICTA-SIDRA 355 ML', 'Vinos y espumantes', 195.00, 95.3389, 163.00, 163.00, '7467303621494', true, 66),
  ('7460736908507', 'MARQUEZ DE SITCHES SAUV-BLANCO 750ML', 'Vinos y espumantes', 150.00, 100.0000, 3.00, 3.00, '7460736908507', true, 70),
  ('664486040020', 'TORREORIA CAVA BRUT', 'Vinos y espumantes', 700.00, 381.2300, 1.00, 1.00, '664486040020', true, 144),
  ('082734416357', 'VINO TENTA SAUVG BLANC', 'Vinos y espumantes', 750.00, 289.5000, 0.00, 0.00, '082734416357', true, 159),
  ('051497322618', 'VINO TINTO 689', 'Vinos y espumantes', 1950.00, 1199.1525, 8.00, 8.00, '051497322618', true, 162),
  ('1210000107602', 'BUZZ BALK BERRY CHERRY LIMEADE', 'Premix y cócteles', 275.00, 160.0000, 0.00, 0.00, '1210000107602', true, 5),
  ('7401000709291', 'KARMA PIÑA COLADA', 'Premix y cócteles', 145.00, 82.0000, 0.00, 0.00, '7401000709291', true, 22),
  ('5904941750404', 'MOJITO JAVAPAY', 'Premix y cócteles', 225.00, 136.0000, 5.00, 5.00, '5904941750404', true, 24),
  ('082000803317', 'SMIRNOFF ICE BLUE RASPBERRY', 'Premix y cócteles', 225.00, 100.6355, 21.00, 21.00, '082000803317', true, 25),
  ('082000727477', 'SMIRNOFF ICE GREEN APPLE', 'Premix y cócteles', 225.00, 100.6355, 119.00, 119.00, '082000727477', true, 26),
  ('082000723844', 'SMIRNOFF ORIGINAL', 'Premix y cócteles', 225.00, 100.6355, 59.00, 59.00, '082000723844', true, 27),
  ('082000789727', 'SMIRNOFF RASPBERRY', 'Premix y cócteles', 225.00, 100.6355, 89.00, 89.00, '082000789727', true, 28),
  ('635985800095', 'WHITE CLAW', 'Premix y cócteles', 190.00, 110.0000, 0.00, -6.00, '635985800095', true, 29),
  ('635985500018', 'WHITE CLAW HARD SELZER BLACK CHERRY', 'Premix y cócteles', 175.00, 102.6700, 7.00, 7.00, '635985500018', true, 30),
  ('7463172803856', '911 ENERGISANTE 16 ONZ', 'Refrescos y energizantes', 65.00, 36.0000, 43.00, 43.00, '7463172803856', true, 2),
  ('7465383000321', 'AGUA TONICA CANADA DRY 20 OZ', 'Refrescos y energizantes', 45.00, 25.0700, 0.00, -1.00, '7465383000321', true, 3),
  ('7462693276002', 'AQUALIT CEREZA 500.M.L', 'Refrescos y energizantes', 150.00, null, 0.00, -1.00, '7462693276002', true, 4),
  ('7462693276026', 'AQUALIT FRUIT PUNCH', 'Refrescos y energizantes', 170.00, 118.2200, 0.00, 0.00, '7462693276026', true, 5),
  ('7462693276019', 'AQUALIT LIMA LIMON', 'Refrescos y energizantes', 150.00, 118.2200, 0.00, 0.00, '7462693276019', true, 6),
  ('07811102', 'CANADA DRY BLACK BERRIES 335.ML', 'Refrescos y energizantes', 65.00, 41.0000, 0.00, -2.00, '07811102', true, 7),
  ('07844508', 'CANADA DRY CHERRY GINGER ALE 355.M.L', 'Refrescos y energizantes', 60.00, 41.0000, 23.00, 23.00, '07844508', true, 8),
  ('7465383000307', 'CANADA DRY CLUB SODA 400 ML.', 'Refrescos y energizantes', 40.00, 22.1750, 190.00, 190.00, '7465383000307', true, 9),
  ('07813401', 'CANADA DRY CRANBERRIES 335.ML', 'Refrescos y energizantes', 70.00, 41.0000, 31.00, 31.00, '07813401', true, 10),
  ('07811403', 'CANADA DRY GINGER ALE LATA', 'Refrescos y energizantes', 70.00, 41.0810, 89.00, 89.00, '07811403', true, 11),
  ('07811801', 'CANADA DRY ZERO SUGAR.355.ML', 'Refrescos y energizantes', 70.00, 41.0000, 0.00, -20.00, '07811801', true, 12),
  ('07846001', 'CANADA-DRY STRAWERRY', 'Refrescos y energizantes', 70.00, 41.3133, 6.00, 6.00, '07846001', true, 13),
  ('07813207', 'CANADADRY CRANBERRY', 'Refrescos y energizantes', 70.00, 41.0000, 0.00, 0.00, '07813207', true, 14),
  ('7465385000343', 'CANADRA DRY AGUA TONICA', 'Refrescos y energizantes', 40.00, 25.0700, 0.00, -6.00, '7465385000343', true, 15),
  ('049000081428', 'COCA COLA 2L', 'Refrescos y energizantes', 110.00, 63.5593, 16.00, 16.00, '049000081428', true, 19),
  ('049000057638', 'COCA COLA 400 ML', 'Refrescos y energizantes', 40.00, 21.1866, 90.00, 90.00, '049000057638', true, 20),
  ('049000071993', 'COCA COLA ZERO 400.M.L', 'Refrescos y energizantes', 40.00, 21.1864, 21.00, 21.00, '049000071993', true, 21),
  ('049000000443', 'COCA COLA20 ONZ', 'Refrescos y energizantes', 60.00, 32.2741, 66.00, 66.00, '049000000443', true, 22),
  ('7467003480339', 'COCO RICO 20 ONZ', 'Refrescos y energizantes', 45.00, 17.3450, 0.00, -2.00, '7467003480339', true, 24),
  ('7463172803818', 'COCO RICO 400. ML', 'Refrescos y energizantes', 45.00, 26.2500, 17.00, 17.00, '7463172803818', true, 25),
  ('049000057676', 'COUNTRY CLUB FRABUESA 400 ML', 'Refrescos y energizantes', 30.00, 17.2316, 87.00, 87.00, '049000057676', true, 26),
  ('7465383000055', 'COUNTRY CLUB FRABUESA DOBLE LITRO', 'Refrescos y energizantes', 110.00, 63.5593, 0.00, 0.00, '7465383000055', true, 27),
  ('7465383000062', 'COUNTRY CLUB MERENGUE 2000 ML.', 'Refrescos y energizantes', 110.00, 63.5593, 0.00, 0.00, '7465383000062', true, 28),
  ('049000057669', 'COUNTRY CLUB MERENGUE 400 ML', 'Refrescos y energizantes', 30.00, 17.2316, 73.00, 73.00, '049000057669', true, 29),
  ('049000547870', 'COUNTRY CLUB PIÑA 400.M.L', 'Refrescos y energizantes', 30.00, 17.2316, 0.00, 0.00, '049000547870', true, 30),
  ('049000057683', 'COUNTRY CLUB UVA 400 ML', 'Refrescos y energizantes', 30.00, 17.2316, 18.00, 18.00, '049000057683', true, 31),
  ('07831504', 'DR PEPPER 23. 355.ML', 'Refrescos y energizantes', 95.00, 56.0000, 0.00, -26.00, '07831504', true, 34),
  ('07895308', 'DR PEPPER C HERRY.355.ML', 'Refrescos y energizantes', 95.00, 52.5000, 27.00, 27.00, '07895308', true, 35),
  ('7463172803733', 'ENRRIQUILLO AGUA TONICA', 'Refrescos y energizantes', 35.00, 20.6700, 0.00, -11.00, '7463172803733', true, 36),
  ('7463172803726', 'ENRRIQUILLO CLUB SODA 400ML', 'Refrescos y energizantes', 40.00, 22.0500, 18.00, 18.00, '7463172803726', true, 37),
  ('7463172802613', 'EXTRATO DE MALTA', 'Refrescos y energizantes', 80.00, 47.0000, 0.00, -22.00, '7463172802613', true, 38),
  ('049000550412', 'FANTA NARANJA 400ML', 'Refrescos y energizantes', 30.00, 17.2316, 83.00, 83.00, '049000550412', true, 39);

-- filas 201–400
insert into _p007f2 (codigo, name, categoria, price, cost, qty, qty_listado, barcode, is_bev, posicion) values
  ('7460548000130', 'GATORADE COOL BLUE 600ML', 'Refrescos y energizantes', 70.00, 36.7000, 38.00, 38.00, '7460548000130', true, 41),
  ('7460548002660', 'GATORADE FRESANDIA.600.M.L', 'Refrescos y energizantes', 70.00, 36.7000, 0.00, -1.00, '7460548002660', true, 42),
  ('7460548000154', 'GATORADE FRUIT PUNCH DC 600.M.L', 'Refrescos y energizantes', 70.00, 36.7000, 57.00, 57.00, '7460548000154', true, 43),
  ('7460548000178', 'GATORADE LEMON LIME 600.M.L', 'Refrescos y energizantes', 70.00, 36.7000, 22.00, 22.00, '7460548000178', true, 44),
  ('7460548000147', 'GATORADE MELON', 'Refrescos y energizantes', 70.00, 36.7000, 9.00, 9.00, '7460548000147', true, 45),
  ('7460548000185', 'GATORADE ORANGE 600ML', 'Refrescos y energizantes', 70.00, 36.7000, 17.00, 17.00, '7460548000185', true, 46),
  ('7460548000161', 'GATORADE UVAS 600ML', 'Refrescos y energizantes', 70.00, 36.7000, 24.00, 24.00, '7460548000161', true, 47),
  ('7460548002134', 'GATORADE ZERO FRUTOS ROJOS 500.ML', 'Refrescos y energizantes', 70.00, 28.8900, 4.00, 4.00, '7460548002134', true, 48),
  ('7460548002127', 'GATORADE ZERO SPORT CAR BERRY BLUE', 'Refrescos y energizantes', 70.00, 28.8900, 0.00, -3.00, '7460548002127', true, 49),
  ('7460548002158', 'GATORLIT COCO 591.M.L', 'Refrescos y energizantes', 120.00, 45.4000, 11.00, 11.00, '7460548002158', true, 50),
  ('7460548002189', 'GATORLIT FRESA KIWI', 'Refrescos y energizantes', 125.00, 45.4000, 20.00, 20.00, '7460548002189', true, 51),
  ('7460548002141', 'GATORLIT MORAS 591.M.L', 'Refrescos y energizantes', 120.00, 45.4000, 13.00, 13.00, '7460548002141', true, 52),
  ('7460548002172', 'GATORLIT NARANJA 591.M.L', 'Refrescos y energizantes', 120.00, 45.4000, 16.00, 16.00, '7460548002172', true, 53),
  ('7460548002165', 'GATORLIT UVA 591.M.L', 'Refrescos y energizantes', 120.00, 45.4000, 17.00, 17.00, '7460548002165', true, 54),
  ('052000047912', 'GATORLYTE FRESA KIWI 591.ML', 'Refrescos y energizantes', 130.00, 71.7100, 0.00, -29.00, '052000047912', true, 55),
  ('052000050820', 'GATORLYTE MIXED BERRY 591.M.L', 'Refrescos y energizantes', 125.00, 71.7100, 0.00, 0.00, '052000050820', true, 56),
  ('052000047905', 'GATORLYTE NARANJA 591ML', 'Refrescos y energizantes', 130.00, 45.4000, 22.00, 22.00, '052000047905', true, 57),
  ('051228637677', 'HATUEY -SODA', 'Refrescos y energizantes', 15.00, 6.1000, 32.00, 32.00, '051228637677', true, 60),
  ('74603640', 'MABI AREITO 355.ML', 'Refrescos y energizantes', 60.00, 36.3700, 0.00, -30.00, '74603640', true, 62),
  ('74601998', 'MALTA INDIA GDE', 'Refrescos y energizantes', 55.00, 32.5900, 0.00, -38.00, '74601998', true, 64),
  ('74601356', 'MALTA INDIA PEQ. 207 ML', 'Refrescos y energizantes', 40.00, 23.2300, 0.00, -21.00, '74601356', true, 65),
  ('74601769', 'MALTA MORENA 8 OZ. PLASTICO', 'Refrescos y energizantes', 40.00, 23.8040, 2.00, 2.00, '74601769', true, 66),
  ('74650309', 'MALTA MORENA MED. 355.ML', 'Refrescos y energizantes', 60.00, 34.0100, 8.00, 8.00, '74650309', true, 67),
  ('070847029106', 'MONSTER ENERGY 16 OZ', 'Refrescos y energizantes', 165.00, 84.7457, 19.00, 19.00, '070847029106', true, 68),
  ('070847893110', 'MONSTER ENERGY JUGO MANGO LOCO 16.OZ', 'Refrescos y energizantes', 220.00, 127.1186, 0.00, 0.00, '070847893110', true, 69),
  ('070847891727', 'MONSTER ENERGY ULTRA CERO AZUCAR', 'Refrescos y energizantes', 150.00, 84.7457, 0.00, -1.00, '070847891727', true, 70),
  ('070847897095', 'MONSTER PIPELINE PUNCH', 'Refrescos y energizantes', 150.00, 84.7500, 0.00, 0.00, '070847897095', true, 71),
  ('7463172803290', 'PEPSI BLAX 400M', 'Refrescos y energizantes', 25.00, 10.3900, 26.00, 26.00, '7463172803290', true, 72),
  ('7463172802750', 'RED ROCK 20 ONZ', 'Refrescos y energizantes', 25.00, 13.8700, 0.00, -3.00, '7463172802750', true, 85),
  ('7463172803467', 'RED ROCK FRAMBUESA 400ML.', 'Refrescos y energizantes', 30.00, 14.8333, 1.00, 1.00, '7463172803467', true, 86),
  ('7468973201160', 'RED ROCK FRAMBUESA DOBLE LITRO', 'Refrescos y energizantes', 100.00, 60.0300, 0.00, 0.00, '7468973201160', true, 87),
  ('7463172803498', 'RED ROCK MANZANA VERDE 400.ML', 'Refrescos y energizantes', 30.00, 14.8333, 48.00, 48.00, '7463172803498', true, 88),
  ('7468973202952', 'RED ROCK MANZANA VERDE 450 ML', 'Refrescos y energizantes', 25.00, 20.8100, 0.00, -2.00, '7468973202952', true, 89),
  ('7468973202761', 'RED ROCK MANZANITA DOBLE LITRO', 'Refrescos y energizantes', 100.00, 60.0300, 0.00, 0.00, '7468973202761', true, 90),
  ('7463172803528', 'RED ROCK MERENGUE 400 ML', 'Refrescos y energizantes', 30.00, 14.8333, 0.00, -11.00, '7463172803528', true, 91),
  ('7468973201184', 'RED ROCK MERENGUE DOBLE LITRO', 'Refrescos y energizantes', 100.00, 60.0300, 1.00, 1.00, '7468973201184', true, 92),
  ('7463172803559', 'RED ROCK NARANJA 400 ML.', 'Refrescos y energizantes', 30.00, 14.8333, 0.00, -38.00, '7463172803559', true, 93),
  ('7468973200293', 'RED ROCK NARANJA DOBLE LITRO', 'Refrescos y energizantes', 100.00, 60.0300, 5.00, 5.00, '7468973200293', true, 94),
  ('7463172803580', 'RED ROCK UVA 400 ML', 'Refrescos y energizantes', 30.00, 14.8333, 41.00, 41.00, '7463172803580', true, 95),
  ('7468973201177', 'RED ROCK UVA DOBLE LITRO', 'Refrescos y energizantes', 100.00, 60.0300, 5.00, 5.00, '7468973201177', true, 96),
  ('7468973203072', 'SEVEN UP DIETA 591 ML', 'Refrescos y energizantes', 35.00, 13.8700, 0.00, -1.00, '7468973203072', true, 98),
  ('7463172803344', 'SEVEN UP DOBLE LITRO', 'Refrescos y energizantes', 110.00, 60.0300, 0.00, 0.00, '7463172803344', true, 99),
  ('7463172803320', 'SEVEN-UP 400 ML.', 'Refrescos y energizantes', 25.00, 12.5706, 17.00, 17.00, '7463172803320', true, 100),
  ('049000057690', 'SPRITE 400.ML', 'Refrescos y energizantes', 30.00, 17.2316, 58.00, 58.00, '049000057690', true, 102),
  ('049000025620', 'SPRITE DOBLE LITRO', 'Refrescos y energizantes', 110.00, 63.5593, 20.00, 20.00, '049000025620', true, 103),
  ('650240063213', 'SUEROX FRESA KIWI', 'Refrescos y energizantes', 225.00, 135.5900, 9.00, 9.00, '650240063213', true, 104),
  ('650240069192', 'SUEROX FRUTOS ROJOS', 'Refrescos y energizantes', 225.00, 135.5900, 3.00, 3.00, '650240069192', true, 105),
  ('650240069208', 'SUEROX LIMA-LIMON', 'Refrescos y energizantes', 225.00, 135.0000, 0.00, 0.00, '650240069208', true, 106),
  ('650240063220', 'SUEROX MANZANA', 'Refrescos y energizantes', 225.00, 135.5900, 4.00, 4.00, '650240063220', true, 107),
  ('650240063244', 'SUEROX MORA AZUL-HIERBABUENA', 'Refrescos y energizantes', 225.00, 135.5900, 9.00, 9.00, '650240063244', true, 108),
  ('650240063237', 'SUEROX NARANJA-MANDARINA', 'Refrescos y energizantes', 225.00, 135.5900, 0.00, 0.00, '650240063237', true, 109),
  ('650240078040', 'SUEROX PIÑA 630.M.L', 'Refrescos y energizantes', 225.00, 135.5900, 7.00, 7.00, '650240078040', true, 110),
  ('650240070495', 'SUEROX SABOR COCO 630.M.L', 'Refrescos y energizantes', 225.00, 135.5900, 0.00, 0.00, '650240070495', true, 111),
  ('650240061325', 'SUEROX UVA', 'Refrescos y energizantes', 225.00, 135.5900, 6.00, 6.00, '650240061325', true, 112),
  ('07827404', 'SUNKIST ORANGE 355.M.L LATA', 'Refrescos y energizantes', 75.00, 42.3725, 0.00, 0.00, '07827404', true, 114),
  ('74642250', 'TIEGERBRAN EXTRATO DE MALTA', 'Refrescos y energizantes', 80.00, 46.3200, 0.00, -21.00, '74642250', true, 116),
  ('041331021951', 'AGUA DE COCO 13.5 CON TROCITOS GOYA', 'Jugos, tés y lácteos', 185.00, 109.2500, 0.00, -2.00, '041331021951', true, 1),
  ('041331027854', 'AGUA DE COCO GOYA 11.8', 'Jugos, tés y lácteos', 120.00, 72.0000, 0.00, -21.00, '041331027854', true, 3),
  ('041331027878', 'AGUA DE COCO GOYA 17.6', 'Jugos, tés y lácteos', 160.00, 95.0000, 41.00, 41.00, '041331027878', true, 4),
  ('076301000155', 'APPLE&EVE FRUIT PUNCH', 'Jugos, tés y lácteos', 25.00, 10.4600, 0.00, -2.00, '076301000155', true, 10),
  ('0000', 'CAPRISUN', 'Jugos, tés y lácteos', 40.00, 22.5625, 5.00, 5.00, null, true, 11),
  ('7460111102377', 'CHOCO RICA 250ML CON SOLVETE', 'Jugos, tés y lácteos', 30.00, 22.2800, 0.00, -6.00, '7460111102377', true, 16),
  ('7460111102483', 'CHOCO RICA 330ML', 'Jugos, tés y lácteos', 55.00, 31.8400, 11.00, 11.00, '7460111102483', true, 17),
  ('7460111103039', 'CHOCO RICA 500.ML', 'Jugos, tés y lácteos', 70.00, 42.5300, 2.00, 2.00, '7460111103039', true, 19),
  ('01484035', 'CLAMATOS', 'Jugos, tés y lácteos', 85.00, 38.3120, 117.00, 117.00, '01484035', true, 21),
  ('031200200006', 'CRAMBERRY OCEAN SPRAY 32 OZ.', 'Jugos, tés y lácteos', 350.00, 147.8100, 0.00, -1.00, '031200200006', true, 23),
  ('025000130311', 'DEL VALLE NARANJA', 'Jugos, tés y lácteos', 25.00, 16.0000, 0.00, -2.00, '025000130311', true, 24),
  ('5904941750459', 'DR+OWOC FRUIT RED 330.ML', 'Jugos, tés y lácteos', 110.00, 67.8000, 0.00, 0.00, '5904941750459', true, 25),
  ('5904941750350', 'DR+OWOC ZIELONE', 'Jugos, tés y lácteos', 100.00, 64.0000, 0.00, 0.00, '5904941750350', true, 26),
  ('024474007372', 'FRUTA FRESCA FRUIT PUNCCH', 'Jugos, tés y lácteos', 35.00, 19.5600, 0.00, -2.00, '024474007372', true, 30),
  ('024474007341', 'FRUTA FRESCA NARANJA', 'Jugos, tés y lácteos', 35.00, null, 0.00, -2.00, '024474007341', true, 31),
  ('070074678436', 'GLUCERNA SHAKE VAINILLA', 'Jugos, tés y lácteos', 200.00, 120.0000, 1.00, 1.00, '070074678436', true, 32),
  ('2018', 'JUGOS NATURAL FRESA', 'Jugos, tés y lácteos', 80.00, 40.0000, 0.00, -2.00, null, true, 39),
  ('2017', 'JUGOS NATURALES VARIADOS', 'Jugos, tés y lácteos', 85.00, 50.0000, 23.00, 23.00, null, true, 40),
  ('7460111102278', 'LISTAMILK RICA 250ML', 'Jugos, tés y lácteos', 35.00, 22.9100, 66.00, 66.00, '7460111102278', true, 44),
  ('7460111102186', 'LISTAMILK RICA LITRO', 'Jugos, tés y lácteos', 120.00, 77.2500, 6.00, 6.00, '7460111102186', true, 45),
  ('025000137341', 'MINUTE MAID CITRUS PUNCH 500 ML.', 'Jugos, tés y lácteos', 35.00, 18.3616, 8.00, 8.00, '025000137341', true, 47),
  ('01489438', 'MOTTS APPLE', 'Jugos, tés y lácteos', 100.00, 57.3800, 31.00, 31.00, '01489438', true, 48),
  ('014800000320', 'MOTTS APPLE JUICE 32 OZ', 'Jugos, tés y lácteos', 280.00, 150.7768, 28.00, 28.00, '014800000320', true, 49),
  ('031200008091', 'OCEAN SPRAY CRANBERRY 450ML', 'Jugos, tés y lácteos', 125.00, 75.5500, 0.00, -1.00, '031200008091', true, 58),
  ('7411204841918', 'PETIT COCTEL DE FRUTAS', 'Jugos, tés y lácteos', 55.00, 29.4300, 1.00, 1.00, '7411204841918', true, 62),
  ('7411204808119', 'PETIT DURASNO', 'Jugos, tés y lácteos', 55.00, 29.0000, 0.00, -21.00, '7411204808119', true, 63),
  ('024474007204', 'PETIT DURAZNOS 330.ML', 'Jugos, tés y lácteos', 40.00, 28.9500, 24.00, 24.00, '024474007204', true, 64),
  ('024474381014', 'PETIT JUGO MANZANA 330 ML', 'Jugos, tés y lácteos', 60.00, 27.8900, 0.00, -1.00, '024474381014', true, 65),
  ('7411204808089', 'PETIT MANZANA DE LATA', 'Jugos, tés y lácteos', 55.00, 29.0000, 5.00, 5.00, '7411204808089', true, 66),
  ('7411204808140', 'PETIT PERAS 330.ML', 'Jugos, tés y lácteos', 55.00, 29.4300, 5.00, 5.00, '7411204808140', true, 67),
  ('7460111102568', 'RICA NARANJA 100/% CON SOLVETE 10ML', 'Jugos, tés y lácteos', 35.00, 18.7200, 103.00, 103.00, '7460111102568', true, 98),
  ('7460111132503', 'RICA RIGURT NATURAL', 'Jugos, tés y lácteos', 60.00, 33.0000, 0.00, 0.00, '7460111132503', true, 128),
  ('7460111132510', 'RICA RIGURTMELOCOTON CHINOLA', 'Jugos, tés y lácteos', 60.00, 33.0000, 0.00, 0.00, '7460111132510', true, 129),
  ('076183003138', 'SNAPPLE FRUIT PUNCH', 'Jugos, tés y lácteos', 125.00, 69.9154, 26.00, 26.00, '076183003138', true, 134),
  ('076183003107', 'SNAPPLE KIWI STRAWBERRY', 'Jugos, tés y lácteos', 125.00, 69.9154, 0.00, -17.00, '076183003107', true, 135),
  ('076183003275', 'SNAPPLE UVA PLASTICO', 'Jugos, tés y lácteos', 110.00, 65.8545, 0.00, -6.00, '076183003275', true, 136),
  ('752046152570', 'SUPLIGEN CHOCOLATE', 'Jugos, tés y lácteos', 165.00, 102.3966, 24.00, 24.00, '752046152570', true, 137),
  ('752046150170', 'SUPLIGEN VAINILLA', 'Jugos, tés y lácteos', 165.00, 102.3966, 19.00, 19.00, '752046150170', true, 138),
  ('7462275402843', 'V8 LIGTH SPLASH FRESA KIWI', 'Jugos, tés y lácteos', 120.00, 71.7100, 2.00, 2.00, '7462275402843', true, 140),
  ('7462275402812', 'V8 SPLASH BERRY BLEND', 'Jugos, tés y lácteos', 120.00, 71.7100, 5.00, 5.00, '7462275402812', true, 141),
  ('7462275402829', 'V8 SPLASH MEZCLA TROPICAL', 'Jugos, tés y lácteos', 120.00, 71.7100, 0.00, -1.00, '7462275402829', true, 142),
  ('7462275402836', 'V8 SPLASH ORANGE CARROT', 'Jugos, tés y lácteos', 120.00, 71.7100, 2.00, 2.00, '7462275402836', true, 143),
  ('016571957438', 'WATERMELON LEMONADE', 'Jugos, tés y lácteos', 140.00, 78.3300, 14.00, 14.00, '016571957438', true, 144),
  ('041800354009', 'WELCHS GRAPE JUICE 10 OZ', 'Jugos, tés y lácteos', 115.00, 66.0310, 20.00, 20.00, '041800354009', true, 145),
  ('7460199565347', 'YOKA YOGURT CIRUELA PASA', 'Jugos, tés y lácteos', 55.00, 28.8700, 0.00, -1.00, '7460199565347', true, 146),
  ('7460199551012', 'YOKA YOGURT CON FRUTAS. FRESA', 'Jugos, tés y lácteos', 70.00, 38.0000, 1.00, 1.00, '7460199551012', true, 147),
  ('7460199552088', 'YOKA YOGURT CON FRUTAS. VAINILLA', 'Jugos, tés y lácteos', 70.00, 38.0000, 2.00, 2.00, '7460199552088', true, 148),
  ('7460199565019', 'YOKA YOGURT FRESA', 'Jugos, tés y lácteos', 55.00, 31.0000, 0.00, -5.00, '7460199565019', true, 149),
  ('7460199565057', 'YOKA YOGURT MORIR SOÑANDO', 'Jugos, tés y lácteos', 55.00, 31.0000, 3.00, 3.00, '7460199565057', true, 150),
  ('7460199565224', 'YOKA YOGURT NATURAL', 'Jugos, tés y lácteos', 55.00, 23.0000, 0.00, -2.00, '7460199565224', true, 151),
  ('7466772506332', 'YOPLAIT CIRUELAS Y CEREALES', 'Jugos, tés y lácteos', 60.00, 33.3000, 16.00, 16.00, '7466772506332', true, 152),
  ('7466772504833', 'YOPLAIT FRUTAS ROJAS', 'Jugos, tés y lácteos', 50.00, 28.0000, 0.00, -3.00, '7466772504833', true, 153),
  ('7466772504840', 'YOPLAIT GOGUR', 'Jugos, tés y lácteos', 60.00, 33.0000, 0.00, -20.00, '7466772504840', true, 154),
  ('7466772508367', 'YOPLAIT TOP FRESA GRANOLA', 'Jugos, tés y lácteos', 100.00, 57.9000, 1.00, 1.00, '7466772508367', true, 155),
  ('7466772508350', 'YOPLAIT TOP NATURAL GRANOLA', 'Jugos, tés y lácteos', 100.00, 57.0000, 0.00, -1.00, '7466772508350', true, 156),
  ('7466772504802', 'YOPLAIT YOGUR NATURAL', 'Jugos, tés y lácteos', 60.00, 33.3000, 2.00, 2.00, '7466772504802', true, 157),
  ('7466772504819', 'YOPLAIT. FRESA. VASO 6OZ', 'Jugos, tés y lácteos', 60.00, 35.0000, 0.00, -7.00, '7466772504819', true, 158),
  ('7466772504185', 'YOPLAY FRESA 8.45OZ', 'Jugos, tés y lácteos', 55.00, 32.2500, 0.00, -2.00, '7466772504185', true, 159),
  ('5777', '1/2 FUNDA DE HIELO', 'Aguas', 40.00, 25.0000, 0.00, -181.00, null, true, 1),
  ('7461063094994', 'AGUA COOL HEAVEN LITRO', 'Aguas', 25.00, 18.3333, 0.00, -2.00, '7461063094994', true, 2),
  ('049000409772', 'AGUA DASANI 20 ONZ', 'Aguas', 35.00, 16.8333, 270.00, 270.00, '049000409772', true, 5),
  ('079298000078', 'AGUA EVIAN 1 LITRO', 'Aguas', 235.00, 157.0000, 41.00, 41.00, '079298000078', true, 6),
  ('701891100014', 'AGUA PLANETA AZUL', 'Aguas', 25.00, null, 497.00, 497.00, '701891100014', true, 10),
  ('701891100038', 'AGUA PLANETA AZUL GD', 'Aguas', 50.00, null, 65.00, 65.00, '701891100038', true, 11),
  ('701891101035', 'AGUA PLANETA SPORT 24.OZ', 'Aguas', 35.00, 18.8300, 7.00, 7.00, '701891101035', true, 12),
  ('049000027822', 'DASANI AGUA 1.5 LITRO', 'Aguas', 60.00, 33.6700, 29.00, 29.00, '049000027822', true, 17),
  ('049000554489', 'DASANI CRANBERRY 591.ML', 'Aguas', 35.00, 19.0000, 1.00, 1.00, '049000554489', true, 18),
  ('049000051636', 'DASANI DE LIMON', 'Aguas', 40.00, 25.4220, 1.00, 1.00, '049000051636', true, 19),
  ('049000051612', 'DASANI DE TORONJA', 'Aguas', 40.00, 25.4220, 12.00, 12.00, '049000051612', true, 20),
  ('061314000032', 'EVIAN AGUA NATURAL', 'Aguas', 170.00, 118.7500, 44.00, 44.00, '061314000032', true, 21),
  ('577', 'HIELO FUNDA', 'Aguas', 80.00, 50.0000, 0.00, -3.00, null, true, 22),
  ('016571953867', 'ICE CAFFEINE BLACK RASPBERRY', 'Aguas', 140.00, 78.3300, 26.00, 26.00, '016571953867', true, 23),
  ('016571953829', 'ICE CAFFEINE TRIPLE CITRUS 16ONZ', 'Aguas', 140.00, 78.3300, 21.00, 21.00, '016571953829', true, 24),
  ('016571952822', 'ICE SPARKING CAFEINE ORANGE PASSIONFRUIT16ONZ', 'Aguas', 140.00, 78.3300, 11.00, 11.00, '016571952822', true, 26),
  ('016571953843', 'ICE SPARKLING CAFFEINE BLUE RASPBERRY 16ONZ', 'Aguas', 140.00, 78.3300, 12.00, 12.00, '016571953843', true, 27),
  ('016571940355', 'ICE SPARKLING CLASSIC LEMONADA', 'Aguas', 125.00, 72.1045, 0.00, -16.00, '016571940355', true, 28),
  ('41508015', 'PERRIER 330ML', 'Aguas', 125.00, 73.7994, 119.00, 119.00, '41508015', true, 31),
  ('07478545', 'PERRIER 750ML', 'Aguas', 285.00, 163.0833, 13.00, 13.00, '07478545', true, 32),
  ('074780000703', 'PERRIER AGUA BOTELLA PLASTICA 500 ML', 'Aguas', 135.00, 81.2100, 0.00, -1.00, '074780000703', true, 33),
  ('701891103015', 'PLANETA TORONJA AZUL', 'Aguas', 25.00, 10.5610, 9.00, 9.00, '701891103015', true, 34),
  ('016571960148', 'SPARKLIN LATA. KIWI STRAWBERRY.7.5.OZ', 'Aguas', 80.00, 46.7000, 0.00, 0.00, '016571960148', true, 40),
  ('016571960926', 'SPARKLIN LATA. MANDARINA.7.5.OZ', 'Aguas', 80.00, 46.7000, 0.00, 0.00, '016571960926', true, 41),
  ('016571960957', 'SPARKLIN LATA. ORANGE CREAM 7.5.OZ', 'Aguas', 80.00, 46.7000, 0.00, 0.00, '016571960957', true, 42),
  ('016571910310', 'SPARKLING ICE', 'Aguas', 125.00, 72.1045, 0.00, -8.00, '016571910310', true, 43),
  ('016571955359', 'SPARKLING ICE BERRY LEMONADE', 'Aguas', 125.00, 72.1045, 1.00, 1.00, '016571955359', true, 44),
  ('016571910303', 'SPARKLING ICE BLACK RASPBERRY', 'Aguas', 125.00, 72.1045, 20.00, 20.00, '016571910303', true, 45),
  ('016571955144', 'SPARKLING ICE CAFFEINE CHERRY VANILLA 16OZ', 'Aguas', 140.00, 78.3300, 11.00, 11.00, '016571955144', true, 46),
  ('016571952839', 'SPARKLING ICE CAFFEINE CITRUS 16 OZ', 'Aguas', 140.00, 78.3300, 0.00, -16.00, '016571952839', true, 47),
  ('016571950842', 'SPARKLING ICE CHERRY LIMEADE', 'Aguas', 125.00, 72.1045, 10.00, 10.00, '016571950842', true, 48),
  ('016571940331', 'SPARKLING ICE COCONUT PINEAPPLE', 'Aguas', 125.00, 72.1045, 3.00, 3.00, '016571940331', true, 49),
  ('016571954369', 'SPARKLING ICE FRUIT PUNCH', 'Aguas', 125.00, 72.1045, 26.00, 26.00, '016571954369', true, 50),
  ('016571952679', 'SPARKLING ICE GRAPE RASPBERRY', 'Aguas', 125.00, 72.1045, 13.00, 13.00, '016571952679', true, 51),
  ('016571910327', 'SPARKLING ICE KIWI STRAWBERRY', 'Aguas', 125.00, 72.1045, 8.00, 8.00, '016571910327', true, 52),
  ('016571911256', 'SPARKLING ICE LEMON LIME', 'Aguas', 125.00, 72.1045, 17.00, 17.00, '016571911256', true, 53),
  ('016571953966', 'SPARKLING ICE PINK GRAPEFRUIT', 'Aguas', 125.00, 72.1045, 12.00, 12.00, '016571953966', true, 54),
  ('016571910372', 'SPARKLING ICE PINK GRAPEFRUIT', 'Aguas', 125.00, 72.1045, 0.00, -1.00, '016571910372', true, 55),
  ('016571950859', 'SPARKLING STRABERRY WATERMELON', 'Aguas', 125.00, 72.1045, 7.00, 7.00, '016571950859', true, 56),
  ('502', 'VASO CON HIELO PQ', 'Aguas', 20.00, 8.0000, 0.00, -1.00, null, true, 57),
  ('1152', 'AROMA CAFE-CORTADITO', 'Café y batidos', 45.00, 25.0000, 34.00, 34.00, null, true, 1),
  ('1151', 'AROMA CAPUC-CHOC-MOKA', 'Café y batidos', 100.00, 50.0000, 42.00, 42.00, null, true, 2),
  ('004', 'CAFE-CAPUC-MOKAC-CHOCOL', 'Café y batidos', 100.00, 50.0000, 0.00, -27.00, null, true, 3),
  ('003', 'CAFE-ESPRESO-LARGO', 'Café y batidos', 45.00, 25.0000, 0.00, -3.00, null, true, 4),
  ('0004', 'CAPUCCINO FRIO', 'Café y batidos', 180.00, 75.0000, 22.00, 22.00, null, true, 5),
  ('04', 'CAPUCHINO VASO GRANDE', 'Café y batidos', 190.00, 95.0000, 40.00, 40.00, null, true, 6),
  ('01241000', 'FRAPPUCCINO VANILLA', 'Café y batidos', 205.00, 130.0000, 0.00, 0.00, '01241000', true, 7),
  ('01264904', 'FRAPUCCINO MOCHA', 'Café y batidos', 220.00, 130.0000, 0.00, 0.00, '01264904', true, 8),
  ('0107', 'FRESA CON FRUTOS DEL BOSQUE', 'Café y batidos', 195.00, 100.0000, 0.00, -4.00, null, true, 9),
  ('0207', 'FRESA CON LECHE', 'Café y batidos', 195.00, 100.0000, 0.00, -15.00, null, true, 10),
  ('0407', 'FRESA MELON', 'Café y batidos', 195.00, 100.0000, 0.00, -15.00, null, true, 11),
  ('0307', 'LECHOZA CON LECHE', 'Café y batidos', 160.00, 85.0000, 0.00, -10.00, null, true, 12),
  ('204', 'NESCAFE.12.OZ. PRO CHOLATE KITKAT', 'Café y batidos', 180.00, 75.0000, 0.00, -46.00, null, true, 13),
  ('1004', 'NESCAFE.7.OZ. PRO CHOLATE KITKAT', 'Café y batidos', 95.00, 55.0000, 0.00, -79.00, null, true, 14),
  ('30004', 'NESCAFE.FRIO. PRO CHOLATE KITKAT', 'Café y batidos', 180.00, 100.0000, 0.00, -18.00, null, true, 15),
  ('1153', 'VASO GRANDE AROMA', 'Café y batidos', 190.00, 95.0000, 203.00, 203.00, null, true, 16),
  ('201', 'VASO PARA NESCAFE', 'Café y batidos', 260.00, 157.7400, 0.00, -2.00, null, true, 17),
  ('7463910335045', 'ALMENDRA CON PASAS SEMILLAS CARMENCITA', 'Snacks salados', 60.00, 45.0000, 0.00, 0.00, '7463910335045', false, 1),
  ('7468841250085', 'ALMENDRA LINEA DORADA PUNTA RUSIA', 'Snacks salados', 540.00, 385.0000, 8.00, 8.00, '7468841250085', false, 2),
  ('7461433140184', 'ALMENDRA NAT DYNASTY', 'Snacks salados', 215.00, 130.0000, 0.00, -1.00, '7461433140184', false, 3),
  ('7468841250559', 'ALMENDRA PUNTA RUCIA 113GR', 'Snacks salados', 245.00, 142.0000, 2.00, 2.00, '7468841250559', false, 4),
  ('7467863736980', 'ALMENDRAS ENTERAS NATURAL', 'Snacks salados', 115.00, 65.0000, 0.00, -1.00, '7467863736980', false, 5),
  ('7461514667081', 'ALMENDRAS NUTRI SEMILLAS', 'Snacks salados', 65.00, 45.0000, 0.00, 0.00, '7461514667081', false, 6),
  ('7468841250344', 'ALMENDRAS PUNTA RUSIA', 'Snacks salados', 70.00, 47.0000, 27.00, 27.00, '7468841250344', false, 7),
  ('7465610154681', 'ALMENDRAS TOSTADAS Y SALADAS 2.OZ.DYNASTY', 'Snacks salados', 130.00, 77.9900, 0.00, 0.00, '7465610154681', false, 8),
  ('3800205875604', 'BRUSCHETTE CHIPS FINE CHEESE', 'Snacks salados', 75.00, 37.8133, 5.00, 5.00, '3800205875604', false, 10),
  ('3800205871255', 'BRUSCHETTE CHIPS PIZZA', 'Snacks salados', 75.00, 37.8133, 0.00, -24.00, '3800205871255', false, 11),
  ('3800205877325', 'BRUSCHETTE CHIPS SOUR CREAM Y ONION', 'Snacks salados', 75.00, 37.8133, 16.00, 16.00, '3800205877325', false, 12),
  ('3800205875109', 'BRUSCHETTE CHIPS TOMATO', 'Snacks salados', 75.00, 37.8133, 15.00, 15.00, '3800205875109', false, 13),
  ('3800205875307', 'BRUSCHETTE CHIPS, VEGETABLES', 'Snacks salados', 75.00, 37.8133, 13.00, 13.00, '3800205875307', false, 14),
  ('7460496803142', 'CARIBAS DE AJO', 'Snacks salados', 145.00, 85.4000, 36.00, 36.00, '7460496803142', false, 19),
  ('7460496801483', 'CARIBAS MADURITOS 110 G', 'Snacks salados', 145.00, 85.4000, 10.00, 10.00, '7460496801483', false, 20),
  ('7460496800905', 'CARIBAS PLATANITOS 52GMS.', 'Snacks salados', 85.00, 49.6500, 12.00, 12.00, '7460496800905', false, 21),
  ('7464113812579', 'CARIBAS YUCA 110G', 'Snacks salados', 145.00, 85.4000, 31.00, 31.00, '7464113812579', false, 22),
  ('7460496805115', 'CARIBAS YUCA Y QUESO ORIGINAL 100.GMOS', 'Snacks salados', 145.00, 85.4000, 0.00, -18.00, '7460496805115', false, 23),
  ('7467035860451', 'CARIBBEAD NUTS ALMENDRAS NATURALES', 'Snacks salados', 240.00, 142.0000, 0.00, -3.00, '7467035860451', false, 24),
  ('7467035860000', 'CARIBBEAD NUTS CASHEWS', 'Snacks salados', 225.00, 118.7000, 1.00, 1.00, '7467035860000', false, 25),
  ('7467035860048', 'CARIBBEAD NUTS NUECES MIXTAS', 'Snacks salados', 200.00, 101.7000, 0.00, 0.00, '7467035860048', false, 26),
  ('7467035860222', 'CARIBBEAD NUTS PISTACHO', 'Snacks salados', 285.00, 161.0000, 1.00, 1.00, '7467035860222', false, 27),
  ('7467035860574', 'CARIBBEAD NUTS SUPER MIX', 'Snacks salados', 200.00, 110.2000, 1.00, 1.00, '7467035860574', false, 28),
  ('7467035860628', 'CARIBBEAD NUTS TRAIL MIX 127.G', 'Snacks salados', 200.00, 110.2000, 1.00, 1.00, '7467035860628', false, 29),
  ('7460590002700', 'CARLES PAPITAS CON LIMON', 'Snacks salados', 80.00, 48.3600, 5.00, 5.00, '7460590002700', false, 30),
  ('7460590002724', 'CARLES PAPITAS CON QUESO', 'Snacks salados', 80.00, 48.3600, 5.00, 5.00, '7460590002724', false, 31),
  ('7460590002717', 'CARLES PAPITAS CON SAL', 'Snacks salados', 80.00, 48.3600, 1.00, 1.00, '7460590002717', false, 32),
  ('7460590002731', 'CARLES PAPITAS CON SOUR CREMA ONION', 'Snacks salados', 80.00, 48.3600, 5.00, 5.00, '7460590002731', false, 33),
  ('7460590001017', 'CARLES PATACONES', 'Snacks salados', 225.00, 104.3000, 0.00, 0.00, '7460590001017', false, 34);

-- filas 401–600
insert into _p007f2 (codigo, name, categoria, price, cost, qty, qty_listado, barcode, is_bev, posicion) values
  ('7461568453227', 'CASABE AL AJILLO 175.PESOS', 'Snacks salados', 225.00, 127.5000, 7.00, 7.00, '7461568453227', false, 35),
  ('7468215707450', 'CASABE APARRILLA AJONJOLI', 'Snacks salados', 310.00, 175.0000, 1.00, 1.00, '7468215707450', false, 36),
  ('7468215707405', 'CASABE APARRILLA NATURAL', 'Snacks salados', 300.00, 160.0000, 4.00, 4.00, '7468215707405', false, 37),
  ('7468215707429', 'CASABE APARRILLA QUESO PARMESANO', 'Snacks salados', 340.00, 195.0000, 4.00, 4.00, '7468215707429', false, 38),
  ('7468215707436', 'CASABE APARRILLA SEMILLAS DE CHIA', 'Snacks salados', 310.00, 175.0000, 2.00, 2.00, '7468215707436', false, 39),
  ('7468215707498', 'CASABE APARRILLA. COCO Y AVENA', 'Snacks salados', 310.00, 175.0000, 1.00, 1.00, '7468215707498', false, 40),
  ('7468215707474', 'CASABE APARRILLA.SEMILLA DE AYUMA', 'Snacks salados', 300.00, 175.0000, 3.00, 3.00, '7468215707474', false, 41),
  ('7469460900047', 'CASABE DE AJO PEQUEÑO', 'Snacks salados', 50.00, 30.0000, 0.00, -2.00, '7469460900047', false, 42),
  ('7468215705012', 'CASABE RELLENO,S GUAYABA', 'Snacks salados', 145.00, 85.0000, 1.00, 1.00, '7468215705012', false, 43),
  ('7501234567893', 'CASABE SANTO DOMINGO', 'Snacks salados', 125.00, 70.0000, 1.00, 1.00, '7501234567893', false, 44),
  ('7468215701021', 'CASABE TRADICIONAL G.', 'Snacks salados', 140.00, 115.0000, 5.00, 5.00, '7468215701021', false, 45),
  ('028400025409', 'CHEETOS CORN JUMBO PUFFS. 9 OZ- 255.G', 'Snacks salados', 350.00, 185.3396, 16.00, 16.00, '028400025409', false, 46),
  ('7460496803326', 'CHEETOS CRUNCHY 85G. P', 'Snacks salados', 85.00, 49.6500, 0.00, -43.00, '7460496803326', false, 47),
  ('7460496803227', 'CHEETOS CRUNCHY QUESO', 'Snacks salados', 145.00, 85.4000, 0.00, -30.00, '7460496803227', false, 48),
  ('7464113802532', 'CHEETOS QUESO BLANCO 85 MGS', 'Snacks salados', 85.00, 49.6500, 49.00, 49.00, '7464113802532', false, 49),
  ('7460496804729', 'CHICHARRON LIMOM', 'Snacks salados', 145.00, 85.4000, 30.00, 30.00, '7460496804729', false, 50),
  ('027800072723', 'CHIPS DELUXES MINI', 'Snacks salados', 55.00, 29.2372, 10.00, 10.00, '027800072723', false, 51),
  ('7465073651185', 'COCALECAS BUTTER DELICIOCHO', 'Snacks salados', 70.00, 30.0000, 6.00, 6.00, '7465073651185', false, 57),
  ('7465073651000', 'COCALECAS CARAMELO DELICIOCHO', 'Snacks salados', 70.00, 30.0000, 0.00, 0.00, '7465073651000', false, 58),
  ('7465073651178', 'COCALECAS WHITE CHEDDAR DELICIOCHO', 'Snacks salados', 70.00, 30.0000, 12.00, 12.00, '7465073651178', false, 59),
  ('7468841252492', 'CRANBERRIES Y SEMILLAS DE CAJUIL 113.GM PUNTA RICI', 'Snacks salados', 245.00, 142.0000, 4.00, 4.00, '7468841252492', false, 60),
  ('7463649219371', 'D ISLA., GRANOLA . PASASY ALMENDRAS REBANADAS', 'Snacks salados', 240.00, 142.3400, 0.00, 0.00, '7463649219371', false, 63),
  ('7463649219364', 'D ISLA., GRANOLA .CHIA ,PASAS Y ALMENDRAS REBANADA', 'Snacks salados', 240.00, 142.3400, 0.00, 0.00, '7463649219364', false, 64),
  ('7461433140221', 'DELUXE NUECES MIXTAS DYNASTY', 'Snacks salados', 290.00, 170.9200, 0.00, -1.00, '7461433140221', false, 65),
  ('7460496804804', 'DORITO NACHOS CHEESE 140 G', 'Snacks salados', 145.00, 85.4000, 5.00, 5.00, '7460496804804', false, 66),
  ('7460496803159', 'DORITOS FLAMIN HOT 130G', 'Snacks salados', 145.00, 85.4000, 21.00, 21.00, '7460496803159', false, 67),
  ('7460496803319', 'DORITOS NACHO CHEESE 70.GMS', 'Snacks salados', 85.00, 49.6500, 19.00, 19.00, '7460496803319', false, 68),
  ('7460496806303', 'DORITOS PIZZA.130.G', 'Snacks salados', 150.00, 85.4000, 9.00, 9.00, '7460496806303', false, 69),
  ('7460496804866', 'DORITOS PM 70', 'Snacks salados', 85.00, 49.6500, 2.00, 2.00, '7460496804866', false, 70),
  ('721282411116', 'DORITOS SWAP 130.GMOS', 'Snacks salados', 145.00, 85.4000, 0.00, 0.00, '721282411116', false, 71),
  ('7468215701502', 'E.GUARAGUANO TRADICIONAL 10.OZ', 'Snacks salados', 190.00, 114.4067, 5.00, 5.00, '7468215701502', false, 72),
  ('7465610154582', 'FRUTAS TROPICALES MIXTAS MWS', 'Snacks salados', 100.00, 58.0000, 4.00, 4.00, '7465610154582', false, 81),
  ('028400017824', 'FUNYUNS ONION 163 G.', 'Snacks salados', 310.00, 185.3400, 4.00, 4.00, '028400017824', false, 83),
  ('7468841252478', 'GRAMBERRIES Y ALMENDRA', 'Snacks salados', 230.77, 142.0000, 8.00, 8.00, '7468841252478', false, 84),
  ('7465610154421', 'GRANOLA CON FRUTAS', 'Snacks salados', 160.00, 94.0000, 0.00, 0.00, '7465610154421', false, 85),
  ('7465610154506', 'GRANOLA CON FRUTAS 2.OZ.DYNASTY', 'Snacks salados', 80.00, 47.9900, 0.00, -1.00, '7465610154506', false, 86),
  ('7468215701311', 'GUARAGUANO K-SABITOS COCONUT', 'Snacks salados', 160.00, 105.0000, 0.00, 0.00, '7468215701311', false, 87),
  ('7460496803289', 'HOJUELITAS BBQ 160 G', 'Snacks salados', 145.00, 85.4000, 36.00, 36.00, '7460496803289', false, 90),
  ('7460496803272', 'HOJUELITAS DE QUESO 160 G', 'Snacks salados', 145.00, 85.4000, 32.00, 32.00, '7460496803272', false, 91),
  ('709972311236', 'HOT PEPPERONI', 'Snacks salados', 100.00, 70.8400, 0.00, -2.00, '709972311236', false, 92),
  ('017082880635', 'JACK LINKS HOT & SPICY', 'Snacks salados', 165.00, 98.5000, 46.00, 46.00, '017082880635', false, 93),
  ('017082460714', 'JL TENDER TERYAKI BEEF STEAK', 'Snacks salados', 240.00, 73.0208, 0.00, -4.00, '017082460714', false, 94),
  ('017082880628', 'JL TERIYAKI', 'Snacks salados', 140.00, 73.0200, 0.00, -6.00, '017082880628', false, 95),
  ('7468215700109', 'K-SABITOS AL AJILLO', 'Snacks salados', 35.00, 22.5000, 25.00, 25.00, '7468215700109', false, 96),
  ('7460496806167', 'LAYS ASADO ARGENTINO', 'Snacks salados', 150.00, 85.4000, 17.00, 17.00, '7460496806167', false, 99),
  ('028400016544', 'LAYS DORITOS NACHO 255G', 'Snacks salados', 235.00, 145.6500, 9.00, 9.00, '028400016544', false, 100),
  ('7460496803258', 'LAYS LIMON 110G', 'Snacks salados', 145.00, 85.4000, 27.00, 27.00, '7460496803258', false, 101),
  ('7460496803364', 'LAYS LIMON 55G', 'Snacks salados', 85.00, 49.6500, 40.00, 40.00, '7460496803364', false, 102),
  ('7460496803845', 'LAYS PAPITA QUESO BLANCO 200G', 'Snacks salados', 245.00, 145.6086, 2.00, 2.00, '7460496803845', false, 103),
  ('7460496803357', 'LAYS PAPITA QUESO BLANCO 55G', 'Snacks salados', 85.00, 49.6500, 28.00, 28.00, '7460496803357', false, 104),
  ('7460496803340', 'LAYS PAPITA SAL 55.GMOS', 'Snacks salados', 85.00, 49.6500, 63.00, 63.00, '7460496803340', false, 105),
  ('7460496803838', 'LAYS PAPITA SAL X.L.200.G', 'Snacks salados', 250.00, 145.6500, 1.00, 1.00, '7460496803838', false, 106),
  ('7464113821403', 'LAYS PLATANITOS CARIBAS 160G', 'Snacks salados', 150.00, 99.3100, 0.00, -1.00, '7464113821403', false, 107),
  ('7460496803241', 'LAYS QUESO BLANCO 110G', 'Snacks salados', 145.00, 85.4000, 24.00, 24.00, '7460496803241', false, 108),
  ('7460496803371', 'LAYS RUFFLES QUESO55GMOS', 'Snacks salados', 85.00, 49.6500, 33.00, 33.00, '7460496803371', false, 109),
  ('7460496803234', 'LAYS SAL 110 G', 'Snacks salados', 145.00, 85.4000, 37.00, 37.00, '7460496803234', false, 110),
  ('7460496804675', 'LAYS SOUR CREAM', 'Snacks salados', 145.00, 85.4000, 0.00, 0.00, '7460496804675', false, 111),
  ('721282411079', 'LAYS SWAP 105.GMOS', 'Snacks salados', 145.00, 85.4000, 2.00, 2.00, '721282411079', false, 112),
  ('7460496806228', 'LAYS TACO MEXICANO', 'Snacks salados', 150.00, 85.4000, 2.00, 2.00, '7460496806228', false, 113),
  ('7467863736928', 'MANI CON PASAS 2.OZ.DYNASTY', 'Snacks salados', 65.00, 38.0000, 0.00, 0.00, '7467863736928', false, 116),
  ('750894671014', 'MANI CON SAL YUMMI NUTS 80.G', 'Snacks salados', 50.00, 24.7100, 3.00, 3.00, '750894671014', false, 117),
  ('7465610154438', 'MANI TOSTADO SALDO', 'Snacks salados', 120.00, 71.0000, 1.00, 1.00, '7465610154438', false, 119),
  ('7465610154513', 'MANI TOSTADO Y SALADO 2.OZ.DYNASTY', 'Snacks salados', 56.00, 33.7500, 5.00, 5.00, '7465610154513', false, 120),
  ('7465610154445', 'MANI TOSTADOS CON PASAS DYNASTY', 'Snacks salados', 120.00, 69.0000, 0.00, -1.00, '7465610154445', false, 121),
  ('3800237480579', 'MARETTI CHEDDAR Y SOUR CREAM', 'Snacks salados', 75.00, 37.8133, 13.00, 13.00, '3800237480579', false, 122),
  ('7464113826606', 'MOFONGO SNAX 52 G.', 'Snacks salados', 85.00, 49.6500, 32.00, 32.00, '7464113826606', false, 126),
  ('028400735827', 'NATU CHIPS CHILE Y LIMON 113.9.G', 'Snacks salados', 145.00, 85.4000, 11.00, 11.00, '028400735827', false, 127),
  ('7460496805986', 'NATUCHIPS LIME LIMON 110.GMS', 'Snacks salados', 145.00, 85.4000, 33.00, 33.00, '7460496805986', false, 128),
  ('7464113821205', 'NATUCHIPS PLATANITOS CARIBAS 110G', 'Snacks salados', 145.00, 85.4000, 54.00, 54.00, '7464113821205', false, 129),
  ('7460995101152', 'NUECES MIXTAS CON MANI', 'Snacks salados', 115.00, 67.0000, 1.00, 1.00, '7460995101152', false, 130),
  ('7467863739905', 'NUECES Y FRUTAS MIXTAS MWS', 'Snacks salados', 80.00, 45.0000, 2.00, 2.00, '7467863739905', false, 131),
  ('7467035860024', 'NUT SACK MIX Y O PISTACHE', 'Snacks salados', 260.00, 120.0000, 0.00, -25.00, '7467035860024', false, 132),
  ('6975478926234', 'PAPITAS MILAMAR ORIGUINAL 90.G', 'Snacks salados', 115.00, 65.8300, 11.00, 11.00, '6975478926234', false, 138),
  ('6975478926241', 'PAPITAS MILAMAR QUESO .90.G', 'Snacks salados', 115.00, 65.8300, 13.00, 13.00, '6975478926241', false, 139),
  ('6928982869122', 'PEANUT MANI 185G', 'Snacks salados', 95.00, 56.5000, 0.00, -1.00, '6928982869122', false, 141),
  ('7468841250542', 'PISTACHO PUNTA RUCIA', 'Snacks salados', 70.00, 47.0000, 4.00, 4.00, '7468841250542', false, 142),
  ('7468841250535', 'PISTACHO PUNTA RUSIA', 'Snacks salados', 245.00, 142.0000, 8.00, 8.00, '7468841250535', false, 143),
  ('7467863736706', 'PISTACHOS 2.OZ.DYNASTY', 'Snacks salados', 125.00, 74.0000, 1.00, 1.00, '7467863736706', false, 144),
  ('7461433140214', 'PISTACHOS TOSTADOS SALADOS DYNASTY', 'Snacks salados', 245.00, 148.0000, 0.00, -1.00, '7461433140214', false, 145),
  ('029000017955', 'PLANTERS SALTED CASHEWS SOBRE', 'Snacks salados', 60.00, 32.3000, 0.00, -3.00, '029000017955', false, 146),
  ('029000017931', 'PLANTERS SALTED PEANUTS', 'Snacks salados', 60.00, 32.3000, 2.00, 2.00, '029000017931', false, 147),
  ('029000076822', 'PLANTERS SALTED PEANUTS 28G.', 'Snacks salados', 25.00, 14.5656, 35.00, 35.00, '029000076822', false, 148),
  ('029000017948', 'PLANTERS SALTED PEANUTS SOBRE', 'Snacks salados', 60.00, 32.3000, 2.00, 2.00, '029000017948', false, 149),
  ('038000185069', 'PRINGLES BARBACOA GDE', 'Snacks salados', 190.00, 130.3500, 12.00, 12.00, '038000185069', false, 160),
  ('038000183737', 'PRINGLES BBQ PEQ.', 'Snacks salados', 75.00, 42.0800, 2.00, 2.00, '038000183737', false, 161),
  ('038000846731', 'PRINGLES ORIGINAL 37G.', 'Snacks salados', 80.00, 42.0800, 27.00, 27.00, '038000846731', false, 162),
  ('038000184932', 'PRINGLES ORIGINAL GDE', 'Snacks salados', 200.00, 127.1200, 21.00, 21.00, '038000184932', false, 163),
  ('038000846748', 'PRINGLES PAPITA CREMA Y CEBOLLA', 'Snacks salados', 80.00, 42.0800, 20.00, 20.00, '038000846748', false, 164),
  ('038000846755', 'PRINGLES QUESO 37.G', 'Snacks salados', 80.00, 42.0800, 29.00, 29.00, '038000846755', false, 165),
  ('038000184956', 'PRINGLES QUESO GRANDE', 'Snacks salados', 225.00, 127.1200, 19.00, 19.00, '038000184956', false, 166),
  ('038000184949', 'PRINGLES SOUR CREAM & ONION', 'Snacks salados', 225.00, 127.1200, 22.00, 22.00, '038000184949', false, 167),
  ('7468841250887', 'PUNTA RICIA CAJUIL CON PASAS', 'Snacks salados', 485.00, 345.0000, 4.00, 4.00, '7468841250887', false, 168),
  ('7468841250931', 'PUNTA RUCIA CRABERRIES ALMENDRA 230G.', 'Snacks salados', 485.00, 345.0000, 3.00, 3.00, '7468841250931', false, 169),
  ('7468841250955', 'PUNTA RUCIA CRANBERRIES ALMENDRA CAJUIL', 'Snacks salados', 485.00, 345.0000, 0.00, -1.00, '7468841250955', false, 170),
  ('7468841250962', 'PUNTA RUCIA CRANBERRIES CON CAJUIL', 'Snacks salados', 485.00, 345.0000, 2.00, 2.00, '7468841250962', false, 171),
  ('00523', 'PUNTA RUCIA CRANE-ALM-SC-135.GR', 'Snacks salados', 235.00, 142.0000, 12.00, 12.00, null, false, 172),
  ('7468841250948', 'PUNTA RUCIA DRIED CRANBERRIES 230.G', 'Snacks salados', 485.00, 345.0000, 9.00, 9.00, '7468841250948', false, 173),
  ('7468841250795', 'PUNTA RUCIA PISTACHOS LINEA DORADO', 'Snacks salados', 482.89, 370.0000, 3.00, 3.00, '7468841250795', false, 174),
  ('7468841250863', 'PUNTA RUCIA SEMILLA CAJUIL SIN SAL', 'Snacks salados', 575.00, 345.0000, 4.00, 4.00, '7468841250863', false, 175),
  ('7468841250870', 'PUNTA RUCIA SEMILLAS CAJUIL CON SAL 230G', 'Snacks salados', 672.60, 345.0000, 1.00, 1.00, '7468841250870', false, 176),
  ('7468841250580', 'PUNTA RUCIA SEMILLAS DE CAJUIL CON PASA', 'Snacks salados', 245.00, 142.0000, 0.00, 0.00, '7468841250580', false, 177),
  ('7468841250382', 'PUNTA RUCIA SEMILLAS DE CAJUIL/PASAS', 'Snacks salados', 70.00, 47.0000, 21.00, 21.00, '7468841250382', false, 178),
  ('7468841250313', 'PUNTA RUCIA SUPER MIX', 'Snacks salados', 70.00, 47.0000, 26.00, 26.00, '7468841250313', false, 179),
  ('7468841250078', 'PUNTA RUCIA SUPER MIX 230G.', 'Snacks salados', 485.00, 345.0000, 3.00, 3.00, '7468841250078', false, 180),
  ('7468841250306', 'PUNTA RUSIA SEMILLAS DE CAJUIL CON SAL', 'Snacks salados', 70.00, 47.0000, 89.00, 89.00, '7468841250306', false, 181),
  ('462878688583', 'ROQUETE AMERIKA', 'Snacks salados', 90.00, 50.0000, 21.00, 21.00, '462878688583', false, 183),
  ('707273605757', 'ROQUETE DE AJO', 'Snacks salados', 100.00, 65.0000, 0.00, -1.00, '707273605757', false, 184),
  ('7460496803524', 'RUFFES QUESO 200G', 'Snacks salados', 200.00, 119.1700, 0.00, -1.00, '7460496803524', false, 185),
  ('7460496805559', 'RUFFLES CARNE ASADA 120.G', 'Snacks salados', 145.00, 85.4000, 16.00, 16.00, '7460496805559', false, 186),
  ('7460496803265', 'RUFFLES QUESO 120G', 'Snacks salados', 145.00, 85.4000, 20.00, 20.00, '7460496803265', false, 187),
  ('7468841250122', 'SEMILLA CAJUIL PUNTA RUCIA SIN SAL', 'Snacks salados', 245.00, 142.0000, 2.00, 2.00, '7468841250122', false, 188),
  ('7468841250351', 'SEMILLA DE CAJUIL CON SAL PUNTA RUCIA', 'Snacks salados', 245.00, 142.0000, 0.00, 0.00, '7468841250351', false, 189),
  ('7468841250269', 'SEMILLA DE CAJUIL PUNTA RUCIA', 'Snacks salados', 70.00, 47.0000, 30.00, 30.00, '7468841250269', false, 190),
  ('7461433140177', 'SEMILLA DE MARAÑON NAT. DYNASTY', 'Snacks salados', 235.00, 141.0000, 0.00, 0.00, '7461433140177', false, 191),
  ('7467863739936', 'SEMILLA DE MARAÑON NATURAL', 'Snacks salados', 125.00, 75.0000, 0.00, 0.00, '7467863739936', false, 192),
  ('7467863736966', 'SEMILLAS DE MARAÑON NATURAL 2.OZ.DYNASTY', 'Snacks salados', 125.00, 73.9900, 1.00, 1.00, '7467863736966', false, 193),
  ('7461433140160', 'SEMILLAS DE MARAÑON TOSTADAS SALADAS DYNASTY', 'Snacks salados', 275.00, 163.0000, 0.00, -1.00, '7461433140160', false, 194),
  ('7467863737017', 'SEMILLAS DE MARAÑON TOSTADO 2.OZ.DYNASTY', 'Snacks salados', 150.00, 88.0000, 0.00, 0.00, '7467863737017', false, 195),
  ('7465793910456', 'SEÑOR NACHO SABOR A MEXICO', 'Snacks salados', 130.00, 74.7100, 4.00, 4.00, '7465793910456', false, 196),
  ('7468841250467', 'SUPER MIX PUNTA RUCIA', 'Snacks salados', 245.00, 142.0000, 5.00, 5.00, '7468841250467', false, 198),
  ('757528048075', 'TAKIS DE FUEGO 92.3G', 'Snacks salados', 280.00, 170.0000, 0.00, 0.00, '757528048075', false, 200),
  ('757528005047', 'TAKIS FUEGO PEQ.', 'Snacks salados', 70.00, 30.5821, 11.00, 11.00, '757528005047', false, 201),
  ('750894609505', 'TAQUERITOS CHILE TOREADO 180 G', 'Snacks salados', 160.00, 91.6300, 24.00, 24.00, '750894609505', false, 202),
  ('750894609499', 'TAQUERITOS QUESO FUSION', 'Snacks salados', 160.00, 91.6300, 4.00, 4.00, '750894609499', false, 203),
  ('028400055970', 'TOSTITOS CHUNKI SALSA MILD', 'Snacks salados', 310.00, 185.3800, 24.00, 24.00, '028400055970', false, 204),
  ('028400070980', 'TOSTITOS SALSA CON QUESO MEDIUM', 'Snacks salados', 325.00, 182.5300, 25.00, 25.00, '028400070980', false, 205),
  ('7460496805320', 'TOSTITOS SANTA ELENA', 'Snacks salados', 280.00, 165.5200, 12.00, 12.00, '7460496805320', false, 206),
  ('634129271074', 'TOSTONES CON AJO LAMS', 'Snacks salados', 245.00, 140.6800, 1.00, 1.00, '634129271074', false, 210),
  ('634129271067', 'TOSTONES CON LIMON LAMS', 'Snacks salados', 235.00, 140.6800, 0.00, 0.00, '634129271067', false, 211),
  ('634129271081', 'TOSTONES LAMS DULCE PICANTES', 'Snacks salados', 245.00, 140.6800, 0.00, 0.00, '634129271081', false, 212),
  ('634129271050', 'TOSTONES MADUROS LAMS', 'Snacks salados', 235.00, 140.6800, 1.00, 1.00, '634129271050', false, 214),
  ('634129271043', 'TOSTONES REGULAR LAMS', 'Snacks salados', 245.00, 140.6800, 5.00, 5.00, '634129271043', false, 215),
  ('750894671427', 'YUMMI NUTS MANI CON LIMON', 'Snacks salados', 20.00, 8.0000, 48.00, 48.00, '750894671427', false, 219),
  ('750894671007', 'YUMMI NUTS MANI CON LIMON 80.G', 'Snacks salados', 50.00, 24.7100, 3.00, 3.00, '750894671007', false, 220),
  ('750894671199', 'YUMMI NUTS MANI CON SAL', 'Snacks salados', 20.00, 8.0000, 0.00, -2.00, '750894671199', false, 221),
  ('750894671410', 'YUMMI NUTS MANI CON SAL', 'Snacks salados', 25.00, 8.0000, 1.00, 1.00, '750894671410', false, 222),
  ('750894671434', 'YUMMI NUTS MIX', 'Snacks salados', 25.00, 13.0000, 37.00, 37.00, '750894671434', false, 223),
  ('750894610822', 'ZAMBOS CEVICHE', 'Snacks salados', 165.00, 98.9600, 0.00, 0.00, '750894610822', false, 224),
  ('750894607181', 'ZAMBOS MADURITOS', 'Snacks salados', 195.00, 117.2900, 3.00, 3.00, '750894607181', false, 225),
  ('750894600267', 'ZAMBOS PICOSITAS FAMILIAR', 'Snacks salados', 165.00, 98.9600, 7.00, 7.00, '750894600267', false, 226),
  ('750894602780', 'ZAMBOS PLATANOS ONDULADOS', 'Snacks salados', 185.00, 107.3300, 7.00, 7.00, '750894602780', false, 227),
  ('750894600717', 'ZAMBOS SALSA VERDE', 'Snacks salados', 180.00, 98.9600, 0.00, 0.00, '750894600717', false, 228),
  ('750894611973', 'ZAMBOS YUQUITAS ORIGINALES', 'Snacks salados', 140.00, 93.0000, 0.00, -1.00, '750894611973', false, 229),
  ('1204', '.PASTRY COOKIE GUAYABA Y CHOCOLATE BLANCO', 'Galletas y bizcochos', 210.00, 125.0000, 0.00, 0.00, null, false, 1),
  ('7462878688705', 'ALFAJONES MINI PRODUCTOS AMERIKA', 'Galletas y bizcochos', 200.00, 140.0000, 5.00, 5.00, '7462878688705', false, 3),
  ('7462878688392', 'AMERIKA GALLETA AL AJO', 'Galletas y bizcochos', 15.00, 8.0000, 0.00, -1.00, '7462878688392', false, 4),
  ('7462878688354', 'AMERIKA GALLETA INTEGRAL CLASICA', 'Galletas y bizcochos', 40.00, null, 0.00, -1.00, '7462878688354', false, 5),
  ('7462878688347', 'AMERIKA GALLETAS DE AJO', 'Galletas y bizcochos', 40.00, 23.0000, 0.00, -1.00, '7462878688347', false, 6),
  ('7462810126036', 'BAN BAN GALLETA DE AJO PEQ.', 'Galletas y bizcochos', 15.00, 4.0000, 0.00, -1.00, '7462810126036', false, 15),
  ('41', 'BIZCOCHO', 'Galletas y bizcochos', 40.00, 18.0000, 0.00, 0.00, null, false, 17),
  ('675', 'BROWNIE DEL ENCANTO', 'Galletas y bizcochos', 160.00, 85.0000, 0.00, 0.00, null, false, 24),
  ('578', 'BROWNIE ROSE', 'Galletas y bizcochos', 110.00, 65.0000, 0.00, -6.00, null, false, 25),
  ('653981779009', 'BROWNIES RICURITAS', 'Galletas y bizcochos', 80.00, 40.0000, 2.00, 2.00, '653981779009', false, 26),
  ('576', 'CHEESECAKE BROWNIE ROSE', 'Galletas y bizcochos', 145.00, 86.0000, 0.00, -5.00, null, false, 29),
  ('721282410102', 'CHOKIS CHOCOBASE 73,5', 'Galletas y bizcochos', 70.00, 42.0400, 109.00, 109.00, '721282410102', false, 34),
  ('7622201717544', 'CLUB SOCIAL GALLETA', 'Galletas y bizcochos', 15.00, 8.0000, 0.00, -58.00, '7622201717544', false, 35),
  ('7622201720032', 'CLUB SOCIAL INTEGRAL', 'Galletas y bizcochos', 15.00, 8.0000, 0.00, -83.00, '7622201720032', false, 36),
  ('7622201717537', 'CLUB SOCIAL ORIGINAL PAQUETES', 'Galletas y bizcochos', 180.00, 110.0000, 1.00, 1.00, '7622201717537', false, 37),
  ('7462878688668', 'COQUITOS AMERIKA', 'Galletas y bizcochos', 190.00, 110.0000, 2.00, 2.00, '7462878688668', false, 43),
  ('7468235130368', 'COQUITOS MOLINOS DEL SOL', 'Galletas y bizcochos', 125.00, 87.1300, 0.00, -1.00, '7468235130368', false, 44),
  ('7500478027118', 'CRACKETS MINI SANDWICH', 'Galletas y bizcochos', 60.00, 35.0000, 12.00, 12.00, '7500478027118', false, 45),
  ('653981779016', 'CUADRITOS DE LIMON RICURITAS', 'Galletas y bizcochos', 80.00, 40.0000, 9.00, 9.00, '653981779016', false, 53),
  ('721282406167', 'DELICIAS CLASICAS', 'Galletas y bizcochos', 70.00, 42.0200, 0.00, -9.00, '721282406167', false, 57),
  ('7501000635245', 'DELICIAS DE MANTEQUILLA', 'Galletas y bizcochos', 40.00, 24.5300, 0.00, -1.00, '7501000635245', false, 58),
  ('753079000418', 'DINO CHOCOLATE', 'Galletas y bizcochos', 20.00, 9.2475, 21.00, 21.00, '753079000418', false, 59),
  ('753079000425', 'DINO CHOCOLATE PAQUETE 12.UNID', 'Galletas y bizcochos', 225.00, 120.0000, 1.00, 1.00, '753079000425', false, 60),
  ('753079000456', 'DINO DE FRESA', 'Galletas y bizcochos', 20.00, 9.2475, 9.00, 9.00, '753079000456', false, 61),
  ('753079000470', 'DINO DE VANILLA', 'Galletas y bizcochos', 20.00, 9.2475, 2.00, 2.00, '753079000470', false, 62),
  ('753079000432', 'DINO DUPLEX', 'Galletas y bizcochos', 20.00, 9.2475, 25.00, 25.00, '753079000432', false, 63),
  ('753079000449', 'DINO DUPLEX PAQUETE 12.UNID', 'Galletas y bizcochos', 225.00, 120.0000, 2.00, 2.00, '753079000449', false, 64),
  ('753079000463', 'DINO FRESA PAQUETE 12.UNID', 'Galletas y bizcochos', 225.00, 120.0000, 1.00, 1.00, '753079000463', false, 65),
  ('653981779030', 'EMPANADAS DE GUAYABA RICURITAS', 'Galletas y bizcochos', 60.00, 35.0000, 5.00, 5.00, '653981779030', false, 67),
  ('7500478013609', 'EMPERADOR CHOCOLATE', 'Galletas y bizcochos', 60.00, 35.0000, 25.00, 25.00, '7500478013609', false, 68),
  ('076677100145', 'FAMOUS AMOS CHOCOLATE CHIP', 'Galletas y bizcochos', 45.00, 30.5700, 0.00, 0.00, '076677100145', false, 69),
  ('7462878688125', 'GALLETA DE AJO LA PALZA PEQ.', 'Galletas y bizcochos', 100.00, 42.0000, 0.00, 0.00, '7462878688125', false, 74),
  ('7462624380143', 'GALLETA INTEGRAL PANADERIA CIBAO', 'Galletas y bizcochos', 75.00, 45.0000, 0.00, -2.00, '7462624380143', false, 76),
  ('7460602200032', 'GALLETA MOCANA INTEGRAL', 'Galletas y bizcochos', 25.00, 8.5000, 0.00, -57.00, '7460602200032', false, 77),
  ('7462624380136', 'GALLETAS CLASICAS PANADERIA CIBAO', 'Galletas y bizcochos', 60.00, 40.0000, 0.00, -2.00, '7462624380136', false, 79),
  ('7460602200094', 'GALLETAS CON AJO MOCANA', 'Galletas y bizcochos', 20.00, 9.3700, 0.00, -8.00, '7460602200094', false, 80),
  ('7462878688040', 'GALLETAS CON OREGANO', 'Galletas y bizcochos', 100.00, 45.0000, 0.00, -1.00, '7462878688040', false, 81),
  ('7462876880422', 'GALLETAS DE AJO MINIÑA', 'Galletas y bizcochos', 100.00, 45.0000, 18.00, 18.00, '7462876880422', false, 83),
  ('7462878688675', 'GALLETAS DE AVENA', 'Galletas y bizcochos', 185.00, 110.0000, 9.00, 9.00, '7462878688675', false, 84),
  ('1023', 'GALLETAS DE CHOCOLECHIPS', 'Galletas y bizcochos', 50.00, 20.0000, 0.00, -1.00, null, false, 85),
  ('7462878688590', 'GALLETAS DE COCO AVENA AMERIKA', 'Galletas y bizcochos', 190.00, 118.0000, 14.00, 14.00, '7462878688590', false, 86),
  ('7462878688743', 'GALLETAS DE JENGIBRE', 'Galletas y bizcochos', 140.00, 82.0000, 11.00, 11.00, '7462878688743', false, 87),
  ('1219', 'GALLETAS DE MANTEQUILLA DELICIAS', 'Galletas y bizcochos', 110.00, 75.0000, 0.00, -27.00, null, false, 88),
  ('7467594930145', 'GALLETAS INTEGRALES SAN LUIS', 'Galletas y bizcochos', 125.00, 41.0000, 0.00, -7.00, '7467594930145', false, 89),
  ('647697659045', 'GALLETAS MARTIN JENGIBRE', 'Galletas y bizcochos', 225.00, 123.7300, 9.00, 9.00, '647697659045', false, 90),
  ('7460602201114', 'GALLETAS MOCANA (MANTECA)', 'Galletas y bizcochos', 160.00, 85.0000, 0.00, 0.00, '7460602201114', false, 91),
  ('7460602201091', 'GALLETAS MOCANA MANTEQUILLA 175.G', 'Galletas y bizcochos', 100.00, 40.0000, 2.00, 2.00, '7460602201091', false, 92),
  ('7460602200100', 'GALLETAS MOCANA PA PIKAR', 'Galletas y bizcochos', 20.00, 100.0000, 0.00, -28.00, '7460602200100', false, 93),
  ('7460602200148', 'GALLETAS MOCANA PA PIKAR', 'Galletas y bizcochos', 80.00, 35.0000, 8.00, 8.00, '7460602200148', false, 94),
  ('7460602200872', 'GALLETAS MOCANAS DE AJO PEQ', 'Galletas y bizcochos', 15.00, 8.0000, 10.00, 10.00, '7460602200872', false, 95),
  ('7462878688804', 'GALLETAS PREMIUM AMERIKA', 'Galletas y bizcochos', 100.00, 60.0000, 0.00, -17.00, '7462878688804', false, 97),
  ('7462878688811', 'GALLETAS PRIMUN DE AJO AMERIKA', 'Galletas y bizcochos', 100.00, 60.0000, 0.00, -4.00, '7462878688811', false, 98),
  ('7467594930138', 'GALLETAS SAN LUIS AJO G', 'Galletas y bizcochos', 125.00, null, 0.00, -6.00, '7467594930138', false, 99),
  ('7467594930060', 'GALLETAS SAN LUIS DE AJO PE', 'Galletas y bizcochos', 90.00, 42.0000, 2.00, 2.00, '7467594930060', false, 100),
  ('2626', 'GALLETAS TOSTADAS GRANDES', 'Galletas y bizcochos', 190.00, 110.0000, 5.00, 5.00, null, false, 101),
  ('7500478008926', 'GAMESA CHOKIS CLASICA', 'Galletas y bizcochos', 70.00, 42.0400, 98.00, 98.00, '7500478008926', false, 102),
  ('7500478013616', 'GAMESA EMPERADOR VAINILLA', 'Galletas y bizcochos', 60.00, 35.0000, 23.00, 23.00, '7500478013616', false, 103);

-- filas 601–800
insert into _p007f2 (codigo, name, categoria, price, cost, qty, qty_listado, barcode, is_bev, posicion) values
  ('7501000601738', 'GAMESA FLORENTINA FRESA', 'Galletas y bizcochos', 70.00, 42.0400, 98.00, 98.00, '7501000601738', false, 104),
  ('7467581603816', 'GUARINA LECHE GRANDE', 'Galletas y bizcochos', 60.00, 37.0000, 0.00, -5.00, '7467581603816', false, 106),
  ('7467581603809', 'GUARINAS LECHE', 'Galletas y bizcochos', 15.00, 8.8000, 16.00, 16.00, '7467581603809', false, 107),
  ('031535591480', 'KNOTTS BERRY FARM RASPBERRY', 'Galletas y bizcochos', 35.00, 26.2500, 0.00, -1.00, '031535591480', false, 110),
  ('7462878688989', 'MANTECADITOS', 'Galletas y bizcochos', 140.00, 82.0000, 0.00, -4.00, '7462878688989', false, 114),
  ('7462878688514', 'MANTECADO PR AMERIKA', 'Galletas y bizcochos', 190.00, 115.0000, 8.00, 8.00, '7462878688514', false, 115),
  ('647697659069', 'MARTIN COCO', 'Galletas y bizcochos', 225.00, 123.7300, 6.00, 6.00, '647697659069', false, 119),
  ('7466564881159', 'MARTIN SUSPIRO', 'Galletas y bizcochos', 225.00, 123.7300, 4.00, 4.00, '7466564881159', false, 120),
  ('044000011703', 'MINI OREO CHOCOLATE', 'Galletas y bizcochos', 60.00, 33.1920, 0.00, -26.00, '044000011703', false, 128),
  ('044000061494', 'MINI OREO VAINILLA', 'Galletas y bizcochos', 55.00, 33.1920, 30.00, 30.00, '044000061494', false, 129),
  ('7467515320048', 'MISSCOOKIE VAINILLA X6', 'Galletas y bizcochos', 60.00, 35.0000, 1.00, 1.00, '7467515320048', false, 131),
  ('7467515320062', 'MISSCOOKIE. COCO', 'Galletas y bizcochos', 50.00, 35.0000, 9.00, 9.00, '7467515320062', false, 132),
  ('7467515320079', 'MISSCOOKIE. JENGEBRE', 'Galletas y bizcochos', 60.00, 35.0000, 4.00, 4.00, '7467515320079', false, 133),
  ('072108010021', 'MOON PIE CHOCOLATE', 'Galletas y bizcochos', 50.00, 30.2100, 1.00, 1.00, '072108010021', false, 136),
  ('7467515320123', 'NY COOKIE CHOCOLATE BLANCO Y GUAYABA', 'Galletas y bizcochos', 230.00, 150.0000, 1.00, 1.00, '7467515320123', false, 137),
  ('7467515320116', 'NY COOKIE CHOCOLATE CHIPS Y NUTELLA', 'Galletas y bizcochos', 200.00, 125.0000, 0.00, -11.00, '7467515320116', false, 138),
  ('7467515320178', 'NY COOKIE CREMA DE PISTACHO Y CHOCOLATE', 'Galletas y bizcochos', 350.00, 225.0000, 1.00, 1.00, '7467515320178', false, 139),
  ('7467515320147', 'NY COOKIE DULCE DE LECHE Y SPECULOS', 'Galletas y bizcochos', 300.00, 175.0000, 13.00, 13.00, '7467515320147', false, 140),
  ('044000047009', 'OREO 6 COOKIES', 'Galletas y bizcochos', 60.00, 35.0283, 71.00, 71.00, '044000047009', false, 142),
  ('7622201693190', 'OREO REGULAR TUBO 108.G', 'Galletas y bizcochos', 80.00, 46.0700, 29.00, 29.00, '7622201693190', false, 145),
  ('1201', 'PASTRY BROWNIE CLASICO', 'Galletas y bizcochos', 70.00, 40.0000, 0.00, -15.00, null, false, 147),
  ('1205', 'PASTRY. COOKIES CREMA DE AVELLANAS', 'Galletas y bizcochos', 210.00, 125.0000, 8.00, 8.00, null, false, 148),
  ('1206', 'PASTRY. COOKIES DULCE DE LECHE', 'Galletas y bizcochos', 210.00, 125.0000, 0.00, -1.00, null, false, 149),
  ('7501000634132', 'QUAKER AVENA FRUTAS ROJAS', 'Galletas y bizcochos', 45.00, 25.5100, 60.00, 60.00, '7501000634132', false, 151),
  ('7501000634118', 'QUAKER GALLETAS GRANOLA', 'Galletas y bizcochos', 45.00, 25.5100, 73.00, 73.00, '7501000634118', false, 152),
  ('680', 'REY DEL BROWNIE BLODE DE GUAYABA', 'Galletas y bizcochos', 65.00, 36.7500, 3.00, 3.00, null, false, 155),
  ('653981779023', 'RICURITAS GALLETAS DE AVENA', 'Galletas y bizcochos', 70.00, 35.0000, 22.00, 22.00, '653981779023', false, 156),
  ('044000009298', 'RITZ BITS CHEESE GALLETA', 'Galletas y bizcochos', 50.00, 34.3300, 11.00, 11.00, '044000009298', false, 157),
  ('7622201390013', 'RITZ QUESO 30G', 'Galletas y bizcochos', 20.00, 8.0000, 6.00, 6.00, '7622201390013', false, 158),
  ('7467594930022', 'SAN LUIS GALLETAS D ANIS', 'Galletas y bizcochos', 120.00, 42.0000, 0.00, -6.00, '7467594930022', false, 166),
  ('7467594930046', 'SAN LUIS GALLETAS D HUEVO', 'Galletas y bizcochos', 120.00, 42.0000, 20.00, 20.00, '7467594930046', false, 167),
  ('6223005598592', 'TAW TAW PHANTOM 4X 30.GM', 'Galletas y bizcochos', 10.00, 5.0000, 0.00, -7.00, '6223005598592', false, 171),
  ('746721770012', 'TRUQUITO', 'Galletas y bizcochos', 100.00, 25.0000, 0.00, 0.00, '746721770012', false, 176),
  ('040000000327', 'CHOCOLATE M Y M AMARILLO', 'Chocolates', 85.00, 47.2281, 104.00, 104.00, '040000000327', false, 4),
  ('4011800546519', 'CORNY CHOCOLATE', 'Chocolates', 80.00, 41.3720, 1.00, 1.00, '4011800546519', false, 5),
  ('4011800548513', 'CORNY CHOCOLATE BANANA', 'Chocolates', 80.00, 41.3720, 6.00, 6.00, '4011800548513', false, 6),
  ('4011800403812', 'CORNY SALTED CARAMEL', 'Chocolates', 80.00, 41.3720, 6.00, 6.00, '4011800403812', false, 7),
  ('03424005', 'HERSHETS MILK CHOC.', 'Chocolates', 110.00, 60.2636, 26.00, 26.00, '03424005', false, 17),
  ('342410', 'HERSHEY,S WHOLE ALMONDS', 'Chocolates', 105.00, 60.1666, 35.00, 35.00, null, false, 19),
  ('03424102', 'HERSHEYS BARRA ALMODS', 'Chocolates', 110.00, 60.1458, 5.00, 5.00, '03424102', false, 20),
  ('034000702152', 'HERSHEYS COOKIES N CREME', 'Chocolates', 105.00, 60.2636, 0.00, -32.00, '034000702152', false, 21),
  ('03423909', 'HERSHEYS COOKIES N CREME 43.G', 'Chocolates', 110.00, 60.2636, 77.00, 77.00, '03423909', false, 22),
  ('00985234', 'KINDER JOY', 'Chocolates', 185.00, 107.0000, 58.00, 58.00, '00985234', false, 23),
  ('03412107', 'KISSES MILK CHOCOLATE', 'Chocolates', 110.00, 60.2050, 17.00, 17.00, '03412107', false, 24),
  ('034000245246', 'KITKAT BIGKAT', 'Chocolates', 75.00, 44.8400, 0.00, 0.00, '034000245246', false, 27),
  ('342460', 'KITKAT CRIPS WAFERS', 'Chocolates', 80.00, 47.7400, 0.00, -1.00, null, false, 28),
  ('040000514480', 'M& M MILK CHOCOLATE', 'Chocolates', 95.00, 51.9980, 14.00, 14.00, '040000514480', false, 29),
  ('040000514510', 'M&M CHOCOLATE AMARILLO', 'Chocolates', 90.00, 51.9704, 32.00, 32.00, '040000514510', false, 30),
  ('040000602040', 'MILKYWAY', 'Chocolates', 95.00, 51.9702, 30.00, 30.00, '040000602040', false, 34),
  ('040000422068', 'MILKYWAY BAR', 'Chocolates', 90.00, 48.0000, 2.00, 2.00, '040000422068', false, 35),
  ('7406234001418', 'MINI CHOCO MANI', 'Chocolates', 120.00, 80.0000, 0.00, -1.00, '7406234001418', false, 36),
  ('009800000753', 'MINI NUTELLA', 'Chocolates', 125.00, 59.4531, 66.00, 66.00, '009800000753', false, 37),
  ('009800800056', 'NUTELLA FERRERO & GO 1.8 OZ', 'Chocolates', 215.00, 129.3404, 4.00, 4.00, '009800800056', false, 38),
  ('04010508', 'SNICKERS ALMOND BAR', 'Chocolates', 95.00, 51.9775, 20.00, 20.00, '04010508', false, 44),
  ('040000514251', 'SNICKERS CLASICO', 'Chocolates', 95.00, 51.9702, 28.00, 28.00, '040000514251', false, 45),
  ('040000004356', 'TWIX COOKIE HARS', 'Chocolates', 95.00, 51.9713, 29.00, 29.00, '040000004356', false, 47),
  ('010700804228', 'ZERO CHOCOLATE', 'Chocolates', 105.00, 60.2050, 1.00, 1.00, '010700804228', false, 48),
  ('140692', 'BOLONES BLOW POP', 'Chicles y caramelos', 10.00, null, 0.00, -2.00, null, false, 2),
  ('107073', 'BOLONES JOLLY', 'Chicles y caramelos', 15.00, 10.0000, 0.00, -2.00, null, false, 3),
  ('7593746000180', 'CARAMEL POPCORN ORIGINAL', 'Chicles y caramelos', 345.00, 208.0000, 2.00, 2.00, '7593746000180', false, 4),
  ('7593746000296', 'CARAMEL POPCORN PEANUTS', 'Chicles y caramelos', 345.00, 208.0000, 6.00, 6.00, '7593746000296', false, 5),
  ('7593746000197', 'CARAMEL POPCORN RAINBOW OF FLAVORS', 'Chicles y caramelos', 345.00, 208.0000, 7.00, 7.00, '7593746000197', false, 6),
  ('310', 'CLORETS PEQ', 'Chicles y caramelos', 2.50, 2.0800, 36.00, 36.00, null, false, 9),
  ('02266600', 'DOUBLEMINT', 'Chicles y caramelos', 110.00, 61.4000, 10.00, 10.00, '02266600', false, 11),
  ('02289106', 'EXTRA PEPPERMINT', 'Chicles y caramelos', 130.00, 64.4000, 0.00, 0.00, '02289106', false, 13),
  ('02289902', 'EXTRA SPEARMINT', 'Chicles y caramelos', 130.00, 64.4000, 0.00, -18.00, '02289902', false, 14),
  ('034856008187', 'GOMITAS WECHS. 22.7.GMS', 'Chicles y caramelos', 30.00, 12.1100, 4.00, 4.00, '034856008187', false, 21),
  ('7622201776459', 'HALL LIMON Y MIEL', 'Chicles y caramelos', 30.00, 13.0374, 35.00, 35.00, '7622201776459', false, 23),
  ('022110079806', 'HUBBA BUBBA CHICLES', 'Chicles y caramelos', 225.00, 120.0000, 8.00, 8.00, '022110079806', false, 29),
  ('03466506', 'ICE BREAKERS DUO FRUIT+COOL', 'Chicles y caramelos', 260.00, 156.0000, 23.00, 23.00, '03466506', false, 31),
  ('03484308', 'ICE BREAKERS ICE CUBES PEPPERMINT', 'Chicles y caramelos', 495.00, 273.2500, 13.00, 13.00, '03484308', false, 32),
  ('03484803', 'ICE BREAKERS ICE CUBES RASPBERRY SORBET', 'Chicles y caramelos', 495.00, 273.2500, 0.00, 0.00, '03484803', false, 33),
  ('03484706', 'ICE BREAKERS ICE CUBES SPERAMINT', 'Chicles y caramelos', 495.00, 273.2500, 14.00, 14.00, '03484706', false, 34),
  ('03400704', 'ICE BREAKERS MINTS 1.5OZ.', 'Chicles y caramelos', 260.00, 156.0000, 23.00, 23.00, '03400704', false, 35),
  ('03409802', 'ICE BREAKERS SOURS GDE', 'Chicles y caramelos', 260.00, 156.0000, 22.00, 22.00, '03409802', false, 36),
  ('739337205146', 'MENTA DE CRISTAL DE FRUTAS', 'Chicles y caramelos', 150.00, 90.0000, 2.00, 2.00, '739337205146', false, 39),
  ('739337205153', 'MENTA DE CRISTAL VERDE', 'Chicles y caramelos', 160.00, 90.0000, 0.00, 0.00, '739337205153', false, 40),
  ('660', 'MENTA DE FRUTAS', 'Chicles y caramelos', 2.50, 1.8300, 0.00, -69.00, null, false, 41),
  ('1234', 'MENTAS DE GUARDIA', 'Chicles y caramelos', 1.90, 1.0900, 0.00, -1.00, null, false, 42),
  ('75072520', 'MENTOS FRESH MINT', 'Chicles y caramelos', 130.00, 71.4460, 0.00, 0.00, '75072520', false, 45),
  ('073390000165', 'MENTOS FRUIT', 'Chicles y caramelos', 60.00, 16.8785, 0.00, -1.00, '073390000165', false, 46),
  ('75068318', 'MENTOS FRUTAS', 'Chicles y caramelos', 50.00, 22.9775, 11.00, 11.00, '75068318', false, 47),
  ('75068271', 'MENTOS MENTA', 'Chicles y caramelos', 50.00, 22.9775, 12.00, 12.00, '75068271', false, 49),
  ('75072537', 'MENTOS PURE FRESH', 'Chicles y caramelos', 130.00, 71.4460, 0.00, 0.00, '75072537', false, 50),
  ('4545', 'PALETA DE AMOR', 'Chicles y caramelos', 5.00, 1.4844, 0.00, -19.00, null, false, 56),
  ('686464432009', 'ROCK PAPER SCISSORS CANDY', 'Chicles y caramelos', 110.00, 67.5000, 0.00, -1.00, '686464432009', false, 59),
  ('022000018465', 'SKITTLES ORIGINAL', 'Chicles y caramelos', 85.00, 47.3163, 1.00, 1.00, '022000018465', false, 60),
  ('009800007219', 'TIC TAC FRESHMINTS', 'Chicles y caramelos', 155.00, 91.3700, 0.00, 0.00, '009800007219', false, 63),
  ('009800007608', 'TIC TAC FRIT ADVENTURE', 'Chicles y caramelos', 155.00, 91.3700, 22.00, 22.00, '009800007608', false, 64),
  ('   7622201776664', 'TRIDENT AZUL PEQ', 'Chicles y caramelos', 30.00, 16.2600, 0.00, -17.00, null, false, 66),
  ('7622201776602', 'TRIDENT FRESA PEQ. 8.5 G', 'Chicles y caramelos', 30.00, 16.2973, 5.00, 5.00, '7622201776602', false, 69),
  ('7506105606077', 'TRIDENT VALU-PAC FRESHMINT', 'Chicles y caramelos', 80.00, 44.1683, 0.00, -1.00, '7506105606077', false, 72),
  ('7506105606091', 'TRIDENT VALU-PACK BUBBLE', 'Chicles y caramelos', 80.00, 41.1108, 1.00, 1.00, '7506105606091', false, 73),
  ('7506105606053', 'TRIDENT VALU-PACK MENTA', 'Chicles y caramelos', 80.00, 44.1683, 28.00, 28.00, '7506105606053', false, 74),
  ('7506105606084', 'TRIDENT VALU-PACK SANDIA', 'Chicles y caramelos', 80.00, 44.1683, 11.00, 11.00, '7506105606084', false, 75),
  ('7506105606060', 'TRIDENT VALU-PACK YERBABUENA', 'Chicles y caramelos', 80.00, 44.1683, 22.00, 22.00, '7506105606060', false, 76),
  ('7622201776572', 'TRIDENT YERBABUENA 8.5 G', 'Chicles y caramelos', 30.00, 16.2973, 6.00, 6.00, '7622201776572', false, 83),
  ('034856028987', 'WELCHIS MIXED FRUIT FRIT SNACKS', 'Chicles y caramelos', 145.00, 84.7525, 12.00, 12.00, '034856028987', false, 87),
  ('034856028918', 'WELCHS FRUIT NSNACKS ISLAND FRUITS', 'Chicles y caramelos', 145.00, 84.7525, 0.00, -1.00, '034856028918', false, 88),
  ('034856028925', 'WELCHS FRUIT SNACKS BERRYES CHERRIES', 'Chicles y caramelos', 145.00, 84.7525, 14.00, 14.00, '034856028925', false, 89),
  ('7468268260452', 'CASTILLO PAQUETE DE RASPADURA DE 4', 'Dulces típicos', 115.00, 70.0000, 0.00, 0.00, '7468268260452', false, 1),
  ('7464088413047', 'DR BANDEJA DE CANQUINA', 'Dulces típicos', 135.00, 75.0000, 3.00, 3.00, '7464088413047', false, 14),
  ('7464088413085', 'DR BANDEJA DE CARAMELOS', 'Dulces típicos', 150.00, 90.0000, 2.00, 2.00, '7464088413085', false, 15),
  ('7464088413023', 'DR BANDEJA DE COCADA', 'Dulces típicos', 190.00, 105.0000, 0.00, 0.00, '7464088413023', false, 16),
  ('7464088413016', 'DR BANDEJA DE JALAO', 'Dulces típicos', 210.00, 105.0000, 0.00, -1.00, '7464088413016', false, 17),
  ('7464088410251', 'DR COCO PIÑA Y LECHE', 'Dulces típicos', 190.00, 105.0000, 0.00, -2.00, '7464088410251', false, 18),
  ('7464088410329', 'DR DULCE DE CAJUIL CON LECHE', 'Dulces típicos', 150.00, 105.0000, 0.00, -2.00, '7464088410329', false, 19),
  ('7464088413153', 'DR DULCE DE COCO TIERNO', 'Dulces típicos', 270.00, 170.0000, 0.00, 0.00, '7464088413153', false, 20),
  ('7464088410244', 'DR DULCE DE COCO Y LECHE', 'Dulces típicos', 210.00, 105.0000, 0.00, -1.00, '7464088410244', false, 21),
  ('7464088410213', 'DR DULCE DE LECHE', 'Dulces típicos', 210.00, 105.0000, 0.00, 0.00, '7464088410213', false, 22),
  ('7464088411104', 'DR DULCE DE MANI', 'Dulces típicos', 120.00, 65.0000, 0.00, 0.00, '7464088411104', false, 23),
  ('7464088410268', 'DR DULCE ESTELAR', 'Dulces típicos', 190.00, 130.0000, 0.00, 0.00, '7464088410268', false, 24),
  ('7464088411173', 'DR DULCE TRES EN UNO', 'Dulces típicos', 210.00, 105.0000, 3.00, 3.00, '7464088411173', false, 25),
  ('7464088412019', 'DR MILK FUDGE', 'Dulces típicos', 250.00, 110.0000, 0.00, 0.00, '7464088412019', false, 26),
  ('7464088413061', 'DR PALETAS KICO', 'Dulces típicos', 70.00, 40.0000, 5.00, 5.00, '7464088413061', false, 27),
  ('7464088413030', 'DR PALITOS DE COCO', 'Dulces típicos', 130.00, 75.0000, 6.00, 6.00, '7464088413030', false, 28),
  ('7464088413221', 'DR PALO NAVIDEÑO', 'Dulces típicos', 210.00, 125.0000, 0.00, 0.00, '7464088413221', false, 29),
  ('7464088411128', 'DR PAQUETE DE RASPAURA', 'Dulces típicos', 195.00, 105.0000, 0.00, 0.00, '7464088411128', false, 30),
  ('7464088410275', 'DR PASTA DE CONCON DE LECHE', 'Dulces típicos', 160.00, 110.0000, 0.00, 0.00, '7464088410275', false, 31),
  ('7464088410367', 'DR PASTA DE NARANJA', 'Dulces típicos', 195.00, 110.0000, 0.00, 0.00, '7464088410367', false, 32),
  ('7464088413092', 'DR RASPADURA FAMILIAR', 'Dulces típicos', 225.00, 125.0000, 0.00, 0.00, '7464088413092', false, 34),
  ('7464088410220', 'DR RELLENO DE GUAYABA', 'Dulces típicos', 210.00, 105.0000, 0.00, -3.00, '7464088410220', false, 35),
  ('7464088410237', 'DR RELLENO DE NARANJA', 'Dulces típicos', 210.00, 105.0000, 0.00, -8.00, '7464088410237', false, 36),
  ('7464088413078', 'DR SANDWICH FAMILIAR', 'Dulces típicos', 190.00, 110.0000, 0.00, 0.00, '7464088413078', false, 37),
  ('7464088411098', 'DR SEMAME AHONJOLI', 'Dulces típicos', 120.00, 65.0000, 0.00, 0.00, '7464088411098', false, 38),
  ('7464088413344', 'DULCE DE GUAYABA RODRIGUEZ', 'Dulces típicos', 180.00, 105.0000, 8.00, 8.00, '7464088413344', false, 50),
  ('7464088413528', 'DULCE GOURMET GRANDE FAMILIAR', 'Dulces típicos', 310.00, 175.0000, 0.00, 0.00, '7464088413528', false, 51),
  ('2014', 'MERMELADAS Y POTES DE DULCES VARIADO', 'Dulces típicos', 200.00, 125.0000, 0.00, -1.00, null, false, 52),
  ('1202', 'PASTRY DULCEDE COCO', 'Dulces típicos', 140.00, 75.0000, 0.00, -7.00, null, false, 53),
  ('7464088411142', 'SANDWICH ORANGE WITH', 'Dulces típicos', 170.00, 105.0000, 2.00, 2.00, '7464088411142', false, 54),
  ('016000264694', 'NATURE VALLEY OATS HONEY', 'Barras de proteína', 85.00, 35.0000, 5.00, 5.00, '016000264694', false, 3),
  ('016000507661', 'NATURE VALLEY PROTEIN', 'Barras de proteína', 75.00, 31.9400, 0.00, 0.00, '016000507661', false, 4),
  ('691535201019', 'SLIM BROWNIE CRUNCH', 'Barras de proteína', 215.00, 129.1700, 0.00, -1.00, '691535201019', false, 27),
  ('691535207011', 'SLIM CRUCHY PEANUT BUTTER', 'Barras de proteína', 215.00, 129.1700, 0.00, 0.00, '691535207011', false, 28),
  ('00071', 'AJO EN PASTA', 'Despensa', 1200.00, 843.2200, 8.00, 8.00, null, false, 8),
  ('12026088', 'AZUCAL CREMA SOBRESITOS NESCAFE', 'Despensa', 1000.00, 681.0300, 2.00, 2.00, '12026088', false, 9),
  ('086600708881', 'BUMBLE BEE FAT FREE TUNA SALADA', 'Despensa', 130.00, 75.4500, 17.00, 17.00, '086600708881', false, 11),
  ('086600707778', 'BUMBLE BEE TUNA SALADA', 'Despensa', 130.00, 75.4500, 6.00, 6.00, '086600707778', false, 13),
  ('074471000500', 'CAFE BUSTELO', 'Despensa', 600.00, 650.0000, 3.00, 3.00, '074471000500', false, 14),
  ('042625', 'CAT CHUP HEINZ SOBRESITOS', 'Despensa', 3.00, 1.4745, 2500.00, 2500.00, null, false, 16),
  ('1125', 'CATCHUP LINDA SOBRE', 'Despensa', 508.47, 1.4700, 3004.00, 3004.00, null, false, 17),
  ('735051000562', 'COMPOTA HEINZ DEMANZANA', 'Despensa', 60.00, 34.0750, 1.00, 1.00, '735051000562', false, 21),
  ('735051000630', 'COMPOTA HEINZ FRUIT', 'Despensa', 55.00, 34.0750, 4.00, 4.00, '735051000630', false, 22),
  ('7460111132251', 'COMPOTA MANZANA RICA', 'Despensa', 50.00, 24.7300, 3.00, 3.00, '7460111132251', false, 23),
  ('7460111132299', 'COMPOTAS RICA DE FRUTAS', 'Despensa', 50.00, 24.7300, 9.00, 9.00, '7460111132299', false, 24),
  ('070662030028', 'CUP NEODLES SOPA DE CAMARONES', 'Despensa', 75.00, 45.1900, 13.00, 13.00, '070662030028', false, 25),
  ('7467581604530', 'HATUEY HIERBAS Y ESPECIAS', 'Despensa', 10.00, 5.8500, 137.00, 137.00, '7467581604530', false, 27),
  ('070662096314', 'HOT Y SPICY CHIKEN FLAVOR SOPA', 'Despensa', 115.00, 67.0903, 7.00, 7.00, '070662096314', false, 28),
  ('750894680078', 'ISSIMA SOPA DE POLLO', 'Despensa', 75.00, 41.0000, 31.00, 31.00, '750894680078', false, 29),
  ('010041001263', 'JAJA SALCHICHAS PQ', 'Despensa', 50.00, 26.1300, 2.00, 2.00, '010041001263', false, 30),
  ('038000635700', 'KELLOGGS FROSTED FLAKES', 'Despensa', 160.00, 94.5000, 1.00, 1.00, '038000635700', false, 32),
  ('095', 'LIMON', 'Despensa', 10.00, 3.0000, 0.00, -13.00, null, false, 34),
  ('307', 'LIMON ENTERO', 'Despensa', 20.00, 10.0000, 0.00, -12.00, null, false, 35),
  ('570', 'MANZANA ROJA GD', 'Despensa', 40.00, 22.7200, 0.00, -2.00, null, false, 36),
  ('572', 'MANZANA VERDE', 'Despensa', 55.00, 33.7500, 0.00, -1.00, null, false, 37),
  ('12257968', 'NESCAFE ALEGRIA', 'Despensa', 2850.00, 1769.7100, 4.00, 4.00, '12257968', false, 38),
  ('1133', 'NESCAFE AZUCAR BLANCA', 'Despensa', 900.00, 681.0300, 1.00, 1.00, null, false, 39),
  ('612', 'NESCAFE CAFE EN GRANO', 'Despensa', 125.00, 1302.7200, 3.00, 3.00, null, false, 40),
  ('070662030035', 'NISSIN CUP NEODLES SOPA POLLO Y VEGETALE', 'Despensa', 75.00, 40.6073, 151.00, 151.00, '070662030035', false, 44),
  ('750894680672', 'NISSIN SOPA POLLO PICANTE', 'Despensa', 75.00, 44.0000, 39.00, 39.00, '750894680672', false, 45),
  ('15003200', 'QUESO MOZZARELLA RICA LB', 'Despensa', 1600.00, 990.0000, 19.00, 19.00, '15003200', false, 46),
  ('039000086639', 'SALCHICHA VIENNA AZUL', 'Despensa', 90.00, 53.1400, 42.00, 42.00, '039000086639', false, 47),
  ('4632', 'SAZON LIQUIDO BALDOM', 'Despensa', 1000.00, 983.0500, 1.00, 1.00, null, false, 49),
  ('754842110105', 'SOPA CANTONESA', 'Despensa', 75.00, 25.0000, 3.00, 3.00, '754842110105', false, 53),
  ('754842110037', 'SOPA CANTONESA DE RES', 'Despensa', 60.00, 25.0000, 27.00, 27.00, '754842110037', false, 54),
  ('754842110020', 'SOPA CANTONESA POLLO', 'Despensa', 60.00, 25.0000, 30.00, 30.00, '754842110020', false, 55),
  ('7467581602888', 'SOPA MILANO SABOR CHULETA', 'Despensa', 75.00, 24.5700, 0.00, -1.00, '7467581602888', false, 56),
  ('7467581602864', 'SOPA MILANO SABOR POLLO', 'Despensa', 75.00, 24.7175, 27.00, 27.00, '7467581602864', false, 57),
  ('039000086691', 'VIENNA SALCHICHA POLLO', 'Despensa', 90.00, 53.1400, 12.00, 12.00, '039000086691', false, 59),
  ('0325', 'VINAGRE GALON', 'Despensa', 150.00, 114.0000, 8.00, 8.00, null, false, 60),
  ('1001007', 'YU SOPAS ISSIMA POLLO PICANTE', 'Despensa', 75.00, 41.0000, 108.00, 108.00, null, false, 62),
  ('676', 'BISCOCHOS DEL ENCANTO', 'Comida y helados', 210.00, 125.0000, 7.00, 7.00, null, false, 1),
  ('531', 'BOLA DE YUCA', 'Comida y helados', 100.00, 55.0000, 0.00, -5.00, null, false, 2),
  ('579', 'BOLA QUESO HOJA', 'Comida y helados', 85.00, 50.0000, 13.00, 13.00, null, false, 3),
  ('557', 'BURRITO PICADERA', 'Comida y helados', 60.00, 58.2500, 0.00, 0.00, null, false, 4),
  ('5699100160216', 'CHEESECAKE', 'Comida y helados', 120.00, 115.0000, 0.00, -5.00, '5699100160216', false, 5),
  ('013087803204', 'CINNAMON ROLL', 'Comida y helados', 140.00, 83.9200, 60.00, 60.00, '013087803204', false, 6),
  ('2021', 'CLUB SANDWICH', 'Comida y helados', 270.00, 135.0000, 1.00, 1.00, null, false, 7),
  ('536', 'CLUB SANDWICH INTEGRAL', 'Comida y helados', 270.00, 150.0000, 3.00, 3.00, null, false, 8),
  ('3030', 'CROISANT DE JAMON Y QUESO', 'Comida y helados', 125.00, 50.0000, 6.00, 6.00, null, false, 9),
  ('5492', 'CROQUETAS', 'Comida y helados', 20.00, 15.0000, 0.00, -2.00, null, false, 10),
  ('5699100304757', 'DONA GLACEADAS', 'Comida y helados', 120.00, 48.0000, 0.00, -15.00, '5699100304757', false, 11),
  ('678', 'DONA RELLENA', 'Comida y helados', 140.00, 45.0000, 0.00, -28.00, null, false, 12),
  ('679', 'DONAS 1', 'Comida y helados', 75.00, 45.0000, 0.00, -4.00, null, false, 13),
  ('677', 'DONAS GLASEADAS', 'Comida y helados', 120.00, 65.0000, 0.00, 0.00, null, false, 14),
  ('5699100154475', 'DULCE FRIO', 'Comida y helados', 100.00, 65.0000, 0.00, -81.00, '5699100154475', false, 15),
  ('671', 'DULCE FRIO DEL ENCANTO', 'Comida y helados', 100.00, 55.0000, 2.00, 2.00, null, false, 16),
  ('575', 'EMPANADAS SURTIDAS', 'Comida y helados', 100.00, 55.0000, 0.00, -2.00, null, false, 17),
  ('7460123444311', 'FLAN DE LECHE', 'Comida y helados', 170.00, 100.0000, 0.00, 0.00, '7460123444311', false, 18),
  ('3333', 'FLAN DE NATALLY', 'Comida y helados', 550.00, 350.0000, 0.00, -6.00, null, false, 19),
  ('1212', 'GELATINA', 'Comida y helados', 50.00, 20.0000, 19.00, 19.00, null, false, 20),
  ('0211130257393', 'GEO GEO 1.17 LB', 'Comida y helados', 400.00, 235.0000, 13.00, 13.00, '0211130257393', false, 21),
  ('581', 'GUAYABA CHEESECAKE BLONDIE', 'Comida y helados', 145.00, 90.0000, 1.00, 1.00, null, false, 22),
  ('670', 'MAJARETE DEL ENCANTO', 'Comida y helados', 85.00, 55.0000, 2.00, 2.00, null, false, 25),
  ('529', 'MINI SANDWICH', 'Comida y helados', 50.00, 25.0000, 0.00, -25.00, null, false, 26),
  ('013087047226', 'MUFFIN CHOCOLATE CHIP', 'Comida y helados', 150.00, 90.5700, 6.00, 6.00, '013087047226', false, 27),
  ('091752001704', 'MUFFIN CORN INDIVIDUAL 4770', 'Comida y helados', 150.00, 90.5700, 1.00, 1.00, '091752001704', false, 28),
  ('0010', 'MUFI CON PASAS SUELTO 2026', 'Comida y helados', 100.00, 60.0000, 2.00, 2.00, null, false, 29),
  ('0011', 'MUFI DE MAIZ SUELTO 2026', 'Comida y helados', 100.00, 60.0000, 0.00, -2.00, null, false, 30),
  ('1203', 'PASTRY CHOCO PASION', 'Comida y helados', 150.00, 85.0000, 0.00, -9.00, null, false, 31);

-- filas 801–1000
insert into _p007f2 (codigo, name, categoria, price, cost, qty, qty_listado, barcode, is_bev, posicion) values
  ('200000065003', 'PICADERA DE JAMON', 'Comida y helados', 200.00, 80.0000, 0.00, 0.00, '200000065003', false, 32),
  ('200000090005', 'PICADERA JAMON Y QUESO', 'Comida y helados', 200.00, 120.0000, 0.00, 0.00, '200000090005', false, 33),
  ('34', 'PICADERA QUESO', 'Comida y helados', 200.00, 120.0000, 0.00, 0.00, null, false, 34),
  ('596', 'PIZZA', 'Comida y helados', 100.00, 40.0000, 0.00, -16.00, null, false, 35),
  ('007', 'PIZZA GRANDE', 'Comida y helados', 500.00, 245.0000, 0.00, 0.00, null, false, 36),
  ('3312', 'PIZZA MEDIANA', 'Comida y helados', 350.00, 175.0000, 0.00, 0.00, null, false, 37),
  ('672', 'QUESILLO DEL ENCANTO', 'Comida y helados', 140.00, 80.0000, 9.00, 9.00, null, false, 38),
  ('0672', 'QUESILLO NUEVO', 'Comida y helados', 140.00, 80.0000, 0.00, -15.00, null, false, 39),
  ('580', 'QUESO DE HOJA GRANDE', 'Comida y helados', 325.00, 190.0000, 11.00, 11.00, null, false, 40),
  ('2039', 'QUESO SUPERIOR TIPO HOLANDES', 'Comida y helados', 350.00, 215.0000, 0.00, -1.00, null, false, 41),
  ('530', 'QUIPE SURTIDO', 'Comida y helados', 100.00, 55.0000, 0.00, -5.00, null, false, 42),
  ('0102', 'SANDWICH CUBANO', 'Comida y helados', 190.00, 60.0000, 6.00, 6.00, null, false, 43),
  ('0103', 'SANDWICH DE POLLO Y PIERNA', 'Comida y helados', 230.00, 100.0000, 4.00, 4.00, null, false, 44),
  ('533', 'SANDWICH INTEGRAL CUADRADO', 'Comida y helados', 120.00, 60.0000, 3.00, 3.00, null, false, 45),
  ('532', 'SANDWICH INTEGRAL PAVO', 'Comida y helados', 170.00, 100.0000, 0.00, -1.00, null, false, 46),
  ('528', 'SANDWICH JAMON DE PAVO CON QUESO', 'Comida y helados', 120.00, 50.0000, 0.00, 0.00, null, false, 47),
  ('2024', 'SERVICIO DE CARNE SALADA', 'Comida y helados', 350.00, 145.0000, 0.00, -5.00, null, false, 48),
  ('2026', 'SERVICIO DE PAPA', 'Comida y helados', 100.00, 25.0000, 0.00, -3.00, null, false, 49),
  ('602', 'SOPA PREPARADAS 007', 'Comida y helados', 100.00, 50.0000, 0.00, -10.00, null, false, 50),
  ('603', 'SOPAS PREPARADAS GRANDES', 'Comida y helados', 150.00, 90.0000, 0.00, -4.00, null, false, 51),
  ('583', 'TRES LECHE', 'Comida y helados', 215.00, 130.0000, 0.00, -1.00, null, false, 52),
  ('673', 'TRES LECHE DEL ENCANTO', 'Comida y helados', 275.00, 135.0000, 0.00, 0.00, null, false, 53),
  ('2125', 'TRES LECHES PICADOS PRICMER', 'Comida y helados', 75.00, 50.0000, 0.00, 0.00, null, false, 54),
  ('1028', 'WRAP DE JAMON Y QUESO', 'Comida y helados', 220.00, 120.0000, 10.00, 10.00, null, false, 55),
  ('1043', 'WRAP DE POLLO', 'Comida y helados', 250.00, 120.0000, 0.00, 0.00, null, false, 56),
  ('5050', 'WRAP DE POLLO CON VEGETALES', 'Comida y helados', 270.00, 125.0000, 3.00, 3.00, null, false, 57),
  ('7468162820301', 'BON ALOHA FROZEN FRAMBUESA', 'Helados', 50.00, 31.2500, 0.00, -2.00, '7468162820301', false, 1),
  ('7468162811279', 'BON CHOCO CHOCO CREMA PALETA', 'Helados', 80.00, 47.9896, 29.00, 29.00, '7468162811279', false, 2),
  ('7468162802321', 'BON CHOCO CREMA', 'Helados', 80.00, 47.9896, 0.00, -6.00, '7468162802321', false, 3),
  ('7468162820974', 'BON CHOCO CREMA DULCE LECHE', 'Helados', 80.00, 47.9896, 5.00, 5.00, '7468162820974', false, 4),
  ('7468162812870', 'BON CHOCO CREMA MANI PALETA', 'Helados', 80.00, 47.9896, 41.00, 41.00, '7468162812870', false, 5),
  ('7468162810982', 'BON COCO PALETA', 'Helados', 70.00, 42.3475, 23.00, 23.00, '7468162810982', false, 6),
  ('7468162812818', 'BON COPA CHIPS', 'Helados', 120.00, 70.6117, 14.00, 14.00, '7468162812818', false, 7),
  ('7468162822176', 'BON DON ALFONSO TARRO', 'Helados', 330.00, 196.8966, 4.00, 4.00, '7468162822176', false, 8),
  ('7468162810944', 'BON FRAMBUESA PALETA', 'Helados', 40.00, 19.7555, 6.00, 6.00, '7468162810944', false, 9),
  ('7468162811019', 'BON FRESA BAR NATURAL PALETA', 'Helados', 70.00, 42.3475, 0.00, -2.00, '7468162811019', false, 10),
  ('7468162813013', 'BON FRESA CREMA', 'Helados', 70.00, 42.3475, 7.00, 7.00, '7468162813013', false, 11),
  ('7468162810388', 'BON FRESA TARRO DE PT2', 'Helados', 400.00, 222.7800, 11.00, 11.00, '7468162810388', false, 12),
  ('7468162813761', 'BON FUDGE BAR BIZCOCHO', 'Helados', 45.00, 25.4166, 3.00, 3.00, '7468162813761', false, 13),
  ('7468162811712', 'BON FUDGE BAR CHOCOLATE PALETA', 'Helados', 45.00, 25.4166, 0.00, 0.00, '7468162811712', false, 14),
  ('7468162810562', 'BON HELADO DE BISCOCHO 1 TARRO', 'Helados', 250.00, 149.5050, 5.00, 5.00, '7468162810562', false, 15),
  ('7468162813594', 'BON HELADO ETIQUETA NEGRA BIZCOCHO', 'Helados', 330.00, 196.8966, 2.00, 2.00, '7468162813594', false, 16),
  ('7468162822183', 'BON MERENGUE TARRO', 'Helados', 330.00, 196.8966, 1.00, 1.00, '7468162822183', false, 17),
  ('7468162810999', 'BON PALETA CHINOLA', 'Helados', 70.00, 42.3475, 11.00, 11.00, '7468162810999', false, 18),
  ('7468162813020', 'BON PALETA CHINOLA CREMA', 'Helados', 70.00, 42.3475, 0.00, -5.00, '7468162813020', false, 19),
  ('7468162810968', 'BON PALETA DE MANZANA', 'Helados', 35.00, 19.7555, 20.00, 20.00, '7468162810968', false, 20),
  ('7468162810951', 'BON PALETA DE UVA', 'Helados', 30.00, 16.9400, 0.00, 0.00, '7468162810951', false, 21),
  ('7468162811163', 'BON PALETA PIÑA COLADA', 'Helados', 25.00, 15.7010, 0.00, -3.00, '7468162811163', false, 22),
  ('7468162813846', 'BON VANILLA CREAM SANDWICH', 'Helados', 120.00, 66.0416, 22.00, 22.00, '7468162813846', false, 23),
  ('7468162820615', 'COPA BON FRESA', 'Helados', 120.00, 70.6117, 18.00, 18.00, '7468162820615', false, 24),
  ('7468162827980', 'COPA BON PRISCILA', 'Helados', 120.00, 70.6117, 41.00, 41.00, '7468162827980', false, 25),
  ('7468162822893', 'DON ALFONSO PALETA', 'Helados', 90.00, 53.6346, 0.00, -1.00, '7468162822893', false, 26),
  ('7468162810579', 'HELADO BON BIZCOCHO 2 PINTA', 'Helados', 380.00, 222.7800, 0.00, 0.00, '7468162810579', false, 27),
  ('7468162810517', 'HELADO BON CHOCOLATE TARRO', 'Helados', 250.00, 149.5050, 4.00, 4.00, '7468162810517', false, 28),
  ('7468162810371', 'HELADO BON FRESA TARRO', 'Helados', 250.00, 149.5050, 4.00, 4.00, '7468162810371', false, 29),
  ('7468162811057', 'HELADO BON MACADAMIA PINTA', 'Helados', 330.00, 196.8966, 1.00, 1.00, '7468162811057', false, 30),
  ('7468162811798', 'HELADO BON RON PASAS TARRO', 'Helados', 250.00, 149.5050, 4.00, 4.00, '7468162811798', false, 31),
  ('7468162810494', 'HELADO BON VAINILLA 2.PINTA', 'Helados', 400.00, 222.7000, 2.00, 2.00, '7468162810494', false, 32),
  ('7468162810746', 'HELADO BON VAINILLA IMPERIAL PINTA', 'Helados', 330.00, 196.8966, 4.00, 4.00, '7468162810746', false, 33),
  ('7468162810487', 'HELADO BON VAINILLA TARRO', 'Helados', 250.00, 149.5050, 10.00, 10.00, '7468162810487', false, 34),
  ('7506306415775', 'MAGNUM ALMENDRAS', 'Helados', 160.00, 96.1280, 0.00, -13.00, '7506306415775', false, 35),
  ('7506306416079', 'MAGNUM ALMENDRAS CHOCO BLANCO', 'Helados', 160.00, 96.1280, 23.00, 23.00, '7506306416079', false, 36),
  ('7506306415799', 'MAGNUM CLASICA', 'Helados', 160.00, 96.1280, 26.00, 26.00, '7506306415799', false, 37),
  ('7506306418066', 'MAGNUM COOKIE REMIX', 'Helados', 160.00, 96.1280, 9.00, 9.00, '7506306418066', false, 38),
  ('7506306413320', 'MAGNUN COOKIES CREAM', 'Helados', 160.00, 96.1200, 25.00, 25.00, '7506306413320', false, 39),
  ('7506306417571', 'MORDISCO', 'Helados', 110.00, 66.2291, 0.00, -30.00, '7506306417571', false, 40),
  ('7501130901050', 'MORDISKO CLASIKO', 'Helados', 115.00, 66.2291, 34.00, 34.00, '7501130901050', false, 41),
  ('7468162813501', 'PALETA CHERRY', 'Helados', 35.00, 19.7555, 1.00, 1.00, '7468162813501', false, 42),
  ('7468162813518', 'PALETA MORA', 'Helados', 35.00, 19.7555, 18.00, 18.00, '7468162813518', false, 43),
  ('7468162823043', 'PALETAS BON ICE', 'Helados', 45.00, 25.4166, 0.00, -1.00, '7468162823043', false, 44),
  ('7468162810524', 'TARRO CHOCOLATE PT2', 'Helados', 400.00, 222.7800, 3.00, 3.00, '7468162810524', false, 45),
  ('640746410093', 'CIMARRON ROBUSTO.5*54,20.S', 'Cigarrillos y tabaco', 385.00, 205.0000, 20.00, 20.00, '640746410093', false, 4),
  ('1024', 'CORTADOR DE SIGARROS PLATICOS NEGRO OVALADO', 'Cigarrillos y tabaco', 280.00, 100.0000, 6.00, 6.00, null, false, 6),
  ('74209934', 'DUNHILL SWITCH 10S', 'Cigarrillos y tabaco', 185.00, 110.7200, 0.00, -16.00, '74209934', false, 10),
  ('74209514', 'DUNHILL SWITCH GDE', 'Cigarrillos y tabaco', 395.00, 237.3730, 19.00, 19.00, '74209514', false, 11),
  ('7502273850366', 'ENCENDEDORA CLIPPER PEQ', 'Cigarrillos y tabaco', 65.00, 25.4240, 20.00, 20.00, '7502273850366', false, 13),
  ('7465603161535', 'LA AURORA BELICOSO MADURO CIGARROS', 'Cigarrillos y tabaco', 390.00, 209.0000, 2.00, 2.00, '7465603161535', false, 16),
  ('689674102540', 'MACANUDO CIGARROS', 'Cigarrillos y tabaco', 575.00, 309.5000, 0.00, -1.00, '689674102540', false, 27),
  ('7460985109304', 'MARLBORO ARTESANAL ICE MIX PEQ', 'Cigarrillos y tabaco', 160.00, 86.2300, 0.00, 0.00, '7460985109304', false, 28),
  ('7460836508218', 'MARLBORO FRESH ICE 20C.', 'Cigarrillos y tabaco', 420.00, 251.8300, 0.00, 0.00, '7460836508218', false, 29),
  ('7460985108413', 'MARLBORO GOLD GDE', 'Cigarrillos y tabaco', 440.00, 266.9500, 1.00, 1.00, '7460985108413', false, 30),
  ('7460985108420', 'MARLBORO GOLD PEQ', 'Cigarrillos y tabaco', 225.00, 133.4700, 5.00, 5.00, '7460985108420', false, 31),
  ('74601462', 'MARLBORO NORMAL GDE.', 'Cigarrillos y tabaco', 440.00, 266.9500, 6.00, 6.00, '74601462', false, 32),
  ('74601172', 'MARLBORO ROJO PEQ.', 'Cigarrillos y tabaco', 210.00, 133.4700, 21.00, 21.00, '74601172', false, 33),
  ('7460985107928', 'NACIONAL GDE.', 'Cigarrillos y tabaco', 350.00, 212.0000, 8.00, 8.00, '7460985107928', false, 34),
  ('7460985107942', 'NACIONAL PEQ', 'Cigarrillos y tabaco', 190.00, 113.4700, 11.00, 11.00, '7460985107942', false, 35),
  ('7421000501336', 'NEWPORT FREEZING POINT GD', 'Cigarrillos y tabaco', 390.00, 235.9322, 14.00, 14.00, '7421000501336', false, 36),
  ('7421000501350', 'NEWPORT FREEZING POINT PQ', 'Cigarrillos y tabaco', 195.00, 117.9666, 0.00, -4.00, '7421000501350', false, 37),
  ('74201334', 'NEWPORT VERDE GDE.12MG', 'Cigarrillos y tabaco', 395.00, 235.9322, 20.00, 20.00, '74201334', false, 38),
  ('74201532', 'NEWPORT VERDE PEQ.', 'Cigarrillos y tabaco', 190.00, 117.9666, 0.00, -6.00, '74201532', false, 39),
  ('071610524958', 'OMAR ORTEZ CONNECTICUT CIGARROS', 'Cigarrillos y tabaco', 415.00, 240.0000, 7.00, 7.00, '071610524958', false, 40),
  ('7421000598411', 'PALL MALL ALASKA', 'Cigarrillos y tabaco', 160.00, 94.7460, 6.00, 6.00, '7421000598411', false, 41),
  ('74209460', 'PALL MALL MENTOL', 'Cigarrillos y tabaco', 150.00, 69.0800, 6.00, 6.00, '74209460', false, 42),
  ('7421000594642', 'PALL MALL MIAMI PEQ.', 'Cigarrillos y tabaco', 150.00, 94.7460, 3.00, 3.00, '7421000594642', false, 43),
  ('7421000594666', 'PALL MALL MYKONOS PEQ', 'Cigarrillos y tabaco', 150.00, 94.7460, 7.00, 7.00, '7421000594666', false, 44),
  ('74209453', 'PALL MALL ROJA', 'Cigarrillos y tabaco', 110.00, 69.0800, 10.00, 10.00, '74209453', false, 45),
  ('7421000594628', 'PALLMALL TOKYO PEQ', 'Cigarrillos y tabaco', 150.00, 94.7460, 7.00, 7.00, '7421000594628', false, 46),
  ('7465603183629', 'PRINCIPE BROWN', 'Cigarrillos y tabaco', 50.00, 25.0000, 5.00, 5.00, '7465603183629', false, 48),
  ('7465603183834', 'PRINCIPE BROWN CHICO', 'Cigarrillos y tabaco', 50.00, 25.0000, 16.00, 16.00, '7465603183834', false, 49),
  ('7465603183643', 'PRINCIPE CARIBE', 'Cigarrillos y tabaco', 50.00, 25.0000, 0.00, 0.00, '7465603183643', false, 50),
  ('7465603183681', 'PRINCIPE CHICO BROWN', 'Cigarrillos y tabaco', 50.00, 24.7000, 0.00, -17.00, '7465603183681', false, 51),
  ('7465603188266', 'TAINO MADURO ROBUSTO', 'Cigarrillos y tabaco', 280.00, 106.0000, 5.00, 5.00, '7465603188266', false, 55),
  ('7460985109076', 'TEREA AZUL OSCURO', 'Cigarrillos y tabaco', 385.00, 230.2272, 2.00, 2.00, '7460985109076', false, 56),
  ('7460985109083', 'TEREA AZULCLARO', 'Cigarrillos y tabaco', 330.00, 237.2900, 0.00, 0.00, '7460985109083', false, 57),
  ('7460985109366', 'TEREA CLACIER PERL', 'Cigarrillos y tabaco', 350.00, 238.0000, 0.00, 0.00, '7460985109366', false, 58),
  ('7460985109021', 'TEREA DORADA', 'Cigarrillos y tabaco', 330.00, 237.2900, 0.00, 0.00, '7460985109021', false, 59),
  ('7460985109038', 'TEREA MARRON', 'Cigarrillos y tabaco', 385.00, 230.2272, 0.00, 0.00, '7460985109038', false, 60),
  ('7460985109106', 'TEREA MORADA', 'Cigarrillos y tabaco', 385.00, 230.2272, 4.00, 4.00, '7460985109106', false, 61),
  ('7460985109052', 'TEREA ROJA', 'Cigarrillos y tabaco', 385.00, 230.2272, 4.00, 4.00, '7460985109052', false, 62),
  ('7460985109069', 'TEREA YELLOW', 'Cigarrillos y tabaco', 385.00, 230.2272, 4.00, 4.00, '7460985109069', false, 63),
  ('7311250045462', 'ZIN BLACK CHERRY MEDIUM', 'Cigarrillos y tabaco', 400.00, 215.0000, 6.00, 6.00, '7311250045462', false, 68),
  ('7311250045479', 'ZIN BLACK CHERRY STRONG', 'Cigarrillos y tabaco', 400.00, 215.0000, 2.00, 2.00, '7311250045479', false, 69),
  ('7311250045417', 'ZIN COOL MINT STRONG', 'Cigarrillos y tabaco', 400.00, 215.0000, 0.00, 0.00, '7311250045417', false, 70),
  ('7311250045400', 'ZYN COOL MINT MEDIUM', 'Cigarrillos y tabaco', 400.00, 215.0000, 6.00, 6.00, '7311250045400', false, 71),
  ('7311250045424', 'ZYN SPEARMINT MEDIUM', 'Cigarrillos y tabaco', 400.00, 215.0000, 4.00, 4.00, '7311250045424', false, 72),
  ('7311250045431', 'ZYN SPEARMINT STRNG', 'Cigarrillos y tabaco', 400.00, 215.0000, 2.00, 2.00, '7311250045431', false, 73),
  ('7406135040219', 'VEEV NOW BLUE MINT', 'Vapes', 850.00, 420.0000, 9.00, 9.00, '7406135040219', false, 2),
  ('7406135040226', 'VEEV NOW BLUE RASPBERRY', 'Vapes', 850.00, 420.0000, 0.00, -15.00, '7406135040226', false, 3),
  ('7406135040264', 'VEEV NOW BLUEBERRY', 'Vapes', 850.00, 495.0000, 0.00, 0.00, '7406135040264', false, 5),
  ('7406135043166', 'VEEV NOW BLUEBERRY.8000.PUFFS', 'Vapes', 1200.00, 603.7300, 0.00, 0.00, '7406135043166', false, 6),
  ('7406135040240', 'VEEV NOW STRAWBERRY', 'Vapes', 850.00, 495.0000, 0.00, 0.00, '7406135040240', false, 7),
  ('7406135040233', 'VEEV NOW WATERMELO', 'Vapes', 850.00, 420.0000, 0.00, -13.00, '7406135040233', false, 8),
  ('7406135043111', 'VEEV NOW.BLUE MINT.8000,PUFFS', 'Vapes', 1200.00, 603.7300, 0.00, 0.00, '7406135043111', false, 9),
  ('7460951309509', 'ACETAMINOFEN', 'Farmacia, higiene y hogar', 10.00, 4.0000, 204.00, 204.00, '7460951309509', false, 1),
  ('7464030842260', 'ALGHO SINUS', 'Farmacia, higiene y hogar', 90.00, 43.4200, 51.00, 51.00, '7464030842260', false, 2),
  ('7464030842420', 'ALGHOS ULTRA', 'Farmacia, higiene y hogar', 75.00, 30.0000, 34.00, 34.00, '7464030842420', false, 3),
  ('011418386891', 'ALKA-SELTZER AZUL', 'Farmacia, higiene y hogar', 25.00, 16.0000, 1.00, 1.00, '011418386891', false, 4),
  ('011418462823', 'ALKA-SELTZER EXTREME BOOST', 'Farmacia, higiene y hogar', 70.00, 37.0000, 47.00, 47.00, '011418462823', false, 5),
  ('7460951317412', 'AMPICILINA 1000', 'Farmacia, higiene y hogar', 15.00, 7.9000, 58.00, 58.00, '7460951317412', false, 6),
  ('607766777841', 'BABY WIPES PRICE SMART', 'Farmacia, higiene y hogar', 350.00, 184.0000, 0.00, 0.00, '607766777841', false, 9),
  ('7468572200175', 'CUCHARAS', 'Farmacia, higiene y hogar', 50.00, 20.0000, 0.00, 0.00, '7468572200175', false, 11),
  ('7460951308069', 'DICLOFENAC-100', 'Farmacia, higiene y hogar', 15.00, 3.0000, 0.00, -40.00, '7460951308069', false, 12),
  ('7460951312387', 'DICLOFEX FORTE', 'Farmacia, higiene y hogar', 15.00, 6.5000, 0.00, -2.00, '7460951312387', false, 13),
  ('067981087970', 'DUREX AIR', 'Farmacia, higiene y hogar', 280.00, 157.9533, 7.00, 7.00, '067981087970', false, 15),
  ('302340995597', 'DUREX ALOE VERA', 'Farmacia, higiene y hogar', 860.00, 460.0500, 0.00, 0.00, '302340995597', false, 16),
  ('302340129008', 'DUREX EXTRA SENSITIVE', 'Farmacia, higiene y hogar', 280.00, 157.9533, 10.00, 10.00, '302340129008', false, 17),
  ('302340995993', 'DUREX INTENSE', 'Farmacia, higiene y hogar', 280.00, 157.9533, 0.00, 0.00, '302340995993', false, 18),
  ('302340096584', 'DUREX INTENSE SANSATION', 'Farmacia, higiene y hogar', 280.00, 157.9533, 9.00, 9.00, '302340096584', false, 19),
  ('302340302227', 'DUREX PLAY ALLURE', 'Farmacia, higiene y hogar', 1260.00, 761.2500, 0.00, 0.00, '302340302227', false, 20),
  ('302340300421', 'DUREX PLEASURE PACK', 'Farmacia, higiene y hogar', 260.00, 140.8000, 0.00, 0.00, '302340300421', false, 21),
  ('067981957525', 'DUREX PLEASURE RING', 'Farmacia, higiene y hogar', 700.00, 414.7500, 2.00, 2.00, '067981957525', false, 22),
  ('302340894555', 'DUREX REAL FEEL NON LATEX', 'Farmacia, higiene y hogar', 260.00, 140.8000, 6.00, 6.00, '302340894555', false, 23),
  ('302340090001', 'DUREX TROPICAL FLAVORS', 'Farmacia, higiene y hogar', 280.00, 157.9533, 6.00, 6.00, '302340090001', false, 24),
  ('302340300452', 'DUREX XXL EXTRA LARGE', 'Farmacia, higiene y hogar', 280.00, 157.9533, 8.00, 8.00, '302340300452', false, 25),
  ('302340995573', 'DUREXJUICY PLAY', 'Farmacia, higiene y hogar', 650.00, 372.0900, 1.00, 1.00, '302340995573', false, 26),
  ('736372551597', 'INTIMATE TEXTURIZADOS', 'Farmacia, higiene y hogar', 215.00, 120.0000, 3.00, 3.00, '736372551597', false, 27),
  ('736372551603', 'INTIMATE ULTRA SENSITIVO', 'Farmacia, higiene y hogar', 215.00, 120.0000, 0.00, 0.00, '736372551603', false, 28),
  ('2020', 'JALEA DEL AMOR', 'Farmacia, higiene y hogar', 500.00, 300.0000, 1.00, 1.00, null, false, 29),
  ('546513215611', 'MIEL DE AMOR PARA MUJER', 'Farmacia, higiene y hogar', 280.00, 166.6700, 20.00, 20.00, '546513215611', false, 32),
  ('546513215642', 'MIEL DEL AMOR', 'Farmacia, higiene y hogar', 280.00, 167.0000, 37.00, 37.00, '546513215642', false, 33),
  ('4444', 'NECTAR DEL AMOR', 'Farmacia, higiene y hogar', 100.00, 35.4100, 10.00, 10.00, null, false, 34),
  ('020909010009', 'NECTAR DEL AMOR', 'Farmacia, higiene y hogar', 100.00, 35.0000, 0.00, -10.00, '020909010009', false, 35),
  ('7466018672029', 'NEVERA FOAM 10L CON ASA', 'Farmacia, higiene y hogar', 550.00, 296.6100, 0.00, 0.00, '7466018672029', false, 36),
  ('7466018672036', 'NEVERA FOAM 20L CON ASA', 'Farmacia, higiene y hogar', 650.00, 364.4100, 0.00, -1.00, '7466018672036', false, 37),
  ('OMEPRAZOL 40.MG', 'OMEPRAZOL .40MG. NUEVO', 'Farmacia, higiene y hogar', 25.00, 6.0000, 148.00, 148.00, null, false, 43),
  ('7460951308397', 'OMEPRAZOL 40.MG', 'Farmacia, higiene y hogar', 25.00, 12.0000, 50.00, 50.00, '7460951308397', false, 44),
  ('18906143150147', 'OMEPRAZOL DE 20.M.G', 'Farmacia, higiene y hogar', 25.00, 3.0000, 153.00, 153.00, '18906143150147', false, 45),
  ('7468572207143', 'PLATOS LLANOS', 'Farmacia, higiene y hogar', 125.00, 60.0000, 8.00, 8.00, '7468572207143', false, 49),
  ('7468999184874', 'REFRIDOL PASTILLA', 'Farmacia, higiene y hogar', 40.00, 19.0000, 8.00, 8.00, '7468999184874', false, 50),
  ('7468999190639', 'RESFRIDOL PASTILLA', 'Farmacia, higiene y hogar', 25.00, 13.0000, 0.00, -9.00, '7468999190639', false, 51),
  ('7468999180463', 'RESFRIDOL TE ANTIGRIPAL 25SOBRE', 'Farmacia, higiene y hogar', 60.00, 31.0800, 0.00, -6.00, '7468999180463', false, 52),
  ('74410187', 'SAL ANDREWS 218G', 'Farmacia, higiene y hogar', 40.00, 14.0000, 49.00, 49.00, '74410187', false, 53),
  ('2019', 'SERVILLETA PAQUETE', 'Farmacia, higiene y hogar', 200.00, 105.9320, 0.00, -2.00, null, false, 54),
  ('7468355587653', 'SERVILLETA PQ.', 'Farmacia, higiene y hogar', 60.00, 25.0000, 20.00, 20.00, '7468355587653', false, 55),
  ('7465668558301', 'SILDENAFIL 100MG', 'Farmacia, higiene y hogar', 50.00, 8.8600, 11.00, 11.00, '7465668558301', false, 56),
  ('7460951313254', 'SILDENAFIL CITRATO DF 100.M.G', 'Farmacia, higiene y hogar', 75.00, 25.0000, 91.00, 91.00, '7460951313254', false, 57),
  ('6935011610174', 'SUPER 100 NEW 24 ROLLO', 'Farmacia, higiene y hogar', 95.00, 733.0000, 0.00, -1.00, '6935011610174', false, 62),
  ('7464405157043', 'TOALLA MARON MICRODRY', 'Farmacia, higiene y hogar', 60.00, 35.5900, 27.00, 27.00, '7464405157043', false, 63),
  ('75916565', 'VAPORUB 12G', 'Farmacia, higiene y hogar', 55.00, 39.1100, 0.00, -1.00, '75916565', false, 64),
  ('7460234550024', 'VASO #7', 'Farmacia, higiene y hogar', 80.00, 25.0000, 0.00, -1.00, '7460234550024', false, 65),
  ('7460234530057', 'VASOS FOAM #16', 'Farmacia, higiene y hogar', 225.00, 85.0000, 0.00, 0.00, '7460234530057', false, 66),
  ('7460834360801', 'VASOS PLASTICOS 7 ONZ', 'Farmacia, higiene y hogar', 70.00, 30.5100, 0.00, 0.00, '7460834360801', false, 67),
  ('7451079003691', 'WINASORB GRIPE MULTI-SINTOMAS', 'Farmacia, higiene y hogar', 60.00, 36.0000, 10.00, 10.00, '7451079003691', false, 69),
  ('7451079003554', 'WINASORB ULTRA', 'Farmacia, higiene y hogar', 55.00, 24.7500, 66.00, 66.00, '7451079003554', false, 70),
  ('7451079003202', 'WINASORD MULTI-SINTOMAS', 'Farmacia, higiene y hogar', 25.00, 12.9100, 0.00, -4.00, '7451079003202', false, 71),
  ('7451079003417', 'WINASORD ULTRA', 'Farmacia, higiene y hogar', 30.00, 18.1700, 0.00, -32.00, '7451079003417', false, 72),
  ('2000000328676', 'AGUA DESTILADA ATLAN 32.OZ', 'Automotriz', 40.00, 16.0000, 0.00, -2.00, '2000000328676', false, 1),
  ('4718403046636', 'AMBIENTADOR HOJA GOLDEN STATE', 'Automotriz', 195.00, 117.8000, 8.00, 8.00, '4718403046636', false, 10),
  ('4718403046643', 'AMBIENTADOR HOJA ICE', 'Automotriz', 195.00, 117.8000, 0.00, 0.00, '4718403046643', false, 11),
  ('4718403046629', 'AMBIENTADOR HOJA LAVANDA', 'Automotriz', 195.00, 117.8000, 2.00, 2.00, '4718403046629', false, 12),
  ('4718403052132', 'AROMATE AIRE LAVENDER', 'Automotriz', 310.00, 185.5900, 1.00, 1.00, '4718403052132', false, 16),
  ('4718403043505', 'AROMATE AIRE VAINILLA', 'Automotriz', 310.00, 185.5900, 1.00, 1.00, '4718403043505', false, 17),
  ('4718403041150', 'AROMATE LUXY CHERRY', 'Automotriz', 340.00, 201.6900, 4.00, 4.00, '4718403041150', false, 18),
  ('4718403041167', 'AROMATE LUXY SPORTY', 'Automotriz', 340.00, 201.6900, 9.00, 9.00, '4718403041167', false, 19),
  ('4718403041327', 'AROMATE LUXY STRAWBERRY', 'Automotriz', 340.00, 201.6900, 5.00, 5.00, '4718403041327', false, 20),
  ('4718403041174', 'AROMATE WILD BERRY', 'Automotriz', 340.00, 201.6900, 1.00, 1.00, '4718403041174', false, 21),
  ('4718403052194', 'AROMATE WOODEN GOLDEN 7 ML', 'Automotriz', 310.00, 185.5900, 0.00, 0.00, '4718403052194', false, 22),
  ('4718403052187', 'AROMATE WOODEN GOLDEN STATE', 'Automotriz', 310.00, 185.5900, 0.00, -1.00, '4718403052187', false, 23),
  ('55', 'CORREA ROULUNDS 1A1370', 'Automotriz', 90.00, 61.0000, 0.00, -2.00, null, false, 25),
  ('6944259810529', 'GETSU SILICONE LIMON', 'Automotriz', 150.00, null, 0.00, -1.00, '6944259810529', false, 35),
  ('74630117320003', 'LAFA TAPA DE RADIADOR', 'Automotriz', 100.00, 44.0000, 0.00, -1.00, '74630117320003', false, 57),
  ('1', 'LANILLA P/CRISTALES', 'Automotriz', 65.00, 40.0000, 0.00, -2.00, null, false, 58),
  ('7461011100548', 'LIMPIA CRISTAL WINDSHIELD WASHER', 'Automotriz', 300.00, 180.0000, 6.00, 6.00, '7461011100548', false, 60),
  ('15', 'LUBE FILTER LP-2256', 'Automotriz', 140.00, 10.0000, 45.00, 45.00, null, false, 64),
  ('2', 'MOTOR OIL 2T', 'Automotriz', 70.00, 25.0000, 0.00, -4.00, null, false, 65),
  ('030644160099', 'PIEDRA AROMA SAPIN / PINO', 'Automotriz', 125.00, 66.0000, 0.00, -1.00, '030644160099', false, 68),
  ('076171170378', 'PINITO ANTI TABACO', 'Automotriz', 100.00, 55.9300, 1.00, 1.00, '076171170378', false, 69),
  ('076171105745', 'PINITO AZUL', 'Automotriz', 100.00, 57.6300, 29.00, 29.00, '076171105745', false, 70),
  ('076171101556', 'PINITO BLACK ICE', 'Automotriz', 100.00, 57.6300, 3.00, 3.00, '076171101556', false, 71),
  ('076171103383', 'PINITO CINNAMON APPLE', 'Automotriz', 100.00, 57.6300, 21.00, 21.00, '076171103383', false, 72);

-- filas 1001–1043
insert into _p007f2 (codigo, name, categoria, price, cost, qty, qty_listado, barcode, is_bev, posicion) values
  ('076171103178', 'PINITO COCONUT', 'Automotriz', 100.00, 57.6300, 33.00, 33.00, '076171103178', false, 73),
  ('076171102102', 'PINITO GOLD', 'Automotriz', 100.00, 57.6300, 28.00, 28.00, '076171102102', false, 74),
  ('076171102904', 'PINITO LEATHER', 'Automotriz', 100.00, 57.6300, 44.00, 44.00, '076171102904', false, 75),
  ('076171101891', 'PINITO NEW CAR SCENT', 'Automotriz', 100.00, 57.6300, 66.00, 66.00, '076171101891', false, 76),
  ('076171103123', 'PINITO STRAWBERRY', 'Automotriz', 100.00, 57.6300, 22.00, 22.00, '076171103123', false, 77),
  ('076171101051', 'PINITO VANILLAROMA', 'Automotriz', 100.00, 57.6300, 41.00, 41.00, '076171101051', false, 78),
  ('RM.2', 'ARREGLO DE ANDEJA PARA MAMA #2', 'Souvenirs y regalos', 2200.00, 1125.0000, 1.00, 1.00, null, false, 1),
  ('RM.1', 'ARREGLO TIPO BANDEJA #1', 'Souvenirs y regalos', 1800.00, 1050.0000, 0.00, 0.00, null, false, 2),
  ('202614', 'BADEJAS DE SAN VALETIN', 'Souvenirs y regalos', 1700.00, 1010.0000, 0.00, 0.00, null, false, 3),
  ('200214', 'BANDEJA DE SAN VALENTIN', 'Souvenirs y regalos', 2700.00, 1780.0000, 1.00, 1.00, null, false, 4),
  ('1222', 'DOMINOS DOMINICANOS', 'Souvenirs y regalos', 650.00, 375.0000, 2.00, 2.00, null, false, 5),
  ('1108', 'DURAG REP. DOM.', 'Souvenirs y regalos', 245.00, 100.0000, 9.00, 9.00, null, false, 6),
  ('1019', 'GORRAS EST DOMINICANO', 'Souvenirs y regalos', 450.00, 210.0000, 13.00, 13.00, null, false, 7),
  ('7453089263393', 'GORROS DE PLAYAS PARA DAMAS', 'Souvenirs y regalos', 1285.00, 750.0000, 2.00, 2.00, '7453089263393', false, 8),
  ('2514821000333', 'GORROS DE PLAYAS PARA DAMAS', 'Souvenirs y regalos', 1285.00, 750.0000, 2.00, 2.00, '2514821000333', false, 9),
  ('2514821000319', 'GORROS DE PLAYAS PARA DAMAS', 'Souvenirs y regalos', 1285.00, 750.0000, 0.00, 0.00, '2514821000319', false, 10),
  ('2312124242418', 'GORROS PEQUEÑOS DE PLAYAS', 'Souvenirs y regalos', 825.00, 475.0000, 5.00, 5.00, '2312124242418', false, 11),
  ('1322', 'GUIRA NIQUEL #3..(10X12)', 'Souvenirs y regalos', 675.00, 350.0000, 2.00, 2.00, null, false, 12),
  ('1327', 'GUIRAS 2.9*9.', 'Souvenirs y regalos', 375.00, 85.0000, 3.00, 3.00, null, false, 13),
  ('1383', 'MAGNETOS ESTILOS DOMINICANOS', 'Souvenirs y regalos', 200.00, 70.0000, 11.00, 11.00, null, false, 14),
  ('1283', 'MAMAJUANA BEEPER EN CUERO', 'Souvenirs y regalos', 265.00, 100.0000, 7.00, 7.00, null, false, 15),
  ('1282', 'MAMAJUANA CHATA EN CUERO', 'Souvenirs y regalos', 325.00, 135.0000, 6.00, 6.00, null, false, 16),
  ('1281', 'MAMAJUANA LITRO EN CUERO', 'Souvenirs y regalos', 475.00, 170.0000, 5.00, 5.00, null, false, 17),
  ('1285', 'MARACAS FORCLORICAS', 'Souvenirs y regalos', 425.00, 145.0000, 4.00, 4.00, null, false, 18),
  ('1610', 'MU;ECA DE PORCELANA ESPECIAL', 'Souvenirs y regalos', 295.00, 160.0000, 12.00, 12.00, null, false, 19),
  ('1453', 'MUÑECAS DE BARRO', 'Souvenirs y regalos', 225.00, 100.0000, 0.00, -5.00, null, false, 20),
  ('03', 'POSUELOS DE SAN VALENTIN', 'Souvenirs y regalos', 275.00, 180.0000, 0.00, -6.00, null, false, 21),
  ('2108', 'POSUELOS DOMINICANOS', 'Souvenirs y regalos', 225.00, 65.0000, 6.00, 6.00, null, false, 22),
  ('1897', 'TAMBORA EST DOMINICANO', 'Souvenirs y regalos', 480.00, 195.0000, 2.00, 2.00, null, false, 23),
  ('2206125508010', 'TAZA CON CUCHAS ESTILO BANDERA', 'Souvenirs y regalos', 475.00, 225.0000, 0.00, 0.00, '2206125508010', false, 24),
  ('1185', 'TAZA CON MAPA DE R.D', 'Souvenirs y regalos', 235.00, 75.0000, 4.00, 4.00, null, false, 25),
  ('02', 'TAZAS CON CHOCOLATES PARA MAMA', 'Souvenirs y regalos', 380.00, 225.0000, 1.00, 1.00, null, false, 26),
  ('699038033078', 'TERMO DECORADO', 'Souvenirs y regalos', 185.00, 144.0800, 0.00, -1.00, '699038033078', false, 27),
  ('4402270523023', 'VASO TERMICO CON AZA REP. DOM', 'Souvenirs y regalos', 675.00, 255.0000, 0.00, 0.00, '4402270523023', false, 28),
  ('1307', 'VASO TERMICO REP. DOM', 'Souvenirs y regalos', 675.00, 290.0000, 5.00, 5.00, null, false, 29),
  ('677916825197', 'CHOPIN PARA VINO', 'Misceláneos', 100.00, 23.0000, 0.00, -1.00, '677916825197', false, 4),
  ('1080', 'CORDON LLAVERO BANDERA R.D', 'Misceláneos', 150.00, 65.0000, 1.00, 1.00, null, false, 8),
  ('4402026022831', 'DESTAPADOR ENFOMA DE CERVEZA', 'Misceláneos', 325.00, 65.0000, 7.00, 7.00, '4402026022831', false, 9),
  ('4402270709014', 'LLAVERO DE BASEBOLL', 'Misceláneos', 225.00, 65.0000, 0.00, -4.00, '4402270709014', false, 12),
  ('1914', 'LLAVERO METAL CM429', 'Misceláneos', 200.00, 55.0000, 28.00, 28.00, null, false, 13),
  ('1131', 'LLAVERO METAL DESTAPADOR BANDERA', 'Misceláneos', 150.00, 55.0000, 14.00, 14.00, null, false, 14),
  ('309', 'ORANGE TARJETA $ 150.00', 'Misceláneos', 150.00, 141.0000, 0.00, -1.00, null, false, 15),
  ('6971268320114', 'THERMO PEQUEÑO', 'Misceláneos', 455.00, 275.0000, 2.00, 2.00, '6971268320114', false, 24);

-- Posición nueva de los productos de la fase 1 (orden alfabético con los nuevos).
create temp table _p007f2_pos1 (
  codigo    text primary key,
  categoria text not null,
  posicion  int  not null
);

insert into _p007f2_pos1 (codigo, categoria, posicion) values
  ('8594003352331', 'Cervezas', 6),
  ('8594003351815', 'Cervezas', 7),
  ('8594003352614', 'Cervezas', 8),
  ('8594003352522', 'Cervezas', 9),
  ('8412598005862', 'Cervezas', 10),
  ('8500001270089', 'Cervezas', 16),
  ('8690582723200', 'Cervezas', 17),
  ('8690582722203', 'Cervezas', 18),
  ('87120103', 'Cervezas', 21),
  ('8714800001793', 'Cervezas', 22),
  ('8423453910535', 'Cervezas', 24),
  ('8423453910566', 'Cervezas', 25),
  ('8412598005831', 'Cervezas', 43),
  ('8712000030582', 'Cervezas', 44),
  ('8712000900045', 'Cervezas', 45),
  ('8714800014212', 'Cervezas', 48),
  ('8714800007580', 'Cervezas', 49),
  ('8714800031127', 'Cervezas', 50),
  ('851621000043', 'Cervezas', 51),
  ('8411327001076', 'Cervezas', 54),
  ('8411327003308', 'Cervezas', 55),
  ('8411327008419', 'Cervezas', 56),
  ('8411327001717', 'Cervezas', 57),
  ('8411327001960', 'Cervezas', 58),
  ('8001435310018', 'Cervezas', 66),
  ('8423453909980', 'Cervezas', 67),
  ('8594006931090', 'Cervezas', 82),
  ('8594006931328', 'Cervezas', 83),
  ('8712000051945', 'Cervezas', 84),
  ('876529000476', 'Cervezas', 85),
  ('876529000421', 'Cervezas', 86),
  ('84692204045', 'Licores', 3),
  ('8004747005535', 'Licores', 4),
  ('796020140504', 'Licores', 11),
  ('796020100508', 'Licores', 13),
  ('804884', 'Licores', 16),
  ('8414771852881', 'Licores', 17),
  ('8000040002509', 'Licores', 30),
  ('8410161711257', 'Licores', 31),
  ('796020010029', 'Licores', 32),
  ('796020010128', 'Licores', 33),
  ('8000020000365', 'Licores', 39),
  ('8000020000396', 'Licores', 40),
  ('796020600022', 'Licores', 41),
  ('796020600008', 'Licores', 42),
  ('7640171032054', 'Licores', 43),
  ('796020100515', 'Licores', 46),
  ('8410414000466', 'Licores', 47),
  ('8410557900203', 'Licores', 55),
  ('8414771853208', 'Licores', 56),
  ('8411705100230', 'Licores', 69),
  ('8411705100223', 'Licores', 70),
  ('8411705100216', 'Licores', 71),
  ('811538010801', 'Licores', 82),
  ('860012986828', 'Licores', 83),
  ('860012986811', 'Licores', 84),
  ('860012986835', 'Licores', 85),
  ('8005713144258', 'Licores', 90),
  ('888', 'Licores', 96),
  ('7640171034058', 'Licores', 104),
  ('8011822008220', 'Vinos y espumantes', 7),
  ('8437003674976', 'Vinos y espumantes', 9),
  ('8436006393006', 'Vinos y espumantes', 10),
  ('7804330312108', 'Vinos y espumantes', 11),
  ('854620', 'Vinos y espumantes', 14),
  ('8003030008819', 'Vinos y espumantes', 17),
  ('8003030008826', 'Vinos y espumantes', 18),
  ('7804320303178', 'Vinos y espumantes', 19),
  ('7804320985633', 'Vinos y espumantes', 20),
  ('7804320301174', 'Vinos y espumantes', 21),
  ('7804320510170', 'Vinos y espumantes', 22),
  ('8420209032510', 'Vinos y espumantes', 23),
  ('8420209039007', 'Vinos y espumantes', 24),
  ('8420209032527', 'Vinos y espumantes', 25),
  ('8008513064016', 'Vinos y espumantes', 26),
  ('7804330004614', 'Vinos y espumantes', 27),
  ('7804320046044', 'Vinos y espumantes', 28),
  ('7804320688480', 'Vinos y espumantes', 29),
  ('7804320384382', 'Vinos y espumantes', 30),
  ('8012769232037', 'Vinos y espumantes', 35),
  ('7804320520162', 'Vinos y espumantes', 36),
  ('7804320523958', 'Vinos y espumantes', 37),
  ('7804320574707', 'Vinos y espumantes', 38),
  ('8425021000068', 'Vinos y espumantes', 40),
  ('8425021000051', 'Vinos y espumantes', 41),
  ('8425021000075', 'Vinos y espumantes', 42),
  ('7804345003145', 'Vinos y espumantes', 44),
  ('7804345001882', 'Vinos y espumantes', 45),
  ('7804320628165', 'Vinos y espumantes', 46),
  ('7804320559001', 'Vinos y espumantes', 47),
  ('7804320642277', 'Vinos y espumantes', 48),
  ('7804320706009', 'Vinos y espumantes', 49),
  ('7804320483115', 'Vinos y espumantes', 50),
  ('7804320556000', 'Vinos y espumantes', 51),
  ('7804320269160', 'Vinos y espumantes', 52),
  ('7804320626994', 'Vinos y espumantes', 53),
  ('7804300010645', 'Vinos y espumantes', 54),
  ('7804300010638', 'Vinos y espumantes', 55),
  ('7804300120603', 'Vinos y espumantes', 56),
  ('7804300123697', 'Vinos y espumantes', 57),
  ('8414606856534', 'Vinos y espumantes', 58),
  ('8437007129984', 'Vinos y espumantes', 59),
  ('8410351000000', 'Vinos y espumantes', 60),
  ('8003030993177', 'Vinos y espumantes', 61),
  ('8011822009975', 'Vinos y espumantes', 64),
  ('8411079501930', 'Vinos y espumantes', 67),
  ('8411079381037', 'Vinos y espumantes', 68),
  ('8410869450014', 'Vinos y espumantes', 69),
  ('8410869451240', 'Vinos y espumantes', 71),
  ('8410866430019', 'Vinos y espumantes', 72),
  ('8410866430477', 'Vinos y espumantes', 73),
  ('8001540002228', 'Vinos y espumantes', 74),
  ('7804330121205', 'Vinos y espumantes', 75),
  ('8414771620022', 'Vinos y espumantes', 76),
  ('8412424325225', 'Vinos y espumantes', 77),
  ('7804449104014', 'Vinos y espumantes', 78),
  ('7804449104021', 'Vinos y espumantes', 79),
  ('7804449103017', 'Vinos y espumantes', 80),
  ('7804449103024', 'Vinos y espumantes', 81),
  ('8414542100104', 'Vinos y espumantes', 82),
  ('7804320485515', 'Vinos y espumantes', 83),
  ('8437008952147', 'Vinos y espumantes', 84),
  ('8000428026257', 'Vinos y espumantes', 85),
  ('8420342001039', 'Vinos y espumantes', 86),
  ('8420342001022', 'Vinos y espumantes', 87),
  ('8420342002012', 'Vinos y espumantes', 88),
  ('8420342203013', 'Vinos y espumantes', 89),
  ('8420209040706', 'Vinos y espumantes', 90),
  ('80516130545', 'Vinos y espumantes', 91),
  ('7804350596366', 'Vinos y espumantes', 92),
  ('7804350600148', 'Vinos y espumantes', 93),
  ('7804350596335', 'Vinos y espumantes', 94),
  ('7804350600391', 'Vinos y espumantes', 95),
  ('7804350701364', 'Vinos y espumantes', 96),
  ('7804350174700', 'Vinos y espumantes', 97),
  ('7804350600285', 'Vinos y espumantes', 98),
  ('7804350596342', 'Vinos y espumantes', 99),
  ('7804350008661', 'Vinos y espumantes', 100),
  ('7804350600384', 'Vinos y espumantes', 101),
  ('7804350701661', 'Vinos y espumantes', 102),
  ('7804350600353', 'Vinos y espumantes', 103),
  ('7804350000054', 'Vinos y espumantes', 104),
  ('7804350000061', 'Vinos y espumantes', 105),
  ('7804350596359', 'Vinos y espumantes', 106),
  ('7804350600070', 'Vinos y espumantes', 107),
  ('7804350596328', 'Vinos y espumantes', 108),
  ('7804350600155', 'Vinos y espumantes', 109),
  ('7804350000528', 'Vinos y espumantes', 110),
  ('784350600391', 'Vinos y espumantes', 111),
  ('7804350600360', 'Vinos y espumantes', 112),
  ('7804330983445', 'Vinos y espumantes', 113),
  ('7804330983438', 'Vinos y espumantes', 114),
  ('7804330321209', 'Vinos y espumantes', 115),
  ('7804330311101', 'Vinos y espumantes', 116),
  ('7804330351206', 'Vinos y espumantes', 117),
  ('7804330111107', 'Vinos y espumantes', 118),
  ('7804330341108', 'Vinos y espumantes', 119),
  ('7804330221202', 'Vinos y espumantes', 120),
  ('7804330211104', 'Vinos y espumantes', 121),
  ('7804330001835', 'Vinos y espumantes', 122),
  ('7804330212101', 'Vinos y espumantes', 123),
  ('7804330211203', 'Vinos y espumantes', 124),
  ('7804330361106', 'Vinos y espumantes', 125),
  ('7804330322206', 'Vinos y espumantes', 126),
  ('7804330001088', 'Vinos y espumantes', 127),
  ('7804330006724', 'Vinos y espumantes', 128),
  ('7804330006717', 'Vinos y espumantes', 129),
  ('8004385032207', 'Vinos y espumantes', 130),
  ('8410428330047', 'Vinos y espumantes', 131),
  ('8411079391012', 'Vinos y espumantes', 132),
  ('8413481014206', 'Vinos y espumantes', 133),
  ('8410635004014', 'Vinos y espumantes', 134),
  ('8410635001013', 'Vinos y espumantes', 135),
  ('8011822007032', 'Vinos y espumantes', 136),
  ('8011822009036', 'Vinos y espumantes', 137),
  ('8008513003756', 'Vinos y espumantes', 138),
  ('8008513008058', 'Vinos y espumantes', 139),
  ('8008513008485', 'Vinos y espumantes', 140),
  ('8003030991418', 'Vinos y espumantes', 141),
  ('8437015144115', 'Vinos y espumantes', 142),
  ('8437015144306', 'Vinos y espumantes', 143),
  ('8410702010344', 'Vinos y espumantes', 145),
  ('8410702010399', 'Vinos y espumantes', 146),
  ('8424718113111', 'Vinos y espumantes', 147),
  ('8427894026503', 'Vinos y espumantes', 148),
  ('8427894026497', 'Vinos y espumantes', 149),
  ('8427021000352', 'Vinos y espumantes', 150),
  ('8413004050117', 'Vinos y espumantes', 151),
  ('8437007129953', 'Vinos y espumantes', 152),
  ('8437007129939', 'Vinos y espumantes', 153),
  ('8004385030395', 'Vinos y espumantes', 154),
  ('796020310501', 'Vinos y espumantes', 155),
  ('8410388003531', 'Vinos y espumantes', 156),
  ('7804320288826', 'Vinos y espumantes', 157),
  ('7804320214085', 'Vinos y espumantes', 158),
  ('818838009818', 'Vinos y espumantes', 160),
  ('818838009825', 'Vinos y espumantes', 161),
  ('8420209028520', 'Vinos y espumantes', 163),
  ('8420209028506', 'Vinos y espumantes', 164),
  ('8420209028537', 'Vinos y espumantes', 165),
  ('8420209028513', 'Vinos y espumantes', 166),
  ('7804320169699', 'Vinos y espumantes', 167),
  ('7804320063010', 'Vinos y espumantes', 168),
  ('839743001483', 'Vinos y espumantes', 169),
  ('764009045577', 'Premix y cócteles', 1),
  ('764009024497', 'Premix y cócteles', 2),
  ('764009011671', 'Premix y cócteles', 3),
  ('764009047984', 'Premix y cócteles', 4),
  ('850035474082', 'Premix y cócteles', 6),
  ('850035474037', 'Premix y cócteles', 7),
  ('850035474068', 'Premix y cócteles', 8),
  ('850035474051', 'Premix y cócteles', 9),
  ('850035474464', 'Premix y cócteles', 10),
  ('850035474105', 'Premix y cócteles', 11),
  ('850035474006', 'Premix y cócteles', 12),
  ('849806002319', 'Premix y cócteles', 13),
  ('849806001756', 'Premix y cócteles', 14),
  ('849806001855', 'Premix y cócteles', 15),
  ('849806003859', 'Premix y cócteles', 16),
  ('849806004962', 'Premix y cócteles', 17),
  ('849806001220', 'Premix y cócteles', 18),
  ('849806002746', 'Premix y cócteles', 19),
  ('849806001206', 'Premix y cócteles', 20),
  ('849806005754', 'Premix y cócteles', 21),
  ('7898605253012', 'Premix y cócteles', 23),
  ('780380', 'Refrescos y energizantes', 1),
  ('830207000707', 'Refrescos y energizantes', 16),
  ('830207010706', 'Refrescos y energizantes', 17),
  ('830207000301', 'Refrescos y energizantes', 18),
  ('815934000107', 'Refrescos y energizantes', 23),
  ('789120', 'Refrescos y energizantes', 32),
  ('783150', 'Refrescos y energizantes', 33),
  ('790330050508', 'Refrescos y energizantes', 40),
  ('8053626292788', 'Refrescos y energizantes', 58),
  ('7702090048643', 'Refrescos y energizantes', 59),
  ('784000', 'Refrescos y energizantes', 61),
  ('831384000504', 'Refrescos y energizantes', 63),
  ('7702354251673', 'Refrescos y energizantes', 73),
  ('7702354251666', 'Refrescos y energizantes', 74),
  ('850003560410', 'Refrescos y energizantes', 75),
  ('850003560441', 'Refrescos y energizantes', 76),
  ('850003560458', 'Refrescos y energizantes', 77),
  ('9002490212148', 'Refrescos y energizantes', 78),
  ('9002490291709', 'Refrescos y energizantes', 79),
  ('9002490267544', 'Refrescos y energizantes', 80),
  ('9002490204006', 'Refrescos y energizantes', 81),
  ('9002490266288', 'Refrescos y energizantes', 82),
  ('9002490206710', 'Refrescos y energizantes', 83),
  ('9002490268657', 'Refrescos y energizantes', 84),
  ('84233299812184', 'Refrescos y energizantes', 97),
  ('78250004321', 'Refrescos y energizantes', 101),
  ('782740', 'Refrescos y energizantes', 113),
  ('782850', 'Refrescos y energizantes', 115),
  ('7702354253776', 'Refrescos y energizantes', 117),
  ('7702354253769', 'Refrescos y energizantes', 118),
  ('859710000011', 'Refrescos y energizantes', 119),
  ('859710000004', 'Refrescos y energizantes', 120),
  ('893504860702', 'Jugos, tés y lácteos', 2),
  ('893504860696', 'Jugos, tés y lácteos', 5),
  ('8809125063011', 'Jugos, tés y lácteos', 6),
  ('884394007391', 'Jugos, tés y lácteos', 7),
  ('884394007285', 'Jugos, tés y lácteos', 8),
  ('884394007377', 'Jugos, tés y lácteos', 9),
  ('8936020049793', 'Jugos, tés y lácteos', 12),
  ('8936020049786', 'Jugos, tés y lácteos', 13),
  ('790330008080', 'Jugos, tés y lácteos', 14),
  ('790330008028', 'Jugos, tés y lácteos', 15),
  ('790330004587', 'Jugos, tés y lácteos', 18),
  ('790330002323', 'Jugos, tés y lácteos', 20),
  ('884394000538', 'Jugos, tés y lácteos', 22),
  ('7703186031303', 'Jugos, tés y lácteos', 27),
  ('8710428019509', 'Jugos, tés y lácteos', 28),
  ('8410635024029', 'Jugos, tés y lácteos', 29),
  ('7707362397672', 'Jugos, tés y lácteos', 33),
  ('7709990350463', 'Jugos, tés y lácteos', 34),
  ('7707362390079', 'Jugos, tés y lácteos', 35),
  ('7709990350470', 'Jugos, tés y lácteos', 36),
  ('790330021461', 'Jugos, tés y lácteos', 37),
  ('790330021454', 'Jugos, tés y lácteos', 38),
  ('8687', 'Jugos, tés y lácteos', 41),
  ('790330002118', 'Jugos, tés y lácteos', 42),
  ('790330021584', 'Jugos, tés y lácteos', 43),
  ('87328431846', 'Jugos, tés y lácteos', 46),
  ('876063005951', 'Jugos, tés y lácteos', 50),
  ('876063005968', 'Jugos, tés y lácteos', 51),
  ('876063002035', 'Jugos, tés y lácteos', 52),
  ('876063002011', 'Jugos, tés y lácteos', 53),
  ('876063002042', 'Jugos, tés y lácteos', 54),
  ('876063002028', 'Jugos, tés y lácteos', 55),
  ('790330005096', 'Jugos, tés y lácteos', 56),
  ('790330050676', 'Jugos, tés y lácteos', 57),
  ('786273040041', 'Jugos, tés y lácteos', 59),
  ('786273040034', 'Jugos, tés y lácteos', 60),
  ('8710428020215', 'Jugos, tés y lácteos', 61),
  ('888849008100', 'Jugos, tés y lácteos', 68),
  ('888849014460', 'Jugos, tés y lácteos', 69),
  ('888849008117', 'Jugos, tés y lácteos', 70),
  ('790330050614', 'Jugos, tés y lácteos', 71),
  ('790330021256', 'Jugos, tés y lácteos', 72),
  ('790330021249', 'Jugos, tés y lácteos', 73);

insert into _p007f2_pos1 (codigo, categoria, posicion) values
  ('790330030029', 'Jugos, tés y lácteos', 74),
  ('790330021263', 'Jugos, tés y lácteos', 75),
  ('790330050669', 'Jugos, tés y lácteos', 76),
  ('790330021270', 'Jugos, tés y lácteos', 77),
  ('790330050058', 'Jugos, tés y lácteos', 78),
  ('79033050072', 'Jugos, tés y lácteos', 79),
  ('790330050645', 'Jugos, tés y lácteos', 80),
  ('790330005003', 'Jugos, tés y lácteos', 81),
  ('790330021188', 'Jugos, tés y lácteos', 82),
  ('790330021171', 'Jugos, tés y lácteos', 83),
  ('790330005300', 'Jugos, tés y lácteos', 84),
  ('790330050621', 'Jugos, tés y lácteos', 85),
  ('790330021164', 'Jugos, tés y lácteos', 86),
  ('790330050386', 'Jugos, tés y lácteos', 87),
  ('790330030012', 'Jugos, tés y lácteos', 88),
  ('790330050072', 'Jugos, tés y lácteos', 89),
  ('790330021973', 'Jugos, tés y lácteos', 90),
  ('790330021126', 'Jugos, tés y lácteos', 91),
  ('790330021003', 'Jugos, tés y lácteos', 92),
  ('790330021225', 'Jugos, tés y lácteos', 93),
  ('790330021089', 'Jugos, tés y lácteos', 94),
  ('790330021133', 'Jugos, tés y lácteos', 95),
  ('790330021119', 'Jugos, tés y lácteos', 96),
  ('790330021072', 'Jugos, tés y lácteos', 97),
  ('790330004655', 'Jugos, tés y lácteos', 99),
  ('790330004600', 'Jugos, tés y lácteos', 100),
  ('790330004617', 'Jugos, tés y lácteos', 101),
  ('790330005133', 'Jugos, tés y lácteos', 102),
  ('790330021805', 'Jugos, tés y lácteos', 103),
  ('790330051109', 'Jugos, tés y lácteos', 104),
  ('790330005171', 'Jugos, tés y lácteos', 105),
  ('790330021027', 'Jugos, tés y lácteos', 106),
  ('790330021898', 'Jugos, tés y lácteos', 107),
  ('790330021140', 'Jugos, tés y lácteos', 108),
  ('790330021157', 'Jugos, tés y lácteos', 109),
  ('790330050065', 'Jugos, tés y lácteos', 110),
  ('790330050607', 'Jugos, tés y lácteos', 111),
  ('790330050140', 'Jugos, tés y lácteos', 112),
  ('790330050133', 'Jugos, tés y lácteos', 113),
  ('790330050041', 'Jugos, tés y lácteos', 114),
  ('790330050034', 'Jugos, tés y lácteos', 115),
  ('790330021928', 'Jugos, tés y lácteos', 116),
  ('790330021935', 'Jugos, tés y lácteos', 117),
  ('790330021881', 'Jugos, tés y lácteos', 118),
  ('790330021515', 'Jugos, tés y lácteos', 119),
  ('790330021232', 'Jugos, tés y lácteos', 120),
  ('790330050447', 'Jugos, tés y lácteos', 121),
  ('790330050652', 'Jugos, tés y lácteos', 122),
  ('790330005324', 'Jugos, tés y lácteos', 123),
  ('790330022017', 'Jugos, tés y lácteos', 124),
  ('790330050638', 'Jugos, tés y lácteos', 125),
  ('790330021294', 'Jugos, tés y lácteos', 126),
  ('790330022024', 'Jugos, tés y lácteos', 127),
  ('790330014333', 'Jugos, tés y lácteos', 130),
  ('790330006741', 'Jugos, tés y lácteos', 131),
  ('790330006703', 'Jugos, tés y lácteos', 132),
  ('790330006789', 'Jugos, tés y lácteos', 133),
  ('777', 'Jugos, tés y lácteos', 139),
  ('796025000025', 'Aguas', 3),
  ('796025000483', 'Aguas', 4),
  ('8020141152002', 'Aguas', 7),
  ('8003430100656', 'Aguas', 8),
  ('8003430100311', 'Aguas', 9),
  ('8002270015991', 'Aguas', 13),
  ('8020141214007', 'Aguas', 14),
  ('8020141204008', 'Aguas', 15),
  ('765066747367', 'Aguas', 16),
  ('893919001301', 'Aguas', 25),
  ('893919001608', 'Aguas', 29),
  ('8004192102209', 'Aguas', 30),
  ('8002270136559', 'Aguas', 35),
  ('8002270536472', 'Aguas', 36),
  ('8002270000188', 'Aguas', 37),
  ('8020141101307', 'Aguas', 38),
  ('8007601001049', 'Aguas', 39),
  ('7862126331641', 'Snacks salados', 9),
  ('853240003023', 'Snacks salados', 15),
  ('853240003009', 'Snacks salados', 16),
  ('853240003153', 'Snacks salados', 17),
  ('853240003016', 'Snacks salados', 18),
  ('7750168001687', 'Snacks salados', 52),
  ('7622300375713', 'Snacks salados', 53),
  ('7622300051327', 'Snacks salados', 54),
  ('7622210101273', 'Snacks salados', 55),
  ('7622210101396', 'Snacks salados', 56),
  ('894185000852', 'Snacks salados', 61),
  ('894185000494', 'Snacks salados', 62),
  ('852109004034', 'Snacks salados', 73),
  ('852109004003', 'Snacks salados', 74),
  ('853240003238', 'Snacks salados', 75),
  ('853240003214', 'Snacks salados', 76),
  ('853240003221', 'Snacks salados', 77),
  ('811387010281', 'Snacks salados', 78),
  ('811387010274', 'Snacks salados', 79),
  ('811387010298', 'Snacks salados', 80),
  ('894185000487', 'Snacks salados', 82),
  ('850126007045', 'Snacks salados', 88),
  ('850126007090', 'Snacks salados', 89),
  ('765857349893', 'Snacks salados', 97),
  ('765857349909', 'Snacks salados', 98),
  ('856414002174', 'Snacks salados', 114),
  ('856414001023', 'Snacks salados', 115),
  ('7798151950468', 'Snacks salados', 118),
  ('856414001078', 'Snacks salados', 123),
  ('856414001085', 'Snacks salados', 124),
  ('856414001139', 'Snacks salados', 125),
  ('873617005245', 'Snacks salados', 133),
  ('873617001759', 'Snacks salados', 134),
  ('873617000165', 'Snacks salados', 135),
  ('8801043008525', 'Snacks salados', 136),
  ('850000725287', 'Snacks salados', 137),
  ('7750168001694', 'Snacks salados', 140),
  ('856414001160', 'Snacks salados', 150),
  ('856414001108', 'Snacks salados', 151),
  ('856414001191', 'Snacks salados', 152),
  ('856414001054', 'Snacks salados', 153),
  ('856414001184', 'Snacks salados', 154),
  ('856414001207', 'Snacks salados', 155),
  ('856414001092', 'Snacks salados', 156),
  ('856414001016', 'Snacks salados', 157),
  ('856414002167', 'Snacks salados', 158),
  ('893594002112', 'Snacks salados', 159),
  ('7622300124526', 'Snacks salados', 182),
  ('764090053710', 'Snacks salados', 197),
  ('850000725249', 'Snacks salados', 199),
  ('850000725263', 'Snacks salados', 207),
  ('850000725256', 'Snacks salados', 208),
  ('7862106721882', 'Snacks salados', 209),
  ('850000725270', 'Snacks salados', 213),
  ('7862126330989', 'Snacks salados', 216),
  ('7862126330972', 'Snacks salados', 217),
  ('771', 'Snacks salados', 218),
  ('8690481004714', 'Galletas y bizcochos', 2),
  ('8690481003267', 'Galletas y bizcochos', 7),
  ('8690481002437', 'Galletas y bizcochos', 8),
  ('7790040930407', 'Galletas y bizcochos', 9),
  ('7790040930209', 'Galletas y bizcochos', 10),
  ('77903518', 'Galletas y bizcochos', 11),
  ('7790040930506', 'Galletas y bizcochos', 12),
  ('7790040999404', 'Galletas y bizcochos', 13),
  ('80752981', 'Galletas y bizcochos', 14),
  ('7790040726505', 'Galletas y bizcochos', 16),
  ('8410368000970', 'Galletas y bizcochos', 18),
  ('8410368040082', 'Galletas y bizcochos', 19),
  ('8410368039611', 'Galletas y bizcochos', 20),
  ('8410014378330', 'Galletas y bizcochos', 21),
  ('8410014317070', 'Galletas y bizcochos', 22),
  ('765066783532', 'Galletas y bizcochos', 23),
  ('8410368033329', 'Galletas y bizcochos', 27),
  ('7750243004534', 'Galletas y bizcochos', 28),
  ('7622300268633', 'Galletas y bizcochos', 30),
  ('7622210259004', 'Galletas y bizcochos', 31),
  ('8080', 'Galletas y bizcochos', 32),
  ('787692834617', 'Galletas y bizcochos', 33),
  ('787692835416', 'Galletas y bizcochos', 38),
  ('787692835386', 'Galletas y bizcochos', 39),
  ('787692835430', 'Galletas y bizcochos', 40),
  ('787692835331', 'Galletas y bizcochos', 41),
  ('787692835355', 'Galletas y bizcochos', 42),
  ('8904006206058', 'Galletas y bizcochos', 46),
  ('8904006206072', 'Galletas y bizcochos', 47),
  ('8906001385028', 'Galletas y bizcochos', 48),
  ('810010660886', 'Galletas y bizcochos', 49),
  ('8906001386001', 'Galletas y bizcochos', 50),
  ('8906001386278', 'Galletas y bizcochos', 51),
  ('8906001385387', 'Galletas y bizcochos', 52),
  ('8902335028884', 'Galletas y bizcochos', 54),
  ('8901972057493', 'Galletas y bizcochos', 55),
  ('8901972073592', 'Galletas y bizcochos', 56),
  ('8904006230077', 'Galletas y bizcochos', 66),
  ('8901972068666', 'Galletas y bizcochos', 70),
  ('781718687720', 'Galletas y bizcochos', 71),
  ('8902335013163', 'Galletas y bizcochos', 72),
  ('8902335013156', 'Galletas y bizcochos', 73),
  ('781718687737', 'Galletas y bizcochos', 75),
  ('8901972071888', 'Galletas y bizcochos', 78),
  ('8902335006189', 'Galletas y bizcochos', 82),
  ('8902335005236', 'Galletas y bizcochos', 96),
  ('765351901221', 'Galletas y bizcochos', 105),
  ('888109010683', 'Galletas y bizcochos', 108),
  ('7896071021210', 'Galletas y bizcochos', 109),
  ('809552099283', 'Galletas y bizcochos', 111),
  ('809552088708', 'Galletas y bizcochos', 112),
  ('8095520099247', 'Galletas y bizcochos', 113),
  ('8410120500038', 'Galletas y bizcochos', 116),
  ('797936000470', 'Galletas y bizcochos', 117),
  ('7896003701180', 'Galletas y bizcochos', 118),
  ('8904006291009', 'Galletas y bizcochos', 121),
  ('8904006291016', 'Galletas y bizcochos', 122),
  ('8904006291047', 'Galletas y bizcochos', 123),
  ('8904006291030', 'Galletas y bizcochos', 124),
  ('8904006291023', 'Galletas y bizcochos', 125),
  ('8410368033848', 'Galletas y bizcochos', 126),
  ('8410368033312', 'Galletas y bizcochos', 127),
  ('7702189041197', 'Galletas y bizcochos', 130),
  ('80602316', 'Galletas y bizcochos', 134),
  ('7702011003881', 'Galletas y bizcochos', 135),
  ('787692834624', 'Galletas y bizcochos', 141),
  ('7702133009037', 'Galletas y bizcochos', 143),
  ('7750168002240', 'Galletas y bizcochos', 144),
  ('7622202217579', 'Galletas y bizcochos', 146),
  ('787692835324', 'Galletas y bizcochos', 150),
  ('7702025182329', 'Galletas y bizcochos', 153),
  ('7702025182305', 'Galletas y bizcochos', 154),
  ('8410368002936', 'Galletas y bizcochos', 159),
  ('8410368000390', 'Galletas y bizcochos', 160),
  ('8410368034678', 'Galletas y bizcochos', 161),
  ('80661641', 'Galletas y bizcochos', 162),
  ('8001585010103', 'Galletas y bizcochos', 163),
  ('80633051', 'Galletas y bizcochos', 164),
  ('781718687713', 'Galletas y bizcochos', 165),
  ('7702011048301', 'Galletas y bizcochos', 168),
  ('7702011003553', 'Galletas y bizcochos', 169),
  ('7702011014184', 'Galletas y bizcochos', 170),
  ('8904006205082', 'Galletas y bizcochos', 172),
  ('8904006206065', 'Galletas y bizcochos', 173),
  ('8904006291054', 'Galletas y bizcochos', 174),
  ('80633044', 'Galletas y bizcochos', 175),
  ('7891962005553', 'Galletas y bizcochos', 177),
  ('787692838349', 'Galletas y bizcochos', 178),
  ('7702993042311', 'Chocolates', 1),
  ('7702993022283', 'Chocolates', 2),
  ('776', 'Chocolates', 3),
  ('764090052515', 'Chocolates', 8),
  ('764090052478', 'Chocolates', 9),
  ('764090052454', 'Chocolates', 10),
  ('764090052119', 'Chocolates', 11),
  ('7891000369371', 'Chocolates', 12),
  ('8690997158611', 'Chocolates', 13),
  ('869302920023', 'Chocolates', 14),
  ('7891233', 'Chocolates', 15),
  ('8690997111753', 'Chocolates', 16),
  ('7899970401206', 'Chocolates', 18),
  ('7891000248768', 'Chocolates', 25),
  ('7891000249239', 'Chocolates', 26),
  ('8746197756475', 'Chocolates', 31),
  ('764090052157', 'Chocolates', 32),
  ('764090052133', 'Chocolates', 33),
  ('764090052430', 'Chocolates', 39),
  ('764090052416', 'Chocolates', 40),
  ('764090053703', 'Chocolates', 41),
  ('764090052171', 'Chocolates', 42),
  ('8413725004062', 'Chocolates', 43),
  ('8412704007308', 'Chocolates', 46),
  ('840004098302', 'Chicles y caramelos', 1),
  ('7702133853265', 'Chicles y caramelos', 7),
  ('7702133100130', 'Chicles y caramelos', 8),
  ('7891200001637', 'Chicles y caramelos', 10),
  ('7777', 'Chicles y caramelos', 12),
  ('8410525116759', 'Chicles y caramelos', 15),
  ('8410525143403', 'Chicles y caramelos', 16),
  ('8410525211065', 'Chicles y caramelos', 17),
  ('7896058593839', 'Chicles y caramelos', 18),
  ('763061080892', 'Chicles y caramelos', 19),
  ('7896451908575', 'Chicles y caramelos', 20),
  ('7891151017404', 'Chicles y caramelos', 22),
  ('7622210427045', 'Chicles y caramelos', 24),
  ('7622210427076', 'Chicles y caramelos', 25),
  ('7622202015212', 'Chicles y caramelos', 26),
  ('872635001802', 'Chicles y caramelos', 27),
  ('872635001246', 'Chicles y caramelos', 28),
  ('8850197580951', 'Chicles y caramelos', 30),
  ('7896286601900', 'Chicles y caramelos', 37),
  ('840004097466', 'Chicles y caramelos', 38),
  ('7801615692283', 'Chicles y caramelos', 43),
  ('78925281', 'Chicles y caramelos', 44),
  ('78914681', 'Chicles y caramelos', 48),
  ('78930643', 'Chicles y caramelos', 51),
  ('7896262304306', 'Chicles y caramelos', 52),
  ('763061082001', 'Chicles y caramelos', 53),
  ('816251010428', 'Chicles y caramelos', 54),
  ('787545004914', 'Chicles y caramelos', 55),
  ('7702402057615', 'Chicles y caramelos', 57),
  ('871478617225', 'Chicles y caramelos', 58),
  ('854929006557', 'Chicles y caramelos', 61),
  ('7702133879494', 'Chicles y caramelos', 62),
  ('7622201801229', 'Chicles y caramelos', 65),
  ('7622202212062', 'Chicles y caramelos', 67),
  ('7622210171115', 'Chicles y caramelos', 68),
  ('7622201776664', 'Chicles y caramelos', 70),
  ('7702133862793', 'Chicles y caramelos', 71),
  ('7622210973436', 'Chicles y caramelos', 77),
  ('7622210461674', 'Chicles y caramelos', 78),
  ('7622210461704', 'Chicles y caramelos', 79),
  ('7622210461728', 'Chicles y caramelos', 80),
  ('7622210461742', 'Chicles y caramelos', 81),
  ('7622202395130', 'Chicles y caramelos', 82),
  ('7622202395536', 'Chicles y caramelos', 84),
  ('7622210938282', 'Chicles y caramelos', 85),
  ('7622202394799', 'Chicles y caramelos', 86),
  ('763061080700', 'Chicles y caramelos', 90),
  ('820', 'Dulces típicos', 2),
  ('819', 'Dulces típicos', 3),
  ('818', 'Dulces típicos', 4),
  ('821', 'Dulces típicos', 5),
  ('815', 'Dulces típicos', 6),
  ('816', 'Dulces típicos', 7),
  ('817', 'Dulces típicos', 8),
  ('812', 'Dulces típicos', 9),
  ('810', 'Dulces típicos', 10);

insert into _p007f2_pos1 (codigo, categoria, posicion) values
  ('811', 'Dulces típicos', 11),
  ('814', 'Dulces típicos', 12),
  ('813', 'Dulces típicos', 13),
  ('8031', 'Dulces típicos', 33),
  ('8025', 'Dulces típicos', 39),
  ('8029', 'Dulces típicos', 40),
  ('8026', 'Dulces típicos', 41),
  ('8028', 'Dulces típicos', 42),
  ('8023', 'Dulces típicos', 43),
  ('8024', 'Dulces típicos', 44),
  ('8030', 'Dulces típicos', 45),
  ('8021', 'Dulces típicos', 46),
  ('8022', 'Dulces típicos', 47),
  ('8020', 'Dulces típicos', 48),
  ('8027', 'Dulces típicos', 49),
  ('888849006038', 'Barras de proteína', 1),
  ('888849000494', 'Barras de proteína', 2),
  ('888849000630', 'Barras de proteína', 5),
  ('888849005956', 'Barras de proteína', 6),
  ('888849004621', 'Barras de proteína', 7),
  ('888849000432', 'Barras de proteína', 8),
  ('888849000234', 'Barras de proteína', 9),
  ('888849000005', 'Barras de proteína', 10),
  ('888849012244', 'Barras de proteína', 11),
  ('888849005994', 'Barras de proteína', 12),
  ('888849006014', 'Barras de proteína', 13),
  ('888849006069', 'Barras de proteína', 14),
  ('888849006397', 'Barras de proteína', 15),
  ('888849008049', 'Barras de proteína', 16),
  ('888849000418', 'Barras de proteína', 17),
  ('888849000456', 'Barras de proteína', 18),
  ('888849003495', 'Barras de proteína', 19),
  ('888849010103', 'Barras de proteína', 20),
  ('888849010646', 'Barras de proteína', 21),
  ('888849010707', 'Barras de proteína', 22),
  ('888849000012', 'Barras de proteína', 23),
  ('888849000210', 'Barras de proteína', 24),
  ('8888490000470', 'Barras de proteína', 25),
  ('888849001224', 'Barras de proteína', 26),
  ('8410667020174', 'Despensa', 1),
  ('8410667020419', 'Despensa', 2),
  ('8437001130474', 'Despensa', 3),
  ('8480013190219', 'Despensa', 4),
  ('8437001130450', 'Despensa', 5),
  ('8480013190127', 'Despensa', 6),
  ('8480013190226', 'Despensa', 7),
  ('866213', 'Despensa', 10),
  ('866203', 'Despensa', 12),
  ('8701471', 'Despensa', 15),
  ('8411916202150', 'Despensa', 18),
  ('8852021298445', 'Despensa', 19),
  ('8852021002233', 'Despensa', 20),
  ('8410159044329', 'Despensa', 26),
  ('8410667005706', 'Despensa', 31),
  ('8423329813311', 'Despensa', 33),
  ('7788', 'Despensa', 41),
  ('7702024004943', 'Despensa', 42),
  ('7891000372609', 'Despensa', 43),
  ('8850468611377', 'Despensa', 48),
  ('8410344151504', 'Despensa', 50),
  ('8410344700030', 'Despensa', 51),
  ('8410344111508', 'Despensa', 52),
  ('8434165488663', 'Despensa', 58),
  ('90000', 'Despensa', 61),
  ('84233299812189', 'Comida y helados', 23),
  ('900', 'Comida y helados', 24),
  ('843182100577', 'Cigarrillos y tabaco', 1),
  ('843182100607', 'Cigarrillos y tabaco', 2),
  ('88', 'Cigarrillos y tabaco', 3),
  ('790690070154', 'Cigarrillos y tabaco', 5),
  ('78019423', 'Cigarrillos y tabaco', 7),
  ('78019416', 'Cigarrillos y tabaco', 8),
  ('78018662', 'Cigarrillos y tabaco', 9),
  ('853195000467', 'Cigarrillos y tabaco', 12),
  ('850043075103', 'Cigarrillos y tabaco', 14),
  ('853195000498', 'Cigarrillos y tabaco', 15),
  ('762446440009', 'Cigarrillos y tabaco', 17),
  ('762446450008', 'Cigarrillos y tabaco', 18),
  ('762446420001', 'Cigarrillos y tabaco', 19),
  ('762446400003', 'Cigarrillos y tabaco', 20),
  ('78020856', 'Cigarrillos y tabaco', 21),
  ('78018464', 'Cigarrillos y tabaco', 22),
  ('78018068', 'Cigarrillos y tabaco', 23),
  ('78018501', 'Cigarrillos y tabaco', 24),
  ('78014626', 'Cigarrillos y tabaco', 25),
  ('78014633', 'Cigarrillos y tabaco', 26),
  ('810134310650', 'Cigarrillos y tabaco', 47),
  ('844111003839', 'Cigarrillos y tabaco', 52),
  ('762446820009', 'Cigarrillos y tabaco', 53),
  ('89012001182', 'Cigarrillos y tabaco', 54),
  ('762446730001', 'Cigarrillos y tabaco', 64),
  ('762446703005', 'Cigarrillos y tabaco', 65),
  ('762446706006', 'Cigarrillos y tabaco', 66),
  ('762446710003', 'Cigarrillos y tabaco', 67),
  ('7707200947311', 'Vapes', 1),
  ('7751201001602', 'Vapes', 4),
  ('7702303182898', 'Vapes', 10),
  ('7702303936590', 'Vapes', 11),
  ('7702303023221', 'Vapes', 12),
  ('7707200941951', 'Vapes', 13),
  ('7707200941661', 'Vapes', 14),
  ('7707200942835', 'Vapes', 15),
  ('7707200940282', 'Vapes', 16),
  ('7702303809511', 'Vapes', 17),
  ('7702303404068', 'Vapes', 18),
  ('7702303721387', 'Vapes', 19),
  ('7702303401944', 'Vapes', 20),
  ('7702303142427', 'Vapes', 21),
  ('7702303246743', 'Vapes', 22),
  ('7702303027878', 'Vapes', 23),
  ('7702303915199', 'Vapes', 24),
  ('7702303617000', 'Vapes', 25),
  ('7702303923477', 'Vapes', 26),
  ('8904169416899', 'Farmacia, higiene y hogar', 7),
  ('857424000341', 'Farmacia, higiene y hogar', 8),
  ('8906101702589', 'Farmacia, higiene y hogar', 10),
  ('84233299812166', 'Farmacia, higiene y hogar', 14),
  ('808829032079', 'Farmacia, higiene y hogar', 30),
  ('808829032130', 'Farmacia, higiene y hogar', 31),
  ('7702027041020', 'Farmacia, higiene y hogar', 38),
  ('7702027494901', 'Farmacia, higiene y hogar', 39),
  ('7702027044168', 'Farmacia, higiene y hogar', 40),
  ('7702027402777', 'Farmacia, higiene y hogar', 41),
  ('84233299812177', 'Farmacia, higiene y hogar', 42),
  ('8010052120009', 'Farmacia, higiene y hogar', 46),
  ('7702026016616', 'Farmacia, higiene y hogar', 47),
  ('84115560', 'Farmacia, higiene y hogar', 48),
  ('7702035372154', 'Farmacia, higiene y hogar', 58),
  ('7702134372208', 'Farmacia, higiene y hogar', 59),
  ('7702031787570', 'Farmacia, higiene y hogar', 60),
  ('8901790682938', 'Farmacia, higiene y hogar', 61),
  ('7702418004825', 'Farmacia, higiene y hogar', 68),
  ('826942010088', 'Automotriz', 2),
  ('826942010026', 'Automotriz', 3),
  ('826942010033', 'Automotriz', 4),
  ('826942010071', 'Automotriz', 5),
  ('826942010019', 'Automotriz', 6),
  ('826942654909', 'Automotriz', 7),
  ('826942654893', 'Automotriz', 8),
  ('826942654916', 'Automotriz', 9),
  ('84121130068', 'Automotriz', 13),
  ('84121130013', 'Automotriz', 14),
  ('84121130044', 'Automotriz', 15),
  ('84233299812161', 'Automotriz', 24),
  ('84233299812162', 'Automotriz', 26),
  ('84233299812159', 'Automotriz', 27),
  ('84233299812157', 'Automotriz', 28),
  ('84233299812160', 'Automotriz', 29),
  ('84233299812156', 'Automotriz', 30),
  ('89269000457', 'Automotriz', 31),
  ('89269000198', 'Automotriz', 32),
  ('8000', 'Automotriz', 33),
  ('8877', 'Automotriz', 34),
  ('80', 'Automotriz', 36),
  ('842071002657', 'Automotriz', 37),
  ('842071002381', 'Automotriz', 38),
  ('842071002411', 'Automotriz', 39),
  ('842071002428', 'Automotriz', 40),
  ('842071002442', 'Automotriz', 41),
  ('7705808449169', 'Automotriz', 42),
  ('842071002725', 'Automotriz', 43),
  ('842071003302', 'Automotriz', 44),
  ('810822013313', 'Automotriz', 45),
  ('810822013252', 'Automotriz', 46),
  ('810822013306', 'Automotriz', 47),
  ('810822014860', 'Automotriz', 48),
  ('810822013276', 'Automotriz', 49),
  ('810822013283', 'Automotriz', 50),
  ('810822014853', 'Automotriz', 51),
  ('810822013290', 'Automotriz', 52),
  ('810822013269', 'Automotriz', 53),
  ('810822014846', 'Automotriz', 54),
  ('810822013245', 'Automotriz', 55),
  ('769848100746', 'Automotriz', 56),
  ('79238046180', 'Automotriz', 59),
  ('84233299812175', 'Automotriz', 61),
  ('84233299812165', 'Automotriz', 62),
  ('84233299812194', 'Automotriz', 63),
  ('79191514009', 'Automotriz', 66),
  ('76333113939', 'Automotriz', 67),
  ('859196130080', 'Automotriz', 79),
  ('797496878892', 'Automotriz', 80),
  ('797496863362', 'Automotriz', 81),
  ('797496871541', 'Automotriz', 82),
  ('797496861573', 'Automotriz', 83),
  ('797496865632', 'Automotriz', 84),
  ('797496860606', 'Automotriz', 85),
  ('797496871343', 'Automotriz', 86),
  ('797496861559', 'Automotriz', 87),
  ('797496658128', 'Automotriz', 88),
  ('797496875723', 'Automotriz', 89),
  ('797496865489', 'Automotriz', 90),
  ('853313006012', 'Automotriz', 91),
  ('8081', 'Automotriz', 92),
  ('7805040751126', 'Automotriz', 93),
  ('797496862341', 'Automotriz', 94),
  ('842071002527', 'Automotriz', 95),
  ('842071002565', 'Automotriz', 96),
  ('842071002534', 'Automotriz', 97),
  ('842071002664', 'Automotriz', 98),
  ('769848100722', 'Automotriz', 99),
  ('769848100708', 'Automotriz', 100),
  ('769848100715', 'Automotriz', 101),
  ('79238011133', 'Automotriz', 102),
  ('79238011164', 'Automotriz', 103),
  ('79238011188', 'Automotriz', 104),
  ('79238011508', 'Automotriz', 105),
  ('79238011225', 'Automotriz', 106),
  ('79238011478', 'Automotriz', 107),
  ('79238011492', 'Automotriz', 108),
  ('79238011157', 'Automotriz', 109),
  ('84233299812153', 'Misceláneos', 1),
  ('8409730014714', 'Misceláneos', 2),
  ('801', 'Misceláneos', 3),
  ('77', 'Misceláneos', 5),
  ('84233299812171', 'Misceláneos', 6),
  ('801248667334', 'Misceláneos', 7),
  ('783094020115', 'Misceláneos', 10),
  ('800', 'Misceláneos', 11),
  ('850051002009', 'Misceláneos', 16),
  ('7878', 'Misceláneos', 17),
  ('8888', 'Misceláneos', 18),
  ('8606004528650', 'Misceláneos', 19),
  ('802141257264', 'Misceláneos', 20),
  ('818043000013', 'Misceláneos', 21),
  ('84233299812193', 'Misceláneos', 22),
  ('840034240313', 'Misceláneos', 23),
  ('8714786213760', 'Misceláneos', 25);

create temp table _p007f2_categorias (
  name     text primary key,
  posicion int  not null
) on commit drop;

insert into _p007f2_categorias (name, posicion) values
  ('Cervezas', 10),
  ('Licores', 20),
  ('Vinos y espumantes', 30),
  ('Premix y cócteles', 40),
  ('Refrescos y energizantes', 50),
  ('Jugos, tés y lácteos', 60),
  ('Aguas', 70),
  ('Café y batidos', 75),
  ('Snacks salados', 80),
  ('Galletas y bizcochos', 90),
  ('Chocolates', 100),
  ('Chicles y caramelos', 110),
  ('Dulces típicos', 120),
  ('Barras de proteína', 130),
  ('Despensa', 140),
  ('Comida y helados', 150),
  ('Helados', 155),
  ('Cigarrillos y tabaco', 160),
  ('Vapes', 170),
  ('Farmacia, higiene y hogar', 180),
  ('Automotriz', 190),
  ('Souvenirs y regalos', 195),
  ('Misceláneos', 200);

do $$
declare
  v_business     uuid := '3c5c3b8e-28e6-45f0-8dc7-85e3efe8d30c';
  v_total        int  := 1043;
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
  v_pos1         int;
begin
  -- =========================================================================
  -- 1) GUARDAS — se comprueba todo ANTES de escribir una sola fila.
  -- =========================================================================

  if not exists (select 1 from public.businesses where id = v_business) then
    raise exception 'El negocio % no existe.', v_business;
  end if;

  -- 1a) La fase 1 tiene que estar cargada: esta fase la completa.
  select count(*) into v_n
  from _p007f2_pos1 q
  where exists (select 1 from public.menu_items mi
                where mi.business_id = v_business and mi.sku = q.codigo);
  if v_n = 0 then
    raise exception
      'No encuentro ningún producto de la fase 1. Corre primero IMPORT_COMPLETO.sql.';
  elsif v_n < 828 then
    raise notice 'De los 828 productos de la fase 1 encontré %: los que falten no se renumeran.', v_n;
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

  -- 1e) Ningún código apunta a VARIOS productos o insumos.
  select string_agg(format('%s (%s productos)', p.codigo, x.n), ', ')
    into v_list
  from _p007f2 p
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
      'Códigos que ya tienen VARIOS productos, no sé cuál actualizar: %', v_list;
  end if;

  select string_agg(format('%s (%s insumos)', p.codigo, x.n), ', ')
    into v_list
  from _p007f2 p
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
      'Códigos que ya tienen VARIOS insumos, no sé cuál usar: %', v_list;
  end if;

  -- 1f) Ningún código de esta fase apunta a un producto de la FASE 1: lo
  --     pisaría con los datos de otro artículo.
  select string_agg(format('%s → %s (%s)', p.codigo, mi.name, mi.sku), '; ')
    into v_list
  from _p007f2 p
  join public.menu_items mi
    on mi.business_id = v_business
   and (mi.sku = p.codigo or mi.barcode = p.codigo
        or (p.barcode is not null and mi.barcode = p.barcode))
  join _p007f2_pos1 q on q.codigo = mi.sku;

  if v_list is not null then
    raise exception
      'Códigos de la fase 2 que apuntan a productos de la fase 1: %. Revísalos '
      'antes de cargar.', v_list;
  end if;

  -- 1g) Menú: 0 se crea, 1 se reusa, más de 1 aborta.
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

  -- 1h) Bodega: la MISMA que escoge consume_inventory_from_order al vender.
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

  -- 1i) Área de comanda: la misma regla que la fase 1.
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
          'apaga Cocina en Ajustes y vuelve a correr.';
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
  from _p007f2_categorias c
  where exists (select 1 from _p007f2 p where p.categoria = c.name)
    and not exists (
      select 1 from public.categories x
      where x.business_id = v_business
        and lower(btrim(x.name)) = lower(c.name)
    );

  -- =========================================================================
  -- 4) PRODUCTOS — por código. Actualiza los que existen, inserta los demás.
  -- =========================================================================

  create temp table _p007f2_ids (
    codigo text primary key,
    id     uuid not null,
    nuevo  boolean not null
  ) on commit drop;

  insert into _p007f2_ids (codigo, id, nuevo)
  select p.codigo, mi.id, false
  from _p007f2 p
  join public.menu_items mi
    on mi.business_id = v_business
   and (mi.sku = p.codigo or mi.barcode = p.codigo
        or (p.barcode is not null and mi.barcode = p.barcode));

  select string_agg(format('%s ← %s', mi.name, z.codigos), '; ')
    into v_list
  from (
    select id, string_agg(codigo, ', ') as codigos
    from _p007f2_ids group by id having count(*) > 1
  ) z
  join public.menu_items mi on mi.id = z.id;

  if v_list is not null then
    raise exception
      'Productos que calzan con varios códigos del maestro a la vez: %', v_list;
  end if;

  -- Productos que ya existían con estos códigos: en una primera corrida son los
  -- que alguien creó a mano. Se avisa cuáles (en una re-corrida salen todos).
  select count(*), string_agg(mi.name, ', ' order by mi.name)
    into v_n, v_list
  from _p007f2_ids i
  join public.menu_items mi on mi.id = i.id;
  if v_n > 0 and v_n < v_total then
    raise notice '% productos ya existían con su código y se actualizan: %', v_n, v_list;
  end if;

  update public.menu_items mi
  set category_id         = cat.id,
      price               = p.price,
      cost                = p.cost,
      tax_mode            = 'inclusive',
      sku                 = p.codigo,
      barcode             = coalesce(p.barcode, mi.barcode),
      is_beverage         = p.is_bev,
      position            = p.posicion,
      print_area_code     = v_area_code,
      allow_negative_sale = true,
      updated_at          = now()
  from _p007f2_ids i
  join _p007f2 p on p.codigo = i.codigo
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
         'inclusive', p.codigo, p.barcode, true, p.is_bev, p.posicion,
         v_area_code, true
  from _p007f2 p
  cross join lateral (
    select c.id from public.categories c
    where c.business_id = v_business
      and lower(btrim(c.name)) = lower(p.categoria)
    order by c.created_at
    limit 1
  ) cat
  where not exists (select 1 from _p007f2_ids i where i.codigo = p.codigo);
  get diagnostics v_nuevos = row_count;

  insert into _p007f2_ids (codigo, id, nuevo)
  select p.codigo, mi.id, true
  from _p007f2 p
  join public.menu_items mi
    on mi.business_id = v_business
   and mi.sku = p.codigo
  where not exists (select 1 from _p007f2_ids i where i.codigo = p.codigo);

  -- =========================================================================
  -- 5) IMPUESTOS — exactamente el ITBIS.
  -- =========================================================================

  delete from public.menu_item_taxes mit
  using _p007f2_ids i
  where mit.item_id = i.id
    and mit.tax_id <> v_tax_id;

  insert into public.menu_item_taxes (item_id, tax_id)
  select i.id, v_tax_id
  from _p007f2_ids i
  where not exists (
    select 1 from public.menu_item_taxes x
    where x.item_id = i.id and x.tax_id = v_tax_id
  );

  -- =========================================================================
  -- 6) ÁREA DE COMANDA (N:M), igual que la fase 1.
  -- =========================================================================

  delete from public.menu_item_print_areas x
  using _p007f2_ids i
  where x.menu_item_id = i.id
    and (v_area_id is null or x.print_area_id <> v_area_id);

  if v_area_id is not null then
    insert into public.menu_item_print_areas (menu_item_id, print_area_id)
    select i.id, v_area_id
    from _p007f2_ids i
    where not exists (
      select 1 from public.menu_item_print_areas x
      where x.menu_item_id = i.id and x.print_area_id = v_area_id
    );
  end if;

  -- =========================================================================
  -- 7) ENLACE AL MENÚ Y POSICIONES
  -- =========================================================================

  insert into public.menu_item_links (menu_id, item_id, position)
  select v_menu_id, i.id, p.posicion
  from _p007f2_ids i
  join _p007f2 p on p.codigo = i.codigo
  where not exists (
    select 1 from public.menu_item_links l
    where l.menu_id = v_menu_id and l.item_id = i.id
  );

  update public.menu_item_links l
  set position = p.posicion
  from _p007f2_ids i
  join _p007f2 p on p.codigo = i.codigo
  where l.menu_id = v_menu_id
    and l.item_id = i.id
    and l.position is distinct from p.posicion;

  -- 7b) Fase 1: solo la posición, y solo si el producto sigue en la categoría
  --     con que se cargó (si lo movieron de categoría, no se toca).
  create temp table _p007f2_ids1 on commit drop as
  select mi.id, q.posicion
  from _p007f2_pos1 q
  join public.menu_items mi
    on mi.business_id = v_business
   and mi.sku = q.codigo
  join public.categories c
    on c.id = mi.category_id
   and lower(btrim(c.name)) = lower(q.categoria);

  update public.menu_items mi
  set position   = x.posicion,
      updated_at = now()
  from _p007f2_ids1 x
  where mi.id = x.id
    and mi.position is distinct from x.posicion;
  get diagnostics v_pos1 = row_count;

  update public.menu_item_links l
  set position = x.posicion
  from _p007f2_ids1 x
  where l.menu_id = v_menu_id
    and l.item_id = x.id
    and l.position is distinct from x.posicion;

  -- =========================================================================
  -- 8) INVENTARIO — un insumo por producto, emparejado por CÓDIGO.
  --    DML directo: fn_menu_item_set_inventory_tracked exige auth.uid().
  -- =========================================================================

  create temp table _p007f2_insumos (
    codigo     text primary key,
    item_id    uuid,
    tenia_movs boolean not null default false
  ) on commit drop;

  insert into _p007f2_insumos (codigo, item_id)
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
  from _p007f2 p
  join _p007f2_ids i on i.codigo = p.codigo;

  insert into public.inventory_items (
    business_id, sku, barcode, name, unit, cost, is_active
  )
  select v_business, p.codigo, p.barcode, p.name, 'unidad',
         coalesce(p.cost, 0), true
  from _p007f2 p
  join _p007f2_insumos s on s.codigo = p.codigo
  where s.item_id is null;
  get diagnostics v_insumos = row_count;

  update _p007f2_insumos s
  set item_id = ii.id
  from public.inventory_items ii
  where s.item_id is null
    and ii.business_id = v_business
    and ii.sku = s.codigo;

  -- Un insumo con CUALQUIER movimiento ya tiene historia (su existencia inicial
  -- de una corrida anterior, o ventas y compras si lo crearon a mano): no se le
  -- suma la del maestro.
  update _p007f2_insumos s
  set tenia_movs = exists (select 1 from public.inventory_movements m
                           where m.item_id = s.item_id);

  update public.menu_items mi
  set inventory_item_id    = s.item_id,
      is_inventory_tracked = true
  from _p007f2_ids i
  join _p007f2_insumos s on s.codigo = i.codigo
  where mi.id = i.id
    and (mi.inventory_item_id is distinct from s.item_id
         or not coalesce(mi.is_inventory_tracked, false));

  insert into public.inventory_movements (
    business_id, warehouse_id, item_id, movement_type, quantity,
    cost_per_unit, reference_type, notes
  )
  select v_business, v_wh_id, s.item_id, 'purchase'::public.movement_type,
         p.qty, p.cost, 'initial_stock',
         'Existencia inicial del maestro del sistema anterior (15/09/2026) — '
           || p.name
  from _p007f2 p
  join _p007f2_insumos s on s.codigo = p.codigo
  where p.qty > 0
    and not s.tenia_movs;
  get diagnostics v_movs = row_count;

  select count(*), string_agg(p.name || ' (' || p.qty || ')', ', ' order by p.name)
    into v_n, v_list
  from _p007f2 p
  join _p007f2_insumos s on s.codigo = p.codigo
  where p.qty > 0
    and s.tenia_movs
    and not exists (select 1 from public.inventory_movements m
                    where m.item_id = s.item_id
                      and m.reference_type = 'initial_stock');
  if v_n > 0 then
    raise notice '% insumos ya tenían movimientos y NO se les cargó la existencia del maestro (cuéntalos): %', v_n, v_list;
  end if;

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
  from _p007f2 p
  where (select count(*) from public.menu_items mi
         where mi.business_id = v_business and mi.sku = p.codigo) <> 1;
  if v_n > 0
     or (select count(*) from _p007f2_ids) <> v_total
     or (select count(distinct id) from _p007f2_ids) <> v_total then
    raise exception '% códigos sin producto o con más de uno. Revertido.', v_n;
  end if;

  -- 9b) Precio, ITBIS incluido, categoría, código de barras y posición.
  select count(*) into v_n
  from _p007f2_ids i
  join public.menu_items mi on mi.id = i.id
  join _p007f2 p on p.codigo = i.codigo
  left join public.categories c on c.id = mi.category_id
  where mi.price <> p.price
     or mi.tax_mode <> 'inclusive'
     or c.id is null
     or lower(btrim(c.name)) <> lower(p.categoria)
     or (p.barcode is not null and mi.barcode is distinct from p.barcode)
     or mi.position is distinct from p.posicion;
  if v_n > 0 then
    raise exception '% productos con precio, impuesto, categoría, código de barras o posición incorrectos. Revertido.', v_n;
  end if;

  -- 9c) Exactamente el ITBIS.
  select count(*) into v_n
  from _p007f2_ids i
  where not exists (select 1 from public.menu_item_taxes x
                    where x.item_id = i.id and x.tax_id = v_tax_id)
     or exists (select 1 from public.menu_item_taxes x
                where x.item_id = i.id and x.tax_id <> v_tax_id);
  if v_n > 0 then
    raise exception '% productos sin ITBIS o con otro impuesto. Revertido.', v_n;
  end if;

  -- 9d) Área: legacy y N:M de acuerdo.
  select count(*) into v_n
  from _p007f2_ids i
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

  -- 9e) Todos en el menú de la caja, con su posición.
  select count(*) into v_n
  from _p007f2_ids i
  join _p007f2 p on p.codigo = i.codigo
  where not exists (select 1 from public.menu_item_links l
                    where l.menu_id = v_menu_id and l.item_id = i.id
                      and l.position = p.posicion);
  if v_n > 0 then
    raise exception '% productos fuera del menú o con otra posición. Revertido.', v_n;
  end if;

  -- 9f) Todos enlazados a un insumo del negocio.
  select count(*) into v_n
  from _p007f2_ids i
  join public.menu_items mi on mi.id = i.id
  left join public.inventory_items ii
    on ii.id = mi.inventory_item_id and ii.business_id = v_business
  where not coalesce(mi.is_inventory_tracked, false) or ii.id is null;
  if v_n > 0 then
    raise exception '% productos sin insumo: se venderían sin descontar. Revertido.', v_n;
  end if;

  -- 9g) Ningún insumo compartido.
  select count(*) into v_n
  from (select item_id from _p007f2_insumos
        group by item_id having count(*) > 1) z;
  if v_n > 0
     or exists (select 1 from _p007f2_insumos s
                join public.menu_items mi on mi.inventory_item_id = s.item_id
                where mi.business_id = v_business
                  and mi.id not in (select id from _p007f2_ids)) then
    raise exception 'Hay insumos compartidos con otros productos: descontarían cruzado. Revertido.';
  end if;

  -- 9h) Existencia: la trae, o el insumo ya tenía historia (aviso de arriba).
  select count(*) into v_n
  from _p007f2 p
  join _p007f2_insumos s on s.codigo = p.codigo
  where p.qty > 0
    and not s.tenia_movs
    and not exists (select 1 from public.inventory_movements m
                    where m.item_id = s.item_id
                      and m.reference_type = 'initial_stock'
                      and m.quantity = p.qty);
  if v_n > 0 then
    raise exception '% productos sin su existencia inicial. Revertido.', v_n;
  end if;

  -- 9i) El motor de inventario encendido.
  if (select inventory_mode from public.business_settings
      where business_id = v_business) not in ('basic', 'advanced') then
    raise exception 'inventory_mode no quedó en basic/advanced. Revertido.';
  end if;

  -- 9j) Ningún código de barras repetido en productos activos del negocio.
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

  raise notice 'OK — % productos (% nuevos, % actualizados) · % insumos nuevos · % existencias iniciales en "%" · % posiciones de la fase 1 renumeradas · área: % · Commit.',
    v_total, v_nuevos, v_actualizados, v_insumos, v_movs, v_wh_name, v_pos1,
    coalesce(v_area_code, 'ninguna (cocina apagada)');
end $$;

commit;

-- ============================================================================
-- REPORTE — todas las filas deben decir ✓
-- ============================================================================

with items as (
  select mi.*, p.qty as p_qty, p.cost as p_cost, p.posicion as p_pos
  from public.menu_items mi
  join _p007f2 p on p.codigo = mi.sku
  where mi.business_id = '3c5c3b8e-28e6-45f0-8dc7-85e3efe8d30c'::uuid
),
fase1 as (
  select mi.*, q.posicion as q_pos
  from public.menu_items mi
  join _p007f2_pos1 q on q.codigo = mi.sku
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
stock as (
  -- Por producto con existencia en el maestro: su movimiento inicial, o si el
  -- insumo ya traía historia de antes (entonces no se le cargó).
  select i.id, i.p_qty, i.p_cost,
         (select sum(m.quantity) from public.inventory_movements m
           where m.item_id = i.inventory_item_id
             and m.reference_type = 'initial_stock') as inicial,
         (select sum(m.quantity * coalesce(m.cost_per_unit, 0))
            from public.inventory_movements m
           where m.item_id = i.inventory_item_id
             and m.reference_type = 'initial_stock') as valor
  from items i
  where i.p_qty > 0
),
r(orden, concepto, encontrado, esperado, ok) as (
  select 1, 'Productos de la fase 2',
         (select count(*) from items)::text, '1043',
         (select count(*) from items) = 1043
  union all
  select 2, 'Activos',
         (select count(*) filter (where is_active) from items)::text, '1043',
         (select count(*) filter (where is_active) from items) = 1043
  union all
  select 3, 'Con ITBIS incluido (inclusive)',
         (select count(*) from items where tax_mode = 'inclusive')::text, '1043',
         (select count(*) from items where tax_mode = 'inclusive') = 1043
  union all
  select 4, 'Vinculados SOLO al ITBIS 18%',
         (select count(*) from items i
           where exists (select 1 from public.menu_item_taxes x
                         join itbis t on t.id = x.tax_id where x.item_id = i.id)
             and not exists (select 1 from public.menu_item_taxes x
                             where x.item_id = i.id
                               and x.tax_id not in (select id from itbis)))::text,
         '1043',
         (select count(*) from items i
           where exists (select 1 from public.menu_item_taxes x
                         join itbis t on t.id = x.tax_id where x.item_id = i.id)
             and not exists (select 1 from public.menu_item_taxes x
                             where x.item_id = i.id
                               and x.tax_id not in (select id from itbis))) = 1043
  union all
  select 5, 'Enlazados al menú de la caja, en su posición',
         (select count(*) from items i where exists (
            select 1 from public.menu_item_links l
            where l.item_id = i.id and l.position = i.p_pos))::text,
         '1043',
         (select count(*) from items i where exists (
            select 1 from public.menu_item_links l
            where l.item_id = i.id and l.position = i.p_pos)) = 1043
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
                          where x.menu_item_id = i.id)) = 1043
              else (select count(*) from areas) = 0
                   and (select count(*) from items
                        where print_area_code is not null) = 0
         end
  union all
  select 7, 'Con su insumo (inventario 1:1)',
         (select count(*) from items i
           where i.is_inventory_tracked and i.inventory_item_id is not null)::text,
         '1043',
         (select count(*) from items i
           where i.is_inventory_tracked and i.inventory_item_id is not null) = 1043
  union all
  select 8, 'Con existencia inicial (+ ya tenían historia, sin tocar)',
         (select count(*) filter (where inicial is not null) || ' + ' ||
                 count(*) filter (where inicial is null) from stock),
         '669',
         (select count(*) from stock) = 669
         and (select count(*) from stock s
               where s.inicial is null
                 and not exists (select 1 from items i
                                 join public.inventory_movements m
                                   on m.item_id = i.inventory_item_id
                                 where i.id = s.id)) = 0
  union all
  select 9, 'Unidades de existencia inicial',
         coalesce((select sum(inicial) from stock), 0)::text,
         coalesce((select sum(p_qty) from stock where inicial is not null), 0)::text,
         coalesce((select sum(inicial) from stock), 0)
           = coalesce((select sum(p_qty) from stock where inicial is not null), 0)
  union all
  select 10, 'Valor de la existencia a costo (RD$)',
         to_char(coalesce((select sum(valor) from stock), 0), 'FM999,999,990.00'),
         to_char(coalesce((select sum(p_qty * coalesce(p_cost, 0)) from stock
                           where inicial is not null), 0), 'FM999,999,990.00'),
         round(coalesce((select sum(valor) from stock), 0), 2)
           = round(coalesce((select sum(p_qty * coalesce(p_cost, 0)) from stock
                             where inicial is not null), 0), 2)
  union all
  select 11, 'Modo de inventario',
         (select inventory_mode from bs), 'basic o advanced',
         (select inventory_mode from bs) in ('basic', 'advanced')
  union all
  select 12, 'Con código de barras',
         (select count(*) from items where nullif(btrim(barcode), '') is not null)::text,
         '902 o más',
         (select count(*) from items where nullif(btrim(barcode), '') is not null) >= 902
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
  select 15, 'Fase 1 en el menú de la caja (de 828 cargados)',
         (select count(*) from fase1 f where exists (
             select 1 from public.menu_item_links l where l.item_id = f.id))::text,
         (select count(*) from fase1)::text || ' que siguen',
         (select count(*) from fase1 f where not exists (
             select 1 from public.menu_item_links l where l.item_id = f.id)) = 0
  union all
  select 16, 'Fase 1 renumerada (en su categoría original)',
         (select count(*) from fase1 f
           join public.categories c on c.id = f.category_id
           join _p007f2_pos1 q on q.codigo = f.sku
                              and lower(btrim(c.name)) = lower(q.categoria)
          where f.position = f.q_pos)::text,
         (select count(*) from fase1 f
           join public.categories c on c.id = f.category_id
           join _p007f2_pos1 q on q.codigo = f.sku
                              and lower(btrim(c.name)) = lower(q.categoria))::text,
         (select count(*) from fase1 f
           join public.categories c on c.id = f.category_id
           join _p007f2_pos1 q on q.codigo = f.sku
                              and lower(btrim(c.name)) = lower(q.categoria)
          where f.position is distinct from f.q_pos) = 0
)
select concepto, encontrado, esperado,
       case when ok then '✓' else '✗ REVISAR' end as estado
from r
order by orden;

drop table if exists _p007f2;
drop table if exists _p007f2_pos1;
