-- =============================================================================
-- ECO BAR & LOUNGE — cotejo del menú YA CARGADO contra el PDF.
-- Negocio: fc3065c8-cb40-45ad-bec1-aecb388001c1
--
-- El diagnóstico mostró que el menú del PDF ya está en la POS (280 productos,
-- 32 categorías que cuadran una a una con el PDF). Esto NO borra ni cambia
-- nada: solo dice qué falta, qué sobra y qué tiene otro precio.
--
-- Compara por NOMBRE normalizado (sin tildes, sin mayúsculas, sin puntuación),
-- así que "Piña Colada" y "PINA COLADA" se reconocen como el mismo producto.
-- Pega TODO de una vez en el SQL Editor de Supabase.
-- =============================================================================

create or replace function pg_temp.norm(t text) returns text
  language sql immutable as $fn$
  select regexp_replace(
           translate(lower(coalesce(t,'')), 'áéíóúüñç', 'aeiouunc'),
           '[^a-z0-9]', '', 'g')
$fn$;

drop table if exists _pdf;
create temp table _pdf(cat text, name text, price numeric(12,2), k text);
insert into _pdf(cat, name, price) values
  ('ANTOJOS', 'Picadera de salchichas picantes', 350),
  ('ANTOJOS', 'Picadera de embutidos & quesos', 850),
  ('ANTOJOS', 'Eco Tartar', 750),
  ('ANTOJOS', 'Brocheta de Pollo', 350),
  ('ANTOJOS', 'Brocheta de Camarón', 400),
  ('ANTOJOS', 'Brocheta Mixta', 450),
  ('ANTOJOS', 'Canasticas de Birria (3 Unid)', 650),
  ('ANTOJOS', 'Canasticas de Camarones (3 Unid)', 700),
  ('ANTOJOS', 'Calamares fritos (7 Unid)', 350),
  ('ANTOJOS', 'Croquetas (3 Unid)', 400),
  ('ENTRADAS', 'Tacos al Campo (2 Unid)', 400),
  ('ENTRADAS', 'Tacos de Chicharrón (2 Unid)', 500),
  ('ENTRADAS', 'Tacos Hermanos Trejo (3 Unid)', 450),
  ('ENTRADAS', 'Camarones a la Roca', 650),
  ('ENTRADAS', 'Dumplings de Pork (5 Unid)', 450),
  ('ENTRADAS', 'Alitas a la BBQ (3 Unid)', 450),
  ('ENTRADAS', 'Ceviche Ecológico', 550),
  ('ENTRADAS', 'Deditos de pollo', 450),
  ('PLATOS FUERTES', 'Chuletas Fresh Pig', 600),
  ('PLATOS FUERTES', 'Pechuga de pollo a la parrilla', 400),
  ('PLATOS FUERTES', 'Ribeye', 2000),
  ('PLATOS FUERTES', 'Eco Ribs BBQ', 800),
  ('PLATOS FUERTES', 'Filet Mignon', 1400),
  ('PLATOS FUERTES', 'Delicia de la Selva Negra', 1500),
  ('PLATOS FUERTES', 'Churrasco a la Juliana', 1800),
  ('PLATOS FUERTES', 'Lomo Saltado', 1950),
  ('DELICIAS DEL MAR', 'Filete de Salmón del Pacífico', 900),
  ('DELICIAS DEL MAR', 'Parrillada de mariscos', 2500),
  ('DELICIAS DEL MAR', 'Camarones a la Eco criolla', 700),
  ('DELICIAS DEL MAR', 'Langosta Caribeña (por libra)', 1500),
  ('DELICIAS DEL MAR', 'Chillo del Mar Caribe (por libra)', 1000),
  ('DELICIAS DEL MAR', 'Mar y Tierra', 1800),
  ('DELICIAS DEL MAR', 'Cazuela de Mariscos Ecológica', 900),
  ('ENSALADAS', 'Tropical Salad', 550),
  ('ENSALADAS', 'Caeser Salad', 350),
  ('ENSALADAS', 'BBQ Salad', 550),
  ('ENSALADAS', 'Ensalada Eco', 400),
  ('MOFONGO', 'El Mofongo de Cayacoa', 900),
  ('MOFONGO', 'Mofongo de Pollo', 600),
  ('MOFONGO', 'Mofongo de Camarones', 800),
  ('MOFONGO', 'Mofongo de Churrasco', 1400),
  ('ARROCES AL ESTILO ECOBAR', 'Risotto Volcan', 1200),
  ('ARROCES AL ESTILO ECOBAR', 'Risotto de Camarón', 1100),
  ('ARROCES AL ESTILO ECOBAR', 'Salvaje Rice', 850),
  ('ARROCES AL ESTILO ECOBAR', 'Eco Concón', 550),
  ('ADICIONALES', 'Adicional Chicken', 250),
  ('ADICIONALES', 'Adicional Beef', 250),
  ('ADICIONALES', 'Adicional Shrimps', 250),
  ('ADICIONALES', 'Adicional Chicharrón', 250),
  ('PASTAS', 'Pasta del mar al tomate fresco', 850),
  ('PASTAS', 'Pasta alfredo', 550),
  ('PASTAS', 'Pasta a la carbonara', 600),
  ('PASTAS', 'Pasta con camarones', 800),
  ('PASTAS', 'Pesto de camarones', 950),
  ('PASTAS', 'Pasta Bolognesa', 550),
  ('HAMBURGUESAS', 'Chicken Burguer Special', 700),
  ('HAMBURGUESAS', 'Eco Burguer Special', 750),
  ('HAMBURGUESAS', 'La Ciclo Burguer', 650),
  ('GUARNICIONES', 'Tostones de mi tierra', 200),
  ('GUARNICIONES', 'Papas a la Francesa', 200),
  ('GUARNICIONES', 'Papas Salteadas', 250),
  ('GUARNICIONES', 'Vegetales Salteados', 250),
  ('GUARNICIONES', 'Eco puré de papas', 250),
  ('GUARNICIONES', 'Yuca Mash', 250),
  ('RINCOCITOS DE LOS ECOPEQUES', 'Nuggets', 350),
  ('RINCOCITOS DE LOS ECOPEQUES', 'Croquetas Mágicas', 350),
  ('RINCOCITOS DE LOS ECOPEQUES', 'Mini Burguer Eco', 400),
  ('RINCOCITOS DE LOS ECOPEQUES', 'Pasta Pirata', 400),
  ('RINCOCITOS DE LOS ECOPEQUES', 'Arroz Ninja', 400),
  ('RINCOCITOS DE LOS ECOPEQUES', 'Taquitos Caribeños', 350),
  ('POSTRES', 'Romeo y Julieta', 400),
  ('CAFÉ', 'Café americano', 140),
  ('CAFÉ', 'Café expreso', 135),
  ('CAFÉ', 'Capuchino', 170),
  ('AGUAS / SABORIZADAS', 'Agua San Pellegrino Cristal 750ml', 350),
  ('AGUAS / SABORIZADAS', 'Agua San Pellegrino Cristal 505ml', 250),
  ('AGUAS / SABORIZADAS', 'Agua Panna Cristal 750ml', 250),
  ('AGUAS / SABORIZADAS', 'Agua Panna Cristal 505ml', 200),
  ('AGUAS / SABORIZADAS', 'San Pellegrino Aranciata 330ml', 200),
  ('AGUAS / SABORIZADAS', 'San Pellegrino Melograno 330ml', 200),
  ('AGUAS / SABORIZADAS', 'San Pellegrino Aranciata Limón y Menta 330ml', 200),
  ('AGUAS / SABORIZADAS', 'San Pellegrino Aranciata Rossa 330ml', 200),
  ('AGUAS / SABORIZADAS', 'Agua Perrier Cristal 330ml', 200),
  ('AGUAS / SABORIZADAS', 'Dasani', 80),
  ('JUGOS / MIXERS', 'Aloe Vera Natural', 235),
  ('JUGOS / MIXERS', 'Canada Dry soda', 120),
  ('JUGOS / MIXERS', 'Canada Dry tónica', 120),
  ('JUGOS / MIXERS', 'Coca Cola', 65),
  ('JUGOS / MIXERS', 'Sprite', 65),
  ('JUGOS / MIXERS', 'Cranberry 946ml', 350),
  ('JUGOS / MIXERS', 'Gatorade', 100),
  ('JUGOS / MIXERS', 'Jarra Jugo de Naranja', 275),
  ('JUGOS / MIXERS', 'Jugo Clamato', 200),
  ('JUGOS / MIXERS', 'Jugos Motts 946ml', 350),
  ('JUGOS / MIXERS', 'Jugos Naturales', 160),
  ('JUGOS / MIXERS', 'Redbull', 200),
  ('CERVEZAS', 'Corona Extra', 195),
  ('CERVEZAS', 'Erdinger Weissbier', 350),
  ('CERVEZAS', 'Modelo Negra', 225),
  ('CERVEZAS', 'Modelo Especial', 210),
  ('CERVEZAS', 'Stella Artois', 235),
  ('CERVEZAS', 'Smirnoff Ice Green', 235),
  ('CERVEZAS', 'Presidente Light', 155),
  ('CERVEZAS', 'Presidente Regular', 155),
  ('CERVEZAS', 'Erdinger Alkoholfrei', 300),
  ('CERVEZAS', 'Paulaner Sin Alcohol', 450),
  ('CERVEZAS', 'Heiniken', 235),
  ('CERVEZAS', 'Ginger Beer Gosling Lata', 195),
  ('CERVEZAS', 'Ginger ale lata C&C', 155),
  ('CERVEZAS', 'Leffe Blonde', 235),
  ('CERVEZAS', 'Paulaner con Alcohol', 235),
  ('CERVEZAS', 'Estrella Galicia', 235),
  ('CERVEZAS', 'Coors Light', 235),
  ('CÓCTELES', 'Eco Spritz', 450),
  ('CÓCTELES', 'Cuba libre', 400),
  ('CÓCTELES', 'Dreamers', 300),
  ('CÓCTELES', 'Hotelero', 350),
  ('CÓCTELES', 'Higuey City', 300),
  ('CÓCTELES', 'El Ecologista', 350),
  ('CÓCTELES', 'Eco Verde', 550),
  ('CÓCTELES', 'Eco Punch', 200),
  ('CÓCTELES', 'Turista', 350),
  ('CÓCTELES', 'Basilica', 350),
  ('CÓCTELES', 'Margarita Eco', 400),
  ('CÓCTELES', 'Las Tres Cruces', 300),
  ('CÓCTELES', 'Fresa Colada sin alcohol', 250),
  ('CÓCTELES', 'Fresa Colada con alcohol', 350),
  ('CÓCTELES', 'Mojito de Limón / Fresa / Chinola', 300),
  ('CÓCTELES', 'Mojito de Coco', 350),
  ('CÓCTELES', 'Old Fashion', 400),
  ('CÓCTELES', 'Piña Colada', 400),
  ('CÓCTELES', 'Piña Colada con Alcohol', 350),
  ('CÓCTELES', 'Campari Tónic', 350),
  ('CÓCTELES', 'Mickey Mouse', 400),
  ('CÓCTELES', 'Amaretto Sour', 350),
  ('CÓCTELES', 'Whiskey Sour', 450),
  ('CÓCTELES', 'Moscow Mule', 350),
  ('CÓCTELES', 'Eco Special', 300),
  ('CÓCTELES', 'Sanky Panky', 350),
  ('CÓCTELES', 'Negroni Ecobar', 550),
  ('CÓCTELES', 'Beso Higueyano', 350),
  ('CÓCTELES', 'Ecomule', 350),
  ('CÓCTELES', 'Vodka Cinnamon', 300),
  ('CÓCTELES', 'Eco Diversidad', 350),
  ('CÓCTELES', 'Eco Sangría', 450),
  ('CÓCTELES', 'Madre Tierra', 350),
  ('CÓCTELES', 'Martini Clásico', 350),
  ('CÓCTELES', 'Lago Cristalino', 350),
  ('CÓCTELES', 'Schweppes Ginger Ale', 550),
  ('CÓCTELES', 'Daikiri', 350),
  ('CÓCTELES', 'Caipiriña', 350),
  ('CÓCTELES', 'Coco Loco', 400),
  ('CÓCTELES', 'Michelada', 450),
  ('CÓCTELES', 'Costa Azul', 350),
  ('GIN TONIC', 'Gin Tonic Eco', 350),
  ('GIN TONIC', 'Gin Tonic Bulldog', 450),
  ('GIN TONIC', 'Gin Tonic Bombay Saphire', 500),
  ('GIN TONIC', 'Gin Tonic Hendricks', 550),
  ('GIN TONIC', 'Gin Tonic Tanqueray No. Ten', 500),
  ('GIN TONIC', 'Gin Tonic Tanqueray Sport', 400),
  ('GIN TONIC', 'Gin Tonic Beefeater Pink', 450),
  ('GIN TONIC', 'Gin Tonic Beefeater', 350),
  ('RONES / TRAGOS', 'Barcelo Imperial (Botella)', 2500),
  ('RONES / TRAGOS', 'Barcelo Imperial (Trago)', 380),
  ('RONES / TRAGOS', 'Brugal 1888 (Botella)', 4000),
  ('RONES / TRAGOS', 'Brugal 1888 (Trago)', 420),
  ('RONES / TRAGOS', 'Brugal Leyenda (Botella)', 2300),
  ('RONES / TRAGOS', 'Brugal Leyenda (Trago)', 350),
  ('RONES / TRAGOS', 'Brugal Doble Reserva (Botella)', 1700),
  ('RONES / TRAGOS', 'Brugal Doble Reserva (Trago)', 300),
  ('RONES / TRAGOS', 'Brugal XV (Botella)', 1500),
  ('RONES / TRAGOS', 'Brugal XV (Trago)', 250),
  ('RONES / TRAGOS', 'Brugal Extra Viejo (Botella)', 1300),
  ('RONES / TRAGOS', 'Brugal Extra Viejo (Trago)', 200),
  ('WHISKEY / TRAGOS', 'Buchanans 12 (Botella)', 4300),
  ('WHISKEY / TRAGOS', 'Buchanans 12 (Trago)', 500),
  ('WHISKEY / TRAGOS', 'Buchanans 18 (Botella)', 8500),
  ('WHISKEY / TRAGOS', 'Buchanans 18 (Trago)', 850),
  ('WHISKEY / TRAGOS', 'Buffalo Trace Bourbon (Botella)', 4500),
  ('WHISKEY / TRAGOS', 'Buffalo Trace Bourbon (Trago)', 450),
  ('WHISKEY / TRAGOS', 'Chivas Regal 12 (Botella)', 4000),
  ('WHISKEY / TRAGOS', 'Chivas Regal 12 (Trago)', 400),
  ('WHISKEY / TRAGOS', 'Chivas Regal 18 (Botella)', 8000),
  ('WHISKEY / TRAGOS', 'Chivas Regal 18 (Trago)', 800),
  ('WHISKEY / TRAGOS', 'Dewars 12 años (Botella)', 2500),
  ('WHISKEY / TRAGOS', 'Dewars 12 años (Trago)', 350),
  ('WHISKEY / TRAGOS', 'Dewars 8 años (Botella)', 1300),
  ('WHISKEY / TRAGOS', 'Dewars 8 años (Trago)', 300),
  ('WHISKEY / TRAGOS', 'Fireball Liquors (Botella)', 2800),
  ('WHISKEY / TRAGOS', 'Fireball Liquors (Trago)', 300),
  ('WHISKEY / TRAGOS', 'Jack Daniel''s (Botella)', 3500),
  ('WHISKEY / TRAGOS', 'Jack Daniel''s (Trago)', 350),
  ('WHISKEY / TRAGOS', 'Jim Beam Bourbon (Botella)', 3000),
  ('WHISKEY / TRAGOS', 'Jim Beam Bourbon (Trago)', 350),
  ('WHISKEY / TRAGOS', 'JW Black Label (Botella)', 4500),
  ('WHISKEY / TRAGOS', 'JW Black Label (Trago)', 500),
  ('WHISKEY / TRAGOS', 'JW Doble Black (Botella)', 5500),
  ('WHISKEY / TRAGOS', 'JW Doble Black (Trago)', 600),
  ('WHISKEY / TRAGOS', 'JW Gold Label (Botella)', 7000),
  ('WHISKEY / TRAGOS', 'JW Gold Label (Trago)', 700),
  ('WHISKEY / TRAGOS', 'Old Parr 12 (Botella)', 4500),
  ('WHISKEY / TRAGOS', 'Old Parr 12 (Trago)', 450),
  ('WHISKEY / TRAGOS', 'Glenfiddich 12 (Botella)', 6000),
  ('WHISKEY / TRAGOS', 'The Glenlivet Founders (Botella)', 4500),
  ('WHISKEY / TRAGOS', 'The Macallan 12 (Botella)', 11000),
  ('VODKA', 'Tito''s Vodka (Botella)', 2700),
  ('VODKA', 'Grey Goose (Botella)', 3200),
  ('VODKA', 'Belvedere (Botella)', 4000),
  ('VODKA', 'Ketel One (Botella)', 3000),
  ('VODKA', 'Absolut (Botella)', 2300),
  ('VODKA', 'Stolichnaya (Botella)', 2000),
  ('VODKA', 'Eristoff (Botella)', 1500),
  ('GINEBRA', 'Hendricks (Botella)', 5750),
  ('GINEBRA', 'Tanqueray No Ten (Botella)', 4000),
  ('GINEBRA', 'Tanqueray Sport (Botella)', 2600),
  ('GINEBRA', 'Tanqueray London (Botella)', 3000),
  ('GINEBRA', 'Bombay Sapphire (Botella)', 3000),
  ('GINEBRA', 'Bulldog (Botella)', 3800),
  ('GINEBRA', 'Beefeater Pink (Botella)', 3500),
  ('GINEBRA', 'Beefeater (Botella)', 2300),
  ('TEQUILA', 'Don Julio Añejo (Botella)', 7300),
  ('TEQUILA', 'Don Julio Blanco (Botella)', 6800),
  ('TEQUILA', 'Don Julio Reposado (Botella)', 7500),
  ('TEQUILA', 'Patron Silver (Botella)', 6200),
  ('TEQUILA', 'Agavita Blanco (Botella)', 2500),
  ('TEQUILA', 'Agavita Gold (Botella)', 2500),
  ('DIGESTIVOS', 'Sambuca Romana', 250),
  ('DIGESTIVOS', 'Grappa Cellini Bianca', 250),
  ('DIGESTIVOS', 'Grappa Limóncello Cellini', 250),
  ('DIGESTIVOS', 'Amaro Averna', 250),
  ('DIGESTIVOS', 'Frangelico', 250),
  ('DIGESTIVOS', 'Baileys', 300),
  ('DIGESTIVOS', 'Kahlua licor de café', 300),
  ('DIGESTIVOS', 'Fernet Branca', 300),
  ('COPAS DE VINO', 'Vino tinto de la casa', 300),
  ('COPAS DE VINO', 'Vino blanco de la casa', 300),
  ('VINOS TINTO', 'Lopez de Haro Reserva', 2000),
  ('VINOS TINTO', 'Protos 9 Meses', 2400),
  ('VINOS TINTO', 'Emilio Moro Finca Resalso', 2000),
  ('VINOS TINTO', 'Robert Mondavi Private Selection Cabernet Sauvignon', 2200),
  ('VINOS TINTO', 'Woodbridge by Robert Mondavi Cabernet Sauvignon', 1500),
  ('VINOS TINTO', '19 Crimes Cali Red Snoop Dogg Red Blend', 2300),
  ('VINOS TINTO', '19 Crimes The Banished Red Blend', 2300),
  ('VINOS TINTO', 'Cantina Zaccagnini Montepulciano D''Abruzzo Sangiovese', 2000),
  ('VINOS TINTO', 'Frontera After Midnight', 1500),
  ('VINOS TINTO', 'Primitivo Borgo di Mandorlo Red Blend', 2000),
  ('VINOS TINTO', 'Trapiche Malbec', 1500),
  ('VINOS TINTO', 'Frontera Carmenere', 1500),
  ('VINOS TINTO', 'Josh Cellars Legacy', 2000),
  ('VINOS TINTO', 'Beringer Red Crush Red Blend', 1500),
  ('VINOS TINTO', 'Mureda Tempranillo', 1200),
  ('VINOS TINTO', 'Knock Knock Red Blend', 1200),
  ('VINOS TINTO', 'Próximo Marqués de Riscal', 1500),
  ('VINOS TINTO', 'Woodbridge Cabernet Sauvignon', 1500),
  ('VINOS BLANCOS', 'Beringer Main & Vine Chardonnay', 1500),
  ('VINOS BLANCOS', 'Martín Códax Albariño', 2000),
  ('VINOS BLANCOS', 'Beringer Main & Vine Moscato', 1500),
  ('VINOS BLANCOS', 'Gotas de Mar Albariño', 2300),
  ('VINOS BLANCOS', 'Knock Knock Sauvignon Blanc', 1200),
  ('VINOS BLANCOS', 'Marqués de Riscal', 2000),
  ('VINOS BLANCOS', 'Marqués de Vizhoja', 1500),
  ('VINOS BLANCOS', 'Mureda Sauvignon Blanc', 1200),
  ('VINOS BLANCOS', 'Torresella Pinot Grigio', 1500),
  ('VINOS BLANCOS', 'Woodbridge Sauvignon Blanc', 1500),
  ('VINOS BLANCOS', 'Frontera Pinot Grigio', 1200),
  ('VINOS ROSADO', '19 Crimes Cali Rosé', 2300),
  ('VINOS ROSADO', 'Woodbridge White Zinfandel', 1500),
  ('VINOS ROSADO', 'Beringer White Zinfandel', 1500),
  ('CAVA / PROSECCO', 'Segura Viudas Brut Reserva', 2000),
  ('CAVA / PROSECCO', 'Segura Viudas Brut Rosé', 2000),
  ('CAVA / PROSECCO', 'Prosecco Maschio', 2000),
  ('CAVA / PROSECCO', 'Jaume Serra Cava', 1200),
  ('CHAMPAGNE', 'Perrier Jouet Grand Brut', 6600),
  ('CHAMPAGNE', 'Pommery Brut Royal', 4900),
  ('CIGARROS', 'La Aurora 115 Aniversario c/u', 550),
  ('CIGARROS', 'La Aurora Connecticut c/u', 400),
  ('CIGARROS', 'La Aurora Maduro Belicoso c/u', 450),
  ('CIGARROS', 'La Aurora Maduro Robusto c/u', 400),
  ('CIGARROS', 'León Jimenes No. 5 c/u', 350),
  ('CIGARROS', 'Don Carlos Altagracia Premium', 500),
  ('CIGARRILLOS', 'Lucky Strike Black', 275),
  ('CIGARRILLOS', 'Marlboro Fresh Ice Peq.', 500),
  ('CIGARRILLOS', 'Marlboro Gold Peq.', 400),
  ('CIGARRILLOS', 'Marlboro Rojo Peq.', 350);
update _pdf set k = pg_temp.norm(name);


-- ---------------------------------------------------------------------------
-- 1. EN EL PDF PERO NO EN LA POS. Hay que crearlos.
--    Se esperan los 4 de ADICIONALES; cualquier otro es un renglón que se
--    quedó fuera o que está cargado con otro nombre.
-- ---------------------------------------------------------------------------
select p.cat as categoria_pdf, p.name as producto, p.price as precio_pdf
  from _pdf p
 where not exists (
   select 1 from public.menu_items mi
    where mi.business_id = 'fc3065c8-cb40-45ad-bec1-aecb388001c1' and mi.is_active
      and pg_temp.norm(mi.name) = p.k)
 order by p.cat, p.name;


-- ---------------------------------------------------------------------------
-- 2. EN LA POS PERO NO EN EL PDF. O es un nombre escrito distinto, o es un
--    producto viejo que sobrevivió y ya no va en la carta.
-- ---------------------------------------------------------------------------
select c.name as categoria_pos, mi.name as producto, mi.price as precio_pos
  from public.menu_items mi
  left join public.categories c on c.id = mi.category_id
 where mi.business_id = 'fc3065c8-cb40-45ad-bec1-aecb388001c1' and mi.is_active
   and not exists (select 1 from _pdf p where p.k = pg_temp.norm(mi.name))
 order by c.position, mi.name;


-- ---------------------------------------------------------------------------
-- 3. MISMO PRODUCTO, PRECIO DISTINTO. Esto es lo que de verdad importa:
--    un precio mal cargado se factura mal todos los días.
-- ---------------------------------------------------------------------------
select c.name as categoria, mi.name as producto,
       mi.price as precio_en_pos, p.price as precio_en_pdf,
       mi.price - p.price as diferencia
  from public.menu_items mi
  join _pdf p on p.k = pg_temp.norm(mi.name)
  left join public.categories c on c.id = mi.category_id
 where mi.business_id = 'fc3065c8-cb40-45ad-bec1-aecb388001c1' and mi.is_active
   and mi.price is distinct from p.price
 order by abs(mi.price - p.price) desc;


-- ---------------------------------------------------------------------------
-- 4. PRODUCTOS REPETIDOS en la POS (mismo nombre normalizado más de una vez).
-- ---------------------------------------------------------------------------
select pg_temp.norm(mi.name) as clave, count(*) as veces,
       string_agg(mi.name || ' = ' || mi.price, ' | ' order by mi.name) as filas
  from public.menu_items mi
 where mi.business_id = 'fc3065c8-cb40-45ad-bec1-aecb388001c1' and mi.is_active
 group by pg_temp.norm(mi.name)
having count(*) > 1;


-- ---------------------------------------------------------------------------
-- 5. RESUMEN.
-- ---------------------------------------------------------------------------
select (select count(*) from _pdf)                                    as en_el_pdf,
       (select count(*) from public.menu_items
         where business_id = 'fc3065c8-cb40-45ad-bec1-aecb388001c1' and is_active)                  as en_la_pos,
       (select count(*) from _pdf p where not exists (
          select 1 from public.menu_items mi
           where mi.business_id = 'fc3065c8-cb40-45ad-bec1-aecb388001c1' and mi.is_active
             and pg_temp.norm(mi.name) = p.k))                        as faltan,
       (select count(*) from public.menu_items mi
         where mi.business_id = 'fc3065c8-cb40-45ad-bec1-aecb388001c1' and mi.is_active
           and exists (select 1 from _pdf p where p.k = pg_temp.norm(mi.name)
                        and p.price is distinct from mi.price))       as precio_distinto;