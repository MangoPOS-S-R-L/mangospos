-- ============================================================================
-- LA COCINA MEXICANA AUTENTICA — CARGA DEL CATÁLOGO
-- Business b0bd6f20-850c-4e9a-85ae-4cd619e1a0ee
--
-- Fuente: "Catalogo de productos (Transformados)" del sistema anterior
-- (07/10/2026 01:59 PM, 190 filas) + el diagnóstico del 07-oct (39 productos
-- ya subidos, todos sin impuesto). Este archivo lo arma
-- build_import_b0bd6f20.py. No lo edites a mano.
-- ============================================================================
--
-- QUÉ HACE
--   126 productos de la lista (104 nuevos + 22 que ya estaban subidos): 36
--   a la COCINA y 90 al BAR. 15 con modificador obligatorio y el grupo
--   opcional "Extras" con 11 opciones.
--   De lo que ya estaba: 22 son de la lista, 4 no están en el CSV
--   (se quedan), 12 se desactivan (DELIVERY y extras sueltos) y 1 no se toca.
--   Crea la Ley 10% (copia de Ágora) y las áreas Cocina y Bar.
--   No se cargan: 4 filas repetidas y los 8 "Delivery 100 … 450".
--   Sin costo (el CSV lo trae en 0), sin insumos ni existencias.
--
-- PRECIOS E IMPUESTOS
--   tax_mode = 'inclusive' con ITBIS 18% + Ley 10%: lo que dice la lista es lo
--   que paga el cliente; los dos impuestos se sacan de adentro del precio.
--   Una Corona de $300 queda en base 234.38 + impuestos 65.62.
--   menu_item_taxes es la ÚNICA fuente del impuesto: sin fila ahí la factura
--   sale en 0.00. Por eso se les pone a TODOS los productos activos del
--   negocio, también a los que ya estaban subidos (no tenían ninguno). AGUA
--   lleva solo la Ley, como en Ágora. "Carne Cocida Natural xlb" es exclusive
--   y no se toca: el reporte la marca para decidirla con el dueño.
--   Manda el precio del CSV: los ya subidos que estaban distintos se ajustan.
--
-- LEY 10%
--   El negocio no la tiene: se COPIA tal cual la de la sucursal de Ágora
--   (6e18428f): mismos canales, mismo include_in_ecf. Si ya existe una, se usa
--   esa. Aborta si hay dos, si Ágora no tiene exactamente una, o si la copia
--   traería un uuid que apunte a otra cosa de Ágora.
--
-- VARIANTES = PRODUCTO + MODIFICADOR OBLIGATORIO
--   "Cantarito 1800" vale $500 y pide "Cantarito 1800 · Tequila" (elige 1):
--   Silver, Reposado, Añejo +50, Añejo Cristalino +150. La base es el precio
--   más bajo y la opción suma la diferencia (se cobra por unidad y entra en la
--   base del ITBIS y la Ley). TOSTADAS y ENCHILADA, que ya estaban subidos
--   genéricos, piden el tipo.
--
-- EXTRAS
--   Grupo opcional "Extras" (varias opciones) en los productos de cocina.
--   Los extras que estaban subidos como producto se desactivan.
--
-- ÁREAS DE PRODUCCIÓN (comanda)
--   No hay ninguna: se CREAN "Cocina" (`cocina`) y "Bar" (`bar`) sin
--   impresora. Si ya existieran (code cocina/kitchen/kitchen_hot/comida y
--   bar/barra, o con ese nombre) se reusan.
--   TODO producto activo queda con su área en la N:M (menu_item_print_areas)
--   y en el legacy menu_items.print_area_code, que fn_add_item_from_menu copia
--   al ítem. Los ya subidos tenían el legacy en 'kitchen_hot', un área que no
--   existe: "Enviar a cocina" no habría sacado ninguna comanda.
--   Las filas de impresoras salen ✗ hasta que vincules la impresora a cada
--   área en la app (Ajustes → Impresoras).
--
-- DELIVERY
--   Los productos DELIVERY 100 … 450 se desactivan: el cargo de delivery lo
--   pide la caja al cobrar (delivery_fee_required = true). Si el negocio no
--   tiene montos rápidos, se ponen 100, 150 … 450.
--
-- LO QUE YA ESTABA SUBIDO
--   _b0_existentes dice qué hacer con cada uno (sale del diagnóstico). Si
--   aparece un producto activo que no está ahí, ABORTA y lo lista: hay que
--   correr de nuevo 00_diagnostico.sql y decidir.
--
-- CÓMO CORRERLO
--   Pega este archivo entero en el SQL Editor de Supabase y dale Run. La
--   tabla del final es el reporte.
--
-- TODO O NADA
--   Va en UNA transacción. Primero comprueba todo y después, antes del commit,
--   verifica producto por producto. Si algo no cuadra lanza excepción y
--   REVIERTE ENTERO.
--
-- SE PUEDE RE-CORRER
--   No duplica nada: lo que creó una corrida anterior vuelve a quedar como
--   dice la lista. Para corregir un precio: cámbialo en catalogo.py, corre
--   build_import_b0bd6f20.py y vuelve a correr este archivo.
-- ============================================================================

begin;

-- Nombre normalizado: sin mayúsculas, sin tildes, sin espacios repetidos.
create or replace function pg_temp.norm(t text) returns text
language sql immutable as $f$
  select translate(lower(regexp_replace(btrim(t), '\s+', ' ', 'g')),
                   'áéíóúüñÁÉÍÓÚÜÑ', 'aeiouunaeiouun')
$f$;

-- Llave de emparejamiento: solo letras y números ("TACOS 🌮" = "tacos").
create or replace function pg_temp.k(t text) returns text
language sql immutable as $f$
  select btrim(regexp_replace(
           translate(lower(t), 'áéíóúüñÁÉÍÓÚÜÑ', 'aeiouunaeiouun'),
           '[^a-z0-9]+', ' ', 'g'))
$f$;

-- ---------------------------------------------------------------------------
-- 0) La lista. Tablas temporales de la sesión: el reporte de abajo las usa.
-- ---------------------------------------------------------------------------

drop table if exists _b0_cfg;
create temp table _b0_cfg (ley_origen uuid not null, presets jsonb not null);
insert into _b0_cfg (ley_origen, presets) values
  ('6e18428f-fdd6-4c58-af0e-dae2403fbf1d', '[100, 150, 200, 250, 300, 350, 400, 450]'::jsonb)
;

drop table if exists _b0_categorias;
create temp table _b0_categorias (
  name     text not null,
  posicion int  not null,
  area     text not null check (area in ('cocina', 'bar')),
  bebida   boolean not null
);
insert into _b0_categorias (name, posicion, area, bebida) values
  ('ENTRADAS 🥨', 10, 'cocina', false),
  ('TACOS 🌮', 20, 'cocina', false),
  ('PLATOS MEXICANOS 🌯', 30, 'cocina', false),
  ('BEBIDAS🥤', 40, 'bar', true),
  ('Postres', 50, 'bar', false),
  ('DELIVERY', 60, 'cocina', false),
  ('EXTRAS', 70, 'cocina', false),
  ('SIN ALCOHOL', 41, 'bar', true),
  ('CERVEZA', 42, 'bar', true),
  ('CAFÉ', 43, 'bar', true),
  ('CANTARITOS', 44, 'bar', true),
  ('MARGARITAS', 45, 'bar', true),
  ('MICHELADAS', 46, 'bar', true),
  ('MOJITOS', 47, 'bar', true),
  ('COCTELES', 48, 'bar', true),
  ('MEZCAL', 49, 'bar', true),
  ('DON JULIO RESERVA', 51, 'bar', true),
  ('OTROS TEQUILAS EXCLUSIVOS', 52, 'bar', true),
  ('OTROS TEQUILAS', 53, 'bar', true)
;

drop table if exists _b0_productos;
create temp table _b0_productos (
  name        text not null,
  categoria   text not null,
  area        text not null check (area in ('cocina', 'bar')),
  price       numeric(12,2) not null,
  description text,
  grupo       text,            -- modificador obligatorio (variantes) o null
  posicion    int not null,
  impuestos   text not null check (impuestos in ('itbis_ley', 'ley'))
);
insert into _b0_productos (name, categoria, area, price, description, grupo, posicion, impuestos) values
  ('CHORIQUESO', 'ENTRADAS 🥨', 'cocina', 650.00, null, null, 1, 'itbis_ley'),
  ('MINI FLAUTAS', 'ENTRADAS 🥨', 'cocina', 500.00, null, null, 2, 'itbis_ley'),
  ('MINI SOPES', 'ENTRADAS 🥨', 'cocina', 600.00, null, null, 3, 'itbis_ley'),
  ('NACHOS 3 COMPADRES', 'ENTRADAS 🥨', 'cocina', 450.00, null, null, 4, 'itbis_ley'),
  ('NACHOS CON GUACAMOLE', 'ENTRADAS 🥨', 'cocina', 350.00, null, null, 5, 'itbis_ley'),
  ('CACHETADAS', 'TACOS 🌮', 'cocina', 600.00, null, 'Cachetadas · Corte', 1, 'itbis_ley'),
  ('CHAMORRO DE CERDO', 'TACOS 🌮', 'cocina', 1800.00, null, null, 2, 'itbis_ley'),
  ('TACOS', 'TACOS 🌮', 'cocina', 700.00, null, null, 3, 'itbis_ley'),
  ('TACOS A LA ZIMBRON', 'TACOS 🌮', 'cocina', 600.00, '3 unidades', null, 4, 'itbis_ley'),
  ('TACOS AL PASTOR', 'TACOS 🌮', 'cocina', 700.00, '4 unidades', null, 5, 'itbis_ley'),
  ('TACOS DE BIRRIA', 'TACOS 🌮', 'cocina', 800.00, '4 unidades', null, 6, 'itbis_ley'),
  ('TACOS DE CARNITAS MICHOACANAS', 'TACOS 🌮', 'cocina', 700.00, '4 unidades', null, 7, 'itbis_ley'),
  ('TACOS DE CHILORIO', 'TACOS 🌮', 'cocina', 750.00, null, null, 8, 'itbis_ley'),
  ('TACOS DE COCHINITA PIBIL', 'TACOS 🌮', 'cocina', 750.00, '4 unidades', null, 9, 'itbis_ley'),
  ('TACOS DE TINGA DE POLLO', 'TACOS 🌮', 'cocina', 700.00, '4 unidades', null, 10, 'itbis_ley'),
  ('UNIDAD DE TACO', 'TACOS 🌮', 'cocina', 250.00, null, null, 11, 'itbis_ley'),
  ('BURRITO', 'PLATOS MEXICANOS 🌯', 'cocina', 700.00, null, null, 1, 'itbis_ley'),
  ('CHILAQUILES', 'PLATOS MEXICANOS 🌯', 'cocina', 700.00, null, null, 2, 'itbis_ley'),
  ('CHIMICHANGA', 'PLATOS MEXICANOS 🌯', 'cocina', 700.00, null, null, 3, 'itbis_ley'),
  ('ENCHILADA', 'PLATOS MEXICANOS 🌯', 'cocina', 800.00, null, 'Enchilada · Tipo', 4, 'itbis_ley'),
  ('FAJITAS', 'PLATOS MEXICANOS 🌯', 'cocina', 850.00, null, null, 5, 'itbis_ley'),
  ('FLAUTAS DE PAPA Y CHORIZO', 'PLATOS MEXICANOS 🌯', 'cocina', 600.00, null, null, 6, 'itbis_ley'),
  ('FLAUTAS DE POLLO', 'PLATOS MEXICANOS 🌯', 'cocina', 650.00, null, null, 7, 'itbis_ley'),
  ('GRINGA', 'PLATOS MEXICANOS 🌯', 'cocina', 800.00, null, null, 8, 'itbis_ley'),
  ('HUEVOS RANCHEROS', 'PLATOS MEXICANOS 🌯', 'cocina', 550.00, null, null, 9, 'itbis_ley'),
  ('HUEVOS RANCHEROS DIVORCIADOS', 'PLATOS MEXICANOS 🌯', 'cocina', 550.00, null, null, 10, 'itbis_ley'),
  ('QUESADILLA DE CHORIZO', 'PLATOS MEXICANOS 🌯', 'cocina', 650.00, null, null, 11, 'itbis_ley'),
  ('QUESADILLA DE POLLO', 'PLATOS MEXICANOS 🌯', 'cocina', 650.00, null, null, 12, 'itbis_ley'),
  ('SOPA DE TORTILLAS', 'PLATOS MEXICANOS 🌯', 'cocina', 600.00, null, null, 13, 'itbis_ley'),
  ('SOPES DE PAPA Y CHORIZO', 'PLATOS MEXICANOS 🌯', 'cocina', 650.00, null, null, 14, 'itbis_ley'),
  ('SOPES DE POLLO', 'PLATOS MEXICANOS 🌯', 'cocina', 650.00, null, null, 15, 'itbis_ley'),
  ('SOPES DE TINGA DE POLLO', 'PLATOS MEXICANOS 🌯', 'cocina', 700.00, null, null, 16, 'itbis_ley'),
  ('TOSTADAS', 'PLATOS MEXICANOS 🌯', 'cocina', 650.00, null, 'Tostadas · Tipo', 17, 'itbis_ley'),
  ('ARIZONA', 'BEBIDAS🥤', 'bar', 200.00, null, 'Arizona · Sabor', 1, 'itbis_ley'),
  ('JARRITOS', 'BEBIDAS🥤', 'bar', 175.00, null, 'Jarritos · Sabor', 2, 'itbis_ley'),
  ('JUGOS NATURALES', 'BEBIDAS🥤', 'bar', 150.00, null, null, 3, 'itbis_ley'),
  ('REFRESCOS SABORES', 'BEBIDAS🥤', 'bar', 50.00, null, 'Refrescos Sabores · Sabor', 4, 'itbis_ley'),
  ('SODA CAN', 'BEBIDAS🥤', 'bar', 100.00, null, 'Soda Can · Sabor', 5, 'itbis_ley'),
  ('AGUA DASANI', 'SIN ALCOHOL', 'bar', 50.00, null, null, 1, 'ley'),
  ('CHINOLA FROZEN', 'SIN ALCOHOL', 'bar', 250.00, null, null, 2, 'itbis_ley'),
  ('FRESA FROZEN', 'SIN ALCOHOL', 'bar', 300.00, null, null, 3, 'itbis_ley'),
  ('HORCHATA', 'SIN ALCOHOL', 'bar', 250.00, null, null, 4, 'itbis_ley'),
  ('JUGO DE CEREZA', 'SIN ALCOHOL', 'bar', 200.00, null, null, 5, 'itbis_ley'),
  ('JUGO DE CHINOLA', 'SIN ALCOHOL', 'bar', 200.00, null, null, 6, 'itbis_ley'),
  ('JUGO DE FRUIT PUNCH', 'SIN ALCOHOL', 'bar', 250.00, null, null, 7, 'itbis_ley'),
  ('JUGO DE LIMÓN', 'SIN ALCOHOL', 'bar', 200.00, null, null, 8, 'itbis_ley'),
  ('LIMONADA DE COCO', 'SIN ALCOHOL', 'bar', 300.00, null, null, 9, 'itbis_ley'),
  ('LIMONADA FROZEN', 'SIN ALCOHOL', 'bar', 250.00, null, null, 10, 'itbis_ley'),
  ('REFRESCO', 'SIN ALCOHOL', 'bar', 100.00, null, 'Refresco · Sabor', 11, 'itbis_ley'),
  ('TAMARINDO FROZEN', 'SIN ALCOHOL', 'bar', 250.00, null, null, 12, 'itbis_ley'),
  ('TÉ DE JAMAICA', 'SIN ALCOHOL', 'bar', 200.00, null, null, 13, 'itbis_ley'),
  ('CLAMATO', 'CERVEZA', 'bar', 100.00, null, null, 1, 'itbis_ley'),
  ('CORONA', 'CERVEZA', 'bar', 300.00, null, null, 2, 'itbis_ley'),
  ('HEINEKEN', 'CERVEZA', 'bar', 300.00, null, null, 3, 'itbis_ley'),
  ('MODELO NEGRA', 'CERVEZA', 'bar', 300.00, null, null, 4, 'itbis_ley'),
  ('MODELO RUBIA', 'CERVEZA', 'bar', 300.00, null, null, 5, 'itbis_ley'),
  ('PRESIDENTE LIGHT', 'CERVEZA', 'bar', 300.00, null, null, 6, 'itbis_ley'),
  ('PRESIDENTE NORMAL', 'CERVEZA', 'bar', 300.00, null, null, 7, 'itbis_ley'),
  ('STELLA ARTOIS', 'CERVEZA', 'bar', 300.00, null, null, 8, 'itbis_ley'),
  ('CAFÉ CON LECHE', 'CAFÉ', 'bar', 150.00, null, null, 1, 'itbis_ley'),
  ('CORTADITO', 'CAFÉ', 'bar', 100.00, null, null, 2, 'itbis_ley'),
  ('ESPRESSO', 'CAFÉ', 'bar', 100.00, null, null, 3, 'itbis_ley'),
  ('CANTARITO 1800', 'CANTARITOS', 'bar', 500.00, null, 'Cantarito 1800 · Tequila', 1, 'itbis_ley'),
  ('CANTARITO 400 CONEJOS', 'CANTARITOS', 'bar', 700.00, null, null, 2, 'itbis_ley'),
  ('CANTARITO AGAVITA', 'CANTARITOS', 'bar', 400.00, null, 'Cantarito Agavita · Tequila', 3, 'itbis_ley'),
  ('CANTARITO DON JULIO', 'CANTARITOS', 'bar', 550.00, null, 'Cantarito Don Julio · Tequila', 4, 'itbis_ley'),
  ('CANTARITO GRAN CAVA EXTRA AÑEJO', 'CANTARITOS', 'bar', 900.00, null, null, 5, 'itbis_ley'),
  ('CANTARITO GRAND MAYAN EXTRA AÑEJO', 'CANTARITOS', 'bar', 900.00, null, null, 6, 'itbis_ley'),
  ('CANTARITO HERRADURA', 'CANTARITOS', 'bar', 650.00, null, 'Cantarito Herradura · Tequila', 7, 'itbis_ley'),
  ('CANTARITO JOSÉ CUERVO', 'CANTARITOS', 'bar', 450.00, null, 'Cantarito José Cuervo · Tequila', 8, 'itbis_ley'),
  ('CANTARITO MEZCAL MITRE', 'CANTARITOS', 'bar', 950.00, null, null, 9, 'itbis_ley'),
  ('CANTARITO MONTELOBOS', 'CANTARITOS', 'bar', 600.00, null, null, 10, 'itbis_ley'),
  ('MARGARITA DE CHINOLA', 'MARGARITAS', 'bar', 450.00, null, null, 1, 'itbis_ley'),
  ('MARGARITA DE COCO', 'MARGARITAS', 'bar', 450.00, null, null, 2, 'itbis_ley'),
  ('MARGARITA DE FRESA', 'MARGARITAS', 'bar', 500.00, null, null, 3, 'itbis_ley'),
  ('MARGARITA DE LIMÓN', 'MARGARITAS', 'bar', 450.00, null, null, 4, 'itbis_ley'),
  ('MARGARITA DE LIMÓN A LA ROCA', 'MARGARITAS', 'bar', 450.00, null, null, 5, 'itbis_ley'),
  ('MARGARITA DE TAMARINDO', 'MARGARITAS', 'bar', 450.00, null, null, 6, 'itbis_ley'),
  ('CHELADA', 'MICHELADAS', 'bar', 350.00, null, null, 1, 'itbis_ley'),
  ('MICHELADA DE MANGO', 'MICHELADAS', 'bar', 500.00, null, null, 2, 'itbis_ley'),
  ('MICHELADA DE TAMARINDO', 'MICHELADAS', 'bar', 500.00, null, null, 3, 'itbis_ley'),
  ('MICHELADA TRADICIONAL', 'MICHELADAS', 'bar', 500.00, null, null, 4, 'itbis_ley'),
  ('MOJITO DE CHINOLA', 'MOJITOS', 'bar', 400.00, null, null, 1, 'itbis_ley'),
  ('MOJITO DE COCO', 'MOJITOS', 'bar', 400.00, null, null, 2, 'itbis_ley'),
  ('MOJITO DE FRESA', 'MOJITOS', 'bar', 400.00, null, null, 3, 'itbis_ley'),
  ('MOJITO DE JAMAICA', 'MOJITOS', 'bar', 400.00, null, null, 4, 'itbis_ley'),
  ('MOJITO DE LIMÓN', 'MOJITOS', 'bar', 400.00, null, null, 5, 'itbis_ley'),
  ('APEROL SPRITZ', 'COCTELES', 'bar', 450.00, null, null, 1, 'itbis_ley'),
  ('AVERNA', 'COCTELES', 'bar', 200.00, null, null, 2, 'itbis_ley'),
  ('BAILEYS', 'COCTELES', 'bar', 300.00, null, null, 3, 'itbis_ley'),
  ('DIEGO RIVERA', 'COCTELES', 'bar', 500.00, null, null, 4, 'itbis_ley'),
  ('MANGONADA', 'COCTELES', 'bar', 500.00, null, 'Mangonada · Alcohol', 5, 'itbis_ley'),
  ('MEZCALITA', 'COCTELES', 'bar', 500.00, null, null, 6, 'itbis_ley'),
  ('PALOMA', 'COCTELES', 'bar', 450.00, null, null, 7, 'itbis_ley'),
  ('PIÑA COLADA', 'COCTELES', 'bar', 400.00, null, 'Piña Colada · Alcohol', 8, 'itbis_ley'),
  ('SANGRÍA DE JAMAICA', 'COCTELES', 'bar', 450.00, null, null, 9, 'itbis_ley'),
  ('TEQUILA SUNRISE', 'COCTELES', 'bar', 400.00, null, null, 10, 'itbis_ley'),
  ('CONTRALUZ MEZCAL', 'MEZCAL', 'bar', 600.00, null, null, 1, 'itbis_ley'),
  ('MEZCAL 400 CONEJOS (SHOT)', 'MEZCAL', 'bar', 550.00, null, null, 2, 'itbis_ley'),
  ('OJO DE TIGRE', 'MEZCAL', 'bar', 450.00, null, null, 3, 'itbis_ley'),
  ('BROWNIE A LA MODA', 'Postres', 'bar', 550.00, null, null, 1, 'itbis_ley'),
  ('CHURROS', 'Postres', 'bar', 400.00, null, null, 2, 'itbis_ley'),
  ('PIE DE LIMÓN', 'Postres', 'bar', 400.00, null, null, 3, 'itbis_ley'),
  ('DON JULIO AÑEJO (SHOT)', 'DON JULIO RESERVA', 'bar', 700.00, null, null, 1, 'itbis_ley'),
  ('DON JULIO REPOSADO (SHOT)', 'DON JULIO RESERVA', 'bar', 600.00, null, null, 2, 'itbis_ley'),
  ('FRANCISCO GONZALES EXTRA AÑEJO (SHOT)', 'DON JULIO RESERVA', 'bar', 800.00, null, null, 3, 'itbis_ley'),
  ('AMOR MÍO BLANCO (SHOT)', 'OTROS TEQUILAS EXCLUSIVOS', 'bar', 550.00, null, null, 1, 'itbis_ley'),
  ('CLASE AZUL REPOSADO (SHOT)', 'OTROS TEQUILAS EXCLUSIVOS', 'bar', 1450.00, null, null, 2, 'itbis_ley'),
  ('GRAN CAVA DE ORO EXTRA VIEJO (SHOT)', 'OTROS TEQUILAS EXCLUSIVOS', 'bar', 900.00, null, null, 3, 'itbis_ley'),
  ('GRAND MAYAN EXTRA VIEJO (SHOT)', 'OTROS TEQUILAS EXCLUSIVOS', 'bar', 800.00, null, null, 4, 'itbis_ley'),
  ('1800 AÑEJO (SHOT)', 'OTROS TEQUILAS', 'bar', 550.00, null, null, 1, 'itbis_ley'),
  ('1800 REPOSADO (SHOT)', 'OTROS TEQUILAS', 'bar', 400.00, null, null, 2, 'itbis_ley'),
  ('1800 SILVER (SHOT)', 'OTROS TEQUILAS', 'bar', 400.00, null, null, 3, 'itbis_ley'),
  ('1800 ULTRA AÑEJO CRISTALINO (SHOT)', 'OTROS TEQUILAS', 'bar', 600.00, null, null, 4, 'itbis_ley'),
  ('AGAVITA REPOSADO (SHOT)', 'OTROS TEQUILAS', 'bar', 300.00, null, null, 5, 'itbis_ley'),
  ('AGAVITA SILVER (SHOT)', 'OTROS TEQUILAS', 'bar', 300.00, null, null, 6, 'itbis_ley'),
  ('GRAN MALO (SHOT)', 'OTROS TEQUILAS', 'bar', 450.00, null, null, 7, 'itbis_ley'),
  ('HERRADURA AÑEJO (SHOT)', 'OTROS TEQUILAS', 'bar', 500.00, null, null, 8, 'itbis_ley'),
  ('HERRADURA REPOSADO (SHOT)', 'OTROS TEQUILAS', 'bar', 450.00, null, null, 9, 'itbis_ley'),
  ('HERRADURA SILVER (SHOT)', 'OTROS TEQUILAS', 'bar', 400.00, null, null, 10, 'itbis_ley'),
  ('HERRADURA ULTRA AÑEJO (SHOT)', 'OTROS TEQUILAS', 'bar', 600.00, null, null, 11, 'itbis_ley'),
  ('JOSÉ CUERVO REPOSADO (SHOT)', 'OTROS TEQUILAS', 'bar', 350.00, null, null, 12, 'itbis_ley'),
  ('JOSÉ CUERVO SILVER (SHOT)', 'OTROS TEQUILAS', 'bar', 350.00, null, null, 13, 'itbis_ley'),
  ('COMBO ROSARIO', 'DELIVERY', 'cocina', 1100.00, null, null, 1, 'itbis_ley'),
  ('FIESTÓN DE TACOS', 'DELIVERY', 'cocina', 2000.00, null, null, 2, 'itbis_ley'),
  ('CARNES', 'EXTRAS', 'cocina', 700.00, null, null, 1, 'itbis_ley')
;

-- Nombres con los que un producto de la lista podría estar ya en la caja.
drop table if exists _b0_claves;
create temp table _b0_claves (producto text not null, k text not null);
insert into _b0_claves (producto, k) values
  ('CHORIQUESO', 'choriqueso'),
  ('CHORIQUESO', 'choriqueso choriqueso'),
  ('MINI FLAUTAS', 'mini flautas'),
  ('MINI FLAUTAS', 'mini flautas mini flautas'),
  ('MINI SOPES', 'mini sopes'),
  ('MINI SOPES', 'mini sopes mini sopes'),
  ('NACHOS 3 COMPADRES', 'nachos 3 compadres'),
  ('NACHOS CON GUACAMOLE', 'nachos con guacamole'),
  ('NACHOS CON GUACAMOLE', 'nachos con guacamole nachos con guacamole'),
  ('CACHETADAS', 'cachetadas'),
  ('CHAMORRO DE CERDO', 'chamorro de cerdo'),
  ('CHAMORRO DE CERDO', 'chamorro de cerdo chamorro'),
  ('TACOS', 'tacos'),
  ('TACOS', 'tacos tacos'),
  ('TACOS A LA ZIMBRON', 'tacos a la zimbron'),
  ('TACOS A LA ZIMBRON', 'tacos a la zimbron 3 und'),
  ('TACOS AL PASTOR', 'tacos al pastor'),
  ('TACOS AL PASTOR', 'tacos al pastor 4 und'),
  ('TACOS DE BIRRIA', 'tacos de birria'),
  ('TACOS DE BIRRIA', 'tacos de birria 4 und'),
  ('TACOS DE CARNITAS MICHOACANAS', 'tacos de carnita michoacan'),
  ('TACOS DE CARNITAS MICHOACANAS', 'tacos de carnitas michoacanas'),
  ('TACOS DE CARNITAS MICHOACANAS', 'tacos de carnitas michoacanas 4 und'),
  ('TACOS DE CHILORIO', 'tacos chilorio'),
  ('TACOS DE CHILORIO', 'tacos chilorio tacos de chilorio'),
  ('TACOS DE CHILORIO', 'tacos de chilorio'),
  ('TACOS DE COCHINITA PIBIL', 'tacos de cochinita pibil'),
  ('TACOS DE COCHINITA PIBIL', 'tacos de cochinita pibil 4 und'),
  ('TACOS DE TINGA DE POLLO', 'tacos de tinga de pollo'),
  ('TACOS DE TINGA DE POLLO', 'tacos de tinga de pollo 4 und'),
  ('UNIDAD DE TACO', 'unidad de taco'),
  ('UNIDAD DE TACO', 'unidad de taco unidad de taco'),
  ('BURRITO', 'burrito'),
  ('BURRITO', 'burrito burrito'),
  ('CHILAQUILES', 'chilaquiles'),
  ('CHILAQUILES', 'chilaquiles chilaquiles'),
  ('CHIMICHANGA', 'chimichanga'),
  ('CHIMICHANGA', 'chimichanga chimichanga'),
  ('ENCHILADA', 'enchilada'),
  ('FAJITAS', 'fajitas'),
  ('FAJITAS', 'fajitas fajitas'),
  ('FLAUTAS DE PAPA Y CHORIZO', 'flauta de papa y chorizo'),
  ('FLAUTAS DE PAPA Y CHORIZO', 'flauta de papa y chorizo flautas papa y chorizo'),
  ('FLAUTAS DE PAPA Y CHORIZO', 'flautas de papa y chorizo'),
  ('FLAUTAS DE POLLO', 'flautas de pollo'),
  ('FLAUTAS DE POLLO', 'flautas de pollo flautas pollo'),
  ('GRINGA', 'gringa'),
  ('GRINGA', 'gringa gringa'),
  ('HUEVOS RANCHEROS', 'huevos rancheros'),
  ('HUEVOS RANCHEROS DIVORCIADOS', 'huevos rancheros divorciados'),
  ('HUEVOS RANCHEROS DIVORCIADOS', 'huevos rancheros divorciados huevos ranch div'),
  ('QUESADILLA DE CHORIZO', 'quesadilla de chorizo'),
  ('QUESADILLA DE CHORIZO', 'quesadilla de chorizo queda chorizo'),
  ('QUESADILLA DE POLLO', 'quesadilla de pollo'),
  ('QUESADILLA DE POLLO', 'quesadilla de pollo quesadillas'),
  ('SOPA DE TORTILLAS', 'sopa de tortillas'),
  ('SOPES DE PAPA Y CHORIZO', 'sopes de papa y chorizo'),
  ('SOPES DE PAPA Y CHORIZO', 'sopes de papa y chorizo sope papa chorizo'),
  ('SOPES DE POLLO', 'sopes de pollo'),
  ('SOPES DE POLLO', 'sopes de pollo sope pollo'),
  ('SOPES DE TINGA DE POLLO', 'sopes de tinga de pollo'),
  ('SOPES DE TINGA DE POLLO', 'sopes de tinga de pollo sope tinga'),
  ('TOSTADAS', 'tostadas'),
  ('ARIZONA', 'arizona'),
  ('ARIZONA', 'arizona all natural'),
  ('JARRITOS', 'jarritos'),
  ('JUGOS NATURALES', 'jugos naturales'),
  ('REFRESCOS SABORES', 'refrescos'),
  ('REFRESCOS SABORES', 'refrescos sabores'),
  ('SODA CAN', 'soda can'),
  ('AGUA DASANI', 'agua'),
  ('AGUA DASANI', 'agua dasani'),
  ('CHINOLA FROZEN', 'chinola frozen'),
  ('FRESA FROZEN', 'fresa frozen'),
  ('HORCHATA', 'horchata'),
  ('JUGO DE CEREZA', 'jugo cereza'),
  ('JUGO DE CEREZA', 'jugo de cereza'),
  ('JUGO DE CHINOLA', 'jugo de chinola'),
  ('JUGO DE FRUIT PUNCH', 'jugo de fruit punch'),
  ('JUGO DE LIMÓN', 'jugo de limon'),
  ('LIMONADA DE COCO', 'limonada coco'),
  ('LIMONADA DE COCO', 'limonada de coco'),
  ('LIMONADA FROZEN', 'limonada frozen'),
  ('REFRESCO', 'refresco'),
  ('TAMARINDO FROZEN', 'tamarindo frozen'),
  ('TÉ DE JAMAICA', 'te de jamaica'),
  ('CLAMATO', 'clamato'),
  ('CORONA', 'corona'),
  ('HEINEKEN', 'heineken'),
  ('MODELO NEGRA', 'modelo negra'),
  ('MODELO RUBIA', 'modelo rubia'),
  ('PRESIDENTE LIGHT', 'presidente light'),
  ('PRESIDENTE LIGHT', 'presidente light presi'),
  ('PRESIDENTE NORMAL', 'presidente normal'),
  ('PRESIDENTE NORMAL', 'presidente normal presi'),
  ('STELLA ARTOIS', 'stella artois'),
  ('CAFÉ CON LECHE', 'cafe con leche'),
  ('CORTADITO', 'cortadito'),
  ('ESPRESSO', 'espresso'),
  ('CANTARITO 1800', 'cantarito 1800'),
  ('CANTARITO 400 CONEJOS', 'cantarito 400 conejos'),
  ('CANTARITO AGAVITA', 'cantarito agavita'),
  ('CANTARITO DON JULIO', 'cantarito don julio'),
  ('CANTARITO GRAN CAVA EXTRA AÑEJO', 'cantarito gran cava'),
  ('CANTARITO GRAN CAVA EXTRA AÑEJO', 'cantarito gran cava extra anejo'),
  ('CANTARITO GRAND MAYAN EXTRA AÑEJO', 'cantarito grand mayan'),
  ('CANTARITO GRAND MAYAN EXTRA AÑEJO', 'cantarito grand mayan extra anejo'),
  ('CANTARITO HERRADURA', 'cantarito herradura'),
  ('CANTARITO HERRADURA', 'cantarito herrtadura'),
  ('CANTARITO JOSÉ CUERVO', 'cantarito jose cuervo'),
  ('CANTARITO MEZCAL MITRE', 'cantarito mezcal mitre'),
  ('CANTARITO MONTELOBOS', 'cantarito montelobos'),
  ('MARGARITA DE CHINOLA', 'margarita chinola'),
  ('MARGARITA DE CHINOLA', 'margarita de chinola'),
  ('MARGARITA DE COCO', 'margarita coco'),
  ('MARGARITA DE COCO', 'margarita de coco'),
  ('MARGARITA DE FRESA', 'margarita de fresa'),
  ('MARGARITA DE FRESA', 'margarita de fresa fresa'),
  ('MARGARITA DE LIMÓN', 'margarita de limon'),
  ('MARGARITA DE LIMÓN', 'margarita de limon limon'),
  ('MARGARITA DE LIMÓN A LA ROCA', 'margarita de limon a la roca'),
  ('MARGARITA DE LIMÓN A LA ROCA', 'margarita limon roca'),
  ('MARGARITA DE TAMARINDO', 'margarita de tamarindo'),
  ('MARGARITA DE TAMARINDO', 'margarita de tamarindo tamarindo'),
  ('CHELADA', 'chelada'),
  ('MICHELADA DE MANGO', 'michelada de mango'),
  ('MICHELADA DE MANGO', 'michelada mango'),
  ('MICHELADA DE MANGO', 'michelada mango michelada mango'),
  ('MICHELADA DE TAMARINDO', 'michelada de tamarindo'),
  ('MICHELADA DE TAMARINDO', 'michelada de tamarindo michelada tam'),
  ('MICHELADA TRADICIONAL', 'michelada tradicional'),
  ('MICHELADA TRADICIONAL', 'michelada tradicional michelada trad'),
  ('MOJITO DE CHINOLA', 'mojito chinola'),
  ('MOJITO DE CHINOLA', 'mojito de chinola'),
  ('MOJITO DE COCO', 'mojito de coco'),
  ('MOJITO DE COCO', 'mojito de coco mojito coco'),
  ('MOJITO DE FRESA', 'mojito de fresa'),
  ('MOJITO DE FRESA', 'mojito de fresa mojito fresa'),
  ('MOJITO DE JAMAICA', 'mojito de jamaica'),
  ('MOJITO DE JAMAICA', 'mojito de jamaica mojito jamaica'),
  ('MOJITO DE LIMÓN', 'mojito de limon'),
  ('MOJITO DE LIMÓN', 'mojito de limon mojito limon'),
  ('APEROL SPRITZ', 'aperol spritz'),
  ('AVERNA', 'averna'),
  ('BAILEYS', 'baileys'),
  ('DIEGO RIVERA', 'diego rivera'),
  ('MANGONADA', 'mangonada'),
  ('MEZCALITA', 'mezcalita'),
  ('MEZCALITA', 'mezcalita nueva'),
  ('PALOMA', 'paloma'),
  ('PALOMA', 'paloma paloma'),
  ('PIÑA COLADA', 'pina colada'),
  ('SANGRÍA DE JAMAICA', 'sangria de jamaica'),
  ('SANGRÍA DE JAMAICA', 'sangria de jamaica sangria'),
  ('TEQUILA SUNRISE', 'tequila sunrise'),
  ('CONTRALUZ MEZCAL', 'contraluz mezcal'),
  ('MEZCAL 400 CONEJOS (SHOT)', 'mezcal 400 conejos'),
  ('MEZCAL 400 CONEJOS (SHOT)', 'mezcal 400 conejos shot'),
  ('OJO DE TIGRE', 'ojo de tigre'),
  ('BROWNIE A LA MODA', 'brownie a la moda'),
  ('CHURROS', 'churros'),
  ('PIE DE LIMÓN', 'pie de limon'),
  ('PIE DE LIMÓN', 'pie de limon pie limon'),
  ('DON JULIO AÑEJO (SHOT)', 'don julio anejo'),
  ('DON JULIO AÑEJO (SHOT)', 'don julio anejo shot'),
  ('DON JULIO REPOSADO (SHOT)', 'don julio reposado'),
  ('DON JULIO REPOSADO (SHOT)', 'don julio reposado shot'),
  ('FRANCISCO GONZALES EXTRA AÑEJO (SHOT)', 'francisco gonzales extra anejo'),
  ('FRANCISCO GONZALES EXTRA AÑEJO (SHOT)', 'francisco gonzales extra anejo shot'),
  ('AMOR MÍO BLANCO (SHOT)', 'amor mio blanco'),
  ('AMOR MÍO BLANCO (SHOT)', 'amor mio blanco shot'),
  ('CLASE AZUL REPOSADO (SHOT)', 'clase azul reposado'),
  ('CLASE AZUL REPOSADO (SHOT)', 'clase azul reposado shot'),
  ('GRAN CAVA DE ORO EXTRA VIEJO (SHOT)', 'gran cava de oro extra viejo shot'),
  ('GRAN CAVA DE ORO EXTRA VIEJO (SHOT)', 'grand cava de oro extra viejo'),
  ('GRAN CAVA DE ORO EXTRA VIEJO (SHOT)', 'grand cava de oro extra viejo shot'),
  ('GRAND MAYAN EXTRA VIEJO (SHOT)', 'grand mayan extra viejo'),
  ('GRAND MAYAN EXTRA VIEJO (SHOT)', 'grand mayan extra viejo shot'),
  ('1800 AÑEJO (SHOT)', '1800 anejo'),
  ('1800 AÑEJO (SHOT)', '1800 anejo shot'),
  ('1800 REPOSADO (SHOT)', '1800 reposado'),
  ('1800 REPOSADO (SHOT)', '1800 reposado shot'),
  ('1800 SILVER (SHOT)', '1800 silver'),
  ('1800 SILVER (SHOT)', '1800 silver shot'),
  ('1800 ULTRA AÑEJO CRISTALINO (SHOT)', '1800 ultra anejo cristalino'),
  ('1800 ULTRA AÑEJO CRISTALINO (SHOT)', '1800 ultra anejo cristalino shot'),
  ('AGAVITA REPOSADO (SHOT)', 'agavita reposado'),
  ('AGAVITA REPOSADO (SHOT)', 'agavita reposado shot'),
  ('AGAVITA SILVER (SHOT)', 'agavita silver'),
  ('AGAVITA SILVER (SHOT)', 'agavita silver shot'),
  ('GRAN MALO (SHOT)', 'gran malo'),
  ('GRAN MALO (SHOT)', 'gran malo shot'),
  ('HERRADURA AÑEJO (SHOT)', 'herradura anejo'),
  ('HERRADURA AÑEJO (SHOT)', 'herradura anejo shot'),
  ('HERRADURA REPOSADO (SHOT)', 'herradura reposado'),
  ('HERRADURA REPOSADO (SHOT)', 'herradura reposado shot'),
  ('HERRADURA SILVER (SHOT)', 'herradura silver'),
  ('HERRADURA SILVER (SHOT)', 'herradura silver shot'),
  ('HERRADURA ULTRA AÑEJO (SHOT)', 'herradura ultra anejo'),
  ('HERRADURA ULTRA AÑEJO (SHOT)', 'herradura ultra anejo shot'),
  ('JOSÉ CUERVO REPOSADO (SHOT)', 'jose cuervo reposado'),
  ('JOSÉ CUERVO REPOSADO (SHOT)', 'jose cuervo reposado shot'),
  ('JOSÉ CUERVO SILVER (SHOT)', 'jose cuervo silver'),
  ('JOSÉ CUERVO SILVER (SHOT)', 'jose cuervo silver shot'),
  ('COMBO ROSARIO', 'combo rosario'),
  ('FIESTÓN DE TACOS', 'a fieston de tacos'),
  ('FIESTÓN DE TACOS', 'fieston de tacos'),
  ('CARNES', 'carnes')
;

-- Nombres que NO deberían estar sueltos en la caja: las opciones de los
-- modificadores ("Cantarito 1800 Silver", "Extra queso").
drop table if exists _b0_otras;
create temp table _b0_otras (k text not null, que text not null);
insert into _b0_otras (k, que) values
  ('arizona all natural ice tea', 'opción Ice Tea de Arizona · Sabor'),
  ('arizona all natural strawberry kiwi', 'opción Strawberry Kiwi de Arizona · Sabor'),
  ('cachetadas ny steak', 'opción NY Steak de Cachetadas · Corte'),
  ('cachetadas ribeye', 'opción Ribeye de Cachetadas · Corte'),
  ('cachetadas tenderloin', 'opción Tenderloin de Cachetadas · Corte'),
  ('cantarito 1800 anejo', 'opción Añejo de Cantarito 1800 · Tequila'),
  ('cantarito 1800 anejo cristalino', 'opción Añejo Cristalino de Cantarito 1800 · Tequila'),
  ('cantarito 1800 reposado', 'opción Reposado de Cantarito 1800 · Tequila'),
  ('cantarito 1800 silver', 'opción Silver de Cantarito 1800 · Tequila'),
  ('cantarito agavita gold', 'opción Gold de Cantarito Agavita · Tequila'),
  ('cantarito agavita silver', 'opción Silver de Cantarito Agavita · Tequila'),
  ('cantarito don julio anejo', 'opción Añejo de Cantarito Don Julio · Tequila'),
  ('cantarito don julio extra anejo', 'opción Extra Añejo de Cantarito Don Julio · Tequila'),
  ('cantarito don julio reposado', 'opción Reposado de Cantarito Don Julio · Tequila'),
  ('cantarito herrtadura 818 reposado', 'opción 818 Reposado de Cantarito Herradura · Tequila'),
  ('cantarito herrtadura anejo', 'opción Añejo de Cantarito Herradura · Tequila'),
  ('cantarito herrtadura cristalino ultra', 'opción Cristalino Ultra de Cantarito Herradura · Tequila'),
  ('cantarito herrtadura reposado', 'opción Reposado de Cantarito Herradura · Tequila'),
  ('cantarito jose cuervo reposado', 'opción Reposado de Cantarito José Cuervo · Tequila'),
  ('cantarito jose cuervo silver', 'opción Silver de Cantarito José Cuervo · Tequila'),
  ('enchilada pollo', 'opción Pollo de Enchilada · Tipo'),
  ('enchilada pollo enchilada', 'opción Pollo de Enchilada · Tipo'),
  ('enchilada queso', 'opción Queso de Enchilada · Tipo'),
  ('enchilada queso a', 'opción Queso de Enchilada · Tipo'),
  ('enchilada suiza', 'opción Suiza de Enchilada · Tipo'),
  ('enchilada suiza enchilada suiza', 'opción Suiza de Enchilada · Tipo'),
  ('extra', 'opción Otro extra de Extras'),
  ('extra crema', 'opción Extra crema de Extras'),
  ('extra de carne', 'opción Extra de carne de Extras'),
  ('extra de pollo', 'opción Extra de pollo de Extras'),
  ('extra frijoles', 'opción Extra frijoles de Extras'),
  ('extra guacamole', 'opción Extra guacamole de Extras'),
  ('extra nachos', 'opción Extra nachos de Extras'),
  ('extra queso', 'opción Extra queso de Extras'),
  ('extra salsa ranchera', 'opción Extra salsa ranchera de Extras'),
  ('extra tortillas', 'opción Extra tortillas de Extras'),
  ('jarritos fruit punch', 'opción Fruit Punch de Jarritos · Sabor'),
  ('jarritos guayaba', 'opción Guayaba de Jarritos · Sabor'),
  ('jarritos limon', 'opción Limón de Jarritos · Sabor'),
  ('jarritos mandarina', 'opción Mandarina de Jarritos · Sabor'),
  ('jarritos pina', 'opción Piña de Jarritos · Sabor'),
  ('jarritos tamarindo', 'opción Tamarindo de Jarritos · Sabor'),
  ('jarritos toronja', 'opción Toronja de Jarritos · Sabor'),
  ('mangonada con alcohol', 'opción Con alcohol de Mangonada · Alcohol'),
  ('mangonada sin alcohol', 'opción Sin alcohol de Mangonada · Alcohol'),
  ('otro extra', 'opción Otro extra de Extras'),
  ('pico de gallo', 'opción Pico de gallo de Extras'),
  ('pina colada con alcohol', 'opción Con alcohol de Piña Colada · Alcohol'),
  ('pina colada sin alcohol', 'opción Sin alcohol de Piña Colada · Alcohol'),
  ('refresco boing mango', 'opción Boing Mango de Refresco · Sabor'),
  ('refresco coca cola', 'opción Coca Cola de Refresco · Sabor'),
  ('refresco sangria senorial', 'opción Sangría Señorial de Refresco · Sabor'),
  ('refresco sidral manzana', 'opción Sidral Manzana de Refresco · Sabor'),
  ('refresco soda', 'opción Soda de Refresco · Sabor'),
  ('refresco sprite', 'opción Sprite de Refresco · Sabor'),
  ('refresco squirt', 'opción Squirt de Refresco · Sabor'),
  ('refresco zero', 'opción Zero de Refresco · Sabor'),
  ('refrescos sabores merengue', 'opción Merengue de Refrescos Sabores · Sabor'),
  ('refrescos sabores rojo', 'opción Rojo de Refrescos Sabores · Sabor'),
  ('refrescos sabores soda', 'opción Soda de Refrescos Sabores · Sabor'),
  ('refrescos sabores sprite', 'opción Sprite de Refrescos Sabores · Sabor'),
  ('refrescos sabores uva', 'opción Uva de Refrescos Sabores · Sabor'),
  ('soda can canada dry blackberry', 'opción Canada Dry Blackberry de Soda Can · Sabor'),
  ('soda can canada dry ginger', 'opción Canada Dry Ginger de Soda Can · Sabor'),
  ('soda can dr pepper', 'opción Dr Pepper de Soda Can · Sabor'),
  ('soda can dr pepper blackberry', 'opción Dr Pepper Blackberry de Soda Can · Sabor'),
  ('soda can dr pepper cherry', 'opción Dr Pepper Cherry de Soda Can · Sabor'),
  ('soda can squirt toronja', 'opción Squirt Toronja de Soda Can · Sabor'),
  ('tostadas de cerdo', 'opción Cerdo de Tostadas · Tipo'),
  ('tostadas de cerdo tostadas', 'opción Cerdo de Tostadas · Tipo'),
  ('tostadas de chilorio', 'opción Chilorio de Tostadas · Tipo'),
  ('tostadas de chilorio tostada chilorio', 'opción Chilorio de Tostadas · Tipo'),
  ('tostadas de papa y chorizo', 'opción Papa y Chorizo de Tostadas · Tipo'),
  ('tostadas de papa y chorizo tostada papa chorizo', 'opción Papa y Chorizo de Tostadas · Tipo'),
  ('tostadas de pollo', 'opción Pollo de Tostadas · Tipo'),
  ('tostadas de pollo tost pollo', 'opción Pollo de Tostadas · Tipo'),
  ('tostadas de tinga de pollo', 'opción Tinga de Pollo de Tostadas · Tipo'),
  ('tostadas de tinga de pollo tost tinga', 'opción Tinga de Pollo de Tostadas · Tipo')
;

drop table if exists _b0_opciones;
create temp table _b0_opciones (
  grupo text not null, name text not null, delta numeric(12,2) not null, orden int not null
);
insert into _b0_opciones (grupo, name, delta, orden) values
  ('Cachetadas · Corte', 'Tenderloin', 0.00, 10),
  ('Cachetadas · Corte', 'NY Steak', 100.00, 20),
  ('Cachetadas · Corte', 'Ribeye', 200.00, 30),
  ('Enchilada · Tipo', 'Pollo', 0.00, 10),
  ('Enchilada · Tipo', 'Queso', 0.00, 20),
  ('Enchilada · Tipo', 'Suiza', 0.00, 30),
  ('Tostadas · Tipo', 'Cerdo', 0.00, 10),
  ('Tostadas · Tipo', 'Chilorio', 0.00, 20),
  ('Tostadas · Tipo', 'Papa y Chorizo', 0.00, 30),
  ('Tostadas · Tipo', 'Pollo', 0.00, 40),
  ('Tostadas · Tipo', 'Tinga de Pollo', 0.00, 50),
  ('Arizona · Sabor', 'Ice Tea', 0.00, 10),
  ('Arizona · Sabor', 'Strawberry Kiwi', 0.00, 20),
  ('Jarritos · Sabor', 'Tamarindo', 0.00, 10),
  ('Jarritos · Sabor', 'Mandarina', 0.00, 20),
  ('Jarritos · Sabor', 'Toronja', 0.00, 30),
  ('Jarritos · Sabor', 'Fruit Punch', 0.00, 40),
  ('Jarritos · Sabor', 'Limón', 0.00, 50),
  ('Jarritos · Sabor', 'Piña', 0.00, 60),
  ('Jarritos · Sabor', 'Guayaba', 0.00, 70),
  ('Refrescos Sabores · Sabor', 'Rojo', 0.00, 10),
  ('Refrescos Sabores · Sabor', 'Uva', 0.00, 20),
  ('Refrescos Sabores · Sabor', 'Merengue', 0.00, 30),
  ('Refrescos Sabores · Sabor', 'Sprite', 0.00, 40),
  ('Refrescos Sabores · Sabor', 'Soda', 25.00, 50),
  ('Soda Can · Sabor', 'Canada Dry Ginger', 0.00, 10),
  ('Soda Can · Sabor', 'Canada Dry Blackberry', 0.00, 20),
  ('Soda Can · Sabor', 'Dr Pepper', 25.00, 30),
  ('Soda Can · Sabor', 'Dr Pepper Blackberry', 25.00, 40),
  ('Soda Can · Sabor', 'Dr Pepper Cherry', 25.00, 50),
  ('Soda Can · Sabor', 'Squirt Toronja', 50.00, 60),
  ('Refresco · Sabor', 'Coca Cola', 0.00, 10),
  ('Refresco · Sabor', 'Sprite', 0.00, 20),
  ('Refresco · Sabor', 'Soda', 0.00, 30),
  ('Refresco · Sabor', 'Zero', 0.00, 40),
  ('Refresco · Sabor', 'Squirt', 50.00, 50),
  ('Refresco · Sabor', 'Sidral Manzana', 100.00, 60),
  ('Refresco · Sabor', 'Sangría Señorial', 100.00, 70),
  ('Refresco · Sabor', 'Boing Mango', 100.00, 80),
  ('Cantarito 1800 · Tequila', 'Silver', 0.00, 10),
  ('Cantarito 1800 · Tequila', 'Reposado', 0.00, 20),
  ('Cantarito 1800 · Tequila', 'Añejo', 50.00, 30),
  ('Cantarito 1800 · Tequila', 'Añejo Cristalino', 150.00, 40),
  ('Cantarito Agavita · Tequila', 'Silver', 0.00, 10),
  ('Cantarito Agavita · Tequila', 'Gold', 0.00, 20),
  ('Cantarito Don Julio · Tequila', 'Reposado', 0.00, 10),
  ('Cantarito Don Julio · Tequila', 'Añejo', 100.00, 20),
  ('Cantarito Don Julio · Tequila', 'Extra Añejo', 150.00, 30),
  ('Cantarito Herradura · Tequila', 'Reposado', 0.00, 10),
  ('Cantarito Herradura · Tequila', '818 Reposado', 0.00, 20),
  ('Cantarito Herradura · Tequila', 'Añejo', 50.00, 30),
  ('Cantarito Herradura · Tequila', 'Cristalino Ultra', 150.00, 40),
  ('Cantarito José Cuervo · Tequila', 'Silver', 0.00, 10),
  ('Cantarito José Cuervo · Tequila', 'Reposado', 0.00, 20),
  ('Mangonada · Alcohol', 'Sin alcohol', 0.00, 10),
  ('Mangonada · Alcohol', 'Con alcohol', 50.00, 20),
  ('Piña Colada · Alcohol', 'Con alcohol', 0.00, 10),
  ('Piña Colada · Alcohol', 'Sin alcohol', 0.00, 20)
;

drop table if exists _b0_extras;
create temp table _b0_extras (name text not null, delta numeric(12,2) not null, orden int not null);
insert into _b0_extras (name, delta, orden) values
  ('Extra crema', 50.00, 10),
  ('Extra salsa ranchera', 50.00, 20),
  ('Extra tortillas', 50.00, 30),
  ('Extra frijoles', 100.00, 40),
  ('Extra guacamole', 100.00, 50),
  ('Extra nachos', 100.00, 60),
  ('Otro extra', 100.00, 70),
  ('Pico de gallo', 100.00, 80),
  ('Extra de carne', 150.00, 90),
  ('Extra queso', 150.00, 100),
  ('Extra de pollo', 200.00, 110)
;

-- ▶ DECISIONES sobre lo que ya está en la caja (diagnóstico del 07-oct).
drop table if exists _b0_existentes;
create temp table _b0_existentes (
  existente    text not null,
  accion       text not null check (accion in ('ya_subido', 'fuera_csv', 'desactivar', 'mantener')),
  producto     text,            -- ya_subido: el producto de la lista
  area         text,            -- fuera_csv
  extras       boolean,         -- fuera_csv: lleva el grupo Extras
  impuestos    text,            -- fuera_csv: itbis_ley / ley / no_tocar
  precio_antes numeric(12,2),   -- ya_subido: para el rollback
  check ((accion = 'ya_subido') = (producto is not null)),
  check ((accion = 'fuera_csv') = (area is not null and impuestos is not null))
);
insert into _b0_existentes (existente, accion, producto, area, extras, impuestos, precio_antes) values
  ('BURRITO', 'ya_subido', 'BURRITO', null, null, null, 650.00),
  ('CHILAQUILES', 'ya_subido', 'CHILAQUILES', null, null, null, 700.00),
  ('CHIMICHANGA', 'ya_subido', 'CHIMICHANGA', null, null, null, 700.00),
  ('CHORIQUESO', 'ya_subido', 'CHORIQUESO', null, null, null, 600.00),
  ('FLAUTAS DE POLLO', 'ya_subido', 'FLAUTAS DE POLLO', null, null, null, 600.00),
  ('MINI FLAUTAS', 'ya_subido', 'MINI FLAUTAS', null, null, null, 500.00),
  ('NACHOS CON GUACAMOLE', 'ya_subido', 'NACHOS CON GUACAMOLE', null, null, null, 250.00),
  ('QUESADILLA DE CHORIZO', 'ya_subido', 'QUESADILLA DE CHORIZO', null, null, null, 650.00),
  ('QUESADILLA DE POLLO', 'ya_subido', 'QUESADILLA DE POLLO', null, null, null, 600.00),
  ('TACOS', 'ya_subido', 'TACOS', null, null, null, 650.00),
  ('TACOS AL PASTOR', 'ya_subido', 'TACOS AL PASTOR', null, null, null, 700.00),
  ('TACOS CHILORIO', 'ya_subido', 'TACOS DE CHILORIO', null, null, null, 700.00),
  ('TACOS DE BIRRIA', 'ya_subido', 'TACOS DE BIRRIA', null, null, null, 750.00),
  ('TACOS DE CARNITA MICHOACAN', 'ya_subido', 'TACOS DE CARNITAS MICHOACANAS', null, null, null, 650.00),
  ('UNIDAD DE TACO', 'ya_subido', 'UNIDAD DE TACO', null, null, null, 250.00),
  ('TOSTADAS', 'ya_subido', 'TOSTADAS', null, null, null, 650.00),
  ('ENCHILADA', 'ya_subido', 'ENCHILADA', null, null, null, 800.00),
  ('AGUA', 'ya_subido', 'AGUA DASANI', null, null, null, 50.00),
  ('JARRITOS', 'ya_subido', 'JARRITOS', null, null, null, 175.00),
  ('JUGOS NATURALES', 'ya_subido', 'JUGOS NATURALES', null, null, null, 0.00),
  ('REFRESCOS', 'ya_subido', 'REFRESCOS SABORES', null, null, null, 0.00),
  ('SODA CAN', 'ya_subido', 'SODA CAN', null, null, null, 0.00),
  ('ENCHILADA SUIZA', 'mantener', null, null, null, null, null),
  ('DELIVERY 100', 'desactivar', null, null, null, null, null),
  ('DELIVERY 150', 'desactivar', null, null, null, null, null),
  ('DELIVERY 200', 'desactivar', null, null, null, null, null),
  ('DELIVERY 250', 'desactivar', null, null, null, null, null),
  ('DELIVERY 300', 'desactivar', null, null, null, null, null),
  ('DELIVERY 350', 'desactivar', null, null, null, null, null),
  ('DELIVERY 400', 'desactivar', null, null, null, null, null),
  ('DELIVERY 450', 'desactivar', null, null, null, null, null),
  ('EXTRA GUACAMOLE', 'desactivar', null, null, null, null, null),
  ('Extra Queso', 'desactivar', null, null, null, null, null),
  ('EXTRA DE CARNE', 'desactivar', null, null, null, null, null),
  ('Extra Nachos', 'desactivar', null, null, null, null, null),
  ('TACO DOBLE DECKERS', 'fuera_csv', null, 'cocina', true, 'itbis_ley', null),
  ('TACOS FIESTAS', 'fuera_csv', null, 'cocina', true, 'itbis_ley', null),
  ('GANSITO MARINELA GRANDE', 'fuera_csv', null, 'bar', false, 'itbis_ley', null),
  ('Carne Cocida Natural xlb', 'fuera_csv', null, 'cocina', false, 'no_tocar', null)
;

-- Lo que la carga escoge (lo llena el bloque de abajo; el reporte lo lee).
drop table if exists _b0_area_sel;
create temp table _b0_area_sel (area text primary key, id uuid not null, code text not null);
drop table if exists _b0_ley;
create temp table _b0_ley (id uuid not null, copiada boolean not null);

do $$
declare
  v_business   uuid := 'b0bd6f20-850c-4e9a-85ae-4cd619e1a0ee';
  v_ley_origen uuid;
  v_presets    jsonb;
  v_grupo_ex   text := 'Extras';
  v_esperados  int;
  v_itbis_id   uuid;
  v_ley_id     uuid;
  v_ley_src    uuid;
  v_cocina_id   uuid;
  v_cocina_code text;
  v_bar_id      uuid;
  v_bar_code    text;
  v_menu_id    uuid;
  v_ex_id      uuid;
  v_rerun      boolean;
  v_n          int;
  v_list       text;
begin
  select count(*) into v_esperados from _b0_productos;
  select ley_origen, presets into v_ley_origen, v_presets from _b0_cfg;

  -- =========================================================================
  -- 1) GUARDAS: se comprueba todo ANTES de escribir una sola fila.
  -- =========================================================================

  if not exists (select 1 from public.businesses where id = v_business) then
    raise exception 'El negocio % no existe.', v_business;
  end if;

  -- 1a0) Después de 02_modificadores_foodtropolis.sql esta carga ya no se
  --      re-corre: volvería a crear los grupos que el 02 quitó y a ponerle
  --      precio a SODA CAN, REFRESCOS y JUGOS NATURALES (cobro doble).
  if exists (select 1 from public.modifier_groups
             where business_id = v_business
               and pg_temp.norm(name) in ('sabor soda', 'proteina 3', 'sabores jugos')) then
    raise exception
      'Ya se corrió 02_modificadores_foodtropolis.sql: esta carga no se vuelve a correr. '
      'Los cambios van en el 02 o en la app.';
  end if;

  -- 1a) La lista: sin nombres repetidos y con categorías conocidas.
  select string_agg(n, ', ') into v_list
  from (select pg_temp.k(name) as n from _b0_productos group by 1 having count(*) > 1) d;
  if v_list is not null then
    raise exception 'La lista trae nombres repetidos: %', v_list;
  end if;
  if exists (select 1 from _b0_productos p
             where not exists (select 1 from _b0_categorias c where c.name = p.categoria)) then
    raise exception 'Hay productos con una categoría que no está en _b0_categorias.';
  end if;

  -- 1b) ITBIS 18%: uno solo, activo, sin is_service_fee.
  select count(*) into v_n
  from public.taxes t
  where t.business_id = v_business and t.name ilike '%itbis%'
    and t.rate = 18 and coalesce(t.is_active, true);
  if v_n <> 1 then
    select string_agg(format('%s %s%% (%s)', t.name, t.rate,
             case when coalesce(t.is_active, true) then 'activo' else 'INACTIVO' end), ', ')
      into v_list
    from public.taxes t where t.business_id = v_business;
    raise exception
      'Debe haber UN ITBIS 18%% activo y hay % (impuestos del negocio: %).',
      v_n, coalesce(v_list, 'ninguno');
  end if;
  select t.id into v_itbis_id
  from public.taxes t
  where t.business_id = v_business and t.name ilike '%itbis%'
    and t.rate = 18 and coalesce(t.is_active, true);

  -- 1c) Ley 10%: la del negocio, o la de Ágora para copiarla.
  select count(*), string_agg(t.name, ', ') into v_n, v_list
  from public.taxes t
  where t.business_id = v_business and t.rate = 10
    and t.name not ilike '%itbis%' and coalesce(t.is_active, true);
  if v_n > 1 then
    raise exception 'Hay % impuestos activos del 10%% (%). Deja uno solo.', v_n, v_list;
  elsif v_n = 1 then
    select t.id into v_ley_id
    from public.taxes t
    where t.business_id = v_business and t.rate = 10
      and t.name not ilike '%itbis%' and coalesce(t.is_active, true);
  else
    select count(*), string_agg(t.name, ', ') into v_n, v_list
    from public.taxes t
    where t.business_id = v_ley_origen and t.rate = 10
      and t.name not ilike '%itbis%' and coalesce(t.is_active, true);
    if v_n <> 1 then
      raise exception
        'Para copiar la Ley, la sucursal % debe tener UNA Ley 10%% activa y tiene % (%).',
        v_ley_origen, v_n, coalesce(v_list, 'ninguna');
    end if;
    select t.id into v_ley_src
    from public.taxes t
    where t.business_id = v_ley_origen and t.rate = 10
      and t.name not ilike '%itbis%' and coalesce(t.is_active, true);

    -- Una columna con un uuid (fuera de id y business_id) apuntaría a algo
    -- de Ágora: no se copia a ciegas.
    select string_agg(j.key, ', ') into v_list
    from public.taxes t, jsonb_each_text(to_jsonb(t)) j
    where t.id = v_ley_src
      and j.key not in ('id', 'business_id')
      and j.value ~* '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$';
    if v_list is not null then
      raise exception 'La Ley de Ágora trae columnas con uuid (%): créala a mano en la app.', v_list;
    end if;
    if exists (select 1 from public.taxes where id = v_ley_src and coalesce(is_service_fee, false)) then
      raise exception 'La Ley de Ágora tiene is_service_fee = true: no se copia.';
    end if;
  end if;

  -- 1d) Nada de cobrar un impuesto dos veces.
  if exists (select 1 from public.taxes
             where id in (v_itbis_id, v_ley_id) and coalesce(is_service_fee, false)) then
    raise exception
      'El ITBIS o la Ley tienen is_service_fee = true: vinculados al producto se facturan DOBLE.';
  end if;
  if exists (select 1 from public.business_settings
             where business_id = v_business and coalesce(service_fee_enabled, false)) then
    raise exception
      'service_fee_enabled está en true: la Ley saldría por producto Y por orden. '
      'Dime si es intencional antes de cargar.';
  end if;

  -- 1e) Lo que ya está en la caja.
  --     Re-corrida: si ya existen los grupos de variantes de esta carga
  --     ("Cantarito 1800 · Tequila"...), los productos con el nombre exacto de
  --     la lista son de la corrida anterior y se re-alinean sin preguntar.
  v_rerun := exists (select 1 from public.modifier_groups g
                     where g.business_id = v_business
                       and pg_temp.norm(g.name) in (select pg_temp.norm(grupo) from _b0_productos
                                                    where grupo is not null));

  -- Cada producto ACTIVO del negocio tiene que tener su decisión.
  select string_agg(format('"%s"%s', mi.name,
           coalesce(' → ' || (select string_agg(x.que, ' | ')
                              from (select c.producto as que from _b0_claves c
                                    where c.k = pg_temp.k(mi.name)
                                    union
                                    select o.que from _b0_otras o
                                    where o.k = pg_temp.k(mi.name)) x), '')),
           '; ' order by mi.name) into v_list
  from public.menu_items mi
  where mi.business_id = v_business and mi.is_active
    and not exists (select 1 from _b0_existentes e where pg_temp.k(e.existente) = pg_temp.k(mi.name))
    and not (v_rerun and exists (select 1 from _b0_productos p
                                 where pg_temp.k(p.name) = pg_temp.k(mi.name)));
  if v_list is not null then
    raise exception
      'Estos productos están en la caja y no tienen decisión en _b0_existentes '
      '(corre otra vez 00_diagnostico.sql): %', v_list;
  end if;

  select string_agg(format('"%s" (%s)', e.existente, x.n), ', ') into v_list
  from _b0_existentes e
  cross join lateral (select count(*) as n from public.menu_items mi
                      where mi.business_id = v_business
                        and pg_temp.k(mi.name) = pg_temp.k(e.existente)) x
  where x.n <> 1;
  if v_list is not null then
    raise exception
      'En _b0_existentes hay nombres que no están UNA vez en la caja (veces): %. '
      'Vuelve a correr el diagnóstico.', v_list;
  end if;

  select string_agg(format('"%s" → %s', e.existente, e.producto), ', ') into v_list
  from _b0_existentes e
  where e.accion = 'ya_subido'
    and not exists (select 1 from _b0_claves c
                    where c.producto = e.producto and c.k = pg_temp.k(e.existente));
  if v_list is not null then
    raise exception 'Estos "ya_subido" no casan con ese producto de la lista: %', v_list;
  end if;

  select string_agg(producto, ', ') into v_list
  from (select producto from _b0_existentes where accion = 'ya_subido'
        group by producto having count(*) > 1) d;
  if v_list is not null then
    raise exception 'Hay dos productos de la caja marcados como el mismo de la lista: %', v_list;
  end if;

  -- Un producto de la lista que casa con otro producto de la caja (que no es
  -- su ya_subido) se insertaría repetido.
  select string_agg(format('"%s" → %s', mi.name, c.producto), ', ') into v_list
  from _b0_claves c
  join public.menu_items mi
    on mi.business_id = v_business and pg_temp.k(mi.name) = c.k
  where not exists (select 1 from _b0_existentes e
                    where e.accion = 'ya_subido' and e.producto = c.producto
                      and pg_temp.k(e.existente) = pg_temp.k(mi.name))
    and not (v_rerun and pg_temp.k(mi.name) = pg_temp.k(c.producto));
  if v_list is not null then
    raise exception 'Estos productos de la caja casan con la lista y la carga los duplicaría: %', v_list;
  end if;

  -- 1f) Menú: 0 se crea, 1 se reusa, más de 1 aborta.
  select count(*), string_agg(name, ', ' order by created_at) into v_n, v_list
  from public.menus
  where business_id = v_business and coalesce(is_active, true);
  if v_n > 1 then
    raise exception 'El negocio tiene % menús activos (%). Dime a cuál van los productos.',
      v_n, v_list;
  end if;

  -- 1g) Grupos de modificadores: no puede haber dos con el mismo nombre.
  select string_agg(n, ', ') into v_list
  from (select pg_temp.norm(g.name) as n from public.modifier_groups g
        where g.business_id = v_business
          and (pg_temp.norm(g.name) = pg_temp.norm(v_grupo_ex)
               or pg_temp.norm(g.name) in (select pg_temp.norm(grupo) from _b0_productos
                                           where grupo is not null))
        group by 1 having count(*) > 1) d;
  if v_list is not null then
    raise exception 'Hay grupos de modificadores repetidos: %', v_list;
  end if;

  -- =========================================================================
  -- 2) LEY Y ÁREAS DE PRODUCCIÓN
  -- =========================================================================

  if v_ley_id is null then
    v_ley_id := gen_random_uuid();
    insert into public.taxes
    select (jsonb_populate_record(
              null::public.taxes,
              to_jsonb(t) || jsonb_build_object('id', v_ley_id, 'business_id', v_business,
                                                'created_at', now()))).*
    from public.taxes t
    where t.id = v_ley_src;
    insert into _b0_ley (id, copiada) values (v_ley_id, true);
  else
    insert into _b0_ley (id, copiada) values (v_ley_id, false);
  end if;

  -- COCINA
  select a.id, a.code into v_cocina_id, v_cocina_code
  from public.print_areas a
  where a.business_id = v_business and a.is_active
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
  where a.business_id = v_business and a.is_active
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

  insert into _b0_area_sel (area, id, code)
  values ('cocina', v_cocina_id, v_cocina_code), ('bar', v_bar_id, v_bar_code);

  -- =========================================================================
  -- 3) MENÚ Y CATEGORÍAS
  --    Las que ya existen se reusan (por letras y números: "TACOS 🌮" =
  --    "Tacos"); se crean solo las que van a tener un producto nuevo.
  -- =========================================================================

  select id into v_menu_id
  from public.menus
  where business_id = v_business and coalesce(is_active, true)
  order by created_at limit 1;
  if v_menu_id is null then
    v_menu_id := gen_random_uuid();
    insert into public.menus (id, business_id, name, is_active)
    values (v_menu_id, v_business, 'Menú Principal', true);
  end if;

  insert into public.categories (id, business_id, name, position, is_active)
  select gen_random_uuid(), v_business, c.name, c.posicion, true
  from _b0_categorias c
  where not exists (select 1 from public.categories x
                    where x.business_id = v_business and pg_temp.k(x.name) = pg_temp.k(c.name))
    and exists (select 1 from _b0_productos p
                where p.categoria = c.name
                  and not exists (select 1 from _b0_existentes e
                                  where e.accion = 'ya_subido' and e.producto = p.name));

  update public.categories x set is_active = true
  from _b0_categorias c
  where x.business_id = v_business
    and pg_temp.k(x.name) = pg_temp.k(c.name) and not x.is_active
    and exists (select 1 from _b0_productos p where p.categoria = c.name);

  -- =========================================================================
  -- 4) PRODUCTOS
  -- =========================================================================

  -- Reemplazados por un modificador o por el cargo de delivery.
  update public.menu_items mi
  set is_active = false, updated_at = now()
  from _b0_existentes e
  where e.accion = 'desactivar'
    and mi.business_id = v_business and pg_temp.k(mi.name) = pg_temp.k(e.existente)
    and mi.is_active;

  -- Destino de cada producto de la lista.
  drop table if exists _b0_dest;
  create temp table _b0_dest on commit drop as
  select p.name,
         (select mi.id from _b0_existentes e
          join public.menu_items mi
            on mi.business_id = v_business and pg_temp.k(mi.name) = pg_temp.k(e.existente)
          where e.accion = 'ya_subido' and e.producto = p.name) as existente_id,
         cat.id as category_id,
         c.bebida
  from _b0_productos p
  join _b0_categorias c on c.name = p.categoria
  left join lateral (
    select x.id from public.categories x
    where x.business_id = v_business and pg_temp.k(x.name) = pg_temp.k(p.categoria)
    order by x.is_active desc, x.created_at
    limit 1
  ) cat on true;

  insert into public.menu_items (
    id, business_id, category_id, name, price, cost, description,
    tax_mode, is_active, is_beverage, position, print_area_code
  )
  select gen_random_uuid(), v_business, d.category_id, p.name, p.price, null, p.description,
         'inclusive', true, d.bebida, p.posicion, s.code
  from _b0_productos p
  join _b0_dest d on d.name = p.name
  join _b0_area_sel s on s.area = p.area
  where d.existente_id is null
    and not exists (select 1 from public.menu_items mi
                    where mi.business_id = v_business
                      and pg_temp.k(mi.name) = pg_temp.k(p.name));

  -- Re-corrida: lo que esta misma carga insertó antes se re-alinea a la lista.
  update public.menu_items mi
  set price = p.price, category_id = d.category_id, description = p.description,
      tax_mode = 'inclusive', is_active = true, is_beverage = d.bebida,
      position = p.posicion, updated_at = now()
  from _b0_productos p
  join _b0_dest d on d.name = p.name
  where d.existente_id is null
    and mi.business_id = v_business and pg_temp.k(mi.name) = pg_temp.k(p.name)
    and (mi.price, mi.category_id, coalesce(mi.description, ''), mi.tax_mode, mi.is_active,
         mi.is_beverage, mi.position)
        is distinct from
        (p.price, d.category_id, coalesce(p.description, ''), 'inclusive', true,
         d.bebida, p.posicion);

  -- Ya subidos: conservan nombre y categoría; toman el precio del CSV.
  update public.menu_items mi
  set price = p.price, tax_mode = 'inclusive', is_active = true,
      description = coalesce(mi.description, p.description), updated_at = now()
  from _b0_productos p
  join _b0_dest d on d.name = p.name
  where mi.id = d.existente_id
    and (mi.price, mi.tax_mode, mi.is_active) is distinct from (p.price, 'inclusive', true);

  drop table if exists _b0_ids;
  create temp table _b0_ids on commit drop as
  select coalesce(d.existente_id, mi.id) as id, p.name,
         (d.existente_id is not null) as ya_subido
  from _b0_productos p
  join _b0_dest d on d.name = p.name
  left join public.menu_items mi
    on d.existente_id is null
   and mi.business_id = v_business and pg_temp.k(mi.name) = pg_temp.k(p.name);

  -- Todo lo que la carga deja en la caja: la lista + lo que no está en el CSV.
  drop table if exists _b0_scope;
  create temp table _b0_scope on commit drop as
  select i.id, p.area, p.impuestos, (p.area = 'cocina') as extras, p.grupo
  from _b0_ids i join _b0_productos p on p.name = i.name
  union all
  select mi.id, e.area, e.impuestos, coalesce(e.extras, false), null
  from _b0_existentes e
  join public.menu_items mi
    on mi.business_id = v_business and pg_temp.k(mi.name) = pg_temp.k(e.existente)
  where e.accion = 'fuera_csv';

  -- =========================================================================
  -- 5) IMPUESTOS: exactamente el juego decidido ('no_tocar' se salta).
  -- =========================================================================

  drop table if exists _b0_tx;
  create temp table _b0_tx on commit drop as
  select s.id, t.tax_id
  from _b0_scope s
  cross join lateral (
    select v_itbis_id as tax_id where s.impuestos = 'itbis_ley'
    union all
    select v_ley_id where s.impuestos in ('itbis_ley', 'ley')
  ) t;

  delete from public.menu_item_taxes x
  using _b0_scope s
  where s.impuestos <> 'no_tocar' and x.item_id = s.id
    and not exists (select 1 from _b0_tx t where t.id = s.id and t.tax_id = x.tax_id);

  insert into public.menu_item_taxes (item_id, tax_id)
  select t.id, t.tax_id from _b0_tx t
  where not exists (select 1 from public.menu_item_taxes x
                    where x.item_id = t.id and x.tax_id = t.tax_id);

  -- =========================================================================
  -- 6) ÁREA DE PRODUCCIÓN: exactamente la suya, en la N:M y en el legacy.
  -- =========================================================================

  delete from public.menu_item_print_areas x
  using _b0_scope s
  join _b0_area_sel a on a.area = s.area
  where x.menu_item_id = s.id and x.print_area_id <> a.id;

  insert into public.menu_item_print_areas (menu_item_id, print_area_id)
  select s.id, a.id
  from _b0_scope s
  join _b0_area_sel a on a.area = s.area
  where not exists (select 1 from public.menu_item_print_areas x
                    where x.menu_item_id = s.id and x.print_area_id = a.id);

  update public.menu_items mi
  set print_area_code = a.code, updated_at = now()
  from _b0_scope s
  join _b0_area_sel a on a.area = s.area
  where mi.id = s.id and mi.print_area_code is distinct from a.code;

  -- =========================================================================
  -- 7) ENLACE AL MENÚ: sin esto el producto no aparece en la caja.
  -- =========================================================================

  insert into public.menu_item_links (menu_id, item_id, position)
  select v_menu_id, s.id, coalesce(p.posicion, 0)
  from _b0_scope s
  left join _b0_ids i on i.id = s.id
  left join _b0_productos p on p.name = i.name
  where not exists (select 1 from public.menu_item_links l
                    where l.menu_id = v_menu_id and l.item_id = s.id);

  -- =========================================================================
  -- 8) MODIFICADORES
  --    a) variantes: 'single', min = max = 1 → la caja no deja agregar el
  --       producto sin escoger ("Debes completar: ...");
  --    b) Extras: 'multiple', min 0, sin máximo.
  -- =========================================================================

  insert into public.modifier_groups (
    id, business_id, name, min_select, max_select, is_active,
    display_type, selection_mode, is_required, free_qty, max_qty_per_option, sort_order
  )
  select gen_random_uuid(), v_business, p.grupo, 1, 1, true,
         'single', 'modifier', true, 0, 1, 10
  from _b0_productos p
  where p.grupo is not null
    and not exists (select 1 from public.modifier_groups g
                    where g.business_id = v_business
                      and pg_temp.norm(g.name) = pg_temp.norm(p.grupo));

  update public.modifier_groups g
  set min_select = 1, max_select = 1, is_active = true,
      display_type = 'single', is_required = true
  from _b0_productos p
  where p.grupo is not null and g.business_id = v_business
    and pg_temp.norm(g.name) = pg_temp.norm(p.grupo)
    and (g.min_select, g.max_select, g.is_active, g.display_type, g.is_required)
        is distinct from (1, 1, true, 'single', true);

  select id into v_ex_id
  from public.modifier_groups
  where business_id = v_business and pg_temp.norm(name) = pg_temp.norm(v_grupo_ex);
  if v_ex_id is null then
    v_ex_id := gen_random_uuid();
    insert into public.modifier_groups (
      id, business_id, name, min_select, max_select, is_active,
      display_type, selection_mode, is_required, free_qty, max_qty_per_option, sort_order
    ) values (
      v_ex_id, v_business, v_grupo_ex, 0, 0, true,
      'multiple', 'extra', false, 0, 1, 20
    );
  else
    update public.modifier_groups
    set min_select = 0, is_active = true, display_type = 'multiple', is_required = false
    where id = v_ex_id
      and (min_select, is_active, display_type, is_required)
          is distinct from (0, true, 'multiple', false);
  end if;

  drop table if exists _b0_ops;
  create temp table _b0_ops on commit drop as
  select g.id as group_id, o.name, o.delta, o.orden
  from _b0_opciones o
  join public.modifier_groups g
    on g.business_id = v_business and pg_temp.norm(g.name) = pg_temp.norm(o.grupo)
  union all
  select v_ex_id, e.name, e.delta, e.orden
  from _b0_extras e;

  insert into public.modifiers (id, business_id, group_id, name, price_delta, is_active, sort_order)
  select gen_random_uuid(), v_business, o.group_id, o.name, o.delta, true, o.orden
  from _b0_ops o
  where not exists (select 1 from public.modifiers m
                    where m.group_id = o.group_id and pg_temp.norm(m.name) = pg_temp.norm(o.name));

  update public.modifiers m
  set price_delta = o.delta, is_active = true, sort_order = o.orden
  from _b0_ops o
  where m.group_id = o.group_id and pg_temp.norm(m.name) = pg_temp.norm(o.name)
    and (m.price_delta, m.is_active, m.sort_order) is distinct from (o.delta, true, o.orden);

  insert into public.menu_item_groups (menu_item_id, group_id)
  select s.id, g.id
  from _b0_scope s
  join public.modifier_groups g
    on g.business_id = v_business and pg_temp.norm(g.name) = pg_temp.norm(s.grupo)
  where s.grupo is not null
    and not exists (select 1 from public.menu_item_groups y
                    where y.menu_item_id = s.id and y.group_id = g.id);

  insert into public.menu_item_groups (menu_item_id, group_id)
  select s.id, v_ex_id
  from _b0_scope s
  where s.extras
    and not exists (select 1 from public.menu_item_groups y
                    where y.menu_item_id = s.id and y.group_id = v_ex_id);

  -- =========================================================================
  -- 9) MONTOS RÁPIDOS DEL DELIVERY (solo si no hay ninguno)
  -- =========================================================================

  if exists (select 1 from information_schema.columns
             where table_schema = 'public' and table_name = 'business_settings'
               and column_name = 'delivery_fee_presets') then
    execute $q$
      update public.business_settings
      set delivery_fee_presets = $1
      where business_id = $2
        and coalesce(delivery_fee_presets, '[]'::jsonb) = '[]'::jsonb
    $q$ using v_presets, v_business;
  end if;

  -- =========================================================================
  -- 10) VERIFICACIÓN DENTRO DE LA TRANSACCIÓN: cualquier fallo revierte TODO.
  -- =========================================================================

  select count(*) into v_n
  from _b0_productos p
  where (select count(*) from _b0_ids i
         join public.menu_items mi on mi.id = i.id
         where i.name = p.name and mi.is_active) <> 1;
  if v_n > 0 or (select count(distinct id) from _b0_ids) <> v_esperados then
    raise exception '% productos de la lista no quedaron (o quedaron repetidos). Revertido.', v_n;
  end if;

  select string_agg(p.name, ', ') into v_list
  from _b0_productos p
  where (select count(*) from public.menu_items mi
         where mi.business_id = v_business and mi.is_active
           and pg_temp.k(mi.name) = pg_temp.k(p.name)) > 1;
  if v_list is not null then
    raise exception 'Quedaron productos activos repetidos en la caja: %. Revertido.', v_list;
  end if;

  select count(*) into v_n
  from _b0_ids i
  join public.menu_items mi on mi.id = i.id
  join _b0_productos p on p.name = i.name
  join _b0_dest d on d.name = i.name
  where mi.price <> p.price or mi.tax_mode <> 'inclusive'
     or (not i.ya_subido and mi.category_id is distinct from d.category_id);
  if v_n > 0 then
    raise exception '% productos con precio, modo de impuesto o categoría incorrectos. Revertido.', v_n;
  end if;

  select count(*) into v_n
  from _b0_scope s
  where s.impuestos <> 'no_tocar'
    and ((select count(*) from public.menu_item_taxes x where x.item_id = s.id)
           <> (select count(*) from _b0_tx t where t.id = s.id)
         or exists (select 1 from _b0_tx t
                    where t.id = s.id
                      and not exists (select 1 from public.menu_item_taxes x
                                      where x.item_id = s.id and x.tax_id = t.tax_id)));
  if v_n > 0 then
    raise exception '% productos con un juego de impuestos distinto al decidido. Revertido.', v_n;
  end if;

  -- TODO producto activo del negocio: una sola área, existente y activa, y el
  -- legacy igual a su code. Es lo que evita que "Enviar a cocina" falle.
  select string_agg(mi.name, ', ') into v_list
  from public.menu_items mi
  where mi.business_id = v_business and mi.is_active
    and not ((select count(*) from public.menu_item_print_areas x where x.menu_item_id = mi.id) = 1
             and exists (select 1 from public.menu_item_print_areas x
                         join public.print_areas a on a.id = x.print_area_id
                         where x.menu_item_id = mi.id and a.is_active
                           and a.business_id = v_business
                           and a.code = mi.print_area_code));
  if v_list is not null then
    raise exception 'Productos activos sin un área válida: %. Revertido.', v_list;
  end if;

  select count(*) into v_n
  from _b0_scope s
  join _b0_area_sel a on a.area = s.area
  where not exists (select 1 from public.menu_item_print_areas x
                    where x.menu_item_id = s.id and x.print_area_id = a.id)
     or not exists (select 1 from public.menu_item_links l
                    where l.menu_id = v_menu_id and l.item_id = s.id);
  if v_n > 0 then
    raise exception '% productos en otra área o fuera del menú. Revertido.', v_n;
  end if;

  select count(*) into v_n
  from _b0_scope s
  where (s.grupo is not null
         and not exists (select 1 from public.menu_item_groups y
                         join public.modifier_groups g on g.id = y.group_id
                         where y.menu_item_id = s.id
                           and pg_temp.norm(g.name) = pg_temp.norm(s.grupo)))
     or (s.extras
         and not exists (select 1 from public.menu_item_groups y
                         where y.menu_item_id = s.id and y.group_id = v_ex_id));
  if v_n > 0 then
    raise exception '% productos sin su modificador o sin Extras. Revertido.', v_n;
  end if;

  select count(*) into v_n
  from _b0_ops o
  where (select count(*) from public.modifiers m
         where m.group_id = o.group_id and pg_temp.norm(m.name) = pg_temp.norm(o.name)
           and m.is_active and m.price_delta = o.delta) <> 1;
  if v_n > 0 then
    raise exception '% opciones de modificador faltan o tienen otro precio. Revertido.', v_n;
  end if;

  if exists (select 1 from _b0_existentes e
             join public.menu_items mi
               on mi.business_id = v_business and pg_temp.k(mi.name) = pg_temp.k(e.existente)
             where e.accion = 'desactivar' and mi.is_active) then
    raise exception 'Quedó activo un producto que había que desactivar. Revertido.';
  end if;

  raise notice 'OK: % productos de la lista (% ya estaban), % fuera del CSV, cocina=%, bar=%, '
               'Ley copiada=%, re-corrida=%. Commit.',
    v_esperados, (select count(*) from _b0_ids where ya_subido),
    (select count(*) from _b0_existentes where accion = 'fuera_csv'),
    v_cocina_code, v_bar_code, (select copiada from _b0_ley), v_rerun;
end $$;

commit;

-- ============================================================================
-- REPORTE: todas las filas deben decir ✓, menos las impresoras (hasta que las
-- vincules en la app) y Carne Cocida (decidir con el dueño).
-- ============================================================================

with
biz as (
  select 'b0bd6f20-850c-4e9a-85ae-4cd619e1a0ee'::uuid as id
),
esperados as (select count(*)::int as n from _b0_productos),
items as (
  select mi.*, p.price as precio_lista, p.area, p.grupo, p.impuestos as imp_lista,
         p.name as nombre_lista, (e.existente is not null) as ya_subido, e.precio_antes
  from _b0_productos p
  left join _b0_existentes e on e.accion = 'ya_subido' and e.producto = p.name
  join public.menu_items mi
    on mi.business_id = (select id from biz)
   and pg_temp.k(mi.name) = pg_temp.k(coalesce(e.existente, p.name))
  where mi.is_active
),
fuera as (
  select mi.*, e.area, e.impuestos as imp_lista, coalesce(e.extras, false) as con_extras
  from _b0_existentes e
  join public.menu_items mi
    on mi.business_id = (select id from biz) and pg_temp.k(mi.name) = pg_temp.k(e.existente)
  where e.accion = 'fuera_csv'
),
activos as (
  select mi.* from public.menu_items mi
  where mi.business_id = (select id from biz) and mi.is_active
),
tx as (
  select t.* from public.taxes t
  where t.business_id = (select id from biz) and coalesce(t.is_active, true)
),
itbis as (select * from tx where name ilike '%itbis%' and rate = 18 limit 1),
ley as (select * from tx where id = (select id from _b0_ley)),
juego_de as (
  select a.id, a.name,
         coalesce((select string_agg(format('%s %s%%', t.name, t.rate), ' + '
                                     order by t.rate desc, t.name)
                   from public.menu_item_taxes x join public.taxes t on t.id = x.tax_id
                   where x.item_id = a.id), 'SIN IMPUESTO') as juego,
         coalesce((select sum(t.rate) from public.menu_item_taxes x
                   join public.taxes t on t.id = x.tax_id where x.item_id = a.id), 0) as tasa,
         coalesce((select i.imp_lista from items i where i.id = a.id),
                  (select f.imp_lista from fuera f where f.id = a.id)) as esperado
  from activos a
),
juego_ok as (
  select j.*,
         case j.esperado
           when 'itbis_ley' then j.juego = (select format('%s %s%% + %s %s%%', i.name, i.rate, l.name, l.rate)
                                            from itbis i, ley l)
           when 'ley' then j.juego = (select format('%s %s%%', name, rate) from ley)
           when 'no_tocar' then true
           else false end as ok
  from juego_de j
),
ajustes as (
  select coalesce((s.j->>'kitchen_enabled')::boolean, true) as cocina_encendida,
         coalesce((s.j->>'service_fee_enabled')::boolean, false) as ley_por_orden,
         s.j->'delivery_fee_presets' as presets
  from (select to_jsonb(bs) as j from public.business_settings bs
        where bs.business_id = (select id from biz)
        union all
        select '{}'::jsonb
        where not exists (select 1 from public.business_settings bs
                          where bs.business_id = (select id from biz))) s
),
sel as (
  select s.area, s.id, a.name, a.code,
         (select count(*) from public.print_area_printers p where p.area_id = s.id) as impresoras
  from _b0_area_sel s
  join public.print_areas a on a.id = s.id
),
destino as (
  select id, area from items union all select id, area from fuera
),
nm as (
  select a.id, a.name, d.area,
         (select count(*) from public.menu_item_print_areas x where x.menu_item_id = a.id) as n_areas,
         exists (select 1 from public.menu_item_print_areas x
                 join sel s on s.id = x.print_area_id and s.area = d.area
                 where x.menu_item_id = a.id) as en_su_area,
         exists (select 1 from public.menu_item_print_areas x
                 join public.print_areas pa on pa.id = x.print_area_id
                 where x.menu_item_id = a.id and pa.is_active and pa.code = a.print_area_code)
           as legacy_ok
  from activos a
  left join destino d on d.id = a.id
),
grupos as (
  select g.*,
         (select count(*) from public.modifiers m where m.group_id = g.id and m.is_active) as n_op
  from public.modifier_groups g
  where g.business_id = (select id from biz)
),
extras as (select * from grupos where pg_temp.norm(name) = pg_temp.norm('Extras')),
variantes_ok as (
  select i.id
  from items i
  join grupos g on pg_temp.norm(g.name) = pg_temp.norm(i.grupo)
  where g.min_select = 1 and g.max_select = 1 and g.is_active
    and not exists (select 1 from _b0_opciones o
                    where o.grupo = i.grupo
                      and not exists (select 1 from public.modifiers m
                                      where m.group_id = g.id and m.is_active
                                        and pg_temp.norm(m.name) = pg_temp.norm(o.name)
                                        and m.price_delta = o.delta))
    and exists (select 1 from public.menu_item_groups y
                where y.menu_item_id = i.id and y.group_id = g.id)
),
con_extras as (
  select id from items where area = 'cocina'
  union
  select id from fuera where con_extras
),
r(orden, concepto, encontrado, esperado, ok) as (
  select 1, 'Productos de la lista activos en la caja',
         format('%s (%s nuevos + %s ya subidos)', (select count(*) from items),
                (select count(*) from items where not ya_subido),
                (select count(*) from items where ya_subido)),
         (select n from esperados)::text,
         (select count(*) from items) = (select n from esperados)
  union all
  select 2, 'Con precio distinto a la lista',
         (select count(*) from items where price <> precio_lista)::text, '0',
         (select count(*) from items where price <> precio_lista) = 0
  union all
  select 3, 'Ya subidos que cambiaron de precio (manda el CSV)',
         coalesce((select string_agg(format('%s %s→%s', name, precio_antes, price), ' · ' order by name)
                   from items where ya_subido and precio_antes is distinct from price), 'ninguno'),
         'informativo', true
  union all
  select 4, 'Impuestos de TODO lo activo',
         (select string_agg(format('%s (%s)', juego, n), ' · ' order by n desc)
          from (select juego, count(*) as n from juego_ok group by juego) g),
         'ITBIS + Ley; AGUA solo Ley; Carne Cocida sin tocar',
         not exists (select 1 from juego_ok where not ok)
  union all
  select 5, 'Productos con otro juego de impuestos',
         coalesce((select string_agg(format('%s: %s', name, juego), ' · ' order by name)
                   from juego_ok where not ok), 'ninguno'),
         'ninguno', not exists (select 1 from juego_ok where not ok)
  union all
  select 6, 'Ley 10%: ' || case when (select copiada from _b0_ley) then 'copiada de Ágora' else 'ya existía' end,
         coalesce((select format('%s %s%% · include_in_ecf=%s · mesa=%s rápida=%s llevar=%s delivery=%s',
                                 name, rate,
                                 coalesce(to_jsonb(l)->>'include_in_ecf', '—'),
                                 apply_on_zone, apply_on_quick, apply_on_takeout, apply_on_delivery)
                   from ley l), '—'),
         'como en Ágora; mesa=true',
         coalesce((select apply_on_zone and not coalesce(is_service_fee, false) from ley), false)
  union all
  select 7, 'Ley 10% por orden (service_fee_enabled)',
         case when (select ley_por_orden from ajustes) then 'ENCENDIDA' else 'apagada' end,
         'apagada', not (select ley_por_orden from ajustes)
  union all
  select 8, 'Ejemplo: Corona $300',
         coalesce((select format('base %s + impuestos %s = %s',
                                 round(i.price / (1 + j.tasa / 100), 2),
                                 i.price - round(i.price / (1 + j.tasa / 100), 2), i.price)
                   from items i join juego_de j on j.id = i.id where i.nombre_lista = 'CORONA'), '—'),
         'base 234.38 + impuestos 65.62 = 300.00',
         coalesce((select i.price = 300 and j.tasa = 28
                   from items i join juego_de j on j.id = i.id where i.nombre_lista = 'CORONA'), false)
  union all
  select 9, 'Ejemplo: AGUA $50 (solo Ley)',
         coalesce((select format('base %s + Ley %s = %s',
                                 round(i.price / (1 + j.tasa / 100), 2),
                                 i.price - round(i.price / (1 + j.tasa / 100), 2), i.price)
                   from items i join juego_de j on j.id = i.id where i.nombre_lista = 'AGUA DASANI'), '—'),
         'base 45.45 + Ley 4.55 = 50.00',
         coalesce((select i.price = 50 and j.tasa = 10
                   from items i join juego_de j on j.id = i.id where i.nombre_lista = 'AGUA DASANI'), false)
  union all
  select 10, 'Comida → área ' || coalesce((select name || ' (' || code || ')' from sel where area = 'cocina'), '—'),
         (select count(*) from nm where area = 'cocina' and n_areas = 1 and en_su_area)::text,
         (select count(*) from nm where area = 'cocina')::text,
         (select count(*) from nm where area = 'cocina' and n_areas = 1 and en_su_area)
           = (select count(*) from nm where area = 'cocina')
  union all
  select 11, 'Bebidas y postres → área ' || coalesce((select name || ' (' || code || ')' from sel where area = 'bar'), '—'),
         (select count(*) from nm where area = 'bar' and n_areas = 1 and en_su_area)::text,
         (select count(*) from nm where area = 'bar')::text,
         (select count(*) from nm where area = 'bar' and n_areas = 1 and en_su_area)
           = (select count(*) from nm where area = 'bar')
  union all
  select 12, 'TODO lo activo con un área válida (N:M = legacy)',
         format('%s de %s', (select count(*) from nm where n_areas = 1 and legacy_ok),
                (select count(*) from activos)),
         'todos',
         (select count(*) from nm where n_areas = 1 and legacy_ok) = (select count(*) from activos)
  union all
  select 13, 'Enlazados al menú de la caja',
         (select count(*) from activos a where exists (
            select 1 from public.menu_item_links l where l.item_id = a.id))::text,
         (select count(*) from activos)::text,
         (select count(*) from activos a where exists (
            select 1 from public.menu_item_links l where l.item_id = a.id)) = (select count(*) from activos)
  union all
  select 14, 'Con modificador obligatorio y sus opciones (variantes)',
         (select count(*) from variantes_ok)::text,
         (select count(*) from _b0_productos where grupo is not null)::text,
         (select count(*) from variantes_ok) = (select count(*) from _b0_productos where grupo is not null)
  union all
  select 15, 'Ejemplo: Cantarito 1800 Añejo Cristalino',
         coalesce((select format('%s + %s = %s', i.price, m.price_delta, i.price + m.price_delta)
                   from items i
                   join grupos g on pg_temp.norm(g.name) = pg_temp.norm(i.grupo)
                   join public.modifiers m
                     on m.group_id = g.id and pg_temp.norm(m.name) = 'anejo cristalino'
                   where i.nombre_lista = 'CANTARITO 1800'), '—'),
         '500.00 + 150.00 = 650.00',
         coalesce((select i.price + m.price_delta = 650
                   from items i
                   join grupos g on pg_temp.norm(g.name) = pg_temp.norm(i.grupo)
                   join public.modifiers m
                     on m.group_id = g.id and pg_temp.norm(m.name) = 'anejo cristalino'
                   where i.nombre_lista = 'CANTARITO 1800'), false)
  union all
  select 16, 'Productos de cocina con el grupo Extras',
         format('%s · opciones activas %s',
                (select count(*) from con_extras c
                 join public.menu_item_groups y on y.menu_item_id = c.id
                 join extras g on g.id = y.group_id),
                coalesce((select n_op from extras), 0)),
         format('%s · opciones activas %s o más',
                (select count(*) from con_extras), (select count(*) from _b0_extras)),
         (select count(*) from con_extras c
          join public.menu_item_groups y on y.menu_item_id = c.id
          join extras g on g.id = y.group_id) = (select count(*) from con_extras)
         and coalesce((select n_op from extras), 0) >= (select count(*) from _b0_extras)
  union all
  select 17, 'Desactivados (DELIVERY y extras sueltos)',
         format('%s de %s inactivos',
                (select count(*) from _b0_existentes e
                 join public.menu_items mi
                   on mi.business_id = (select id from biz)
                  and pg_temp.k(mi.name) = pg_temp.k(e.existente)
                 where e.accion = 'desactivar' and not mi.is_active),
                (select count(*) from _b0_existentes where accion = 'desactivar')),
         'todos',
         not exists (select 1 from _b0_existentes e
                     join public.menu_items mi
                       on mi.business_id = (select id from biz)
                      and pg_temp.k(mi.name) = pg_temp.k(e.existente)
                     where e.accion = 'desactivar' and mi.is_active)
  union all
  select 18, 'Montos rápidos del cargo de delivery',
         coalesce((select presets::text from ajustes), '—'),
         '1 o más',
         coalesce(jsonb_array_length((select presets from ajustes)), 0) > 0
  union all
  select 19, 'Impresoras en el área ' || coalesce((select name from sel where area = 'cocina'), 'de cocina'),
         coalesce((select impresoras from sel where area = 'cocina'), 0)::text, '1 o más',
         coalesce((select impresoras from sel where area = 'cocina'), 0) > 0
  union all
  select 20, 'Impresoras en el área ' || coalesce((select name from sel where area = 'bar'), 'del bar'),
         coalesce((select impresoras from sel where area = 'bar'), 0)::text, '1 o más',
         coalesce((select impresoras from sel where area = 'bar'), 0) > 0
  union all
  select 21, 'Cocina encendida en Ajustes (kitchen_enabled)',
         case when (select cocina_encendida from ajustes) then 'encendida' else 'APAGADA' end,
         'encendida', (select cocina_encendida from ajustes)
  union all
  select 22, 'ITBIS en mesa / rápida / llevar / delivery',
         coalesce((select concat_ws(' / ',
                     case when apply_on_zone     then 'sí' else 'NO' end,
                     case when apply_on_quick    then 'sí' else 'NO' end,
                     case when apply_on_takeout  then 'sí' else 'NO' end,
                     case when apply_on_delivery then 'sí' else 'NO' end) from itbis), '—'),
         'sí / sí / sí / sí',
         coalesce((select apply_on_zone and apply_on_quick
                          and apply_on_takeout and apply_on_delivery from itbis), false)
  union all
  select 23, 'Fuera del CSV sin tocar impuestos (decidir con el dueño)',
         coalesce((select string_agg(format('%s $%s %s · %s', f.name, f.price, f.tax_mode, j.juego), ' · ')
                   from fuera f join juego_de j on j.id = f.id
                   where f.imp_lista = 'no_tocar'), 'ninguno'),
         'ninguno',
         not exists (select 1 from fuera where imp_lista = 'no_tocar')
)
select concepto, encontrado, esperado,
       case when ok then '✓' else '✗ REVISAR' end as estado
from r
order by orden;
