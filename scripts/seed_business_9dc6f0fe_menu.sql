-- ============================================================================
-- Seed de productos: El Faro (restaurante de mariscos)
-- Business: 9dc6f0fe-a152-4a60-b279-22885717eec5
-- ============================================================================
--
-- Carga el menú físico al sistema (49 productos en 9 categorías):
--   ENTRADAS, PLATOS FUERTES, MAR Y TIERRA, MOFONGOS, PASTAS, CALDOS,
--   CORTES DE CARNES, PARA LOS MÁS PEQUEÑOS, GUARNICIONES.
--
-- Todos los precios son INCLUSIVOS de ITBIS (tax_mode = 'inclusive'):
--   el precio mostrado al cliente ya incluye el impuesto.
--
-- Todos los platos van a cocina (has_prep = true → print_area_code 'kitchen_hot'
-- por default). No hay control de stock (is_inventory_tracked queda false);
-- el dueño lo activa por producto desde el admin cuando configure recetas.
--
-- Idempotente:
--   - Categorías: se crean sólo si no existen para este business.
--   - Productos: se insertan sólo si no hay un menu_item con el mismo
--     nombre en este business. Re-ejecutar el script no duplica items.
--
-- Decisiones de carga (del menú físico):
--   - Platos con preparaciones (a la criolla / al ajillo / a la crema, Alfredo
--     de camarones/mariscos/pollo, Pechuga a la plancha/empanizada/crema, etc.)
--     se cargan como UN solo producto; las opciones quedan en la descripción.
--   - Cortes SIN precio publicado (Ribeye Premium, Picaña, Filete Mignón) se
--     cargan con price = 0 y is_active = false, para que NO aparezcan vendibles
--     a precio cero. El dueño les pone precio y los activa desde el admin.
--   - GUARNICIONES no traen precio individual en el menú; sólo dice "Extras 100$",
--     así que se cargan a 100. Ajusta si aplica.
-- ============================================================================

begin;

-- ----------------------------------------------------------------------------
-- 1) Categorías
-- ----------------------------------------------------------------------------

insert into public.categories (id, business_id, name, position, is_active)
select gen_random_uuid(), '9dc6f0fe-a152-4a60-b279-22885717eec5', 'ENTRADAS', 0, true
where not exists (
  select 1 from public.categories
  where business_id = '9dc6f0fe-a152-4a60-b279-22885717eec5' and name = 'ENTRADAS'
);

insert into public.categories (id, business_id, name, position, is_active)
select gen_random_uuid(), '9dc6f0fe-a152-4a60-b279-22885717eec5', 'PLATOS FUERTES', 1, true
where not exists (
  select 1 from public.categories
  where business_id = '9dc6f0fe-a152-4a60-b279-22885717eec5' and name = 'PLATOS FUERTES'
);

insert into public.categories (id, business_id, name, position, is_active)
select gen_random_uuid(), '9dc6f0fe-a152-4a60-b279-22885717eec5', 'MAR Y TIERRA', 2, true
where not exists (
  select 1 from public.categories
  where business_id = '9dc6f0fe-a152-4a60-b279-22885717eec5' and name = 'MAR Y TIERRA'
);

insert into public.categories (id, business_id, name, position, is_active)
select gen_random_uuid(), '9dc6f0fe-a152-4a60-b279-22885717eec5', 'MOFONGOS', 3, true
where not exists (
  select 1 from public.categories
  where business_id = '9dc6f0fe-a152-4a60-b279-22885717eec5' and name = 'MOFONGOS'
);

insert into public.categories (id, business_id, name, position, is_active)
select gen_random_uuid(), '9dc6f0fe-a152-4a60-b279-22885717eec5', 'PASTAS', 4, true
where not exists (
  select 1 from public.categories
  where business_id = '9dc6f0fe-a152-4a60-b279-22885717eec5' and name = 'PASTAS'
);

insert into public.categories (id, business_id, name, position, is_active)
select gen_random_uuid(), '9dc6f0fe-a152-4a60-b279-22885717eec5', 'CALDOS', 5, true
where not exists (
  select 1 from public.categories
  where business_id = '9dc6f0fe-a152-4a60-b279-22885717eec5' and name = 'CALDOS'
);

insert into public.categories (id, business_id, name, position, is_active)
select gen_random_uuid(), '9dc6f0fe-a152-4a60-b279-22885717eec5', 'CORTES DE CARNES', 6, true
where not exists (
  select 1 from public.categories
  where business_id = '9dc6f0fe-a152-4a60-b279-22885717eec5' and name = 'CORTES DE CARNES'
);

insert into public.categories (id, business_id, name, position, is_active)
select gen_random_uuid(), '9dc6f0fe-a152-4a60-b279-22885717eec5', 'PARA LOS MÁS PEQUEÑOS', 7, true
where not exists (
  select 1 from public.categories
  where business_id = '9dc6f0fe-a152-4a60-b279-22885717eec5' and name = 'PARA LOS MÁS PEQUEÑOS'
);

insert into public.categories (id, business_id, name, position, is_active)
select gen_random_uuid(), '9dc6f0fe-a152-4a60-b279-22885717eec5', 'GUARNICIONES', 8, true
where not exists (
  select 1 from public.categories
  where business_id = '9dc6f0fe-a152-4a60-b279-22885717eec5' and name = 'GUARNICIONES'
);

-- ----------------------------------------------------------------------------
-- 2) Productos
-- ----------------------------------------------------------------------------

do $$
declare
  v_business uuid := '9dc6f0fe-a152-4a60-b279-22885717eec5';
  v_cat_entradas     uuid;
  v_cat_fuertes      uuid;
  v_cat_marytierra   uuid;
  v_cat_mofongos     uuid;
  v_cat_pastas       uuid;
  v_cat_caldos       uuid;
  v_cat_cortes       uuid;
  v_cat_ninos        uuid;
  v_cat_guarniciones uuid;
begin
  select id into v_cat_entradas     from public.categories where business_id = v_business and name = 'ENTRADAS' limit 1;
  select id into v_cat_fuertes      from public.categories where business_id = v_business and name = 'PLATOS FUERTES' limit 1;
  select id into v_cat_marytierra   from public.categories where business_id = v_business and name = 'MAR Y TIERRA' limit 1;
  select id into v_cat_mofongos     from public.categories where business_id = v_business and name = 'MOFONGOS' limit 1;
  select id into v_cat_pastas       from public.categories where business_id = v_business and name = 'PASTAS' limit 1;
  select id into v_cat_caldos       from public.categories where business_id = v_business and name = 'CALDOS' limit 1;
  select id into v_cat_cortes       from public.categories where business_id = v_business and name = 'CORTES DE CARNES' limit 1;
  select id into v_cat_ninos        from public.categories where business_id = v_business and name = 'PARA LOS MÁS PEQUEÑOS' limit 1;
  select id into v_cat_guarniciones from public.categories where business_id = v_business and name = 'GUARNICIONES' limit 1;

  -- ==========================================================================
  -- ENTRADAS (8 productos)
  -- ==========================================================================
  insert into public.menu_items (
    business_id, category_id, name, price, description, tax_mode,
    is_active, has_prep, position
  )
  select
    v_business, v_cat_entradas, n.name, n.price::numeric(12,2), n.descr::text,
    'inclusive', n.active, true, n.pos
  from (values
    ('Sabor del faro', 450, 'Crujientes camarones jumbo rebozados en tempura japonesa tradicional, acompañados de finas y crocantes tiras de plátano verde frito. Servidos con salsa agridulce de la casa.', true, 1),
    ('Aros de calamar crujientes', 350, 'Tiernos aros de calamar seleccionados, empanizados al momento con un rebozado crujiente y sazonado. Servidos con cuñas de limón fresco y nuestra salsa tártara artesanal.', true, 2),
    ('Ensalada Capressa', 399, 'Rodajas de tomate maduro y mozzarella de búfala fresca, intercaladas con hojas de albahaca aromática, bañadas en aceite de oliva virgen extra y un toque de pimienta negra.', true, 3),
    ('Mozzarella Sticks', 299, 'Dedos de queso mozzarella Premium empanizados, fritos a la perfección hasta quedar dorados y derretidos. Acompañados de nuestra salsa marinara de la casa.', true, 4),
    ('Minis canasticas de pollo', 380, '3 canastitas artesanales rellenas de jugoso pollo desmechado, sazonado al estilo criollo, coronadas con un toque de crema de la casa.', true, 5),
    ('Canapés de pulpo', 450, 'Delicadas láminas de pulpo cocido a la perfección sobre crocantes de pan.', true, 6),
    ('Los Tacos Mordisco', 350, 'Tres tacos rellenos a su preferencia (pollo o camarones) acompañados de nuestra rica salsa de la casa.', true, 7),
    ('Croquetas de pescado', 399, 'Deliciosas croquetas empanizadas elaboradas con pescado fresco, con una salsa chutney de cilantro fresco y limón.', true, 8)
  ) as n(name, price, descr, active, pos)
  where not exists (
    select 1 from public.menu_items mi
    where mi.business_id = v_business and mi.name = n.name
  );

  -- ==========================================================================
  -- PLATOS FUERTES (16 productos)
  -- ==========================================================================
  insert into public.menu_items (
    business_id, category_id, name, price, description, tax_mode,
    is_active, has_prep, position
  )
  select
    v_business, v_cat_fuertes, n.name, n.price::numeric(12,2), n.descr::text,
    'inclusive', n.active, true, n.pos
  from (values
    ('Seafood case (2 personas)', 1850, 'La Gran Funda Marinera (para compartir): espectacular selección de mariscos que incluye centolla, camarones jumbo, calamar, almejas y langostinos cocidos al vapor en su propio jugo con ruedas de maíz dulce y huevos. Todo bañado en nuestra intensa y secreta salsa de mantequilla con ajo asado, servido directamente en mesa.', true, 1),
    ('Wok Marinero de Arroz Frito', 750, 'Delicioso y generoso arroz salteado al estilo oriental con camarones, anillos de calamar, mejillones y almejas, mezclado con vegetales y el toque perfecto de la salsa de la casa.', true, 2),
    ('Camarones', 700, 'A la criolla, al ajillo o a la crema. Servidos con tu elección de acompañamiento.', true, 3),
    ('La Corona del Mar', 1550, 'El caparazón de una centolla Premium seleccionado, relleno con una jugosa combinación de camarones jumbo y tiernos trozos de pulpo salteados, bañado en nuestra cremosa salsa de la casa. Una obra de arte para los verdaderos amantes del mar.', true, 4),
    ('Elixir Marino', 900, 'Cubos de pescado blanco Premium marinados al momento en jugo de limón recién exprimido, con camarones, cebolla morada crujiente, cilantro fresco y un sutil toque de ají.', true, 5),
    ('Ceviche Marea Fría', 1000, 'Una selección de cubos de pescado blanco fresco, tiernos camarones y láminas de pulpo cocido, marinados al momento en puro jugo de limón cítrico y vegetales salteados.', true, 6),
    ('Pulpo a la parrilla', 750, 'Tierno tentáculo de pulpo marinado en una infusión de ají, ajo y finas hierbas, sellado a la brasa viva para lograr un exterior crujiente y un interior sumamente suave. Servido sobre una cama de vegetales.', true, 7),
    ('Pulpo coralino a la brasa', 750, 'Tierno pulpo braseado al carbón, servido sobre nuestro exclusivo chutney de piña glaseada y jengibre fresco. Perfumado con hojas de menta y albahaca.', true, 8),
    ('Lambí', 600, 'A la criolla, al ajillo o a la crema. Servidos con tu elección de acompañamiento.', true, 9),
    ('Lambí glaseado en reducción de champagne y mantequilla de trufa', 699, 'Láminas de lambí Premium tiernizadas al vacío, perfectamente glaseadas en una reducción caliente de champagne Brut y una emulsión de mantequilla de trufa blanca.', true, 10),
    ('Capricho tropical de lambí', 699, 'Delicados cubos de lambí fresco marinados en zumo de limón criollo, coronados con cilantro fresco y un toque de aceite de oliva extra virgen.', true, 11),
    ('Langosta', 900, 'Langosta caribeña servida a su preferencia: al ajillo, a la criolla o a la crema.', true, 12),
    ('Pescado', 400, 'Pescado entero de temporada, seleccionado a mano y elaborado a su gusto: al vapor, frito, a la criolla o a la crema.', true, 13),
    ('Salmón Rosado a la Brasa Viva', 950, 'Lomo de salmón Premium seleccionado, sellado a la parrilla para lograr una costra dorada y ahumada mientras conserva su centro jugoso y tierno. Glaseado con un toque de mantequilla de hierbas finas y servido sobre vegetales asados.', true, 14),
    ('Mero Supremo al Ajillo', 375, 'Filete de mero de carne firme, bañado en una salsa de ajo laminado, mantequilla o aceite de oliva.', true, 15),
    ('Filete de mero real en salsa de coco', 450, 'Corte selecto de mero real sellado a la perfección, bañado en una suntuosa reducción de leche de coco con finas hierbas. El balance ideal.', true, 16)
  ) as n(name, price, descr, active, pos)
  where not exists (
    select 1 from public.menu_items mi
    where mi.business_id = v_business and mi.name = n.name
  );

  -- ==========================================================================
  -- MAR Y TIERRA (2 productos)
  -- ==========================================================================
  insert into public.menu_items (
    business_id, category_id, name, price, description, tax_mode,
    is_active, has_prep, position
  )
  select
    v_business, v_cat_marytierra, n.name, n.price::numeric(12,2), n.descr::text,
    'inclusive', n.active, true, n.pos
  from (values
    ('Suprema Mar y Tierra', 999, 'Tierna pechuga de pollo rellena de jugosos camarones seleccionados, sellada a la plancha y bañada en una suntuosa crema de queso parmesano.', true, 1),
    ('El Tablón Supremo del Capitán (2 personas)', 1600, 'Espectacular y generosa combinación servida sobre madera: cortes jugosos de carnes (costillas, pechuga de pollo grillada, filete de cerdo) y mar (camarones jumbo, crujientes aros de calamar empanizados, langostinos). Acompañado de una montaña de tostones artesanales o papas fritas y un set de salsas de la casa.', true, 2)
  ) as n(name, price, descr, active, pos)
  where not exists (
    select 1 from public.menu_items mi
    where mi.business_id = v_business and mi.name = n.name
  );

  -- ==========================================================================
  -- MOFONGOS (2 productos)
  -- ==========================================================================
  insert into public.menu_items (
    business_id, category_id, name, price, description, tax_mode,
    is_active, has_prep, position
  )
  select
    v_business, v_cat_mofongos, n.name, n.price::numeric(12,2), n.descr::text,
    'inclusive', n.active, true, n.pos
  from (values
    ('Mofongo', 500, 'Plátano verde seleccionado, frito y majado a mano en pilón de madera con abundante ajo asado y finas hierbas, con el relleno de tu preferencia: camarones, pollo o chicharrones.', true, 1),
    ('Mofongo Mixto', 900, 'Plátano verde seleccionado, frito y majado a mano en pilón de madera con abundante ajo asado y finas hierbas, con relleno mixto.', true, 2)
  ) as n(name, price, descr, active, pos)
  where not exists (
    select 1 from public.menu_items mi
    where mi.business_id = v_business and mi.name = n.name
  );

  -- ==========================================================================
  -- PASTAS (1 producto)
  -- ==========================================================================
  insert into public.menu_items (
    business_id, category_id, name, price, description, tax_mode,
    is_active, has_prep, position
  )
  select
    v_business, v_cat_pastas, n.name, n.price::numeric(12,2), n.descr::text,
    'inclusive', n.active, true, n.pos
  from (values
    ('Pasta Alfredo', 700, 'Cremosa pasta Alfredo a tu elección: de camarones, de mariscos o de pollo.', true, 1)
  ) as n(name, price, descr, active, pos)
  where not exists (
    select 1 from public.menu_items mi
    where mi.business_id = v_business and mi.name = n.name
  );

  -- ==========================================================================
  -- CALDOS (3 productos)
  -- ==========================================================================
  insert into public.menu_items (
    business_id, category_id, name, price, description, tax_mode,
    is_active, has_prep, position
  )
  select
    v_business, v_cat_caldos, n.name, n.price::numeric(12,2), n.descr::text,
    'inclusive', n.active, true, n.pos
  from (values
    ('Sopa de mariscos', 800, null, true, 1),
    ('Sopa de camarones', 550, null, true, 2),
    ('Sopa de pollo', 250, null, true, 3)
  ) as n(name, price, descr, active, pos)
  where not exists (
    select 1 from public.menu_items mi
    where mi.business_id = v_business and mi.name = n.name
  );

  -- ==========================================================================
  -- CORTES DE CARNES (8 productos)
  --   Ribeye, Picaña y Filete Mignón: sin precio en el menú → price 0, inactivos.
  -- ==========================================================================
  insert into public.menu_items (
    business_id, category_id, name, price, description, tax_mode,
    is_active, has_prep, position
  )
  select
    v_business, v_cat_cortes, n.name, n.price::numeric(12,2), n.descr::text,
    'inclusive', n.active, true, n.pos
  from (values
    ('Costillas a la BBQ', 450, 'Tiernas costillas de cerdo cocinadas a fuego lento hasta que la carne casi se sale del hueso, terminadas a la parrilla con abundante salsa BBQ dulce y ahumada.', true, 1),
    ('Alitas a la BBQ', 400, 'Alitas de pollo seleccionadas, fritas a la perfección para lograr una piel extra crujiente por fuera y jugosa por dentro. Bañadas generosamente en nuestra salsa BBQ dulce y ahumada, acompañadas de aderezo ranch.', true, 2),
    ('Ribeye Premium a la Vuelta del Fuego', 0, 'Jugoso y tierno corte de Ribeye seleccionado por su excelente marmoleo de grasa natural. Sellado a la parrilla de carbón al término de su elección para resaltar su intenso sabor y suavidad.', false, 3),
    ('Picaña', 0, 'Jugoso y tierno corte de picaña, famoso por su característica capa de grasa exterior que le aporta una jugosidad única y un sabor inigualable. Sellado a fuego vivo al término de su elección, espolvoreado con sal marina gruesa y servido con tu guarnición preferida.', false, 4),
    ('Churrasco', 900, 'Jugoso y tierno corte de churrasco Premium, sellado a fuego vivo en nuestra parrilla para concentrar sus jugos naturales.', true, 5),
    ('Filete Mignón', 0, 'El corte más tierno de lomo fino de res seleccionado, abrazado en crujiente tocineta ahumada y sellado a la plancha en mantequilla de ajo. Bañado en una suntuosa reducción de vino tinto.', false, 6),
    ('Filete de cerdo glaseado', 499, 'Medallones de solomillo de cerdo extra tierno y magro, sellados a la plancha con mantequilla de ajo y romero. Glaseados con una suave reducción de miel y mostaza antigua.', true, 7),
    ('Pechuga de pollo', 399, 'Jugosa pechuga de pollo servida a su preferencia: a la plancha, empanizada o a la crema. Acompañada de la guarnición de su preferencia.', true, 8)
  ) as n(name, price, descr, active, pos)
  where not exists (
    select 1 from public.menu_items mi
    where mi.business_id = v_business and mi.name = n.name
  );

  -- ==========================================================================
  -- PARA LOS MÁS PEQUEÑOS (3 productos)
  -- ==========================================================================
  insert into public.menu_items (
    business_id, category_id, name, price, description, tax_mode,
    is_active, has_prep, position
  )
  select
    v_business, v_cat_ninos, n.name, n.price::numeric(12,2), n.descr::text,
    'inclusive', n.active, true, n.pos
  from (values
    ('Pechurina', 150, null, true, 1),
    ('Hamburguesa', 250, null, true, 2),
    ('Montaña de Papas', 150, 'Explosión de papas fritas bañadas en queso.', true, 3)
  ) as n(name, price, descr, active, pos)
  where not exists (
    select 1 from public.menu_items mi
    where mi.business_id = v_business and mi.name = n.name
  );

  -- ==========================================================================
  -- GUARNICIONES (6 productos) — sin precio individual en el menú; "Extras 100$".
  -- ==========================================================================
  insert into public.menu_items (
    business_id, category_id, name, price, description, tax_mode,
    is_active, has_prep, position
  )
  select
    v_business, v_cat_guarniciones, n.name, n.price::numeric(12,2), n.descr::text,
    'inclusive', n.active, true, n.pos
  from (values
    ('Fritos verdes', 100, null, true, 1),
    ('Yuquita frita', 100, null, true, 2),
    ('Casabe tostado', 100, null, true, 3),
    ('Puré de papa', 100, null, true, 4),
    ('Papas fritas', 100, null, true, 5),
    ('Vegetales salteados/al grill', 100, null, true, 6)
  ) as n(name, price, descr, active, pos)
  where not exists (
    select 1 from public.menu_items mi
    where mi.business_id = v_business and mi.name = n.name
  );

end $$;

commit;

-- ============================================================================
-- Verificación (opcional): conteo por categoría
-- ============================================================================
-- select c.name as categoria, count(mi.id) as productos
-- from public.categories c
-- left join public.menu_items mi on mi.category_id = c.id
-- where c.business_id = '9dc6f0fe-a152-4a60-b279-22885717eec5'
-- group by c.name, c.position
-- order by c.position;
