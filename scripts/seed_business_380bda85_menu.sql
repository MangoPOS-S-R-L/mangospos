-- ============================================================================
-- Seed de productos: UNOSIETEOCHO 178 BY LUICHYCHECO SRL
-- Business: 380bda85-023d-41ed-9a85-0b3efc341304
-- Fuente: Catalogo_productos_no_transformados.pdf (export catálogo MangoPOS)
--   - 69  productos NO transformados (bebidas embotelladas, vinos, cervezas)
--   - 250 productos TRANSFORMADOS (cócteles, tragos, cafés, comidas)
--   -  1  combo (Combo evento IERL)
--   - 32  categorías
--
-- Convenciones del catálogo origen:
--   - Cada producto trae un "Identificador Unico" → lo guardamos en sku.
--   - "Transformado = Si"  → menu_items.has_prep = true (cócteles, tragos).
--   - "Transformado = No"  → menu_items.has_prep = false (bebidas embotelladas).
--   - Todos los precios en RD$, tal cual aparecen en el PDF (sin ITBIS).
--   - tax_mode queda por DEFAULT ('exclusive') porque el bar normalmente
--     agrega ITBIS sobre precio.
--
-- Idempotente:
--   - Categorías: se crean sólo si no existen para este business.
--   - Productos: se insertan sólo si no hay menu_item con el mismo sku
--     dentro de este business. Re-ejecutar el script no duplica nada.
--
-- Nota sobre nombres duplicados:
--   - MOJITO aparece 4 veces (sku 40, 101, 102, 103) — variantes del catálogo.
--   - MARGARITA JARANA aparece 4 veces (sku 39, 99, 100, 272).
--   - SANGRIA TINTA aparece 3 veces (sku 41, 104, 293).
--   - T. BOMBAY y T. HENDRIK'S aparecen 2 veces cada uno.
--   La dedup va por sku, no por nombre, así que se preservan todos.
-- ============================================================================

begin;

-- ----------------------------------------------------------------------------
-- 1) Categorías (32)
-- ----------------------------------------------------------------------------

insert into public.categories (id, business_id, name, position, is_active)
select gen_random_uuid(),
       '380bda85-023d-41ed-9a85-0b3efc341304'::uuid,
       c.name,
       c.position,
       true
from (values
  ('JUGOS',                          1),
  ('AGUA',                           2),
  ('SMOOTHIES',                      3),
  ('COCTELES',                       4),
  ('RON',                            5),
  ('VODKA',                          6),
  ('VINOS',                          7),
  ('VINOS BLANCOS',                  8),
  ('VINOS Y ESPUMANTES POR COPA',    9),
  ('ESPUMANTE',                     10),
  ('APERITIVOS Y DIGESTIVOS',       11),
  ('ADICIONALES',                   12),
  ('CIGARROS',                      13),
  ('CERVEZAS',                      14),
  ('GINEBRA',                       15),
  ('TEQUILA',                       16),
  ('COMIDAS',                       17),
  ('T. WHISKY',                     18),
  ('WHISKY',                        19),
  ('CAFES, INFUSIONES Y FRAPPE',    20),
  ('T. RON',                        21),
  ('T. GINEBRA',                    22),
  ('T. TEQUILA',                    23),
  ('T. MEZCAL',                     24),
  ('T. VODKA',                      25),
  ('COCTELES CON TEQUILA',          26),
  ('COCTELES CON RON',              27),
  ('COCTELES CON GINEBRA',          28),
  ('COCTELES CON WHISKY',           29),
  ('COCTELES CON VODKA',            30),
  ('DISCOVERY COCKTAILS',           31),
  ('COMBOS',                        32)
) as c(name, position)
where not exists (
  select 1
  from public.categories cat
  where cat.business_id = '380bda85-023d-41ed-9a85-0b3efc341304'::uuid
    and cat.name = c.name
);

-- ----------------------------------------------------------------------------
-- 2) Productos
--    Estructura del bloque:
--      - Se resuelven los UUIDs de cada categoría a variables locales.
--      - Se hace un INSERT por categoría, con dedup por (business_id, sku).
--      - Las VALUES llevan: (sku, name, price, has_prep, cost)
--        is_beverage se decide por categoría (true para líquidos / coctelería).
-- ----------------------------------------------------------------------------

do $$
declare
  v_bid uuid := '380bda85-023d-41ed-9a85-0b3efc341304'::uuid;

  v_jugos        uuid;
  v_agua         uuid;
  v_smoothies    uuid;
  v_cocteles     uuid;
  v_ron          uuid;
  v_vodka        uuid;
  v_vinos        uuid;
  v_vinos_b      uuid;
  v_vinos_copa   uuid;
  v_espumante    uuid;
  v_aperitivos   uuid;
  v_adicionales  uuid;
  v_cigarros     uuid;
  v_cervezas     uuid;
  v_ginebra      uuid;
  v_tequila      uuid;
  v_comidas      uuid;
  v_t_whisky     uuid;
  v_whisky       uuid;
  v_cafes        uuid;
  v_t_ron        uuid;
  v_t_ginebra    uuid;
  v_t_tequila    uuid;
  v_t_mezcal     uuid;
  v_t_vodka      uuid;
  v_c_tequila    uuid;
  v_c_ron        uuid;
  v_c_ginebra    uuid;
  v_c_whisky     uuid;
  v_c_vodka      uuid;
  v_discovery    uuid;
  v_combos       uuid;
begin
  select id into v_jugos       from public.categories where business_id = v_bid and name = 'JUGOS' limit 1;
  select id into v_agua        from public.categories where business_id = v_bid and name = 'AGUA' limit 1;
  select id into v_smoothies   from public.categories where business_id = v_bid and name = 'SMOOTHIES' limit 1;
  select id into v_cocteles    from public.categories where business_id = v_bid and name = 'COCTELES' limit 1;
  select id into v_ron         from public.categories where business_id = v_bid and name = 'RON' limit 1;
  select id into v_vodka       from public.categories where business_id = v_bid and name = 'VODKA' limit 1;
  select id into v_vinos       from public.categories where business_id = v_bid and name = 'VINOS' limit 1;
  select id into v_vinos_b     from public.categories where business_id = v_bid and name = 'VINOS BLANCOS' limit 1;
  select id into v_vinos_copa  from public.categories where business_id = v_bid and name = 'VINOS Y ESPUMANTES POR COPA' limit 1;
  select id into v_espumante   from public.categories where business_id = v_bid and name = 'ESPUMANTE' limit 1;
  select id into v_aperitivos  from public.categories where business_id = v_bid and name = 'APERITIVOS Y DIGESTIVOS' limit 1;
  select id into v_adicionales from public.categories where business_id = v_bid and name = 'ADICIONALES' limit 1;
  select id into v_cigarros    from public.categories where business_id = v_bid and name = 'CIGARROS' limit 1;
  select id into v_cervezas    from public.categories where business_id = v_bid and name = 'CERVEZAS' limit 1;
  select id into v_ginebra     from public.categories where business_id = v_bid and name = 'GINEBRA' limit 1;
  select id into v_tequila     from public.categories where business_id = v_bid and name = 'TEQUILA' limit 1;
  select id into v_comidas     from public.categories where business_id = v_bid and name = 'COMIDAS' limit 1;
  select id into v_t_whisky    from public.categories where business_id = v_bid and name = 'T. WHISKY' limit 1;
  select id into v_whisky      from public.categories where business_id = v_bid and name = 'WHISKY' limit 1;
  select id into v_cafes       from public.categories where business_id = v_bid and name = 'CAFES, INFUSIONES Y FRAPPE' limit 1;
  select id into v_t_ron       from public.categories where business_id = v_bid and name = 'T. RON' limit 1;
  select id into v_t_ginebra   from public.categories where business_id = v_bid and name = 'T. GINEBRA' limit 1;
  select id into v_t_tequila   from public.categories where business_id = v_bid and name = 'T. TEQUILA' limit 1;
  select id into v_t_mezcal    from public.categories where business_id = v_bid and name = 'T. MEZCAL' limit 1;
  select id into v_t_vodka     from public.categories where business_id = v_bid and name = 'T. VODKA' limit 1;
  select id into v_c_tequila   from public.categories where business_id = v_bid and name = 'COCTELES CON TEQUILA' limit 1;
  select id into v_c_ron       from public.categories where business_id = v_bid and name = 'COCTELES CON RON' limit 1;
  select id into v_c_ginebra   from public.categories where business_id = v_bid and name = 'COCTELES CON GINEBRA' limit 1;
  select id into v_c_whisky    from public.categories where business_id = v_bid and name = 'COCTELES CON WHISKY' limit 1;
  select id into v_c_vodka     from public.categories where business_id = v_bid and name = 'COCTELES CON VODKA' limit 1;
  select id into v_discovery   from public.categories where business_id = v_bid and name = 'DISCOVERY COCKTAILS' limit 1;
  select id into v_combos      from public.categories where business_id = v_bid and name = 'COMBOS' limit 1;

  -- =========================================================================
  -- NO TRANSFORMADOS (has_prep = false)
  -- =========================================================================

  -- JUGOS (no transformados: solo 1)
  insert into public.menu_items (business_id, category_id, sku, name, price, cost, has_prep, is_beverage, is_active)
  select v_bid, v_jugos, p.sku, p.name, p.price::numeric(12,2), p.cost::numeric, false, true, true
  from (values
    ('386','JUGO DE NARANJA',172.00,0)
  ) as p(sku, name, price, cost)
  where not exists (select 1 from public.menu_items mi where mi.business_id = v_bid and mi.sku = p.sku);

  -- AGUA
  insert into public.menu_items (business_id, category_id, sku, name, price, cost, has_prep, is_beverage, is_active)
  select v_bid, v_agua, p.sku, p.name, p.price::numeric(12,2), p.cost::numeric, false, true, true
  from (values
    ('25', 'Agua Dasani',              62.50, 0),
    ('23', 'Perrier Peq.',            169.49, 0),
    ('288','San Pelegrino Melograno', 156.25, 0),
    ('253','San Pelegrino Vidrio 50ml',343.75,0),
    ('22', 'San Pellegrino peq.',     169.49, 0)
  ) as p(sku, name, price, cost)
  where not exists (select 1 from public.menu_items mi where mi.business_id = v_bid and mi.sku = p.sku);

  -- SMOOTHIES (no transformado: solo 1)
  insert into public.menu_items (business_id, category_id, sku, name, price, cost, has_prep, is_beverage, is_active)
  select v_bid, v_smoothies, p.sku, p.name, p.price::numeric(12,2), p.cost::numeric, false, true, true
  from (values
    ('330','SMOOTHIE DE CHINOLA', 140.63, 0)
  ) as p(sku, name, price, cost)
  where not exists (select 1 from public.menu_items mi where mi.business_id = v_bid and mi.sku = p.sku);

  -- COCTELES (no transformado: solo 1)
  insert into public.menu_items (business_id, category_id, sku, name, price, cost, has_prep, is_beverage, is_active)
  select v_bid, v_cocteles, p.sku, p.name, p.price::numeric(12,2), p.cost::numeric, false, true, true
  from (values
    ('329','CUBA LIBRE', 309.00, 0)
  ) as p(sku, name, price, cost)
  where not exists (select 1 from public.menu_items mi where mi.business_id = v_bid and mi.sku = p.sku);

  -- RON (botellas)
  insert into public.menu_items (business_id, category_id, sku, name, price, cost, has_prep, is_beverage, is_active)
  select v_bid, v_ron, p.sku, p.name, p.price::numeric(12,2), p.cost::numeric, false, true, true
  from (values
    ('292','ABUELO 7 ANOS',                    2343.75, 0),
    ('70', 'BARCELO AÑEJO',                    1186.44, 0),
    ('69', 'BARCELO GRAN AÑEJO',               1228.81, 0),
    ('66', 'BRUGAL 1888',                      3347.46, 0),
    ('285','BRUGAL DOBLE RESERVA 1/2 LITRO',    781.25, 0),
    ('64', 'BRUGAL DOBLE RESERVAS',            1609.37, 0),
    ('63', 'BRUGAL EXTRA VIEJO',               1250.00, 0),
    ('65', 'BRUGAL LEYENDA',                   2343.75, 0),
    ('229','BRUGAL TRIPLE RESERVA',            1562.50, 0),
    ('302','E. LEON JIMENEZ 110 ANIVERSARIO', 12800.00, 0),
    ('250','E. LEON JIMENEZ 1903',             3085.93, 0),
    ('68', 'RON VIEJO BERMUDEZ',               1186.44, 0),
    ('248','SIBONEY BLANCO',                   1171.87, 0)
  ) as p(sku, name, price, cost)
  where not exists (select 1 from public.menu_items mi where mi.business_id = v_bid and mi.sku = p.sku);

  -- VODKA (botellas)
  insert into public.menu_items (business_id, category_id, sku, name, price, cost, has_prep, is_beverage, is_active)
  select v_bid, v_vodka, p.sku, p.name, p.price::numeric(12,2), p.cost::numeric, false, true, true
  from (values
    ('71','B. STOLICHNAYA', 2109.37, 0),
    ('72','B. TITOS´S',     2694.92, 0)
  ) as p(sku, name, price, cost)
  where not exists (select 1 from public.menu_items mi where mi.business_id = v_bid and mi.sku = p.sku);

  -- VINOS (tintos)
  insert into public.menu_items (business_id, category_id, sku, name, price, cost, has_prep, is_beverage, is_active)
  select v_bid, v_vinos, p.sku, p.name, p.price::numeric(12,2), p.cost::numeric, false, true, true
  from (values
    ('139','19 CRIMENES',              1992.18, 0),
    ('257','APOTHIC RED',              2156.25, 0),
    ('306','BOGLE ESSENTIAL RED',         0.00, 0),
    ('326','CAYMUS',                   7827.00, 0),
    ('318','GLORIOZO CRIANZA',         1875.00, 0),
    ('319','MARQUES DE RISAL RESERVA', 3351.56, 0),
    ('216','MENAGE A TROIS',           1640.62, 0),
    ('320','PROTOS CRIANZA',           3652.34, 0),
    ('297','PROTOS ROBLE',             1821.87, 10),
    ('321','PROTOS ROBLES',            2105.47, 0),
    ('299','SCARLETT DARK',            1641.00, 0),
    ('158','SILK AND SPICE',           1804.68, 0)
  ) as p(sku, name, price, cost)
  where not exists (select 1 from public.menu_items mi where mi.business_id = v_bid and mi.sku = p.sku);

  -- VINOS BLANCOS
  insert into public.menu_items (business_id, category_id, sku, name, price, cost, has_prep, is_beverage, is_active)
  select v_bid, v_vinos_b, p.sku, p.name, p.price::numeric(12,2), p.cost::numeric, false, true, true
  from (values
    ('157','BERINGER PINOT GRIGIO', 1203.12, 0),
    ('156','CAVIT PINOT GRIGIO',    2247.45, 0),
    ('256','GOTAS DE MAR',          1914.06, 0),
    ('268','MATUA',                 2109.37, 0),
    ('155','PROTOS VERDEJO',        1821.87, 0)
  ) as p(sku, name, price, cost)
  where not exists (select 1 from public.menu_items mi where mi.business_id = v_bid and mi.sku = p.sku);

  -- ESPUMANTE (no transformados)
  insert into public.menu_items (business_id, category_id, sku, name, price, cost, has_prep, is_beverage, is_active)
  select v_bid, v_espumante, p.sku, p.name, p.price::numeric(12,2), p.cost::numeric, false, true, true
  from (values
    ('300','San Remis',           0.00, 0),
    ('226','SEGURA VIUDA BRUT', 1550.00, 0)
  ) as p(sku, name, price, cost)
  where not exists (select 1 from public.menu_items mi where mi.business_id = v_bid and mi.sku = p.sku);

  -- APERITIVOS Y DIGESTIVOS (no transformado: Limoncello)
  insert into public.menu_items (business_id, category_id, sku, name, price, cost, has_prep, is_beverage, is_active)
  select v_bid, v_aperitivos, p.sku, p.name, p.price::numeric(12,2), p.cost::numeric, false, true, true
  from (values
    ('328','Trago De Limoncello Cellini', 274.63, 0)
  ) as p(sku, name, price, cost)
  where not exists (select 1 from public.menu_items mi where mi.business_id = v_bid and mi.sku = p.sku);

  -- ADICIONALES no transformados (cigarrillos sueltos / redbull / servicio)
  insert into public.menu_items (business_id, category_id, sku, name, price, cost, has_prep, is_beverage, is_active)
  select v_bid, v_adicionales, p.sku, p.name, p.price::numeric(12,2), p.cost::numeric, false, false, true
  from (values
    ('225','MARLBORO ROJO',           207.03, 0),
    ('224','REDBULL',                 195.31, 0),
    ('309','SERVICIO DE PERSONAL',   2343.75, 0)
  ) as p(sku, name, price, cost)
  where not exists (select 1 from public.menu_items mi where mi.business_id = v_bid and mi.sku = p.sku);

  -- CIGARROS (no transformados)
  insert into public.menu_items (business_id, category_id, sku, name, price, cost, has_prep, is_beverage, is_active)
  select v_bid, v_cigarros, p.sku, p.name, p.price::numeric(12,2), p.cost::numeric, false, false, true
  from (values
    ('211','AURORA 100 AÑOS ROBUSTO / 25',           937.50, 0),
    ('210','AURORA MAD. 107 AÑOS ROBUSTO / 21',      414.06, 0),
    ('209','Don Fernando corona Founder Choice',     550.00, 0),
    ('178','LA AUR. FAM/CREED FUERTE SOL TORO /20', 1050.00, 0),
    ('179','LA AURORA 115 ANIVERSARIO TORO /20',     600.00, 0)
  ) as p(sku, name, price, cost)
  where not exists (select 1 from public.menu_items mi where mi.business_id = v_bid and mi.sku = p.sku);

  -- CERVEZAS (no transformadas — botellas)
  insert into public.menu_items (business_id, category_id, sku, name, price, cost, has_prep, is_beverage, is_active)
  select v_bid, v_cervezas, p.sku, p.name, p.price::numeric(12,2), p.cost::numeric, false, true, true
  from (values
    ('59', 'BLUE MOON',         234.37, 0),
    ('310','CERVEZA 5.0',       195.31, 0),
    ('290','COORS LIGHT',       175.78, 0),
    ('252','COORS ORIGINAL',    203.12, 0),
    ('54', 'CORONA',            214.84, 0),
    ('57', 'HEINEKEN',          203.12, 0),
    ('230','MICHELOB',          214.84, 0),
    ('58', 'MILLER',            203.12, 0),
    ('56', 'MODELO NEGRA',      203.12, 0),
    ('55', 'MODELO RUBIA',      203.12, 0),
    ('61', 'PAULANER NEGRA',    390.62, 0),
    ('60', 'PAULANER RUBIA',    390.62, 0),
    ('286','PRESIDENTE BLACK',  188.00, 0),
    ('98', 'PRESIDENTE DURA',   187.50, 0),
    ('52', 'PRESIDENTE LIGHT',  188.00, 0),
    ('134','SMIRNOFF',          234.37, 0),
    ('53', 'STELLA ARTOIS',     234.37, 0),
    ('327','THE ONE',           160.15, 0)
  ) as p(sku, name, price, cost)
  where not exists (select 1 from public.menu_items mi where mi.business_id = v_bid and mi.sku = p.sku);

  -- =========================================================================
  -- TRANSFORMADOS (has_prep = true)
  -- =========================================================================

  -- JUGOS (transformados)
  insert into public.menu_items (business_id, category_id, sku, name, price, cost, has_prep, is_beverage, is_active)
  select v_bid, v_jugos, p.sku, p.name, p.price::numeric(12,2), p.cost::numeric, true, true, true
  from (values
    ('260','CRAMBERRY',        195.31, 0),
    ('20', 'JUGO DE CEREZA',   160.00, 0),
    ('21', 'JUGO DE CHINOLA',  160.00, 0),
    ('233','JUGO DE FRESA',    175.78, 0),
    ('426','JUGO DE LIMON',    132.81, 0),
    ('234','JUGO MOTS',        175.78, 0)
  ) as p(sku, name, price, cost)
  where not exists (select 1 from public.menu_items mi where mi.business_id = v_bid and mi.sku = p.sku);

  -- SMOOTHIES (transformados)
  insert into public.menu_items (business_id, category_id, sku, name, price, cost, has_prep, is_beverage, is_active)
  select v_bid, v_smoothies, p.sku, p.name, p.price::numeric(12,2), p.cost::numeric, true, true, true
  from (values
    ('29', 'SMOOTHIE DE BANANA',   140.63, 0),
    ('273','SMOOTHIE DE COCO',     140.63, 0),
    ('27', 'SMOOTHIE DE FRESA',    150.00, 0),
    ('26', 'SMOOTHIE DE LECHOSA',  150.00, 0),
    ('30', 'SMOOTHIE DE LIMON',    140.63, 0),
    ('28', 'SMOOTHIE DE MELON',    140.62, 0)
  ) as p(sku, name, price, cost)
  where not exists (select 1 from public.menu_items mi where mi.business_id = v_bid and mi.sku = p.sku);

  -- COCTELES (transformados)
  insert into public.menu_items (business_id, category_id, sku, name, price, cost, has_prep, is_beverage, is_active)
  select v_bid, v_cocteles, p.sku, p.name, p.price::numeric(12,2), p.cost::numeric, true, true, true
  from (values
    ('43', 'APEROL SPRITZ',       332.03, 0),
    ('50', 'CAIPIRINHA',          324.21, 0),
    ('222','Long Island Ice Tea', 367.18, 0),
    ('281','MALIBU',              312.00, 0),
    ('437','MICHELADA',           468.75, 0),
    ('438','MICHELADA CORONA',    351.56, 0),
    ('40', 'MOJITO',              312.50, 0),
    ('101','MOJITO',              312.50, 0),
    ('102','MOJITO',              312.50, 0),
    ('103','MOJITO',              312.50, 0),
    ('280','ORGASMO',             312.50, 0),
    ('41', 'SANGRIA TINTA',       308.59, 0),
    ('104','SANGRIA TINTA',       308.59, 0),
    ('293','SANGRIA TINTA',       308.59, 0),
    ('294','T. SANTO LIBRE',      308.59, 0)
  ) as p(sku, name, price, cost)
  where not exists (select 1 from public.menu_items mi where mi.business_id = v_bid and mi.sku = p.sku);

  -- RON (transformados — tragos / boletas individuales)
  insert into public.menu_items (business_id, category_id, sku, name, price, cost, has_prep, is_beverage, is_active)
  select v_bid, v_ron, p.sku, p.name, p.price::numeric(12,2), p.cost::numeric, true, true, true
  from (values
    ('312','BARCELO GRAN ANEJO',   1015.62, 0),
    ('313','DON ARMANDO RESERVA',  1562.50, 0),
    ('433','DON ISIDRO',           2536.06, 0)
  ) as p(sku, name, price, cost)
  where not exists (select 1 from public.menu_items mi where mi.business_id = v_bid and mi.sku = p.sku);

  -- VODKA (transformados)
  insert into public.menu_items (business_id, category_id, sku, name, price, cost, has_prep, is_beverage, is_active)
  select v_bid, v_vodka, p.sku, p.name, p.price::numeric(12,2), p.cost::numeric, true, true, true
  from (values
    ('247','B. BELUGA NOBLE', 5390.62, 0),
    ('242','B. DEEP EDDY',    2210.93, 0),
    ('241','B. POLIAKOV',     1484.37, 0)
  ) as p(sku, name, price, cost)
  where not exists (select 1 from public.menu_items mi where mi.business_id = v_bid and mi.sku = p.sku);

  -- GINEBRA
  insert into public.menu_items (business_id, category_id, sku, name, price, cost, has_prep, is_beverage, is_active)
  select v_bid, v_ginebra, p.sku, p.name, p.price::numeric(12,2), p.cost::numeric, true, true, true
  from (values
    ('74', 'BEEFEATER',                2627.12, 0),
    ('75', 'BEEFEATER ORANGE',         2542.37, 0),
    ('311','BEEFEATER PINK',           2500.00, 0),
    ('301','BERMUDEZ GIN',             1328.00, 0),
    ('197','BOMBAY',                   3125.00, 0),
    ('237','BROCKMAN',                 4218.75, 0),
    ('79', 'BULLDOGS',                 3813.56, 0),
    ('235','GIBSON',                   1757.81, 0),
    ('76', 'HENDRICKS',                4687.50, 0),
    ('77', 'TANQUERAY',                2966.10, 0),
    ('78', 'TANQUERAY FLOR DE CEBILLA',3220.34, 0)
  ) as p(sku, name, price, cost)
  where not exists (select 1 from public.menu_items mi where mi.business_id = v_bid and mi.sku = p.sku);

  -- TEQUILA
  insert into public.menu_items (business_id, category_id, sku, name, price, cost, has_prep, is_beverage, is_active)
  select v_bid, v_tequila, p.sku, p.name, p.price::numeric(12,2), p.cost::numeric, true, true, true
  from (values
    ('278','400 CONEJO',         4375.00, 0),
    ('240','ALTO SILVER',        4804.69, 0),
    ('369','ALTOS RTEPOSADO',    3515.62, 0),
    ('314','DON JULIO 1942',    23437.50, 0),
    ('82', 'DON JULIO REPOSADO', 7100.00, 0),
    ('83', 'JARANA',             2500.00, 0),
    ('81', 'PATRON REPOSADO',    5000.00, 0),
    ('80', 'PATRON SILVER',      4830.51, 0),
    ('239','TISCAZ SILVER',      2148.43, 0),
    ('368','TIZCAS REPOSADO',    4360.00, 0)
  ) as p(sku, name, price, cost)
  where not exists (select 1 from public.menu_items mi where mi.business_id = v_bid and mi.sku = p.sku);

  -- COMIDAS
  insert into public.menu_items (business_id, category_id, sku, name, price, cost, has_prep, is_beverage, is_active)
  select v_bid, v_comidas, p.sku, p.name, p.price::numeric(12,2), p.cost::numeric, true, false, true
  from (values
    ('105','PALITOS DE MOZARELLA', 312.50, 0)
  ) as p(sku, name, price, cost)
  where not exists (select 1 from public.menu_items mi where mi.business_id = v_bid and mi.sku = p.sku);

  -- T. WHISKY (tragos de whisky)
  insert into public.menu_items (business_id, category_id, sku, name, price, cost, has_prep, is_beverage, is_active)
  select v_bid, v_t_whisky, p.sku, p.name, p.price::numeric(12,2), p.cost::numeric, true, true, true
  from (values
    ('439','T. BLACK LABEL',                       468.75, 0),
    ('130','T. BUCHANNA´S 12 AÑOS',                469.00, 0),
    ('126','T. CHIVAS 12 AÑOS',                    500.00, 0),
    ('127','T. CHIVAS 18 AÑOS',                    726.56, 0),
    ('128','T. DEWAR´S 12 AÑOS',                   390.62, 0),
    ('218','T. DEWAR´S WHITE LABEL',               312.50, 0),
    ('355','T. DOBLE BLACK',                       484.38, 0),
    ('332','T. GLENLIVET 12 AÑOS',                 781.00, 0),
    ('129','T. GOLD LABEL',                        734.37, 0),
    ('441','T. HENNESSY',                          468.75, 0),
    ('133','T. JACK DANIEL´S',                     429.68, 0),
    ('289','T. JACK DANIEL´S HONEY',               468.75, 0),
    ('212','T. JOHNNY NEGRO',                      468.75, 0),
    ('131','T. MACALLAN 12 AÑOS DOBLE CASK',       937.50, 0),
    ('416','T. MACALLAN 15 AÑOS SHERRY OAK CASK', 1495.60, 0),
    ('413','T. MAKER''S MARK',                     429.68, 0),
    ('132','T. THE GLENLIVET FOUNDER',             585.93, 0)
  ) as p(sku, name, price, cost)
  where not exists (select 1 from public.menu_items mi where mi.business_id = v_bid and mi.sku = p.sku);

  -- APERITIVOS Y DIGESTIVOS (transformados)
  insert into public.menu_items (business_id, category_id, sku, name, price, cost, has_prep, is_beverage, is_active)
  select v_bid, v_aperitivos, p.sku, p.name, p.price::numeric(12,2), p.cost::numeric, true, true, true
  from (values
    ('277','Sambuca Romana', 325.00, 0),
    ('227','T. AMARETTO',    312.50, 0),
    ('219','T. COINTREAU',   507.81, 0),
    ('217','T. KAHLUA',      382.81, 0),
    ('383','VERMUTH ROSSO',  296.88, 0)
  ) as p(sku, name, price, cost)
  where not exists (select 1 from public.menu_items mi where mi.business_id = v_bid and mi.sku = p.sku);

  -- ADICIONALES (transformados — mixers / siropes / extras)
  insert into public.menu_items (business_id, category_id, sku, name, price, cost, has_prep, is_beverage, is_active)
  select v_bid, v_adicionales, p.sku, p.name, p.price::numeric(12,2), p.cost::numeric, true, false, true
  from (values
    ('38', 'AGUA TONICA',              117.18, 0),
    ('31', 'CHOCOLATE CALIENTE',       110.00, 0),
    ('95', 'CHOCOLATE CALIENTE',       140.00, 0),
    ('223','CLAMATO',                  171.87, 0),
    ('35', 'COCA COLA',                 78.12, 0),
    ('440','DESCORCHE T7',             546.87, 0),
    ('296','FUNDA DE HIELO',           117.18, 0),
    ('232','SCHWEPPES',                234.37, 0),
    ('167','SIRUP DE FLOR DE JAMAICA',  89.84, 0),
    ('153','SIRUP DE FRESA',            97.65, 0),
    ('37', 'SODA AMARGA',              117.18, 0),
    ('353','SODA ARTESANAL',           156.25, 0),
    ('152','SOUR DE CHINOLA',           97.65, 0),
    ('151','SOUR DE LIMON',             89.84, 0),
    ('36', 'SPRITER',                  105.00, 0),
    ('291','Tabla de Quesos',          781.25, 0)
  ) as p(sku, name, price, cost)
  where not exists (select 1 from public.menu_items mi where mi.business_id = v_bid and mi.sku = p.sku);

  -- CIGARROS (transformados — venta unitaria)
  insert into public.menu_items (business_id, category_id, sku, name, price, cost, has_prep, is_beverage, is_active)
  select v_bid, v_cigarros, p.sku, p.name, p.price::numeric(12,2), p.cost::numeric, true, false, true
  from (values
    ('343','DON EMILIO', 400.00, 0)
  ) as p(sku, name, price, cost)
  where not exists (select 1 from public.menu_items mi where mi.business_id = v_bid and mi.sku = p.sku);

  -- VINOS Y ESPUMANTES POR COPA
  insert into public.menu_items (business_id, category_id, sku, name, price, cost, has_prep, is_beverage, is_active)
  select v_bid, v_vinos_copa, p.sku, p.name, p.price::numeric(12,2), p.cost::numeric, true, true, true
  from (values
    ('183','COPA DE BERINJER BLANCO',     304.68, 0),
    ('261','COPA DE RIGOL',               429.69, 0),
    ('324','COPA DE VINO SILK AND SPICIE',332.02, 0)
  ) as p(sku, name, price, cost)
  where not exists (select 1 from public.menu_items mi where mi.business_id = v_bid and mi.sku = p.sku);

  -- WHISKY (botellas)
  insert into public.menu_items (business_id, category_id, sku, name, price, cost, has_prep, is_beverage, is_active)
  select v_bid, v_whisky, p.sku, p.name, p.price::numeric(12,2), p.cost::numeric, true, true, true
  from (values
    ('88', 'B. BUCHANNAN´S 12',              4063.00, 0),
    ('84', 'B. CHIVAS 12 AÑOS',              3515.62, 0),
    ('85', 'B. CHIVAS 18 AÑOS',              8984.37, 0),
    ('244','B. DEACON',                      5000.00, 0),
    ('86', 'B. DEWAR´S 12 AÑOS',             2966.10, 0),
    ('245','B. EVAN WILLIAMS',               2250.00, 0),
    ('304','B. GLENLIVET 12 AÑOS',           5469.00, 0),
    ('316','B. GLENLIVET 18 AÑOS',          12890.62, 0),
    ('333','B. GLENLIVET FOUNDER´S',         5000.00, 0),
    ('315','B. GLENLIVET15 AÑOS',            8203.12, 0),
    ('295','B. JACK DANIEL''S HONEY',        3000.00, 0),
    ('243','B. JAMESON',                     3000.00, 0),
    ('317','B. JOHNNIE WALKER',              4296.87, 0),
    ('283','B. JOHNNIE WALKER BLACK',        3906.25, 0),
    ('87', 'B. JOHNNIE WALKER GOLD LABEL',   6328.12, 0),
    ('344','B. MACALLAN 15 AÑOS DOUBLE CASK',22000.00,0),
    ('89', 'B. MACALLAN SHERRY OAK 12 AÑOS', 8984.37, 0),
    ('303','B. MAKERS MARK',                 5800.00, 0),
    ('238','B.JACK DANIEL´S #7',             2812.50, 0),
    ('246','BALLANTINES 17 AÑOS',           10600.00, 0),
    ('408','MACALLA DOBLE CASK 12 AÑOS',    10500.00, 0)
  ) as p(sku, name, price, cost)
  where not exists (select 1 from public.menu_items mi where mi.business_id = v_bid and mi.sku = p.sku);

  -- ESPUMANTE (transformados — copas / botellas grandes)
  insert into public.menu_items (business_id, category_id, sku, name, price, cost, has_prep, is_beverage, is_active)
  select v_bid, v_espumante, p.sku, p.name, p.price::numeric(12,2), p.cost::numeric, true, true, true
  from (values
    ('255','MASCHIO BRUT',     1914.06, 0),
    ('254','SEGURA VIUDA ROSE',1796.87, 0)
  ) as p(sku, name, price, cost)
  where not exists (select 1 from public.menu_items mi where mi.business_id = v_bid and mi.sku = p.sku);

  -- CAFES, INFUSIONES Y FRAPPE
  insert into public.menu_items (business_id, category_id, sku, name, price, cost, has_prep, is_beverage, is_active)
  select v_bid, v_cafes, p.sku, p.name, p.price::numeric(12,2), p.cost::numeric, true, true, true
  from (values
    ('349','CAFE AMERICANO',      62.50, 0),
    ('346','CAFE CORTADO',        85.93, 0),
    ('347','CAFE UNOSIETEOCHO',  156.25, 0),
    ('350','CAPUCCINO',          125.00, 0),
    ('351','CAPUCCINO AMERICANO',125.00, 0),
    ('17', 'CARAMEL FRAPPE',     172.00, 0),
    ('16', 'COCONUT FRAPPE',     175.00, 0),
    ('348','EXPRESSO',            54.68, 0),
    ('18', 'FRAPPE DE CHOCOLATE',165.00, 0),
    ('13', 'ICE COFFEE',         125.00, 0),
    ('352','MOCACCINO',          132.81, 0)
  ) as p(sku, name, price, cost)
  where not exists (select 1 from public.menu_items mi where mi.business_id = v_bid and mi.sku = p.sku);

  -- CERVEZAS (transformados — venta unitaria / barra)
  insert into public.menu_items (business_id, category_id, sku, name, price, cost, has_prep, is_beverage, is_active)
  select v_bid, v_cervezas, p.sku, p.name, p.price::numeric(12,2), p.cost::numeric, true, true, true
  from (values
    ('307','BOHEMIA',     156.25, 0),
    ('345','CERVEZA SOL', 214.84, 0),
    ('356','CORONA CERO', 171.87, 0),
    ('308','HEINEKEN 00', 203.12, 0)
  ) as p(sku, name, price, cost)
  where not exists (select 1 from public.menu_items mi where mi.business_id = v_bid and mi.sku = p.sku);

  -- T. RON
  insert into public.menu_items (business_id, category_id, sku, name, price, cost, has_prep, is_beverage, is_active)
  select v_bid, v_t_ron, p.sku, p.name, p.price::numeric(12,2), p.cost::numeric, true, true, true
  from (values
    ('360','T. ABUELO 7 AÑOS',           371.09, 0),
    ('115','T. BARCELO AÑEJO',           292.96, 0),
    ('114','T. BARCELO GRAN AÑEJO',      304.68, 0),
    ('111','T. BRUGAL 1888',             386.71, 0),
    ('108','T. BRUGAL EXTRA VIEJO',      304.68, 0),
    ('110','T. BRUGAL LEYENDA',          332.03, 0),
    ('284','T. BRUGAL TRIPLE RESERVA',   312.50, 0),
    ('109','T. DOBLE RESERVA',           308.59, 0),
    ('112','T. DON ARMANDO BERMUDEZ',    308.59, 0),
    ('434','T. DON ISIDRO',              332.03, 0),
    ('371','T. E. LEON JIMENEZ 110 AÑOS',1350.00, 0),
    ('361','T. HAVANA CLUB 7 AÑOS',      382.81, 0),
    ('113','T. RON VIEJO BERMUDEZ',      292.96, 0),
    ('359','T. SIBONEY 1920',            328.12, 0),
    ('358','T. SIBONEY ANEJO',           210.93, 0),
    ('357','T. SIBONEY RESERVA ESPECIAL',273.43, 0)
  ) as p(sku, name, price, cost)
  where not exists (select 1 from public.menu_items mi where mi.business_id = v_bid and mi.sku = p.sku);

  -- T. GINEBRA
  insert into public.menu_items (business_id, category_id, sku, name, price, cost, has_prep, is_beverage, is_active)
  select v_bid, v_t_ginebra, p.sku, p.name, p.price::numeric(12,2), p.cost::numeric, true, true, true
  from (values
    ('119','T. BEEFEATER',       300.78, 0),
    ('121','T. BEEFEATER ORANGE',343.75, 0),
    ('120','T. BEEFEATER PINK',  312.50, 0),
    ('118','T. BERMUDEZ',        277.34, 0),
    ('166','T. BOMBAY',          386.71, 0),
    ('274','T. BOMBAY',          386.71, 0),
    ('125','T. BULL DOG',        429.68, 0),
    ('122','T. FLOR DE SEVILLA', 406.25, 0),
    ('384','T. GIBSON',          277.34, 0),
    ('385','T. GIBSON PINK',     292.96, 0),
    ('124','T. HENDRIK''S',      585.93, 0),
    ('275','T. HENDRIK''S',      585.93, 0),
    ('123','T. TANQUERAY',       398.43, 0)
  ) as p(sku, name, price, cost)
  where not exists (select 1 from public.menu_items mi where mi.business_id = v_bid and mi.sku = p.sku);

  -- T. TEQUILA
  insert into public.menu_items (business_id, category_id, sku, name, price, cost, has_prep, is_beverage, is_active)
  select v_bid, v_t_tequila, p.sku, p.name, p.price::numeric(12,2), p.cost::numeric, true, true, true
  from (values
    ('362','T. ALTOS PLATA',       468.75, 0),
    ('363','T. ALTOS REPOSADO',    400.00, 0),
    ('364','T. DON JULIO 1942',   1800.00, 0),
    ('198','T. DON JULIO REPOSADO',742.18, 0),
    ('148','T. JARANA',            234.37, 0),
    ('199','T. PATRON REPOSADO',   507.81, 0),
    ('154','T. PATRON SILVER',     476.56, 0),
    ('366','T. TIZCAS REPOSADO',   360.00, 0),
    ('365','T. TIZCAS SILVER',     360.00, 0)
  ) as p(sku, name, price, cost)
  where not exists (select 1 from public.menu_items mi where mi.business_id = v_bid and mi.sku = p.sku);

  -- T. MEZCAL
  insert into public.menu_items (business_id, category_id, sku, name, price, cost, has_prep, is_beverage, is_active)
  select v_bid, v_t_mezcal, p.sku, p.name, p.price::numeric(12,2), p.cost::numeric, true, true, true
  from (values
    ('287','T. 400 CONEJOS',  609.38, 0),
    ('367','T. AMARAS VERDE', 497.50, 0)
  ) as p(sku, name, price, cost)
  where not exists (select 1 from public.menu_items mi where mi.business_id = v_bid and mi.sku = p.sku);

  -- T. VODKA
  insert into public.menu_items (business_id, category_id, sku, name, price, cost, has_prep, is_beverage, is_active)
  select v_bid, v_t_vodka, p.sku, p.name, p.price::numeric(12,2), p.cost::numeric, true, true, true
  from (values
    ('370','T. BELUGA NOBLE', 531.25, 0),
    ('417','T. POLIAKOV',     300.00, 0),
    ('107','T. STOLICHNAYA',  312.50, 0),
    ('117','T. TITO´S',       410.15, 0)
  ) as p(sku, name, price, cost)
  where not exists (select 1 from public.menu_items mi where mi.business_id = v_bid and mi.sku = p.sku);

  -- COCTELES CON TEQUILA
  insert into public.menu_items (business_id, category_id, sku, name, price, cost, has_prep, is_beverage, is_active)
  select v_bid, v_c_tequila, p.sku, p.name, p.price::numeric(12,2), p.cost::numeric, true, true, true
  from (values
    ('393','AGAVONI PATRON REPOSADO',     664.06, 0),
    ('392','AGAVONI PATRON SILVER',       585.93, 0),
    ('409','MARGARITA ALTOS REPOSADO',    400.00, 0),
    ('410','MARGARITA ALTOS SILVER',      400.00, 0),
    ('402','MARGARITA DON JULIO 1942',   2030.00, 0),
    ('403','MARGARITA DON JULIO REPOSADO',859.38, 0),
    ('39', 'MARGARITA JARANA',            312.50, 0),
    ('99', 'MARGARITA JARANA',            312.50, 0),
    ('100','MARGARITA JARANA',            312.50, 0),
    ('272','MARGARITA JARANA',            312.50, 0),
    ('411','MARGARITA PATRON REPOSADO',   585.00, 0),
    ('376','MARGARITA PATRON SILVER',     546.87, 0),
    ('404','MARGARITA TIZCAS REPOSADO',   359.37, 0),
    ('405','MARGARITA TIZCAS SILVER',     359.37, 0),
    ('396','PALOMA ALTOS REPOSADO',       500.00, 0),
    ('397','PALOMA ALTOS SILVER',         500.00, 0),
    ('394','PALOMA DON JULIO 1942',      1953.13, 0),
    ('395','PALOMA DON JULIO REPOSADO',   859.37, 0),
    ('47', 'PALOMA JARANA',               429.68, 0),
    ('401','PALOMA PATRON REPOSADO',      609.38, 0),
    ('400','PALOMA PATRON SILVER',        585.93, 0),
    ('398','PALOMA TIZCAS REPOSADO',      390.63, 0),
    ('399','PALOMA TIZCAS SILVER',        400.00, 0),
    ('406','TEQUILA MULE',                332.03, 0),
    ('45', 'TEQUILA SOUR JARANA',         312.50, 0)
  ) as p(sku, name, price, cost)
  where not exists (select 1 from public.menu_items mi where mi.business_id = v_bid and mi.sku = p.sku);

  -- COCTELES CON RON
  insert into public.menu_items (business_id, category_id, sku, name, price, cost, has_prep, is_beverage, is_active)
  select v_bid, v_c_ron, p.sku, p.name, p.price::numeric(12,2), p.cost::numeric, true, true, true
  from (values
    ('432','KINGSTON',                              414.06, 0),
    ('422','RUM OLD FASHION ARMANDO BERMUDEZ',      371.80, 0),
    ('420','RUM OLD FASHION B. 1888',               430.00, 0),
    ('424','RUM OLD FASHION B. DOBLE RESERVAS',     367.18, 0),
    ('421','RUM OLD FASHION B. EXTRA VIEJO',        335.94, 0),
    ('423','RUM OLD FASHION B. TRIPLE RESERVAS',    375.00, 0),
    ('419','RUM OLD FASHION E. 1903',               429.68, 0),
    ('435','SPICY RUM FASHION DON ISIDRO',          390.63, 0),
    ('418','SPICY RUM OLD FASHION ABUELO 7 AÑOS',   421.88, 0)
  ) as p(sku, name, price, cost)
  where not exists (select 1 from public.menu_items mi where mi.business_id = v_bid and mi.sku = p.sku);

  -- COCTELES CON GINEBRA
  insert into public.menu_items (business_id, category_id, sku, name, price, cost, has_prep, is_beverage, is_active)
  select v_bid, v_c_ginebra, p.sku, p.name, p.price::numeric(12,2), p.cost::numeric, true, true, true
  from (values
    ('380','BEEFEATER PINK SOUR',                  312.60, 0),
    ('377','FRENCH 75 BEEFEATER',                  378.90, 0),
    ('378','FRENCH 75 BEEFEATER PINK',             390.63, 0),
    ('379','FRENCH 75 BOMBAY',                     398.44, 0),
    ('46', 'GIN FLOR DE JAMAICA BERMUDEZ',         359.37, 0),
    ('190','GIN MARTINI BOMBAY',                   429.69, 0),
    ('387','GIN TONIC BEEFEATER',                  324.22, 0),
    ('388','GIN TONIC BEEFEATER PINK',             335.00, 0),
    ('106','GIN TONIC BERMUDEZ',                   312.50, 0),
    ('389','GIN TONIC BOMBAY',                     410.16, 0),
    ('381','GIN TONIC BULLDOG',                    468.75, 0),
    ('382','GIN TONIC HENDRIK´S',                  648.44, 0),
    ('391','GIN TONIC TANQUERAY',                  417.96, 0),
    ('390','GIN TONIC TANQUERAY FLOR DE SEVILLA',  429.68, 0),
    ('51', 'MIDGNITHE KISS',                       332.03, 0),
    ('372','NEGRONI BEEFEATER',                    429.68, 0),
    ('48', 'NEGRONI BERMUDEZ',                     371.09, 0),
    ('374','NEGRONI COMBAY',                       531.00, 0),
    ('373','NEGRONI HENDRIK´S',                    585.00, 0),
    ('375','NEGRONI TANQUERAY',                    546.87, 0),
    ('425','PINKNIGHT KISS',                       375.00, 0)
  ) as p(sku, name, price, cost)
  where not exists (select 1 from public.menu_items mi where mi.business_id = v_bid and mi.sku = p.sku);

  -- COCTELES CON WHISKY
  insert into public.menu_items (business_id, category_id, sku, name, price, cost, has_prep, is_beverage, is_active)
  select v_bid, v_c_whisky, p.sku, p.name, p.price::numeric(12,2), p.cost::numeric, true, true, true
  from (values
    ('195','MANHATHAN EVAN WILLIAM´S',           406.25, 0),
    ('415','MANHATHAN MAKER´S',                  546.87, 0),
    ('194','NEGRONI BOULEVADIER EVAN WILLIAMS',  507.81, 0),
    ('44', 'OLD FASHION EVAN WILLIAM´S',         351.56, 0),
    ('414','OLD FASHION MAKER',                  500.00, 0),
    ('412','WHISKY SOUR BALLENTINE',             289.06, 0)
  ) as p(sku, name, price, cost)
  where not exists (select 1 from public.menu_items mi where mi.business_id = v_bid and mi.sku = p.sku);

  -- COCTELES CON VODKA
  insert into public.menu_items (business_id, category_id, sku, name, price, cost, has_prep, is_beverage, is_active)
  select v_bid, v_c_vodka, p.sku, p.name, p.price::numeric(12,2), p.cost::numeric, true, true, true
  from (values
    ('192','COSMOPOLITAN',     429.69, 0),
    ('189','EXPRESSO MARTINI', 437.50, 0),
    ('188','LYCHEE MARTINI',   468.75, 0),
    ('42', 'MOSCOW MULE',      328.12, 0),
    ('191','VODKA MARTINI',    410.16, 0)
  ) as p(sku, name, price, cost)
  where not exists (select 1 from public.menu_items mi where mi.business_id = v_bid and mi.sku = p.sku);

  -- DISCOVERY COCKTAILS
  insert into public.menu_items (business_id, category_id, sku, name, price, cost, has_prep, is_beverage, is_active)
  select v_bid, v_discovery, p.sku, p.name, p.price::numeric(12,2), p.cost::numeric, true, true, true
  from (values
    ('430','DISCOVERY DON JULIO REPOSADO', 856.38, 0),
    ('431','DISCOVERY PATRON REPOSADO',    703.13, 0),
    ('427','DISCOVERY PATRON SILVER',      699.22, 0),
    ('428','DISCOVERY STOLI',              449.22, 0),
    ('429','DISCOVERY TITO´S',             468.75, 0)
  ) as p(sku, name, price, cost)
  where not exists (select 1 from public.menu_items mi where mi.business_id = v_bid and mi.sku = p.sku);

  -- =========================================================================
  -- COMBOS
  -- =========================================================================
  --
  -- El catálogo lista 1 combo (sku 276 — "Combo evento IERL", RD$31,620.31).
  -- Sus componentes se anotan como referencia en la descripción; la lógica
  -- de combo (bundle) puede modelarse luego con menu_item_groups si se
  -- requiere descontar inventario por componente.
  --
  -- Componentes según catálogo (cantidad 35 cada uno):
  --   - sku 40  MOJITO            (Limon)
  --   - sku 52  PRESIDENTE LIGHT
  --   - sku 41  SANGRIA TINTA     (Tinta)

  insert into public.menu_items (
    business_id, category_id, sku, name, price, cost, has_prep, is_beverage,
    is_active, description
  )
  select v_bid, v_combos, p.sku, p.name, p.price::numeric(12,2), p.cost::numeric,
         true, false, true, p.descr
  from (values
    ('276','Combo evento IERL', 31620.31, 0,
     'Combo para evento IERL. Incluye 35 x MOJITO (Limón) + 35 x PRESIDENTE LIGHT + 35 x SANGRIA TINTA (Tinta).')
  ) as p(sku, name, price, cost, descr)
  where not exists (select 1 from public.menu_items mi where mi.business_id = v_bid and mi.sku = p.sku);

end $$;

commit;

-- ============================================================================
-- Verificación rápida (ejecutar manualmente después del commit):
--
--   select count(*) from public.categories
--    where business_id = '380bda85-023d-41ed-9a85-0b3efc341304';
--   -- esperado: 32
--
--   select count(*) from public.menu_items
--    where business_id = '380bda85-023d-41ed-9a85-0b3efc341304';
--   -- esperado: 320
--
--   select c.name as categoria, count(mi.id) as productos
--     from public.categories c
--     left join public.menu_items mi
--       on mi.category_id = c.id
--      and mi.business_id = c.business_id
--    where c.business_id = '380bda85-023d-41ed-9a85-0b3efc341304'
--    group by c.name
--    order by c.position;
-- ============================================================================
