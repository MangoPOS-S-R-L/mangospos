-- ============================================================================
-- Seed de productos del menú
-- Business: f9128fc0-ae24-45f3-bd6f-1e1c9eae084b
-- ============================================================================
--
-- Carga el menú completo (~261 productos en 24 categorías).
--
-- Idempotente:
--   - Categorías: se crean sólo si no existen para este business.
--   - Productos: se insertan sólo si no hay un menu_item con el mismo
--     nombre en este business. Re-ejecutar el script no duplica items.
--
-- Notas de origen:
--   - Origen: export JSON externo (productos.json). Encoding mojibake
--     (Ã±, Ã³, etc.) fue corregido a UTF-8 nativo.
--   - Todos los productos del export tenían "TIENE CONTROL DE STOCK" = NO,
--     así que is_inventory_tracked queda en false. El admin lo activa
--     por producto desde el formulario cuando configure recetas.
--   - tax_mode = 'exclusive' por default. Cámbialo a 'inclusive' si los
--     precios cargados ya incluyen ITBIS.
-- ============================================================================

begin;

-- ----------------------------------------------------------------------------
-- 1) Categorías
-- ----------------------------------------------------------------------------
insert into public.categories (id, business_id, name, position, is_active)
select gen_random_uuid(), 'f9128fc0-ae24-45f3-bd6f-1e1c9eae084b', 'AGUAS, REFRESCO AGUAS T.', 0, true
where not exists (
  select 1 from public.categories
  where business_id = 'f9128fc0-ae24-45f3-bd6f-1e1c9eae084b' and name = 'AGUAS, REFRESCO AGUAS T.'
);
insert into public.categories (id, business_id, name, position, is_active)
select gen_random_uuid(), 'f9128fc0-ae24-45f3-bd6f-1e1c9eae084b', 'CAFFE Y CAPUCCINO', 1, true
where not exists (
  select 1 from public.categories
  where business_id = 'f9128fc0-ae24-45f3-bd6f-1e1c9eae084b' and name = 'CAFFE Y CAPUCCINO'
);
insert into public.categories (id, business_id, name, position, is_active)
select gen_random_uuid(), 'f9128fc0-ae24-45f3-bd6f-1e1c9eae084b', 'CARNES Y PESCADOS', 2, true
where not exists (
  select 1 from public.categories
  where business_id = 'f9128fc0-ae24-45f3-bd6f-1e1c9eae084b' and name = 'CARNES Y PESCADOS'
);
insert into public.categories (id, business_id, name, position, is_active)
select gen_random_uuid(), 'f9128fc0-ae24-45f3-bd6f-1e1c9eae084b', 'CARTA DE VINO', 3, true
where not exists (
  select 1 from public.categories
  where business_id = 'f9128fc0-ae24-45f3-bd6f-1e1c9eae084b' and name = 'CARTA DE VINO'
);
insert into public.categories (id, business_id, name, position, is_active)
select gen_random_uuid(), 'f9128fc0-ae24-45f3-bd6f-1e1c9eae084b', 'CERVEZA', 4, true
where not exists (
  select 1 from public.categories
  where business_id = 'f9128fc0-ae24-45f3-bd6f-1e1c9eae084b' and name = 'CERVEZA'
);
insert into public.categories (id, business_id, name, position, is_active)
select gen_random_uuid(), 'f9128fc0-ae24-45f3-bd6f-1e1c9eae084b', 'CHAMPAGNE', 5, true
where not exists (
  select 1 from public.categories
  where business_id = 'f9128fc0-ae24-45f3-bd6f-1e1c9eae084b' and name = 'CHAMPAGNE'
);
insert into public.categories (id, business_id, name, position, is_active)
select gen_random_uuid(), 'f9128fc0-ae24-45f3-bd6f-1e1c9eae084b', 'ENSALADA''S Y CARPACCIO''S', 6, true
where not exists (
  select 1 from public.categories
  where business_id = 'f9128fc0-ae24-45f3-bd6f-1e1c9eae084b' and name = 'ENSALADA''S Y CARPACCIO''S'
);
insert into public.categories (id, business_id, name, position, is_active)
select gen_random_uuid(), 'f9128fc0-ae24-45f3-bd6f-1e1c9eae084b', 'ENTRADAS', 7, true
where not exists (
  select 1 from public.categories
  where business_id = 'f9128fc0-ae24-45f3-bd6f-1e1c9eae084b' and name = 'ENTRADAS'
);
insert into public.categories (id, business_id, name, position, is_active)
select gen_random_uuid(), 'f9128fc0-ae24-45f3-bd6f-1e1c9eae084b', 'EXTRAS', 8, true
where not exists (
  select 1 from public.categories
  where business_id = 'f9128fc0-ae24-45f3-bd6f-1e1c9eae084b' and name = 'EXTRAS'
);
insert into public.categories (id, business_id, name, position, is_active)
select gen_random_uuid(), 'f9128fc0-ae24-45f3-bd6f-1e1c9eae084b', 'GINEBRA', 9, true
where not exists (
  select 1 from public.categories
  where business_id = 'f9128fc0-ae24-45f3-bd6f-1e1c9eae084b' and name = 'GINEBRA'
);
insert into public.categories (id, business_id, name, position, is_active)
select gen_random_uuid(), 'f9128fc0-ae24-45f3-bd6f-1e1c9eae084b', 'PASTA DE AUTORES', 10, true
where not exists (
  select 1 from public.categories
  where business_id = 'f9128fc0-ae24-45f3-bd6f-1e1c9eae084b' and name = 'PASTA DE AUTORES'
);
insert into public.categories (id, business_id, name, position, is_active)
select gen_random_uuid(), 'f9128fc0-ae24-45f3-bd6f-1e1c9eae084b', 'PASTA FRESCA HOME MADE', 11, true
where not exists (
  select 1 from public.categories
  where business_id = 'f9128fc0-ae24-45f3-bd6f-1e1c9eae084b' and name = 'PASTA FRESCA HOME MADE'
);
insert into public.categories (id, business_id, name, position, is_active)
select gen_random_uuid(), 'f9128fc0-ae24-45f3-bd6f-1e1c9eae084b', 'PASTAS', 12, true
where not exists (
  select 1 from public.categories
  where business_id = 'f9128fc0-ae24-45f3-bd6f-1e1c9eae084b' and name = 'PASTAS'
);
insert into public.categories (id, business_id, name, position, is_active)
select gen_random_uuid(), 'f9128fc0-ae24-45f3-bd6f-1e1c9eae084b', 'PIZZA''S ARTESANALES', 13, true
where not exists (
  select 1 from public.categories
  where business_id = 'f9128fc0-ae24-45f3-bd6f-1e1c9eae084b' and name = 'PIZZA''S ARTESANALES'
);
insert into public.categories (id, business_id, name, position, is_active)
select gen_random_uuid(), 'f9128fc0-ae24-45f3-bd6f-1e1c9eae084b', 'POSTRE', 14, true
where not exists (
  select 1 from public.categories
  where business_id = 'f9128fc0-ae24-45f3-bd6f-1e1c9eae084b' and name = 'POSTRE'
);
insert into public.categories (id, business_id, name, position, is_active)
select gen_random_uuid(), 'f9128fc0-ae24-45f3-bd6f-1e1c9eae084b', 'PROSECCO Y  CAVA', 15, true
where not exists (
  select 1 from public.categories
  where business_id = 'f9128fc0-ae24-45f3-bd6f-1e1c9eae084b' and name = 'PROSECCO Y  CAVA'
);
insert into public.categories (id, business_id, name, position, is_active)
select gen_random_uuid(), 'f9128fc0-ae24-45f3-bd6f-1e1c9eae084b', 'RISOTTOS.', 16, true
where not exists (
  select 1 from public.categories
  where business_id = 'f9128fc0-ae24-45f3-bd6f-1e1c9eae084b' and name = 'RISOTTOS.'
);
insert into public.categories (id, business_id, name, position, is_active)
select gen_random_uuid(), 'f9128fc0-ae24-45f3-bd6f-1e1c9eae084b', 'RONNES', 17, true
where not exists (
  select 1 from public.categories
  where business_id = 'f9128fc0-ae24-45f3-bd6f-1e1c9eae084b' and name = 'RONNES'
);
insert into public.categories (id, business_id, name, position, is_active)
select gen_random_uuid(), 'f9128fc0-ae24-45f3-bd6f-1e1c9eae084b', 'TEQUILAS.', 18, true
where not exists (
  select 1 from public.categories
  where business_id = 'f9128fc0-ae24-45f3-bd6f-1e1c9eae084b' and name = 'TEQUILAS.'
);
insert into public.categories (id, business_id, name, position, is_active)
select gen_random_uuid(), 'f9128fc0-ae24-45f3-bd6f-1e1c9eae084b', 'TRAGOS (COCTELES)', 19, true
where not exists (
  select 1 from public.categories
  where business_id = 'f9128fc0-ae24-45f3-bd6f-1e1c9eae084b' and name = 'TRAGOS (COCTELES)'
);
insert into public.categories (id, business_id, name, position, is_active)
select gen_random_uuid(), 'f9128fc0-ae24-45f3-bd6f-1e1c9eae084b', 'VINO ROSADO', 20, true
where not exists (
  select 1 from public.categories
  where business_id = 'f9128fc0-ae24-45f3-bd6f-1e1c9eae084b' and name = 'VINO ROSADO'
);
insert into public.categories (id, business_id, name, position, is_active)
select gen_random_uuid(), 'f9128fc0-ae24-45f3-bd6f-1e1c9eae084b', 'VINOS BLANCO', 21, true
where not exists (
  select 1 from public.categories
  where business_id = 'f9128fc0-ae24-45f3-bd6f-1e1c9eae084b' and name = 'VINOS BLANCO'
);
insert into public.categories (id, business_id, name, position, is_active)
select gen_random_uuid(), 'f9128fc0-ae24-45f3-bd6f-1e1c9eae084b', 'VINOS TINTO', 22, true
where not exists (
  select 1 from public.categories
  where business_id = 'f9128fc0-ae24-45f3-bd6f-1e1c9eae084b' and name = 'VINOS TINTO'
);
insert into public.categories (id, business_id, name, position, is_active)
select gen_random_uuid(), 'f9128fc0-ae24-45f3-bd6f-1e1c9eae084b', 'WHISKY', 23, true
where not exists (
  select 1 from public.categories
  where business_id = 'f9128fc0-ae24-45f3-bd6f-1e1c9eae084b' and name = 'WHISKY'
);
-- ----------------------------------------------------------------------------
-- 2) Productos
-- ----------------------------------------------------------------------------

do $$
declare
  v_business uuid := 'f9128fc0-ae24-45f3-bd6f-1e1c9eae084b';
  v_cat_00 uuid;
  v_cat_01 uuid;
  v_cat_02 uuid;
  v_cat_03 uuid;
  v_cat_04 uuid;
  v_cat_05 uuid;
  v_cat_06 uuid;
  v_cat_07 uuid;
  v_cat_08 uuid;
  v_cat_09 uuid;
  v_cat_10 uuid;
  v_cat_11 uuid;
  v_cat_12 uuid;
  v_cat_13 uuid;
  v_cat_14 uuid;
  v_cat_15 uuid;
  v_cat_16 uuid;
  v_cat_17 uuid;
  v_cat_18 uuid;
  v_cat_19 uuid;
  v_cat_20 uuid;
  v_cat_21 uuid;
  v_cat_22 uuid;
  v_cat_23 uuid;
begin
  select id into v_cat_00
    from public.categories
    where business_id = v_business and name = 'AGUAS, REFRESCO AGUAS T.' limit 1;
  select id into v_cat_01
    from public.categories
    where business_id = v_business and name = 'CAFFE Y CAPUCCINO' limit 1;
  select id into v_cat_02
    from public.categories
    where business_id = v_business and name = 'CARNES Y PESCADOS' limit 1;
  select id into v_cat_03
    from public.categories
    where business_id = v_business and name = 'CARTA DE VINO' limit 1;
  select id into v_cat_04
    from public.categories
    where business_id = v_business and name = 'CERVEZA' limit 1;
  select id into v_cat_05
    from public.categories
    where business_id = v_business and name = 'CHAMPAGNE' limit 1;
  select id into v_cat_06
    from public.categories
    where business_id = v_business and name = 'ENSALADA''S Y CARPACCIO''S' limit 1;
  select id into v_cat_07
    from public.categories
    where business_id = v_business and name = 'ENTRADAS' limit 1;
  select id into v_cat_08
    from public.categories
    where business_id = v_business and name = 'EXTRAS' limit 1;
  select id into v_cat_09
    from public.categories
    where business_id = v_business and name = 'GINEBRA' limit 1;
  select id into v_cat_10
    from public.categories
    where business_id = v_business and name = 'PASTA DE AUTORES' limit 1;
  select id into v_cat_11
    from public.categories
    where business_id = v_business and name = 'PASTA FRESCA HOME MADE' limit 1;
  select id into v_cat_12
    from public.categories
    where business_id = v_business and name = 'PASTAS' limit 1;
  select id into v_cat_13
    from public.categories
    where business_id = v_business and name = 'PIZZA''S ARTESANALES' limit 1;
  select id into v_cat_14
    from public.categories
    where business_id = v_business and name = 'POSTRE' limit 1;
  select id into v_cat_15
    from public.categories
    where business_id = v_business and name = 'PROSECCO Y  CAVA' limit 1;
  select id into v_cat_16
    from public.categories
    where business_id = v_business and name = 'RISOTTOS.' limit 1;
  select id into v_cat_17
    from public.categories
    where business_id = v_business and name = 'RONNES' limit 1;
  select id into v_cat_18
    from public.categories
    where business_id = v_business and name = 'TEQUILAS.' limit 1;
  select id into v_cat_19
    from public.categories
    where business_id = v_business and name = 'TRAGOS (COCTELES)' limit 1;
  select id into v_cat_20
    from public.categories
    where business_id = v_business and name = 'VINO ROSADO' limit 1;
  select id into v_cat_21
    from public.categories
    where business_id = v_business and name = 'VINOS BLANCO' limit 1;
  select id into v_cat_22
    from public.categories
    where business_id = v_business and name = 'VINOS TINTO' limit 1;
  select id into v_cat_23
    from public.categories
    where business_id = v_business and name = 'WHISKY' limit 1;

  -- ==========================================================================
  -- AGUAS, REFRESCO AGUAS T. (22 productos)
  -- ==========================================================================
  insert into public.menu_items (
    business_id, category_id, name, price, tax_mode,
    is_active, has_prep, position
  )
  select
    v_business, v_cat_00, n.name, n.price::numeric(12,2),
    'exclusive', true, true, n.pos
  from (values
    ('Agua natural', 85.00, 1),
    ('Agua tonica', 85.00, 2),
    ('Canada Dry Ginger', 100.00, 3),
    ('Clamato', 175.00, 4),
    ('Coca Cola 12ONZ', 85.00, 5),
    ('Coca Cola Cero', 110.00, 6),
    ('Enrriquillo', 85.00, 7),
    ('Jugo de chinola', 200.00, 8),
    ('Jugo de fresa', 250.00, 9),
    ('Jugo de limon', 180.00, 10),
    ('Jugo de naranja', 150.00, 11),
    ('Mickey Mouse', 150.00, 12),
    ('Panna 500ML', 175.00, 13),
    ('Perrier grande 750 ML', 300.00, 14),
    ('Perrier pequeña 200ML', 200.00, 15),
    ('San pellegrino grande 750ML', 300.00, 16),
    ('San pellegrino pequeña 250ML', 200.00, 17),
    ('Schweppes', 200.00, 18),
    ('Smothie chinola', 295.00, 19),
    ('Smothie fresa', 300.00, 20),
    ('Smothie limon', 270.00, 21),
    ('Sprite 12ONZ', 85.00, 22)
  ) as n(name, price, pos)
  where not exists (
    select 1 from public.menu_items mi
    where mi.business_id = v_business and mi.name = n.name
  );

  -- ==========================================================================
  -- CAFFE Y CAPUCCINO (4 productos)
  -- ==========================================================================
  insert into public.menu_items (
    business_id, category_id, name, price, tax_mode,
    is_active, has_prep, position
  )
  select
    v_business, v_cat_01, n.name, n.price::numeric(12,2),
    'exclusive', true, true, n.pos
  from (values
    ('Cappucino', 200.00, 23),
    ('Cortadito', 90.00, 24),
    ('Espresso', 75.00, 25),
    ('Mochaccino', 200.00, 26)
  ) as n(name, price, pos)
  where not exists (
    select 1 from public.menu_items mi
    where mi.business_id = v_business and mi.name = n.name
  );

  -- ==========================================================================
  -- CARNES Y PESCADOS (18 productos)
  -- ==========================================================================
  insert into public.menu_items (
    business_id, category_id, name, price, tax_mode,
    is_active, has_prep, position
  )
  select
    v_business, v_cat_02, n.name, n.price::numeric(12,2),
    'exclusive', true, true, n.pos
  from (values
    ('Bacalao a la puttanesca', 1250.00, 27),
    ('Calamar Salad Stuffed Scarola y Piñones', 745.00, 28),
    ('Camarones a la diabla; con mix verde', 1250.00, 29),
    ('Camarones termidor', 1450.00, 30),
    ('Chillo al gusto', 1150.00, 31),
    ('Escalopine Ternera al Marsala', 795.00, 32),
    ('Escalopine al Limon', 895.00, 33),
    ('Langosta Thermidor; Libra', 2000.00, 34),
    ('Langosta a la termidor', 1500.00, 35),
    ('Mariscada 1 persona', 1950.00, 36),
    ('Milanesa de pollo a la parmesana; papas fritas', 975.00, 37),
    ('Parrillada especial', 3500.00, 38),
    ('Pechuga de pollo a limon', 745.00, 39),
    ('Picadera verde del mar', 1500.00, 40),
    ('Salmon al Cartoccio', 1150.00, 41),
    ('Salmon en costra de pistacho salsa ciruela; Risotto parmesano', 1150.00, 42),
    ('Tenderloin res 5 pimientas; vegetales al grill', 1150.00, 43),
    ('Tenderloin select', 1550.00, 44)
  ) as n(name, price, pos)
  where not exists (
    select 1 from public.menu_items mi
    where mi.business_id = v_business and mi.name = n.name
  );

  -- ==========================================================================
  -- CARTA DE VINO (2 productos)
  -- ==========================================================================
  insert into public.menu_items (
    business_id, category_id, name, price, tax_mode,
    is_active, has_prep, position
  )
  select
    v_business, v_cat_03, n.name, n.price::numeric(12,2),
    'exclusive', true, true, n.pos
  from (values
    ('BERINGER W. ZINFANDEL', 1350.00, 45),
    ('Copa de vino', 350.00, 46)
  ) as n(name, price, pos)
  where not exists (
    select 1 from public.menu_items mi
    where mi.business_id = v_business and mi.name = n.name
  );

  -- ==========================================================================
  -- CERVEZA (12 productos)
  -- ==========================================================================
  insert into public.menu_items (
    business_id, category_id, name, price, tax_mode,
    is_active, has_prep, position
  )
  select
    v_business, v_cat_04, n.name, n.price::numeric(12,2),
    'exclusive', true, true, n.pos
  from (values
    ('Birra moretti', 245.31, 47),
    ('Blue moon', 270.84, 48),
    ('Corona', 250.00, 49),
    ('Heineken', 250.00, 50),
    ('Miller', 220.78, 51),
    ('Modelo especial', 250.00, 52),
    ('Modelo negra', 296.84, 53),
    ('Paulaner Wessbier', 343.44, 54),
    ('Peroni Nastro Azzurro', 295.00, 55),
    ('Presidente Ligth', 250.00, 56),
    ('Presidente normal', 250.00, 57),
    ('Stella Artois', 250.00, 58)
  ) as n(name, price, pos)
  where not exists (
    select 1 from public.menu_items mi
    where mi.business_id = v_business and mi.name = n.name
  );

  -- ==========================================================================
  -- CHAMPAGNE (2 productos)
  -- ==========================================================================
  insert into public.menu_items (
    business_id, category_id, name, price, tax_mode,
    is_active, has_prep, position
  )
  select
    v_business, v_cat_05, n.name, n.price::numeric(12,2),
    'exclusive', true, true, n.pos
  from (values
    ('Moet y Chandon', 5450.00, 59),
    ('Perrier Jovet', 5450.00, 60)
  ) as n(name, price, pos)
  where not exists (
    select 1 from public.menu_items mi
    where mi.business_id = v_business and mi.name = n.name
  );

  -- ==========================================================================
  -- ENSALADA'S Y CARPACCIO'S (9 productos)
  -- ==========================================================================
  insert into public.menu_items (
    business_id, category_id, name, price, tax_mode,
    is_active, has_prep, position
  )
  select
    v_business, v_cat_06, n.name, n.price::numeric(12,2),
    'exclusive', true, true, n.pos
  from (values
    ('Basquiat; Mix verde, camarones al gril, goat cheese, balsamico camarelizado', 695.00, 61),
    ('Capaccio de Salmon', 695.00, 62),
    ('Capresa', 525.00, 63),
    ('Carpaccio de Res', 625.00, 64),
    ('Cesar Camarones', 695.00, 65),
    ('Cesar Clasica', 525.00, 66),
    ('Cesar Pollo', 625.00, 67),
    ('Godiva; Rucula Prosciutto, Mozzarella y Parmesano en Lascas', 745.00, 68),
    ('Mixto verde', 525.00, 69)
  ) as n(name, price, pos)
  where not exists (
    select 1 from public.menu_items mi
    where mi.business_id = v_business and mi.name = n.name
  );

  -- ==========================================================================
  -- ENTRADAS (14 productos)
  -- ==========================================================================
  insert into public.menu_items (
    business_id, category_id, name, price, tax_mode,
    is_active, has_prep, position
  )
  select
    v_business, v_cat_07, n.name, n.price::numeric(12,2),
    'exclusive', true, true, n.pos
  from (values
    ('Albondigas de la Abuela', 575.00, 70),
    ('Arancini Siciliana', 545.00, 71),
    ('Baby Pulpo a la Luciana', 745.00, 72),
    ('Berengena a la Parmesana', 565.00, 73),
    ('Croqueta a la Carbonara S. 4 Quesos', 525.00, 74),
    ('Dip Espinaca', 545.00, 75),
    ('Fondue (Burrata, Rucula y Parmesano)', 950.00, 76),
    ('Mozzarella Stick', 595.00, 77),
    ('Polenta al Grill (Salchicha Italian S. 4 Quesos)', 595.00, 78),
    ('Salchicha al grill', 595.00, 79),
    ('Salchicha al vinotinto', 595.00, 80),
    ('Tabla de Embutido y queso Italiano', 1050.00, 81),
    ('Tasting menu Appetizzers', 745.00, 82),
    ('Trio Bruschetta con Burrata', 895.00, 83)
  ) as n(name, price, pos)
  where not exists (
    select 1 from public.menu_items mi
    where mi.business_id = v_business and mi.name = n.name
  );

  -- ==========================================================================
  -- EXTRAS (20 productos)
  -- ==========================================================================
  insert into public.menu_items (
    business_id, category_id, name, price, tax_mode,
    is_active, has_prep, position
  )
  select
    v_business, v_cat_08, n.name, n.price::numeric(12,2),
    'exclusive', true, true, n.pos
  from (values
    ('Burrata', 425.00, 84),
    ('Descorche', 500.00, 85),
    ('Extra camarones', 295.00, 86),
    ('Extra de maiz', 100.00, 87),
    ('Extra pan', 125.00, 88),
    ('Extra parmesano', 150.00, 89),
    ('Extra peperoni', 195.00, 90),
    ('Extra pollo', 175.00, 91),
    ('Extra prosciutto', 295.00, 92),
    ('Extra res', 525.00, 93),
    ('Extra salchicha', 250.00, 94),
    ('Extra salsa', 150.00, 95),
    ('Extra tocineta', 150.00, 96),
    ('Extracciatella', 200.00, 97),
    ('Langosta Libra', 1150.00, 98),
    ('Menú degustación', 1500.00, 99),
    ('Papas fritas', 200.00, 100),
    ('Salsa de hongos', 300.00, 101),
    ('Tomate', 120.00, 102),
    ('Vegetales', 250.00, 103)
  ) as n(name, price, pos)
  where not exists (
    select 1 from public.menu_items mi
    where mi.business_id = v_business and mi.name = n.name
  );

  -- ==========================================================================
  -- GINEBRA (6 productos)
  -- ==========================================================================
  insert into public.menu_items (
    business_id, category_id, name, price, tax_mode,
    is_active, has_prep, position
  )
  select
    v_business, v_cat_09, n.name, n.price::numeric(12,2),
    'exclusive', true, true, n.pos
  from (values
    ('Beefeater', 425.00, 104),
    ('Bombay', 400.00, 105),
    ('Botella Beefeater', 2200.00, 106),
    ('Botella Stolichaya', 1700.00, 107),
    ('Botella Tito Vodka', 2400.00, 108),
    ('Tanquerry', 425.00, 109)
  ) as n(name, price, pos)
  where not exists (
    select 1 from public.menu_items mi
    where mi.business_id = v_business and mi.name = n.name
  );

  -- ==========================================================================
  -- PASTA DE AUTORES (7 productos)
  -- ==========================================================================
  insert into public.menu_items (
    business_id, category_id, name, price, tax_mode,
    is_active, has_prep, position
  )
  select
    v_business, v_cat_10, n.name, n.price::numeric(12,2),
    'exclusive', true, true, n.pos
  from (values
    ('Espaguetis con Almejas', 795.00, 110),
    ('Linguini Eco del Mar', 1150.00, 111),
    ('Menú de Degustación', 1000.00, 112),
    ('Paccheri a la Campesina', 745.00, 113),
    ('Penne Condesa', 795.00, 114),
    ('Rigatoni Francescana', 795.00, 115),
    ('Tagliolini Frutos del Mar', 1300.00, 116)
  ) as n(name, price, pos)
  where not exists (
    select 1 from public.menu_items mi
    where mi.business_id = v_business and mi.name = n.name
  );

  -- ==========================================================================
  -- PASTA FRESCA HOME MADE (9 productos)
  -- ==========================================================================
  insert into public.menu_items (
    business_id, category_id, name, price, tax_mode,
    is_active, has_prep, position
  )
  select
    v_business, v_cat_11, n.name, n.price::numeric(12,2),
    'exclusive', true, true, n.pos
  from (values
    ('CASARECCE SALCHICHA Y PESTO', 725.00, 117),
    ('Canelones Ricota y Espinaca. (S. Albahaca)', 695.00, 118),
    ('Gnocchi 4 quesos', 745.00, 119),
    ('Gnocchi a la Sorrentina', 615.00, 120),
    ('Lasaña Napoletana', 695.00, 121),
    ('Ravioli 4 quesos Salsa Cacio y Pepe', 645.00, 122),
    ('Raviolis boloñesa, tomate fresco con burrata', 945.00, 123),
    ('TAGLIORINI PROSCIUTO Y HONGOS', 695.00, 124),
    ('Trio de pasta fresca', 695.00, 125)
  ) as n(name, price, pos)
  where not exists (
    select 1 from public.menu_items mi
    where mi.business_id = v_business and mi.name = n.name
  );

  -- ==========================================================================
  -- PASTAS (19 productos)
  -- ==========================================================================
  insert into public.menu_items (
    business_id, category_id, name, price, tax_mode,
    is_active, has_prep, position
  )
  select
    v_business, v_cat_12, n.name, n.price::numeric(12,2),
    'exclusive', true, true, n.pos
  from (values
    ('4 Quesos', 595.00, 126),
    ('4 quesos con camarones', 995.00, 127),
    ('4 quesos con pollo', 840.00, 128),
    ('4 quesos con tocineta', 800.00, 129),
    ('Aglio y olio', 595.00, 130),
    ('Amatriciana', 595.00, 131),
    ('Bologñesa', 595.00, 132),
    ('Camarones con tomate fresco', 925.00, 133),
    ('Carbonara Dominicana', 595.00, 134),
    ('Carbonara Italiana', 745.00, 135),
    ('Pasta Alfredo con pollo', 745.00, 136),
    ('Pasta al pesto', 595.00, 137),
    ('Pasta especial', 1000.00, 138),
    ('Pasta pomodoro', 595.00, 139),
    ('Puttanesca', 595.00, 140),
    ('Salsa blanca con camarones', 745.00, 141),
    ('Salsa blanca tocineta y pollo', 850.00, 142),
    ('TASTING MENU', 1250.00, 143),
    ('Tomate fresco', 595.00, 144)
  ) as n(name, price, pos)
  where not exists (
    select 1 from public.menu_items mi
    where mi.business_id = v_business and mi.name = n.name
  );

  -- ==========================================================================
  -- PIZZA'S ARTESANALES (26 productos)
  -- ==========================================================================
  insert into public.menu_items (
    business_id, category_id, name, price, tax_mode,
    is_active, has_prep, position
  )
  select
    v_business, v_cat_13, n.name, n.price::numeric(12,2),
    'exclusive', true, true, n.pos
  from (values
    ('4 Estaciones', 895.00, 145),
    ('BABY PIZZA', 300.00, 146),
    ('CROCCOPIZZA', 795.00, 147),
    ('Calzone', 825.00, 148),
    ('Capricciosa', 875.00, 149),
    ('Carnivora. (Mix de Carne)', 895.00, 150),
    ('DIABLITA', 745.00, 151),
    ('Faccia Rellena', 745.00, 152),
    ('Focaccia Mortadela Stracciatella y Pistacho', 845.00, 153),
    ('Focaccia al Romero', 475.00, 154),
    ('Jamon y Queso', 595.00, 155),
    ('Langosta y Camarones', 1150.00, 156),
    ('Ortolana', 725.00, 157),
    ('Pizza 4 Quesos', 725.00, 158),
    ('Pizza Carbonara', 695.00, 159),
    ('Pizza Maiz', 595.00, 160),
    ('Pizza Margherita', 545.00, 161),
    ('Pizza Nutella', 695.00, 162),
    ('Pizza Pepperoni', 595.00, 163),
    ('Prosciutto y Rucula', 895.00, 164),
    ('Ricotta y Boloñesa', 895.00, 165),
    ('Salchicha y Hongos', 725.00, 166),
    ('Sorrentina', 745.00, 167),
    ('Tomate Cherry Burrata', 845.00, 168),
    ('Tuna y Cebolla', 695.00, 169),
    ('Vegetariana', 695.00, 170)
  ) as n(name, price, pos)
  where not exists (
    select 1 from public.menu_items mi
    where mi.business_id = v_business and mi.name = n.name
  );

  -- ==========================================================================
  -- POSTRE (4 productos)
  -- ==========================================================================
  insert into public.menu_items (
    business_id, category_id, name, price, tax_mode,
    is_active, has_prep, position
  )
  select
    v_business, v_cat_14, n.name, n.price::numeric(12,2),
    'exclusive', true, true, n.pos
  from (values
    ('BOLA DE HELADO', 150.00, 171),
    ('POSTRE', 500.00, 172),
    ('TARTA DE MANZANA', 425.00, 173),
    ('chocolate y almendras', 425.00, 174)
  ) as n(name, price, pos)
  where not exists (
    select 1 from public.menu_items mi
    where mi.business_id = v_business and mi.name = n.name
  );

  -- ==========================================================================
  -- PROSECCO Y  CAVA (3 productos)
  -- ==========================================================================
  insert into public.menu_items (
    business_id, category_id, name, price, tax_mode,
    is_active, has_prep, position
  )
  select
    v_business, v_cat_15, n.name, n.price::numeric(12,2),
    'exclusive', true, true, n.pos
  from (values
    ('Maschio Prosecco', 1850.00, 175),
    ('Maschio Rose', 1850.00, 176),
    ('Segura Viudas Brut Reserva', 1950.00, 177)
  ) as n(name, price, pos)
  where not exists (
    select 1 from public.menu_items mi
    where mi.business_id = v_business and mi.name = n.name
  );

  -- ==========================================================================
  -- RISOTTOS. (14 productos)
  -- ==========================================================================
  insert into public.menu_items (
    business_id, category_id, name, price, tax_mode,
    is_active, has_prep, position
  )
  select
    v_business, v_cat_16, n.name, n.price::numeric(12,2),
    'exclusive', true, true, n.pos
  from (values
    ('RIsotto del Cheff', 1280.00, 178),
    ('Risoto camarones y peticua', 940.00, 179),
    ('Risoto pesto pistacho y Tenderloin', 1095.00, 180),
    ('Risotto  Mr. Jose Ginebra', 1000.00, 181),
    ('Risotto Capresa', 625.00, 182),
    ('Risotto Carbonara', 645.00, 183),
    ('Risotto Porcini', 725.00, 184),
    ('Risotto al Pesto', 675.00, 185),
    ('Risotto al Vinotinto', 795.00, 186),
    ('Risotto de Aullama', 715.00, 187),
    ('Risotto de Pistacho y Proscciutto', 795.00, 188),
    ('Risotto parmesano', 625.00, 189),
    ('Risotto pesto de pistacho', 695.00, 190),
    ('Rissotto Ossobuco', 945.00, 191)
  ) as n(name, price, pos)
  where not exists (
    select 1 from public.menu_items mi
    where mi.business_id = v_business and mi.name = n.name
  );

  -- ==========================================================================
  -- RONNES (5 productos)
  -- ==========================================================================
  insert into public.menu_items (
    business_id, category_id, name, price, tax_mode,
    is_active, has_prep, position
  )
  select
    v_business, v_cat_17, n.name, n.price::numeric(12,2),
    'exclusive', true, true, n.pos
  from (values
    ('Botella Brugal Leyenda', 2500.00, 192),
    ('Botella Brugal doble reserva', 1900.00, 193),
    ('Brugal Leyenda', 300.00, 194),
    ('Brugal doble reserva', 300.00, 195),
    ('Brugal extra viejo', 250.00, 196)
  ) as n(name, price, pos)
  where not exists (
    select 1 from public.menu_items mi
    where mi.business_id = v_business and mi.name = n.name
  );

  -- ==========================================================================
  -- TEQUILAS. (3 productos)
  -- ==========================================================================
  insert into public.menu_items (
    business_id, category_id, name, price, tax_mode,
    is_active, has_prep, position
  )
  select
    v_business, v_cat_18, n.name, n.price::numeric(12,2),
    'exclusive', true, true, n.pos
  from (values
    ('Botella Vodka Tito', 3250.00, 197),
    ('Don Julio reposado', 546.87, 198),
    ('Patron', 400.00, 199)
  ) as n(name, price, pos)
  where not exists (
    select 1 from public.menu_items mi
    where mi.business_id = v_business and mi.name = n.name
  );

  -- ==========================================================================
  -- TRAGOS (COCTELES) (26 productos)
  -- ==========================================================================
  insert into public.menu_items (
    business_id, category_id, name, price, tax_mode,
    is_active, has_prep, position
  )
  select
    v_business, v_cat_19, n.name, n.price::numeric(12,2),
    'exclusive', true, true, n.pos
  from (values
    ('Amaro del Capo', 400.00, 200),
    ('Aperol Spritz', 435.00, 201),
    ('Brandy Cardenal Mendoza', 400.00, 202),
    ('Caipiriña', 470.00, 203),
    ('Campari', 350.00, 204),
    ('Cointreau', 400.00, 205),
    ('Cosmopolitan', 435.00, 206),
    ('Cuba Libre', 280.00, 207),
    ('Daikiri', 375.00, 208),
    ('Digestivo', 400.00, 209),
    ('Gintonic', 435.00, 210),
    ('Limoncello', 400.00, 211),
    ('Martini Rosso Vermouth rojo', 345.00, 212),
    ('Mojito', 375.00, 213),
    ('Moscow Mule', 405.00, 214),
    ('Negroni', 530.00, 215),
    ('Piña Colada', 345.00, 216),
    ('Sambuca', 200.00, 217),
    ('Sangria', 425.00, 218),
    ('Santo Libre', 280.00, 219),
    ('Stolichaya', 345.00, 220),
    ('Tequila Sour', 435.00, 221),
    ('Tequila Sunrise', 375.00, 222),
    ('Trago de Margarita', 470.00, 223),
    ('Vodka Sour', 405.00, 224),
    ('Vodka Tonic', 345.00, 225)
  ) as n(name, price, pos)
  where not exists (
    select 1 from public.menu_items mi
    where mi.business_id = v_business and mi.name = n.name
  );

  -- ==========================================================================
  -- VINO ROSADO (2 productos)
  -- ==========================================================================
  insert into public.menu_items (
    business_id, category_id, name, price, tax_mode,
    is_active, has_prep, position
  )
  select
    v_business, v_cat_20, n.name, n.price::numeric(12,2),
    'exclusive', true, true, n.pos
  from (values
    ('BOGLE WHE ZINFANDEL', 1060.00, 226),
    ('DOGLE  ESENTIAL RED', 1615.00, 227)
  ) as n(name, price, pos)
  where not exists (
    select 1 from public.menu_items mi
    where mi.business_id = v_business and mi.name = n.name
  );

  -- ==========================================================================
  -- VINOS BLANCO (7 productos)
  -- ==========================================================================
  insert into public.menu_items (
    business_id, category_id, name, price, tax_mode,
    is_active, has_prep, position
  )
  select
    v_business, v_cat_21, n.name, n.price::numeric(12,2),
    'exclusive', true, true, n.pos
  from (values
    ('Marques de Riscal', 1850.00, 228),
    ('Martin Codax Albariño', 2190.00, 229),
    ('Piccini Pinot Grigio', 1395.00, 230),
    ('Pinot Grigio Delle Venezie', 1550.00, 231),
    ('Riporta Pinot Grigio', 1750.00, 232),
    ('Santa Margherita', 2400.00, 233),
    ('Woodbridge Sauvigñon', 1390.00, 234)
  ) as n(name, price, pos)
  where not exists (
    select 1 from public.menu_items mi
    where mi.business_id = v_business and mi.name = n.name
  );

  -- ==========================================================================
  -- VINOS TINTO (18 productos)
  -- ==========================================================================
  insert into public.menu_items (
    business_id, category_id, name, price, tax_mode,
    is_active, has_prep, position
  )
  select
    v_business, v_cat_22, n.name, n.price::numeric(12,2),
    'exclusive', true, true, n.pos
  from (values
    ('19 Crimenes Red Wine', 2300.00, 235),
    ('689', 2390.00, 236),
    ('Argiano Toscana', 2000.00, 237),
    ('Arzuaga la Planta', 1950.00, 238),
    ('Bogle Esential Red', 2400.00, 239),
    ('Carmelo Rodero', 2400.00, 240),
    ('Catena Malbec', 2490.00, 241),
    ('Chianti Piccini', 1590.00, 242),
    ('Cune Crianza', 1850.00, 243),
    ('Izadi Reserva', 1730.00, 244),
    ('Lopez de Haro', 1950.00, 245),
    ('Protos 9 Meses', 1950.00, 246),
    ('Riporta Primitivo', 1750.00, 247),
    ('Robert Mondavi', 1980.00, 248),
    ('Ruffino Chianti', 1950.00, 249),
    ('The Prisoner', 8500.00, 250),
    ('Woodbridge Red Blend', 1315.00, 251),
    ('Zaccagnini Montepulciano', 2100.00, 252)
  ) as n(name, price, pos)
  where not exists (
    select 1 from public.menu_items mi
    where mi.business_id = v_business and mi.name = n.name
  );

  -- ==========================================================================
  -- WHISKY (9 productos)
  -- ==========================================================================
  insert into public.menu_items (
    business_id, category_id, name, price, tax_mode,
    is_active, has_prep, position
  )
  select
    v_business, v_cat_23, n.name, n.price::numeric(12,2),
    'exclusive', true, true, n.pos
  from (values
    ('Botella Jhonny Walker', 4500.00, 253),
    ('Buchanan 12', 500.00, 254),
    ('Buchanan 18', 850.00, 255),
    ('Chivas 12', 500.00, 256),
    ('Chivas 18', 700.00, 257),
    ('Hennessy', 740.00, 258),
    ('Jack Daniels', 500.00, 259),
    ('Jhonny Walker 12', 500.00, 260),
    ('Jhonny Walker 18', 700.00, 261)
  ) as n(name, price, pos)
  where not exists (
    select 1 from public.menu_items mi
    where mi.business_id = v_business and mi.name = n.name
  );

end $$;

commit;
