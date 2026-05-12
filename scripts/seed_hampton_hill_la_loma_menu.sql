-- ============================================================================
-- Seed de productos: Hampton Hill La Loma
-- Business: 020320c7-275b-45f4-801f-ebc81ed4732d
-- ============================================================================
--
-- Carga el menú físico al sistema:
--   - Comida (Entrada, Carnes, Guarniciones, Pizza, Hamburger, Combos)
--     → categoría "Entrada"
--   - Bebidas (Bebidas, Drink, Tragos)
--     → categoría "Bebidas", flag is_beverage=true
--
-- Todos los precios son INCLUSIVOS de ITBIS (tax_mode = 'inclusive'),
-- es decir: el precio mostrado al cliente ya incluye el impuesto.
--
-- Idempotente:
--   - Categorías: se crean sólo si no existen para este business.
--   - Productos: se insertan sólo si no hay un menu_item con el mismo
--     nombre en este business. Re-ejecutar el script no duplica items.
--
-- Productos sin precio publicado en el menú físico (la sección DRINK
-- premium, TRAGOS y GUARNICIONES) se cargan con price = 0 para que el
-- dueño los actualice via la UI. Esto evita que aparezcan como vendibles
-- a precio cero por accidente — el POS los listará pero requerirá
-- actualización antes de cobrar.
-- ============================================================================

begin;

-- ----------------------------------------------------------------------------
-- 1) Categorías
-- ----------------------------------------------------------------------------

insert into public.categories (id, business_id, name, position, is_active)
select
  gen_random_uuid(),
  '020320c7-275b-45f4-801f-ebc81ed4732d',
  'Entrada',
  0,
  true
where not exists (
  select 1 from public.categories
  where business_id = '020320c7-275b-45f4-801f-ebc81ed4732d'
    and name = 'Entrada'
);

insert into public.categories (id, business_id, name, position, is_active)
select
  gen_random_uuid(),
  '020320c7-275b-45f4-801f-ebc81ed4732d',
  'Bebidas',
  1,
  true
where not exists (
  select 1 from public.categories
  where business_id = '020320c7-275b-45f4-801f-ebc81ed4732d'
    and name = 'Bebidas'
);

-- ----------------------------------------------------------------------------
-- 2) Productos
-- ----------------------------------------------------------------------------

do $$
declare
  v_business uuid := '020320c7-275b-45f4-801f-ebc81ed4732d';
  v_cat_entrada uuid;
  v_cat_bebidas uuid;
begin
  select id into v_cat_entrada
    from public.categories
    where business_id = v_business and name = 'Entrada'
    limit 1;
  select id into v_cat_bebidas
    from public.categories
    where business_id = v_business and name = 'Bebidas'
    limit 1;

  -- ==========================================================================
  -- COMIDA → categoría Entrada
  -- ==========================================================================
  insert into public.menu_items (
    business_id, category_id, name, price, tax_mode,
    is_active, is_beverage, position
  )
  select
    v_business,
    v_cat_entrada,
    n.name,
    n.price::numeric(12, 2),
    'inclusive',
    true,
    false,
    n.pos
  from (values
    -- ENTRADA
    ('Alitas Picantes',          400, 1),
    ('Croquetas de Pollo',       300, 2),
    -- CARNES
    ('Pechuga al Grill',         600, 3),
    ('Carne Salada',             300, 4),
    ('Costillita a la BBQ',      700, 5),
    ('Pechurrinas',              400, 6),
    -- GUARNICIONES (sin precio en menú físico)
    ('Papas Fritas',               0, 7),
    ('Tostones',                   0, 8),
    -- PIZZA
    ('Pizza Jamón y Queso',      700, 9),
    ('Pizza Pollo y Vegetales',  900, 10),
    ('Pizza Pepperoni y Queso',  700, 11),
    ('Pizza Queso y Maíz',       700, 12),
    ('Pizza Pollo y Queso',      700, 13),
    -- HAMBURGER
    ('Cheeseburger con Bacon',   600, 14),
    ('Cheeseburger',             500, 15),
    -- COMBOS (typo del menú original: tenía dos "Combo 1"; renombro la
    --         bandeja grande a "Combo 3" para evitar la colisión)
    ('Combo 1 - Bandeja Pequeña',  700, 16),
    ('Combo 2 - Bandeja Mediana', 1000, 17),
    ('Combo 3 - Bandeja Grande',  1500, 18)
  ) as n(name, price, pos)
  where not exists (
    select 1 from public.menu_items mi
    where mi.business_id = v_business and mi.name = n.name
  );

  -- ==========================================================================
  -- BEBIDAS → categoría Bebidas, is_beverage = true
  -- ==========================================================================
  insert into public.menu_items (
    business_id, category_id, name, price, tax_mode,
    is_active, is_beverage, position
  )
  select
    v_business,
    v_cat_bebidas,
    n.name,
    n.price::numeric(12, 2),
    'inclusive',
    true,
    true,
    n.pos
  from (values
    -- BEBIDAS (sección con precios)
    ('Agua',                          30, 1),
    ('Refresco Pequeño',              50, 2),
    ('Refresco Big Leaguer',         150, 3),
    ('Jugos Naturales',              100, 4),
    ('Limonada Frozen',              150, 5),
    ('Cerveza Presidente Pequeña',   200, 6),
    ('Cerveza Presidente Grande',    250, 7),
    ('Corona',                       200, 8),
    ('Estela',                       200, 9),
    ('Modelo Rubia',                 200, 10),
    ('Ciclón',                       150, 11),
    ('911',                          150, 12),
    ('Red Bull',                     150, 13),
    ('Gatorade',                     125, 14),
    ('Jugo Mots',                    300, 15),
    ('Jugo Rica Grande',             250, 16),
    ('Cerveza Smirnoff',             250, 17),
    ('Agua Perrier',                 100, 18),
    ('Copa de Maní',                 150, 19),
    -- DRINK (premium, sin precio publicado)
    ('Brugal Extra Viejo',             0, 20),
    ('Brugal Blanco',                  0, 21),
    ('Brugal Leyenda',                 0, 22),
    ('Brugal XB',                      0, 23),
    ('Barceló Imperial',               0, 24),
    ('Barceló Gran Añejo',             0, 25),
    ('Barceló Blanco',                 0, 26),
    ('Buchanans',                      0, 27),
    ('Jhonny Gold',                    0, 28),
    ('Jhonny Negro',                   0, 29),
    ('Jhonny Doble Black',             0, 30),
    ('Dewars 12 Años',                 0, 31),
    ('Chiva 12 Años',                  0, 32),
    ('Vino Carlos Rossi Negro',        0, 33),
    ('Vino Carlos Rossi Rosado',       0, 34),
    ('Vino Casiller del Diablo',       0, 35),
    ('Tequila Don Julio',              0, 36),
    ('Tequila Patrón Silver',          0, 37),
    ('Tequila Patrón Café',            0, 38),
    ('Old Park',                       0, 39),
    ('Fireball',                       0, 40),
    -- TRAGOS (sin precio publicado). "Jhonny Doble Black" y "Barceló"
    -- ya aparecen arriba como botellas; aquí van los preparados.
    ('Piña Colada',                    0, 41),
    ('Margarita',                      0, 42),
    ('Mojito',                         0, 43),
    ('Cuba Libre',                     0, 44),
    ('Trago Vodka',                    0, 45),
    ('Trago Brugal',                   0, 46),
    ('Shot de Tequila',                0, 47)
  ) as n(name, price, pos)
  where not exists (
    select 1 from public.menu_items mi
    where mi.business_id = v_business and mi.name = n.name
  );

end$$;

commit;

-- ============================================================================
-- Verificación (opcional, comentar/descomentar según necesites)
-- ============================================================================
-- select c.name as categoria, count(mi.id) as items, sum(mi.price) as suma_precios
-- from public.categories c
-- left join public.menu_items mi
--   on mi.business_id = c.business_id and mi.category_id = c.id
-- where c.business_id = '020320c7-275b-45f4-801f-ebc81ed4732d'
-- group by c.name
-- order by c.position;
