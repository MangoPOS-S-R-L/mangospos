-- ============================================================================
-- ESTANCIA NUEVA SPORT · TIENDA — CARGA DEL CATÁLOGO (artículos deportivos)
-- Business 40b0fa9d-9ce6-4e17-902d-6f5f37cc58ab
--
-- Fuente: "ARTICULOS DE INVENTARIO.csv" del sistema anterior, dividido el
-- 21/09/2026 (build_estancia_nueva.py). Precios: ProIsa_lista.csv (sin ITBIS ×1.18 al peso; 9 ya finales; 7 en dólares sin precio).
--
-- ⚠ ARCHIVO GENERADO por build_import_tienda.py desde _tpl_import_tienda.sql.
--   No lo edites a mano: cambia el .py (o la plantilla) y regenera.
-- ============================================================================
--
-- QUÉ CARGA
--   353 artículos en 4 categorías (Pádel, Fútbol, Ropa y accesorios,
--   Servicios del club), todos en el menú de la caja, con ITBIS 18% INCLUIDO.
--   17 con código de barras; el código del sistema viejo va siempre en `sku`.
--   341 con precio → ACTIVOS. Los demás entran INACTIVOS en RD$0 hasta que
--   tengan precio (en $0 la caja los cobraría gratis).
--   344 inventariables 1:1 con su insumo, stock en CERO y "Vender aunque
--   esté agotado". Los servicios del club (clases, alquiler, liga…) NO llevan
--   inventario.
--
-- COMANDA
--   * Cocina apagada (lo normal en una tienda): ninguna; la venta pasa directo.
--   * Cocina encendida: el área `tienda` si existe; si no, la única área
--     activa; si no hay ninguna o hay varias, ABORTA y explica.
--
-- CÓMO CORRERLO
--   Pega este archivo entero en el SQL Editor de Supabase y dale Run. La tabla
--   del final es el reporte: todas las filas deben decir ✓.
--
-- TODO O NADA / SE PUEDE RE-CORRER
--   Una transacción con verificación antes del commit. Empareja por CÓDIGO.
--   Re-correrlo actualiza precio, costo, categoría, ITBIS y código de barras;
--   activa los que estaban inactivos en $0 y ahora traen precio; no reactiva
--   lo que apagaron a mano; no toca el stock.
-- ============================================================================

begin;

create temp table _tie (
  codigo        text primary key,     -- código del sistema viejo → sku
  name          text not null,
  categoria     text not null,
  price         numeric(12,2),        -- null = sin precio todavía
  cost          numeric,
  barcode       text,
  inventariable boolean not null,
  posicion      int not null
) on commit drop;

-- filas 1–200
insert into _tie (codigo, name, categoria, price, cost, barcode, inventariable, posicion) values
  ('1224', 'ADIDAS ARROW HIT JUNIOR', 'Pádel', 7850.00, 6900.0000, null, true, 1),
  ('110000100497', 'BABOLAT COUNTER VERTUO', 'Pádel', null, null, null, true, 2),
  ('097512510264', 'BOLAS DE PADEL WILSON TUBO 3 EN 1 ROJAS', 'Pádel', 650.00, 350.0000, '097512510264', true, 3),
  ('110000100718', 'BULLPADEL JUNIOR LINE PALA', 'Pádel', 7000.00, 4000.0000, null, true, 4),
  ('1223', 'BULLPADEL ÍNDIGA BOY', 'Pádel', 6000.00, 4850.0000, null, true, 5),
  ('110000100420', 'CALCETINES VIBOR-A KAIT MEDIA CAÑA', 'Pádel', 450.00, 381.3600, null, true, 6),
  ('110000100421', 'CALCETINES VIBOR-A KAIT MEDIA CAÑA (39-', 'Pádel', 450.00, 293.3200, null, true, 7),
  ('110000100424', 'CAMISETA VIBOR-A KAIT ADULTO (ROYAL, M)', 'Pádel', 1500.00, 1122.3900, null, true, 8),
  ('110000100428', 'CAMISETA VIBOR-A TAIPAN HOMBRE (AMARILL', 'Pádel', 1500.00, 1271.1900, null, true, 9),
  ('110000100649', 'CODERA DE PADEL', 'Pádel', 2650.00, 1567.0000, null, true, 10),
  ('766871822508', 'DUAL PRO GRIP + OVERGRIP SHOCKOUT (NEGR', 'Pádel', 1000.00, 808.1200, '766871822508', true, 11),
  ('1052', 'FOR ALL GRIP MULTICOLOR SIUX', 'Pádel', 200.00, 129.8000, null, true, 12),
  ('1069', 'GRIP OFFSERVE', 'Pádel', 200.00, 118.0000, null, true, 13),
  ('110000100463', 'GRIPS MULTI COLOR', 'Pádel', 150.00, 53.0000, null, true, 14),
  ('110000100726', 'GRIPS WILSON', 'Pádel', 300.00, 130.9100, null, true, 15),
  ('110000100427', 'MOCHILA SOFTEE CAR (NEGRO)', 'Pádel', 3500.00, 3499.8800, null, true, 16),
  ('1105', 'MUÑEQUERA ANCHA VIBOR A (BLANCA)', 'Pádel', 461.00, 286.0100, null, true, 17),
  ('1108', 'MUÑEQUERAS WILSON DOBLE WHITE', 'Pádel', 553.00, 413.0000, null, true, 18),
  ('1238', 'OVERGRIPS LISO ENEBE', 'Pádel', 150.00, 24.5600, null, true, 19),
  ('1228', 'OVERGRIPS PRO NOX', 'Pádel', 200.00, 93.5300, null, true, 20),
  ('110000100419', 'PACK VIBOR-A 2 MUÑEQUERAS 12 CM NEGRO', 'Pádel', 950.00, 739.8600, null, true, 21),
  ('887768339241', 'PADEL RUSH 100 WILSON', 'Pádel', 575.00, 414.0900, '887768339241', true, 22),
  ('110000100488', 'PALA ADIDAS RX SERIES LIGHT', 'Pádel', 8500.00, null, null, true, 23),
  ('1229', 'PALA AT10 GENIUS ULTRALIGHT', 'Pádel', 8000.00, 5490.1300, null, true, 24),
  ('110000100486', 'PALA BABOLAT AIR VERTUO', 'Pádel', 11101.00, 11100.0000, null, true, 25),
  ('110000100485', 'PALA BABOLAT CONTACT', 'Pádel', null, null, null, true, 26),
  ('110000100487', 'PALA BABOLAT TECHNICAL VERTUO', 'Pádel', null, null, null, true, 27),
  ('110000100484', 'PALA HEAD DELTA JUNIOR', 'Pádel', 6700.00, null, null, true, 28),
  ('110000100482', 'PALA HEAD FLASH', 'Pádel', null, null, null, true, 29),
  ('110000100489', 'PALA HEAD RADICAL PRO', 'Pádel', null, null, null, true, 30),
  ('110000100490', 'PALA HEAD ZEPHYR UL', 'Pádel', null, null, null, true, 31),
  ('110000100418', 'PALA PADEL SOFTEE FREEZER CARBON GREEN', 'Pádel', 12501.00, 10593.0000, null, true, 32),
  ('110000100515', 'PALA PADEL SOFTEE RANGER JUNIOR', 'Pádel', 3800.00, 2536.4900, null, true, 33),
  ('110000100414', 'PALA PADEL SOFTEE RANGER ORANGE', 'Pádel', 5900.00, 5000.0000, null, true, 34),
  ('110000100417', 'PALA PADEL SOFTEE SUMMIT GREEN POWER', 'Pádel', 9951.00, 8400.0000, null, true, 35),
  ('110000100413', 'PALA PADEL SOFTEE SWAT RED', 'Pádel', 5400.00, 3367.0000, null, true, 36),
  ('110000100514', 'PALA PADEL SOFTEE YELLOW JUNIOR', 'Pádel', 4000.00, 2866.2300, null, true, 37),
  ('110000100415', 'PALA PADEL VIBOR-A BAMBOO LIQUID EDITIO', 'Pádel', 9501.00, 8051.0000, null, true, 38),
  ('110000100416', 'PALA PADEL VIBOR-A SERPENT ADVANCE', 'Pádel', 8501.00, 7204.0000, null, true, 39),
  ('110000100483', 'PALA SIUX SPIDER', 'Pádel', null, null, null, true, 40),
  ('110000100524', 'PALBEA PADEL OVERGRIP EXTRA ADHERENCE B', 'Pádel', 200.00, 60.0000, null, true, 41),
  ('110000100422', 'PALETERO ENEBE RESPONSE TOUR (AZUL)', 'Pádel', 5900.00, 5800.8800, null, true, 42),
  ('110000100423', 'PALETERO SOFTEE EXTRA COOL BAG (NEGRO/A', 'Pádel', 2300.00, 1949.1500, null, true, 43),
  ('1226', 'PELOTA PRO NOX', 'Pádel', 650.00, 442.0000, null, true, 44),
  ('1227', 'PELOTA SOFTEER AMARILLA', 'Pádel', 650.00, 328.0900, null, true, 45),
  ('8435536789372', 'PELOTAS SIUX NEO', 'Pádel', 650.00, 442.5000, '8435536789372', true, 46),
  ('097512831048', 'PELOTAS WILSON NEGRAS', 'Pádel', 650.00, 414.0500, '097512831048', true, 47),
  ('1107', 'PELOTAS WILSON PADEL PREMIER', 'Pádel', 650.00, 466.1000, null, true, 48),
  ('1124', 'PRO OVERGRIP WILSON PADEL 3PK', 'Pádel', 500.00, 354.0000, null, true, 49),
  ('1106', 'PROTECTOR SIUX TRANSPARENTE', 'Pádel', 1500.00, 885.0000, null, true, 50),
  ('6165010781128', 'SACK PACK WILSON NAVY', 'Pádel', 800.00, 460.2000, '6165010781128', true, 51),
  ('6165010781050', 'SACK PACK WILSON RED', 'Pádel', 800.00, 460.2000, '6165010781050', true, 52),
  ('6165010781111', 'SACK PACK WILSON ROYAL', 'Pádel', 800.00, 460.2000, '6165010781111', true, 53),
  ('8435536788504', 'SIUX OVERGRIP X3', 'Pádel', 850.00, 501.5000, '8435536788504', true, 54),
  ('110000100001', 'AROS DE AGILIDAD', 'Fútbol', 125.00, 105.9300, null, true, 1),
  ('110000100375', 'BALON ARGENTINA', 'Fútbol', 3500.00, 2610.1700, null, true, 2),
  ('110000100002', 'BALON BARCA AMARILLO Y ROJO', 'Fútbol', 3500.00, 2372.8800, null, true, 3),
  ('110000100003', 'BALON MANCHESTER CITY', 'Fútbol', 3000.00, 2372.8800, null, true, 4),
  ('110000100376', 'BALON REAL MADRID NUMERO 5', 'Fútbol', 3500.00, 2610.1700, null, true, 5),
  ('110000100004', 'BALON STRETT SOCCER', 'Fútbol', 2200.00, 2610.1700, null, true, 6),
  ('110000100005', 'BALONES FRANCIA', 'Fútbol', 3500.00, 2610.1700, null, true, 7),
  ('110000100006', 'BALONES GVOVA NUMERO 5 BLANCO', 'Fútbol', 2200.00, 1393.3500, null, true, 8),
  ('110000100007', 'BALONES VENEZUELA', 'Fútbol', 3500.00, 2610.1700, null, true, 9),
  ('110000100008', 'BANDA DE CAPITAN GENERICA', 'Fútbol', 500.00, 211.8600, null, true, 10),
  ('1066', 'BOTAS IGNACIO', 'Fútbol', 1500.00, null, null, true, 11),
  ('110000100010', 'CAMISETA ARGENTINA AZUL 1998 SIZE M', 'Fútbol', 3500.00, 1601.6900, null, true, 12),
  ('110000100011', 'CAMISETA ARGENTINA AZUL 1998 SIZE S', 'Fútbol', 3500.00, 1601.6900, null, true, 13),
  ('110000100012', 'CAMISETA ARGENTINA AZUL CLARO SIZE M', 'Fútbol', 3500.00, 1601.6900, null, true, 14),
  ('110000100013', 'CAMISETA ARGENTINA AZUL CLARO SIZE S', 'Fútbol', 3500.00, 1601.6900, null, true, 15),
  ('110000100014', 'CAMISETA ARGENTINA AZUL CON CUELLO 1994', 'Fútbol', 3500.00, 1601.6900, null, true, 16),
  ('110000100015', 'CAMISETA ARGENTINA AZUL CON CUELLO 1994', 'Fútbol', 3500.00, 1601.6900, null, true, 17),
  ('110000100009', 'CAMISETA ARGENTINA MUNDIAL VISITANTE MO', 'Fútbol', 2400.00, 1305.0800, null, true, 18),
  ('110000100016', 'CAMISETA BARCA DORADA SIZE XL', 'Fútbol', 2400.00, 1254.2000, null, true, 19),
  ('110000100017', 'CAMISETA BARCA LOCAL TEMPORADA 24-25 SI', 'Fútbol', 2400.00, 1305.0800, null, true, 20),
  ('110000100018', 'CAMISETA BARCA LOCAL TEMPORADA 24-25 SI', 'Fútbol', 2400.00, 1305.0800, null, true, 21),
  ('110000100019', 'CAMISETA BARCA LOCAL TEMPORADA 24-25 SI', 'Fútbol', 2400.00, 1305.0800, null, true, 22),
  ('110000100382', 'CAMISETA BARCA NUEVA TEMPORADA NEGRA SI', 'Fútbol', 2400.00, 1305.0800, null, true, 23),
  ('110000100020', 'CAMISETA BARCA TEMPORADA 23LOCAL L', 'Fútbol', 2400.00, 1127.1200, null, true, 24),
  ('110000100021', 'CAMISETA ESPAÑA EUROCOPA LOCAL 2024 SIZ', 'Fútbol', 2400.00, 1254.2400, null, true, 25),
  ('110000100022', 'CAMISETA ESPAÑA EUROCOPA LOCAL 2024 SIZ', 'Fútbol', 2400.00, 1254.2400, null, true, 26),
  ('110000100023', 'CAMISETA ESPAÑA EUROCOPA LOCAL 2024 SIZ', 'Fútbol', 2400.00, 1480.0000, null, true, 27),
  ('110000100024', 'CAMISETA ESPAÑA EUROCOPA LOCAL 2024 SIZ', 'Fútbol', 2400.00, 1254.2400, null, true, 28),
  ('110000100025', 'CAMISETA ESPAÑA EUROCOPA VISITANTE 2024', 'Fútbol', 2400.00, 1254.2400, null, true, 29),
  ('110000100026', 'CAMISETA ESPAÑA EUROCOPA VISITANTE 2024', 'Fútbol', 2400.00, 1254.2400, null, true, 30),
  ('110000100027', 'CAMISETA ESPAÑA EUROCOPA VISITANTE 2024', 'Fútbol', 2400.00, 1254.2400, null, true, 31),
  ('110000100028', 'CAMISETA ESPAÑA EUROCOPA VISITANTE 2024', 'Fútbol', 2400.00, 1254.2400, null, true, 32),
  ('110000100029', 'CAMISETA ESPAÑA LOCAL MUNDIAL SIZE XL', 'Fútbol', 2400.00, 1254.2400, null, true, 33),
  ('110000100030', 'CAMISETA FRANCIA LOCAL NEW TEMPORADA S', 'Fútbol', 2400.00, 1305.0800, null, true, 34),
  ('110000100031', 'CAMISETA FRANCIA VISITANTE MUNDIAL QATA', 'Fútbol', 2400.00, 1305.0800, null, true, 35),
  ('110000100032', 'CAMISETA INTER MIAMI NEGRA SIZE L', 'Fútbol', 2400.00, 1305.0800, null, true, 36),
  ('110000100033', 'CAMISETA INTER MIAMI NEGRA SIZE M', 'Fútbol', 2400.00, 1305.0800, null, true, 37),
  ('110000100383', 'CAMISETA INTER MIAMI NUEVA SIZE L', 'Fútbol', 2400.00, 1305.0800, null, true, 38),
  ('110000100405', 'CAMISETA INTER MIAMI NUEVA TEMPORADA AZ', 'Fútbol', 2500.00, 1305.0800, null, true, 39),
  ('110000100406', 'CAMISETA INTER MIAMI NUEVA TEMPORADA AZ', 'Fútbol', 2500.00, 1305.0800, null, true, 40),
  ('110000100035', 'CAMISETA ITALIA TEMPORADA NUEVA AZUL L', 'Fútbol', 2400.00, 1305.0800, null, true, 41),
  ('110000100036', 'CAMISETA ITALIA TEMPORADA NUEVA AZUL S', 'Fútbol', 2400.00, 1305.0800, null, true, 42),
  ('110000100037', 'CAMISETA ITALIA VISITANTE EUROCOPA M VE', 'Fútbol', 2400.00, 1305.0800, null, true, 43),
  ('110000100034', 'CAMISETA ITALIA VISITANTE EUROCOPA S VE', 'Fútbol', 2400.00, 1305.0800, null, true, 44),
  ('110000100536', 'CAMISETA JUVENTUS LOCAL M', 'Fútbol', 2400.00, 1305.0800, null, true, 45),
  ('110000100038', 'CAMISETA LOCAL ARGENTINA MUNDIAL 2022 M', 'Fútbol', 2400.00, 1254.2400, null, true, 46),
  ('110000100039', 'CAMISETA MANCHESTER CITY TEMPORADA 2024', 'Fútbol', 2400.00, 1127.1200, null, true, 47),
  ('110000100537', 'CAMISETA MANCHESTER CITY VERDE M', 'Fútbol', 2400.00, 1205.0800, null, true, 48),
  ('110000100538', 'CAMISETA MEXICO MUNDIA VISITANTE', 'Fútbol', 2400.00, 1305.0000, null, true, 49),
  ('110000100221', 'CAMISETA MOCA FC AMARILLA SIZE 12', 'Fútbol', 1200.00, 850.0000, null, true, 50),
  ('110000100224', 'CAMISETA MOCA FC AMARILLA SIZE L', 'Fútbol', 1200.00, 850.0000, null, true, 51),
  ('110000100223', 'CAMISETA MOCA FC AMARILLA SIZE M', 'Fútbol', 1200.00, 850.0000, null, true, 52),
  ('110000100222', 'CAMISETA MOCA FC AMARILLA SIZE S', 'Fútbol', 1200.00, 850.0000, null, true, 53),
  ('110000100225', 'CAMISETA MOCA FC NEGRA SIZE 12', 'Fútbol', 1200.00, 850.0000, null, true, 54),
  ('110000100228', 'CAMISETA MOCA FC NEGRA SIZE L', 'Fútbol', 1200.00, 850.0000, null, true, 55),
  ('110000100227', 'CAMISETA MOCA FC NEGRA SIZE M', 'Fútbol', 1200.00, 850.0000, null, true, 56),
  ('110000100226', 'CAMISETA MOCA FC NEGRA SIZE S', 'Fútbol', 1200.00, 850.0000, null, true, 57),
  ('110000100539', 'CAMISETA PORTUGAL EUROCOPA M', 'Fútbol', 2400.00, 1305.0000, null, true, 58),
  ('110000100040', 'CAMISETA PSG BLANCA L', 'Fútbol', 2400.00, 1305.0800, null, true, 59),
  ('110000100041', 'CAMISETA PSG LOCAL TEMPORADA 22 M', 'Fútbol', 2400.00, 1127.1200, null, true, 60),
  ('110000100042', 'CAMISETA PSG LOCAL TEMPORADA 22 S', 'Fútbol', 2400.00, 1127.1200, null, true, 61),
  ('110000100043', 'CAMISETA PSG LOCAL TEMPORADA 22 XL', 'Fútbol', 2400.00, 1127.1200, null, true, 62),
  ('110000100044', 'CAMISETA PSG NEGRA CON AMARILLO S', 'Fútbol', 2400.00, 1127.1200, null, true, 63),
  ('110000100045', 'CAMISETA PSG NEGRA CON AMARILLO XL', 'Fútbol', 2400.00, 1127.1200, null, true, 64),
  ('110000100046', 'CAMISETA REAL MADRID BLANCA TEMPORADA 2', 'Fútbol', 2400.00, 1305.0800, null, true, 65),
  ('110000100047', 'CAMISETA REAL MADRID BLANCA TEMPORADA 2', 'Fútbol', 2400.00, 1305.0800, null, true, 66),
  ('110000100403', 'CAMISETA REAL MADRID GRIS 24-25 SIZE L', 'Fútbol', 2500.00, 1539.9900, null, true, 67),
  ('110000100402', 'CAMISETA REAL MADRID GRIS 24-25 SIZE M', 'Fútbol', 2500.00, 1539.9900, null, true, 68),
  ('110000100401', 'CAMISETA REAL MADRID GRIS 24-25 SIZE S', 'Fútbol', 2500.00, 1539.9900, null, true, 69),
  ('110000100404', 'CAMISETA REAL MADRID GRIS 24-25 SIZE XL', 'Fútbol', 2500.00, 1539.9900, null, true, 70),
  ('110000100397', 'CAMISETA REAL MADRID NARANJA 24-25 SIZE', 'Fútbol', 2500.00, 1539.9900, null, true, 71),
  ('110000100398', 'CAMISETA REAL MADRID NARANJA 24-25 SIZE', 'Fútbol', 2500.00, 1539.9900, null, true, 72),
  ('110000100399', 'CAMISETA REAL MADRID NARANJA 24-25 SIZE', 'Fútbol', 2500.00, 1539.9900, null, true, 73),
  ('110000100400', 'CAMISETA REAL MADRID NARANJA 24-25 SIZE', 'Fútbol', 2500.00, 1539.9900, null, true, 74),
  ('110000100048', 'CAMISETA REAL MADRID TEMPORADA 24-25 SI', 'Fútbol', 2400.00, 1305.0800, null, true, 75),
  ('110000100246', 'CAMISETA REAL MADRID TEMPORADA 24-25 SI', 'Fútbol', 2400.00, 1305.0800, null, true, 76),
  ('110000100049', 'CAMISETA RETRO ARGENTINA 1990 SIZE M', 'Fútbol', 3500.00, 1601.6900, null, true, 77),
  ('110000100050', 'CAMISETA RETRO ARGENTINA 1990 SIZE S', 'Fútbol', 3500.00, 1601.6900, null, true, 78),
  ('110000100051', 'CAMISETA RETRO ARGENTINA LE COP SPORTF', 'Fútbol', 3500.00, 1601.6900, null, true, 79),
  ('110000100052', 'CAMISETA RETRO BARCA 1899-1999 SIZE L', 'Fútbol', 3500.00, 1601.6900, null, true, 80),
  ('110000100053', 'CAMISETA RETRO BARCA 1899-1999 SIZE M', 'Fútbol', 3500.00, 1601.6900, null, true, 81),
  ('110000100054', 'CAMISETA RETRO REAL MADRID 2010-2012 SI', 'Fútbol', 3500.00, 1601.6900, null, true, 82),
  ('110000100055', 'CAMISETA RETRO REAL MADRID 2010-2012 SI', 'Fútbol', 3500.00, 1601.6900, null, true, 83),
  ('110000100056', 'CAMISETA RETRO REAL MADRID 2010-2012 SI', 'Fútbol', 3500.00, 1601.6900, null, true, 84),
  ('110000100057', 'CAMISETA RETRO REAL MADRID ROSADA 2015', 'Fútbol', 3500.00, 1601.6900, null, true, 85),
  ('1073', 'CAMISETA UNIFORME SIZE 16', 'Fútbol', 1000.00, 531.0000, null, true, 86),
  ('1074', 'CAMISETA UNIFORME SIZE 6', 'Fútbol', 1000.00, 531.0000, null, true, 87),
  ('1075', 'CAMISETA UNIFORME SIZE 8', 'Fútbol', 1000.00, 531.0000, null, true, 88),
  ('110000100058', 'CAMISETA VISITANTE ARGENTINA MUNDIAL 20', 'Fútbol', 2400.00, 1008.4700, null, true, 89),
  ('110000100059', 'CAMISETA VISITANTE ARGENTINA MUNDIAL 20', 'Fútbol', 2400.00, 1008.4700, null, true, 90),
  ('110000100061', 'CONJUNTO ALL NASSAR LOCAL 20', 'Fútbol', 2600.00, 1305.0800, null, true, 91),
  ('110000100062', 'CONJUNTO ALL NASSAR VISITANTE 22', 'Fútbol', 2600.00, 1305.0800, null, true, 92),
  ('110000100395', 'CONJUNTO ARGENTINA EUROPA LOCAL 20', 'Fútbol', 2600.00, 1539.9900, null, true, 93),
  ('110000100396', 'CONJUNTO ARGENTINA EUROPA LOCAL 22', 'Fútbol', 2600.00, 1539.9900, null, true, 94),
  ('110000100063', 'CONJUNTO ARGENTINA EUROPA LOCAL 24', 'Fútbol', 2600.00, 1305.0800, null, true, 95),
  ('110000100381', 'CONJUNTO ARGENTINA EUROPA LOCAL 28', 'Fútbol', 2600.00, 1305.0800, null, true, 96),
  ('110000100064', 'CONJUNTO ARGENTINA VISITANTE COPA AMERI', 'Fútbol', 2600.00, 1305.0000, null, true, 97),
  ('110000100065', 'CONJUNTO ARGENTINA VISITANTE MUNDIAL MO', 'Fútbol', 2200.00, 1008.4700, null, true, 98),
  ('110000100066', 'CONJUNTO ARGENTINA VISITANTE MUNDIAL MO', 'Fútbol', 2200.00, 1008.4700, null, true, 99),
  ('110000100067', 'CONJUNTO ATLETICO MADRID BLANCO ROJO 16', 'Fútbol', 2600.00, 1305.0800, null, true, 100),
  ('110000100068', 'CONJUNTO ATLETICO MADRID BLANCO ROJO 24', 'Fútbol', 2600.00, 1305.0800, null, true, 101),
  ('110000100069', 'CONJUNTO ATLETICO MADRID BLANCO ROJO 28', 'Fútbol', 2600.00, 1305.0800, null, true, 102),
  ('110000100070', 'CONJUNTO BARCA LOCAL TEMPORADA PASADA 2', 'Fútbol', 2600.00, 1305.0800, null, true, 103),
  ('110000100071', 'CONJUNTO BARCA LOCAL TEMPORADA PASADA S', 'Fútbol', 2600.00, 1305.0800, null, true, 104),
  ('110000100072', 'CONJUNTO BARCA LOCAL TEMPORADA PASADA S', 'Fútbol', 2600.00, 1305.0800, null, true, 105),
  ('110000100073', 'CONJUNTO BARCA LOCAL TEMPORADA PASADA S', 'Fútbol', 2600.00, 1305.0800, null, true, 106),
  ('110000100074', 'CONJUNTO BARCA LOCAL TEMPORADA PASADA S', 'Fútbol', 2600.00, 1305.0800, null, true, 107),
  ('110000100407', 'CONJUNTO BARCA NEGRO NUEVA TEMPORADA 24', 'Fútbol', 2600.00, 1305.0800, null, true, 108),
  ('110000100408', 'CONJUNTO BARCA NEGRO NUEVA TEMPORADA 28', 'Fútbol', 2600.00, 1305.0800, null, true, 109),
  ('110000100377', 'CONJUNTO BARCA NUEVA TEMPORADA NEGRO SI', 'Fútbol', 2600.00, 1305.0800, null, true, 110),
  ('110000100378', 'CONJUNTO BARCA NUEVA TEMPORADA NEGRO SI', 'Fútbol', 2600.00, 1305.0800, null, true, 111),
  ('110000100075', 'CONJUNTO BARCA TEMPORADA 24-25 SIZE 24', 'Fútbol', 2600.00, 1305.0800, null, true, 112),
  ('110000100076', 'CONJUNTO BARCA TEMPORADA 24-25 SIZE 26', 'Fútbol', 2600.00, 1305.0800, null, true, 113),
  ('110000100077', 'CONJUNTO BARCA TEMPORADA 24-25 SIZE 28', 'Fútbol', 2600.00, 1305.0800, null, true, 114),
  ('110000100078', 'CONJUNTO BAYER 20', 'Fútbol', 2600.00, 1305.0800, null, true, 115),
  ('110000100079', 'CONJUNTO BAYER 22', 'Fútbol', 2600.00, 1305.0800, null, true, 116),
  ('110000100080', 'CONJUNTO BAYER 24', 'Fútbol', 2600.00, 1305.0800, null, true, 117),
  ('110000100081', 'CONJUNTO BRASIL NUEVA TEMPORADA LOCAL 1', 'Fútbol', 2600.00, 1305.0800, null, true, 118),
  ('110000100082', 'CONJUNTO CITY TEMPORADA PASADA 16', 'Fútbol', 2600.00, 1305.0800, null, true, 119),
  ('110000100083', 'CONJUNTO CITY TEMPORADA PASADA 20', 'Fútbol', 2600.00, 1305.0800, null, true, 120),
  ('110000100084', 'CONJUNTO ESPAÑA EUROCOPA LOCAL SIZE 28', 'Fútbol', 2600.00, 1305.0800, null, true, 121),
  ('110000100085', 'CONJUNTO ESPAÑA EUROCOPA VISITANTE SIZE', 'Fútbol', 2600.00, 1305.0800, null, true, 122),
  ('110000100086', 'CONJUNTO INTER MIAMI NEGRO 20', 'Fútbol', 2600.00, 1305.0800, null, true, 123),
  ('110000100087', 'CONJUNTO INTER MIAMI NEGRO 22', 'Fútbol', 2600.00, 1305.0800, null, true, 124),
  ('110000100380', 'CONJUNTO INTER MIAMI NUEVA AZUL 24', 'Fútbol', 2600.00, 1305.0800, null, true, 125),
  ('110000100379', 'CONJUNTO INTER MIAMI NUEVA AZUL 28', 'Fútbol', 2600.00, 1305.0800, null, true, 126),
  ('110000100088', 'CONJUNTO INTER MIAMI ROSADO 24', 'Fútbol', 2600.00, 1305.0800, null, true, 127),
  ('110000100089', 'CONJUNTO INTER MIAMI VISITANTE TEMPORAD', 'Fútbol', 2600.00, 1305.0800, null, true, 128),
  ('110000100090', 'CONJUNTO MANCHESTER UNITED MANGA LARGA', 'Fútbol', 4700.00, 3347.0000, null, true, 129),
  ('110000100091', 'CONJUNTO MANCHESTER UNITED MANGA LARGA', 'Fútbol', 4700.00, 3347.0000, null, true, 130),
  ('110000100092', 'CONJUNTO MANCHESTER UNITED MANGA LARGA', 'Fútbol', 4700.00, 3347.0000, null, true, 131),
  ('110000100093', 'CONJUNTO MANGA LARGA BARCA AZUL CLARO 1', 'Fútbol', 4700.00, 3347.0000, null, true, 132),
  ('110000100094', 'CONJUNTO MANGA LARGA BARCA AZUL CLARO 1', 'Fútbol', 4700.00, 3347.0000, null, true, 133),
  ('110000100095', 'CONJUNTO MANGA LARGA BARCA NARANJA 12', 'Fútbol', 4700.00, 3347.0000, null, true, 134),
  ('110000100096', 'CONJUNTO MANGA LARGA BARCA NARANJA 14', 'Fútbol', 4700.00, 3347.0000, null, true, 135),
  ('110000100097', 'CONJUNTO MANGA LARGA BARCA NARANJA 16', 'Fútbol', 4700.00, 3347.0000, null, true, 136),
  ('110000100098', 'CONJUNTO MANGA LARGA BARCA NARANJA 18', 'Fútbol', 4700.00, 3347.0000, null, true, 137),
  ('110000100099', 'CONJUNTO MANGA LARGA PSG AZUL 14', 'Fútbol', 4700.00, 4480.0000, null, true, 138),
  ('110000100100', 'CONJUNTO MANGA LARGA PSG AZUL 16', 'Fútbol', 4700.00, 3347.0000, null, true, 139),
  ('110000100411', 'CONJUNTO PORTUGAL RONALDO SIZE 28', 'Fútbol', 2600.00, 1305.0800, null, true, 140),
  ('110000100101', 'CONJUNTO PORTUGAL TEMPORADA LOCAL 2022', 'Fútbol', 2600.00, 1305.0800, null, true, 141),
  ('110000100102', 'CONJUNTO PORTUGAL TEMPORADA VISITANTE 2', 'Fútbol', 2600.00, 1305.0800, null, true, 142),
  ('110000100103', 'CONJUNTO PSG BLANCO SIZE 28', 'Fútbol', 2600.00, 1305.0800, null, true, 143),
  ('110000100104', 'CONJUNTO REAL MADRID AZUL TEMPORADA 23', 'Fútbol', 2600.00, 1305.0800, null, true, 144),
  ('110000100105', 'CONJUNTO REAL MADRID BLANCA TEMPORADA 2', 'Fútbol', 2600.00, 1305.0800, null, true, 145),
  ('110000100106', 'CONJUNTO REAL MADRID BLANCA TEMPORADA 2', 'Fútbol', 2600.00, 1305.0800, null, true, 146);

-- filas 201–353
insert into _tie (codigo, name, categoria, price, cost, barcode, inventariable, posicion) values
  ('110000100107', 'CONJUNTO REAL MADRID BLANCO 22', 'Fútbol', 2600.00, 1305.0800, null, true, 147),
  ('110000100108', 'CONJUNTO REAL MADRID LOCAL TEMPORADA 24', 'Fútbol', 2600.00, 1305.0800, null, true, 148),
  ('110000100109', 'CONJUNTO REAL MADRID LOCAL TEMPORADA 24', 'Fútbol', 2600.00, 1305.0800, null, true, 149),
  ('110000100110', 'CONJUNTO REAL MADRID MANGA LARGA MORADO', 'Fútbol', 4700.00, 3347.0000, null, true, 150),
  ('110000100111', 'CONJUNTO REAL MADRID MANGA LARGA MORADO', 'Fútbol', 4700.00, 3347.0000, null, true, 151),
  ('110000100112', 'CONJUNTO REAL MADRID MANGA LARGA NEGRO', 'Fútbol', 4700.00, 3347.0000, null, true, 152),
  ('110000100113', 'CONJUNTO REAL MADRID MANGA LARGA NEGRO', 'Fútbol', 4700.00, 3347.0000, null, true, 153),
  ('110000100114', 'CONJUNTO REAL MADRID MORADO 20', 'Fútbol', 2600.00, 1305.0800, null, true, 154),
  ('110000100409', 'CONJUNTO REAL MADRID NARANJA SIZE 24', 'Fútbol', 2600.00, 1305.0800, null, true, 155),
  ('110000100410', 'CONJUNTO REAL MADRID NARANJA SIZE 28', 'Fútbol', 2600.00, 1305.0800, null, true, 156),
  ('110000100115', 'CONJUNTO REAL MADRID NEGRO 24', 'Fútbol', 2600.00, 1305.0800, null, true, 157),
  ('110000100116', 'CONJUNTO REAL MADRID NEGRO 28', 'Fútbol', 2600.00, 1305.0800, null, true, 158),
  ('110000100268', 'CONJUTO REAL MADRID MORADO CON NEGRO NU', 'Fútbol', 2600.00, null, null, true, 159),
  ('110000100117', 'CUBITT SPORT BELT', 'Fútbol', 1200.00, 830.5100, null, true, 160),
  ('110000100118', 'ESPINILLERA AZUL', 'Fútbol', 500.00, 237.2900, null, true, 161),
  ('110000100249', 'ESPINILLERA SPORT BLANCA', 'Fútbol', 500.00, 237.2900, null, true, 162),
  ('110000100248', 'ESPINILLERA SPORT NARANJA', 'Fútbol', 450.00, 237.2900, null, true, 163),
  ('110000100247', 'ESPINILLERA SPORT NEGRA', 'Fútbol', 450.00, 237.2900, null, true, 164),
  ('110000100715', 'GORRA ESTANCIA NUEVA SPORT CLUB', 'Fútbol', 1200.00, null, null, true, 165),
  ('110000100119', 'GORRA INTER DE MILAN', 'Fútbol', 2000.00, 762.7100, null, true, 166),
  ('110000100120', 'GORRA MERCEDES ROJA', 'Fútbol', 2000.00, 762.7100, null, true, 167),
  ('110000100121', 'GORRA PORTUGAL ROJA', 'Fútbol', 2000.00, 762.7100, null, true, 168),
  ('110000100122', 'GORRA REAL MADRID', 'Fútbol', 2000.00, 762.7100, null, true, 169),
  ('110000100123', 'GORRA REAL MADRID AZUL', 'Fútbol', 2000.00, 762.7100, null, true, 170),
  ('110000100124', 'GORRA RED BULL ROJA', 'Fútbol', 2000.00, 762.7100, null, true, 171),
  ('1131', 'GUANTE DE PORTERIA SULTAN BUFFON', 'Fútbol', 5500.00, 1433.3300, null, true, 172),
  ('1130', 'GUANTE DE PORTERIA TRITON BUFFTON', 'Fútbol', 5500.00, 1433.3300, null, true, 173),
  ('1213', 'GUANTERAS DBK NIÑO', 'Fútbol', 2100.00, 1500.0000, null, true, 174),
  ('110000100125', 'GUANTES RINAT DE PORTERO PROFESIONAL BL', 'Fútbol', 7401.00, 5300.0000, null, true, 175),
  ('110000100126', 'GUANTES RINAT SEMI PRO DE PORTERO NEGRO', 'Fútbol', 4900.00, 3500.0000, null, true, 176),
  ('110000100127', 'INFLADOR MANUAL DE BALONES GENERICO', 'Fútbol', 250.00, 148.3000, null, true, 177),
  ('110000100128', 'KIT CONOS VARIAS 50 UNIDAD', 'Fútbol', 1500.00, 845.4500, null, true, 178),
  ('110000100129', 'MEDIA BABY NEGRA GIVOVA', 'Fútbol', 600.00, 380.0000, null, true, 179),
  ('110000100130', 'MEDIA BOY BLU GIVOVA', 'Fútbol', 525.00, 350.1100, null, true, 180),
  ('110000100131', 'MEDIA GIVOVA SENIOR CELESTE', 'Fútbol', 525.00, 200.0000, null, true, 181),
  ('110000100132', 'MEDIA GIVOVA SENIOR NEGRA', 'Fútbol', 600.00, 380.0000, null, true, 182),
  ('110000100250', 'MEDIAS ANTIDESLIZANTE', 'Fútbol', 600.00, 275.0000, null, true, 183),
  ('1208', 'MEDIAS GIVOVA BABY BLANCA', 'Fútbol', 500.00, 380.0000, null, true, 184),
  ('110000100133', 'MEDIAS GIVOVA BABY CELESTE', 'Fútbol', 600.00, 236.0000, null, true, 185),
  ('1209', 'MEDIAS GIVOVA BLANCA BOY', 'Fútbol', 500.00, 407.1000, null, true, 186),
  ('1210', 'MEDIAS GIVOVA BLANCA SENIOR', 'Fútbol', 525.00, 380.0000, null, true, 187),
  ('1211', 'MEDIAS GIVOVA NEGRA BOY', 'Fútbol', 500.00, 407.1000, null, true, 188),
  ('110000100134', 'MOCHILAS REAL MADRID AZULES', 'Fútbol', 3500.00, 1864.4000, null, true, 189),
  ('110000100135', 'PERFUME BARCA', 'Fútbol', 3500.00, 1016.9500, null, true, 190),
  ('110000100136', 'PIZARRA DE FUTBALL MAGNETICA', 'Fútbol', 2500.00, 1779.6600, null, true, 191),
  ('110000100137', 'RINAT TURF GUANTES PORTEROS SIZE 9', 'Fútbol', 4500.00, 3500.0000, null, true, 192),
  ('110000100138', 'SPINILLERA SPORT', 'Fútbol', 500.00, null, null, true, 193),
  ('1199', 'UNIFORME FUTBOL MANGA CORTA C/ NOMBRE', 'Fútbol', 2200.00, 1412.4600, null, true, 194),
  ('1198', 'UNIFORME FUTBOL MANGA LARGA PORT.C/NOMBR', 'Fútbol', 2400.00, 1602.4400, null, true, 195),
  ('110000100140', 'ZAPATILLA ADIDAS GAME MODE SIZE 10 CLAV', 'Fútbol', 5900.00, 4576.2700, null, true, 196),
  ('110000100141', 'ZAPATILLA ADIDAS GOLETO NEGRO SIZE 3.5', 'Fútbol', 5900.00, 3813.5600, null, true, 197),
  ('110000100142', 'ZAPATILLA ADIDAS GOLETOS SIZE 5', 'Fútbol', 3500.00, 3813.8600, null, true, 198),
  ('110000100154', 'ZAPATILLA ADIDAS SPEED PORTAL VERDE SIZ', 'Fútbol', 6801.00, 4576.2700, null, true, 199),
  ('110000100144', 'ZAPATILLA CRAZY FAST SIZE 6.5', 'Fútbol', 6501.00, 3813.5600, null, true, 200),
  ('110000100145', 'ZAPATILLA GIVOVA SIZE 39', 'Fútbol', 4500.00, 2478.8100, null, true, 201),
  ('110000100146', 'ZAPATILLA GIVOVA SIZE 43', 'Fútbol', 4500.00, 2478.8100, null, true, 202),
  ('110000100147', 'ZAPATILLA GIVOVA SIZE 44', 'Fútbol', 4500.00, 2478.8100, null, true, 203),
  ('110000100148', 'ZAPATILLA KERME AZUL SIZE 4.5', 'Fútbol', 4500.00, 3389.8300, null, true, 204),
  ('110000100149', 'ZAPATILLA KERME ROJAS SIZE 5.5', 'Fútbol', 4500.00, 3389.8300, null, true, 205),
  ('110000100150', 'ZAPATILLA MERCURIALES AZUL CON VERDE SI', 'Fútbol', 5900.00, 3813.5600, null, true, 206),
  ('110000100469', 'ZAPATILLA PUMA ATTACANTO SIZE 2 NEGRO', 'Fútbol', 5900.00, 4661.0100, null, true, 207),
  ('110000100470', 'ZAPATILLA PUMA ATTACANTO SIZE 2.5 NEGRO', 'Fútbol', 5900.00, 4661.0100, null, true, 208),
  ('110000100472', 'ZAPATILLA PUMA ATTACANTO SIZE 3 NEGRO', 'Fútbol', 5900.00, 4661.0100, null, true, 209),
  ('110000100468', 'ZAPATILLA PUMA ATTACANTO SIZE 3.5 VERDE', 'Fútbol', 5900.00, 4661.0100, null, true, 210),
  ('110000100471', 'ZAPATILLA PUMA ATTACANTO SIZE 4 NEGRO', 'Fútbol', 5900.00, 4661.0100, null, true, 211),
  ('110000100465', 'ZAPATILLA PUMA ATTACANTO SIZE 4 VERDES', 'Fútbol', 5900.00, 4661.0100, null, true, 212),
  ('110000100466', 'ZAPATILLA PUMA ATTACANTO SIZE 4.5 VERDE', 'Fútbol', 5900.00, 4661.0100, null, true, 213),
  ('110000100467', 'ZAPATILLA PUMA ATTACANTO SIZE 5 VERDE', 'Fútbol', 5900.00, 4661.0100, null, true, 214),
  ('110000100151', 'ZAPATILLA PUMA ATTACANTO SIZE 8', 'Fútbol', 5900.00, 4661.0100, null, true, 215),
  ('110000100388', 'ZAPATILLA PUMA AZUL SIZE 3C', 'Fútbol', 5000.00, null, null, true, 216),
  ('1027', 'BLUSA BLANCA BEFINE', 'Ropa y accesorios', 1770.00, 750.0000, null, true, 1),
  ('1028', 'BLUSA CREMA BEFINE', 'Ropa y accesorios', 1770.00, 750.0000, null, true, 2),
  ('1029', 'BLUSA NEGRA GYMWEAR', 'Ropa y accesorios', 2360.00, 1000.0000, null, true, 3),
  ('40650000', 'BLUSA ROSADA', 'Ropa y accesorios', 899.00, 500.0000, null, true, 4),
  ('1025', 'BLUSA ROSADA M-GYM', 'Ropa y accesorios', 1850.00, 900.0000, null, true, 5),
  ('X001X38ZF1', 'BODY PROX RODILLERA', 'Ropa y accesorios', 2650.00, 1450.0000, null, true, 6),
  ('110000100440', 'BOLSA DE REGALO GRANDE', 'Ropa y accesorios', 200.00, null, null, true, 7),
  ('110000100439', 'BOLSA DE REGALO PEQUEÑA', 'Ropa y accesorios', 100.00, null, null, true, 8),
  ('110000100504', 'CALCETINES VIVORA', 'Ropa y accesorios', 450.00, 381.0000, null, true, 9),
  ('1187', 'CAMPAMENTO T-SHIRTS MANGAS CORTAS ,TELA', 'Ropa y accesorios', 1000.00, 710.3600, null, true, 10),
  ('110000100060', 'COLCHONETA PILATE YOGA 4MM', 'Ropa y accesorios', 2200.00, 1271.1800, null, true, 11),
  ('110000100707', 'FALDA BLANCA ADIDAS', 'Ropa y accesorios', 3000.00, null, null, true, 12),
  ('110000100543', 'FALDA BLANCA XS', 'Ropa y accesorios', 3950.00, 2750.0000, null, true, 13),
  ('110000100694', 'FALDA DE PADEL ROSADA MAMEI', 'Ropa y accesorios', 3000.00, null, null, true, 14),
  ('1021', 'FALDAS CORTA', 'Ropa y accesorios', 1865.00, 1700.0000, null, true, 15),
  ('1054', 'FALDAS DEPORTIVA PADEL', 'Ropa y accesorios', 2200.00, 1000.0000, null, true, 16),
  ('110000100495', 'FALDITA AZUL', 'Ropa y accesorios', 2000.00, null, null, true, 17),
  ('1033', 'LICRA NEGRA', 'Ropa y accesorios', 599.00, 300.0000, null, true, 18),
  ('110000100363', 'MANGAS', 'Ropa y accesorios', 300.00, null, null, true, 19),
  ('8034044828117', 'PANTALON 2XS', 'Ropa y accesorios', null, 100.0000, '8034044828117', true, 20),
  ('110000100438', 'PANTALON 2XS UNIFORME', 'Ropa y accesorios', 800.00, null, null, true, 21),
  ('110000100426', 'PANTALON PADEL SOFTEE CLUB (BLANCO, L)', 'Ropa y accesorios', 450.00, 381.3600, null, true, 22),
  ('110000100425', 'PANTALON PADEL SOFTEE CLUB (MARINO, M)', 'Ropa y accesorios', 450.00, 381.3600, null, true, 23),
  ('110000100587', 'PANTALON PADEL SOFTEE CLUB BLANCO', 'Ropa y accesorios', 450.00, 381.0000, null, true, 24),
  ('8034044828100', 'PANTALON UNIFORME 3XS', 'Ropa y accesorios', 300.00, 150.0000, '8034044828100', true, 25),
  ('8034044828155', 'PANTALON UNIFORME L', 'Ropa y accesorios', 300.00, 150.0000, '8034044828155', true, 26),
  ('1076', 'PANTALON UNIFORME SIZE 16', 'Ropa y accesorios', 725.00, 495.0000, null, true, 27),
  ('1077', 'PANTALON UNIFORME SIZE 6', 'Ropa y accesorios', 800.00, 584.1000, null, true, 28),
  ('1078', 'PANTALON UNIFORME SIZE 8', 'Ropa y accesorios', 725.00, 495.0000, null, true, 29),
  ('1031', 'PANTALON UNIFORME XS', 'Ropa y accesorios', 300.00, 150.0000, null, true, 30),
  ('1053', 'PANTALONES Y BLUSA', 'Ropa y accesorios', 1695.00, 1000.0000, null, true, 31),
  ('1197', 'POLOSHIRTS C/M M/M MANGA CORTA PADRES', 'Ropa y accesorios', 1000.00, 937.5100, null, true, 32),
  ('1243', 'RESISTANGE TRAINER', 'Ropa y accesorios', 4300.00, 3064.1400, null, true, 33),
  ('110000100571', 'SHORT AZUL PADEL', 'Ropa y accesorios', 450.00, null, null, true, 34),
  ('1236', 'SHORTS,TELA DRY FIT NEGRO', 'Ropa y accesorios', 1250.00, 782.9300, null, true, 35),
  ('1030', 'SUERA MANGA LARGA M GYM', 'Ropa y accesorios', 2800.00, 1400.0000, null, true, 36),
  ('8034044838079', 'T SHIRT 2XS', 'Ropa y accesorios', null, 250.0000, '8034044838079', true, 37),
  ('110000100435', 'T SHIRT 2XS UNIFORME', 'Ropa y accesorios', 1000.00, null, null, true, 38),
  ('8034044838062', 'T SHIRT 3XS', 'Ropa y accesorios', null, 250.0000, '8034044838062', true, 39),
  ('110000100437', 'T SHIRT 3XS UNIFORME', 'Ropa y accesorios', 500.00, 472.0000, null, true, 40),
  ('110000100695', 'T SHIRT AZUL CLARA WOMEN', 'Ropa y accesorios', 1695.00, null, null, true, 41),
  ('110000100547', 'T SHIRT MOCA PADEL CLUB L', 'Ropa y accesorios', 1200.00, 815.0000, null, true, 42),
  ('110000100546', 'T SHIRT MOCA PADEL CLUB M', 'Ropa y accesorios', 1200.00, 815.0000, null, true, 43),
  ('110000100545', 'T SHIRT MOCA PADEL CLUB S', 'Ropa y accesorios', 1200.00, 815.0000, null, true, 44),
  ('110000100548', 'T SHIRT MOCA PADEL CLUB XL', 'Ropa y accesorios', 1200.00, 815.0000, null, true, 45),
  ('110000100544', 'T SHIRT MOCA PADEL CLUB XS', 'Ropa y accesorios', 1200.00, 815.0000, null, true, 46),
  ('8034044838116', 'T SHIRT UNIFORME L', 'Ropa y accesorios', 500.00, 250.0000, '8034044838116', true, 47),
  ('1032', 'T SHIRT UNIFORME XS', 'Ropa y accesorios', 1000.00, 250.0000, null, true, 48),
  ('1188', 'T-SHIRTS C/M # 8 MANGA CORTA PADRES', 'Ropa y accesorios', 1000.00, 710.3600, null, true, 49),
  ('1190', 'T-SHIRTS C/M FEM./M MANGA CORTA PADRES', 'Ropa y accesorios', 1000.00, 710.3600, null, true, 50),
  ('1189', 'T-SHIRTS C/M FEM./XS MANGA CORTA PADRE', 'Ropa y accesorios', 1000.00, 710.3600, null, true, 51),
  ('1191', 'T-SHIRTS C/M- L MANGA CORTA PADRES', 'Ropa y accesorios', 1000.00, 710.3600, null, true, 52),
  ('1233', 'T-SHIRTS MANGA CORTA,TELA DRY FIT MASCUL', 'Ropa y accesorios', 1000.00, 710.3600, null, true, 53),
  ('1234', 'T-SHIRTS MANGAS CORTAS,TELA DRY FIT NIÑO', 'Ropa y accesorios', 1000.00, 710.3600, null, true, 54),
  ('1235', 'T-SHIRTS MANGAS CORTAS,TELA FEMENIÑA', 'Ropa y accesorios', 1000.00, 710.3600, null, true, 55),
  ('1237', 'T-SHIRTS MANGAS CORTAS,TELA,AZUL', 'Ropa y accesorios', 1250.00, 828.3600, null, true, 56),
  ('110000100513', 'TOALLA ZAFIRO DE MANO BLANCA', 'Ropa y accesorios', 200.00, 66.0000, null, true, 57),
  ('1023', 'TOP GRIS GALA SPORT', 'Ropa y accesorios', 1650.00, 825.0000, null, true, 58),
  ('196473749291', 'TOP NEGRO ALL ME', 'Ropa y accesorios', null, 1050.0000, '196473749291', true, 59),
  ('1026', 'TOP NEGRO BEFINE', 'Ropa y accesorios', 1770.00, 750.0000, null, true, 60),
  ('1022', 'TOP NEGRO SENCILLO', 'Ropa y accesorios', 1770.00, 750.0000, null, true, 61),
  ('1024', 'TOP ROSADO SENCILLO', 'Ropa y accesorios', 1350.00, 600.0000, null, true, 62),
  ('196608848431', 'TOP VERDE OLIVO', 'Ropa y accesorios', 2000.00, 1000.0000, '196608848431', true, 63),
  ('1196', 'TSHIRTS C/M 3XL MANGA CORTA PADRES', 'Ropa y accesorios', 1000.00, 710.3600, null, true, 64),
  ('1193', 'TSHIRTS C/M S MANGA CORTA PADRES', 'Ropa y accesorios', 1000.00, 710.3600, null, true, 65),
  ('1195', 'TSHIRTS C/M XL MANGAS CORTA PADRES', 'Ropa y accesorios', 1000.00, 710.3600, null, true, 66),
  ('1192', 'TSHIRTS C/M XS MANGA CORTA PADRES', 'Ropa y accesorios', 1000.00, 710.3600, null, true, 67),
  ('1194', 'TSHIRTS CM M/M MANGA CORTA PADRES', 'Ropa y accesorios', 1000.00, 602.0000, null, true, 68),
  ('110000100549', 'VESTIDO ADIDDAS NEGRO', 'Ropa y accesorios', 6701.00, null, null, true, 69),
  ('110000100550', 'VESTIDO ADIDDAS ROSADO', 'Ropa y accesorios', 6701.00, null, null, true, 70),
  ('110000100492', 'VESTIDO PADEL AZUL', 'Ropa y accesorios', 3250.00, null, null, true, 71),
  ('110000100494', 'VESTIDO PADEL NEGRO', 'Ropa y accesorios', 2800.00, null, null, true, 72),
  ('110000100493', 'VESTIDO PADEL ROJO', 'Ropa y accesorios', 2800.00, null, null, true, 73),
  ('110000100491', 'VESTIDO PADEL VERDE', 'Ropa y accesorios', 3250.00, null, null, true, 74),
  ('110000100450', 'ALQUILER DE PALAS', 'Servicios del club', 200.00, null, null, false, 1),
  ('1017', 'CLASE DE PADEL PARA 1 PERSONA', 'Servicios del club', 2700.00, null, null, false, 2),
  ('110000100449', 'CLASES DE PADEL PARA 4 PERSONAS', 'Servicios del club', 1000.00, null, null, false, 3),
  ('110000100579', 'LIGA ABIERTA DEL PADEL', 'Servicios del club', 800.00, null, null, false, 4),
  ('1065', 'PATROCINIO TORNEO DE PADEL', 'Servicios del club', 11800.00, null, null, false, 5),
  ('1020', 'SERVICIO DE TRANSPORTE', 'Servicios del club', null, 106.2000, null, false, 6),
  ('1221', 'SERVICIOS DE PUBLICIDAD', 'Servicios del club', 11000.00, null, null, false, 7),
  ('110000100139', 'SERVICIOS DE VALLA LATERALES 360', 'Servicios del club', 59000.00, 50000.0000, null, false, 8),
  ('1137', 'SERVICIOS DE VALLAS LATERALES 360', 'Servicios del club', 295000.00, null, null, false, 9);

create temp table _tie_categorias (
  name     text primary key,
  posicion int  not null
) on commit drop;

insert into _tie_categorias (name, posicion) values
  ('Pádel', 10),
  ('Fútbol', 20),
  ('Ropa y accesorios', 30),
  ('Servicios del club', 40);

do $$
declare
  v_business     uuid := '40b0fa9d-9ce6-4e17-902d-6f5f37cc58ab';
  v_total        int  := 353;
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
begin
  -- =========================================================================
  -- 1) GUARDAS — se comprueba todo ANTES de escribir una sola fila.
  -- =========================================================================

  if not exists (select 1 from public.businesses where id = v_business) then
    raise exception 'El negocio % no existe.', v_business;
  end if;

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

  if exists (select 1 from public.taxes
             where id = v_tax_id and coalesce(is_service_fee, false)) then
    raise exception
      'El ITBIS tiene is_service_fee = true: la factura lo cobraría DOS veces. '
      'Apágalo antes de cargar.';
  end if;

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
      'por orden. Apágalo primero si la tienda no lo cobra.';
  end if;

  -- Ningún código de la lista apunta a VARIOS productos o insumos.
  select string_agg(format('%s (%s productos)', p.codigo, x.n), ', ')
    into v_list
  from _tie p
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

  select string_agg(format('%s (%s insumos)', p.codigo, x.n), ', ')
    into v_list
  from _tie p
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
      'Códigos de la lista que ya tienen VARIOS insumos, no sé cuál usar: %',
      v_list;
  end if;

  -- Menú: 0 se crea, 1 se reusa, más de 1 aborta.
  select count(*) into v_menus
  from public.menus
  where business_id = v_business and coalesce(is_active, true);

  if v_menus > 1 then
    select string_agg(name, ', ' order by created_at) into v_list
    from public.menus
    where business_id = v_business and coalesce(is_active, true);

    raise exception
      'La tienda tiene % menús activos (%). Dime a cuál van los artículos.',
      v_menus, v_list;
  end if;

  -- Bodega: la MISMA que escoge consume_inventory_from_order al vender.
  select w.id, w.name, coalesce(w.is_active, true)
    into v_wh_id, v_wh_name, v_wh_active
  from public.warehouses w
  where w.business_id = v_business
  order by w.is_main desc, w.created_at asc nulls first, w.id asc
  limit 1;

  if v_wh_id is null then
    raise exception
      'La tienda no tiene bodega. Créala en Inventario → Bodegas, márcala '
      'como principal y vuelve a correr.';
  end if;

  if not v_wh_active or v_wh_name = '__IN_TRANSIT__' then
    raise exception
      'La bodega de la que descuenta la venta es "%" (desactivada o de '
      'tránsito). Marca la bodega real como principal y vuelve a correr.',
      v_wh_name;
  end if;

  -- Área de comanda (ver encabezado).
  if v_kitchen then
    select count(*), string_agg(format('%s (%s)', name, code), ', ')
      into v_n, v_list
    from public.print_areas
    where business_id = v_business
      and is_active
      and code not in ('cashier', 'fiscal', 'cash_close');

    select id, code into v_area_id, v_area_code
    from public.print_areas
    where business_id = v_business and is_active and code = 'tienda';

    if v_area_id is null then
      if v_n = 1 then
        select id, code into v_area_id, v_area_code
        from public.print_areas
        where business_id = v_business
          and is_active
          and code not in ('cashier', 'fiscal', 'cash_close');
      elsif v_n = 0 then
        raise exception
          'Cocina está ENCENDIDA en la tienda y no hay ninguna área de comanda: '
          'cada venta fallaría al mandar a cocina. En una tienda lo normal es '
          'APAGAR Cocina (Ajustes): la venta pasa directo, sin comanda. Apágala '
          'y vuelve a correr.';
      else
        raise exception
          'Cocina está encendida y hay % áreas de comanda (%), ninguna "tienda". '
          'Apaga Cocina en Ajustes (lo normal en una tienda) o dime a cuál van.',
          v_n, v_list;
      end if;
    end if;
  end if;

  -- =========================================================================
  -- 2) MENÚ  3) CATEGORÍAS
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

  insert into public.categories (id, business_id, name, position, is_active)
  select gen_random_uuid(), v_business, c.name, c.posicion, true
  from _tie_categorias c
  where not exists (
    select 1 from public.categories x
    where x.business_id = v_business
      and lower(btrim(x.name)) = lower(c.name)
  );

  -- =========================================================================
  -- 4) ARTÍCULOS — por código. Actualiza los que existen, inserta los demás.
  -- =========================================================================

  create temp table _tie_ids (
    codigo text primary key,
    id     uuid not null,
    nuevo  boolean not null
  ) on commit drop;

  insert into _tie_ids (codigo, id, nuevo)
  select p.codigo, mi.id, false
  from _tie p
  join public.menu_items mi
    on mi.business_id = v_business
   and (mi.sku = p.codigo or mi.barcode = p.codigo
        or (p.barcode is not null and mi.barcode = p.barcode));

  select string_agg(format('%s ← %s', mi.name, z.codigos), '; ')
    into v_list
  from (
    select id, string_agg(codigo, ', ') as codigos
    from _tie_ids group by id having count(*) > 1
  ) z
  join public.menu_items mi on mi.id = z.id;

  if v_list is not null then
    raise exception
      'Productos que calzan con varios códigos de la lista a la vez: %', v_list;
  end if;

  update public.menu_items mi
  set category_id         = cat.id,
      price               = coalesce(p.price, mi.price),
      cost                = coalesce(p.cost, mi.cost),
      tax_mode            = 'inclusive',
      sku                 = p.codigo,
      barcode             = coalesce(p.barcode, mi.barcode),
      is_beverage         = false,
      is_active           = case
                              when coalesce(p.price, 0) > 0
                                   and mi.price = 0 and not mi.is_active then true
                              else mi.is_active
                            end,
      position            = p.posicion,
      print_area_code     = v_area_code,
      allow_negative_sale = true,
      updated_at          = now()
  from _tie_ids i
  join _tie p on p.codigo = i.codigo
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
         coalesce(p.price, 0) > 0, false, p.posicion, v_area_code, true
  from _tie p
  cross join lateral (
    select c.id from public.categories c
    where c.business_id = v_business
      and lower(btrim(c.name)) = lower(p.categoria)
    order by c.created_at
    limit 1
  ) cat
  where not exists (select 1 from _tie_ids i where i.codigo = p.codigo);
  get diagnostics v_nuevos = row_count;

  insert into _tie_ids (codigo, id, nuevo)
  select p.codigo, mi.id, true
  from _tie p
  join public.menu_items mi
    on mi.business_id = v_business
   and mi.sku = p.codigo
  where not exists (select 1 from _tie_ids i where i.codigo = p.codigo);

  -- =========================================================================
  -- 5) ITBIS  6) ÁREA  7) MENÚ DE LA CAJA
  -- =========================================================================

  delete from public.menu_item_taxes mit
  using _tie_ids i
  where mit.item_id = i.id
    and mit.tax_id <> v_tax_id;

  insert into public.menu_item_taxes (item_id, tax_id)
  select i.id, v_tax_id
  from _tie_ids i
  where not exists (
    select 1 from public.menu_item_taxes x
    where x.item_id = i.id and x.tax_id = v_tax_id
  );

  delete from public.menu_item_print_areas x
  using _tie_ids i
  where x.menu_item_id = i.id
    and (v_area_id is null or x.print_area_id <> v_area_id);

  if v_area_id is not null then
    insert into public.menu_item_print_areas (menu_item_id, print_area_id)
    select i.id, v_area_id
    from _tie_ids i
    where not exists (
      select 1 from public.menu_item_print_areas x
      where x.menu_item_id = i.id and x.print_area_id = v_area_id
    );
  end if;

  insert into public.menu_item_links (menu_id, item_id, position)
  select v_menu_id, i.id, p.posicion
  from _tie_ids i
  join _tie p on p.codigo = i.codigo
  where not exists (
    select 1 from public.menu_item_links l
    where l.menu_id = v_menu_id and l.item_id = i.id
  );

  -- =========================================================================
  -- 8) INVENTARIO — un insumo por artículo, por CÓDIGO; stock en CERO.
  --    Los servicios no llevan. DML directo: el RPC exige auth.uid().
  -- =========================================================================

  create temp table _tie_insumo_de (
    codigo  text primary key,
    item_id uuid
  ) on commit drop;

  insert into _tie_insumo_de (codigo, item_id)
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
  from _tie p
  join _tie_ids i on i.codigo = p.codigo
  where p.inventariable;

  insert into public.inventory_items (
    business_id, sku, barcode, name, unit, cost, is_active
  )
  select v_business, p.codigo, p.barcode, p.name, 'unidad',
         coalesce(p.cost, 0), true
  from _tie p
  join _tie_insumo_de s on s.codigo = p.codigo
  where s.item_id is null;
  get diagnostics v_insumos = row_count;

  update _tie_insumo_de s
  set item_id = ii.id
  from public.inventory_items ii
  where s.item_id is null
    and ii.business_id = v_business
    and ii.sku = s.codigo;

  update public.menu_items mi
  set inventory_item_id    = s.item_id,
      is_inventory_tracked = true
  from _tie_ids i
  join _tie_insumo_de s on s.codigo = i.codigo
  where mi.id = i.id
    and (mi.inventory_item_id is distinct from s.item_id
         or not coalesce(mi.is_inventory_tracked, false));

  if v_mode = 'none' then
    update public.business_settings
    set inventory_mode = 'basic'
    where business_id = v_business;
  end if;

  -- =========================================================================
  -- 9) VERIFICACIÓN DENTRO DE LA TRANSACCIÓN — cualquier fallo revierte TODO.
  -- =========================================================================

  select count(*) into v_n
  from _tie p
  where (select count(*) from public.menu_items mi
         where mi.business_id = v_business and mi.sku = p.codigo) <> 1;
  if v_n > 0
     or (select count(*) from _tie_ids) <> v_total
     or (select count(distinct id) from _tie_ids) <> v_total then
    raise exception '% códigos sin producto o con más de uno. Revertido.', v_n;
  end if;

  select count(*) into v_n
  from _tie_ids i
  join public.menu_items mi on mi.id = i.id
  join _tie p on p.codigo = i.codigo
  left join public.categories c on c.id = mi.category_id
  where (p.price is not null and mi.price <> p.price)
     or mi.tax_mode <> 'inclusive'
     or c.id is null
     or lower(btrim(c.name)) <> lower(p.categoria)
     or (p.barcode is not null and mi.barcode is distinct from p.barcode);
  if v_n > 0 then
    raise exception '% artículos con precio, impuesto, categoría o código de barras incorrectos. Revertido.', v_n;
  end if;

  select count(*) into v_n
  from _tie_ids i
  where not exists (select 1 from public.menu_item_taxes x
                    where x.item_id = i.id and x.tax_id = v_tax_id)
     or exists (select 1 from public.menu_item_taxes x
                where x.item_id = i.id and x.tax_id <> v_tax_id);
  if v_n > 0 then
    raise exception '% artículos sin ITBIS o con otro impuesto. Revertido.', v_n;
  end if;

  select count(*) into v_n
  from _tie_ids i
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
    raise exception '% artículos con el área de comanda en desacuerdo. Revertido.', v_n;
  end if;

  select count(*) into v_n
  from _tie_ids i
  where not exists (select 1 from public.menu_item_links l
                    where l.menu_id = v_menu_id and l.item_id = i.id);
  if v_n > 0 then
    raise exception '% artículos fuera del menú: no saldrían en la caja. Revertido.', v_n;
  end if;

  select count(*) into v_n
  from _tie p
  join _tie_ids i on i.codigo = p.codigo
  join public.menu_items mi on mi.id = i.id
  left join public.inventory_items ii
    on ii.id = mi.inventory_item_id and ii.business_id = v_business
  where (p.inventariable
         and (not coalesce(mi.is_inventory_tracked, false) or ii.id is null))
     or not mi.allow_negative_sale;
  if v_n > 0 then
    raise exception '% artículos inventariables sin insumo o sin "vender aunque esté agotado". Revertido.', v_n;
  end if;

  select count(*) into v_n
  from (select item_id from _tie_insumo_de
        group by item_id having count(*) > 1) z;
  if v_n > 0 then
    raise exception '% insumos compartidos por varios artículos: descontarían cruzado. Revertido.', v_n;
  end if;

  if (select inventory_mode from public.business_settings
      where business_id = v_business) not in ('basic', 'advanced') then
    raise exception 'inventory_mode no quedó en basic/advanced. Revertido.';
  end if;

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
    raise exception 'Códigos de barras repetidos en artículos activos (%). Revertido.', v_list;
  end if;

  raise notice 'OK — % artículos (% nuevos, % actualizados) · % insumos nuevos · bodega "%" · comanda: % · Commit.',
    v_total, v_nuevos, v_actualizados, v_insumos, v_wh_name,
    coalesce(v_area_code, 'ninguna (cocina apagada)');
end $$;

commit;

-- ============================================================================
-- REPORTE — todas las filas deben decir ✓
-- ============================================================================

with codigos as (
  select unnest(string_to_array(
    '1224,110000100497,097512510264,110000100718,1223,110000100420,110000100421,110000100424,110000100428,110000100649,766871822508,1052,1069,110000100463,110000100726,110000100427,1105,1108,1238,1228,110000100419,887768339241,110000100488,1229,110000100486,110000100485,110000100487,110000100484,110000100482,110000100489,110000100490,110000100418,110000100515,110000100414,110000100417,110000100413,110000100514,110000100415,110000100416,110000100483,110000100524,110000100422,110000100423,1226,1227,8435536789372,097512831048,1107,1124,1106,6165010781128,6165010781050,6165010781111,8435536788504,110000100001,110000100375,110000100002,110000100003,110000100376,110000100004,110000100005,110000100006,110000100007,110000100008,1066,110000100010,110000100011,110000100012,110000100013,110000100014,110000100015,110000100009,110000100016,110000100017,110000100018,110000100019,110000100382,110000100020,110000100021,110000100022,110000100023,110000100024,110000100025,110000100026,110000100027,110000100028,110000100029,110000100030,110000100031,110000100032,110000100033,110000100383,110000100405,110000100406,110000100035,110000100036,110000100037,110000100034,110000100536,110000100038,110000100039,110000100537,110000100538,110000100221,110000100224,110000100223,110000100222,110000100225,110000100228,110000100227,110000100226,110000100539,110000100040,110000100041,110000100042,110000100043,110000100044,110000100045,110000100046,110000100047,110000100403,110000100402,110000100401,110000100404,110000100397,110000100398,110000100399,110000100400,110000100048,110000100246,110000100049,110000100050,110000100051,110000100052,110000100053,110000100054,110000100055,110000100056,110000100057,1073,1074,1075,110000100058,110000100059,110000100061,110000100062,110000100395,110000100396,110000100063,110000100381,110000100064,110000100065,110000100066,110000100067,110000100068,110000100069,110000100070,110000100071,110000100072,110000100073,110000100074,110000100407,110000100408,110000100377,110000100378,110000100075,110000100076,110000100077,110000100078,110000100079,110000100080,110000100081,110000100082,110000100083,110000100084,110000100085,110000100086,110000100087,110000100380,110000100379,110000100088,110000100089,110000100090,110000100091,110000100092,110000100093,110000100094,110000100095,110000100096,110000100097,110000100098,110000100099,110000100100,110000100411,110000100101,110000100102,110000100103,110000100104,110000100105,110000100106,110000100107,110000100108,110000100109,110000100110,110000100111,110000100112,110000100113,110000100114,110000100409,110000100410,110000100115,110000100116,110000100268,110000100117,110000100118,110000100249,110000100248,110000100247,110000100715,110000100119,110000100120,110000100121,110000100122,110000100123,110000100124,1131,1130,1213,110000100125,110000100126,110000100127,110000100128,110000100129,110000100130,110000100131,110000100132,110000100250,1208,110000100133,1209,1210,1211,110000100134,110000100135,110000100136,110000100137,110000100138,1199,1198,110000100140,110000100141,110000100142,110000100154,110000100144,110000100145,110000100146,110000100147,110000100148,110000100149,110000100150,110000100469,110000100470,110000100472,110000100468,110000100471,110000100465,110000100466,110000100467,110000100151,110000100388,1027,1028,1029,40650000,1025,X001X38ZF1,110000100440,110000100439,110000100504,1187,110000100060,110000100707,110000100543,110000100694,1021,1054,110000100495,1033,110000100363,8034044828117,110000100438,110000100426,110000100425,110000100587,8034044828100,8034044828155,1076,1077,1078,1031,1053,1197,1243,110000100571,1236,1030,8034044838079,110000100435,8034044838062,110000100437,110000100695,110000100547,110000100546,110000100545,110000100548,110000100544,8034044838116,1032,1188,1190,1189,1191,1233,1234,1235,1237,110000100513,1023,196473749291,1026,1022,1024,196608848431,1196,1193,1195,1192,1194,110000100549,110000100550,110000100492,110000100494,110000100493,110000100491,110000100450,1017,110000100449,110000100579,1065,1020,1221,110000100139,1137', ',')) as codigo
),
items as (
  select mi.*
  from public.menu_items mi
  join codigos c on c.codigo = mi.sku
  where mi.business_id = '40b0fa9d-9ce6-4e17-902d-6f5f37cc58ab'::uuid
),
itbis as (
  select t.* from public.taxes t
  where t.business_id = '40b0fa9d-9ce6-4e17-902d-6f5f37cc58ab'::uuid
    and t.name ilike '%itbis%' and t.rate = 18 and coalesce(t.is_active, true)
  limit 1
),
bs as (
  select * from public.business_settings
  where business_id = '40b0fa9d-9ce6-4e17-902d-6f5f37cc58ab'::uuid
),
r(orden, concepto, encontrado, esperado, ok) as (
  select 1, 'Artículos de la lista',
         (select count(*) from items)::text, '353',
         (select count(*) from items) = 353
  union all
  select 2, 'Activos en $0 (la caja los cobra GRATIS: ponles precio)',
         (select count(*) from items where is_active and price <= 0)::text
           || ' de ' || (select count(*) filter (where is_active) from items) || ' activos',
         '0',
         (select count(*) from items where is_active and price <= 0) = 0
  union all
  select 3, 'Con precio (activos)',
         (select count(*) from items where price > 0)::text, '341 o más',
         (select count(*) from items where price > 0) >= 341
  union all
  select 4, 'Con ITBIS incluido (inclusive)',
         (select count(*) from items where tax_mode = 'inclusive')::text, '353',
         (select count(*) from items where tax_mode = 'inclusive') = 353
  union all
  select 5, 'Vinculados SOLO al ITBIS 18%',
         (select count(*) from items i
           where exists (select 1 from public.menu_item_taxes x
                         join itbis t on t.id = x.tax_id where x.item_id = i.id)
             and not exists (select 1 from public.menu_item_taxes x
                             where x.item_id = i.id
                               and x.tax_id not in (select id from itbis)))::text,
         '353',
         (select count(*) from items i
           where exists (select 1 from public.menu_item_taxes x
                         join itbis t on t.id = x.tax_id where x.item_id = i.id)
             and not exists (select 1 from public.menu_item_taxes x
                             where x.item_id = i.id
                               and x.tax_id not in (select id from itbis))) = 353
  union all
  select 6, 'Enlazados al menú de la caja',
         (select count(*) from items i where exists (
            select 1 from public.menu_item_links l where l.item_id = i.id))::text,
         '353',
         (select count(*) from items i where exists (
            select 1 from public.menu_item_links l where l.item_id = i.id)) = 353
  union all
  select 7, 'Comanda',
         case when (select coalesce(kitchen_enabled, true) from bs)
              then 'cocina encendida → ' || coalesce((select string_agg(distinct print_area_code, ',') from items), '—')
              else 'cocina apagada, sin comanda' end,
         'apagada, o una sola área',
         case when (select coalesce(kitchen_enabled, true) from bs)
              then (select count(distinct print_area_code) from items) = 1
              else (select count(*) from items where print_area_code is not null) = 0 end
  union all
  select 8, 'Inventariables con su insumo',
         (select count(*) from items i
           where i.is_inventory_tracked and i.inventory_item_id is not null)::text,
         '344',
         (select count(*) from items i
           where i.is_inventory_tracked and i.inventory_item_id is not null) = 344
  union all
  select 9, '"Vender aunque esté agotado"',
         (select count(*) from items where allow_negative_sale)::text, '353',
         (select count(*) from items where allow_negative_sale) = 353
  union all
  select 10, 'Existencia de lo cargado (arranca en 0; baja con ventas)',
         coalesce((select sum(st.quantity) from public.inventory_stock st
                    where st.item_id in (select inventory_item_id from items)), 0)::text,
         '0 o menos',
         coalesce((select sum(st.quantity) from public.inventory_stock st
                    where st.item_id in (select inventory_item_id from items)), 0) <= 0
  union all
  select 11, 'Modo de inventario',
         (select inventory_mode from bs), 'basic o advanced',
         (select inventory_mode from bs) in ('basic', 'advanced')
  union all
  select 12, 'Con código de barras',
         (select count(*) from items where nullif(btrim(barcode), '') is not null)::text,
         '17 o más',
         (select count(*) from items where nullif(btrim(barcode), '') is not null) >= 17
  union all
  select 13, 'Códigos de barras repetidos (activos, toda la tienda)',
         (select count(*) from (
            select barcode from public.menu_items
            where business_id = '40b0fa9d-9ce6-4e17-902d-6f5f37cc58ab'::uuid
              and is_active and nullif(btrim(barcode), '') is not null
            group by barcode having count(*) > 1) z)::text,
         '0',
         (select count(*) from (
            select barcode from public.menu_items
            where business_id = '40b0fa9d-9ce6-4e17-902d-6f5f37cc58ab'::uuid
              and is_active and nullif(btrim(barcode), '') is not null
            group by barcode having count(*) > 1) z) = 0
  union all
  select 14, 'ITBIS se cobra en venta rápida',
         coalesce((select case when apply_on_quick then 'sí' else 'NO' end from itbis), '—'),
         'sí',
         coalesce((select apply_on_quick from itbis), false)
)
select concepto, encontrado, esperado,
       case when ok then '✓' else '✗ REVISAR' end as estado
from r
order by orden;
