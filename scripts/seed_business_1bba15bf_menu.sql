-- ============================================================================
-- Seed de productos del menú
-- Business: 1bba15bf-f7be-4fcf-9a4d-af61ca114cf1
-- Origen:   Listado de Precios.pdf (sistema viejo del cliente — restaurante/bar
--           con parrilla, mofongos, picaderas, sandwiches, tacos, etc.)
-- ============================================================================
--
-- Procesamiento aplicado al PDF:
--   - tax_mode = 'exclusive' en todos los productos: los precios NO incluyen
--     ITBIS ni Ley 10%. El sistema suma ambos al cobrar.
--   - Costo placeholder 0.01 del sistema viejo → normalizado a 0.
--   - Items con price = 0 se cargan así (CHIVAS REGAL 750ML, CASABE, OTROS,
--     PARRILLADA MIXTA PARA 10/18/22, picadera para 20 personas, PAN TOSTADO).
--     El dueño los actualiza desde la UI antes de venderlos.
--
-- Typos corregidos (la "Referencia" original se preserva como sku):
--     MNICHELOB ULTRA       → MICHELOB ULTRA
--     BOOTELLA VINO         → BOTELLA VINO
--     AROS DE CABOLLA       → AROS DE CEBOLLA
--     CEVEZA PADERBORNE     → CERVEZA PADERBORNE
--     CERVEZA ZABRiNGER     → CERVEZA ZABRINGER
--     COSMOPOLOTAN          → COSMOPOLITAN
--     APPLETINNI            → APPLETINI
--     ENSADA DE POLLO       → ENSALADA DE POLLO
--     HAMBUGER              → HAMBURGER
--     HOT FOG DE POLLO      → HOT DOG DE POLLO
--     HOT DE PIERNA         → HOT DOG DE PIERNA
--     BEACON CHEESE BUURGUER→ BACON CHEESEBURGER
--     CHEESE BURGUER        → CHEESEBURGER
--     SANDUICH              → SANDWICH
--     SANDWICHS             → SANDWICH (singular)
--     TACOS DE PUIERNA      → TACOS DE PIERNA
--     TCOS DE POLLO         → TACOS DE POLLO
--     QUESADILLA DE RES REQ → QUESADILLA DE RES PEQ
--     MAYONES DE ARENQUE    → MAYONESA DE ARENQUE
--     FILETE...REVOSADO     → FILETE...REBOZADO
--     PECHUGA REBOSADA...PIMNETOS → PECHUGA REBOZADA...PIMIENTOS
--     FILETE CERDO RELLENO  → FILETE DE CERDO RELLENO
--     PROMACION             → PROMOCION
--     SABORISADA            → SABORIZADA
--     PINA COLADA           → PIÑA COLADA
--     FROZZEN / FROOSEN     → FROZEN
--     DESCOLCHE             → DESCORCHE
--     STEACK                → STEAK
--     VEGETALES AL GRIL     → VEGETALES AL GRILL
--     ANEJO / ANOS          → AÑEJO / AÑOS
--     S(.) PELLEGRINO       → SAN PELLEGRINO
--     RRFRESCO 16 oz        → REFRESCO 16 OZ (consolidado con sku 1000018)
--     PICADERA MIXTA PAR 15 → PICADERA MIXTA PARA 15
--     CHICKEN NUGGET CON PAPA FRITAS → CHICKEN NUGGET CON PAPAS FRITAS
--     NACHOS DE POLLOS PÈQ  → NACHOS DE POLLO PEQ
--     CANASTICA RELLENAS    → CANASTICA RELLENA
--     QUESO MOZARELA        → QUESO MOZZARELLA
--     PAPA FRITAS           → PAPAS FRITAS
--     BURRITOS DE POLLO     → BURRITO DE POLLO
--     WRAPS DE ...          → WRAP DE ... (singular)
--     CLUB SANDWICH .       → CLUB SANDWICH (sin punto sobrante)
--     GDEZ                  → GDE (estandarizado en quesadillas/nachos)
--
-- Duplicados consolidados (mismo producto con dos referencias en el PDF —
-- se conserva el sku más antiguo; los demás NO se cargan):
--     MICHELOB ULTRA       sku 1000112 (descarta 1000130 MNICHELOB, 1000131)
--     CAIPIROSKA           sku 1000078 (descarta 1000072)
--     LIMONCELLO           sku 1000102 (descarta 1000084)
--     BOTELLA 19 CRIMES    sku 1000069 (descarta 1000064)
--     MARGARITA            sku 1000010 (descarta 1000075)
--     COSMOPOLITAN         sku 1000077 (descarta 1000071 COSMOPOLOTAN)
--     HOT DOG DE POLLO     sku 1040    (descarta 1001 HOT FOG)
--     REFRESCO 16 OZ       sku 1000018 (descarta 1177 RRFRESCO)
--     TABLA DE VEGETALES   sku 1114    (descarta 1110, conserva costo menor)
--     TACO DE POLLO        sku 1106    (descarta 1159, mismo precio)
--     QUESADILLA MIXTA PEQ sku 1000040 (descarta 1064)
--     QUESADILLA POLLO GDE sku 1083    (descarta 1113, que estaba en price=0)
--
-- Conflictos preservados (mismo nombre, precio DISTINTO — el dueño decide):
--     QUISQUEYA            1000006=100 + 1000008=120  → renombrada la 2da
--                                                         como QUISQUEYA GRANDE
--     CORONA               1033=200 + 1000129=175     → renombrada la 2da
--                                                         como CORONA PEQUEÑA
--     SPRITE               1164=60 + 1201=40           → SPRITE GDE / SPRITE PEQ
--     FRESA FROZEN         1209=250 + 1163=125         → FRESA FROZEN GDE / PEQ
--     PICANTE              1000098=250 + 1000114=200   → PICANTE / PICANTE PEQ
--     SAN PELLEGRINO 750ML 1000043=265 + 1000067=300   → la 2da con sufijo PREMIUM
--     TACO(S) DE POLLO     1106=150 (singular) +
--                          1049=110 (plural, era TCOS) → mantenidos como
--                                                         "TACO DE POLLO" y
--                                                         "TACOS DE POLLO"
--     BRUGAL 1888          1000003=350 (bottle?) +
--                          1000056 TRAGO BRUGAL 1888=400 → ambos cargan
--
-- Impuestos:
--   - Se garantizan dos taxes para este business: ITBIS 18% y Propina Ley 10%
--     (is_service_fee=true). Se crean solo si no existen.
--   - Se vinculan automáticamente AMBOS impuestos a TODOS los productos de
--     menú EXCEPTO los de la categoría "EXTRAS Y SERVICIOS" (ALQUILERES,
--     DELIVERY, CARBON, FUNDA DE HIELO, etc.), donde el dueño decide caso
--     por caso desde la UI.
--
-- Idempotente:
--   - Categorías, taxes, productos y vinculaciones se insertan solo si no
--     existen. Re-ejecutar este script no duplica nada.
-- ============================================================================

begin;

-- ----------------------------------------------------------------------------
-- 1) Categorías
-- ----------------------------------------------------------------------------

insert into public.categories (id, business_id, name, position, is_active)
select gen_random_uuid(), '1bba15bf-f7be-4fcf-9a4d-af61ca114cf1', 'CERVEZAS', 0, true
where not exists (select 1 from public.categories where business_id = '1bba15bf-f7be-4fcf-9a4d-af61ca114cf1' and name = 'CERVEZAS');

insert into public.categories (id, business_id, name, position, is_active)
select gen_random_uuid(), '1bba15bf-f7be-4fcf-9a4d-af61ca114cf1', 'BOTELLAS DE LICOR', 1, true
where not exists (select 1 from public.categories where business_id = '1bba15bf-f7be-4fcf-9a4d-af61ca114cf1' and name = 'BOTELLAS DE LICOR');

insert into public.categories (id, business_id, name, position, is_active)
select gen_random_uuid(), '1bba15bf-f7be-4fcf-9a4d-af61ca114cf1', 'BOTELLAS DE VINO Y CHAMPAGNE', 2, true
where not exists (select 1 from public.categories where business_id = '1bba15bf-f7be-4fcf-9a4d-af61ca114cf1' and name = 'BOTELLAS DE VINO Y CHAMPAGNE');

insert into public.categories (id, business_id, name, position, is_active)
select gen_random_uuid(), '1bba15bf-f7be-4fcf-9a4d-af61ca114cf1', 'TRAGOS Y COCTELES', 3, true
where not exists (select 1 from public.categories where business_id = '1bba15bf-f7be-4fcf-9a4d-af61ca114cf1' and name = 'TRAGOS Y COCTELES');

insert into public.categories (id, business_id, name, position, is_active)
select gen_random_uuid(), '1bba15bf-f7be-4fcf-9a4d-af61ca114cf1', 'BEBIDAS SIN ALCOHOL', 4, true
where not exists (select 1 from public.categories where business_id = '1bba15bf-f7be-4fcf-9a4d-af61ca114cf1' and name = 'BEBIDAS SIN ALCOHOL');

insert into public.categories (id, business_id, name, position, is_active)
select gen_random_uuid(), '1bba15bf-f7be-4fcf-9a4d-af61ca114cf1', 'ENTRADAS Y PICADERAS', 5, true
where not exists (select 1 from public.categories where business_id = '1bba15bf-f7be-4fcf-9a4d-af61ca114cf1' and name = 'ENTRADAS Y PICADERAS');

insert into public.categories (id, business_id, name, position, is_active)
select gen_random_uuid(), '1bba15bf-f7be-4fcf-9a4d-af61ca114cf1', 'PARRILLA Y CARNES', 6, true
where not exists (select 1 from public.categories where business_id = '1bba15bf-f7be-4fcf-9a4d-af61ca114cf1' and name = 'PARRILLA Y CARNES');

insert into public.categories (id, business_id, name, position, is_active)
select gen_random_uuid(), '1bba15bf-f7be-4fcf-9a4d-af61ca114cf1', 'MOFONGOS', 7, true
where not exists (select 1 from public.categories where business_id = '1bba15bf-f7be-4fcf-9a4d-af61ca114cf1' and name = 'MOFONGOS');

insert into public.categories (id, business_id, name, position, is_active)
select gen_random_uuid(), '1bba15bf-f7be-4fcf-9a4d-af61ca114cf1', 'ENSALADAS', 8, true
where not exists (select 1 from public.categories where business_id = '1bba15bf-f7be-4fcf-9a4d-af61ca114cf1' and name = 'ENSALADAS');

insert into public.categories (id, business_id, name, position, is_active)
select gen_random_uuid(), '1bba15bf-f7be-4fcf-9a4d-af61ca114cf1', 'HAMBURGUESAS', 9, true
where not exists (select 1 from public.categories where business_id = '1bba15bf-f7be-4fcf-9a4d-af61ca114cf1' and name = 'HAMBURGUESAS');

insert into public.categories (id, business_id, name, position, is_active)
select gen_random_uuid(), '1bba15bf-f7be-4fcf-9a4d-af61ca114cf1', 'SANDWICHES Y HOT DOGS', 10, true
where not exists (select 1 from public.categories where business_id = '1bba15bf-f7be-4fcf-9a4d-af61ca114cf1' and name = 'SANDWICHES Y HOT DOGS');

insert into public.categories (id, business_id, name, position, is_active)
select gen_random_uuid(), '1bba15bf-f7be-4fcf-9a4d-af61ca114cf1', 'WRAPS Y BURRITOS', 11, true
where not exists (select 1 from public.categories where business_id = '1bba15bf-f7be-4fcf-9a4d-af61ca114cf1' and name = 'WRAPS Y BURRITOS');

insert into public.categories (id, business_id, name, position, is_active)
select gen_random_uuid(), '1bba15bf-f7be-4fcf-9a4d-af61ca114cf1', 'TACOS Y QUESADILLAS', 12, true
where not exists (select 1 from public.categories where business_id = '1bba15bf-f7be-4fcf-9a4d-af61ca114cf1' and name = 'TACOS Y QUESADILLAS');

insert into public.categories (id, business_id, name, position, is_active)
select gen_random_uuid(), '1bba15bf-f7be-4fcf-9a4d-af61ca114cf1', 'NACHOS, FLAUTAS Y RIKIS', 13, true
where not exists (select 1 from public.categories where business_id = '1bba15bf-f7be-4fcf-9a4d-af61ca114cf1' and name = 'NACHOS, FLAUTAS Y RIKIS');

insert into public.categories (id, business_id, name, position, is_active)
select gen_random_uuid(), '1bba15bf-f7be-4fcf-9a4d-af61ca114cf1', 'POSTRES', 14, true
where not exists (select 1 from public.categories where business_id = '1bba15bf-f7be-4fcf-9a4d-af61ca114cf1' and name = 'POSTRES');

insert into public.categories (id, business_id, name, position, is_active)
select gen_random_uuid(), '1bba15bf-f7be-4fcf-9a4d-af61ca114cf1', 'EXTRAS Y SERVICIOS', 15, true
where not exists (select 1 from public.categories where business_id = '1bba15bf-f7be-4fcf-9a4d-af61ca114cf1' and name = 'EXTRAS Y SERVICIOS');

-- ----------------------------------------------------------------------------
-- 2) Impuestos (ITBIS 18% y Propina Ley 10%) — solo si no existen
-- ----------------------------------------------------------------------------

insert into public.taxes (business_id, name, rate, is_service_fee)
select '1bba15bf-f7be-4fcf-9a4d-af61ca114cf1', 'ITBIS', 18, false
where not exists (
  select 1 from public.taxes
  where business_id = '1bba15bf-f7be-4fcf-9a4d-af61ca114cf1' and rate = 18 and coalesce(is_service_fee, false) = false
);

insert into public.taxes (business_id, name, rate, is_service_fee)
select '1bba15bf-f7be-4fcf-9a4d-af61ca114cf1', 'Propina Ley', 10, true
where not exists (
  select 1 from public.taxes
  where business_id = '1bba15bf-f7be-4fcf-9a4d-af61ca114cf1' and rate = 10 and coalesce(is_service_fee, false) = true
);

-- ----------------------------------------------------------------------------
-- 3) Productos por categoría (dedup por (business_id, sku))
-- ----------------------------------------------------------------------------

do $$
declare
  v_bid uuid := '1bba15bf-f7be-4fcf-9a4d-af61ca114cf1'::uuid;

  v_cervezas      uuid;
  v_botellas_lic  uuid;
  v_botellas_vino uuid;
  v_tragos        uuid;
  v_bebidas_sa    uuid;
  v_entradas      uuid;
  v_parrilla      uuid;
  v_mofongos      uuid;
  v_ensaladas     uuid;
  v_hamburguesas  uuid;
  v_sandwiches    uuid;
  v_wraps         uuid;
  v_tacos         uuid;
  v_nachos        uuid;
  v_postres       uuid;
  v_extras        uuid;
begin
  select id into v_cervezas      from public.categories where business_id = v_bid and name = 'CERVEZAS' limit 1;
  select id into v_botellas_lic  from public.categories where business_id = v_bid and name = 'BOTELLAS DE LICOR' limit 1;
  select id into v_botellas_vino from public.categories where business_id = v_bid and name = 'BOTELLAS DE VINO Y CHAMPAGNE' limit 1;
  select id into v_tragos        from public.categories where business_id = v_bid and name = 'TRAGOS Y COCTELES' limit 1;
  select id into v_bebidas_sa    from public.categories where business_id = v_bid and name = 'BEBIDAS SIN ALCOHOL' limit 1;
  select id into v_entradas      from public.categories where business_id = v_bid and name = 'ENTRADAS Y PICADERAS' limit 1;
  select id into v_parrilla      from public.categories where business_id = v_bid and name = 'PARRILLA Y CARNES' limit 1;
  select id into v_mofongos      from public.categories where business_id = v_bid and name = 'MOFONGOS' limit 1;
  select id into v_ensaladas     from public.categories where business_id = v_bid and name = 'ENSALADAS' limit 1;
  select id into v_hamburguesas  from public.categories where business_id = v_bid and name = 'HAMBURGUESAS' limit 1;
  select id into v_sandwiches    from public.categories where business_id = v_bid and name = 'SANDWICHES Y HOT DOGS' limit 1;
  select id into v_wraps         from public.categories where business_id = v_bid and name = 'WRAPS Y BURRITOS' limit 1;
  select id into v_tacos         from public.categories where business_id = v_bid and name = 'TACOS Y QUESADILLAS' limit 1;
  select id into v_nachos        from public.categories where business_id = v_bid and name = 'NACHOS, FLAUTAS Y RIKIS' limit 1;
  select id into v_postres       from public.categories where business_id = v_bid and name = 'POSTRES' limit 1;
  select id into v_extras        from public.categories where business_id = v_bid and name = 'EXTRAS Y SERVICIOS' limit 1;

  -- ==========================================================================
  -- CERVEZAS (is_beverage = true)
  -- ==========================================================================
  insert into public.menu_items (business_id, category_id, sku, name, price, cost, tax_mode, is_active, is_beverage)
  select v_bid, v_cervezas, p.sku, p.name, p.price::numeric(12,2), p.cost::numeric(12,2), 'exclusive', true, true
  from (values
    ('1000053', 'BLUE MOON',                  250, 0),
    ('1211',    'BOHEMIA',                    175, 0),
    ('1191',    'CERVEZA ERDINGER PICANTUS',  350, 0),
    ('1193',    'CERVEZA LEFFE',              200, 0),
    ('1000031', 'CERVEZA MAHOU',              150, 0),
    ('1000011', 'CERVEZA MAHOU SIN ALCOHOL',  100, 0),
    ('1000068', 'CERVEZA ONE',                150, 0),
    ('1174',    'CERVEZA WARTEINER ALEMANA',  180, 0),
    ('1192',    'CERVEZA ZABRINGER',          150, 0),
    ('1175',    'CERVEZA PADERBORNE',         150, 0),
    ('1000111', 'COMBO COORS LIGHT 3X2',      350, 0),
    ('1000095', 'COMBO COORS ORIGINAL 3X2',   350, 0),
    ('1000096', 'COMBO HEINEKEN 3X2',         450, 0),
    ('1000097', 'COMBO MILLER 3X2',           400, 0),
    ('1000059', 'COORS ORIGINAL VIDRIO',      200, 0),
    ('1200',    'COORS LIGHT',                175, 0),
    ('1033',    'CORONA',                     200, 80),
    ('1000129', 'CORONA PEQUEÑA',             175, 0),
    ('1171',    'CORONITA',                    80, 0),
    ('1000060', 'HEINEKEN',                   250, 0),
    ('1000112', 'MICHELOB ULTRA',             200, 0),
    ('1000063', 'MILLER',                     200, 0),
    ('1034',    'MODELO',                     200, 85),
    ('1000005', 'MODELO NEGRA',               250, 0),
    ('1189',    'PAULANER',                   350, 0),
    ('1210',    'PRESIDENTE 7OZ',              90, 0),
    ('1136',    'PRESIDENTE LATA 8OZ',        100, 0),
    ('1032',    'PRESIDENTE PEQ.',            175, 66),
    ('1000006', 'QUISQUEYA',                  100, 0),
    ('1000008', 'QUISQUEYA GRANDE',           120, 0),
    ('1138',    'STELLA',                     200, 0)
  ) as p(sku, name, price, cost)
  where not exists (select 1 from public.menu_items mi where mi.business_id = v_bid and mi.sku = p.sku);

  -- ==========================================================================
  -- BOTELLAS DE LICOR (is_beverage = true)
  -- ==========================================================================
  insert into public.menu_items (business_id, category_id, sku, name, price, cost, tax_mode, is_active, is_beverage)
  select v_bid, v_botellas_lic, p.sku, p.name, p.price::numeric(12,2), p.cost::numeric(12,2), 'exclusive', true, true
  from (values
    ('1148',    'BARCELO GRAN AÑEJO',                650, 0),
    ('1151',    'BARCELO GRAN AÑEJO 1000 ML',        850, 0),
    ('1000051', 'BOTELLA BARCELO GRAN AÑEJO',        475, 0),
    ('1208',    'BOTELLA BRUGAL BLANCO',             650, 0),
    ('1000030', 'BOTELLA BRUGAL DOBLE RESERVA',     1300, 0),
    ('1000007', 'BOTELLA BRUGAL XV',                 950, 0),
    ('1000110', 'BOTELLA BRUGAL XV 350 ML',          525, 0),
    ('1214',    'BOTELLA CHIVAS REGAL 750ML',          0, 0),
    ('1000024', 'BOTELLA DE BUCHANANS',             2600, 0),
    ('1129',    'BOTELLA DE DEWARS',                 850, 0),
    ('1141',    'BOTELLA DE STOLICHNAYA',           1750, 0),
    ('1000121', 'BOTELLA DEWARS 12 AÑOS',           2750, 0),
    ('1000113', 'BOTELLA GINEBRA BOMBAY',           2450, 0),
    ('1000082', 'BOTELLA TANQUERAY',                2450, 0),
    ('1124',    'BRUGAL AÑEJO',                      425, 0),
    ('1149',    'BRUGAL EXTRA VIEJO',                550, 0),
    ('1000066', 'BRUGAL EXTRA VIEJO BOTELLA PEQ',    550, 0),
    ('1198',    'BRUGAL LEYENDA',                   1400, 0),
    ('1000003', 'BRUGAL 1888',                       350, 150),
    ('1000048', 'CIELITO LINDO',                    2500, 0),
    ('1000029', 'DEWARS PORTUGUESE 8 AÑOS',         1500, 0),
    ('1203',    'ETIQUETA NEGRA LITRO',             2500, 0),
    ('1204',    'GINEBRA BERMUDEZ PEQ',              300, 0),
    ('1000123', 'LITRO BRUGAL EXTRA VIEJO',          950, 0),
    ('1166',    'SMIRNOFF',                          200, 0),
    ('1000055', 'TEQUILA',                           300, 0)
  ) as p(sku, name, price, cost)
  where not exists (select 1 from public.menu_items mi where mi.business_id = v_bid and mi.sku = p.sku);

  -- ==========================================================================
  -- BOTELLAS DE VINO Y CHAMPAGNE (is_beverage = true)
  -- ==========================================================================
  insert into public.menu_items (business_id, category_id, sku, name, price, cost, tax_mode, is_active, is_beverage)
  select v_bid, v_botellas_vino, p.sku, p.name, p.price::numeric(12,2), p.cost::numeric(12,2), 'exclusive', true, true
  from (values
    ('1000101', 'BOTELLA VINO G ENTELMAN',                  2000, 0),
    ('1000069', 'BOTELLA 19 CRIMES',                        2000, 0),
    ('1117',    'BOTELLA DE VINO',                          1500, 1500),
    ('1181',    'BOTELLA DE VINO CASILLERO DEL DIABLO',     1250, 0),
    ('1000103', 'BOTELLA DE VINO EIGHT SIX NINE',           2000, 0),
    ('1217',    'BOTELLA DE VINO F Y J',                     975, 0),
    ('1182',    'BOTELLA DE VINO GLORIOSO',                 1800, 0),
    ('1180',    'BOTELLA DE VINO PALO ALTO',                1250, 0),
    ('1000009', 'BOTELLA DE VINO PRIVATE DANCER',           1300, 0),
    ('1206',    'BOTELLA VINO CARLO ROSSI BLANCO',           650, 0),
    ('1202',    'BOTELLA VINO TISDALE',                      700, 10),
    ('1000027', 'BOTELLA VINO VIÑA MAIPO',                   950, 0),
    ('1000116', 'CAVA RIGOL',                                950, 0),
    ('1079',    'COPA DE VINO',                              225, 50),
    ('1000026', 'MENAGE A TROIS',                           1500, 0)
  ) as p(sku, name, price, cost)
  where not exists (select 1 from public.menu_items mi where mi.business_id = v_bid and mi.sku = p.sku);

  -- ==========================================================================
  -- TRAGOS Y COCTELES (is_beverage = true)
  -- ==========================================================================
  insert into public.menu_items (business_id, category_id, sku, name, price, cost, tax_mode, is_active, is_beverage)
  select v_bid, v_tragos, p.sku, p.name, p.price::numeric(12,2), p.cost::numeric(12,2), 'exclusive', true, true
  from (values
    ('1152',    'ALEXANDER',                       150, 0),
    ('1000050', 'APEROL SPRITZ',                   350, 0),
    ('1000080', 'APPLETINI',                       350, 0),
    ('1000081', 'CAIPIRIÑA',                       200, 0),
    ('1000078', 'CAIPIROSKA',                      200, 0),
    ('1000079', 'CAIPIROSKA AFRUTADO',             250, 0),
    ('1000118', 'CAMPARI',                         300, 0),
    ('1000077', 'COSMOPOLITAN',                    350, 0),
    ('1130',    'CRANBERRY',                       250, 0),
    ('1209',    'FRESA FROZEN GDE',                250, 0),
    ('1163',    'FRESA FROZEN PEQ',                125, 0),
    ('1119',    'GALON DE FRUIT PUNCH',           1250, 1250),
    ('1120',    'GALON DE MOJITO',                1500, 0),
    ('1000073', 'GIN TONIC PINK',                  350, 0),
    ('1142',    'LIMONADA FROZEN',                 100, 0),
    ('1000102', 'LIMONCELLO',                      200, 0),
    ('1000074', 'LONG ISLAND',                     350, 0),
    ('1000010', 'MARGARITA',                       350, 0),
    ('1000120', 'MICHELADA',                       300, 0),
    ('1000076', 'MIMOSA',                          200, 0),
    ('1077',    'MOJITO',                          280, 75),
    ('1205',    'MOSCOW MULE',                     300, 0),
    ('1000122', 'MOTTS DE MANZANA',                300, 0),
    ('1000108', 'NEGRONI',                         350, 0),
    ('1118',    'PIÑA COLADA',                     200, 200),
    ('1104',    'SANGRIA',                         280, 200),
    ('1165',    'SANGRIA GINA',                    200, 0),
    ('1000099', 'TEQUILA MULE',                    350, 0),
    ('1000104', 'TEQUI MULE',                      350, 0),
    ('1146',    'TRAGO BARCELO AÑEJO',             150, 0),
    ('1000054', 'TRAGO BARCELO IMPERIAL',          250, 0),
    ('1000056', 'TRAGO BRUGAL 1888',               400, 0),
    ('1215',    'TRAGO BRUGAL DOBLE RESERVA',      250, 0),
    ('1184',    'TRAGO DE BRUGAL EXTRA VIEJO',     150, 0),
    ('1039',    'TRAGO DE BRUGAL XV',              150, 50),
    ('1038',    'TRAGO DE BUCHANAN',               350, 100),
    ('1172',    'TRAGO DE CHIVAS REGAL',           300, 0),
    ('1036',    'TRAGO DE DEWARS',                 250, 50),
    ('1000036', 'TRAGO DE OLD PARR',               250, 0),
    ('1037',    'TRAGO DE VODKA',                  250, 75),
    ('1187',    'TRAGO DEWARS 12 AÑOS',            300, 0),
    ('1132',    'TRAGO ETIQUETA NEGRA',            350, 0),
    ('1221',    'TRAGO GINEBRA AFRUTADO',          350, 0),
    ('1000052', 'TRAGO GLENLIVET',                 300, 0),
    ('1213',    'TRAGO GREY GOOSE',                350, 0),
    ('1212',    'TRAGO LEYENDA',                   200, 10),
    ('1000041', 'TUTI FRUTI',                      150, 0),
    ('1078',    'VINO SANGRIA TINTA',              250, 50)
  ) as p(sku, name, price, cost)
  where not exists (select 1 from public.menu_items mi where mi.business_id = v_bid and mi.sku = p.sku);

  -- ==========================================================================
  -- BEBIDAS SIN ALCOHOL (is_beverage = true)
  -- ==========================================================================
  insert into public.menu_items (business_id, category_id, sku, name, price, cost, tax_mode, is_active, is_beverage)
  select v_bid, v_bebidas_sa, p.sku, p.name, p.price::numeric(12,2), p.cost::numeric(12,2), 'exclusive', true, true
  from (values
    ('1076',    'AGUA',                              25, 7),
    ('1190',    'AGUA DASANI SABORIZADA',            50, 0),
    ('1097',    'AGUA PERRIER',                     200, 50),
    ('1127',    'AGUA PERRIER GDE',                 275, 50),
    ('1111',    'AGUA TONICA',                       75, 50),
    ('1000124', 'CAFE',                              75, 0),
    ('1035',    'CLAMATO',                           75, 35),
    ('1000105', 'COCA-COLA DIETA',                   75, 0),
    ('1000037', 'DOBLE LITRO',                      100, 0),
    ('1000032', 'DOBLE LITRO COCA-COLA',            100, 0),
    ('1216',    'GINGER ALE',                        75, 0),
    ('1000033', 'ICE TEA',                           50, 0),
    ('1197',    'JUGO DE NARANJA RICA',             200, 0),
    ('1126',    'JUGO PEQ',                          35, 50),
    ('1074',    'JUGOS NATURAL DE TEMPORADA',       100, 20),
    ('1000109', 'MICKEY MOUSE',                     100, 0),
    ('1000117', 'RED BULL',                         150, 0),
    ('1075',    'REFRESCO',                          40, 20),
    ('1000018', 'REFRESCO 16 OZ',                    50, 0),
    ('1147',    'REFRESCO 20 OZ',                    60, 0),
    ('1000043', 'SAN PELLEGRINO 750ML',             265, 0),
    ('1000067', 'SAN PELLEGRINO 750ML PREMIUM',     300, 0),
    ('1000044', 'SAN PELLEGRINO 505ML',             250, 0),
    ('1000057', 'SAN PELLEGRINO 250ML',             150, 0),
    ('1168',    'SEVENUP',                           40, 0),
    ('1101',    'SODA AMARGA',                       75, 25),
    ('1000128', 'SPARKLING ICE',                    200, 0),
    ('1164',    'SPRITE GDE',                        60, 0),
    ('1201',    'SPRITE PEQ',                        40, 0)
  ) as p(sku, name, price, cost)
  where not exists (select 1 from public.menu_items mi where mi.business_id = v_bid and mi.sku = p.sku);

  -- ==========================================================================
  -- ENTRADAS Y PICADERAS
  -- ==========================================================================
  insert into public.menu_items (business_id, category_id, sku, name, price, cost, tax_mode, is_active, is_beverage)
  select v_bid, v_entradas, p.sku, p.name, p.price::numeric(12,2), p.cost::numeric(12,2), 'exclusive', true, false
  from (values
    ('1137',    'AGUACATE',                                       150, 0),
    ('1143',    'ALBONDIGUITAS',                                  200, 0),
    ('1000038', 'ALITAS DE 8 UNIDADES',                           400, 0),
    ('1016',    'ALITAS NATURAL Y PICANTES',                      250, 50),
    ('1000070', 'AROS DE CEBOLLA',                                225, 0),
    ('1000',    'BERENJENA DON CARBON',                           200, 25),
    ('1021',    'CANASTICA DE PLATANO RELLENO DE ROPA VIEJA',     300, 100),
    ('1000015', 'CANASTICA RELLENA DE CHICHARRON',                350, 0),
    ('1000039', 'CANASTICA RELLENA DE POLLO',                     350, 0),
    ('1100',    'CASABE',                                           0, 0),
    ('1139',    'CEPA DE APIO',                                   100, 0),
    ('1000004', 'CEVICHE',                                        350, 350),
    ('1013',    'CHICHARRON',                                     400, 50),
    ('1024',    'CHICKEN NUGGET CON PAPAS FRITAS',                250, 50),
    ('1123',    'CHIMI',                                          200, 0),
    ('1005',    'CROSTINIS',                                      150, 25),
    ('1122',    'FRASCO DE PESTO',                                500, 0),
    ('1162',    'HUMMUS',                                         450, 0),
    ('1031',    'MAIZ ASADO',                                     150, 25),
    ('1154',    'MAYONESA DE ARENQUE',                            600, 0),
    ('1128',    'PALITOS DE MOZZARELLA',                          275, 150),
    ('1098',    'PAN TOSTADO',                                      0, 0),
    ('1028',    'PAPAS FRITAS',                                   100, 25),
    ('1029',    'PAPAS ASADAS',                                   150, 25),
    ('1000035', 'PARRILLADA MIXTA PARA 8',                       3500, 0),
    ('1157',    'PARRILLADA MIXTA PARA 10',                         0, 0),
    ('1220',    'PARRILLADA PARA 18 PERSONAS',                      0, 0),
    ('1115',    'PARRILLADA PARA 2',                              950, 650),
    ('1000058', 'PICADERA',                                      0.01, 0),
    ('1000047', 'PICADERA MIXTA PARA 15',                        8500, 0),
    ('1156',    'PICADERA MIXTA PARA 10',                           0, 0),
    ('1176',    'PICADERA MIXTA PARA 22',                           0, 0),
    ('1022',    'PICADERA MIXTA PARA 4 PERSONAS',                1750, 250),
    ('1169',    'PICADERA MIXTA PARA 6 PERSONAS',                2500, 0),
    ('1222',    'PICADERA PARA 20 PERSONAS',                        0, 0),
    ('1000098', 'PICANTE',                                        250, 0),
    ('1000114', 'PICANTE PEQ',                                    200, 0),
    ('1150',    'PICO DE GALLO',                                   30, 0),
    ('1000021', 'PIMIENTOS ASADOS',                               100, 0),
    ('1155',    'PIMIENTOS ASADOS DE ROPA VIEJA',                 300, 0),
    ('1002',    'PIMIENTOS ASADOS RELLENOS DE QUESO',             150, 25),
    ('1102',    'PIMIENTOS DE BERENJENA',                         250, 195),
    ('1000020', 'PIZZA',                                          190, 0),
    ('1131',    'PLATANO AMARILLO ASADO',                          75, 50),
    ('1135',    'PURE DE PAPAS',                                  250, 0),
    ('1185',    'QUESO DE FREIR',                                 200, 0),
    ('1178',    'QUESOS',                                         200, 0),
    ('1004',    'QUIPES',                                         100, 20),
    ('1112',    'QUIPES CRUDO',                                   500, 35),
    ('1183',    'SALSA DE TOMATICOS',                             150, 0),
    ('1000025', 'SERVICIO DE CASABE',                              75, 0),
    ('1000083', 'SERVICIO DE CATIVIAS (3)',                       250, 0),
    ('1000042', 'SERVICIO DE PAN',                                 75, 0),
    ('1114',    'TABLA DE VEGETALES',                             800, 200),
    ('1145',    'TIPILE',                                         350, 0),
    ('1030',    'TOSTONES',                                       100, 25),
    ('1092',    'VEGETALES AL GRILL',                             100, 50),
    ('1027',    'YUQUITAS FRITAS',                                100, 25)
  ) as p(sku, name, price, cost)
  where not exists (select 1 from public.menu_items mi where mi.business_id = v_bid and mi.sku = p.sku);

  -- ==========================================================================
  -- PARRILLA Y CARNES (has_prep = true)
  -- ==========================================================================
  insert into public.menu_items (business_id, category_id, sku, name, price, cost, tax_mode, is_active, is_beverage, has_prep)
  select v_bid, v_parrilla, p.sku, p.name, p.price::numeric(12,2), p.cost::numeric(12,2), 'exclusive', true, false, true
  from (values
    ('1218',    'CARNE MOLIDA',                                                450, 0),
    ('1011',    'CARNE SALADA A LA PARRILLA',                                  300, 50),
    ('1219',    'CHIVO',                                                       750, 50),
    ('1009',    'CHULETAS',                                                    400, 50),
    ('1081',    'CHURRASCO ANGUS',                                            1300, 150),
    ('1020',    'CONEJO',                                                      700, 100),
    ('1010',    'COSTILLA',                                                    450, 50),
    ('1000014', 'COSTILLAS SAN LUIS',                                          595, 0),
    ('1007',    'FILETE DE CERDO RELLENO DE QUESO MOZZARELLA Y PIMIENTOS ASADOS', 650, 50),
    ('1006',    'FILETE DE CERDO',                                             450, 25),
    ('1080',    'FILETE DE RES CON CASABE',                                    650, 50),
    ('1090',    'FILETE DE RES CON PAN',                                       650, 65),
    ('1000017', 'FILETE DE RES REBOZADO DE QUESO',                             800, 0),
    ('1012',    'LONGANIZA A LA PARRILLA',                                     250, 50),
    ('1207',    'LONGANIZA POR LIBRA',                                         200, 0),
    ('1008',    'MEDALLONES DE FILETE DE CERDO ENVUELTO EN TOCINETA',          725, 50),
    ('1116',    'MEDALLONES DE RES ENVUELTOS EN TOCINETA',                     800, 375),
    ('1015',    'PECHUGA REBOZADA DE QUESO MOZZARELLA Y PIMIENTOS ASADOS',     575, 50),
    ('1014',    'PECHUGAS',                                                    400, 50),
    ('1017',    'PINCHOS',                                                     195, 50),
    ('1003',    'SALCHICHAS NATURALES Y PICANTES',                             250, 25),
    ('1023',    'SALMON A LA PARRILLA PERFUMADO DE ROMERO',                    750, 0),
    ('1082',    'SOLOMO',                                                      450, 100),
    ('1194',    'VACIO STEAK',                                                 700, 0)
  ) as p(sku, name, price, cost)
  where not exists (select 1 from public.menu_items mi where mi.business_id = v_bid and mi.sku = p.sku);

  -- ==========================================================================
  -- MOFONGOS (has_prep = true)
  -- ==========================================================================
  insert into public.menu_items (business_id, category_id, sku, name, price, cost, tax_mode, is_active, is_beverage, has_prep)
  select v_bid, v_mofongos, p.sku, p.name, p.price::numeric(12,2), p.cost::numeric(12,2), 'exclusive', true, false, true
  from (values
    ('1133',    'MOFONGO',                       375, 0),
    ('1000093', 'MOFONGO CON CHICHARRON EXTRA',  575, 0),
    ('1140',    'MOFONGO DE CEPA',               350, 0),
    ('1195',    'MOFONGO DE POLLO',              300, 0),
    ('1196',    'MOFONGO DE POLLO/QUESO',        325, 0)
  ) as p(sku, name, price, cost)
  where not exists (select 1 from public.menu_items mi where mi.business_id = v_bid and mi.sku = p.sku);

  -- ==========================================================================
  -- ENSALADAS
  -- ==========================================================================
  insert into public.menu_items (business_id, category_id, sku, name, price, cost, tax_mode, is_active, is_beverage)
  select v_bid, v_ensaladas, p.sku, p.name, p.price::numeric(12,2), p.cost::numeric(12,2), 'exclusive', true, false
  from (values
    ('1019', 'ENSALADA CHURRASCO',              800, 100),
    ('1018', 'ENSALADA DON CARBON',             350, 50),
    ('1066', 'ENSALADA DE POLLO',               350, 75),
    ('1067', 'ENSALADA DE POLLO CON SALCHICHA', 350, 75),
    ('1170', 'ENSALADA GDE',                    200, 0),
    ('1091', 'ENSALADA PEQ.',                   100, 50)
  ) as p(sku, name, price, cost)
  where not exists (select 1 from public.menu_items mi where mi.business_id = v_bid and mi.sku = p.sku);

  -- ==========================================================================
  -- HAMBURGUESAS (has_prep = true)
  -- ==========================================================================
  insert into public.menu_items (business_id, category_id, sku, name, price, cost, tax_mode, is_active, is_beverage, has_prep)
  select v_bid, v_hamburguesas, p.sku, p.name, p.price::numeric(12,2), p.cost::numeric(12,2), 'exclusive', true, false, true
  from (values
    ('1103',    'BACON CHEESEBURGER',              320, 200),
    ('1153',    'BACON CHEESEBURGER DOBLE QUESO',  250, 0),
    ('1047',    'CHEESEBURGER',                    280, 50),
    ('1000126', 'CHEESEBURGER DOBLE CARNE',        400, 0),
    ('1046',    'HAMBURGER',                       250, 45),
    ('1048',    'HAMBURGER GULLIVEN',              400, 85)
  ) as p(sku, name, price, cost)
  where not exists (select 1 from public.menu_items mi where mi.business_id = v_bid and mi.sku = p.sku);

  -- ==========================================================================
  -- SANDWICHES Y HOT DOGS (has_prep = true)
  -- ==========================================================================
  insert into public.menu_items (business_id, category_id, sku, name, price, cost, tax_mode, is_active, is_beverage, has_prep)
  select v_bid, v_sandwiches, p.sku, p.name, p.price::numeric(12,2), p.cost::numeric(12,2), 'exclusive', true, false, true
  from (values
    ('1000119', 'CLUB SANDWICH',              450, 0),
    ('1000127', 'HOT DOG DE PIERNA',          160, 0),
    ('1040',    'HOT DOG DE POLLO',           120, 30),
    ('1041',    'HOT DOG DE RES',             100, 30),
    ('1042',    'HOT DOG GULLIVEN',           160, 40),
    ('1109',    'SALCHICHA DE HOT DOG',        25, 25),
    ('1072',    'SANDWICH BACON Y QUESO',     350, 75),
    ('1073',    'SANDWICH CUBANO',            400, 60),
    ('1070',    'SANDWICH DE PIERNA',         300, 60),
    ('1071',    'SANDWICH DE PIERNA Y QUESO', 340, 75),
    ('1068',    'SANDWICH DE POLLO',          300, 60),
    ('1069',    'SANDWICH DE POLLO Y QUESO',  340, 75),
    ('1107',    'SANDWICH GULLIVEN',          500, 0),
    ('1105',    'SANDWICH JAMON Y QUESO',     130, 100)
  ) as p(sku, name, price, cost)
  where not exists (select 1 from public.menu_items mi where mi.business_id = v_bid and mi.sku = p.sku);

  -- ==========================================================================
  -- WRAPS Y BURRITOS (has_prep = true)
  -- ==========================================================================
  insert into public.menu_items (business_id, category_id, sku, name, price, cost, tax_mode, is_active, is_beverage, has_prep)
  select v_bid, v_wraps, p.sku, p.name, p.price::numeric(12,2), p.cost::numeric(12,2), 'exclusive', true, false, true
  from (values
    ('1158',    'BURRITO DE PIERNA',     320, 0),
    ('1058',    'BURRITO DE POLLO',      300, 60),
    ('1059',    'BURRITO DE RES',        300, 60),
    ('1061',    'BURRITO DE VEGETALES',  200, 60),
    ('1108',    'BURRITO GULLIVEN',      350, 250),
    ('1060',    'BURRITO MIXTO',         320, 75),
    ('1000022', 'WRAP DE PIERNA',        250, 0),
    ('1093',    'WRAP DE POLLO',         300, 220),
    ('1094',    'WRAP DE RES',           300, 220),
    ('1096',    'WRAP DE VEGETALES',     250, 200),
    ('1095',    'WRAP MIXTO',            350, 250)
  ) as p(sku, name, price, cost)
  where not exists (select 1 from public.menu_items mi where mi.business_id = v_bid and mi.sku = p.sku);

  -- ==========================================================================
  -- TACOS Y QUESADILLAS (has_prep = true)
  -- ==========================================================================
  insert into public.menu_items (business_id, category_id, sku, name, price, cost, tax_mode, is_active, is_beverage, has_prep)
  select v_bid, v_tacos, p.sku, p.name, p.price::numeric(12,2), p.cost::numeric(12,2), 'exclusive', true, false, true
  from (values
    ('1000023', 'QUESADILLA DE PIERNA',    240, 0),
    ('1083',    'QUESADILLA DE POLLO GDE', 240, 130),
    ('1062',    'QUESADILLA DE POLLO PEQ', 150, 50),
    ('1086',    'QUESADILLA DE QUESO GDE', 230, 130),
    ('1065',    'QUESADILLA DE QUESO PEQ', 130, 45),
    ('1084',    'QUESADILLA DE RES GDE',   260, 130),
    ('1063',    'QUESADILLA DE RES PEQ',   150, 50),
    ('1085',    'QUESADILLA MIXTA GDE',    280, 130),
    ('1000040', 'QUESADILLA MIXTA PEQ',    150, 0),
    ('1106',    'TACO DE POLLO',           150, 70),
    ('1160',    'TACO MIXTO',              140, 0),
    ('1000062', 'TACO TORTILLA DOBLE',     180, 0),
    ('1000013', 'TACOS DE CHICHARRON',     180, 0),
    ('1051',    'TACOS DE PIERNA',         150, 50),
    ('1049',    'TACOS DE POLLO',          110, 40),
    ('1050',    'TACOS DE RES',            150, 50),
    ('1053',    'TACOS DE VEGETALES',      140, 45),
    ('1052',    'TACOS GULLIVEN',          170, 45)
  ) as p(sku, name, price, cost)
  where not exists (select 1 from public.menu_items mi where mi.business_id = v_bid and mi.sku = p.sku);

  -- ==========================================================================
  -- NACHOS, FLAUTAS Y RIKIS (has_prep = true)
  -- ==========================================================================
  insert into public.menu_items (business_id, category_id, sku, name, price, cost, tax_mode, is_active, is_beverage, has_prep)
  select v_bid, v_nachos, p.sku, p.name, p.price::numeric(12,2), p.cost::numeric(12,2), 'exclusive', true, false, true
  from (values
    ('1000034', 'FLAUTAS',              300, 0),
    ('1000012', 'FLAUTAS DE POLLO',     160, 0),
    ('1000028', 'NACHO DE QUESO',       130, 0),
    ('1087',    'NACHOS DE POLLO GDE',  450, 130),
    ('1043',    'NACHOS DE POLLO PEQ',  350, 50),
    ('1088',    'NACHOS DE RES GDE',    450, 130),
    ('1044',    'NACHOS DE RES PEQ',    350, 50),
    ('1089',    'NACHOS MIXTO GDE',     450, 130),
    ('1045',    'NACHOS MIXTO PEQ',     350, 50),
    ('1000045', 'RIKI GULLIVEN',        180, 0),
    ('1056',    'RIKIS DE PIERNA',      150, 45),
    ('1054',    'RIKIS DE POLLO',       150, 40),
    ('1055',    'RIKIS DE RES',         150, 40),
    ('1057',    'RIKIS MIXTO',          170, 50),
    ('1000115', 'YAROA MIXTA',          400, 0)
  ) as p(sku, name, price, cost)
  where not exists (select 1 from public.menu_items mi where mi.business_id = v_bid and mi.sku = p.sku);

  -- ==========================================================================
  -- POSTRES
  -- ==========================================================================
  insert into public.menu_items (business_id, category_id, sku, name, price, cost, tax_mode, is_active, is_beverage)
  select v_bid, v_postres, p.sku, p.name, p.price::numeric(12,2), p.cost::numeric(12,2), 'exclusive', true, false
  from (values
    ('1000016', 'BIZCOCHO',                 900, 0),
    ('1025',    'BROWNIE A LA MODA',        200, 50),
    ('1000046', 'CAJA PROMOCION MADRES',   4950, 0),
    ('1000125', 'CARLOTA DE LIMON',         250, 0),
    ('1026',    'COCO HORNEADO',            200, 50),
    ('1125',    'DEDITOS DE NOVIA',          50, 0),
    ('1000019', 'MAJARETE',                  80, 0),
    ('1000107', 'MARQUESA DE LIMON',        200, 0)
  ) as p(sku, name, price, cost)
  where not exists (select 1 from public.menu_items mi where mi.business_id = v_bid and mi.sku = p.sku);

  -- ==========================================================================
  -- EXTRAS Y SERVICIOS (sin impuestos por defecto — owner decide caso por caso)
  -- ==========================================================================
  insert into public.menu_items (business_id, category_id, sku, name, price, cost, tax_mode, is_active, is_beverage)
  select v_bid, v_extras, p.sku, p.name, p.price::numeric(12,2), p.cost::numeric(12,2), 'exclusive', true, false
  from (values
    ('1199',    'ALQUILERES',               20, 0),
    ('1121',    'CAMARERO',               1600, 0),
    ('1161',    'CARBON',                  100, 0),
    ('1000049', 'DECORACION Y ALQUILERES',19000, 0),
    ('1134',    'DELIVERY',                150, 0),
    ('1144',    'DESCORCHE',               200, 0),
    ('1000106', 'EXTRA',                   100, 0),
    ('1186',    'FUNDA DE HIELO',           80, 0),
    ('1000065', 'GULLI',                  0.01, 0),
    ('1179',    'ICE',                     100, 0),
    ('1167',    'MARLBORO',                300, 0),
    ('1099',    'OTROS',                     0, 0),
    ('1188',    'PALILLOS',                 60, 0),
    ('1000094', 'VASO DE FOAM',             20, 0)
  ) as p(sku, name, price, cost)
  where not exists (select 1 from public.menu_items mi where mi.business_id = v_bid and mi.sku = p.sku);

end$$;

-- ----------------------------------------------------------------------------
-- 4) Vincular ITBIS 18% y Propina Ley 10% a todos los productos
--    EXCEPTO los de EXTRAS Y SERVICIOS.
--    Idempotente: solo inserta el par (item_id, tax_id) si no existe.
-- ----------------------------------------------------------------------------

do $$
declare
  v_bid uuid := '1bba15bf-f7be-4fcf-9a4d-af61ca114cf1'::uuid;
  v_itbis uuid;
  v_ley   uuid;
  v_extras uuid;
begin
  select id into v_itbis
    from public.taxes
    where business_id = v_bid and rate = 18 and coalesce(is_service_fee, false) = false
    order by created_at asc nulls last
    limit 1;

  select id into v_ley
    from public.taxes
    where business_id = v_bid and rate = 10 and coalesce(is_service_fee, false) = true
    order by created_at asc nulls last
    limit 1;

  select id into v_extras
    from public.categories
    where business_id = v_bid and name = 'EXTRAS Y SERVICIOS'
    limit 1;

  -- ITBIS 18%
  if v_itbis is not null then
    insert into public.menu_item_taxes (item_id, tax_id)
    select mi.id, v_itbis
    from public.menu_items mi
    where mi.business_id = v_bid
      and (v_extras is null or mi.category_id is distinct from v_extras)
      and not exists (
        select 1 from public.menu_item_taxes mit
        where mit.item_id = mi.id and mit.tax_id = v_itbis
      );
  end if;

  -- Propina Ley 10%
  if v_ley is not null then
    insert into public.menu_item_taxes (item_id, tax_id)
    select mi.id, v_ley
    from public.menu_items mi
    where mi.business_id = v_bid
      and (v_extras is null or mi.category_id is distinct from v_extras)
      and not exists (
        select 1 from public.menu_item_taxes mit
        where mit.item_id = mi.id and mit.tax_id = v_ley
      );
  end if;
end$$;

commit;

-- ============================================================================
-- Verificación (opcional — descomentar para revisar después del seed)
-- ============================================================================
-- select c.name as categoria, count(mi.id) as items, sum(mi.price) as suma_precios
-- from public.categories c
-- left join public.menu_items mi
--   on mi.business_id = c.business_id and mi.category_id = c.id
-- where c.business_id = '1bba15bf-f7be-4fcf-9a4d-af61ca114cf1'
-- group by c.name, c.position
-- order by c.position;
--
-- -- Productos sin impuestos (deberían ser solo los de EXTRAS Y SERVICIOS):
-- select c.name as categoria, mi.name, mi.sku
-- from public.menu_items mi
-- left join public.categories c on c.id = mi.category_id
-- where mi.business_id = '1bba15bf-f7be-4fcf-9a4d-af61ca114cf1'
--   and not exists (select 1 from public.menu_item_taxes mit where mit.item_id = mi.id)
-- order by c.position, mi.name;
--
-- -- Productos con price = 0 (el dueño debe actualizarlos antes de venderlos):
-- select c.name as categoria, mi.name, mi.sku
-- from public.menu_items mi
-- left join public.categories c on c.id = mi.category_id
-- where mi.business_id = '1bba15bf-f7be-4fcf-9a4d-af61ca114cf1'
--   and mi.price = 0
-- order by c.position, mi.name;
