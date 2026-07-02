-- =============================================================================
-- Carga de productos para el negocio "La Maison Française"
-- business_id: d15b231d-ff9d-43c3-b467-f4a06f2a56d4
--
-- Ejecutar UNA sola vez en el SQL Editor de Supabase (prod).
-- NO va en supabase/migrations/ — es un seed de un negocio puntual.
--
-- Notas:
--  * tax_mode = 'inclusive' en todo: los menús indican que los precios YA
--    incluyen ITBIS y servicio. El total impreso = precio listado.
--    (Requiere que el negocio tenga su ITBIS por defecto configurado para
--     que el desglose base/ITBIS se calcule bien; el total no cambia.)
--  * is_beverage = true para bebidas (no comanda de cocina), false para comida.
--  * El bloque es idempotente: si ya existe la categoría 'Entradas' para este
--    negocio, no inserta nada (evita duplicar al re-ejecutar).
-- =============================================================================

BEGIN;

DO $$
DECLARE
  v_business uuid := 'd15b231d-ff9d-43c3-b467-f4a06f2a56d4';

  c_entradas    uuid := gen_random_uuid();
  c_platos      uuid := gen_random_uuid();
  c_postres     uuid := gen_random_uuid();
  c_tintos      uuid := gen_random_uuid();
  c_blancos     uuid := gen_random_uuid();
  c_rosados     uuid := gen_random_uuid();
  c_champagnes  uuid := gen_random_uuid();
  c_copa        uuid := gen_random_uuid();
  c_jugos       uuid := gen_random_uuid();
  c_agua_nat    uuid := gen_random_uuid();
  c_agua_gas    uuid := gen_random_uuid();
  c_aperitivos  uuid := gen_random_uuid();
  c_ginebras    uuid := gen_random_uuid();
  c_vodkas      uuid := gen_random_uuid();
  c_tequilas    uuid := gen_random_uuid();
  c_rones       uuid := gen_random_uuid();
  c_whiskies    uuid := gen_random_uuid();
BEGIN
  -- Guarda anti-doble-ejecución.
  IF EXISTS (
    SELECT 1 FROM public.categories
    WHERE business_id = v_business AND name = 'Entradas'
  ) THEN
    RAISE NOTICE 'Productos ya cargados para % — no se hace nada.', v_business;
    RETURN;
  END IF;

  -- ---------------------------------------------------------------------------
  -- Categorías
  -- ---------------------------------------------------------------------------
  INSERT INTO public.categories (id, business_id, name, position, is_active) VALUES
    (c_entradas,    v_business, 'Entradas',                1,  true),
    (c_platos,      v_business, 'Platos Principales',      2,  true),
    (c_postres,     v_business, 'Postres',                 3,  true),
    (c_tintos,      v_business, 'Vinos Tintos',            4,  true),
    (c_blancos,     v_business, 'Vinos Blancos',           5,  true),
    (c_rosados,     v_business, 'Vinos Rosados',           6,  true),
    (c_champagnes,  v_business, 'Champagnes',              7,  true),
    (c_copa,        v_business, 'Vinos por Copa',          8,  true),
    (c_jugos,       v_business, 'Jugos Naturales',         9,  true),
    (c_agua_nat,    v_business, 'Aguas Naturales',         10, true),
    (c_agua_gas,    v_business, 'Aguas con Gas',           11, true),
    (c_aperitivos,  v_business, 'Aperitivos y Digestivos', 12, true),
    (c_ginebras,    v_business, 'Ginebras',                13, true),
    (c_vodkas,      v_business, 'Vodkas',                  14, true),
    (c_tequilas,    v_business, 'Tequilas',                15, true),
    (c_rones,       v_business, 'Rones',                   16, true),
    (c_whiskies,    v_business, 'Whiskies',                17, true);

  -- ---------------------------------------------------------------------------
  -- Productos (price = total con ITBIS+servicio incluidos => tax_mode inclusive)
  -- columnas: business_id, category_id, name, price, tax_mode, is_beverage,
  --           position, description
  -- ---------------------------------------------------------------------------
  INSERT INTO public.menu_items
    (business_id, category_id, name, price, tax_mode, is_beverage, position, description)
  VALUES
    -- Entradas
    (v_business, c_entradas, 'Burrata Cremosa',            850,  'inclusive', false, 1, 'Pesto de albahaca y mermelada de higos'),
    (v_business, c_entradas, 'Sopa de Cebolla Gratinada',  600,  'inclusive', false, 2, 'Pan crujiente, queso gratinado'),
    (v_business, c_entradas, 'Huevo Cocotte',              500,  'inclusive', false, 3, 'Tocineta crujiente, hierbas frescas'),

    -- Platos Principales
    (v_business, c_platos, 'Pollo Asado',                  800,  'inclusive', false, 1, 'Papas grenailles al jugo de coccion'),
    (v_business, c_platos, 'Grand Raviolo',                800,  'inclusive', false, 2, 'Ricota y espinaca, yema de huevo al centro, salsa de mantequilla y tocineta'),
    (v_business, c_platos, 'Gratin Cremoso de Coliflor',   600,  'inclusive', false, 3, 'Salsa bechamel, parmesano y gratinado al horno'),
    (v_business, c_platos, 'Boeuf Bourguignon',            1400, 'inclusive', false, 4, 'Corte flat iron, zanahorias, champinones y tocineta, cocido a larga coccion al vino tinto'),
    (v_business, c_platos, 'Salmon a la Naranja',          1200, 'inclusive', false, 5, 'Salsa de naranja caramelizada, calabacin, zanahorias glaseadas, morrones asados, papas baby y esparragos'),
    (v_business, c_platos, 'Entrecote a la Parrilla',      1500, 'inclusive', false, 6, 'Salsa maison, papas grenailles salteadas'),
    (v_business, c_platos, 'Filet de Res (Tenderloin)',    2200, 'inclusive', false, 7, 'Salsa maison, papas grenailles salteadas'),
    (v_business, c_platos, 'Risotto au Churrasco',         1000, 'inclusive', false, 8, 'Arroz cremoso, churrasco a la parrilla, parmesano'),

    -- Postres
    (v_business, c_postres, 'Tarta Moka',   300, 'inclusive', false, 1, 'Bizcocho de mantequilla y cafe, crema de mantequilla de cafe'),
    (v_business, c_postres, 'Pain Perdu',   350, 'inclusive', false, 2, 'Mermelada de frutos rojos y frutas de temporada'),
    (v_business, c_postres, 'Tarta Tatin',  300, 'inclusive', false, 3, 'Manzana caramelizada, helado de vainilla'),
    (v_business, c_postres, 'Helado',       200, 'inclusive', false, 4, 'Seleccion de sabores'),
    (v_business, c_postres, 'Crepe',        200, 'inclusive', false, 5, 'Azucar o Nutella'),

    -- Vinos Tintos
    (v_business, c_tintos, 'Philippe Merlot',                      2450, 'inclusive', true, 1, NULL),
    (v_business, c_tintos, 'Georges Duboeuf Cotes du Rhone',       2700, 'inclusive', true, 2, NULL),
    (v_business, c_tintos, 'Georges Duboeuf Beaujolais-Villages',  3500, 'inclusive', true, 3, NULL),
    (v_business, c_tintos, 'Mouton Cadet Saint-Emilion',          5400, 'inclusive', true, 4, NULL),
    (v_business, c_tintos, 'Georges Duboeuf Chateauneuf-du-Pape',  8900, 'inclusive', true, 5, NULL),

    -- Vinos Blancos
    (v_business, c_blancos, 'Mouton Cadet Blanc',           3200, 'inclusive', true, 1, NULL),
    (v_business, c_blancos, 'Comte Lafond Sancerre Blanc',  7000, 'inclusive', true, 2, NULL),

    -- Vinos Rosados
    (v_business, c_rosados, 'By Ott Rose', 5000, 'inclusive', true, 1, NULL),

    -- Champagnes
    (v_business, c_champagnes, 'Moet & Chandon Brut Imperial',      9600,  'inclusive', true, 1, NULL),
    (v_business, c_champagnes, 'Louis Roederer Collection Brut',    10900, 'inclusive', true, 2, NULL),
    (v_business, c_champagnes, 'Billecart-Salmon Brut Rose',        15200, 'inclusive', true, 3, NULL),

    -- Vinos por Copa
    (v_business, c_copa, 'Philippe Merlot (Copa)',                 650,  'inclusive', true, 1, NULL),
    (v_business, c_copa, 'Georges Duboeuf Cotes du Rhone (Copa)',  700,  'inclusive', true, 2, NULL),
    (v_business, c_copa, 'Mouton Cadet Blanc (Copa)',              800,  'inclusive', true, 3, NULL),
    (v_business, c_copa, 'By Ott Rose (Copa)',                     1200, 'inclusive', true, 4, NULL),

    -- Jugos Naturales
    (v_business, c_jugos, 'Jugo de Fresa',   200, 'inclusive', true, 1, NULL),
    (v_business, c_jugos, 'Jugo de Limon',   200, 'inclusive', true, 2, NULL),
    (v_business, c_jugos, 'Jugo de Naranja', 200, 'inclusive', true, 3, NULL),

    -- Aguas Naturales
    (v_business, c_agua_nat, 'Agua Cascada', 40,  'inclusive', true, 1, NULL),
    (v_business, c_agua_nat, 'Agua Panna',   200, 'inclusive', true, 2, NULL),

    -- Aguas con Gas
    (v_business, c_agua_gas, 'San Pellegrino Grande',   300, 'inclusive', true, 1, NULL),
    (v_business, c_agua_gas, 'San Pellegrino Pequena',  170, 'inclusive', true, 2, NULL),
    (v_business, c_agua_gas, 'Perrier Grande',          290, 'inclusive', true, 3, NULL),
    (v_business, c_agua_gas, 'Perrier Pequena',         160, 'inclusive', true, 4, NULL),
    (v_business, c_agua_gas, 'Canada Dry',              100, 'inclusive', true, 5, NULL),

    -- Aperitivos y Digestivos
    (v_business, c_aperitivos, 'Grand Marnier',   370, 'inclusive', true, 1,  NULL),
    (v_business, c_aperitivos, 'Cointreau',       350, 'inclusive', true, 2,  NULL),
    (v_business, c_aperitivos, 'Sambuca Romana',  350, 'inclusive', true, 3,  NULL),
    (v_business, c_aperitivos, 'Campari',         300, 'inclusive', true, 4,  NULL),
    (v_business, c_aperitivos, 'Baileys',         280, 'inclusive', true, 5,  NULL),
    (v_business, c_aperitivos, 'Ricard',          310, 'inclusive', true, 6,  NULL),
    (v_business, c_aperitivos, 'Jagermeister',    270, 'inclusive', true, 7,  NULL),
    (v_business, c_aperitivos, 'Kahlua',          250, 'inclusive', true, 8,  NULL),
    (v_business, c_aperitivos, 'Branca Menta',    280, 'inclusive', true, 9,  NULL),
    (v_business, c_aperitivos, 'Fernet Branca',   280, 'inclusive', true, 10, NULL),
    (v_business, c_aperitivos, 'Crema de Menta',  200, 'inclusive', true, 11, NULL),

    -- Ginebras
    (v_business, c_ginebras, 'Beefeater (Botella)',       3600, 'inclusive', true, 1,  NULL),
    (v_business, c_ginebras, 'Beefeater (Trago)',         320,  'inclusive', true, 2,  NULL),
    (v_business, c_ginebras, 'Beefeater Pink (Botella)',  2800, 'inclusive', true, 3,  NULL),
    (v_business, c_ginebras, 'Beefeater Pink (Trago)',    340,  'inclusive', true, 4,  NULL),
    (v_business, c_ginebras, 'Citadelle (Botella)',       3200, 'inclusive', true, 5,  NULL),
    (v_business, c_ginebras, 'Citadelle (Trago)',         380,  'inclusive', true, 6,  NULL),
    (v_business, c_ginebras, 'Hendrick''s (Botella)',     3200, 'inclusive', true, 7,  NULL),
    (v_business, c_ginebras, 'Hendrick''s (Trago)',       340,  'inclusive', true, 8,  NULL),
    (v_business, c_ginebras, 'Bombay (Botella)',          2900, 'inclusive', true, 9,  NULL),
    (v_business, c_ginebras, 'Bombay (Trago)',            340,  'inclusive', true, 10, NULL),
    (v_business, c_ginebras, 'Bulldog (Trago)',           340,  'inclusive', true, 11, NULL),
    (v_business, c_ginebras, 'Bermudez (Botella)',        2200, 'inclusive', true, 12, NULL),

    -- Vodkas
    (v_business, c_vodkas, 'Grey Goose (Botella)',  4000, 'inclusive', true, 1, NULL),
    (v_business, c_vodkas, 'Grey Goose (Trago)',    380,  'inclusive', true, 2, NULL),
    (v_business, c_vodkas, 'Absolut (Botella)',     2800, 'inclusive', true, 3, NULL),
    (v_business, c_vodkas, 'Absolut (Trago)',       340,  'inclusive', true, 4, NULL),
    (v_business, c_vodkas, 'Stolichnaya (Botella)', 2800, 'inclusive', true, 5, NULL),
    (v_business, c_vodkas, 'Stolichnaya (Trago)',   340,  'inclusive', true, 6, NULL),
    (v_business, c_vodkas, 'Eristoff (Botella)',    2200, 'inclusive', true, 7, NULL),
    (v_business, c_vodkas, 'Eristoff (Trago)',      300,  'inclusive', true, 8, NULL),

    -- Tequilas
    (v_business, c_tequilas, 'Patron Blanco (Botella)',      6200, 'inclusive', true, 1, NULL),
    (v_business, c_tequilas, 'Patron Blanco (Trago)',        450,  'inclusive', true, 2, NULL),
    (v_business, c_tequilas, 'Don Julio Blanco (Botella)',   6400, 'inclusive', true, 3, NULL),
    (v_business, c_tequilas, 'Don Julio Blanco (Trago)',     400,  'inclusive', true, 4, NULL),
    (v_business, c_tequilas, 'Don Julio Reposado (Botella)', 6400, 'inclusive', true, 5, NULL),
    (v_business, c_tequilas, 'Don Julio Reposado (Trago)',   460,  'inclusive', true, 6, NULL),

    -- Rones
    (v_business, c_rones, 'Brugal Extra Viejo (Botella)',    3000, 'inclusive', true, 1,  NULL),
    (v_business, c_rones, 'Brugal Extra Viejo (Trago)',      340,  'inclusive', true, 2,  NULL),
    (v_business, c_rones, 'Brugal Anejo (Botella)',          2400, 'inclusive', true, 3,  NULL),
    (v_business, c_rones, 'Brugal Anejo (Trago)',            300,  'inclusive', true, 4,  NULL),
    (v_business, c_rones, 'Brugal Leyenda (Botella)',        3400, 'inclusive', true, 5,  NULL),
    (v_business, c_rones, 'Brugal Leyenda (Trago)',          340,  'inclusive', true, 6,  NULL),
    (v_business, c_rones, 'Brugal 1888 (Botella)',           3300, 'inclusive', true, 7,  NULL),
    (v_business, c_rones, 'Brugal 1888 (Trago)',             380,  'inclusive', true, 8,  NULL),
    (v_business, c_rones, 'Brugal Doble Reserva (Botella)',  2800, 'inclusive', true, 9,  NULL),
    (v_business, c_rones, 'Brugal Doble Reserva (Trago)',    320,  'inclusive', true, 10, NULL),
    (v_business, c_rones, 'Ripiao (Botella)',                4000, 'inclusive', true, 11, NULL),
    (v_business, c_rones, 'Ripiao (Trago)',                  340,  'inclusive', true, 12, NULL),

    -- Whiskies
    (v_business, c_whiskies, 'Chivas 12 (Botella)',            4000, 'inclusive', true, 1,  NULL),
    (v_business, c_whiskies, 'Chivas 12 (Trago)',              380,  'inclusive', true, 2,  NULL),
    (v_business, c_whiskies, 'Old Parr 12 (Botella)',          3800, 'inclusive', true, 3,  NULL),
    (v_business, c_whiskies, 'Old Parr 12 (Trago)',            380,  'inclusive', true, 4,  NULL),
    (v_business, c_whiskies, 'Black Label (Botella)',          4000, 'inclusive', true, 5,  NULL),
    (v_business, c_whiskies, 'Black Label (Trago)',            420,  'inclusive', true, 6,  NULL),
    (v_business, c_whiskies, 'Dewar''s 8 Anos (Botella)',      2200, 'inclusive', true, 7,  NULL),
    (v_business, c_whiskies, 'Dewar''s 8 Anos (Trago)',        250,  'inclusive', true, 8,  NULL),
    (v_business, c_whiskies, 'Jack Daniel''s Genesis (Botella)', 3800, 'inclusive', true, 9, NULL),
    (v_business, c_whiskies, 'Jack Daniel''s Genesis (Trago)',   380,  'inclusive', true, 10, NULL),
    (v_business, c_whiskies, 'Jack Daniel''s Fire (Botella)',  3800, 'inclusive', true, 11, NULL),
    (v_business, c_whiskies, 'Jack Daniel''s Fire (Trago)',    400,  'inclusive', true, 12, NULL),
    (v_business, c_whiskies, 'Jack Daniel''s Honey (Botella)', 4000, 'inclusive', true, 13, NULL),
    (v_business, c_whiskies, 'Jack Daniel''s Honey (Trago)',   410,  'inclusive', true, 14, NULL),
    (v_business, c_whiskies, 'Jack Daniel''s Apple (Botella)', 3400, 'inclusive', true, 15, NULL),
    (v_business, c_whiskies, 'Buchanan''s 12 (Botella)',       3800, 'inclusive', true, 16, NULL),
    (v_business, c_whiskies, 'Buchanan''s 18 (Botella)',       6800, 'inclusive', true, 17, NULL),
    (v_business, c_whiskies, 'Fireball (Botella)',             3000, 'inclusive', true, 18, NULL),
    (v_business, c_whiskies, 'Fireball (Trago)',               320,  'inclusive', true, 19, NULL),
    (v_business, c_whiskies, 'Glenfiddich 12 (Botella)',       6000, 'inclusive', true, 20, NULL),
    (v_business, c_whiskies, 'Glenfiddich 12 (Trago)',         450,  'inclusive', true, 21, NULL);

  RAISE NOTICE 'Productos cargados para %.', v_business;
END $$;

COMMIT;

-- Verificación rápida (correr aparte):
-- SELECT c.name AS categoria, count(*) AS items
-- FROM public.menu_items m JOIN public.categories c ON c.id = m.category_id
-- WHERE m.business_id = 'd15b231d-ff9d-43c3-b467-f4a06f2a56d4'
-- GROUP BY c.name ORDER BY min(c.position);
