-- ============================================================================
-- Seed de productos: Hailey's Moncion
-- Business: e405ac62-9ecf-4e81-a6ca-e1b45b191e92
-- Fuente: MENU HAILEYS 2026.pdf (Smash Burgers, Hailey's Sides, Signature)
-- ============================================================================
--
-- Idempotente:
--   - Categorías: se crean sólo si no existen para este business.
--   - Productos: se insertan sólo si no hay un menu_item con el mismo
--     nombre en este business. Re-ejecutar el script no duplica.
--
-- Categorías cargadas:
--   1. Smash Burgers   → Hamburguesas (papas fritas incluidas)
--   2. Hailey's Sides  → Acompañantes (croquetas, papas, aros, etc.)
--   3. Signature       → Platos estrella (Porky Fries, Chili Fries, Quesadilla)
--
-- Precios:
--   - Todos los precios son INCLUSIVOS de ITBIS (tax_mode = 'inclusive')
--     porque el menú físico ya muestra el precio final al cliente.
--     Si el negocio cobra ITBIS sobre el precio, cambiar a 'exclusive'.
--   - El único item con price = 0 es Atomic (sin precio confirmado).
--     El POS lo listará pero NO permitirá cobrarlo a $0 — el dueño
--     debe actualizarlo vía la UI antes de venderlo.
-- ============================================================================

begin;

-- ----------------------------------------------------------------------------
-- 1) Categorías
-- ----------------------------------------------------------------------------

insert into public.categories (id, business_id, name, position, is_active)
select gen_random_uuid(),
       'e405ac62-9ecf-4e81-a6ca-e1b45b191e92',
       'Smash Burgers', 0, true
where not exists (
  select 1 from public.categories
  where business_id = 'e405ac62-9ecf-4e81-a6ca-e1b45b191e92'
    and name = 'Smash Burgers'
);

insert into public.categories (id, business_id, name, position, is_active)
select gen_random_uuid(),
       'e405ac62-9ecf-4e81-a6ca-e1b45b191e92',
       'Hailey''s Sides', 1, true
where not exists (
  select 1 from public.categories
  where business_id = 'e405ac62-9ecf-4e81-a6ca-e1b45b191e92'
    and name = 'Hailey''s Sides'
);

insert into public.categories (id, business_id, name, position, is_active)
select gen_random_uuid(),
       'e405ac62-9ecf-4e81-a6ca-e1b45b191e92',
       'Signature', 2, true
where not exists (
  select 1 from public.categories
  where business_id = 'e405ac62-9ecf-4e81-a6ca-e1b45b191e92'
    and name = 'Signature'
);

-- ----------------------------------------------------------------------------
-- 2) Productos
-- ----------------------------------------------------------------------------

do $$
declare
  v_business uuid := 'e405ac62-9ecf-4e81-a6ca-e1b45b191e92';
  v_cat_burgers   uuid;
  v_cat_sides     uuid;
  v_cat_signature uuid;
begin
  select id into v_cat_burgers
    from public.categories
    where business_id = v_business and name = 'Smash Burgers' limit 1;
  select id into v_cat_sides
    from public.categories
    where business_id = v_business and name = 'Hailey''s Sides' limit 1;
  select id into v_cat_signature
    from public.categories
    where business_id = v_business and name = 'Signature' limit 1;

  -- ========================================================================
  -- SMASH BURGERS  (papas fritas incluidas)
  -- ========================================================================
  insert into public.menu_items (
    business_id, category_id, name, price, tax_mode,
    is_active, has_prep, position, description
  )
  select v_business, v_cat_burgers, n.name, n.price::numeric(12,2),
         'inclusive', true, true, n.pos, n.descr
  from (values
    ('Hailey''s Burger',     300, 1,
      'Carne angus + queso americano + alioli Hailey''s + pan brioche.'),
    ('Verano Sin Bacon',     600, 2,
      'Doble carne angus + doble queso americano + 4 tiras crujientes de tocineta + alioli honey + pan brioche.'),
    ('La Jam',               600, 3,
      'Doble carne angus + doble queso americano + mermelada de tocineta + alioli rosada + pan brioche.'),
    ('La Audi',              600, 4,
      'Doble carne angus + triple queso americano + tocineta + aros de cebolla + alioli rosada + pan brioche.'),
    ('¿Cuándo y Dónde?',     450, 5,
      'Doble carne angus + doble queso americano + lechuga + cebolla + alioli rosada + pan brioche.'),
    ('3 Dragones',           500, 6,
      'Triple carne angus + triple queso americano + alioli Hailey''s + pan brioche.'),
    ('La 4x4',               750, 7,
      'Cuatro carne angus + cuatro queso americano + cebolla + pepinillo + alioli rosada + alioli verde + pan brioche.'),
    ('La Serrana',           550, 8,
      'Doble carne angus + queso blanco empanizado + queso americano + alioli rosada + cebolla + pepinillo + pan brioche.'),
    ('La Matias',            650, 9,
      'Smash sumergida en salsa de queso de la casa + doble carne angus + doble queso americano + tocineta + papas fritas junto a la salsa de queso.'),
    ('Joker',                550, 10,
      'Doble carne angus + doble queso americano + alioli de ajo rostizado + cebolla smasheada junto a la carne + pan brioche.'),
    ('Atomic',                 0, 11,
      'Doble carne angus + doble queso americano + spicy mayo + pan brioche.'),
    ('La Inolvidable',       450, 12,
      'Carne angus + doble queso americano + cebolla + pepinillo + ketchup + mostaza + pan brioche.'),
    ('La MVP',               700, 13,
      'Triple carne angus + triple queso americano + mermelada de tocineta + salsa Emmy (especial del chef).')
  ) as n(name, price, pos, descr)
  where not exists (
    select 1 from public.menu_items mi
    where mi.business_id = v_business and mi.name = n.name
  );

  -- ========================================================================
  -- HAILEY'S SIDES
  -- ========================================================================
  insert into public.menu_items (
    business_id, category_id, name, price, tax_mode,
    is_active, has_prep, position, description
  )
  select v_business, v_cat_sides, n.name, n.price::numeric(12,2),
         'inclusive', true, true, n.pos, n.descr
  from (values
    ('Mozzarella Sticks',    200, 14,
      '5 unidades de mozzarella con salsa especial de la casa.'),
    ('Croquetas de Maduro',  250, 15,
      '4 unidades de croquetas de plátano maduro rellenas de queso y tocineta.'),
    ('Croquetas de Pollo',   250, 16,
      '4 unidades de croquetas rellenas de pollo.'),
    ('Aros de Cebolla',      100, 17,
      'Crujientes aros de cebolla al estilo Hailey''s.'),
    ('Papas Fritas',         200, 18,
      'Nuestras deliciosas y crujientes papas fritas.')
  ) as n(name, price, pos, descr)
  where not exists (
    select 1 from public.menu_items mi
    where mi.business_id = v_business and mi.name = n.name
  );

  -- ========================================================================
  -- SIGNATURE PLATES
  -- ========================================================================
  insert into public.menu_items (
    business_id, category_id, name, price, tax_mode,
    is_active, has_prep, position, description
  )
  select v_business, v_cat_signature, n.name, n.price::numeric(12,2),
         'inclusive', true, true, n.pos, n.descr
  from (values
    ('Porky Fries',          400, 19,
      'Deliciosas papas fritas crujientes con cerdo desmenuzado, alioli verde y cebolla.'),
    ('Chili Fries',          400, 20,
      'Papas fritas crujientes + queso americano + chilis de la casa + alioli ajo rostizado + alioli rosada.'),
    ('Quesadilla de Buelin', 300, 21,
      'Pollo desmenuzado + mix de 4 quesos (cheddar, monterey jack, asadero y mozzarella). Acompaña con guacamole por RD$ 50.')
  ) as n(name, price, pos, descr)
  where not exists (
    select 1 from public.menu_items mi
    where mi.business_id = v_business and mi.name = n.name
  );

end $$;

commit;
