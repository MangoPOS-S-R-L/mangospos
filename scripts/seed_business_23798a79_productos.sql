-- =============================================================================
-- Seed de productos: LAS TRES CRUCES FOOD SHOP
-- Business: 23798a79-fc43-4aec-80e0-219b0e183d4f
-- =============================================================================
-- 684 productos en 22 categorias. Generado por scripts/gen_tres_cruces.py
-- Fuente: PDF 'Listado de Productos las tres cruces food shop'.
--
-- Mapeo: name=DESCRIPCION (limpia), price=P.PUBLICO, cost=P.COMPRA,
--        sku=CODIGO, barcode=CODIGO si es numerico, tax=IMPUESTO.
--
-- tax_mode='inclusive': el P.PUBLICO YA incluye ITBIS (precio de gondola).
-- Se ligan impuestos via menu_item_taxes: EXENTO=0%, ITBIS 18%, ITBIS 16%.
-- Sin tracking de inventario (catalogo). Activar por producto desde el form.
--
-- Idempotente: re-ejecutar no duplica (guarda por sku / nombre de tax/categoria).
-- =============================================================================

begin;

-- ----------------------------------------------------------------------------
-- 1) Categorias
-- ----------------------------------------------------------------------------
insert into public.categories (id, business_id, name, position, is_active)
select gen_random_uuid(), '23798a79-fc43-4aec-80e0-219b0e183d4f', 'CERVEZAS', 0, true
where not exists (
  select 1 from public.categories
  where business_id = '23798a79-fc43-4aec-80e0-219b0e183d4f' and name = 'CERVEZAS'
);
insert into public.categories (id, business_id, name, position, is_active)
select gen_random_uuid(), '23798a79-fc43-4aec-80e0-219b0e183d4f', 'RONES', 1, true
where not exists (
  select 1 from public.categories
  where business_id = '23798a79-fc43-4aec-80e0-219b0e183d4f' and name = 'RONES'
);
insert into public.categories (id, business_id, name, position, is_active)
select gen_random_uuid(), '23798a79-fc43-4aec-80e0-219b0e183d4f', 'WHISKY', 2, true
where not exists (
  select 1 from public.categories
  where business_id = '23798a79-fc43-4aec-80e0-219b0e183d4f' and name = 'WHISKY'
);
insert into public.categories (id, business_id, name, position, is_active)
select gen_random_uuid(), '23798a79-fc43-4aec-80e0-219b0e183d4f', 'TEQUILA', 3, true
where not exists (
  select 1 from public.categories
  where business_id = '23798a79-fc43-4aec-80e0-219b0e183d4f' and name = 'TEQUILA'
);
insert into public.categories (id, business_id, name, position, is_active)
select gen_random_uuid(), '23798a79-fc43-4aec-80e0-219b0e183d4f', 'VODKA', 4, true
where not exists (
  select 1 from public.categories
  where business_id = '23798a79-fc43-4aec-80e0-219b0e183d4f' and name = 'VODKA'
);
insert into public.categories (id, business_id, name, position, is_active)
select gen_random_uuid(), '23798a79-fc43-4aec-80e0-219b0e183d4f', 'VINOS', 5, true
where not exists (
  select 1 from public.categories
  where business_id = '23798a79-fc43-4aec-80e0-219b0e183d4f' and name = 'VINOS'
);
insert into public.categories (id, business_id, name, position, is_active)
select gen_random_uuid(), '23798a79-fc43-4aec-80e0-219b0e183d4f', 'LICORES', 6, true
where not exists (
  select 1 from public.categories
  where business_id = '23798a79-fc43-4aec-80e0-219b0e183d4f' and name = 'LICORES'
);
insert into public.categories (id, business_id, name, position, is_active)
select gen_random_uuid(), '23798a79-fc43-4aec-80e0-219b0e183d4f', 'COCTELES', 7, true
where not exists (
  select 1 from public.categories
  where business_id = '23798a79-fc43-4aec-80e0-219b0e183d4f' and name = 'COCTELES'
);
insert into public.categories (id, business_id, name, position, is_active)
select gen_random_uuid(), '23798a79-fc43-4aec-80e0-219b0e183d4f', 'REFRESCOS', 8, true
where not exists (
  select 1 from public.categories
  where business_id = '23798a79-fc43-4aec-80e0-219b0e183d4f' and name = 'REFRESCOS'
);
insert into public.categories (id, business_id, name, position, is_active)
select gen_random_uuid(), '23798a79-fc43-4aec-80e0-219b0e183d4f', 'JUGOS', 9, true
where not exists (
  select 1 from public.categories
  where business_id = '23798a79-fc43-4aec-80e0-219b0e183d4f' and name = 'JUGOS'
);
insert into public.categories (id, business_id, name, position, is_active)
select gen_random_uuid(), '23798a79-fc43-4aec-80e0-219b0e183d4f', 'AGUA', 10, true
where not exists (
  select 1 from public.categories
  where business_id = '23798a79-fc43-4aec-80e0-219b0e183d4f' and name = 'AGUA'
);
insert into public.categories (id, business_id, name, position, is_active)
select gen_random_uuid(), '23798a79-fc43-4aec-80e0-219b0e183d4f', 'ENERGIZANTES', 11, true
where not exists (
  select 1 from public.categories
  where business_id = '23798a79-fc43-4aec-80e0-219b0e183d4f' and name = 'ENERGIZANTES'
);
insert into public.categories (id, business_id, name, position, is_active)
select gen_random_uuid(), '23798a79-fc43-4aec-80e0-219b0e183d4f', 'SNACKS', 12, true
where not exists (
  select 1 from public.categories
  where business_id = '23798a79-fc43-4aec-80e0-219b0e183d4f' and name = 'SNACKS'
);
insert into public.categories (id, business_id, name, position, is_active)
select gen_random_uuid(), '23798a79-fc43-4aec-80e0-219b0e183d4f', 'DULCES', 13, true
where not exists (
  select 1 from public.categories
  where business_id = '23798a79-fc43-4aec-80e0-219b0e183d4f' and name = 'DULCES'
);
insert into public.categories (id, business_id, name, position, is_active)
select gen_random_uuid(), '23798a79-fc43-4aec-80e0-219b0e183d4f', 'GALLETAS', 14, true
where not exists (
  select 1 from public.categories
  where business_id = '23798a79-fc43-4aec-80e0-219b0e183d4f' and name = 'GALLETAS'
);
insert into public.categories (id, business_id, name, position, is_active)
select gen_random_uuid(), '23798a79-fc43-4aec-80e0-219b0e183d4f', 'CEREALES', 15, true
where not exists (
  select 1 from public.categories
  where business_id = '23798a79-fc43-4aec-80e0-219b0e183d4f' and name = 'CEREALES'
);
insert into public.categories (id, business_id, name, position, is_active)
select gen_random_uuid(), '23798a79-fc43-4aec-80e0-219b0e183d4f', 'CIGARRILLOS', 16, true
where not exists (
  select 1 from public.categories
  where business_id = '23798a79-fc43-4aec-80e0-219b0e183d4f' and name = 'CIGARRILLOS'
);
insert into public.categories (id, business_id, name, position, is_active)
select gen_random_uuid(), '23798a79-fc43-4aec-80e0-219b0e183d4f', 'VAPES', 17, true
where not exists (
  select 1 from public.categories
  where business_id = '23798a79-fc43-4aec-80e0-219b0e183d4f' and name = 'VAPES'
);
insert into public.categories (id, business_id, name, position, is_active)
select gen_random_uuid(), '23798a79-fc43-4aec-80e0-219b0e183d4f', 'CAFE', 18, true
where not exists (
  select 1 from public.categories
  where business_id = '23798a79-fc43-4aec-80e0-219b0e183d4f' and name = 'CAFE'
);
insert into public.categories (id, business_id, name, position, is_active)
select gen_random_uuid(), '23798a79-fc43-4aec-80e0-219b0e183d4f', 'COMIDA', 19, true
where not exists (
  select 1 from public.categories
  where business_id = '23798a79-fc43-4aec-80e0-219b0e183d4f' and name = 'COMIDA'
);
insert into public.categories (id, business_id, name, position, is_active)
select gen_random_uuid(), '23798a79-fc43-4aec-80e0-219b0e183d4f', 'SALUD', 20, true
where not exists (
  select 1 from public.categories
  where business_id = '23798a79-fc43-4aec-80e0-219b0e183d4f' and name = 'SALUD'
);
insert into public.categories (id, business_id, name, position, is_active)
select gen_random_uuid(), '23798a79-fc43-4aec-80e0-219b0e183d4f', 'OTROS', 21, true
where not exists (
  select 1 from public.categories
  where business_id = '23798a79-fc43-4aec-80e0-219b0e183d4f' and name = 'OTROS'
);

-- ----------------------------------------------------------------------------
-- 2) Impuestos (ITBIS). Solo columnas base; el resto toma defaults
--    (apply_on_* = true, is_service_fee = false).
-- ----------------------------------------------------------------------------
insert into public.taxes (id, business_id, name, rate, is_active)
select gen_random_uuid(), '23798a79-fc43-4aec-80e0-219b0e183d4f', 'EXENTO', 0, true
where not exists (
  select 1 from public.taxes
  where business_id = '23798a79-fc43-4aec-80e0-219b0e183d4f' and name = 'EXENTO'
);
insert into public.taxes (id, business_id, name, rate, is_active)
select gen_random_uuid(), '23798a79-fc43-4aec-80e0-219b0e183d4f', 'ITBIS 18%', 18, true
where not exists (
  select 1 from public.taxes
  where business_id = '23798a79-fc43-4aec-80e0-219b0e183d4f' and name = 'ITBIS 18%'
);
insert into public.taxes (id, business_id, name, rate, is_active)
select gen_random_uuid(), '23798a79-fc43-4aec-80e0-219b0e183d4f', 'ITBIS 16%', 16, true
where not exists (
  select 1 from public.taxes
  where business_id = '23798a79-fc43-4aec-80e0-219b0e183d4f' and name = 'ITBIS 16%'
);

-- ----------------------------------------------------------------------------
-- 3) Productos -> tabla temporal -> menu_items + menu_item_taxes
-- ----------------------------------------------------------------------------
create temporary table tmp_tc (
  sku text, name text, price numeric(12,2), cost numeric(12,2),
  taxname text, catname text, is_bev boolean, has_prep boolean, pos int
) on commit drop;

insert into tmp_tc (sku, name, price, cost, taxname, catname, is_bev, has_prep, pos) values
  ('07811403', 'CANADA DRY GINGER ALE VERDE', 100, 55, 'EXENTO', 'REFRESCOS', true, false, 0),
  ('088004144722', 'FIREBALL 375ML', 925, 740, 'ITBIS 16%', 'LICORES', true, false, 1),
  ('088004144708', 'MINIATURA FIREBALL', 125, 93, 'EXENTO', 'LICORES', true, false, 2),
  ('088004144739', 'FIREBALL 200ML', 500, 380, 'ITBIS 16%', 'LICORES', true, false, 3),
  ('721733005888', 'PATRON SILVER 700ML', 3792, 2917, 'ITBIS 16%', 'TEQUILA', true, false, 4),
  ('30021662', 'REMY MARTIN MINIATURA', 450, 320, 'EXENTO', 'LICORES', true, false, 5),
  ('5000281056241', 'DON JULIO REPOSADO', 5460, 4200, 'ITBIS 16%', 'TEQUILA', true, false, 6),
  ('721733002566', 'PATRON REPOSADO', 4332, 3333, 'EXENTO', 'TEQUILA', true, false, 7),
  ('3024480004522', 'REMY MARTIN', 12220, 9400, 'EXENTO', 'LICORES', true, false, 8),
  ('5000281056265', 'DON JULIO 70 CRISTALINO 700ML', 6060, 4666, 'ITBIS 16%', 'TEQUILA', true, false, 9),
  ('7501035013483', 'TEQUILA 1800', 3900, 3000, 'EXENTO', 'TEQUILA', true, false, 10),
  ('4750021000157', 'STOLI 750ML', 1095, 833, 'EXENTO', 'VODKA', true, false, 11),
  ('619947000020', 'TITOS VODKA', 1700, 1325, 'ITBIS 18%', 'VODKA', true, false, 12),
  ('7501035010109', 'JOSE CUERVO 750ML REPOSADO', 1580, 1216, 'EXENTO', 'TEQUILA', true, false, 13),
  ('7501035042322', 'JOSE CUERVO 750ML SILVER', 1580, 1216, 'ITBIS 18%', 'TEQUILA', true, false, 14),
  ('012354000995', '19 CRIMES', 1462, 1125, 'EXENTO', 'VINOS', true, false, 15),
  ('080887496431', 'BOGLE FAMILY', 1462, 1125, 'EXENTO', 'VINOS', true, false, 16),
  ('3024482270109', 'REMY MARTIN', 4117, 3167, 'EXENTO', 'LICORES', true, false, 17),
  ('088004146689', 'FIREBALL 750ML', 1508, 1160, 'EXENTO', 'LICORES', true, false, 18),
  ('088004009281', 'FIREBALL 1750ML MEDIO GALON', 3375, 2700, 'EXENTO', 'LICORES', true, false, 19),
  ('071990300364', 'COORS LIGHT 22FL', 200, 141, 'EXENTO', 'CERVEZAS', true, false, 20),
  ('034100173074', 'MILLER LATA 473ML', 150, 107, 'EXENTO', 'CERVEZAS', true, false, 21),
  ('034100005528', 'MILLER GENUINE DRAFT 10OZ', 110, 70, 'EXENTO', 'CERVEZAS', true, false, 22),
  ('03456217', 'MILLER PEQUENA 12OZ', 175, 118, 'EXENTO', 'CERVEZAS', true, false, 23),
  ('034100005696', 'MILLER GRANDE 22OZ', 210, 156, 'EXENTO', 'CERVEZAS', true, false, 24),
  ('871200030582', 'HEINEKEN 650ML', 200, 170, 'EXENTO', 'CERVEZAS', true, false, 25),
  ('072890006196', 'HEINEKEN 0.0 330ML SIN ALCOHOL', 175, 124, 'EXENTO', 'CERVEZAS', true, false, 26),
  ('072890004994', 'HEINEKEN 330ML', 175, 128, 'ITBIS 18%', 'CERVEZAS', true, false, 27),
  ('071990320003', 'COORS LIGHT 16OZ LATA', 125, 85, 'ITBIS 18%', 'CERVEZAS', true, false, 28),
  ('08780538', 'COORS LIGHT 10OZ LATA', 90, 69, 'EXENTO', 'CERVEZAS', true, false, 29),
  ('87120103', 'HEINEKEN 250ML LATA PEQUENA', 110, 70, 'EXENTO', 'CERVEZAS', true, false, 30),
  ('8712000900045', 'HEINEKEN 500ML', 160, 121, 'EXENTO', 'CERVEZAS', true, false, 31),
  ('8411327011181', 'MAHOU SIN 250ML SIN ALCOHOL', 80, 61, 'EXENTO', 'CERVEZAS', true, false, 32),
  ('89005217', 'ROYAL STAG MINI', 130, 93, 'EXENTO', 'WHISKY', true, false, 33),
  ('08787337', 'BLUE MOON 355ML', 180, 139, 'EXENTO', 'CERVEZAS', true, false, 34),
  ('5411681403656', 'DUVEL BOX + COPA 330ML', 583, 449, 'EXENTO', 'CERVEZAS', true, false, 35),
  ('3119780264285', 'DESPERADOS MOJITO 330ML', 180, 133, 'EXENTO', 'CERVEZAS', true, false, 36),
  ('75001629', 'SOL BOTELLA 355ML', 150, 116, 'EXENTO', 'CERVEZAS', true, false, 37),
  ('8008440249425', 'ASAHI SUPER DRY 330ML', 180, 141, 'EXENTO', 'CERVEZAS', true, false, 38),
  ('072311130110', 'DOS EQUIS AMBAR 335ML', 180, 130, 'EXENTO', 'CERVEZAS', true, false, 39),
  ('072311130127', 'DOS EQUIS', 180, 130, 'EXENTO', 'CERVEZAS', true, false, 40),
  ('087692000051', 'SAMUEL ADAMS 335ML', 175, 133, 'EXENTO', 'CERVEZAS', true, false, 41),
  ('080432802533', 'SEAGRAMS STRAWBERRY 330ML', 160, 125, 'EXENTO', 'COCTELES', true, false, 42),
  ('3119780266494', 'DESPERADOS ORIGINAL', 180, 133, 'EXENTO', 'CERVEZAS', true, false, 43),
  ('635985500018', 'WHITE CLAW LATA', 160, 121, 'EXENTO', 'COCTELES', true, false, 44),
  ('08780936', 'COORS ORIGINAL BEER 335ML', 175, 113, 'EXENTO', 'CERVEZAS', true, false, 45),
  ('8712000051945', 'RED STRIPE 330ML', 195, 138, 'EXENTO', 'CERVEZAS', true, false, 46),
  ('5010106113493', 'BALLANTINES MINIATURA 200ML CHATA', 300, 190, 'EXENTO', 'WHISKY', true, false, 47),
  ('7411204841918', 'JUGOS PETIT 330ML VARIADOS', 65, 34, 'EXENTO', 'JUGOS', true, false, 48),
  ('7401005988547', 'SALUTARIS SODA MIX', 60, 31, 'EXENTO', 'REFRESCOS', true, false, 49),
  ('746054800178', 'GATORADE LIME 600ML', 70, 40, 'EXENTO', 'ENERGIZANTES', true, false, 50),
  ('746054800161', 'GATORADE UVA 600ML', 70, 40, 'EXENTO', 'ENERGIZANTES', true, false, 51),
  ('7460548002134', 'GATORADE ZERO ROJO', 60, 30, 'EXENTO', 'ENERGIZANTES', true, false, 52),
  ('7460548002127', 'GATORADE ZERO 500ML AZUL', 65, 40, 'EXENTO', 'ENERGIZANTES', true, false, 53),
  ('746054800154', 'GATORADE ROJO 600ML', 75, 40, 'EXENTO', 'ENERGIZANTES', true, false, 54),
  ('746054800185', 'GATORADE ORANGE 600ML', 70, 40, 'EXENTO', 'ENERGIZANTES', true, false, 55),
  ('7460548002141', 'GATORLIT RECOVER 591ML AZUL MORAS', 80, 53, 'EXENTO', 'ENERGIZANTES', true, false, 56),
  ('7460548002158', 'GATORLIT COCO', 80, 53, 'EXENTO', 'ENERGIZANTES', true, false, 57),
  ('024474002643', 'PETIT 1000ML COCTEL DE FRUTAS', 110, 73, 'EXENTO', 'JUGOS', true, false, 58),
  ('024474007006', 'PETIT MANZANA', 110, 73, 'EXENTO', 'JUGOS', true, false, 59),
  ('024474007228', 'PETIT PEACHES 600ML', 110, 73, 'EXENTO', 'JUGOS', true, false, 60),
  ('024474007044', 'PETIT PERA', 110, 73, 'ITBIS 18%', 'JUGOS', true, false, 61),
  ('031200009432', 'OCEAN SPRAY APPLE JUICE', 200, 152, 'EXENTO', 'JUGOS', true, false, 62),
  ('031200009401', 'OCEAN SPRAY APPLE JUICE 450ML', 65, 40, 'EXENTO', 'JUGOS', true, false, 63),
  ('764009024497', 'BAMBOO DAIQUIRI FRESA', 100, 76, 'EXENTO', 'COCTELES', true, false, 64),
  ('764009047984', 'BAMBOO PINA COLADA 350ML', 100, 73, 'EXENTO', 'COCTELES', true, false, 65),
  ('764009011671', 'BAMBOO MOJITO 350ML', 100, 73, 'EXENTO', 'COCTELES', true, false, 66),
  ('5000299210413', 'PASSPORT SELECTION 700ML', 950, 720, 'EXENTO', 'WHISKY', true, false, 67),
  ('096749021284', 'EVAN WILLIAMS FIRE 750ML', 1700, 1308, 'EXENTO', 'WHISKY', true, false, 68),
  ('096749021802', 'EVAN WILLIAMS HONEY 750ML', 1700, 1308, 'EXENTO', 'WHISKY', true, false, 69),
  ('096749021345', 'EVAN WILLIAMS 750ML', 1700, 1308, 'EXENTO', 'WHISKY', true, false, 70),
  ('088291100050', 'RON ABUELO ANEJO 750ML RESERVA ESPECIAL', 1047, 805, 'EXENTO', 'RONES', true, false, 71),
  ('860012986835', 'OZAMA GRAN ANEJO DAVID ORTIZ', 1340, 1031, 'EXENTO', 'RONES', true, false, 72),
  ('860012986828', 'OZAMA ANEJO 700ML DAVID ORTIZ', 1600, 1232, 'EXENTO', 'RONES', true, false, 73),
  ('860012986811', 'OZAMA BLANCO 700ML', 1236, 951, 'EXENTO', 'RONES', true, false, 74),
  ('7467325360692', 'CINCO DE MAYO', 1215, 935, 'EXENTO', 'TEQUILA', true, false, 75),
  ('7467325360708', 'CINCO DE MAYO GOLD 750ML', 1215, 935, 'EXENTO', 'TEQUILA', true, false, 76),
  ('856065002417', 'DEEP EDDY LEMON', 1531, 1178, 'EXENTO', 'VODKA', true, false, 77),
  ('3147699106327', 'LABEL 5 + 2 VASOS SCOTCH WHISKY', 1015, 781, 'EXENTO', 'WHISKY', true, false, 78),
  ('5060116321906', 'LABEL 5 GOLD COMBO', 2100, 1504, 'EXENTO', 'WHISKY', true, false, 79),
  ('080660000312', 'AMARETTO LIQUEUR 1L ROYALE CLUB', 650, 500.30, 'EXENTO', 'LICORES', true, false, 80),
  ('080660000305', 'BLUE CURACAO 1L ROYALE CLUB', 650, 500, 'EXENTO', 'LICORES', true, false, 81),
  ('5016840000211', 'HIGH COMMISSIONER 700ML SCOTCH WHISKY', 869, 669, 'EXENTO', 'WHISKY', true, false, 82),
  ('856065002080', 'DEEP EDDY RUBY RED', 1569, 1207, 'EXENTO', 'VODKA', true, false, 83),
  ('856065002035', 'DEEP EDDY VODKA BLANCO', 1575, 1207, 'EXENTO', 'VODKA', true, false, 84),
  ('5390424122460', 'KILROYS', 1015, 781, 'EXENTO', 'LICORES', true, false, 85),
  ('7503032535159', 'EL RECUERDO MEZCAL 750ML', 3844, 2957, 'EXENTO', 'LICORES', true, false, 86),
  ('096749908585', 'LUNAZUL ANEJO', 3149, 2423, 'EXENTO', 'TEQUILA', true, false, 87),
  ('096749908042', 'LUNAZUL REPOSADO', 2724, 2095, 'EXENTO', 'TEQUILA', true, false, 88),
  ('3147690061007', 'POLIAKOV PREMIUM VODKA', 1066, 820, 'EXENTO', 'VODKA', true, false, 89),
  ('8000428026257', 'PERLINO PINOT CHARDONNAY CHAMPAGNE', 794, 611, 'EXENTO', 'VINOS', true, false, 90),
  ('8000428023959', 'PERLINO SPUMANTE ROSE', 794, 611, 'EXENTO', 'VINOS', true, false, 91),
  ('5000299210444', 'PASSPORT SELECTION 1L', 1095, 843, 'EXENTO', 'WHISKY', true, false, 92),
  ('096749908035', 'LUNAZUL TEQUILA BLANCO', 2556, 1974, 'EXENTO', 'TEQUILA', true, false, 93),
  ('5011007003029', 'JAMESON 750ML', 2090, 1608, 'EXENTO', 'WHISKY', true, false, 94),
  ('080432500149', 'JAMESON 375ML MINI', 1066, 820, 'EXENTO', 'WHISKY', true, false, 95),
  ('3147699115473', 'TISCAZ ORO', 1410, 1085, 'EXENTO', 'TEQUILA', true, false, 96),
  ('3147699105597', 'TISCAZ TEQUILA BLANCO', 1410, 1085, 'EXENTO', 'TEQUILA', true, false, 97),
  ('080432108611', 'ALTOS TEQUILA ANEJO 750ML', 3521, 2709, 'EXENTO', 'TEQUILA', true, false, 98),
  ('080432106846', 'ALTOS TEQUILA', 2876, 2213, 'EXENTO', 'TEQUILA', true, false, 99),
  ('080432106853', 'ALTOS TEQUILA REPOSADO', 3024, 2334, 'EXENTO', 'TEQUILA', true, false, 100),
  ('7467325360012', 'SIBONEY RESERVA ESPECIAL', 1099, 846, 'EXENTO', 'RONES', true, false, 101),
  ('7467325360111', 'SIBONEY BLANCO', 800, 570, 'EXENTO', 'RONES', true, false, 102),
  ('7467325360050', 'SIBONEY ANEJO', 800, 572, 'EXENTO', 'RONES', true, false, 103),
  ('7467325360159', 'SIBONEY 34', 929, 715, 'EXENTO', 'RONES', true, false, 104),
  ('8901522004090', 'ROYAL STAG', 1030, 736, 'EXENTO', 'WHISKY', true, false, 105),
  ('7467325360166', 'SIBONEY 1920 GRAN RESERVA 700ML', 1390, 1076, 'EXENTO', 'RONES', true, false, 106),
  ('3012993082625', 'SCARLETT GOLD', 956, 736, 'EXENTO', 'VINOS', true, false, 107),
  ('3012993057012', 'SCARLETT DARK VINO CABERNET', 1050, 796, 'EXENTO', 'VINOS', true, false, 108),
  ('813497005607', 'BELAIRE ROSE CHAMPAGNE', 3815, 2935, 'EXENTO', 'VINOS', true, false, 109),
  ('813497007953', 'BLUE BELAIRE 1L', 4500, 3241, 'EXENTO', 'VINOS', true, false, 110),
  ('5000299611197', 'CHIVAS REGAL EXTRA 13', 3655, 2796, 'EXENTO', 'WHISKY', true, false, 111),
  ('3890000781088', 'BELUGA NOBLE VODKA', 3926, 3020, 'EXENTO', 'VODKA', true, false, 112),
  ('5010106111451', 'BALLANTINES 75ML', 1180, 908, 'EXENTO', 'WHISKY', true, false, 113),
  ('080432001882', 'BALLANTINES 10Y 750ML COMBO', 1800, 1290, 'EXENTO', 'WHISKY', true, false, 114),
  ('5010106111956', 'BALLANTINES 1L COMBO', 1600, 1092, 'EXENTO', 'WHISKY', true, false, 115),
  ('088291120355', 'RON ABUELO 12 ANOS', 2495, 1921, 'EXENTO', 'RONES', true, false, 116),
  ('088291110356', 'RON ABUELO 7 ANOS', 1608, 1237, 'EXENTO', 'RONES', true, false, 117),
  ('8501110080439', 'HAVANA CLUB 7 ANOS', 1631, 1255, 'EXENTO', 'RONES', true, false, 118),
  ('8501110089852', 'ICONICA HAVANA CLUB GRAN ANEJO', 4321, null, 'EXENTO', 'RONES', true, false, 119),
  ('080432400432', 'CHIVAS 12 1LITRO', 3610, 2777, 'EXENTO', 'WHISKY', true, false, 120),
  ('5000299626238', 'CHIVAS REAL 13 ANOS 750ML', 3684, 2796, 'EXENTO', 'WHISKY', true, false, 121),
  ('080432400395', 'CHIVAS 12 ANOS 750ML', 2350, 1900, 'EXENTO', 'WHISKY', true, false, 122),
  ('5000299225028', 'CHIVAS REGAL 18 ANOS 750ML', 3990, 2796, 'EXENTO', 'WHISKY', true, false, 123),
  ('5010106110157', 'BALLANTINES 17 ANOS 750ML', 6031, 4632, 'EXENTO', 'WHISKY', true, false, 124),
  ('5011166081104', 'WHITLEY NEILL GIN 700ML BLOOD ORANGE', 1931, 1486, 'EXENTO', 'LICORES', true, false, 125),
  ('5011166068020', 'WHITLEY NEILL GIN LONDON DRY', 1950, 1486, 'EXENTO', 'LICORES', true, false, 126),
  ('5011166081128', 'WHITLEY NEILL GIN RHUBARB Y GINGER', 1950, 1486, 'EXENTO', 'LICORES', true, false, 127),
  ('7401005007972', 'BOTRAN 8 ANOS RON DE GUATEMALA', 1781, 1370, 'EXENTO', 'RONES', true, false, 128),
  ('3147690060703', 'GIBSONS LONDON DRY GIN', 1150, 886, 'EXENTO', 'LICORES', true, false, 129),
  ('813497003047', 'THE DEACON SCOTLAND 700ML', 2932, 2256, 'EXENTO', 'WHISKY', true, false, 130),
  ('5000267112077', 'JOHNNIE WALKER DOUBLE BLACK 1L', 3890, 2520, 'EXENTO', 'WHISKY', true, false, 131),
  ('5000196001695', 'BUCHANANS 18 ANOS 750ML SPECIAL RESERVE', 5700, 3980, 'EXENTO', 'WHISKY', true, false, 132),
  ('5000196002807', 'BUCHANANS 12 ANOS 1000ML', 3560, 1980, 'EXENTO', 'WHISKY', true, false, 133),
  ('5000267196244', 'JOHNNIE WALKER BLACK RUBY 1L', 3990, 2500, 'EXENTO', 'WHISKY', true, false, 134),
  ('5000267023601', 'JOHNNIE NEGRO 1L', 3600, 1980, 'EXENTO', 'WHISKY', true, false, 135),
  ('5000299622025', 'CHIVAS REGAL 15 ANOS', 4490, 2980, 'EXENTO', 'WHISKY', true, false, 136),
  ('5000281004020', 'OLD PARR 12 ANOS 1L', 2890, 1980, 'EXENTO', 'WHISKY', true, false, 137),
  ('5000267114293', 'JOHNNIE BLUE LABEL 1L', 20990, 17532, 'EXENTO', 'WHISKY', true, false, 138),
  ('5000299211243', 'CHIVAS ROYAL SALUTE 21 ANOS 700ML', 14990, 10260, 'EXENTO', 'WHISKY', true, false, 139),
  ('5000267197753', 'JOHNNIE GOLD LABEL RESERVA 1000ML', 4800, 3800, 'EXENTO', 'WHISKY', true, false, 140),
  ('721733002634', 'PATRON SILVER 1L', 4320, 2820, 'EXENTO', 'TEQUILA', true, false, 141),
  ('3185370773017', 'MOET CHANDON ICE IMPERIAL 750ML', 4950, 3600, 'EXENTO', 'VINOS', true, false, 142),
  ('088004144678', 'FIREBALL 1LITRO', 1690, 900, 'EXENTO', 'LICORES', true, false, 143),
  ('012000130311', 'MOUNTAIN DEW BAJA BLAST TROPICAL', 125, 53, 'EXENTO', 'REFRESCOS', true, false, 144),
  ('07831504', 'DR PEPPER', 100, 45, 'EXENTO', 'REFRESCOS', true, false, 145),
  ('CARGADOR', 'CARGADOR CARGA RAPIDA', 590, 85, 'EXENTO', 'OTROS', false, false, 146),
  ('HIELO', 'HIELO CASCADA', 80, 55, 'EXENTO', 'OTROS', false, false, 147),
  ('049000030761', 'FANTA STRAWBERRY', 125, 45, 'EXENTO', 'REFRESCOS', true, false, 148),
  ('01275900', 'LIPTON BRISK LEMON ICED TEA 12FL', 100, 47, 'EXENTO', 'REFRESCOS', true, false, 149),
  ('031200015303', 'OCEAN SPRAY CRANBERRY 10FL', 70, 54, 'EXENTO', 'JUGOS', true, false, 150),
  ('041508800082', 'S. PELLEGRINO AGUA CON GAS', 125, 90, 'EXENTO', 'AGUA', true, false, 151),
  ('613008724221', 'ARIZONA GREEN TEA', 139, 48, 'EXENTO', 'REFRESCOS', true, false, 152),
  ('193968284664', 'SPARKLING WATER VARIETY PACK MEMBERS MARK 17FL', 100, 44, 'EXENTO', 'AGUA', true, false, 153),
  ('CAPRISUN', 'CAPRI SUN 6FL VARIETY PACK', 50, 30, 'EXENTO', 'JUGOS', true, false, 154),
  ('810113830049', 'BODYARMOR LYTE 12FL', 175, 54, 'EXENTO', 'ENERGIZANTES', true, false, 155),
  ('050200013171', 'SUNNYD TANGY ORIGINAL ORANGE', 45, 34, 'EXENTO', 'JUGOS', true, false, 156),
  ('031200025319', 'OCEAN SPRAY TROPICAL', 100, 54, 'EXENTO', 'JUGOS', true, false, 157),
  ('031200011831', 'OCEAN SPRAY CRAN X WATERMELON 10FL', 100, 54, 'EXENTO', 'JUGOS', true, false, 158),
  ('031200024916', 'OCEAN SPRAY TROPICAL JUICE', 100, 54, 'EXENTO', 'JUGOS', true, false, 159),
  ('031200014030', 'OCEAN SPRAY TROPICAL JUICE 2', 100, 54, 'EXENTO', 'JUGOS', true, false, 160),
  ('889392010190', 'CELSIUS SPARKLING PEACH VIBE 12FL', 175, 97, 'EXENTO', 'ENERGIZANTES', true, false, 161),
  ('889392001723', 'CELSIUS SPARKLING RETRO VIBE', 175, 97, 'EXENTO', 'ENERGIZANTES', true, false, 162),
  ('889392021394', 'CELSIUS SPARKLING TROPICAL VIBE', 175, 97, 'EXENTO', 'ENERGIZANTES', true, false, 163),
  ('076406021802', 'JUMEX TROPICAL MANGO 11.3FL', 75, 54, 'EXENTO', 'JUGOS', true, false, 164),
  ('076406023103', 'JUMEX TROPICAL STRAWBERRY-BANANA', 75, 54, 'EXENTO', 'JUGOS', true, false, 165),
  ('076406021604', 'JUMEX TROPICAL GUAVA', 75, 54, 'EXENTO', 'JUGOS', true, false, 166),
  ('073360377518', 'LACROIX SPARKLING WATER LEMON', 76, 42, 'EXENTO', 'AGUA', true, false, 167),
  ('073360237515', 'LACROIX SPARKLING WATER LIME', 75, 42, 'EXENTO', 'AGUA', true, false, 168),
  ('012993101619', 'LACROIX SPARKLING WATER PAMPLEMOUSSE', 75, 42, 'EXENTO', 'AGUA', true, false, 169),
  ('04905004', 'COCA-COLA CHERRY SODA LATA', 125, 62, 'EXENTO', 'REFRESCOS', true, false, 170),
  ('038900009144', 'DOLE 100% PINEAPPLE JUICE', 80, 54, 'EXENTO', 'JUGOS', true, false, 171),
  ('04971502', 'SPRITE ZERO SODA LIMON LIME', 125, 26, 'EXENTO', 'REFRESCOS', true, false, 172),
  ('049000014235', 'FANTA ORANGE SODA 12FL', 125, 29, 'EXENTO', 'REFRESCOS', true, false, 173),
  ('078000037975', '7UP TROPICAL SODA LATA', 125, 29, 'EXENTO', 'REFRESCOS', true, false, 174),
  ('051000201768', 'V8 +ENERGY ORANGE PINEAPPLE', 130, 75, 'EXENTO', 'ENERGIZANTES', true, false, 175),
  ('051000292933', 'V8 ENERGY PASSIONFRUIT ORANGE GUAVA', 130, 75, 'EXENTO', 'ENERGIZANTES', true, false, 176),
  ('076183202012', 'SNAPPLE TEA PEACH 16FL', 150, 54, 'EXENTO', 'REFRESCOS', true, false, 177),
  ('076183202029', 'SNAPPLE TEA RASBERRY', 150, 54, 'EXENTO', 'REFRESCOS', true, false, 178),
  ('076183202005', 'SNAPPLE TEA LEMON', 150, 54, 'EXENTO', 'REFRESCOS', true, false, 179),
  ('810063711078', 'POPPI ORANGE PREBIOTIC SODA', 125, 83, 'EXENTO', 'REFRESCOS', true, false, 180),
  ('810063710071', 'POPPI PREBIOTIC SODA WILD BERRY', 125, 83, 'EXENTO', 'REFRESCOS', true, false, 181),
  ('044000015923', 'OREO MINIS CHOCOLATE 8OZ', 495, 197, 'EXENTO', 'GALLETAS', false, false, 182),
  ('016000236417', 'FRUIT GUSHERS SWEET Y FIERY', 325, 154, 'EXENTO', 'DULCES', false, false, 183),
  ('851681008379', 'HI-CHEW ASSORTED FRUIT CANDY', 663, 363, 'EXENTO', 'DULCES', false, false, 184),
  ('009800556014', 'KINDER BUENO MINIS SHARE PACK', 577, null, 'EXENTO', 'DULCES', false, false, 185),
  ('040000607243', 'M&M WHITE CHOCOLATE', 499, 377, 'EXENTO', 'DULCES', false, false, 186),
  ('041364087320', 'SOUR PUNCH ASSORTED FLAVOR BITES', 397, 197, 'EXENTO', 'DULCES', false, false, 187),
  ('011206001258', 'SMARTIES SQUASHIES CANDY', 215, 166, 'EXENTO', 'DULCES', false, false, 188),
  ('070462082517', 'SOUR PATCH KIDS WATERMELON', 237, 137, 'EXENTO', 'DULCES', false, false, 189),
  ('041116262197', 'RING POP LOLLIPOPS PARTY PACK', 744, 544, 'EXENTO', 'DULCES', false, false, 190),
  ('044000081423', 'OREO LOADED CHOCOLATE', 590, 340, 'EXENTO', 'GALLETAS', false, false, 191),
  ('044000060251', 'OREO DOUBLE STUF FAMILY SIZE', 595, 340, 'EXENTO', 'GALLETAS', false, false, 192),
  ('034000466481', 'REESE''S OREO PEANUT BUTTER CUPS', 150, 91, 'EXENTO', 'DULCES', false, false, 193),
  ('044000086039', 'OREO CAKESTERS CONFETTI', 370, 274, 'EXENTO', 'GALLETAS', false, false, 194),
  ('079200085391', 'NERDS JUICY GUMMY CLUSTERS', 357, 257, 'EXENTO', 'DULCES', false, false, 195),
  ('079200088125', 'NERDS GUMMY CLUSTERS CHERRY LEMONADE', 395, 257, 'EXENTO', 'DULCES', false, false, 196),
  ('079200060688', 'NERDS GUMMY CLUSTERS', 595, 354, 'EXENTO', 'DULCES', false, false, 197),
  ('073390612191', 'AIRHEADS MINI BARS CHEWY CANDY', 344, 244, 'EXENTO', 'DULCES', false, false, 198),
  ('051000217691', 'V8 SPLASH MANGO PEACH', 80, 53, 'EXENTO', 'JUGOS', true, false, 199),
  ('051000217684', 'V8 SPLASH BERRY BLEND 12OZ', 80, 54, 'EXENTO', 'JUGOS', true, false, 200),
  ('051000217745', 'V8 SPLASH 12FL', 80, 54, 'EXENTO', 'JUGOS', true, false, 201),
  ('076301590625', 'APPLE Y EVE 100% JUICE TROPICAL', 100, 52, 'EXENTO', 'JUGOS', true, false, 202),
  ('076301590762', 'APPLE Y EVE 100% JUICE ORANGE', 100, 52, 'EXENTO', 'JUGOS', true, false, 203),
  ('076301590052', 'APPLE Y EVE 100% JUICE MANZANA', 100, 50, 'EXENTO', 'JUGOS', true, false, 204),
  ('041800317004', 'WELCH''S VARIETY ORANGE PINEAPPLE 10FL', 90, 50, 'EXENTO', 'JUGOS', true, false, 205),
  ('041800490004', 'WELCH''S VARIETY 10FL', 100, 50, 'EXENTO', 'JUGOS', true, false, 206),
  ('041800354009', 'WELCH''S VARIETY 10FL 2', 100, 50, 'EXENTO', 'JUGOS', true, false, 207),
  ('858176002799', 'BODYARMOR MANGO 12OZ', 100, 50, 'EXENTO', 'ENERGIZANTES', true, false, 208),
  ('810113832715', 'BODYARMOR 12OZ LYTE', 100, 50, 'EXENTO', 'ENERGIZANTES', true, false, 209),
  ('810113832692', 'BODYARMOR STRAWBERRY BANANA', 100, 50, 'EXENTO', 'ENERGIZANTES', true, false, 210),
  ('810113832678', 'BODYARMOR BLUEBERRY 12FL', 100, 50, 'EXENTO', 'ENERGIZANTES', true, false, 211),
  ('031200024022', 'OCEAN SPRAY CRANBERRY JUICE 10FL', 105, 51, 'EXENTO', 'JUGOS', true, false, 212),
  ('031200015525', 'OCEAN SPRAY CRANBERRY JUICE 2', 105, 51, 'EXENTO', 'JUGOS', true, false, 213),
  ('031200015556', 'OCEAN SPRAY CRANBERRY JUICE 3', 105, 50, 'EXENTO', 'JUGOS', true, false, 214),
  ('041800316007', 'OCEAN SPRAY CRANBERRY JUICE 4', 105, 51, 'EXENTO', 'JUGOS', true, false, 215),
  ('028000616502', 'NESQUIK CHOCOLATE MILK 8FL', 158, 59, 'EXENTO', 'JUGOS', true, false, 216),
  ('041800326006', 'WELCH''S GRAPE', 100, 50, 'EXENTO', 'JUGOS', true, false, 217),
  ('041800301232', 'WELCH''S', 100, 50, 'EXENTO', 'JUGOS', true, false, 218),
  ('836093011551', 'IZZE PINEAPPLE SPARKLING JUICE', 105, 85, 'EXENTO', 'JUGOS', true, false, 219),
  ('096619204212', 'KIRKLAND VITA RAIN 20OZ', 125, 50.85, 'EXENTO', 'ENERGIZANTES', true, false, 220),
  ('096619192328', 'KIRKLAND VITA RAIN LEMONADE 20OZ', 125, 50.85, 'EXENTO', 'ENERGIZANTES', true, false, 221),
  ('096619204205', 'KIRKLAND VITA RAIN DRAGON FRUIT 20OZ', 125, 50.85, 'EXENTO', 'ENERGIZANTES', true, false, 222),
  ('096619204014', 'KIRKLAND MANGO VITAMIN 20OZ', 125, 50.85, 'EXENTO', 'ENERGIZANTES', true, false, 223),
  ('076171102287', 'LITTLE TREES AMBIENTADOR', 120, 81, 'EXENTO', 'OTROS', false, false, 224),
  ('016571960230', 'SPARKLING ICE WATERMELON 17FL', 110, 40, 'EXENTO', 'AGUA', true, false, 225),
  ('016571959203', 'SPARKLING ICE STRAWBERRY', 110, 45, 'EXENTO', 'AGUA', true, false, 226),
  ('016571959265', 'SPARKLING ICE CHERRY', 110, 45, 'EXENTO', 'AGUA', true, false, 227),
  ('016571960254', 'SPARKLING ICE FRUIT PUNCH', 110, 45, 'EXENTO', 'AGUA', true, false, 228),
  ('087684011744', 'CAPRI SUN SUMMER MANGO', 544, 244, 'EXENTO', 'JUGOS', true, false, 229),
  ('044000037451', 'NUTTER BUTTER SANDWICH COOKIES', 110, 79, 'EXENTO', 'GALLETAS', false, false, 230),
  ('028400261555', 'SABRITAS PEANUTS', 50, 33, 'EXENTO', 'SNACKS', false, false, 231),
  ('028400261531', 'SABRITAS PEANUTS SAL Y LIMON', 49, 34, 'EXENTO', 'SNACKS', false, false, 232),
  ('028400725163', 'SABRITAS PEANUTS HOT', 50, 34, 'EXENTO', 'SNACKS', false, false, 233),
  ('028400261548', 'SABRITAS PEANUTS SPICY', 50, 34, 'EXENTO', 'SNACKS', false, false, 234),
  ('044000035440', 'RITZ BITS', 455, 255, 'EXENTO', 'GALLETAS', false, false, 235),
  ('010700024404', 'WHOPPERS MALTED MILK BALLS', 234, 134, 'EXENTO', 'DULCES', false, false, 236),
  ('022000301116', 'LIFE SAVERS WILDBERRY', 375, 120, 'EXENTO', 'DULCES', false, false, 237),
  ('016000147058', 'ROLL UP VARIADO', 420, 300, 'EXENTO', 'DULCES', false, false, 238),
  ('725226001098', 'PULPARINDO', 297, 197, 'EXENTO', 'DULCES', false, false, 239),
  ('070462014938', 'SOUR PATCH', 670, 311, 'EXENTO', 'DULCES', false, false, 240),
  ('070462013122', 'SOUR PATCH FRUITS MIX', 431, 311, 'EXENTO', 'DULCES', false, false, 241),
  ('022000330550', 'STARBURST', 411, 311, 'EXENTO', 'DULCES', false, false, 242),
  ('022000279774', 'STARBURST 2', 345, 211, 'EXENTO', 'DULCES', false, false, 243),
  ('016000236424', 'GUSHERS', 220, 100, 'EXENTO', 'DULCES', false, false, 244),
  ('070462015546', 'SOUR PATCH 2', 450, 311, 'EXENTO', 'DULCES', false, false, 245),
  ('788434200738', 'REESE''S ONE PROTEIN BAR', 155, 75, 'EXENTO', 'GALLETAS', false, false, 246),
  ('02289902', 'CHICLE EXTRA', 105, 78, 'EXENTO', 'DULCES', false, false, 247),
  ('02289106', 'CHICLE EXTRA 2', 105, 78, 'EXENTO', 'DULCES', false, false, 248),
  ('073390055165', 'TRIDENT', 80, null, 'EXENTO', 'DULCES', false, false, 249),
  ('073390055158', 'TRIDENT 2', 98, 78, 'EXENTO', 'DULCES', false, false, 250),
  ('7506105606053', 'TRIDENT 3', 75, 30, 'EXENTO', 'DULCES', false, false, 251),
  ('028400048026', 'SUNCHIPS INTEGRAL ROJO', 110, 58, 'EXENTO', 'SNACKS', false, false, 252),
  ('028400073257', 'SUNCHIPS INTEGRAL AZUL', 110, 58, 'EXENTO', 'SNACKS', false, false, 253),
  ('028400043489', 'SUNCHIPS INTEGRAL VERDE', 110, 58, 'EXENTO', 'SNACKS', false, false, 254),
  ('028400073264', 'SUNCHIPS INTEGRAL NARANJA', 110, 58, 'EXENTO', 'SNACKS', false, false, 255),
  ('073390055219', 'TRIDENT 4', 100, 48, 'EXENTO', 'DULCES', false, false, 256),
  ('010700170408', 'JOLLY RANCHER BOLON', 25, 12, 'EXENTO', 'DULCES', false, false, 257),
  ('014200338696', 'CHARMS BLOW POPS', 15, 9, 'EXENTO', 'DULCES', false, false, 258),
  ('071720305713', 'TOOTSIE POPS', 25, 9.60, 'EXENTO', 'DULCES', false, false, 259),
  ('087076467395', 'SNAK CLUB CRUNCHY PEANUTS', 135, 70, 'EXENTO', 'SNACKS', false, false, 260),
  ('722252194138', 'ZBAR ORGANIC GRANOLA', 100, 51, 'EXENTO', 'GALLETAS', false, false, 261),
  ('722252194985', 'ZBAR ORGANIC GRANOLA 2', 100, 51, 'EXENTO', 'GALLETAS', false, false, 262),
  ('722252194145', 'ZBAR ORGANIC GRANOLA 3', 100, 51, 'EXENTO', 'GALLETAS', false, false, 263),
  ('041570051795', 'BLUE DIAMOND ALMONDS', 130, 64, 'EXENTO', 'SNACKS', false, false, 264),
  ('034856018865', 'WELCH''S FRUIT N YOGURT SNACKS', 100, 74, 'EXENTO', 'DULCES', false, false, 265),
  ('009800800056', 'NUTELLA Y GO HAZELNUT Y COCOA', 200, 78, 'EXENTO', 'GALLETAS', false, false, 266),
  ('028400260343', 'GRANDMA''S SANDWICH CREME COOKIE', 99, 55, 'EXENTO', 'GALLETAS', false, false, 267),
  ('024100114962', 'GRANDMA''S SANDWICH CREME COOKIE 2', 50, 31, 'EXENTO', 'GALLETAS', false, false, 268),
  ('070074121017', 'ENSURE VAINILLA 237ML', 175, 90, 'EXENTO', 'OTROS', false, false, 269),
  ('040000514510', 'M&M PEANUTS', 80, 59.68, 'EXENTO', 'DULCES', false, false, 270),
  ('040000514251', 'SNICKERS 1.86OZ', 80, 59.68, 'EXENTO', 'DULCES', false, false, 271),
  ('040000602040', 'MILKY WAY 1.84OZ', 80, 59.72, 'EXENTO', 'DULCES', false, false, 272),
  ('884394007285', 'ALOE VERA ORIGINAL', 100, 40, 'EXENTO', 'REFRESCOS', true, false, 273),
  ('01489438', 'JUGOS MOTTS MANZANA 10OZ', 95, 65, 'EXENTO', 'JUGOS', true, false, 274),
  ('014800000320', 'JUGOS MOTTS MANZANA 32OZ', 235, 162, 'EXENTO', 'JUGOS', true, false, 275),
  ('07811102', 'CANADA DRY BLACKBERRY GINGER', 89, 38, 'EXENTO', 'REFRESCOS', true, false, 276),
  ('07813207', 'CANADA DRY CRANBERRY', 89, 39, 'EXENTO', 'REFRESCOS', true, false, 277),
  ('07844508', 'CANADA DRY FRUIT SPLASH', 89, 39, 'EXENTO', 'REFRESCOS', true, false, 278),
  ('7702354253769', 'VIVE 100', 50, 40, 'EXENTO', 'ENERGIZANTES', true, false, 279),
  ('7702354254070', 'VIVE 100 MORA AZUL 300', 50, 40, 'EXENTO', 'ENERGIZANTES', true, false, 280),
  ('7463172803856', '911 ORIGINAL', 45, 33, 'EXENTO', 'ENERGIZANTES', true, false, 281),
  ('9002490204006', 'RED BULL 250ML', 125, 72, 'EXENTO', 'ENERGIZANTES', true, false, 282),
  ('4014086096365', '5.0 ORIGINAL', 175, 103, 'EXENTO', 'CERVEZAS', true, false, 283),
  ('4014086096334', '5.0 ORIGINAL 2', 175, 103, 'EXENTO', 'CERVEZAS', true, false, 284),
  ('8423453915011', 'REPUBLICA LA TUYA LATA', 195, 97, 'EXENTO', 'CERVEZAS', true, false, 285),
  ('3500610093708', 'JP CHENET', 700, 216, 'EXENTO', 'VINOS', true, false, 286),
  ('7463172803375', 'CORONA EXTRA', 200, 118, 'ITBIS 18%', 'CERVEZAS', true, false, 287),
  ('7460855234990', 'BRUGAL EXTRA VIEJO', 850, 595, 'EXENTO', 'RONES', true, false, 288),
  ('7460855235270', 'RON BRUGAL XV', 845, 645, 'EXENTO', 'RONES', true, false, 289),
  ('5000329002230', 'BEEFEATER LONDON GIN', 1800, 1340, 'EXENTO', 'LICORES', true, false, 290),
  ('7460855208694', 'BRUGAL LEYENDA', 1500, 1180, 'EXENTO', 'RONES', true, false, 291),
  ('7460855233269', 'RON BRUGAL LEYENDA 5TO', 1755, 1365, 'EXENTO', 'RONES', true, false, 292),
  ('7461323129350', 'RON BARCELO GRAN ANEJO', 850, 500, 'EXENTO', 'RONES', true, false, 293),
  ('7461592130965', 'KALEMBU', 930, 725, 'EXENTO', 'LICORES', true, false, 294),
  ('5011013100132', 'BAILEYS', 1890, 1360, 'EXENTO', 'LICORES', true, false, 295),
  ('7460522300461', 'GINEBRA LONDON DRY GIN', 800, 615, 'EXENTO', 'LICORES', true, false, 296),
  ('7460736980206', 'VINO LA FUERZA MEDIO GALON', 460, 360, 'EXENTO', 'VINOS', true, false, 297),
  ('7460736980480', 'VINO LA FUERZA', 720, 560, 'EXENTO', 'VINOS', true, false, 298),
  ('8427894026756', 'VEGA ROBLEDO', 595, 325, 'EXENTO', 'VINOS', true, false, 299),
  ('7460855235263', 'BRUGAL XV 350ML', 552, 345, 'EXENTO', 'RONES', true, false, 300),
  ('7460522300553', 'WHISKY KINGS LABEL', 455, 340, 'EXENTO', 'WHISKY', true, false, 301),
  ('7460736910012', 'WHISKY MACK ALBERT 700ML', 775, 560, 'EXENTO', 'WHISKY', true, false, 302),
  ('7804320559001', 'VINO TINTO FRONTERA CABERNET', 695, 490, 'ITBIS 18%', 'VINOS', true, false, 303),
  ('7804320430683', 'FRONTERA PINOT GRIGIO', 700, 515, 'EXENTO', 'VINOS', true, false, 304),
  ('7460522300539', 'KINGS LABEL', 687, 529, 'EXENTO', 'WHISKY', true, false, 305),
  ('7460855233498', 'BRUGAL DOBLE RESERVA', 1100, 820, 'EXENTO', 'RONES', true, false, 306),
  ('7460855238967', 'BRUGAL DOBLE RESERVA 350ML', 600, 452, 'EXENTO', 'RONES', true, false, 307),
  ('74624201', 'RON BRUGAL ANEJO 350ML', 370, 285, 'EXENTO', 'RONES', true, false, 308),
  ('74620708', 'RON BRUGAL ANEJO 700ML', 728, 560, 'EXENTO', 'RONES', true, false, 309),
  ('7460855234983', 'BRUGAL EXTRA VIEJO 350ML', 472, 295, 'EXENTO', 'RONES', true, false, 310),
  ('8002270015991', 'S. PELLEGRINO', 140, 107, 'EXENTO', 'AGUA', true, false, 311),
  ('41508015', 'AGUA PERRIER', 125, 79, 'EXENTO', 'AGUA', true, false, 312),
  ('08911108', 'JOHNNIE WALKER MINIATURA', 485, 241, 'EXENTO', 'WHISKY', true, false, 313),
  ('082000005490', 'BUCHANANS MINIATURA', 500, 241, 'EXENTO', 'WHISKY', true, false, 314),
  ('3245991093304', 'HENNESSY MINIATURA', 500, 220, 'EXENTO', 'LICORES', true, false, 315),
  ('7460522300782', 'KINGS LABEL 2', 442, 340, 'EXENTO', 'WHISKY', true, false, 316),
  ('7460736910029', 'MACK ALBERT CHATA', 370, 285, 'EXENTO', 'WHISKY', true, false, 317),
  ('7460522300546', 'KINGS LABEL 3', 351, 270, 'EXENTO', 'WHISKY', true, false, 318),
  ('080480230036', 'DEWARS CHATA 350ML', 630, 485, 'EXENTO', 'WHISKY', true, false, 319),
  ('5000277000500', 'DEWARS MEDIO CUARTO CHATA', 375, 275, 'EXENTO', 'WHISKY', true, false, 320),
  ('8427894026503', 'VEGA ROBLEDO RED WINE', 595, 325, 'EXENTO', 'VINOS', true, false, 321),
  ('8427894026497', 'VEGA ROBLEDO ROSE WINE', 595, 325, 'EXENTO', 'VINOS', true, false, 322),
  ('7461592130088', 'KALEMBU 180ML', 1390, 1080, 'EXENTO', 'LICORES', true, false, 323),
  ('658325189155', 'BACANAL MAMAJUANA', 675, 480, 'EXENTO', 'LICORES', true, false, 324),
  ('7460522300478', 'GINEBRA DRY GIN', 410, 320, 'EXENTO', 'LICORES', true, false, 325),
  ('7467303621494', 'NEW DOMINICAN MINIATURA', 500, 244, 'EXENTO', 'LICORES', true, false, 326),
  ('041331027854', 'AGUA DE COCO GOYA LATA 350ML', 130, 90, 'EXENTO', 'JUGOS', true, false, 327),
  ('01484035', 'CLAMATO', 70, 46, 'EXENTO', 'JUGOS', true, false, 328),
  ('082000723844', 'RTD SMIRNOFF ICE ORIGINAL', 200, 121, 'EXENTO', 'COCTELES', true, false, 329),
  ('082000803317', 'SMIRNOFF ICE BLUE RASPBERRY', 175, 121, 'EXENTO', 'COCTELES', true, false, 330),
  ('082000789727', 'SMIRNOFF ICE RASBERRY', 200, 121, 'EXENTO', 'COCTELES', true, false, 331),
  ('082000727477', 'SMIRNOFF GREEN APPLE', 200, 125, 'EXENTO', 'COCTELES', true, false, 332),
  ('4066600060741', 'PAULANER RUBIA', 200, 165, 'EXENTO', 'CERVEZAS', true, false, 333),
  ('7461592130989', 'KALEMBU 2', 300, 90, 'EXENTO', 'LICORES', true, false, 334),
  ('607766541213', 'SPARKLING WATER VARIETY PACK MEMBER SELECTION', 100, 42, 'EXENTO', 'AGUA', true, false, 335),
  ('607766541206', 'SPARKLING WATER ORANGE MANGO', 100, 42, 'EXENTO', 'AGUA', true, false, 336),
  ('607766541190', 'SPARKLING WATER KIWI STRAWBERRY', 100, 42, 'EXENTO', 'AGUA', true, false, 337),
  ('038000184956', 'PRINGLES SABOR A QUESO', 215, 160, 'EXENTO', 'SNACKS', false, false, 338),
  ('038000845253', 'PRINGLES SOUR CREAM', 135, 104, 'EXENTO', 'SNACKS', false, false, 339),
  ('038000138638', 'PRINGLES PIZZA', 235, 171, 'EXENTO', 'SNACKS', false, false, 340),
  ('038000845246', 'PRINGLES ORIGINAL', 125, 73, 'EXENTO', 'SNACKS', false, false, 341),
  ('038000169113', 'PRINGLES PIZZA 71G', 125, 73.94, 'EXENTO', 'SNACKS', false, false, 342),
  ('038000184949', 'PRINGLES CREMA Y CEBOLLA', 215, 170, 'EXENTO', 'SNACKS', false, false, 343),
  ('038000184932', 'PRINGLES ORIGINAL 2', 215, 173, 'EXENTO', 'SNACKS', false, false, 344),
  ('7622201693190', 'OREO REGULAR AZUL', 295, 222, 'EXENTO', 'GALLETAS', false, false, 345),
  ('7622202299636', 'OREO GOLDEN AMARILLA Y AZUL', 98, 48, 'EXENTO', 'GALLETAS', false, false, 346),
  ('7622201711726', 'TRIDENT SABOR Y DURADERO', 200, 142, 'EXENTO', 'DULCES', false, false, 347),
  ('7622201711757', 'TRIDENT YERBABUENA', 195, 142, 'EXENTO', 'DULCES', false, false, 348),
  ('7622201735432', 'TRIDENT DE FRESA PASTILLA', 195, 142, 'EXENTO', 'DULCES', false, false, 349),
  ('7622210427045', 'HALLS CERVEZA', 20, 9.50, 'EXENTO', 'DULCES', false, false, 350),
  ('7622201776459', 'HALLS LIMON Y MIEL', 20, 9.50, 'EXENTO', 'DULCES', false, false, 351),
  ('7622210427076', 'HALLS', 20, 9.50, 'EXENTO', 'DULCES', false, false, 352),
  ('7460590002724', 'CARLES PAPITA QUESO', 85, 56, 'EXENTO', 'SNACKS', false, false, 353),
  ('7460590002717', 'CARLES PAPITAS SAL', 80, 56, 'EXENTO', 'SNACKS', false, false, 354),
  ('7460590002700', 'CARLES PAPITA LIMON', 80, 56, 'EXENTO', 'SNACKS', false, false, 355),
  ('070970475474', 'MIKE AND IKE', 100, 50, 'EXENTO', 'DULCES', false, false, 356),
  ('070970475481', 'MIKE AND IKE SOUR LEMON', 50, 3, 'EXENTO', 'DULCES', false, false, 357),
  ('070970475436', 'MIKE AND IKE ORIGINALS FRUITS', 55, 3, 'EXENTO', 'DULCES', false, false, 358),
  ('070970475450', 'MIKE AND IKE 2', 55, 3, 'EXENTO', 'DULCES', false, false, 359),
  ('GOMITAS', 'MOTT GOMITAS', 25, 8, 'EXENTO', 'DULCES', false, false, 360),
  ('878114006900', 'EXTRA STRENGTH MORADA', 250, 75, 'EXENTO', 'SALUD', false, false, 361),
  ('878114007303', 'EXTRA STRENGTH', 250, 75, 'EXENTO', 'SALUD', false, false, 362),
  ('878114005187', 'EXTRA STRENGTH 2', 250, 75, 'EXENTO', 'SALUD', false, false, 363),
  ('860006830656', 'EXTRA STRENGTH 3', 250, 75, 'EXENTO', 'SALUD', false, false, 364),
  ('076677100145', 'FAMOUS AMOS CHOCOLATE CHIP COOKIES', 105, 36, 'EXENTO', 'GALLETAS', false, false, 365),
  ('014100096016', 'GOLDFISH', 60, 25, 'EXENTO', 'GALLETAS', false, false, 366),
  ('014100050544', 'GOLDFISH 2', 65, 32, 'EXENTO', 'GALLETAS', false, false, 367),
  ('038000356216', 'NUTRI-GRAIN BARS APPLE', 69, 25, 'EXENTO', 'GALLETAS', false, false, 368),
  ('038000357213', 'NUTRI-GRAIN BARS', 65, 25, 'EXENTO', 'GALLETAS', false, false, 369),
  ('038000359217', 'NUTRI-GRAIN BARS 2', 65, 25, 'EXENTO', 'GALLETAS', false, false, 370),
  ('038000265013', 'RICE KRISPIES TREATS', 20, 10, 'EXENTO', 'GALLETAS', false, false, 371),
  ('044000009298', 'RITZ BITS 2', 86, 36, 'EXENTO', 'GALLETAS', false, false, 372),
  ('016000487598', 'NATURE VALLEY CRUNCHY GRANOLA BAR', 55, 25, 'EXENTO', 'GALLETAS', false, false, 373),
  ('016000507661', 'NATURE VALLEY PEANUT BUTTER DARK CHOCOLATE', 100, 25, 'EXENTO', 'GALLETAS', false, false, 374),
  ('044000043148', 'CHIPS AHOY', 65, 26, 'EXENTO', 'GALLETAS', false, false, 375),
  ('044000047009', 'OREO 2.4OZ', 75, 26, 'EXENTO', 'GALLETAS', false, false, 376),
  ('041116241086', 'BAZOOKA CANDY VARIETY PACK', 2100, 1620, 'EXENTO', 'DULCES', false, false, 377),
  ('021000023226', 'VELVEETA SHELLS AND CHEESE', 95, 46, 'EXENTO', 'OTROS', false, false, 378),
  ('070662030035', 'NISSIN CUP NOODLES', 110, 37, 'EXENTO', 'OTROS', false, false, 379),
  ('193968526108', 'MEMBERS MARK HEART HEALTHY NUT MIX', 100, 50, 'EXENTO', 'SNACKS', false, false, 380),
  ('024100122615', 'CHEEZ IT', 85, 33, 'EXENTO', 'GALLETAS', false, false, 381),
  ('7421000594642', 'PALL MALL MIAMI SUNSET', 130, 94.75, 'EXENTO', 'CIGARRILLOS', false, false, 382),
  ('7421000594666', 'PALL MALL MYKONOS NIGHTFALL', 130, 94.75, 'EXENTO', 'CIGARRILLOS', false, false, 383),
  ('7421000594628', 'PALL MALL TOKYO MIDNIGHT', 130, 94.75, 'EXENTO', 'CIGARRILLOS', false, false, 384),
  ('7421000598411', 'PALL MALL ALASKA', 130, 94.75, 'EXENTO', 'CIGARRILLOS', false, false, 385),
  ('028400700061', 'DORITOS AZUL', 530, 240, 'ITBIS 16%', 'SNACKS', false, false, 386),
  ('070137000181', 'BLACK Y MILD', 500, 318, 'EXENTO', 'CIGARRILLOS', false, false, 387),
  ('023923201903', 'ORGANIC BARRA DE PROTEINA', 220, 100, 'EXENTO', 'GALLETAS', false, false, 388),
  ('74201532', 'NEWPORT VERDE PEQUENO', 200, 117, 'EXENTO', 'CIGARRILLOS', false, false, 389),
  ('74201334', 'NEWPORT VERDE GRANDE', 350, 235, 'ITBIS 18%', 'CIGARRILLOS', false, false, 390),
  ('7421000501336', 'NEWPORT AZUL GRANDE', 350, 235, 'EXENTO', 'CIGARRILLOS', false, false, 391),
  ('74209460', 'PALL MALL VERDE MEDIA', 180, 138, 'ITBIS 18%', 'CIGARRILLOS', false, false, 392),
  ('74209453', 'PALL MALL ROJA MEDIA', 180, 130, 'ITBIS 18%', 'CIGARRILLOS', false, false, 393),
  ('842426158572', 'WOODS LEAF', 350, 192, 'ITBIS 18%', 'CIGARRILLOS', false, false, 394),
  ('819721011710', 'PIFF CIGARILLO', 125, 86, 'ITBIS 18%', 'CIGARRILLOS', false, false, 395),
  ('819721011772', 'BLUNTVILLE PINK DIVA', 125, 86, 'ITBIS 18%', 'CIGARRILLOS', false, false, 396),
  ('4895151872967', 'ZENGAZ ENCENDEDOR', 420, 240, 'ITBIS 18%', 'OTROS', false, false, 397),
  ('TYLENOL', 'TYLENOL', 50, 26, 'ITBIS 18%', 'SALUD', false, false, 398),
  ('ADVIL', 'ADVIL', 50, 26, 'ITBIS 18%', 'SALUD', false, false, 399),
  ('633148166552', 'TAJIN LIME 14OZ', 490, 249, 'ITBIS 18%', 'OTROS', false, false, 400),
  ('028400000789', 'FRITOS BEAN DIP', 250, 157, 'ITBIS 18%', 'SNACKS', false, false, 401),
  ('071159078196', 'CORN NUTS CRUNCHY', 135, 40, 'EXENTO', 'SNACKS', false, false, 402),
  ('071159073115', 'CORN NUTS CRUNCHY 2', 125, 40, 'EXENTO', 'SNACKS', false, false, 403),
  ('029000017955', 'PLANTERS SALTED PEANUTS', 55, 23, 'EXENTO', 'SNACKS', false, false, 404),
  ('029000017917', 'PLANTERS SALTED PEANUTS 2', 55, 23, 'EXENTO', 'SNACKS', false, false, 405),
  ('028400735827', 'NATU CHIPS', 140, 100, 'EXENTO', 'SNACKS', false, false, 406),
  ('7460496803357', 'FRITO LAYS', 100, 60, 'EXENTO', 'SNACKS', false, false, 407),
  ('7460496803340', 'LAY''S CLASICAS', 100, 60, 'EXENTO', 'SNACKS', false, false, 408),
  ('7460496803364', 'LAY''S LIMON', 100, 60, 'EXENTO', 'SNACKS', false, false, 409),
  ('7460496803371', 'RUFFLES CHEDDAR', 100, 60, 'ITBIS 18%', 'SNACKS', false, false, 410),
  ('7460496803401', 'HOJUELITAS QUESO', 100, 60, 'EXENTO', 'SNACKS', false, false, 411),
  ('7460496800905', 'PLATANOS ORIGINALES', 120, 60, 'EXENTO', 'SNACKS', false, false, 412),
  ('028400025409', 'CHEETOS PUFFS QUESO', 290, 185, 'EXENTO', 'SNACKS', false, false, 413),
  ('7501000604685', 'GALLETA CHOKIS RELLENA', 100, 49, 'EXENTO', 'GALLETAS', false, false, 414),
  ('721282410102', 'GALLETA CHOKIS CHOCOBASE', 100, 45, 'EXENTO', 'GALLETAS', false, false, 415),
  ('7500478008926', 'GALLETA CHOKIS CLASICA', 100, 45, 'EXENTO', 'GALLETAS', false, false, 416),
  ('7500478001200', 'GALLETA CHOKIS MIX CHOCOLATE', 100, 45, 'EXENTO', 'GALLETAS', false, false, 417),
  ('7501000610228', 'GALLETA MINI CHOKIS', 70, 41, 'EXENTO', 'GALLETAS', false, false, 418),
  ('7501000634125', 'GALLETA AVENA', 50, 28, 'EXENTO', 'GALLETAS', false, false, 419),
  ('7501000634132', 'GALLETA DE AVENA', 50, 28, 'EXENTO', 'GALLETAS', false, false, 420),
  ('7501000634118', 'GALLETA DE AVENA 2', 50, 28, 'EXENTO', 'GALLETAS', false, false, 421),
  ('7460496805320', 'TOSTITOS SANTA ELENA', 290, 197, 'EXENTO', 'SNACKS', false, false, 422),
  ('028400070980', 'TOSTITOS MEDIUM SALSA CON QUESO', 325, 220, 'EXENTO', 'SNACKS', false, false, 423),
  ('028400055970', 'TOSTITOS MEDIUM CHUNKY SALSA', 325, 220, 'EXENTO', 'SNACKS', false, false, 424),
  ('7501000601738', 'FLORENTINAS SABOR FRESA', 100, 49, 'ITBIS 18%', 'GALLETAS', false, false, 425),
  ('7501000601745', 'FLORENTINAS SABOR DULCE DE LECHE', 100, 49.56, 'ITBIS 18%', 'GALLETAS', false, false, 426),
  ('7500478027118', 'CRACKETS MINI SANDWICH', 79, 41, 'EXENTO', 'GALLETAS', false, false, 427),
  ('7460736905469', 'KINGS PRIDE KANEL 125ML', 200, 149, 'EXENTO', 'LICORES', true, false, 428),
  ('016000146983', 'GUSHERS STRAWBERRY Y TROPICAL VARIETY PACK', 50, 23, 'EXENTO', 'DULCES', false, false, 429),
  ('076410901633', 'LANCE TOASTCHEE PEANUT BUTTER CRACKERS', 50, 18, 'EXENTO', 'GALLETAS', false, false, 430),
  ('044000055837', 'BELVITA BITES BREAKFAST BISCUITS', 60, 23, 'EXENTO', 'GALLETAS', false, false, 431),
  ('044000055851', 'BELVITA BITES BREAKFAST BISCUITS 2', 60, 23, 'EXENTO', 'GALLETAS', false, false, 432),
  ('044000055844', 'BELVITA BITES BREAKFAST BISCUITS 3', 60, 23, 'EXENTO', 'GALLETAS', false, false, 433),
  ('846548070323', 'NATURES GARDEN TRAIL MIX SNACK', 80, 25, 'EXENTO', 'SNACKS', false, false, 434),
  ('846548070330', 'NATURES GARDEN TRAIL MIX SNACK 2', 80, 23, 'EXENTO', 'SNACKS', false, false, 435),
  ('846548070316', 'NATURES GARDEN TRAIL MIX SNACK 3', 80, 23, 'EXENTO', 'SNACKS', false, false, 436),
  ('027800064698', 'KEEBLER E.L. FUDGE DOUBLE STUFFED', 495, 295, 'EXENTO', 'GALLETAS', false, false, 437),
  ('024300041013', 'OATMEAL CREME PIES', 50, 12, 'EXENTO', 'GALLETAS', false, false, 438),
  ('757528005276', 'TAKIS FUEGO', 130, 50, 'EXENTO', 'SNACKS', false, false, 439),
  ('697151786711', 'LIP BALM', 75, 18, 'EXENTO', 'OTROS', false, false, 440),
  ('026200006840', 'DAVID NACHO CHEESE', 69, 20, 'EXENTO', 'SNACKS', false, false, 441),
  ('041192111075', 'COCOA LOOPS', 620, 300, 'EXENTO', 'CEREALES', false, false, 442),
  ('016000171138', 'CINNAMON TOAST', 730, 320, 'EXENTO', 'CEREALES', false, false, 443),
  ('016000171138016', 'CINNAMON MINI', 420, 180, 'EXENTO', 'CEREALES', false, false, 444),
  ('74601172', 'MARLBORO ROJO MEDIA', 200, 157, 'ITBIS 18%', 'CIGARRILLOS', false, false, 445),
  ('74601462', 'MARLBORO ROJO GRANDE', 390, 315, 'ITBIS 18%', 'CIGARRILLOS', false, false, 446),
  ('7460985108413', 'MARLBORO GOLD GRANDE', 390, 315, 'ITBIS 18%', 'CIGARRILLOS', false, false, 447),
  ('3245991460205', 'HENNESSY PURE WHITE 700ML', 4890, 3200, 'EXENTO', 'LICORES', true, false, 448),
  ('7460985108420', 'MARLBORO MEDIA', 200, 157, 'EXENTO', 'CIGARRILLOS', false, false, 449),
  ('033314221069', 'MARLOW GUMMI BEARS', 100, 40, 'EXENTO', 'DULCES', false, false, 450),
  ('193968303723', 'ALPHABET COOKIES', 50, 22, 'EXENTO', 'GALLETAS', false, false, 451),
  ('193968303624', 'ALPHABET COOKIES 2', 50, 22, 'EXENTO', 'GALLETAS', false, false, 452),
  ('888109300036', 'ZINGERS', 195, 25, 'EXENTO', 'GALLETAS', false, false, 453),
  ('9555755800036', 'ROYAL HONEY', 300, 183, 'EXENTO', 'SALUD', false, false, 454),
  ('786468817779', 'BLACK BULL EXTREME', 280, 150, 'EXENTO', 'SALUD', false, false, 455),
  ('9555671700311', 'BIO HERBS', 300, 150, 'EXENTO', 'SALUD', false, false, 456),
  ('5285002251413', 'CANDY POWER', 720, 570, 'EXENTO', 'SALUD', false, false, 457),
  ('724087947316', 'RHINO CHOCO VIP', 300, 183, 'EXENTO', 'SALUD', false, false, 458),
  ('9555708301016', 'VITA MAX', 300, 150, 'EXENTO', 'SALUD', false, false, 459),
  ('787188873229', 'GOLD HARD STEEL PLUS', 300, 150, 'EXENTO', 'SALUD', false, false, 460),
  ('888109300050', 'COFFEE CAKES', 195, 53, 'EXENTO', 'GALLETAS', false, false, 461),
  ('857900005198', 'DRIZZILICIOUS DRIZZLED MINI RICE', 100, 25, 'EXENTO', 'SNACKS', false, false, 462),
  ('031200008091', 'OCEAN SPRAY 15ML', 150, 97, 'EXENTO', 'JUGOS', true, false, 463),
  ('031200200006', 'OCEAN SPRAY CRANBERRY 32ML', 290, 191, 'EXENTO', 'JUGOS', true, false, 464),
  ('852682507434', 'PRESERVATIVOS TROJAN MAGNUM LARGE', 60, 40, 'EXENTO', 'SALUD', false, false, 465),
  ('PRECERVATIVO', 'PRESERVATIVOS LIFESTYLES', 35, 10, 'EXENTO', 'SALUD', false, false, 466),
  ('963784552465', 'CURITAS', 40, 10, 'EXENTO', 'SALUD', false, false, 467),
  ('731946017233', 'SUPER GLUE', 170, 50, 'EXENTO', 'OTROS', false, false, 468),
  ('NEW', 'AIR FRESHENER', 100, 20, 'EXENTO', 'OTROS', false, false, 469),
  ('6977102579441', 'NOTA 75 20000 PUFFS PAPITO', 900, 425, 'EXENTO', 'VAPES', false, false, 470),
  ('6978113237085', 'NOTA 75 PUFFS EL NEGRITO', 900, 425, 'EXENTO', 'VAPES', false, false, 471),
  ('6977102579434', 'NOTA 75 PUFFS SOUR MAGIC', 900, 425, 'EXENTO', 'VAPES', false, false, 472),
  ('6978113237108', 'NOTA 75 PUFFS CLEAR', 900, 425, 'EXENTO', 'VAPES', false, false, 473),
  ('739608540433', 'TYGA BARS', 500, 145, 'EXENTO', 'VAPES', false, false, 474),
  ('6978974246738', 'HOOKAH', 900, 450, 'EXENTO', 'VAPES', false, false, 475),
  ('6978974246707', 'HOOKAH PUFF BLUEBERRY GUM', 900, 425, 'EXENTO', 'VAPES', false, false, 476),
  ('6978974246639', 'HOOKAH MINT BUBBLEGUM', 900, 425, 'EXENTO', 'VAPES', false, false, 477),
  ('6979193543264', 'BETTA POD GRAPE GREEN APPLE PEACH', 500, 245, 'EXENTO', 'VAPES', false, false, 478),
  ('6979193543097', 'BETTA POD', 500, 245, 'EXENTO', 'VAPES', false, false, 479),
  ('6979193543189', 'BETTA POD STRAWBERRY ICE', 600, 245, 'EXENTO', 'VAPES', false, false, 480),
  ('6979193543226', 'BETTA POD CHINOLA FRESA', 600, 245, 'EXENTO', 'VAPES', false, false, 481),
  ('6979193543240', 'BETTA POD KIWI BERRY', 600, 245, 'EXENTO', 'VAPES', false, false, 482),
  ('6979193543233', 'BETTA POD BLUE RAZZ PEACH ICE', 600, 245, 'EXENTO', 'VAPES', false, false, 483),
  ('6979193543158', 'BETTA POD 2', 600, 245, 'EXENTO', 'VAPES', false, false, 484),
  ('6979193543172', 'BETTA POD 3', 600, 6, 'EXENTO', 'VAPES', false, false, 485),
  ('6979193543547', 'BATERIA VAPE', 420, 325, 'EXENTO', 'VAPES', false, false, 486),
  ('072320700397', 'HELLO PANDA', 55, 25, 'EXENTO', 'GALLETAS', false, false, 487),
  ('7460855238066', 'BRUGAL TRIPLE RESERVA 700ML', 1380, 983, 'ITBIS 18%', 'RONES', true, false, 488),
  ('080432402795', 'SOMETHING SPECIAL 750ML', 1050, 766, 'ITBIS 18%', 'WHISKY', true, false, 489),
  ('085000001868', 'CARLO ROSSI WHITE', 550, 370, 'ITBIS 18%', 'VINOS', true, false, 490),
  ('085000001875', 'CARLO ROSSI ROSE', 595, 370, 'ITBIS 18%', 'VINOS', true, false, 491),
  ('085000022030', 'CARLO ROSSI FRUITY RED', 595, 370, 'ITBIS 18%', 'VINOS', true, false, 492),
  ('085000001882', 'CARLO ROSSI TINTO', 595, 370, 'ITBIS 18%', 'VINOS', true, false, 493),
  ('7804320706009', 'FRONTERA MERLOT', 695, 500, 'ITBIS 18%', 'VINOS', true, false, 494),
  ('051497322618', 'SIX EIGHT NINE', 1600, 1458, 'ITBIS 18%', 'VINOS', true, false, 495),
  ('4014086096518', '5.0 TRICOLOR', 175, 107, 'ITBIS 18%', 'CERVEZAS', true, false, 496),
  ('4014086096303', '5.0 AMARILLA', 175, 107, 'ITBIS 18%', 'CERVEZAS', true, false, 497),
  ('74600014', 'HILTON ROJO MEDIA', 110, 80, 'ITBIS 18%', 'CIGARRILLOS', false, false, 498),
  ('74600298', 'HILTON VERDE MEDIA', 110, 80, 'ITBIS 18%', 'CIGARRILLOS', false, false, 499),
  ('74600472', 'CONSTANZA MEDIA', 150, 115, 'ITBIS 18%', 'CIGARRILLOS', false, false, 500),
  ('012354001602', '19 CRIMES THE WARDEN 750ML', 2890, 2215, 'EXENTO', 'VINOS', true, false, 501),
  ('012354001688', '19 CRIMES THE BANISHED 750ML', 1690, 1265, 'ITBIS 18%', 'VINOS', true, false, 502),
  ('012354001930', '19 CRIMES UPRISING 750ML', 1690, 1265, 'EXENTO', 'VINOS', true, false, 503),
  ('8681137800439', 'JAWS ENERGY DRINK 250ML', 100, 61, 'ITBIS 18%', 'ENERGIZANTES', true, false, 504),
  ('8427894027746', 'VEGA ROBLEDO ESPUMANTE BRUT ROSE', 490, 325, 'EXENTO', 'VINOS', true, false, 505),
  ('8427894027753', 'VEGA ROBLEDO ESPUMANTE BRUT', 495, 325, 'EXENTO', 'VINOS', true, false, 506),
  ('7506064300344', 'DON JULIO 1942', 14095, 9000, 'ITBIS 18%', 'TEQUILA', true, false, 507),
  ('850014275099', 'CLASE AZUL', 15995, 11500, 'ITBIS 18%', 'TEQUILA', true, false, 508),
  ('07199044', 'COORS LIGHT 12OZ 330ML', 175, 110.26, 'ITBIS 18%', 'CERVEZAS', true, false, 509),
  ('850035474105', 'BUZZBALLZ STRAWBERRY RITA', 290, 215.86, 'ITBIS 18%', 'COCTELES', true, false, 510),
  ('850035474068', 'BUZZBALLZ ESPRESSO MARTINI', 290, 215, 'ITBIS 18%', 'COCTELES', true, false, 511),
  ('850035474006', 'BUZZBALLZ TEQUILA RITA', 290, 215, 'ITBIS 18%', 'COCTELES', true, false, 512),
  ('850035474051', 'BUZZBALLZ LOTTA COLADA', 290, 215, 'ITBIS 18%', 'COCTELES', true, false, 513),
  ('850035474037', 'BUZZBALLZ CHOC TEASE', 290, 215, 'ITBIS 18%', 'COCTELES', true, false, 514),
  ('044000086046', 'OREO CAKESTERS', 70, 45, 'EXENTO', 'GALLETAS', false, false, 515),
  ('024300041204', 'NUTTY BUDDY', 70, 30, 'ITBIS 18%', 'GALLETAS', false, false, 516),
  ('049000014273', 'FANTA PINEAPPLE', 125, 38, 'ITBIS 18%', 'REFRESCOS', true, false, 517),
  ('75031602', 'MODELO RUBIA ESPECIAL', 200, null, 'ITBIS 18%', 'CERVEZAS', true, false, 518),
  ('74601561', 'PRESIDENTE LIGHT 22OZ', 200, 148, 'ITBIS 18%', 'CERVEZAS', true, false, 519),
  ('74601554', 'PRESIDENTE NORMAL 22OZ', 200, 148, 'ITBIS 18%', 'CERVEZAS', true, false, 520),
  ('7463172803733', 'AGUA TONICA ENRIQUILLO', 50, 25, 'ITBIS 18%', 'REFRESCOS', true, false, 521),
  ('7463172803726', 'SODA ENRIQUILLO', 50, 25, 'ITBIS 18%', 'REFRESCOS', true, false, 522),
  ('7463172803320', '7UP', 45, 20, 'ITBIS 18%', 'REFRESCOS', true, false, 523),
  ('74601127', 'CERVEZA ONE 22OZ', 120, 87, 'ITBIS 18%', 'CERVEZAS', true, false, 524),
  ('7460590002731', 'CARLES SOUR CREAM ONION', 80, 56, 'ITBIS 18%', 'SNACKS', false, false, 525),
  ('7460985107942', 'NACIONAL ARTESANAL', 180, 133, 'ITBIS 18%', 'CERVEZAS', true, false, 526),
  ('7460836505002', 'L Y M', 150, 107, 'ITBIS 18%', 'CIGARRILLOS', false, false, 527),
  ('736372551597', 'INTIMATE TEXTURIZADOS', 150, 83, 'ITBIS 18%', 'SALUD', false, false, 528),
  ('736372551603', 'INTIMATE ULTRA SENSITIVO', 150, 83, 'ITBIS 18%', 'SALUD', false, false, 529),
  ('8411327122016', 'MAHOU CINCO ESTRELLAS LATA', 175, 110, 'ITBIS 18%', 'CERVEZAS', true, false, 530),
  ('635985500025', 'WHITE CLAW RUBY GRAPEFRUIT LATA', 160, 121, 'ITBIS 18%', 'COCTELES', true, false, 531),
  ('635985800095', 'WHITE CLAW WATERMELON', 160, 121, 'ITBIS 18%', 'COCTELES', true, false, 532),
  ('4101120015106', 'PADERBORNER PILSENER LATA', 155, 95, 'ITBIS 18%', 'CERVEZAS', true, false, 533),
  ('ACEITE', 'VEGETABLE OIL', 1100, 590, 'ITBIS 18%', 'OTROS', false, false, 534),
  ('7460590002953', 'CARLES PATACONES LEMON', 300, 207, 'ITBIS 18%', 'SNACKS', false, false, 535),
  ('7460590001338', 'CARLES PATACONES SAL', 300, 215, 'ITBIS 18%', 'SNACKS', false, false, 536),
  ('7460590002922', 'CARLES PATACONES AJO', 300, 207, 'ITBIS 18%', 'SNACKS', false, false, 537),
  ('7467113580882', 'CARLES MADURITOS', 95, 57.69, 'ITBIS 18%', 'SNACKS', false, false, 538),
  ('7451011041132', 'CARLES YUKITAS PICANTITAS', 95, 57.69, 'ITBIS 18%', 'SNACKS', false, false, 539),
  ('7467113580974', 'CARLES PLATANITO LIMON', 95, 57.69, 'ITBIS 18%', 'SNACKS', false, false, 540),
  ('7451011040289', 'CARLES TAJADITAS', 90, 57.69, 'ITBIS 18%', 'SNACKS', false, false, 541),
  ('076410903873', 'LANCE TOAST CHEE', 50, 25, 'ITBIS 18%', 'GALLETAS', false, false, 542),
  ('072320701882', 'HELLO PANDA CAJA DE 12', 695, 300, 'ITBIS 18%', 'GALLETAS', false, false, 543),
  ('041192116636', 'CEREAL FROSTED FLAKES', 695, 300, 'ITBIS 18%', 'CEREALES', false, false, 544),
  ('7451011040425', 'CARLES PLATANITO', 90, 57, 'ITBIS 18%', 'SNACKS', false, false, 545),
  ('7451011041149', 'CARLES PLATANITOS PICANTITOS', 90, 57, 'ITBIS 18%', 'SNACKS', false, false, 546),
  ('Roll-Ups', 'ROLL-UPS VARIADOS', 35, 17, 'ITBIS 18%', 'DULCES', false, false, 547),
  ('02', 'GUSHERS GOMMIS', 50, 22, 'ITBIS 18%', 'DULCES', false, false, 548),
  ('024100126606', 'CHEEZ-IT WHITE CHEDDAR', 60, 25, 'ITBIS 18%', 'GALLETAS', false, false, 549),
  ('725226001005', 'PULPARINDO 2', 35, 12, 'ITBIS 18%', 'DULCES', false, false, 550),
  ('034856008187', 'WELCH''S MIXED FRUIT', 25, 9, 'ITBIS 18%', 'DULCES', false, false, 551),
  ('049000067262', 'FANTA ORANGE MINI', 895, 425, 'ITBIS 18%', 'REFRESCOS', true, false, 552),
  ('746054800147', 'GATORADE MELON 600ML', 70, 40, 'ITBIS 18%', 'ENERGIZANTES', true, false, 553),
  ('044000020170', 'OREO MINI 1OZ', 65, 30, 'ITBIS 18%', 'GALLETAS', false, false, 554),
  ('746054800130', 'GATORADE COOL BLUE', 75, 40, 'ITBIS 18%', 'ENERGIZANTES', true, false, 555),
  ('7460000046300', 'AGUA CASCADA 500ML', 15, 6.25, 'ITBIS 18%', 'AGUA', true, false, 556),
  ('7422110104967', 'MICHELOB ULTRA', 150, 99, 'ITBIS 18%', 'CERVEZAS', true, false, 557),
  ('74621774', 'PRESIDENTE LIGHT 12OZ', 150, 89, 'ITBIS 18%', 'CERVEZAS', true, false, 558),
  ('74621767', 'PRESIDENTE REGULAR 12OZ PEQUENA', 150, 89, 'ITBIS 18%', 'CERVEZAS', true, false, 559),
  ('74601325', 'THE ONE 12OZ PEQUENA', 90, 65.13, 'ITBIS 18%', 'CERVEZAS', true, false, 560),
  ('7501064199141', 'STELLA ARTOIS 330ML', 180, 129, 'ITBIS 18%', 'CERVEZAS', true, false, 561),
  ('633148100068', 'TAJIN MINI', 75, 27, 'ITBIS 18%', 'OTROS', false, false, 562),
  ('7460234530026', 'VASO FOAM NO.12 25UDS', 100, 80, 'ITBIS 18%', 'OTROS', false, false, 563),
  ('070491804951', 'FINEST CALL PINA COLADA', 500, 360, 'ITBIS 18%', 'COCTELES', true, false, 564),
  ('070491051805', 'FINEST CALL BLUE CURACAO', 550, 415, 'ITBIS 18%', 'COCTELES', true, false, 565),
  ('070491544000', 'FINEST CALL MOJITO', 525, 380, 'ITBIS 18%', 'COCTELES', true, false, 566),
  ('070491802957', 'FINEST CALL MARGARITA', 525, 380, 'ITBIS 18%', 'COCTELES', true, false, 567),
  ('070491808959', 'FINEST CALL TRIPLE SEC', 525, 380, 'ITBIS 18%', 'COCTELES', true, false, 568),
  ('070491105003', 'MASTER OF MIX COSMOPOLITAN', 525, 365, 'ITBIS 18%', 'COCTELES', true, false, 569),
  ('070491225008', 'MASTER OF MIX MOJITO', 525, 365, 'ITBIS 18%', 'COCTELES', true, false, 570),
  ('070491060241', 'MASTER OF MIX SOUR APPLE', 550, 365, 'ITBIS 18%', 'COCTELES', true, false, 571),
  ('3024480001781', 'REMY MARTIN 1738', 6795, 6055, 'ITBIS 18%', 'LICORES', true, false, 572),
  ('088076174955', 'CIROC COCONUT', 3450, 2995, 'ITBIS 18%', 'VODKA', true, false, 573),
  ('5000281055091', 'OLD PARR 18Y', 4795, 4480, 'ITBIS 18%', 'WHISKY', true, false, 574),
  ('5099873026045', 'JACK DANIELS MCLAREN', 2995, 1695, 'ITBIS 18%', 'WHISKY', true, false, 575),
  ('082184004371', 'JACK DANIELS APPLE', 1995, 1595, 'ITBIS 18%', 'WHISKY', true, false, 576),
  ('082184001172', 'JACK DANIELS FIRE', 2100, 1680, 'ITBIS 18%', 'WHISKY', true, false, 577),
  ('082184000335', 'JACK DANIELS HONEY', 1995, 1605, 'ITBIS 18%', 'WHISKY', true, false, 578),
  ('082184090466', 'JACK DANIELS SOUR MASH', 1995, 1690, 'ITBIS 18%', 'WHISKY', true, false, 579),
  ('856724006114', 'CASAMIGOS BLANCO', 4800, 4500, 'ITBIS 18%', 'TEQUILA', true, false, 580),
  ('856724006015', 'CASAMIGOS', 4800, 4500, 'ITBIS 18%', 'TEQUILA', true, false, 581),
  ('5000281033280', 'OLD PARR SILVER', 1895, 1675, 'ITBIS 18%', 'WHISKY', true, false, 582),
  ('7640330384178', 'DEWARS 700ML', 995, 775, 'ITBIS 18%', 'WHISKY', true, false, 583),
  ('080480989347', 'GREY GOOSE MINI', 399, 195, 'ITBIS 18%', 'VODKA', true, false, 584),
  ('5010677800792', 'ERISTOFF VODKA', 250, 80, 'ITBIS 18%', 'VODKA', true, false, 585),
  ('4750021001789', 'STOLI MINI', 400, 209, 'ITBIS 18%', 'VODKA', true, false, 586),
  ('8714800001793', 'HOLLANDIA 330ML', 110, 87.50, 'ITBIS 18%', 'CERVEZAS', true, false, 587),
  ('8714800007580', 'HOLLANDIA LATA', 125, 82.91, 'ITBIS 18%', 'CERVEZAS', true, false, 588),
  ('4014086090370', '9.0 ORIGINAL MORADA', 200, 143, 'ITBIS 18%', 'CERVEZAS', true, false, 589),
  ('8714800036214', '8.6 IPA', 230, 165, 'ITBIS 18%', 'CERVEZAS', true, false, 590),
  ('4066600303336', 'PAULANER DUNKEL 500ML', 250, 198, 'ITBIS 18%', 'CERVEZAS', true, false, 591),
  ('3500610085338', 'JP CHENET ICE BLANCA', 899, 649, 'ITBIS 18%', 'VINOS', true, false, 592),
  ('012993441142', 'LA CROIX BEACH PLUM', 100, 35, 'ITBIS 18%', 'AGUA', true, false, 593),
  ('012993441135', 'LA CROIX GUAVA', 100, 35, 'ITBIS 18%', 'AGUA', true, false, 594),
  ('012993441128', 'LA CROIX BLACK RAZZBERRY', 100, 35, 'ITBIS 18%', 'AGUA', true, false, 595),
  ('607766777841', 'MEMBERS SELECTION TOALLITAS HUMEDAS', 300, 176, 'ITBIS 18%', 'OTROS', false, false, 596),
  ('039000086639', 'VIENNA SAUSAGE', 85, 48.96, 'ITBIS 18%', 'OTROS', false, false, 597),
  ('849806004962', 'FOUR LOKO MARACUYA', 325, 231, 'ITBIS 18%', 'COCTELES', true, false, 598),
  ('849806001206', 'FOUR LOKO SANDIA 473ML', 325, 231, 'ITBIS 18%', 'COCTELES', true, false, 599),
  ('849806002319', 'FOUR LOKO BLUE 473ML', 325, 231, 'ITBIS 18%', 'COCTELES', true, false, 600),
  ('849806001855', 'FOUR LOKO GREEN 473ML', 325, 231, 'ITBIS 18%', 'COCTELES', true, false, 601),
  ('849806002746', 'FOUR LOKO PURPLE 473ML', 325, 231, 'ITBIS 18%', 'COCTELES', true, false, 602),
  ('849806001756', 'FOUR LOKO GOLD 473ML', 325, 231, 'ITBIS 18%', 'COCTELES', true, false, 603),
  ('849806001220', 'FOUR LOKO PONCHE DE FRUTAS 473ML', 325, 231, 'ITBIS 18%', 'COCTELES', true, false, 604),
  ('849806005754', 'FOUR LOKO WHITE 473ML', 325, 231, 'ITBIS 18%', 'COCTELES', true, false, 605),
  ('830207000301', 'CICLON GRANDE 16OZ', 140, 96.85, 'ITBIS 18%', 'CERVEZAS', true, false, 606),
  ('830207010706', 'CICLON ORIGINAL 10OZ', 115, 70.80, 'ITBIS 18%', 'CERVEZAS', true, false, 607),
  ('830207010904', 'CICLON BERRY STRONG 10OZ', 110, 70.80, 'ITBIS 18%', 'CERVEZAS', true, false, 608),
  ('830207011109', 'CICLON CRANBERRY', 110, 70.80, 'ITBIS 18%', 'CERVEZAS', true, false, 609),
  ('074090510091', 'OLD TYME BLUEBERRY LEMONADE', 125, 74.93, 'ITBIS 18%', 'COCTELES', true, false, 610),
  ('5010509003001', 'MAC ARTHURS 70CL', 975, 634, 'ITBIS 18%', 'WHISKY', true, false, 611),
  ('8436559524094', 'TRABUCO VINO TINTO', 495, 274.94, 'ITBIS 18%', 'VINOS', true, false, 612),
  ('088076188365', 'BUCHANANS PINEAPPLE 750ML', 2650, 1800, 'ITBIS 18%', 'WHISKY', true, false, 613),
  ('012000240768', 'MOUNTAIN DEW BAJA BLAST CABO CITRUS', 125, 26, 'ITBIS 18%', 'REFRESCOS', true, false, 614),
  ('7960250000025', 'AGUA CRYSTAL', 20, 8, 'ITBIS 18%', 'AGUA', true, false, 615),
  ('7460262300806', 'INDIAN MOTORCYCLE ROBUSTO SHADE', 350, 245, 'ITBIS 18%', 'CIGARRILLOS', false, false, 616),
  ('7460262300622', 'INDIAN MOTORCYCLE ROBUSTO POUCH', 350, 245, 'ITBIS 18%', 'CIGARRILLOS', false, false, 617),
  ('7460262300325', 'INDIAN MOTORCYCLE TORO HABANO', 385, 270, 'ITBIS 18%', 'CIGARRILLOS', false, false, 618),
  ('7460262300363', 'INDIAN MOTORCYCLE MADURO', 385, 270, 'ITBIS 18%', 'CIGARRILLOS', false, false, 619),
  ('7460262300790', 'INDIAN MOTORCYCLE SHADE', 380, 270, 'ITBIS 18%', 'CIGARRILLOS', false, false, 620),
  ('810129850109', 'HABANO CIBAO TORO', 350, 245, 'ITBIS 18%', 'CIGARRILLOS', false, false, 621),
  ('810129850147', 'CIBAO MADURO HABANERO', 350, 245, 'ITBIS 18%', 'CIGARRILLOS', false, false, 622),
  ('7460812902467', 'LA HABANERA 120 ANIVERSARIO', 650, 483, 'ITBIS 18%', 'CIGARRILLOS', false, false, 623),
  ('7460812902320', 'VEGA REAL EDICION ESPECIAL ROBUSTO', 400, 279, 'ITBIS 18%', 'CIGARRILLOS', false, false, 624),
  ('7460812902351', 'VEGA REAL TORO', 450, 301, 'ITBIS 18%', 'CIGARRILLOS', false, false, 625),
  ('74603633', 'VEGA REAL TUBO ROBUSTO', 350, 224, 'ITBIS 18%', 'CIGARRILLOS', false, false, 626),
  ('74601899', 'HABANERA TUBO EMPERADOR', 300, 193, 'ITBIS 18%', 'CIGARRILLOS', false, false, 627),
  ('Cheesecake', 'CHEESECAKE', 245, 82.91, 'ITBIS 18%', 'COMIDA', false, true, 628),
  ('MOJITO LIMON', 'MOJITO CLASICO', 350, 89, 'ITBIS 18%', 'COCTELES', true, false, 629),
  ('MOJITO', 'MOJITO DE COCO Y CHINOLA', 300, 89, 'ITBIS 18%', 'COCTELES', true, false, 630),
  ('PALOMA', 'PALOMA', 595, 89, 'ITBIS 18%', 'COCTELES', true, false, 631),
  ('PINA COLADA', 'PINA COLADA', 350, 100, 'ITBIS 18%', 'COCTELES', true, false, 632),
  ('00982237', 'RAFFAELLO 1OZ', 120, 64, 'ITBIS 18%', 'DULCES', false, false, 633),
  ('009800123018', 'FERRERO ROCHER 1.3OZ', 237, 137, 'ITBIS 18%', 'DULCES', false, false, 634),
  ('009800007226', 'TIC TAC FRUIT ADVENTURE', 210, 107, 'ITBIS 18%', 'DULCES', false, false, 635),
  ('009800007219', 'TIC TAC', 227, 107, 'ITBIS 18%', 'DULCES', false, false, 636),
  ('00985234', 'KINDER JOY', 175, 126, 'ITBIS 18%', 'DULCES', false, false, 637),
  ('049000000443', 'COCA COLA', 75, 40, 'ITBIS 18%', 'REFRESCOS', true, false, 638),
  ('009800000555', 'KINDER BUENO 1.5OZ', 165, 95, 'ITBIS 18%', 'DULCES', false, false, 639),
  ('3800205877325', 'MARETTI BRUSCHETTE CHIPS', 135, 43, 'ITBIS 18%', 'SNACKS', false, false, 640),
  ('8020141203001', 'SANT ANNA 0.5L', 75, 29, 'ITBIS 18%', 'AGUA', true, false, 641),
  ('8020141202004', 'AGUA SANTANNA MINERAL NATURAL 1.5L', 125, 64, 'ITBIS 18%', 'AGUA', true, false, 642),
  ('3800205871255', 'MARETTI BRUSCHETTE', 120, 43, 'ITBIS 18%', 'SNACKS', false, false, 643),
  ('888109010683', 'HOSTESS TWINKIES GOLDEN', 75, 24, 'ITBIS 18%', 'GALLETAS', false, false, 644),
  ('3800205876861', 'MY MOTTO HAZELNUT Y COCOA', 48, 20, 'ITBIS 18%', 'GALLETAS', false, false, 645),
  ('3800205876809', 'MY MOTTO VANILLA MOUSE', 45, 20, 'ITBIS 18%', 'GALLETAS', false, false, 646),
  ('3800237480562', 'MY MOTTO STRAWBERRIES Y CREAM', 45, 20, 'ITBIS 18%', 'GALLETAS', false, false, 647),
  ('3800205871705', 'MY MOTTO COCOA Y COCOA', 45, 20, 'ITBIS 18%', 'GALLETAS', false, false, 648),
  ('QUESILLO', 'FLAN', 250, 120, 'ITBIS 18%', 'COMIDA', false, true, 649),
  ('MOUSE DE CHINOL', 'MOUSE DE CHINOLA', 250, 120, 'ITBIS 18%', 'COMIDA', false, true, 650),
  ('4LECHE', '4 LECHE', 250, 120, 'ITBIS 18%', 'COMIDA', false, true, 651),
  ('607766452878', 'ICE COFFEE CAFE FRIO', 190, 90, 'ITBIS 18%', 'CAFE', true, true, 652),
  ('038000219740', 'FROOT LOOPS', 55, 33, 'ITBIS 18%', 'CEREALES', false, false, 653),
  ('038000219528', 'COCOA KRISPIES', 55, 33, 'ITBIS 18%', 'CEREALES', false, false, 654),
  ('038000219634', 'ZUCARITAS CEREAL', 55, 33, 'ITBIS 18%', 'CEREALES', false, false, 655),
  ('038000219474', 'CORN POPS', 55, 33, 'ITBIS 18%', 'CEREALES', false, false, 656),
  ('038000219856', 'APPLE JACKS', 55, 33, 'ITBIS 18%', 'CEREALES', false, false, 657),
  ('096265830186', 'HANUTA', 190, 99, 'ITBIS 18%', 'GALLETAS', false, false, 658),
  ('009800820016', 'NUTELLA B-READY', 200, 150, 'ITBIS 18%', 'GALLETAS', false, false, 659),
  ('8002670382150', 'CHEESE SNACK', 190, 109, 'ITBIS 18%', 'SNACKS', false, false, 660),
  ('Croissant', 'CROISSANT', 125, 79, 'ITBIS 18%', 'COMIDA', false, true, 661),
  ('CAFE EXPRESSO', 'CAFE EXPRESSO', 50, 35, 'ITBIS 18%', 'CAFE', true, true, 662),
  ('CAFE DOMINICANO', 'CAFE DOMINICANO', 60, 35, 'ITBIS 18%', 'CAFE', true, true, 663),
  ('CORTADITO', 'CORTADITO', 70, 50, 'ITBIS 18%', 'CAFE', true, true, 664),
  ('CAFE CON LECHE', 'CAFE CON LECHE', 100, 75, 'ITBIS 18%', 'CAFE', true, true, 665),
  ('CARAMELO', 'CARAMELO', 100, 75, 'ITBIS 18%', 'CAFE', true, true, 666),
  ('SUIZO', 'SUIZO', 100, 75, 'ITBIS 18%', 'CAFE', true, true, 667),
  ('CHOCOLATE', 'CHOCOLATE', 100, 75, 'ITBIS 18%', 'CAFE', true, true, 668),
  ('CAFE TRADICIONA', 'CAFE TRADICIONAL', 100, 75, 'ITBIS 18%', 'CAFE', true, true, 669),
  ('CAFE MOCACHINO', 'CAFE MOCACHINO', 100, 75, 'ITBIS 18%', 'CAFE', true, true, 670),
  ('781231001201', 'RAP SNACK RICK ROSS', 100, 42, 'ITBIS 18%', 'SNACKS', false, false, 671),
  ('85003628523', 'RAP SNACKS LIL BABY ROJA', 100, 42, 'EXENTO', 'SNACKS', false, false, 672),
  ('850003628318', 'RAP SNACKS SNOOP DOGG', 100, 42, 'ITBIS 18%', 'SNACKS', false, false, 673),
  ('850003628547', 'RAP SNACKS LIL BABY AZUL', 100, 42, 'ITBIS 18%', 'SNACKS', false, false, 674),
  ('762111287915', 'VERENDA BLEND', 1290, 360, 'ITBIS 18%', 'OTROS', false, false, 675),
  ('CHIVAS REGAL 12', 'CHIVAS REGAL 12Y TRAGOS', 350, 100, 'ITBIS 18%', 'COCTELES', true, false, 676),
  ('EMPANADAS', 'EMPANADAS QUESO Y POLLO PIZZA', 100, 65, 'ITBIS 18%', 'COMIDA', false, true, 677),
  ('QUIPE', 'QUIPE POLLO Y RES', 100, 65, 'ITBIS 18%', 'COMIDA', false, true, 678),
  ('044000068714', 'OREO MINT CREME CHOCOLATE', 695, 323, 'ITBIS 18%', 'GALLETAS', false, false, 679),
  ('DONAS', 'DONAS', 60, 33, 'ITBIS 18%', 'COMIDA', false, true, 680),
  ('BISCOCHITO', 'BIZCOCHITO', 35, 28, 'ITBIS 18%', 'COMIDA', false, true, 681),
  ('CROISSANTS', 'CROISSANTS DE MANTEQUILLA', 120, 79, 'ITBIS 18%', 'COMIDA', false, true, 682),
  ('034000560028', 'TWIZZLERS STRAWBERRY', 420, 293, 'ITBIS 18%', 'DULCES', false, false, 683);

-- 4) Insert productos (idempotente por sku). barcode = sku si es numerico.
insert into public.menu_items
  (business_id, category_id, name, price, cost, sku, barcode,
   tax_mode, is_active, is_beverage, has_prep, position)
select
  '23798a79-fc43-4aec-80e0-219b0e183d4f', c.id, t.name, t.price, t.cost, t.sku,
  case when t.sku ~ '^[0-9]+$' then t.sku else null end,
  'inclusive', true, t.is_bev, t.has_prep, t.pos
from tmp_tc t
join public.categories c on c.business_id = '23798a79-fc43-4aec-80e0-219b0e183d4f' and c.name = t.catname
where not exists (
  select 1 from public.menu_items mi
  where mi.business_id = '23798a79-fc43-4aec-80e0-219b0e183d4f' and mi.sku = t.sku
);

-- 5) Ligar cada producto a su impuesto (idempotente).
insert into public.menu_item_taxes (item_id, tax_id)
select mi.id, tx.id
from tmp_tc t
join public.menu_items mi on mi.business_id = '23798a79-fc43-4aec-80e0-219b0e183d4f' and mi.sku = t.sku
join public.taxes tx on tx.business_id = '23798a79-fc43-4aec-80e0-219b0e183d4f' and tx.name = t.taxname
where not exists (
  select 1 from public.menu_item_taxes l
  where l.item_id = mi.id and l.tax_id = tx.id
);

commit;

-- Verificacion rapida (descomentar):
-- select count(*) from public.menu_items where business_id = '23798a79-fc43-4aec-80e0-219b0e183d4f';
