-- ============================================================================
-- EL RINCÓN DE ADDA — CARGA DEL MENÚ
-- Business 8cb85c65-ae49-4384-a678-0d8a201a955e
--
-- Fuente: 11 fotos de la carta impresa (2026-10-16). Sin códigos ni costos.
-- Este archivo lo arma build_import_8cb85c65.py. No lo edites a mano.
-- ============================================================================
--
-- QUÉ CARGA
--   135 productos en 14 categorías: 70 de comida (van a la COCINA) y 65 bebidas (van al BAR).
--   10 grupos de modificadores, enlazados 30 veces.
--     ENTRADAS                 6  → cocina
--     ENSALADAS                6  → cocina
--     PASTAS                   6  → cocina
--     PIZZAS                  11  → cocina
--     CARNES                  12  → cocina
--     PESCADOS Y MARISCOS     18  → cocina
--     ESPECIALIDADES           6  → cocina
--     GUARNICIONES             5  → cocina
--     TRAGOS PROPIOS           6  → bar
--     TRAGOS TRADICIONALES    23  → bar
--     SHOTS                    7  → bar
--     VINOS                   11  → bar
--     CERVEZAS                 4  → bar
--     BEBIDAS                 14  → bar
--
-- PRECIOS (ITBIS 18% + LEY 10% INCLUIDOS)
--   tax_mode = 'inclusive': lo que dice la carta es lo que paga el cliente.
--   Los dos impuestos salen de adentro: Churrasco $1,200 = base 937.50 +
--   ITBIS 168.75 + Ley 93.75.
--
-- MODIFICADORES
--   * Obligatorios (se escoge 1 al marcar el producto): tipo de pasta,
--     término de la carne, plancha o parrilla, frito o al vapor, preparación
--     del marisco, salsa, vegetales, papas y «con o sin alcohol» (Piña Colada
--     $400 / $450 y Smoothie de Fresa $450 / $500: la opción suma $50).
--   * Opcional: proteína de la pasta (Pollo +150, Res +200, Mariscos +400).
--   Los grupos son del negocio y se buscan por nombre: si ya existe uno con
--   el mismo nombre, se reusa y se deja con la configuración de esta lista.
--
-- CÓMO CORRERLO
--   Corre antes 00_diagnostico.sql. Después pega este entero en el SQL
--   Editor de Supabase y dale Run. La tabla que sale al final es el reporte:
--   todas las filas deben decir ✓.
--
-- TODO O NADA
--   Va en UNA transacción. Primero comprueba todo (negocio, ITBIS, Ley,
--   menú, áreas, choques con el catálogo actual) y después, antes del
--   commit, verifica producto por producto. Si algo no cuadra lanza
--   excepción y REVIERTE ENTERO.
--
-- SE PUEDE RE-CORRER
--   Empareja por nombre (o por el nombre impreso, cuando se corrigió), sin
--   mayúsculas ni tildes. El que ya existe se ACTUALIZA (precio,
--   descripción, categoría, impuestos, área, modificadores) y el que falta
--   se INSERTA. Para corregir algo: cámbialo en catalogo.py, corre
--   build_import_8cb85c65.py y vuelve a correr este archivo.
--
-- IMPUESTOS
--   menu_item_taxes es la ÚNICA fuente del impuesto por producto: sin fila ahí
--   la factura sale con ITBIS 0.00. Cada producto queda con ITBIS 18% + Ley
--   10% y nada más. Aborta si la Ley tiene is_service_fee = true o si la Ley
--   por orden (service_fee_enabled) está encendida: se cobraría DOBLE.
--
-- ÁREAS DE COMANDA (cómo las escoge)
--   * cocina apagada en Ajustes (kitchen_enabled = false): ninguna;
--   * COCINA: un área activa con code cocina / kitchen / kitchen_hot / comida
--     (o que se llame así); si no, reactiva una apagada, o CREA "Cocina"
--     (code `cocina`) SIN impresora;
--   * BAR: un área activa con code bar / barra (o que se llame así); si no,
--     reactiva una apagada, o CREA "Bar" (code `bar`) SIN impresora;
--   * nunca usa las áreas de sistema (cashier, fiscal, cash_close).
--   Un área creada aquí sale ✗ en el reporte hasta que le vincules la
--   impresora en la app.
--   Escribe LOS DOS mecanismos: menu_item_print_areas (N:M) y el legacy
--   menu_items.print_area_code, que fn_add_item_from_menu copia al
--   order_item. Sin el legacy, un bache de red manda la comanda a otro lado.
--
-- MENÚ
--   La caja filtra los productos por menú (menu_item_links). Se reusa el menú
--   activo que hay; si no hay ninguno se crea "Menú Principal"; si hay más de
--   uno, ABORTA.
-- ============================================================================

begin;

-- Nombre normalizado: sin mayúsculas, sin tildes, sin espacios repetidos.
create or replace function pg_temp.norm(t text) returns text
language sql immutable as $f$
  select translate(lower(regexp_replace(btrim(t), '\s+', ' ', 'g')),
                   'áéíóúüñÁÉÍÓÚÜÑ', 'aeiouunaeiouun')
$f$;

-- ---------------------------------------------------------------------------
-- 0) La carta. Tablas temporales de la sesión: el reporte de abajo las usa.
-- ---------------------------------------------------------------------------

drop table if exists _ra_categorias;
create temp table _ra_categorias (
  name     text not null,
  posicion int  not null,
  area     text not null check (area in ('cocina', 'bar'))
);

insert into _ra_categorias (name, posicion, area) values
  ('ENTRADAS', 10, 'cocina'),
  ('ENSALADAS', 11, 'cocina'),
  ('PASTAS', 12, 'cocina'),
  ('PIZZAS', 13, 'cocina'),
  ('CARNES', 14, 'cocina'),
  ('PESCADOS Y MARISCOS', 15, 'cocina'),
  ('ESPECIALIDADES', 16, 'cocina'),
  ('GUARNICIONES', 17, 'cocina'),
  ('TRAGOS PROPIOS', 30, 'bar'),
  ('TRAGOS TRADICIONALES', 31, 'bar'),
  ('SHOTS', 32, 'bar'),
  ('VINOS', 33, 'bar'),
  ('CERVEZAS', 34, 'bar'),
  ('BEBIDAS', 35, 'bar')
;

drop table if exists _ra_productos;
create temp table _ra_productos (
  name        text not null,
  alias       text not null,
  categoria   text not null,
  price       numeric(12,2) not null,
  descripcion text,
  posicion    int not null
);

insert into _ra_productos (name, alias, categoria, price, descripcion, posicion) values
  ('Carpaccio de Lomito', 'Carpaccio de Lomito', 'ENTRADAS', 470.00, 'Finas láminas de lomito de res, acompañadas de queso parmesano, champiñones frescos, aceite de oliva extra virgen y un delicado toque de limón.', 1),
  ('Aros de Calamar Rebozados', 'Aros de Calamar Rebozados', 'ENTRADAS', 470.00, 'Aros de calamar ligeramente empanizados y dorados, servidos con limón fresco y aderezo especial de la casa.', 2),
  ('Bruquetas de Camarón', 'Bruquetas de Camarón', 'ENTRADAS', 700.00, 'Pan artesanal tostado con camarones salteados y queso mozzarella gratinado.', 3),
  ('Bruquetas Caprese', 'Bruquetas Caprese', 'ENTRADAS', 450.00, 'Pan artesanal tostado con tomates frescos, mozzarella gratinada, albahaca y aceite de oliva extra virgen.', 4),
  ('Croquetas de Pollo', 'Croquetas de Pollo', 'ENTRADAS', 360.00, 'Crujientes croquetas de pollo artesanal, acompañadas de salsa tártara.', 5),
  ('Focaccia', 'Focaccia', 'ENTRADAS', 250.00, 'Masa horneada con aceite de oliva extra virgen, queso parmesano y orégano.', 6),
  ('Ensalada Verde', 'Ensalada Verde', 'ENSALADAS', 300.00, 'Mezcla de lechugas frescas, tomate, pepino y zanahoria, acompañada de aderezo especial de la casa.', 1),
  ('Ensalada Caprese', 'Ensalada Caprese', 'ENSALADAS', 420.00, 'Tomates frescos, mozzarella, hojas de albahaca y reducción de vinagre balsámico.', 2),
  ('Ensalada César', 'Ensalada César', 'ENSALADAS', 350.00, 'Lechuga romana, queso parmesano, crutones y el tradicional aderezo César.', 3),
  ('Ensalada César con Pollo', 'Ensalada César con Pollo', 'ENSALADAS', 400.00, 'Lechuga romana, queso parmesano, crutones, pechuga de pollo y el tradicional aderezo César.', 4),
  ('Ensalada César con Camarones', 'Ensalada César con Camarones', 'ENSALADAS', 600.00, 'Lechuga romana, queso parmesano, crutones, camarones y el tradicional aderezo César.', 5),
  ('Ensalada de Aguacate', 'Ensalada de Aguacate', 'ENSALADAS', 250.00, 'Aguacate fresco sobre una cama de lechugas, aliñado con aceite de oliva extra virgen, sal y pimienta.', 6),
  ('Pasta Alfredo', 'Pasta Alfredo', 'PASTAS', 600.00, null, 1),
  ('Pasta Carbonara', 'Pasta Carbonara', 'PASTAS', 650.00, null, 2),
  ('Pasta Marinara', 'Pasta Marinara', 'PASTAS', 1070.00, null, 3),
  ('Pasta Caprese', 'Pasta Caprese', 'PASTAS', 750.00, null, 4),
  ('Pasta a la Crema', 'Pasta a la Crema', 'PASTAS', 600.00, null, 5),
  ('Pasta Cuatro Quesos', 'Pasta Cuatro Quesos', 'PASTAS', 750.00, null, 6),
  ('Pizza Romana', 'Pizza Romana', 'PIZZAS', 700.00, 'Jamón, maíz dulce, pepperoni y mozzarella.', 1),
  ('Pizza Prosciutto e Funghi', 'Pizza Prosciutto e Funghi', 'PIZZAS', 600.00, 'Jamón, champiñones frescos y queso mozzarella.', 2),
  ('Pizza Prosciutto', 'Pizza Prosciutto', 'PIZZAS', 600.00, 'Jamón y abundante queso mozzarella.', 3),
  ('Pizza Caprese', 'Pizza Caprese', 'PIZZAS', 600.00, 'Tomates cherry, mozzarella fresca y albahaca.', 4),
  ('Pizza de Vegetales', 'Pizza de Vegetales', 'PIZZAS', 700.00, 'Pimientos tricolores, cebolla, champiñones y maíz dulce.', 5),
  ('Pizza Pepperoni', 'Pizza Pepperoni', 'PIZZAS', 650.00, 'Pepperoni y queso mozzarella.', 6),
  ('Pizza Cuatro Quesos', 'Pizza Cuatro Quesos', 'PIZZAS', 750.00, 'Mozzarella, parmesano, cheddar y queso azul.', 7),
  ('Pizza Marinera', 'Pizza Marinera', 'PIZZAS', 1100.00, 'Camarones, aros de calamar y queso mozzarella.', 8),
  ('Pizza Chicken Crispy', 'Pizza Chicken Crispy', 'PIZZAS', 600.00, 'Pollo crujiente, mozzarella y salsa de tomate.', 9),
  ('Pizza El Rincón de Adda', 'Pizza El Rincón de Adda', 'PIZZAS', 750.00, 'Pollo, maíz dulce, vegetales frescos, champiñones y aceitunas negras.', 10),
  ('Pizza de Atún y Cebolla', 'Pizza de Atún y Cebolla', 'PIZZAS', 700.00, 'Atún, cebolla y queso mozzarella.', 11),
  ('Churrasco Prime Importado', 'Churrasco Prime Importado', 'CARNES', 1200.00, 'Jugoso corte de res Prime preparado a la parrilla.', 1),
  ('Flap Meat Prime Angus', 'Flap Meat Prime Angus', 'CARNES', 1700.00, 'Corte premium de gran sabor y excelente marmoleo, cocinado al grill.', 2),
  ('Picaña Prime Importada', 'Picaña Prime Importada', 'CARNES', 1100.00, 'Tradicional corte brasileño asado a la parrilla.', 3),
  ('Ribeye Prime Importado', 'Ribeye Prime Importado', 'CARNES', 2500.00, 'Corte premium de intenso marmoleo y extraordinaria jugosidad.', 4),
  ('T-Bone Angus Choice Importado', 'T-Bone Angus Choice Importado', 'CARNES', 2600.00, 'Clásico corte con filete y New York Strip en una sola pieza.', 5),
  ('Tomahawk Angus Choice Importado (2.5 lb)', 'Tomahawk Angus Choice Importado (2.5lb)', 'CARNES', 5000.00, 'Imponente corte con hueso largo, ideal para compartir.', 6),
  ('Pollo a la Plancha', 'Pollo a la Plancha', 'CARNES', 600.00, 'Pechuga marinada y cocinada a la plancha.', 7),
  ('Pechuga de Pollo a la Crema', 'Pechuga de Pollo a la Crema', 'CARNES', 600.00, 'Pechuga de pollo marinada con salsa a la crema.', 8),
  ('Pollo a la Torre', 'Pollo a la Torre', 'CARNES', 720.00, 'Pechuga de pollo a la plancha acompañada de berenjena, queso fresco y cebolla caramelizada.', 9),
  ('Lomo de Cerdo', 'Lomo de Cerdo', 'CARNES', 750.00, 'Preparado a la plancha o a la parrilla con salsa al brandy.', 10),
  ('Chuleta de Cerdo', 'Chuleta de Cerdo', 'CARNES', 600.00, 'Jugosa chuleta de cerdo a la parrilla en salsa brandy.', 11),
  ('Costillas de Cerdo', 'Costillas de Cerdo', 'CARNES', 600.00, 'Costillas tiernas cocinadas lentamente hasta alcanzar su máxima suavidad.', 12),
  ('Chillo Entero', 'Chillo Entero', 'PESCADOS Y MARISCOS', 1500.00, 'Disponible frito o al vapor.', 1),
  ('Filete de Mero Barsa', 'Filete de Mero Barsa', 'PESCADOS Y MARISCOS', 700.00, 'Delicado filete de mero preparado a su elección.', 2),
  ('Lomo de Atún Rojo', 'Lomo de Atún Rojo', 'PESCADOS Y MARISCOS', 1200.00, 'Atún rojo fresco sellado a la perfección.', 3),
  ('Filete de Salmón', 'Filete de Salmón', 'PESCADOS Y MARISCOS', 1000.00, 'Salmón fresco preparado a la plancha o al grill.', 4),
  ('Filete de Salmón en Salsa de Ajo', 'Filete de Salmón (en salsa de ajo)', 'PESCADOS Y MARISCOS', 1000.00, 'Salmón fresco preparado a la plancha o al grill en salsa de ajo.', 5),
  ('Lambí', 'Lambí', 'PESCADOS Y MARISCOS', 700.00, 'Preparado a la criolla, en vinagreta o en salsa cremosa.', 6),
  ('Ceviche de Mero', 'Ceviche de Mero', 'PESCADOS Y MARISCOS', 600.00, 'Mero fresco marinado en jugo de limón con cebolla morada, cilantro y ají.', 7),
  ('Masa de Cangrejo', 'Masa de Cangrejo', 'PESCADOS Y MARISCOS', 950.00, 'Preparada al estilo criollo.', 8),
  ('Camarones', 'Camarones', 'PESCADOS Y MARISCOS', 900.00, 'A elegir: al grill, a la criolla, en vinagreta o en salsa cremosa.', 9),
  ('Pulpo', 'Pulpo', 'PESCADOS Y MARISCOS', 900.00, 'Preparado al grill, a la criolla, en vinagreta o en salsa cremosa.', 10),
  ('Calamar a la Plancha', 'Calamar a la Plancha', 'PESCADOS Y MARISCOS', 850.00, 'Calamar fresco sellado a la plancha con finas hierbas.', 11),
  ('Aros de Calamar Salteados', 'Aros de calamar salteado', 'PESCADOS Y MARISCOS', 700.00, 'Aros de calamar salteados acompañados de salsa brandy.', 12),
  ('Cola de Langosta', 'Cola de Langosta', 'PESCADOS Y MARISCOS', 2200.00, 'Cola de langosta a la parrilla con mantequilla de ajo.', 13),
  ('Cazuela de Mariscos', 'Cazuela de Mariscos', 'PESCADOS Y MARISCOS', 1000.00, 'Exquisita combinación de camarones, calamares, mejillones y pescado fresco en una delicada salsa marinera.', 14),
  ('Sopa de Mariscos', 'Sopa de Mariscos', 'PESCADOS Y MARISCOS', 1000.00, 'Combinación de camarones, calamares, mejillones y pescado fresco.', 15),
  ('Salpicón de Mariscos', 'Salpicón de Mariscos', 'PESCADOS Y MARISCOS', 950.00, 'Camarones, calamares, mejillones y pescado fresco.', 16),
  ('Lambí y Pulpo', 'Lambí y Pulpo', 'PESCADOS Y MARISCOS', 800.00, 'Mezcla de lambí y pulpo en la salsa de su preferencia.', 17),
  ('Mejillones al Vapor', 'Mejillones al Vapor', 'PESCADOS Y MARISCOS', 600.00, 'Mejillones frescos cocidos al vapor con ajo.', 18),
  ('Parrillada Mar y Tierra (2 personas)', 'Parrillada Mar y Tierra x2P', 'ESPECIALIDADES', 2500.00, 'Combinación de carnes premium y mariscos frescos para compartir.', 1),
  ('Parrillada Mixta (2 personas)', 'Parrillada Mixta x2P', 'ESPECIALIDADES', 1800.00, 'Selección de carnes a la parrilla acompañadas de guarniciones.', 2),
  ('Parrillada de Mariscos (2 personas)', 'Parrillada de Mariscos x2P', 'ESPECIALIDADES', 2600.00, 'Exquisita variedad de mariscos frescos preparados a la parrilla.', 3),
  ('Paella (2 personas)', 'Paella x2P', 'ESPECIALIDADES', 2500.00, 'Arroz preparado con mariscos y vegetales, sazonado con especias.', 4),
  ('Mofongo de Camarones', 'Mofongo de Camarones', 'ESPECIALIDADES', 800.00, 'Mofongo de plátano verde con camarones salteados en cremosa salsa.', 5),
  ('Mofongo de Pollo', 'Mofongo de Pollo', 'ESPECIALIDADES', 600.00, 'Mofongo de plátano verde acompañado de pollo salteado en cremosa salsa.', 6),
  ('Arroz Blanco', 'Arroz Blanco', 'GUARNICIONES', 100.00, null, 1),
  ('Vegetales', 'Vegetales al grill, salteados o al vapor', 'GUARNICIONES', 100.00, 'Al grill, salteados o al vapor.', 2),
  ('Papas', 'Papas fritas, salteadas, al vapor o en puré', 'GUARNICIONES', 100.00, 'Fritas, salteadas, al vapor o en puré.', 3),
  ('Tostones', 'Tostones', 'GUARNICIONES', 100.00, null, 4),
  ('Pan con Ajo', 'Pan con Ajo', 'GUARNICIONES', 150.00, null, 5),
  ('Addana Apple', 'Addana Apple', 'TRAGOS PROPIOS', 500.00, null, 1),
  ('Addita', 'Addita', 'TRAGOS PROPIOS', 400.00, null, 2),
  ('Papá Chelo', 'Papá Chelo', 'TRAGOS PROPIOS', 600.00, null, 3),
  ('La Ex', 'La Ex', 'TRAGOS PROPIOS', 450.00, null, 4),
  ('La Rabiosa', 'La Rabiosa', 'TRAGOS PROPIOS', 450.00, null, 5),
  ('La Insoportable', 'La Insoportable', 'TRAGOS PROPIOS', 350.00, null, 6),
  ('Piña Colada', 'Piña Colada', 'TRAGOS TRADICIONALES', 400.00, 'Sin alcohol $400 · con alcohol $450.', 1),
  ('Watermelon Sunset', 'Watermelon Sunset', 'TRAGOS TRADICIONALES', 350.00, null, 2),
  ('Wild Forest', 'Wild Forest', 'TRAGOS TRADICIONALES', 400.00, null, 3),
  ('Ruso Blanco', 'Ruso Blanco', 'TRAGOS TRADICIONALES', 500.00, null, 4),
  ('Ruso Negro', 'Ruso Negro', 'TRAGOS TRADICIONALES', 450.00, null, 5),
  ('Vodka Sunrise', 'Vodka Sunrise', 'TRAGOS TRADICIONALES', 500.00, null, 6),
  ('Vodka Tonic', 'Vodka Tonic', 'TRAGOS TRADICIONALES', 450.00, null, 7),
  ('Screwdriver', 'Screwdriver', 'TRAGOS TRADICIONALES', 500.00, null, 8),
  ('Pink Tonic', 'Pink Tonic', 'TRAGOS TRADICIONALES', 600.00, null, 9),
  ('Gin Tonic', 'Gin Tonic', 'TRAGOS TRADICIONALES', 500.00, null, 10),
  ('Mojito de Pitahaya', 'Mojito de Pitahaya', 'TRAGOS TRADICIONALES', 550.00, null, 11),
  ('Mojito de Limón', 'Mojito de Limón', 'TRAGOS TRADICIONALES', 550.00, null, 12),
  ('Mojito de Morir Soñando', 'Mojito de Morir Soñando', 'TRAGOS TRADICIONALES', 550.00, null, 13),
  ('Mojito de Chinola', 'Mojito de Chinola', 'TRAGOS TRADICIONALES', 600.00, null, 14),
  ('Margarita de Limón', 'Margarita de Limón', 'TRAGOS TRADICIONALES', 500.00, null, 15),
  ('Margarita de Fresa', 'Margarita de Fresa', 'TRAGOS TRADICIONALES', 500.00, null, 16),
  ('Margarita de Chinola', 'Margarita de Chinola', 'TRAGOS TRADICIONALES', 600.00, null, 17),
  ('Cuba Libre', 'Cuba Libre', 'TRAGOS TRADICIONALES', 500.00, null, 18),
  ('Cuba Libre Doble Reserva', 'Cuba Libre Doble Reserva', 'TRAGOS TRADICIONALES', 600.00, null, 19),
  ('Smoothie de Fresa', 'Smoothie de Fresa', 'TRAGOS TRADICIONALES', 450.00, 'Sin alcohol $450 · con alcohol $500.', 20),
  ('Limonada Coco', 'Limonada Coco', 'TRAGOS TRADICIONALES', 500.00, null, 21),
  ('Sangría', 'Sangría', 'TRAGOS TRADICIONALES', 400.00, null, 22),
  ('Frozen', 'Frozen', 'TRAGOS TRADICIONALES', 250.00, null, 23),
  ('Shot de Canelilla', 'Shot de Canelilla', 'SHOTS', 200.00, null, 1),
  ('Shot de Barceló', 'Shot de Barceló', 'SHOTS', 300.00, null, 2),
  ('Shot de Baileys', 'Shot de Baileys', 'SHOTS', 300.00, null, 3),
  ('Shot de Tequila', 'Shot de Tequila', 'SHOTS', 300.00, null, 4),
  ('Trago Johnnie Walker Black Label', 'Trago Johnny Walker Black Label', 'SHOTS', 450.00, null, 5),
  ('Trago Old Parr', 'Trago Old Parr', 'SHOTS', 350.00, null, 6),
  ('Trago Jack Daniel''s', 'Trago Jack Daniel''s', 'SHOTS', 500.00, null, 7),
  ('Porto Tinto', 'Porto Tinto', 'VINOS', 3500.00, null, 1),
  ('Casillero del Diablo Tinto Merlot', 'Casillero del Diablo Tinto Merlot', 'VINOS', 1400.00, null, 2),
  ('Bogle Tinto', 'Bogle Tinto', 'VINOS', 2500.00, null, 3),
  ('Casillero del Diablo Cabernet Tinto', 'Casillero del Diablo Cabernet Tinto', 'VINOS', 1500.00, null, 4),
  ('19 Crimes', '19 Crimemenes', 'VINOS', 2500.00, null, 5),
  ('Carlo Rossi', 'Carlo Rossi', 'VINOS', 1000.00, null, 6),
  ('Copa de Vino de la Casa', 'Copa de Vino de la Casa', 'VINOS', 300.00, null, 7),
  ('Copa de Vino Porto', 'Copa de Vino Porto', 'VINOS', 800.00, null, 8),
  ('Copa de Vino 19 Crimes', 'Copa de Vino 19 Crimes', 'VINOS', 800.00, null, 9),
  ('Copa de Vino Casillero del Diablo', 'Copa de Vino Casillero del Diablo', 'VINOS', 800.00, null, 10),
  ('Copa de Vino Bogle', 'Copa de Vino Bogle', 'VINOS', 500.00, null, 11),
  ('Cerveza Corona', 'Cerveza Corona', 'CERVEZAS', 250.00, null, 1),
  ('Cerveza Presidente', 'Cerveza Presidente', 'CERVEZAS', 200.00, null, 2),
  ('Cerveza Smirnoff', 'Cerveza Smirnoff', 'CERVEZAS', 250.00, null, 3),
  ('Cerveza Modelo', 'Cerveza Modelo', 'CERVEZAS', 250.00, null, 4),
  ('Jugo de Sandía con Limón', 'Jugo de Sandía con Limón', 'BEBIDAS', 200.00, null, 1),
  ('Limonada Natural', 'JUGO DE LIMON', 'BEBIDAS', 150.00, null, 2),
  ('Jugo de Chinola', 'Jugo de Chinola', 'BEBIDAS', 150.00, null, 3),
  ('Jugo de Piña', 'Jugo de Piña', 'BEBIDAS', 150.00, null, 4),
  ('Café Negro', 'Café Negro', 'BEBIDAS', 50.00, null, 5),
  ('AGUA DASANI', 'Agua', 'BEBIDAS', 50.00, null, 6),
  ('Enriquillo', 'Enriquillo', 'BEBIDAS', 50.00, null, 7),
  ('Agua Tónica', 'Agua Tónica', 'BEBIDAS', 50.00, null, 8),
  ('Refresco Coca Cola Peq.', 'Refresco Coca Cola Peq.', 'BEBIDAS', 50.00, null, 9),
  ('Refresco Merengue Peq.', 'Refresco Merengue Peq.', 'BEBIDAS', 50.00, null, 10),
  ('Refresco Naranja Peq.', 'Refresco Naranja Peq.', 'BEBIDAS', 50.00, null, 11),
  ('Refresco Seven Up Peq.', 'Refresco Seven Up Peq.', 'BEBIDAS', 50.00, null, 12),
  ('Refresco Sprite Peq.', 'Refresco Sprite Peq.', 'BEBIDAS', 50.00, null, 13),
  ('Refresco Coca Cola 2 Litros', 'Refresco Coca Cola 2 Litros', 'BEBIDAS', 250.00, null, 14)
;

drop table if exists _ra_grupos;
create temp table _ra_grupos (
  name  text not null,
  tipo  text not null check (tipo in ('uno', 'extra')),
  orden int  not null
);

insert into _ra_grupos (name, tipo, orden) values
  ('Tipo de pasta', 'uno', 1),
  ('Proteína para la pasta', 'extra', 2),
  ('Término de la carne', 'uno', 3),
  ('Plancha o parrilla', 'uno', 4),
  ('Frito o al vapor', 'uno', 5),
  ('Preparación del marisco', 'uno', 6),
  ('Salsa a elegir', 'uno', 7),
  ('Vegetales', 'uno', 8),
  ('Papas', 'uno', 9),
  ('Con o sin alcohol', 'uno', 10)
;

drop table if exists _ra_opciones;
create temp table _ra_opciones (
  grupo text not null,
  name  text not null,
  delta numeric(12,2) not null,
  orden int  not null
);

insert into _ra_opciones (grupo, name, delta, orden) values
  ('Tipo de pasta', 'Linguine', 0.00, 1),
  ('Tipo de pasta', 'Espagueti', 0.00, 2),
  ('Tipo de pasta', 'Plumitas (Penne)', 0.00, 3),
  ('Tipo de pasta', 'Rigatoni', 0.00, 4),
  ('Proteína para la pasta', 'Pollo', 150.00, 1),
  ('Proteína para la pasta', 'Res', 200.00, 2),
  ('Proteína para la pasta', 'Mariscos (indicar cuál)', 400.00, 3),
  ('Término de la carne', 'Rojo', 0.00, 1),
  ('Término de la carne', 'Medio rojo', 0.00, 2),
  ('Término de la carne', 'Término medio', 0.00, 3),
  ('Término de la carne', 'Tres cuartos', 0.00, 4),
  ('Término de la carne', 'Bien cocido', 0.00, 5),
  ('Plancha o parrilla', 'A la plancha', 0.00, 1),
  ('Plancha o parrilla', 'A la parrilla', 0.00, 2),
  ('Frito o al vapor', 'Frito', 0.00, 1),
  ('Frito o al vapor', 'Al vapor', 0.00, 2),
  ('Preparación del marisco', 'Al grill', 0.00, 1),
  ('Preparación del marisco', 'A la criolla', 0.00, 2),
  ('Preparación del marisco', 'En vinagreta', 0.00, 3),
  ('Preparación del marisco', 'En salsa cremosa', 0.00, 4),
  ('Salsa a elegir', 'A la criolla', 0.00, 1),
  ('Salsa a elegir', 'En vinagreta', 0.00, 2),
  ('Salsa a elegir', 'En salsa cremosa', 0.00, 3),
  ('Vegetales', 'Al grill', 0.00, 1),
  ('Vegetales', 'Salteados', 0.00, 2),
  ('Vegetales', 'Al vapor', 0.00, 3),
  ('Papas', 'Fritas', 0.00, 1),
  ('Papas', 'Salteadas', 0.00, 2),
  ('Papas', 'Al vapor', 0.00, 3),
  ('Papas', 'En puré', 0.00, 4),
  ('Con o sin alcohol', 'Sin alcohol', 0.00, 1),
  ('Con o sin alcohol', 'Con alcohol', 50.00, 2)
;

drop table if exists _ra_asig;
create temp table _ra_asig (
  producto text not null,
  grupo    text not null,
  orden    int  not null
);

insert into _ra_asig (producto, grupo, orden) values
  ('Pasta Alfredo', 'Tipo de pasta', 1),
  ('Pasta Alfredo', 'Proteína para la pasta', 2),
  ('Pasta Carbonara', 'Tipo de pasta', 1),
  ('Pasta Carbonara', 'Proteína para la pasta', 2),
  ('Pasta Marinara', 'Tipo de pasta', 1),
  ('Pasta Marinara', 'Proteína para la pasta', 2),
  ('Pasta Caprese', 'Tipo de pasta', 1),
  ('Pasta Caprese', 'Proteína para la pasta', 2),
  ('Pasta a la Crema', 'Tipo de pasta', 1),
  ('Pasta a la Crema', 'Proteína para la pasta', 2),
  ('Pasta Cuatro Quesos', 'Tipo de pasta', 1),
  ('Pasta Cuatro Quesos', 'Proteína para la pasta', 2),
  ('Churrasco Prime Importado', 'Término de la carne', 1),
  ('Flap Meat Prime Angus', 'Término de la carne', 1),
  ('Picaña Prime Importada', 'Término de la carne', 1),
  ('Ribeye Prime Importado', 'Término de la carne', 1),
  ('T-Bone Angus Choice Importado', 'Término de la carne', 1),
  ('Tomahawk Angus Choice Importado (2.5 lb)', 'Término de la carne', 1),
  ('Lomo de Cerdo', 'Plancha o parrilla', 1),
  ('Chillo Entero', 'Frito o al vapor', 1),
  ('Filete de Salmón', 'Plancha o parrilla', 1),
  ('Filete de Salmón en Salsa de Ajo', 'Plancha o parrilla', 1),
  ('Lambí', 'Salsa a elegir', 1),
  ('Camarones', 'Preparación del marisco', 1),
  ('Pulpo', 'Preparación del marisco', 1),
  ('Lambí y Pulpo', 'Salsa a elegir', 1),
  ('Vegetales', 'Vegetales', 1),
  ('Papas', 'Papas', 1),
  ('Piña Colada', 'Con o sin alcohol', 1),
  ('Smoothie de Fresa', 'Con o sin alcohol', 1)
;

do $$
declare
  v_business  uuid := '8cb85c65-ae49-4384-a678-0d8a201a955e';
  v_esperados int;
  v_itbis_id  uuid;
  v_ley_id    uuid;
  v_kitchen   boolean;
  v_cocina_id   uuid;
  v_cocina_code text;
  v_bar_id      uuid;
  v_bar_code    text;
  v_menu_id   uuid;
  v_n         int;
  v_apagadas  int;
  v_list      text;
begin
  select count(*) into v_esperados from _ra_productos;

  -- =========================================================================
  -- 1) GUARDAS: se comprueba todo ANTES de escribir una sola fila.
  -- =========================================================================

  -- 1a) El negocio existe.
  if not exists (select 1 from public.businesses where id = v_business) then
    raise exception 'El negocio % no existe.', v_business;
  end if;

  -- 1b) La carta es coherente: nombres sin repetir (ni entre nombre y nombre
  --     impreso), categorías, grupos y opciones que existen en la lista.
  select string_agg(k, ', ') into v_list
  from (select k from (select pg_temp.norm(name) as k, name as dueno from _ra_productos
                       union
                       select pg_temp.norm(alias), name from _ra_productos) x
        group by k having count(distinct dueno) > 1) d;
  if v_list is not null then
    raise exception 'La carta trae nombres repetidos: %', v_list;
  end if;

  if exists (select 1 from _ra_productos p
             where not exists (select 1 from _ra_categorias c where c.name = p.categoria))
  or exists (select 1 from _ra_asig a
             where not exists (select 1 from _ra_grupos g where g.name = a.grupo)
                or not exists (select 1 from _ra_productos p where p.name = a.producto))
  or exists (select 1 from _ra_opciones o
             where not exists (select 1 from _ra_grupos g where g.name = o.grupo))
  or exists (select 1 from _ra_grupos g
             where not exists (select 1 from _ra_opciones o where o.grupo = g.name)) then
    raise exception 'La lista está incompleta (categoría, grupo u opción sin definir).';
  end if;

  -- 1c) Un ITBIS 18% activo, y uno solo, sin is_service_fee.
  select count(*) into v_n
  from public.taxes t
  where t.business_id = v_business
    and t.name ilike '%itbis%'
    and t.rate = 18
    and coalesce(t.is_active, true);

  if v_n <> 1 then
    select string_agg(format('%s %s%% (%s)', t.name, t.rate,
             case when coalesce(t.is_active, true) then 'activo' else 'INACTIVO' end),
           ', ')
      into v_list
    from public.taxes t
    where t.business_id = v_business;

    raise exception
      'Debe haber UN ITBIS 18%% activo y hay % (impuestos del negocio: %). '
      'Créalo o deja uno solo en la app (Ajustes → Impuestos) y vuelve a correr.',
      v_n, coalesce(v_list, 'ninguno');
  end if;

  select t.id into v_itbis_id
  from public.taxes t
  where t.business_id = v_business
    and t.name ilike '%itbis%'
    and t.rate = 18
    and coalesce(t.is_active, true);

  if exists (select 1 from public.taxes
             where id = v_itbis_id and coalesce(is_service_fee, false)) then
    raise exception
      'El ITBIS tiene is_service_fee = true: la factura lo cobraría DOS veces.';
  end if;

  -- 1d) Una Ley 10% activa (cualquier impuesto del 10% que no sea ITBIS).
  select count(*), string_agg(t.name, ', ')
    into v_n, v_list
  from public.taxes t
  where t.business_id = v_business
    and t.rate = 10
    and t.name not ilike '%itbis%'
    and coalesce(t.is_active, true);

  if v_n <> 1 then
    raise exception
      'Debe haber UNA Ley 10%% activa y hay % (%). '
      'Créala o deja una sola en la app (Ajustes → Impuestos) y vuelve a correr.',
      v_n, coalesce(v_list, 'ninguna');
  end if;

  select t.id into v_ley_id
  from public.taxes t
  where t.business_id = v_business
    and t.rate = 10
    and t.name not ilike '%itbis%'
    and coalesce(t.is_active, true);

  if exists (select 1 from public.taxes
             where id = v_ley_id and coalesce(is_service_fee, false)) then
    raise exception
      'La Ley tiene is_service_fee = true: vinculada al producto se factura DOBLE.';
  end if;

  if exists (select 1 from public.business_settings
             where business_id = v_business
               and coalesce(service_fee_enabled, false)) then
    raise exception
      'service_fee_enabled está en true: la Ley saldría por producto Y por orden.';
  end if;

  -- 1e) Emparejamiento con el catálogo actual: por nombre o por nombre
  --     impreso. Cada renglón de la carta puede caer en UN producto como
  --     mucho, y cada producto en UN renglón.
  drop table if exists _ra_cand;
  create temp table _ra_cand on commit drop as
  select p.name, mi.id as item_id, mi.name as item_name
  from _ra_productos p
  join public.menu_items mi
    on mi.business_id = v_business
   and pg_temp.norm(mi.name) in (pg_temp.norm(p.name), pg_temp.norm(p.alias));

  select string_agg(format('%s → %s', name, nombres), '; ') into v_list
  from (select name, string_agg(item_name, ' / ' order by item_name) as nombres
        from _ra_cand group by name having count(*) > 1) d;
  if v_list is not null then
    raise exception
      'Estos renglones caen en VARIOS productos del catálogo, no sé cuál actualizar: %', v_list;
  end if;

  select string_agg(format('%s ← %s', item_name, nombres), '; ') into v_list
  from (select item_name, string_agg(name, ', ' order by name) as nombres
        from _ra_cand group by item_id, item_name having count(*) > 1) d;
  if v_list is not null then
    raise exception
      'Estos productos del catálogo caen en VARIOS renglones de la carta: %', v_list;
  end if;

  -- 1f) Grupos de modificadores: a lo sumo uno por nombre.
  select string_agg(format('%s (%s)', g.name, x.n), ', ') into v_list
  from _ra_grupos g
  cross join lateral (
    select count(*) as n from public.modifier_groups m
    where m.business_id = v_business and pg_temp.norm(m.name) = pg_temp.norm(g.name)
  ) x
  where x.n > 1;
  if v_list is not null then
    raise exception 'Hay grupos de modificadores repetidos, no sé cuál usar: %', v_list;
  end if;

  -- 1g) Menú: 0 se crea, 1 se reusa, más de 1 aborta.
  select count(*), string_agg(name, ', ' order by created_at) into v_n, v_list
  from public.menus
  where business_id = v_business and coalesce(is_active, true);

  if v_n > 1 then
    raise exception
      'El negocio tiene % menús activos (%). Dime a cuál van los productos.', v_n, v_list;
  end if;

  -- 1h) Áreas de comanda (ver encabezado).
  select coalesce(bs.kitchen_enabled, true) into v_kitchen
  from public.business_settings bs
  where bs.business_id = v_business;
  v_kitchen := coalesce(v_kitchen, true);

  if v_kitchen then
    -- COCINA
    select a.id, a.code into v_cocina_id, v_cocina_code
    from public.print_areas a
    where a.business_id = v_business
      and a.is_active
      and (a.code in ('cocina', 'kitchen', 'kitchen_hot', 'comida')
           or pg_temp.norm(a.name) in ('cocina', 'kitchen', 'comida'))
    order by (a.code = 'cocina') desc, (a.code = 'kitchen') desc, a.created_at
    limit 1;

    if v_cocina_id is null then
      select a.id, a.code into v_cocina_id, v_cocina_code
      from public.print_areas a
      where a.business_id = v_business
        and (a.code in ('cocina', 'kitchen', 'kitchen_hot', 'comida')
             or pg_temp.norm(a.name) in ('cocina', 'kitchen', 'comida'))
      order by (a.code = 'cocina') desc, a.created_at
      limit 1;

      if v_cocina_id is not null then
        update public.print_areas set is_active = true where id = v_cocina_id;
      elsif exists (select 1 from public.print_areas
                    where business_id = v_business and code = 'cocina') then
        raise exception 'Ya hay un área con code "cocina" que no se reconoce. Revísala.';
      else
        v_cocina_id   := gen_random_uuid();
        v_cocina_code := 'cocina';
        insert into public.print_areas (id, business_id, name, code, is_active)
        values (v_cocina_id, v_business, 'Cocina', v_cocina_code, true);
      end if;
    end if;

    -- BAR
    select a.id, a.code into v_bar_id, v_bar_code
    from public.print_areas a
    where a.business_id = v_business
      and a.is_active
      and (a.code in ('bar', 'barra') or pg_temp.norm(a.name) in ('bar', 'barra'))
    order by (a.code = 'bar') desc, a.created_at
    limit 1;

    if v_bar_id is null then
      select a.id, a.code into v_bar_id, v_bar_code
      from public.print_areas a
      where a.business_id = v_business
        and (a.code in ('bar', 'barra') or pg_temp.norm(a.name) in ('bar', 'barra'))
      order by (a.code = 'bar') desc, a.created_at
      limit 1;

      if v_bar_id is not null then
        update public.print_areas set is_active = true where id = v_bar_id;
      elsif exists (select 1 from public.print_areas
                    where business_id = v_business and code = 'bar') then
        raise exception 'Ya hay un área con code "bar" que no se reconoce. Revísala.';
      else
        v_bar_id   := gen_random_uuid();
        v_bar_code := 'bar';
        insert into public.print_areas (id, business_id, name, code, is_active)
        values (v_bar_id, v_business, 'Bar', v_bar_code, true);
      end if;
    end if;

    if v_cocina_id = v_bar_id then
      raise exception 'La cocina y el bar cayeron en la MISMA área (%). Revísalas.', v_bar_code;
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
  -- 3) CATEGORÍAS: crea las que falten; las que ya existen se respetan
  --    (nombre y posición), solo se reactivan.
  -- =========================================================================

  insert into public.categories (id, business_id, name, position, is_active)
  select gen_random_uuid(), v_business, c.name, c.posicion, true
  from _ra_categorias c
  where not exists (
    select 1 from public.categories x
    where x.business_id = v_business
      and pg_temp.norm(x.name) = pg_temp.norm(c.name)
  );

  update public.categories x
  set is_active = true
  from _ra_categorias c
  where x.business_id = v_business
    and pg_temp.norm(x.name) = pg_temp.norm(c.name)
    and not x.is_active;

  -- =========================================================================
  -- 4) PRODUCTOS: actualiza los que ya existen, inserta los que faltan.
  --    print_area_code se escribe aquí mismo. El que se encontró por el
  --    nombre impreso se renombra; el costo del que ya existe no se toca.
  -- =========================================================================

  drop table if exists _ra_dest;
  create temp table _ra_dest on commit drop as
  select p.name, cat.id as category_id, c.area,
         case c.area when 'cocina' then v_cocina_code else v_bar_code end as area_code,
         case c.area when 'cocina' then v_cocina_id   else v_bar_id   end as area_id
  from _ra_productos p
  join _ra_categorias c on c.name = p.categoria
  cross join lateral (
    select x.id from public.categories x
    where x.business_id = v_business
      and pg_temp.norm(x.name) = pg_temp.norm(p.categoria)
    order by x.is_active desc, x.created_at
    limit 1
  ) cat;

  update public.menu_items mi
  set name            = case when pg_temp.norm(mi.name) = pg_temp.norm(p.name)
                             then mi.name else p.name end,
      price           = p.price,
      description     = p.descripcion,
      category_id     = d.category_id,
      tax_mode        = 'inclusive',
      is_active       = true,
      is_beverage     = (d.area = 'bar'),
      position        = p.posicion,
      print_area_code = d.area_code,
      updated_at      = now()
  from _ra_cand c
  join _ra_productos p on p.name = c.name
  join _ra_dest d on d.name = c.name
  where mi.id = c.item_id;

  insert into public.menu_items (
    id, business_id, category_id, name, price, description,
    tax_mode, is_active, is_beverage, position, print_area_code
  )
  select gen_random_uuid(), v_business, d.category_id, p.name, p.price, p.descripcion,
         'inclusive', true, (d.area = 'bar'), p.posicion, d.area_code
  from _ra_productos p
  join _ra_dest d on d.name = p.name
  where not exists (select 1 from _ra_cand c where c.name = p.name);

  drop table if exists _ra_ids;
  create temp table _ra_ids on commit drop as
  select mi.id, p.name
  from public.menu_items mi
  join _ra_productos p on pg_temp.norm(p.name) = pg_temp.norm(mi.name)
  where mi.business_id = v_business;

  -- =========================================================================
  -- 5) IMPUESTOS: ITBIS 18% + Ley 10%, nada más.
  -- =========================================================================

  delete from public.menu_item_taxes mit
  using _ra_ids i
  where mit.item_id = i.id
    and mit.tax_id not in (v_itbis_id, v_ley_id);

  insert into public.menu_item_taxes (item_id, tax_id)
  select i.id, t.id
  from _ra_ids i
  cross join (values (v_itbis_id), (v_ley_id)) t(id)
  where not exists (
    select 1 from public.menu_item_taxes x
    where x.item_id = i.id and x.tax_id = t.id
  );

  -- =========================================================================
  -- 6) ÁREA DE COMANDA (N:M). El legacy ya quedó escrito en el paso 4.
  --    Se borran asignaciones a otras áreas: si no, el producto saldría por
  --    DOS impresoras. Con cocina apagada no queda ninguna.
  -- =========================================================================

  delete from public.menu_item_print_areas x
  using _ra_ids i
  join _ra_dest d on d.name = i.name
  where x.menu_item_id = i.id
    and x.print_area_id is distinct from d.area_id;

  insert into public.menu_item_print_areas (menu_item_id, print_area_id)
  select i.id, d.area_id
  from _ra_ids i
  join _ra_dest d on d.name = i.name
  where d.area_id is not null
    and not exists (
      select 1 from public.menu_item_print_areas x
      where x.menu_item_id = i.id and x.print_area_id = d.area_id
    );

  -- =========================================================================
  -- 7) ENLACE AL MENÚ: sin esto el producto no aparece en la caja.
  -- =========================================================================

  insert into public.menu_item_links (menu_id, item_id, position)
  select v_menu_id, i.id, p.posicion
  from _ra_ids i
  join _ra_productos p on p.name = i.name
  where not exists (
    select 1 from public.menu_item_links l
    where l.menu_id = v_menu_id and l.item_id = i.id
  );

  -- =========================================================================
  -- 8) MODIFICADORES
  --    'uno'   → single, min = max = 1, obligatorio: la caja no deja agregar
  --              el producto sin escoger ("Debes completar: ...").
  --    'extra' → multiple, min 0, sin máximo (max 0), opcional.
  -- =========================================================================

  insert into public.modifier_groups (
    id, business_id, name, min_select, max_select, is_active,
    display_type, selection_mode, is_required, free_qty, max_qty_per_option, sort_order
  )
  select gen_random_uuid(), v_business, g.name,
         case g.tipo when 'uno' then 1 else 0 end,
         case g.tipo when 'uno' then 1 else 0 end,
         true,
         case g.tipo when 'uno' then 'single' else 'multiple' end,
         case g.tipo when 'uno' then 'modifier' else 'extra' end,
         (g.tipo = 'uno'), 0, 1,
         case g.tipo when 'uno' then 10 else 20 end
  from _ra_grupos g
  where not exists (select 1 from public.modifier_groups m
                    where m.business_id = v_business
                      and pg_temp.norm(m.name) = pg_temp.norm(g.name));

  update public.modifier_groups m
  set min_select   = case g.tipo when 'uno' then 1 else 0 end,
      max_select   = case g.tipo when 'uno' then 1 else 0 end,
      is_active    = true,
      display_type = case g.tipo when 'uno' then 'single' else 'multiple' end,
      is_required  = (g.tipo = 'uno')
  from _ra_grupos g
  where m.business_id = v_business
    and pg_temp.norm(m.name) = pg_temp.norm(g.name)
    and (m.min_select, m.max_select, m.is_active, m.display_type, m.is_required)
        is distinct from (case g.tipo when 'uno' then 1 else 0 end,
                          case g.tipo when 'uno' then 1 else 0 end,
                          true,
                          case g.tipo when 'uno' then 'single' else 'multiple' end,
                          (g.tipo = 'uno'));

  drop table if exists _ra_gids;
  create temp table _ra_gids on commit drop as
  select g.name, g.tipo, m.id
  from _ra_grupos g
  join public.modifier_groups m
    on m.business_id = v_business and pg_temp.norm(m.name) = pg_temp.norm(g.name);

  drop table if exists _ra_ops;
  create temp table _ra_ops on commit drop as
  select gi.id as group_id, o.name, o.delta, o.orden
  from _ra_opciones o
  join _ra_gids gi on gi.name = o.grupo;

  insert into public.modifiers (id, business_id, group_id, name, price_delta, is_active, sort_order)
  select gen_random_uuid(), v_business, o.group_id, o.name, o.delta, true, o.orden
  from _ra_ops o
  where not exists (select 1 from public.modifiers m
                    where m.group_id = o.group_id
                      and pg_temp.norm(m.name) = pg_temp.norm(o.name));

  update public.modifiers m
  set price_delta = o.delta, is_active = true, sort_order = o.orden
  from _ra_ops o
  where m.group_id = o.group_id and pg_temp.norm(m.name) = pg_temp.norm(o.name)
    and (m.price_delta, m.is_active, m.sort_order) is distinct from (o.delta, true, o.orden);

  -- Opciones de estos grupos que no están en la lista: se apagan (la lista
  -- manda). No se borran: pueden estar en ventas.
  update public.modifiers m
  set is_active = false
  from _ra_gids gi
  where m.group_id = gi.id
    and m.is_active
    and not exists (select 1 from _ra_ops o
                    where o.group_id = m.group_id
                      and pg_temp.norm(o.name) = pg_temp.norm(m.name));
  get diagnostics v_apagadas = row_count;

  drop table if exists _ra_asig_ids;
  create temp table _ra_asig_ids on commit drop as
  select i.id as item_id, gi.id as group_id, a.orden
  from _ra_asig a
  join _ra_ids i on i.name = a.producto
  join _ra_gids gi on gi.name = a.grupo;

  -- Un producto de la carta enlazado a un grupo de esta lista que ya no le
  -- toca: se desenlaza. Los grupos que no son de esta lista no se tocan.
  delete from public.menu_item_groups y
  using _ra_ids i, _ra_gids gi
  where y.menu_item_id = i.id
    and y.group_id = gi.id
    and not exists (select 1 from _ra_asig_ids a
                    where a.item_id = y.menu_item_id and a.group_id = y.group_id);

  insert into public.menu_item_groups (menu_item_id, group_id)
  select a.item_id, a.group_id
  from _ra_asig_ids a
  where not exists (select 1 from public.menu_item_groups y
                    where y.menu_item_id = a.item_id and y.group_id = a.group_id);

  -- Orden de los grupos dentro del producto (tipo de pasta antes que la
  -- proteína). La columna está en prod pero no en las migraciones del repo.
  if exists (select 1 from information_schema.columns
             where table_schema = 'public' and table_name = 'menu_item_groups'
               and column_name = 'position') then
    execute $q$
      update public.menu_item_groups y
      set position = a.orden
      from _ra_asig_ids a
      where y.menu_item_id = a.item_id and y.group_id = a.group_id
        and y.position is distinct from a.orden
    $q$;
  end if;

  -- =========================================================================
  -- 9) VERIFICACIÓN DENTRO DE LA TRANSACCIÓN: cualquier fallo revierte TODO.
  -- =========================================================================

  select count(*) into v_n
  from _ra_productos p
  where (select count(*) from _ra_ids i
         join public.menu_items mi on mi.id = i.id
         where i.name = p.name and mi.is_active) <> 1;
  if v_n > 0 or (select count(*) from _ra_ids) <> v_esperados then
    raise exception '% productos de la carta no quedaron (o quedaron repetidos). Revertido.', v_n;
  end if;

  select count(*) into v_n
  from _ra_ids i
  join public.menu_items mi on mi.id = i.id
  join _ra_productos p on p.name = i.name
  join _ra_dest d on d.name = i.name
  where mi.price <> p.price
     or mi.description is distinct from p.descripcion
     or mi.tax_mode <> 'inclusive'
     or mi.category_id is distinct from d.category_id
     or mi.is_beverage <> (d.area = 'bar');
  if v_n > 0 then
    raise exception '% productos con precio, descripción, impuesto o categoría incorrectos. Revertido.', v_n;
  end if;

  select count(*) into v_n
  from _ra_ids i
  where (select count(*) from public.menu_item_taxes x where x.item_id = i.id) <> 2
     or not exists (select 1 from public.menu_item_taxes x
                    where x.item_id = i.id and x.tax_id = v_itbis_id)
     or not exists (select 1 from public.menu_item_taxes x
                    where x.item_id = i.id and x.tax_id = v_ley_id);
  if v_n > 0 then
    raise exception '% productos sin el juego ITBIS + Ley exacto. Revertido.', v_n;
  end if;

  select count(*) into v_n
  from _ra_ids i
  join public.menu_items mi on mi.id = i.id
  join _ra_dest d on d.name = i.name
  where mi.print_area_code is distinct from d.area_code
     or (select count(*) from public.menu_item_print_areas x
         where x.menu_item_id = i.id) <> case when d.area_id is null then 0 else 1 end
     or (d.area_id is not null
         and not exists (select 1 from public.menu_item_print_areas x
                         where x.menu_item_id = i.id and x.print_area_id = d.area_id));
  if v_n > 0 then
    raise exception '% productos sin área de comanda o con legacy y N:M en desacuerdo. Revertido.', v_n;
  end if;

  select count(*) into v_n
  from _ra_ids i
  where not exists (select 1 from public.menu_item_links l
                    where l.menu_id = v_menu_id and l.item_id = i.id);
  if v_n > 0 then
    raise exception '% productos fuera del menú: no saldrían en la caja. Revertido.', v_n;
  end if;

  select count(*) into v_n
  from _ra_gids gi
  join public.modifier_groups m on m.id = gi.id
  where (m.min_select, m.max_select, m.display_type, m.is_required, m.is_active)
        is distinct from (case gi.tipo when 'uno' then 1 else 0 end,
                          case gi.tipo when 'uno' then 1 else 0 end,
                          case gi.tipo when 'uno' then 'single' else 'multiple' end,
                          (gi.tipo = 'uno'), true)
     or (select count(*) from public.modifiers x
         where x.group_id = gi.id and x.is_active)
        <> (select count(*) from _ra_ops o where o.group_id = gi.id)
     or exists (select 1 from _ra_ops o
                where o.group_id = gi.id
                  and not exists (select 1 from public.modifiers x
                                  where x.group_id = gi.id and x.is_active
                                    and pg_temp.norm(x.name) = pg_temp.norm(o.name)
                                    and x.price_delta = o.delta));
  if v_n > 0 or (select count(*) from _ra_gids) <> (select count(*) from _ra_grupos) then
    raise exception '% grupos de modificadores mal armados. Revertido.', v_n;
  end if;

  select count(*) into v_n
  from _ra_ids i
  where (select count(*) from public.menu_item_groups y
         join _ra_gids gi on gi.id = y.group_id
         where y.menu_item_id = i.id)
        <> (select count(*) from _ra_asig a where a.producto = i.name);
  if v_n > 0 or (select count(*) from _ra_asig_ids) <> (select count(*) from _ra_asig) then
    raise exception '% productos con los modificadores equivocados. Revertido.', v_n;
  end if;

  raise notice 'OK: % productos (% ya existían), % grupos, % opciones apagadas, cocina=%, bar=%. Commit.',
    v_esperados, (select count(*) from _ra_cand), (select count(*) from _ra_gids), v_apagadas,
    coalesce(v_cocina_code, 'ninguna (cocina apagada)'),
    coalesce(v_bar_code, 'ninguna (cocina apagada)');
end $$;

commit;

-- ============================================================================
-- REPORTE: todas las filas deben decir ✓
-- ============================================================================

with
biz as (
  select '8cb85c65-ae49-4384-a678-0d8a201a955e'::uuid as id
),
esperados as (
  select count(*)::int as n from _ra_productos
),
items as (
  select mi.*, p.name as renglon, p.price as precio_lista, c.area
  from public.menu_items mi
  join biz on mi.business_id = biz.id
  join _ra_productos p on pg_temp.norm(p.name) = pg_temp.norm(mi.name)
  join _ra_categorias c on c.name = p.categoria
  where mi.is_active
),
itbis as (
  select t.* from public.taxes t, biz
  where t.business_id = biz.id
    and t.name ilike '%itbis%' and t.rate = 18 and coalesce(t.is_active, true)
  limit 1
),
ley as (
  select t.* from public.taxes t, biz
  where t.business_id = biz.id
    and t.rate = 10 and t.name not ilike '%itbis%' and coalesce(t.is_active, true)
  limit 1
),
juegos as (
  select i.id,
         coalesce((select string_agg(format('%s %s%%', t.name, t.rate), ' + '
                                     order by t.rate desc, t.name)
                   from public.menu_item_taxes x
                   join public.taxes t on t.id = x.tax_id
                   where x.item_id = i.id), 'SIN IMPUESTO') as juego
  from items i
),
ajustes as (
  select coalesce((s.j->>'kitchen_enabled')::boolean, true) as cocina_encendida,
         coalesce((s.j->>'service_fee_enabled')::boolean, false) as ley_por_orden
  from (select to_jsonb(bs) as j from public.business_settings bs, biz
        where bs.business_id = biz.id
        union all
        select '{}'::jsonb
        where not exists (select 1 from public.business_settings bs, biz
                          where bs.business_id = biz.id)) s
),
ruta as (
  select i.area, a.id as area_id, a.name, a.code
  from items i
  join public.menu_item_print_areas x on x.menu_item_id = i.id
  join public.print_areas a on a.id = x.print_area_id
),
grupos as (
  select g.name, g.tipo, m.id, m.min_select, m.max_select, m.display_type, m.is_required,
         (select count(*) from public.modifiers x where x.group_id = m.id and x.is_active) as opciones,
         (select count(*) from _ra_opciones o where o.grupo = g.name) as opciones_lista
  from _ra_grupos g
  join public.modifier_groups m
    on m.business_id = (select id from biz) and pg_temp.norm(m.name) = pg_temp.norm(g.name)
),
enlaces as (
  select i.renglon, gr.name as grupo
  from items i
  join public.menu_item_groups y on y.menu_item_id = i.id
  join grupos gr on gr.id = y.group_id
),
r(orden, concepto, encontrado, esperado, ok) as (
  select 1, 'Negocio',
         coalesce((select business_name from public.businesses, biz
                   where businesses.id = biz.id), 'NO EXISTE'),
         'El Rincón de Adda',
         exists (select 1 from public.businesses, biz where businesses.id = biz.id)
  union all
  select 2, 'Productos de la carta (activos)',
         (select count(*) from items)::text, (select n from esperados)::text,
         (select count(*) from items) = (select n from esperados)
  union all
  select 3, 'Con precio distinto a la carta',
         (select count(*) from items where price <> precio_lista)::text, '0',
         (select count(*) from items where price <> precio_lista) = 0
  union all
  select 4, 'Con impuestos incluidos (inclusive)',
         (select count(*) from items where tax_mode = 'inclusive')::text,
         (select n from esperados)::text,
         (select count(*) from items where tax_mode = 'inclusive') = (select n from esperados)
  union all
  select 5, 'Juego de impuestos',
         (select string_agg(format('%s (%s)', juego, n), ' · ')
          from (select juego, count(*) as n from juegos group by juego) g),
         'ITBIS 18% + Ley 10% en todos',
         (select count(*) from juegos j
          where exists (select 1 from public.menu_item_taxes x join itbis t on t.id = x.tax_id
                        where x.item_id = j.id)
            and exists (select 1 from public.menu_item_taxes x join ley t on t.id = x.tax_id
                        where x.item_id = j.id)
            and (select count(*) from public.menu_item_taxes x where x.item_id = j.id) = 2)
         = (select n from esperados)
  union all
  select 6, 'Ley 10% por orden (service_fee_enabled)',
         case when (select ley_por_orden from ajustes) then 'ENCENDIDA' else 'apagada' end,
         'apagada',
         not (select ley_por_orden from ajustes)
  union all
  select 7, 'Ejemplo: Churrasco Prime Importado $1,200',
         (select format('base %s + ITBIS %s + Ley %s = %s',
                        round(i.price / 1.28, 2), round(i.price / 1.28 * 0.18, 2),
                        round(i.price / 1.28 * 0.10, 2), i.price)
          from items i where i.renglon = 'Churrasco Prime Importado'),
         'base 937.50 + ITBIS 168.75 + Ley 93.75 = 1200.00',
         (select i.price = 1200 from items i where i.renglon = 'Churrasco Prime Importado')
  union all
  select 8, 'Comida → área: ' || case
            when not (select cocina_encendida from ajustes) then 'ninguna (cocina apagada)'
            else coalesce((select string_agg(distinct name || ' (' || code || ')', ', ')
                           from ruta where area = 'cocina'), '—') end,
         (select count(distinct x.menu_item_id) from public.menu_item_print_areas x
          join items i on i.id = x.menu_item_id where i.area = 'cocina')::text,
         case when (select cocina_encendida from ajustes)
              then (select count(*) from items where area = 'cocina')::text else '0' end,
         case when (select cocina_encendida from ajustes)
              then (select count(distinct x.menu_item_id) from public.menu_item_print_areas x
                    join items i on i.id = x.menu_item_id where i.area = 'cocina')
                   = (select count(*) from items where area = 'cocina')
                   and (select count(distinct area_id) from ruta where area = 'cocina') = 1
              else not exists (select 1 from ruta) end
  union all
  select 9, 'Bebidas → área: ' || case
            when not (select cocina_encendida from ajustes) then 'ninguna (cocina apagada)'
            else coalesce((select string_agg(distinct name || ' (' || code || ')', ', ')
                           from ruta where area = 'bar'), '—') end,
         (select count(distinct x.menu_item_id) from public.menu_item_print_areas x
          join items i on i.id = x.menu_item_id where i.area = 'bar')::text,
         case when (select cocina_encendida from ajustes)
              then (select count(*) from items where area = 'bar')::text else '0' end,
         case when (select cocina_encendida from ajustes)
              then (select count(distinct x.menu_item_id) from public.menu_item_print_areas x
                    join items i on i.id = x.menu_item_id where i.area = 'bar')
                   = (select count(*) from items where area = 'bar')
                   and (select count(distinct area_id) from ruta where area = 'bar') = 1
              else not exists (select 1 from ruta) end
  union all
  select 10, 'Legacy print_area_code igual a la N:M',
         (select count(*) from items i
          where i.print_area_code is not distinct from (
            select a.code from public.menu_item_print_areas x
            join public.print_areas a on a.id = x.print_area_id
            where x.menu_item_id = i.id limit 1))::text, (select n from esperados)::text,
         (select count(*) from items i
          where i.print_area_code is not distinct from (
            select a.code from public.menu_item_print_areas x
            join public.print_areas a on a.id = x.print_area_id
            where x.menu_item_id = i.id limit 1)) = (select n from esperados)
  union all
  select 11, 'Enlazados al menú de la caja',
         (select count(*) from items i where exists (
            select 1 from public.menu_item_links l where l.item_id = i.id))::text,
         (select n from esperados)::text,
         (select count(*) from items i where exists (
            select 1 from public.menu_item_links l where l.item_id = i.id))
         = (select n from esperados)
  union all
  select 12, 'Impresoras en el área de la cocina',
         case when not (select cocina_encendida from ajustes) then 'no aplica'
              else (select count(*) from public.print_area_printers p
                    where p.area_id in (select area_id from ruta where area = 'cocina'))::text end,
         '1 o más',
         not (select cocina_encendida from ajustes)
         or (select count(*) from public.print_area_printers p
             where p.area_id in (select area_id from ruta where area = 'cocina')) > 0
  union all
  select 13, 'Impresoras en el área del bar',
         case when not (select cocina_encendida from ajustes) then 'no aplica'
              else (select count(*) from public.print_area_printers p
                    where p.area_id in (select area_id from ruta where area = 'bar'))::text end,
         '1 o más',
         not (select cocina_encendida from ajustes)
         or (select count(*) from public.print_area_printers p
             where p.area_id in (select area_id from ruta where area = 'bar')) > 0
  union all
  select 14, 'ITBIS en mesa / rápida / llevar / delivery',
         coalesce((select concat_ws(' / ',
                     case when apply_on_zone     then 'sí' else 'NO' end,
                     case when apply_on_quick    then 'sí' else 'NO' end,
                     case when apply_on_takeout  then 'sí' else 'NO' end,
                     case when apply_on_delivery then 'sí' else 'NO' end) from itbis), '—'),
         'sí / sí / sí / sí',
         coalesce((select apply_on_zone and apply_on_quick
                          and apply_on_takeout and apply_on_delivery from itbis), false)
  union all
  select 15, 'Ley en mesa / rápida / llevar / delivery',
         coalesce((select concat_ws(' / ',
                     case when apply_on_zone     then 'sí' else 'NO' end,
                     case when apply_on_quick    then 'sí' else 'NO' end,
                     case when apply_on_takeout  then 'sí' else 'NO' end,
                     case when apply_on_delivery then 'sí' else 'NO' end) from ley), '—'),
         'sí en mesa (lo demás lo decide el dueño)',
         coalesce((select apply_on_zone from ley), false)
  union all
  select 16, 'Categorías con productos de la carta',
         (select count(distinct category_id) from items)::text,
         (select count(*) from _ra_categorias)::text,
         (select count(distinct category_id) from items) = (select count(*) from _ra_categorias)
  union all
  select 17, 'Grupos de modificadores bien armados',
         (select count(*) from grupos
          where (min_select, max_select, display_type, is_required)
                = (case tipo when 'uno' then 1 else 0 end, case tipo when 'uno' then 1 else 0 end,
                   case tipo when 'uno' then 'single' else 'multiple' end, (tipo = 'uno'))
            and opciones = opciones_lista)::text,
         (select count(*) from _ra_grupos)::text,
         (select count(*) from grupos
          where (min_select, max_select, display_type, is_required)
                = (case tipo when 'uno' then 1 else 0 end, case tipo when 'uno' then 1 else 0 end,
                   case tipo when 'uno' then 'single' else 'multiple' end, (tipo = 'uno'))
            and opciones = opciones_lista) = (select count(*) from _ra_grupos)
  union all
  select 18, 'Productos enlazados a sus modificadores',
         (select count(*) from enlaces e
          where exists (select 1 from _ra_asig a
                        where a.producto = e.renglon and a.grupo = e.grupo))::text
           || ' (de más: ' || (select count(*) from enlaces e
                               where not exists (select 1 from _ra_asig a
                                                 where a.producto = e.renglon
                                                   and a.grupo = e.grupo)) || ')',
         (select count(*) from _ra_asig)::text || ' (de más: 0)',
         (select count(*) from enlaces) = (select count(*) from _ra_asig)
         and not exists (select 1 from enlaces e
                         where not exists (select 1 from _ra_asig a
                                           where a.producto = e.renglon and a.grupo = e.grupo))
  union all
  select 19, 'Ejemplo: Piña Colada con alcohol',
         (select format('%s + %s = %s', i.price, m.price_delta, i.price + m.price_delta)
          from items i
          join public.menu_item_groups y on y.menu_item_id = i.id
          join public.modifiers m on m.group_id = y.group_id and m.is_active
          where i.renglon = 'Piña Colada' and m.name = 'Con alcohol'),
         '400.00 + 50.00 = 450.00',
         coalesce((select i.price + m.price_delta = 450
                   from items i
                   join public.menu_item_groups y on y.menu_item_id = i.id
                   join public.modifiers m on m.group_id = y.group_id and m.is_active
                   where i.renglon = 'Piña Colada' and m.name = 'Con alcohol'), false)
)
select concepto, encontrado, esperado,
       case when ok then '✓' else '✗ REVISAR' end as estado
from r
order by orden;
