-- =============================================================================
-- Carga ADITIVA de productos para el negocio (bar/beach — "Farolitos / El Faro")
-- business_id: 9dc6f0fe-a152-4a60-b279-22885717eec5
--
-- El negocio YA TIENE productos: este script SUMA los nuevos sin tocar los
-- existentes. Ejecutar en el SQL Editor de Supabase (prod).
-- NO va en supabase/migrations/ — es un seed de un negocio puntual.
--
-- Seguridad:
--  * Categorías = find-or-create por nombre: si ya existe una con el mismo
--    nombre la reusa; si no, la crea. Las nuevas se numeran DESPUÉS de las
--    categorías actuales (no reordena las pestañas existentes).
--  * Ítems = insert-if-not-exists (por nombre dentro de la categoría), así que
--    correrlo dos veces NO duplica.
--  * tax_mode = 'inclusive': precios redondos de barra (50/200/500…) = precio
--    final que paga el cliente, ITBIS incluido. (Requiere que el negocio tenga
--    su ITBIS por defecto configurado para desglosar; el total no cambia.)
--  * is_beverage = true en todo menos "Chicle".
--
-- Fuentes:
--  * PDF "Menú de Bebidas" (Farolitos Clásicos / Beach / Sunset).
--  * Imagen de carta de botellas/refrescos — SOLO la primera columna de precio.
--  * Dedup: Agua, Agua de Coco y Red Bull salían en ambas; quedan solo en
--    Farolitos Clásicos.
-- =============================================================================

BEGIN;

DO $$
DECLARE
  v_business  uuid := '9dc6f0fe-a152-4a60-b279-22885717eec5';
  v_pos_base  int;
  v_catmap    jsonb := '{}';   -- nombre_categoria -> id
  v_id        uuid;
  v_inserted  int;
  r           RECORD;
BEGIN
  -- Base de posición: las categorías nuevas van después de las actuales.
  SELECT COALESCE(MAX(position), 0) INTO v_pos_base
    FROM public.categories
   WHERE business_id = v_business;

  -- Find-or-create de cada categoría; arma el mapa nombre -> id.
  FOR r IN
    SELECT * FROM (VALUES
      ('Farolitos Clásicos', 1),
      ('Farolitos Beach',    2),
      ('Farolitos Sunset',   3),
      ('Whiskies',           4),
      ('Rones',              5),
      ('Tequilas',           6),
      ('Vodkas',             7),
      ('Champagnes',         8),
      ('Cognac',             9),
      ('Vinos',              10),
      ('Refrescos y Jugos',  11)
    ) AS c(name, ord)
  LOOP
    SELECT id INTO v_id
      FROM public.categories
     WHERE business_id = v_business AND name = r.name
     LIMIT 1;

    IF v_id IS NULL THEN
      v_id := gen_random_uuid();
      INSERT INTO public.categories (id, business_id, name, position, is_active)
      VALUES (v_id, v_business, r.name, v_pos_base + r.ord, true);
    END IF;

    v_catmap := v_catmap || jsonb_build_object(r.name, v_id::text);
  END LOOP;

  -- Ítems: se insertan solo si no existe ya uno con ese nombre en la categoría.
  -- columnas VALUES: (categoria, nombre, precio, is_beverage, posicion)
  INSERT INTO public.menu_items
    (business_id, category_id, name, price, tax_mode, is_beverage, position)
  SELECT v_business,
         (v_catmap ->> x.cat)::uuid,
         x.name, x.price, 'inclusive', x.is_bev, x.pos
  FROM (VALUES
    -- Farolitos Clásicos
    ('Farolitos Clásicos', 'Agua',                              50,  true,  1),
    ('Farolitos Clásicos', 'Agua con Gas (Soda Amarga)',        200, true,  2),
    ('Farolitos Clásicos', 'Agua de Coco',                      200, true,  3),
    ('Farolitos Clásicos', 'Cerveza Blue Moon',                 200, true,  4),
    ('Farolitos Clásicos', 'Cerveza Corona',                    200, true,  5),
    ('Farolitos Clásicos', 'Cerveza Presidente',                200, true,  6),
    ('Farolitos Clásicos', 'Cerveza República',                 200, true,  7),
    ('Farolitos Clásicos', 'Coca Cola',                         50,  true,  8),
    ('Farolitos Clásicos', 'Margarita (Chinola-Tradicional)',   300, true,  9),
    ('Farolitos Clásicos', 'Mojito (Chinola-Coco-Tradicional)', 250, true,  10),
    ('Farolitos Clásicos', 'Red Bull',                          200, true,  11),
    ('Farolitos Clásicos', 'Shots de Tequila Patrón',           500, true,  12),

    -- Farolitos Beach
    ('Farolitos Beach', 'Arena Blanca', 300, true, 1),
    ('Farolitos Beach', 'Coco Loco',    350, true, 2),
    ('Farolitos Beach', 'Dama del Faro', 600, true, 3),
    ('Farolitos Beach', 'Piña Colada',  300, true, 4),

    -- Farolitos Sunset
    ('Farolitos Sunset', 'Caballero del Faro',            400, true, 1),
    ('Farolitos Sunset', 'Faro Sunset',                  300, true, 2),
    ('Farolitos Sunset', 'Gin Tonic (Afrutado-Especiado)', 350, true, 3),
    ('Farolitos Sunset', 'Medusa del Faro',              400, true, 4),
    ('Farolitos Sunset', 'Sexo On The Beach',            400, true, 5),

    -- Whiskies (imagen — primera columna de precio)
    ('Whiskies', 'Johnnie Walker Blue Label',    20000, true, 1),
    ('Whiskies', 'Johnnie Walker Gold 18 Años',  8700,  true, 2),
    ('Whiskies', 'Johnnie Walker Gold 12 Años',  6700,  true, 3),
    ('Whiskies', 'Johnnie Walker Double Black',  5800,  true, 4),
    ('Whiskies', 'Johnnie Walker Black Label',   4600,  true, 5),
    ('Whiskies', 'Chivas 12',                    4300,  true, 6),
    ('Whiskies', 'Old Parr 12 Años',             4600,  true, 7),
    ('Whiskies', 'Buchanan''s 18 Años',          8700,  true, 8),
    ('Whiskies', 'Buchanan''s 12 Años',          4600,  true, 9),

    -- Rones
    ('Rones', 'Brugal 1888',           3500, true, 1),
    ('Rones', 'Brugal Leyenda',        2400, true, 2),
    ('Rones', 'Brugal Doble Reserva',  1700, true, 3),
    ('Rones', 'Brugal Extra Viejo',    1500, true, 4),

    -- Tequilas
    ('Tequilas', 'Tequila Don Julio Reposado', 6600, true, 1),

    -- Vodkas
    ('Vodkas', 'Stolichnaya', 2400, true, 1),

    -- Champagnes
    ('Champagnes', 'Moët Impérial Ice', 7500, true, 1),

    -- Cognac
    ('Cognac', 'Hennessy V.S.O.P', 6600, true, 1),

    -- Vinos
    ('Vinos', 'Vino 19 Crimes', 2700, true, 1),
    ('Vinos', 'Vino 689',       2700, true, 2),

    -- Refrescos y Jugos (imagen — sin duplicar los que ya van en Clásicos)
    ('Refrescos y Jugos', 'Jugo de Cranberry', 200, true,  1),
    ('Refrescos y Jugos', 'Jugo Mott''s',      300, true,  2),
    ('Refrescos y Jugos', 'Jugo de Piña',      200, true,  3),
    ('Refrescos y Jugos', 'Agua Perrier',      200, true,  4),
    ('Refrescos y Jugos', 'Gatorade',          100, true,  5),
    ('Refrescos y Jugos', 'Refresco',          100, true,  6),
    ('Refrescos y Jugos', 'Soda Enriquillo',   100, true,  7),
    ('Refrescos y Jugos', 'Chicle',            50,  false, 8)
  ) AS x(cat, name, price, is_bev, pos)
  WHERE NOT EXISTS (
    SELECT 1 FROM public.menu_items m
    WHERE m.business_id = v_business
      AND m.category_id = (v_catmap ->> x.cat)::uuid
      AND m.name = x.name
  );

  GET DIAGNOSTICS v_inserted = ROW_COUNT;
  RAISE NOTICE 'Insertados % productos nuevos para %.', v_inserted, v_business;
END $$;

COMMIT;

-- Verificación rápida (correr aparte):
-- SELECT c.name AS categoria, count(*) AS items
-- FROM public.menu_items m JOIN public.categories c ON c.id = m.category_id
-- WHERE m.business_id = '9dc6f0fe-a152-4a60-b279-22885717eec5'
-- GROUP BY c.name ORDER BY min(c.position);
