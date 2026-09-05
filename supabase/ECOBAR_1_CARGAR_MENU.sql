-- #############################################################################
-- ##  ALTO — 3-sep-2026: ESTE SCRIPT YA NO HACE FALTA.                       ##
-- ##                                                                         ##
-- ##  El diagnóstico mostró que el menú del PDF YA ESTÁ CARGADO: 280         ##
-- ##  productos y 32 categorías que cuadran una a una con la carta. Correr   ##
-- ##  esto borraría el menú bueno para volver a crearlo, perdiendo el orden  ##
-- ##  de categorías (10, 20, 30...) y la escritura que ya tiene.             ##
-- ##                                                                         ##
-- ##  Y OJO: en esta base la FK order_items.product_id sigue siendo          ##
-- ##  ON DELETE SET NULL (la mig 20260902_0006 NO está aplicada), así que    ##
-- ##  un borrado descuidado desconecta las ventas SIN AVISAR.                ##
-- ##                                                                         ##
-- ##  Lo que sí hay que hacer está en ECOBAR_5_ARREGLAR.sql.                 ##
-- ##  Se deja aquí solo por si algún día hay que rehacer el menú de cero.    ##
-- #############################################################################


-- =============================================================================
-- ECO BAR & LOUNGE — carga del menú nuevo (PDF "MENUU ECO BAR FINAL").
-- Negocio: fc3065c8-cb40-45ad-bec1-aecb388001c1
--
-- QUÉ HACE, EN ORDEN:
--   1. Respalda menú, categorías, impuestos, áreas y recetas actuales.
--   2. Retira el menú viejo:
--        · BORRA los productos que nunca se vendieron.
--        · DESACTIVA (is_active=false) los que sí tienen ventas — borrarlos
--          rompería el histórico fiscal y los reportes por producto.
--   3. Crea las 33 categorías y los productos del PDF.
--   4. Les vincula los MISMOS impuestos que usaba el menú viejo
--      (menu_item_taxes es la ÚNICA fuente del ITBIS; sin vínculo = ITBIS 0).
--   5. Les asigna área de impresión (cocina / bar), legacy + N:M.
--
-- Precios: el PDF dice "LOS PRECIOS NO INCLUYEN ITBIS" → tax_mode='exclusive'.
--
-- CÓMO CORRERLO: pega TODO de una vez en el SQL Editor de Supabase. El editor
-- lo envuelve en una transacción: o entra completo, o no entra nada.
-- Antes corre ECOBAR_0_DIAGNOSTICO.sql y revisa lo que reporta.
-- =============================================================================


-- ---------------------------------------------------------------------------
-- 0. Cortafuegos: que el negocio exista y que nadie esté vendiendo ahora.
-- ---------------------------------------------------------------------------
do $$
declare v_open int;
begin
  if not exists (select 1 from public.businesses where id = 'fc3065c8-cb40-45ad-bec1-aecb388001c1') then
    raise exception 'El negocio no existe. Verifica el UUID.';
  end if;

  -- Órdenes abiertas que YA tienen productos de este negocio cargados.
  -- Cambiar el menú debajo de una cuenta viva deja la orden a medias.
  select count(distinct o.id) into v_open
  from public.orders o
  join public.order_items oi on oi.order_id = o.id
  join public.menu_items mi on mi.id = oi.product_id
  where mi.business_id = 'fc3065c8-cb40-45ad-bec1-aecb388001c1' and o.status = 'open';

  if v_open > 0 then
    raise exception 'Hay % orden(es) ABIERTA(S) con productos cargados. Cierra las cuentas antes de cambiar el menú.', v_open;
  end if;
end $$;


-- ---------------------------------------------------------------------------
-- 1. RESPALDO. Si algo sale mal, ECOBAR_9_ROLLBACK.sql revierte con esto.
-- ---------------------------------------------------------------------------
drop table if exists public.zzz_ecobar_bk_menu_items;
create table public.zzz_ecobar_bk_menu_items as
  select * from public.menu_items where business_id = 'fc3065c8-cb40-45ad-bec1-aecb388001c1';

drop table if exists public.zzz_ecobar_bk_categories;
create table public.zzz_ecobar_bk_categories as
  select * from public.categories where business_id = 'fc3065c8-cb40-45ad-bec1-aecb388001c1';

drop table if exists public.zzz_ecobar_bk_menu_item_taxes;
create table public.zzz_ecobar_bk_menu_item_taxes as
  select mit.* from public.menu_item_taxes mit
  join public.zzz_ecobar_bk_menu_items b on b.id = mit.item_id;

drop table if exists public.zzz_ecobar_bk_menu_item_print_areas;
create table public.zzz_ecobar_bk_menu_item_print_areas as
  select p.* from public.menu_item_print_areas p
  join public.zzz_ecobar_bk_menu_items b on b.id = p.menu_item_id;

drop table if exists public.zzz_ecobar_bk_recipes;
create table public.zzz_ecobar_bk_recipes as
  select r.* from public.recipes r
  join public.zzz_ecobar_bk_menu_items b on b.id = r.menu_item_id;

drop table if exists public.zzz_ecobar_bk_recipe_ingredients;
create table public.zzz_ecobar_bk_recipe_ingredients as
  select ri.* from public.recipe_ingredients ri
  join public.zzz_ecobar_bk_recipes r on r.id = ri.recipe_id;


-- ---------------------------------------------------------------------------
-- 2. RETIRAR EL MENÚ VIEJO.
--
--    Un producto que YA SE VENDIÓ no se borra: se desactiva. La FK
--    order_items.product_id es ON DELETE RESTRICT (mig 20260902_0006) o
--    SET NULL (la vieja): con la primera el borrado falla, con la segunda
--    desconecta las ventas EN SILENCIO. Ninguna de las dos sirve.
--    Igual con order_item_modifiers (SET NULL) y combo_group_items (RESTRICT).
-- ---------------------------------------------------------------------------
do $$
declare
  r record;
  v_borrados int := 0;
  v_bloqueados int := 0;
  v_apagados int := 0;
begin
  for r in
    select mi.id, mi.name
    from public.menu_items mi
    where mi.business_id = 'fc3065c8-cb40-45ad-bec1-aecb388001c1'
      and not exists (select 1 from public.order_items oi where oi.product_id = mi.id)
      and not exists (select 1 from public.order_item_modifiers om where om.menu_item_id = mi.id)
  loop
    begin
      delete from public.menu_items where id = r.id;
      v_borrados := v_borrados + 1;
    exception when others then
      -- combo, promo u otra referencia que no conocemos: se queda y se apaga.
      v_bloqueados := v_bloqueados + 1;
    end;
  end loop;

  update public.menu_items
     set is_active = false, updated_at = now()
   where business_id = 'fc3065c8-cb40-45ad-bec1-aecb388001c1' and is_active;

  get diagnostics v_apagados = row_count;
  raise notice 'Menú viejo: % borrados, % desactivados (con ventas), % protegidos por combos u otras referencias.',
    v_borrados, v_apagados, v_bloqueados;
end $$;

-- Categorías: se van las que quedaron vacías; el resto se apaga.
delete from public.categories c
 where c.business_id = 'fc3065c8-cb40-45ad-bec1-aecb388001c1'
   and not exists (select 1 from public.menu_items mi where mi.category_id = c.id);

update public.categories
   set is_active = false
 where business_id = 'fc3065c8-cb40-45ad-bec1-aecb388001c1' and is_active;


-- ---------------------------------------------------------------------------
-- 3. DATOS DEL MENÚ NUEVO (transcritos del PDF).
-- ---------------------------------------------------------------------------
drop table if exists _eco_cat;
create temp table _eco_cat(pos int, name text primary key, kind text, bev boolean);
insert into _eco_cat(pos, name, kind, bev) values
  (1, 'ANTOJOS', 'cocina', false),
  (2, 'ENTRADAS', 'cocina', false),
  (3, 'PLATOS FUERTES', 'cocina', false),
  (4, 'DELICIAS DEL MAR', 'cocina', false),
  (5, 'ENSALADAS', 'cocina', false),
  (6, 'MOFONGO', 'cocina', false),
  (7, 'ARROCES AL ESTILO ECOBAR', 'cocina', false),
  (8, 'PASTAS', 'cocina', false),
  (9, 'HAMBURGUESAS', 'cocina', false),
  (10, 'GUARNICIONES', 'cocina', false),
  (11, 'RINCOCITOS DE LOS ECOPEQUES', 'cocina', false),
  (12, 'POSTRES', 'cocina', false),
  (13, 'ADICIONALES', 'cocina', false),
  (14, 'CAFÉ', 'bar', true),
  (15, 'AGUAS / SABORIZADAS', 'bar', true),
  (16, 'JUGOS / MIXERS', 'bar', true),
  (17, 'CERVEZAS', 'bar', true),
  (18, 'CÓCTELES', 'bar', true),
  (19, 'GIN TONIC', 'bar', true),
  (20, 'RONES / TRAGOS', 'bar', true),
  (21, 'WHISKEY / TRAGOS', 'bar', true),
  (22, 'VODKA', 'bar', true),
  (23, 'GINEBRA', 'bar', true),
  (24, 'TEQUILA', 'bar', true),
  (25, 'DIGESTIVOS', 'bar', true),
  (26, 'COPAS DE VINO', 'bar', true),
  (27, 'VINOS TINTO', 'bar', true),
  (28, 'VINOS BLANCOS', 'bar', true),
  (29, 'VINOS ROSADO', 'bar', true),
  (30, 'CAVA / PROSECCO', 'bar', true),
  (31, 'CHAMPAGNE', 'bar', true),
  (32, 'CIGARROS', 'bar', false),
  (33, 'CIGARRILLOS', 'bar', false);

drop table if exists _eco_item;
create temp table _eco_item(cat text, pos int, name text, price numeric(12,2), descr text);
insert into _eco_item(cat, pos, name, price, descr) values
  ('ANTOJOS', 1, 'Picadera de salchichas picantes', 350, 'Salchichas sazonadas con especias cuidadosamente seleccionadas, que ofrecen un equilibrio perfecto entre el calor y el sabor.'),
  ('ANTOJOS', 2, 'Picadera de embutidos & quesos', 850, 'Deliciosa variedad de embutidos y quesos de calidad premium que deleitaran tus sentidos.'),
  ('ANTOJOS', 3, 'Eco Tartar', 750, 'Tartar de atún fresco en salsa de la casa, cubos de aguacate y platanitos crocantes.'),
  ('ANTOJOS', 4, 'Brocheta de Pollo', 350, 'Brocheta sellada al fuego vivo en grill, marinada con hierbas, ajo y limón, con cubos de vegetales frescos y salsa de ajo y cilantro.'),
  ('ANTOJOS', 5, 'Brocheta de Camarón', 400, 'Brocheta sellada al fuego vivo en grill, marinada con hierbas, ajo y limón, con cubos de vegetales frescos y salsa de ajo y cilantro.'),
  ('ANTOJOS', 6, 'Brocheta Mixta', 450, 'Brocheta sellada al fuego vivo en grill, marinada con hierbas, ajo y limón, con cubos de vegetales frescos y salsa de ajo y cilantro.'),
  ('ANTOJOS', 7, 'Canasticas de Birria (3 Unid)', 650, 'Canastas de plátanos, birria reducida a 45m, queso mixto gratinado, sobre una base de guacamole.'),
  ('ANTOJOS', 8, 'Canasticas de Camarones (3 Unid)', 700, 'Canastas de plátanos, camarones salteados en licor de coco, base de guacamole, queso mozzarella gratinado y pico de gallo.'),
  ('ANTOJOS', 9, 'Calamares fritos (7 Unid)', 350, 'Aros de calamar rebozados con salsa tártara o picante hecha en casa.'),
  ('ANTOJOS', 10, 'Croquetas (3 Unid)', 400, 'Jugosas croquetas de berenjenas y pollo con el toque al estilo Ecobar.'),
  ('ENTRADAS', 1, 'Tacos al Campo (2 Unid)', 400, 'Tacos mixtos con filete de pechuga de pollo y filete de res, con repollo morado y nuestra salsa especial de la casa.'),
  ('ENTRADAS', 2, 'Tacos de Chicharrón (2 Unid)', 500, 'Chicharrón picado crocante en mantequilla de perejil deshidratado y ajo, ensalada mixta en secret sauce, guacamole y pico de gallo.'),
  ('ENTRADAS', 3, 'Tacos Hermanos Trejo (3 Unid)', 450, 'Pollo desmechado con vegetales mixtos y queso mozzarella gratinado. Salsa picante aparte.'),
  ('ENTRADAS', 4, 'Camarones a la Roca', 650, 'Camarones tempura en salsa spicy mayo, con base de lechuga rizada.'),
  ('ENTRADAS', 5, 'Dumplings de Pork (5 Unid)', 450, 'Cerdo sazonado con especias exquisitas, envuelto en fina masa de dumpling, cocido al vapor o frito.'),
  ('ENTRADAS', 6, 'Alitas a la BBQ (3 Unid)', 450, 'Alitas de pollo bañadas en salsa BBQ al estilo Eco, o picantes.'),
  ('ENTRADAS', 7, 'Ceviche Ecológico', 550, 'Pescado blanco, maíz salado y maíz chulpi, plátanos verdes en esencia de ajo, bañado en salsa de tigre.'),
  ('ENTRADAS', 8, 'Deditos de pollo', 450, 'Con papas fritas y salsa rosa.'),
  ('PLATOS FUERTES', 1, 'Chuletas Fresh Pig', 600, 'Sabrosas chuletas de cerdo fitness para aportar energía y bienestar a tu vida.'),
  ('PLATOS FUERTES', 2, 'Pechuga de pollo a la parrilla', 400, 'Jugosa y aromática pechuga de pollo a la parrilla, una delicia simple y sabrosa.'),
  ('PLATOS FUERTES', 3, 'Ribeye', 2000, 'Corte de carne de res con abundante marmoleado de grasa y jugoso sabor.'),
  ('PLATOS FUERTES', 4, 'Eco Ribs BBQ', 800, 'Costillas baby procesadas a bajas temperaturas al estilo cajun.'),
  ('PLATOS FUERTES', 5, 'Filet Mignon', 1400, 'Solomillo de res envuelto en bacon premium, con salsa de vino especial y porto.'),
  ('PLATOS FUERTES', 6, 'Delicia de la Selva Negra', 1500, 'Filete de res angus certificado.'),
  ('PLATOS FUERTES', 7, 'Churrasco a la Juliana', 1800, 'Especialidad de la parrilla, exquisitamente jugoso y lleno de sabor.'),
  ('PLATOS FUERTES', 8, 'Lomo Saltado', 1950, 'Filete de lomo de res angus certificado, salteado en vegetales mixtos y papas baby.'),
  ('DELICIAS DEL MAR', 1, 'Filete de Salmón del Pacífico', 900, 'Salmón de 8 onz a la plancha con esencia de mantequilla y ajo.'),
  ('DELICIAS DEL MAR', 2, 'Parrillada de mariscos', 2500, 'Rica variedad de frutos del mar adobada con pasión.'),
  ('DELICIAS DEL MAR', 3, 'Camarones a la Eco criolla', 700, 'Camarones en salsa criolla, con tomate, pimiento y especias.'),
  ('DELICIAS DEL MAR', 4, 'Langosta Caribeña (por libra)', 1500, 'Langosta fresca cocinada con aceite de ajo, mantequilla exclusiva, sal, pimienta y salsa al ajillo. Precio por libra.'),
  ('DELICIAS DEL MAR', 5, 'Chillo del Mar Caribe (por libra)', 1000, 'Chillo fresco sazonado y frito, crujiente por fuera y tierno por dentro. Precio por libra.'),
  ('DELICIAS DEL MAR', 6, 'Mar y Tierra', 1800, 'Arroz frito a la plancha con vegetales mixtos, filete de res y camarón a la plancha, salsa de hongos en crema y queso, tierra crocante de tocineta.'),
  ('DELICIAS DEL MAR', 7, 'Cazuela de Mariscos Ecológica', 900, 'Mariscos mixtos sellados y salteados, con vegetales ahumados triturados con crema.'),
  ('ENSALADAS', 1, 'Tropical Salad', 550, 'Mezcla refrescante de piña jugosa y camarones tiernos, aderezada con vinagreta especial.'),
  ('ENSALADAS', 2, 'Caeser Salad', 350, 'Lechuga romana, trozos de pan tostado, queso parmesano rallado y aderezo Caesar.'),
  ('ENSALADAS', 3, 'BBQ Salad', 550, 'Lechuga fresca en salsa ahumada con chicharrón de salmón, tomate, aguacate y tierra de pan crocante.'),
  ('ENSALADAS', 4, 'Ensalada Eco', 400, 'Tiras de pollo con cebolla, aguacate cremoso y tortilla crujiente.'),
  ('MOFONGO', 1, 'El Mofongo de Cayacoa', 900, 'Mofongo mixto de chicharrón y camarón con crema de queso fundido y tocineta crocante.'),
  ('MOFONGO', 2, 'Mofongo de Pollo', 600, 'Mofongo con tierna carne de pollo sazonada.'),
  ('MOFONGO', 3, 'Mofongo de Camarones', 800, 'Plátanos verdes machacados con camarones salteados.'),
  ('MOFONGO', 4, 'Mofongo de Churrasco', 1400, 'Plátanos verdes machacados con salsa de queso y mozzarella, crocante de tocineta y 6 onz de churrasco.'),
  ('ARROCES AL ESTILO ECOBAR', 1, 'Risotto Volcan', 1200, 'Risotto de hongos con 6 onz de churrasco al grill y lluvia de parmesano.'),
  ('ARROCES AL ESTILO ECOBAR', 2, 'Risotto de Camarón', 1100, 'Risotto en reducción de camarón y azafrán, cubos de aguacate ahumado, prosciutto crocante y parmesano.'),
  ('ARROCES AL ESTILO ECOBAR', 3, 'Salvaje Rice', 850, 'Arroz de la selva negra salteado con vegetales frescos, esencia de coco y huevo pochado.'),
  ('ARROCES AL ESTILO ECOBAR', 4, 'Eco Concón', 550, 'Fried rice al estilo Eco, huevo pochado.'),
  ('PASTAS', 1, 'Pasta del mar al tomate fresco', 850, 'A elegir penne, spaguetti o lingüini. Camarones, mejillones y calamares en salsa pomodoro casera.'),
  ('PASTAS', 2, 'Pasta alfredo', 550, 'A elegir penne, spaguetti o lingüini. Salsa Alfredo con mantequilla, crema, ajo y parmesano.'),
  ('PASTAS', 3, 'Pasta a la carbonara', 600, 'A elegir penne, spaguetti o lingüini. Crema de leche, tocino dorado y cebolla juliana.'),
  ('PASTAS', 4, 'Pasta con camarones', 800, 'A elegir penne, spaguetti o lingüini. Salsa cremosa con camarones, ajo, tomates cherry y hierbas frescas.'),
  ('PASTAS', 5, 'Pesto de camarones', 950, 'A elegir penne, spaguetti o lingüini. Salsa pesto con camarones salteados en mantequilla y ajo.'),
  ('PASTAS', 6, 'Pasta Bolognesa', 550, 'A elegir penne, spaguetti o lingüini. Salsa boloñesa de res, tomates maduros, vino tinto y finas hierbas.'),
  ('HAMBURGUESAS', 1, 'Chicken Burguer Special', 700, 'Milanesa de pollo empanizada con crema de tocineta y puerro, lechuga, tomate, cebolla crocante y secret sauce.'),
  ('HAMBURGUESAS', 2, 'Eco Burguer Special', 750, 'Hamburguesa angus certificada, ahogada en crema de hongos y queso.'),
  ('HAMBURGUESAS', 3, 'La Ciclo Burguer', 650, 'Hamburguesa angus certificada, lonja de queso danés, tomate, pepinillo y cebolla caramelizada.'),
  ('GUARNICIONES', 1, 'Tostones de mi tierra', 200, 'Dorados y crujientes.'),
  ('GUARNICIONES', 2, 'Papas a la Francesa', 200, 'Papas fritas doradas y crujientes.'),
  ('GUARNICIONES', 3, 'Papas Salteadas', 250, 'Trozos de papa al dente salteados en ajo y mantequilla de perejil.'),
  ('GUARNICIONES', 4, 'Vegetales Salteados', 250, 'Combinación de verduras a la parrilla o salteadas.'),
  ('GUARNICIONES', 5, 'Eco puré de papas', 250, 'Gratinado con queso parmesano, zumo y rayadura de limón verde fresco.'),
  ('GUARNICIONES', 6, 'Yuca Mash', 250, 'Puré de yuca suave con queso gratinado y crema.'),
  ('RINCOCITOS DE LOS ECOPEQUES', 1, 'Nuggets', 350, 'Medallones de pollo acompañados de papas fritas y ketchup.'),
  ('RINCOCITOS DE LOS ECOPEQUES', 2, 'Croquetas Mágicas', 350, 'Peloticas esponjosas de jamón y queso acompañadas de queso fundido.'),
  ('RINCOCITOS DE LOS ECOPEQUES', 3, 'Mini Burguer Eco', 400, 'Hamburguesa angus certificada, ahogada en crema de queso.'),
  ('RINCOCITOS DE LOS ECOPEQUES', 4, 'Pasta Pirata', 400, 'Pasta al dente con mini albóndigas en salsa roja y queso parmesano.'),
  ('RINCOCITOS DE LOS ECOPEQUES', 5, 'Arroz Ninja', 400, 'Arroz frito salteado con huevito y pollo tierno en salsa de soya.'),
  ('RINCOCITOS DE LOS ECOPEQUES', 6, 'Taquitos Caribeños', 350, 'Mini taquitos de pollo desmechado y queso mozzarella derretido.'),
  ('POSTRES', 1, 'Romeo y Julieta', 400, 'Bizcocho bañado en chocolate, con crema de dulce de leche y topping de suspiro.'),
  ('ADICIONALES', 1, 'Adicional Chicken', 250, 'Acompañamiento adicional para arroces.'),
  ('ADICIONALES', 2, 'Adicional Beef', 250, 'Acompañamiento adicional para arroces.'),
  ('ADICIONALES', 3, 'Adicional Shrimps', 250, 'Acompañamiento adicional para arroces.'),
  ('ADICIONALES', 4, 'Adicional Chicharrón', 250, 'Acompañamiento adicional para arroces.'),
  ('CAFÉ', 1, 'Café americano', 140, null),
  ('CAFÉ', 2, 'Café expreso', 135, null),
  ('CAFÉ', 3, 'Capuchino', 170, null),
  ('AGUAS / SABORIZADAS', 1, 'Agua San Pellegrino Cristal 750ml', 350, 'Agua con gas.'),
  ('AGUAS / SABORIZADAS', 2, 'Agua San Pellegrino Cristal 505ml', 250, 'Agua con gas.'),
  ('AGUAS / SABORIZADAS', 3, 'Agua Panna Cristal 750ml', 250, 'Agua mineral de manantial.'),
  ('AGUAS / SABORIZADAS', 4, 'Agua Panna Cristal 505ml', 200, 'Agua mineral de manantial.'),
  ('AGUAS / SABORIZADAS', 5, 'San Pellegrino Aranciata 330ml', 200, 'Agua saborizada con gas.'),
  ('AGUAS / SABORIZADAS', 6, 'San Pellegrino Melograno 330ml', 200, 'Agua saborizada con gas.'),
  ('AGUAS / SABORIZADAS', 7, 'San Pellegrino Aranciata Limón y Menta 330ml', 200, 'Agua saborizada con gas.'),
  ('AGUAS / SABORIZADAS', 8, 'San Pellegrino Aranciata Rossa 330ml', 200, 'Agua con gas.'),
  ('AGUAS / SABORIZADAS', 9, 'Agua Perrier Cristal 330ml', 200, 'Agua saborizada con gas.'),
  ('AGUAS / SABORIZADAS', 10, 'Dasani', 80, 'Agua natural.'),
  ('JUGOS / MIXERS', 1, 'Aloe Vera Natural', 235, null),
  ('JUGOS / MIXERS', 2, 'Canada Dry soda', 120, null),
  ('JUGOS / MIXERS', 3, 'Canada Dry tónica', 120, null),
  ('JUGOS / MIXERS', 4, 'Coca Cola', 65, null),
  ('JUGOS / MIXERS', 5, 'Sprite', 65, null),
  ('JUGOS / MIXERS', 6, 'Cranberry 946ml', 350, null),
  ('JUGOS / MIXERS', 7, 'Gatorade', 100, null),
  ('JUGOS / MIXERS', 8, 'Jarra Jugo de Naranja', 275, null),
  ('JUGOS / MIXERS', 9, 'Jugo Clamato', 200, null),
  ('JUGOS / MIXERS', 10, 'Jugos Motts 946ml', 350, null),
  ('JUGOS / MIXERS', 11, 'Jugos Naturales', 160, null),
  ('JUGOS / MIXERS', 12, 'Redbull', 200, null),
  ('CERVEZAS', 1, 'Corona Extra', 195, null),
  ('CERVEZAS', 2, 'Erdinger Weissbier', 350, null),
  ('CERVEZAS', 3, 'Modelo Negra', 225, null),
  ('CERVEZAS', 4, 'Modelo Especial', 210, null),
  ('CERVEZAS', 5, 'Stella Artois', 235, null),
  ('CERVEZAS', 6, 'Smirnoff Ice Green', 235, null),
  ('CERVEZAS', 7, 'Presidente Light', 155, null),
  ('CERVEZAS', 8, 'Presidente Regular', 155, null),
  ('CERVEZAS', 9, 'Erdinger Alkoholfrei', 300, 'Sin alcohol.'),
  ('CERVEZAS', 10, 'Paulaner Sin Alcohol', 450, null),
  ('CERVEZAS', 11, 'Heiniken', 235, null),
  ('CERVEZAS', 12, 'Ginger Beer Gosling Lata', 195, null),
  ('CERVEZAS', 13, 'Ginger ale lata C&C', 155, null),
  ('CERVEZAS', 14, 'Leffe Blonde', 235, null),
  ('CERVEZAS', 15, 'Paulaner con Alcohol', 235, null),
  ('CERVEZAS', 16, 'Estrella Galicia', 235, null),
  ('CERVEZAS', 17, 'Coors Light', 235, null),
  ('CÓCTELES', 1, 'Eco Spritz', 450, 'Aperol / zumo de naranja / jugo de sandia / espumante / agua saborizada.'),
  ('CÓCTELES', 2, 'Cuba libre', 400, 'Dark ron / Coca Cola.'),
  ('CÓCTELES', 3, 'Dreamers', 300, 'Tequila dorada / jugo de chinola / jugo de limón / sirope de jengibre / ginger beer.'),
  ('CÓCTELES', 4, 'Hotelero', 350, 'Ron dorado / crema de café / Bailey / amaretto / licor de melocotón / aromatizado con canela.'),
  ('CÓCTELES', 5, 'Higuey City', 300, 'Whisky blend / vermouth rosso / triple sec / zumo de limón / sirope de jengibre.'),
  ('CÓCTELES', 6, 'El Ecologista', 350, 'Vodka / jugo de piña / fresas / jarabe natural / zumo de limón / aroma de romero.'),
  ('CÓCTELES', 7, 'Eco Verde', 550, 'Jugo de pepino / zumo de limón / hoja de menta / sirope de jengibre.'),
  ('CÓCTELES', 8, 'Eco Punch', 200, 'Jugo de naranja / jugo de chinola / jugo de piña / jugo de sandia / sirope de canela / fresas maceradas.'),
  ('CÓCTELES', 9, 'Turista', 350, 'Ron blanco / ron dorado / licor de manzana / licor amarula / triple sec / licor de banana / sirope natural.'),
  ('CÓCTELES', 10, 'Basilica', 350, 'Ginebra / jugo de pepino / jugo de piña / zumo de limón / sirope de canela / licor de banana / dash de angostura.'),
  ('CÓCTELES', 11, 'Margarita Eco', 400, 'Tequila / jugo de pepino / zumo de limón / azúcar liquida / triple sec / amaretto / dash de angostura.'),
  ('CÓCTELES', 12, 'Las Tres Cruces', 300, 'Vodka / triple sec / zumo de limón / jugo de pitahaya / licor de menta verde / soda / jarabe de azúcar.'),
  ('CÓCTELES', 13, 'Fresa Colada sin alcohol', 250, 'Fresas / crema de coco / leche evaporada / jugo de piña.'),
  ('CÓCTELES', 14, 'Fresa Colada con alcohol', 350, 'Fresas / crema de coco / leche evaporada / jugo de piña / ron.'),
  ('CÓCTELES', 15, 'Mojito de Limón / Fresa / Chinola', 300, 'Ron / hoja de menta / sirope natural / zumo de preferencia.'),
  ('CÓCTELES', 16, 'Mojito de Coco', 350, 'Ron / hoja de menta / sirope natural / coco.'),
  ('CÓCTELES', 17, 'Old Fashion', 400, 'Whisky bourbon / dash de angostura / azúcar morena / martini rosso.'),
  ('CÓCTELES', 18, 'Piña Colada', 400, 'Crema de coco / jugo de piña / leche evaporada.'),
  ('CÓCTELES', 19, 'Piña Colada con Alcohol', 350, 'Crema de coco / jugo de piña / leche evaporada / ron blanco.'),
  ('CÓCTELES', 20, 'Campari Tónic', 350, 'Campari / tonica.'),
  ('CÓCTELES', 21, 'Mickey Mouse', 400, 'Seven up / granadina.'),
  ('CÓCTELES', 22, 'Amaretto Sour', 350, 'Disaronno / bourbon / jugo de limón / sirope natural.'),
  ('CÓCTELES', 23, 'Whiskey Sour', 450, 'Whisky de su preferencia / zumo de limón / sirope natural.'),
  ('CÓCTELES', 24, 'Moscow Mule', 350, 'Vodka / limón / sirope natural / ginger beer.'),
  ('CÓCTELES', 25, 'Eco Special', 300, 'Ginebra / licor de menta / jugo de chinola / sirope natural / zumo de limón y pepino.'),
  ('CÓCTELES', 26, 'Sanky Panky', 350, 'Ron blanco / Licor 43 / zumo de chinola / zumo de limón / jarabe de goma.'),
  ('CÓCTELES', 27, 'Negroni Ecobar', 550, 'Ron doble reserva / Aperol / amaro / garnish.'),
  ('CÓCTELES', 28, 'Beso Higueyano', 350, 'Tequila blanco / Aperol / amaretto / zumo de limón / jarabe de goma.'),
  ('CÓCTELES', 29, 'Ecomule', 350, 'Ron blanco / ginger beer / zumo de limón / jarabe de goma.'),
  ('CÓCTELES', 30, 'Vodka Cinnamon', 300, 'Vodka / zumo de limón / sirope de canela y sirope de jengibre.'),
  ('CÓCTELES', 31, 'Eco Diversidad', 350, 'Zumo de chinola / amaretto / Leyenda / crema de coco / leche.'),
  ('CÓCTELES', 32, 'Eco Sangría', 450, 'Vino tinto o blanco / frutas frescas / sirope natural / licores.'),
  ('CÓCTELES', 33, 'Madre Tierra', 350, 'Ron dorado / tequila dorada / whisky / ginebra saborizada / jugo de pepino / ginger ale.'),
  ('CÓCTELES', 34, 'Martini Clásico', 350, 'Martini / ginebra o vodka, decorado con aceitunas o twist de limón.'),
  ('CÓCTELES', 35, 'Lago Cristalino', 350, 'Aloe vera / jugo de pepino / fresas / jugo de toronja / sirope de Splenda.'),
  ('CÓCTELES', 36, 'Schweppes Ginger Ale', 550, 'Bebida gaseosa con auténtico sabor a jengibre natural.'),
  ('CÓCTELES', 37, 'Daikiri', 350, 'Cóctel clásico de ron, jugo de limón y azúcar, servido bien frío.'),
  ('CÓCTELES', 38, 'Caipiriña', 350, 'Cóctel brasileño de cachaça, lima fresca, azúcar y hielo triturado.'),
  ('CÓCTELES', 39, 'Coco Loco', 400, 'Ron, crema de coco, jugo de piña y jugo de limón.'),
  ('CÓCTELES', 40, 'Michelada', 450, 'Cerveza, jugo de limón, salsa picante y sal.'),
  ('CÓCTELES', 41, 'Costa Azul', 350, 'Vodka / jugo de limón / sirope de albahaca / blue curaçao.'),
  ('GIN TONIC', 1, 'Gin Tonic Eco', 350, null),
  ('GIN TONIC', 2, 'Gin Tonic Bulldog', 450, null),
  ('GIN TONIC', 3, 'Gin Tonic Bombay Saphire', 500, null),
  ('GIN TONIC', 4, 'Gin Tonic Hendricks', 550, null),
  ('GIN TONIC', 5, 'Gin Tonic Tanqueray No. Ten', 500, null),
  ('GIN TONIC', 6, 'Gin Tonic Tanqueray Sport', 400, null),
  ('GIN TONIC', 7, 'Gin Tonic Beefeater Pink', 450, null),
  ('GIN TONIC', 8, 'Gin Tonic Beefeater', 350, null),
  ('RONES / TRAGOS', 1, 'Barcelo Imperial (Botella)', 2500, 'Botella.'),
  ('RONES / TRAGOS', 2, 'Barcelo Imperial (Trago)', 380, 'Trago / shot.'),
  ('RONES / TRAGOS', 3, 'Brugal 1888 (Botella)', 4000, 'Botella.'),
  ('RONES / TRAGOS', 4, 'Brugal 1888 (Trago)', 420, 'Trago / shot.'),
  ('RONES / TRAGOS', 5, 'Brugal Leyenda (Botella)', 2300, 'Botella.'),
  ('RONES / TRAGOS', 6, 'Brugal Leyenda (Trago)', 350, 'Trago / shot.'),
  ('RONES / TRAGOS', 7, 'Brugal Doble Reserva (Botella)', 1700, 'Botella.'),
  ('RONES / TRAGOS', 8, 'Brugal Doble Reserva (Trago)', 300, 'Trago / shot.'),
  ('RONES / TRAGOS', 9, 'Brugal XV (Botella)', 1500, 'Botella.'),
  ('RONES / TRAGOS', 10, 'Brugal XV (Trago)', 250, 'Trago / shot.'),
  ('RONES / TRAGOS', 11, 'Brugal Extra Viejo (Botella)', 1300, 'Botella.'),
  ('RONES / TRAGOS', 12, 'Brugal Extra Viejo (Trago)', 200, 'Trago / shot.'),
  ('WHISKEY / TRAGOS', 1, 'Buchanans 12 (Botella)', 4300, 'Botella.'),
  ('WHISKEY / TRAGOS', 2, 'Buchanans 12 (Trago)', 500, 'Trago / shot.'),
  ('WHISKEY / TRAGOS', 3, 'Buchanans 18 (Botella)', 8500, 'Botella.'),
  ('WHISKEY / TRAGOS', 4, 'Buchanans 18 (Trago)', 850, 'Trago / shot.'),
  ('WHISKEY / TRAGOS', 5, 'Buffalo Trace Bourbon (Botella)', 4500, 'Botella.'),
  ('WHISKEY / TRAGOS', 6, 'Buffalo Trace Bourbon (Trago)', 450, 'Trago / shot.'),
  ('WHISKEY / TRAGOS', 7, 'Chivas Regal 12 (Botella)', 4000, 'Botella.'),
  ('WHISKEY / TRAGOS', 8, 'Chivas Regal 12 (Trago)', 400, 'Trago / shot.'),
  ('WHISKEY / TRAGOS', 9, 'Chivas Regal 18 (Botella)', 8000, 'Botella.'),
  ('WHISKEY / TRAGOS', 10, 'Chivas Regal 18 (Trago)', 800, 'Trago / shot.'),
  ('WHISKEY / TRAGOS', 11, 'Dewars 12 años (Botella)', 2500, 'Botella.'),
  ('WHISKEY / TRAGOS', 12, 'Dewars 12 años (Trago)', 350, 'Trago / shot.'),
  ('WHISKEY / TRAGOS', 13, 'Dewars 8 años (Botella)', 1300, 'Botella.'),
  ('WHISKEY / TRAGOS', 14, 'Dewars 8 años (Trago)', 300, 'Trago / shot.'),
  ('WHISKEY / TRAGOS', 15, 'Fireball Liquors (Botella)', 2800, 'Botella.'),
  ('WHISKEY / TRAGOS', 16, 'Fireball Liquors (Trago)', 300, 'Trago / shot.'),
  ('WHISKEY / TRAGOS', 17, 'Jack Daniel''s (Botella)', 3500, 'Botella.'),
  ('WHISKEY / TRAGOS', 18, 'Jack Daniel''s (Trago)', 350, 'Trago / shot.'),
  ('WHISKEY / TRAGOS', 19, 'Jim Beam Bourbon (Botella)', 3000, 'Botella.'),
  ('WHISKEY / TRAGOS', 20, 'Jim Beam Bourbon (Trago)', 350, 'Trago / shot.'),
  ('WHISKEY / TRAGOS', 21, 'JW Black Label (Botella)', 4500, 'Botella.'),
  ('WHISKEY / TRAGOS', 22, 'JW Black Label (Trago)', 500, 'Trago / shot.'),
  ('WHISKEY / TRAGOS', 23, 'JW Doble Black (Botella)', 5500, 'Botella.'),
  ('WHISKEY / TRAGOS', 24, 'JW Doble Black (Trago)', 600, 'Trago / shot.'),
  ('WHISKEY / TRAGOS', 25, 'JW Gold Label (Botella)', 7000, 'Botella.'),
  ('WHISKEY / TRAGOS', 26, 'JW Gold Label (Trago)', 700, 'Trago / shot.'),
  ('WHISKEY / TRAGOS', 27, 'Old Parr 12 (Botella)', 4500, 'Botella.'),
  ('WHISKEY / TRAGOS', 28, 'Old Parr 12 (Trago)', 450, 'Trago / shot.'),
  ('WHISKEY / TRAGOS', 29, 'Glenfiddich 12 (Botella)', 6000, 'Botella.'),
  ('WHISKEY / TRAGOS', 30, 'The Glenlivet Founders (Botella)', 4500, 'Botella.'),
  ('WHISKEY / TRAGOS', 31, 'The Macallan 12 (Botella)', 11000, 'Botella.'),
  ('VODKA', 1, 'Tito''s Vodka (Botella)', 2700, 'Botella.'),
  ('VODKA', 2, 'Grey Goose (Botella)', 3200, 'Botella.'),
  ('VODKA', 3, 'Belvedere (Botella)', 4000, 'Botella.'),
  ('VODKA', 4, 'Ketel One (Botella)', 3000, 'Botella.'),
  ('VODKA', 5, 'Absolut (Botella)', 2300, 'Botella.'),
  ('VODKA', 6, 'Stolichnaya (Botella)', 2000, 'Botella.'),
  ('VODKA', 7, 'Eristoff (Botella)', 1500, 'Botella.'),
  ('GINEBRA', 1, 'Hendricks (Botella)', 5750, 'Botella.'),
  ('GINEBRA', 2, 'Tanqueray No Ten (Botella)', 4000, 'Botella.'),
  ('GINEBRA', 3, 'Tanqueray Sport (Botella)', 2600, 'Botella.'),
  ('GINEBRA', 4, 'Tanqueray London (Botella)', 3000, 'Botella.'),
  ('GINEBRA', 5, 'Bombay Sapphire (Botella)', 3000, 'Botella.'),
  ('GINEBRA', 6, 'Bulldog (Botella)', 3800, 'Botella.'),
  ('GINEBRA', 7, 'Beefeater Pink (Botella)', 3500, 'Botella.'),
  ('GINEBRA', 8, 'Beefeater (Botella)', 2300, 'Botella.'),
  ('TEQUILA', 1, 'Don Julio Añejo (Botella)', 7300, 'Botella.'),
  ('TEQUILA', 2, 'Don Julio Blanco (Botella)', 6800, 'Botella.'),
  ('TEQUILA', 3, 'Don Julio Reposado (Botella)', 7500, 'Botella.'),
  ('TEQUILA', 4, 'Patron Silver (Botella)', 6200, 'Botella.'),
  ('TEQUILA', 5, 'Agavita Blanco (Botella)', 2500, 'Botella.'),
  ('TEQUILA', 6, 'Agavita Gold (Botella)', 2500, 'Botella.'),
  ('DIGESTIVOS', 1, 'Sambuca Romana', 250, null),
  ('DIGESTIVOS', 2, 'Grappa Cellini Bianca', 250, null),
  ('DIGESTIVOS', 3, 'Grappa Limóncello Cellini', 250, null),
  ('DIGESTIVOS', 4, 'Amaro Averna', 250, null),
  ('DIGESTIVOS', 5, 'Frangelico', 250, null),
  ('DIGESTIVOS', 6, 'Baileys', 300, null),
  ('DIGESTIVOS', 7, 'Kahlua licor de café', 300, null),
  ('DIGESTIVOS', 8, 'Fernet Branca', 300, null),
  ('COPAS DE VINO', 1, 'Vino tinto de la casa', 300, null),
  ('COPAS DE VINO', 2, 'Vino blanco de la casa', 300, null),
  ('VINOS TINTO', 1, 'Lopez de Haro Reserva', 2000, 'Rioja, España.'),
  ('VINOS TINTO', 2, 'Protos 9 Meses', 2400, 'Ribera del Duero, España.'),
  ('VINOS TINTO', 3, 'Emilio Moro Finca Resalso', 2000, 'Ribera del Duero, España.'),
  ('VINOS TINTO', 4, 'Robert Mondavi Private Selection Cabernet Sauvignon', 2200, null),
  ('VINOS TINTO', 5, 'Woodbridge by Robert Mondavi Cabernet Sauvignon', 1500, 'California.'),
  ('VINOS TINTO', 6, '19 Crimes Cali Red Snoop Dogg Red Blend', 2300, 'South Australia.'),
  ('VINOS TINTO', 7, '19 Crimes The Banished Red Blend', 2300, 'California.'),
  ('VINOS TINTO', 8, 'Cantina Zaccagnini Montepulciano D''Abruzzo Sangiovese', 2000, 'Italia.'),
  ('VINOS TINTO', 9, 'Frontera After Midnight', 1500, null),
  ('VINOS TINTO', 10, 'Primitivo Borgo di Mandorlo Red Blend', 2000, 'Italia.'),
  ('VINOS TINTO', 11, 'Trapiche Malbec', 1500, 'Argentina.'),
  ('VINOS TINTO', 12, 'Frontera Carmenere', 1500, 'Chile.'),
  ('VINOS TINTO', 13, 'Josh Cellars Legacy', 2000, null),
  ('VINOS TINTO', 14, 'Beringer Red Crush Red Blend', 1500, 'California.'),
  ('VINOS TINTO', 15, 'Mureda Tempranillo', 1200, null),
  ('VINOS TINTO', 16, 'Knock Knock Red Blend', 1200, null),
  ('VINOS TINTO', 17, 'Próximo Marqués de Riscal', 1500, null),
  ('VINOS TINTO', 18, 'Woodbridge Cabernet Sauvignon', 1500, null),
  ('VINOS BLANCOS', 1, 'Beringer Main & Vine Chardonnay', 1500, null),
  ('VINOS BLANCOS', 2, 'Martín Códax Albariño', 2000, null),
  ('VINOS BLANCOS', 3, 'Beringer Main & Vine Moscato', 1500, null),
  ('VINOS BLANCOS', 4, 'Gotas de Mar Albariño', 2300, null),
  ('VINOS BLANCOS', 5, 'Knock Knock Sauvignon Blanc', 1200, null),
  ('VINOS BLANCOS', 6, 'Marqués de Riscal', 2000, null),
  ('VINOS BLANCOS', 7, 'Marqués de Vizhoja', 1500, null),
  ('VINOS BLANCOS', 8, 'Mureda Sauvignon Blanc', 1200, null),
  ('VINOS BLANCOS', 9, 'Torresella Pinot Grigio', 1500, null),
  ('VINOS BLANCOS', 10, 'Woodbridge Sauvignon Blanc', 1500, null),
  ('VINOS BLANCOS', 11, 'Frontera Pinot Grigio', 1200, null),
  ('VINOS ROSADO', 1, '19 Crimes Cali Rosé', 2300, null),
  ('VINOS ROSADO', 2, 'Woodbridge White Zinfandel', 1500, null),
  ('VINOS ROSADO', 3, 'Beringer White Zinfandel', 1500, null),
  ('CAVA / PROSECCO', 1, 'Segura Viudas Brut Reserva', 2000, 'España.'),
  ('CAVA / PROSECCO', 2, 'Segura Viudas Brut Rosé', 2000, 'España.'),
  ('CAVA / PROSECCO', 3, 'Prosecco Maschio', 2000, 'Italia.'),
  ('CAVA / PROSECCO', 4, 'Jaume Serra Cava', 1200, null),
  ('CHAMPAGNE', 1, 'Perrier Jouet Grand Brut', 6600, null),
  ('CHAMPAGNE', 2, 'Pommery Brut Royal', 4900, null),
  ('CIGARROS', 1, 'La Aurora 115 Aniversario c/u', 550, null),
  ('CIGARROS', 2, 'La Aurora Connecticut c/u', 400, null),
  ('CIGARROS', 3, 'La Aurora Maduro Belicoso c/u', 450, null),
  ('CIGARROS', 4, 'La Aurora Maduro Robusto c/u', 400, null),
  ('CIGARROS', 5, 'León Jimenes No. 5 c/u', 350, null),
  ('CIGARROS', 6, 'Don Carlos Altagracia Premium', 500, null),
  ('CIGARRILLOS', 1, 'Lucky Strike Black', 275, null),
  ('CIGARRILLOS', 2, 'Marlboro Fresh Ice Peq.', 500, null),
  ('CIGARRILLOS', 3, 'Marlboro Gold Peq.', 400, null),
  ('CIGARRILLOS', 4, 'Marlboro Rojo Peq.', 350, null);


-- ---------------------------------------------------------------------------
-- 4. ÁREAS DE IMPRESIÓN. Resuelve la de cocina y la de bar contra las que
--    el negocio YA tiene configuradas. No inventa áreas.
-- ---------------------------------------------------------------------------
drop table if exists _eco_area;
create temp table _eco_area(kind text primary key, area_id uuid, code text);

insert into _eco_area(kind, area_id, code)
select 'cocina', pa.id, pa.code from public.print_areas pa
 where pa.business_id = 'fc3065c8-cb40-45ad-bec1-aecb388001c1' and pa.is_active
   and (pa.code in ('kitchen_hot','kitchen','cocina','kitchen_cold')
        or pa.name ilike '%cocina%' or pa.name ilike '%kitchen%')
 order by case pa.code when 'kitchen_hot' then 0 when 'cocina' then 1 else 2 end, pa.created_at
 limit 1;

insert into _eco_area(kind, area_id, code)
select 'bar', pa.id, pa.code from public.print_areas pa
 where pa.business_id = 'fc3065c8-cb40-45ad-bec1-aecb388001c1' and pa.is_active
   and (pa.code = 'bar' or pa.name ilike '%bar%')
 order by case when pa.code = 'bar' then 0 else 1 end, pa.created_at
 limit 1;

-- Sin área de cocina: usa cualquier área activa del negocio.
insert into _eco_area(kind, area_id, code)
select 'cocina', pa.id, pa.code from public.print_areas pa
 where pa.business_id = 'fc3065c8-cb40-45ad-bec1-aecb388001c1' and pa.is_active
   and not exists (select 1 from _eco_area where kind = 'cocina')
 order by pa.created_at limit 1;

-- Sin área de bar: todo va a la de cocina.
insert into _eco_area(kind, area_id, code)
select 'bar', a.area_id, a.code from _eco_area a
 where a.kind = 'cocina'
   and not exists (select 1 from _eco_area b where b.kind = 'bar');

do $$
begin
  if not exists (select 1 from _eco_area) then
    raise warning 'El negocio no tiene áreas de impresión activas: los productos quedan SIN área y "Enviar a cocina" los va a rechazar. Créalas en Ajustes → Impresión y vuelve a correr el paso 6.';
  end if;
end $$;


-- ---------------------------------------------------------------------------
-- 5. IMPUESTOS. Se replica el set que ya usaba la mayoría del menú viejo
--    (así no se cambia la configuración fiscal sin querer). Si el menú viejo
--    no tenía ninguno vinculado, cae al ITBIS activo del negocio.
-- ---------------------------------------------------------------------------
drop table if exists _eco_tax;
create temp table _eco_tax(tax_id uuid primary key);

insert into _eco_tax(tax_id)
select bt.tax_id
  from public.zzz_ecobar_bk_menu_item_taxes bt
  join public.zzz_ecobar_bk_menu_items bm on bm.id = bt.item_id and bm.is_active
  join public.taxes t on t.id = bt.tax_id and t.is_active
 group by bt.tax_id
having count(*) >= 0.5 * greatest(
         (select count(*) from public.zzz_ecobar_bk_menu_items where is_active), 1);

insert into _eco_tax(tax_id)
select t.id from public.taxes t
 where t.business_id = 'fc3065c8-cb40-45ad-bec1-aecb388001c1' and t.is_active
   and t.name ilike '%itbis%'
   and not exists (select 1 from _eco_tax);

do $$
begin
  if not exists (select 1 from _eco_tax) then
    raise warning 'No se resolvió ningún impuesto: el menú nuevo va a facturar con ITBIS 0. Revisa Ajustes → Impuestos y corre el paso 8.';
  end if;
end $$;


-- ---------------------------------------------------------------------------
-- 6. CREAR CATEGORÍAS.
-- ---------------------------------------------------------------------------
insert into public.categories (id, business_id, name, position, is_active)
select gen_random_uuid(), 'fc3065c8-cb40-45ad-bec1-aecb388001c1', c.name, c.pos, true
  from _eco_cat c;


-- ---------------------------------------------------------------------------
-- 7. CREAR PRODUCTOS. tax_mode='exclusive' porque el PDF cobra el ITBIS aparte.
-- ---------------------------------------------------------------------------
insert into public.menu_items (
  business_id, category_id, name, price, tax_mode, is_active, description,
  is_beverage, sold_by, position, print_area_code, updated_at
)
select 'fc3065c8-cb40-45ad-bec1-aecb388001c1',
       c.id,
       i.name,
       i.price,
       'exclusive',
       true,
       i.descr,
       cc.bev,
       'unit'::public.sold_by_type,
       i.pos,
       ar.code,
       now()
  from _eco_item i
  join _eco_cat cc on cc.name = i.cat
  join public.categories c on c.business_id = 'fc3065c8-cb40-45ad-bec1-aecb388001c1' and c.name = i.cat and c.is_active
  left join _eco_area ar on ar.kind = cc.kind;


-- ---------------------------------------------------------------------------
-- 8. VINCULAR IMPUESTOS a todo el menú nuevo.
-- ---------------------------------------------------------------------------
insert into public.menu_item_taxes (item_id, tax_id)
select mi.id, x.tax_id
  from public.menu_items mi
  cross join _eco_tax x
 where mi.business_id = 'fc3065c8-cb40-45ad-bec1-aecb388001c1' and mi.is_active
on conflict do nothing;


-- ---------------------------------------------------------------------------
-- 9. ÁREA DE IMPRESIÓN N:M (la que manda; print_area_code queda de respaldo).
-- ---------------------------------------------------------------------------
insert into public.menu_item_print_areas (menu_item_id, print_area_id)
select mi.id, ar.area_id
  from public.menu_items mi
  join public.categories c on c.id = mi.category_id
  join _eco_cat cc on cc.name = c.name
  join _eco_area ar on ar.kind = cc.kind
 where mi.business_id = 'fc3065c8-cb40-45ad-bec1-aecb388001c1' and mi.is_active and ar.area_id is not null
on conflict do nothing;


-- ---------------------------------------------------------------------------
-- 10. RESULTADO.
-- ---------------------------------------------------------------------------
select c.position                                   as orden,
       c.name                                       as categoria,
       count(mi.id)                                 as productos,
       min(mi.price)                                as precio_min,
       max(mi.price)                                as precio_max,
       min(mi.print_area_code)                      as area
  from public.categories c
  left join public.menu_items mi
         on mi.category_id = c.id and mi.is_active
 where c.business_id = 'fc3065c8-cb40-45ad-bec1-aecb388001c1' and c.is_active
 group by c.position, c.name
 order by c.position;

select count(*) as productos_nuevos,
       count(*) filter (where print_area_code is null) as sin_area,
       count(*) filter (where not exists (
         select 1 from public.menu_item_taxes t where t.item_id = menu_items.id
       )) as sin_impuesto
  from public.menu_items
 where business_id = 'fc3065c8-cb40-45ad-bec1-aecb388001c1' and is_active;
