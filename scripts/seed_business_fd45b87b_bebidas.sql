-- ============================================================================
-- Seed de bebidas (cervezas, licores, vinos, champagnes)
-- Business: fd45b87b-3a41-4540-a107-5b1c186e817f
-- ============================================================================
--
-- 34 productos en 9 categorías. Mismo patrón que seed_business_f9128fc0_menu.sql.
--
-- Idempotente:
--   - Categorías: se crean sólo si no existen para este business.
--   - Productos: se insertan sólo si no hay un menu_item con el mismo
--     nombre en este business. Re-ejecutar el script no duplica items.
--
-- Defaults aplicados:
--   - tax_mode = 'exclusive'  → precios NO incluyen ITBIS. Si ya están
--     con ITBIS incluido, cambiar a 'inclusive' antes de correr.
--   - has_prep = true         → se imprimen tickets al bar (típico para
--     bebidas alcohólicas con printer area de bar configurada).
--   - is_active = true        → visibles en POS desde el inicio.
--   - sin tracking de inventario → activar por producto desde el form
--     cuando configures bodega/receta.
-- ============================================================================

begin;

-- ----------------------------------------------------------------------------
-- 1) Categorías
-- ----------------------------------------------------------------------------
insert into public.categories (id, business_id, name, position, is_active)
select gen_random_uuid(), 'fd45b87b-3a41-4540-a107-5b1c186e817f', 'CERVEZA', 0, true
where not exists (
  select 1 from public.categories
  where business_id = 'fd45b87b-3a41-4540-a107-5b1c186e817f' and name = 'CERVEZA'
);
insert into public.categories (id, business_id, name, position, is_active)
select gen_random_uuid(), 'fd45b87b-3a41-4540-a107-5b1c186e817f', 'COCTELES', 1, true
where not exists (
  select 1 from public.categories
  where business_id = 'fd45b87b-3a41-4540-a107-5b1c186e817f' and name = 'COCTELES'
);
insert into public.categories (id, business_id, name, position, is_active)
select gen_random_uuid(), 'fd45b87b-3a41-4540-a107-5b1c186e817f', 'RON', 2, true
where not exists (
  select 1 from public.categories
  where business_id = 'fd45b87b-3a41-4540-a107-5b1c186e817f' and name = 'RON'
);
insert into public.categories (id, business_id, name, position, is_active)
select gen_random_uuid(), 'fd45b87b-3a41-4540-a107-5b1c186e817f', 'WHISKY', 3, true
where not exists (
  select 1 from public.categories
  where business_id = 'fd45b87b-3a41-4540-a107-5b1c186e817f' and name = 'WHISKY'
);
insert into public.categories (id, business_id, name, position, is_active)
select gen_random_uuid(), 'fd45b87b-3a41-4540-a107-5b1c186e817f', 'TEQUILA', 4, true
where not exists (
  select 1 from public.categories
  where business_id = 'fd45b87b-3a41-4540-a107-5b1c186e817f' and name = 'TEQUILA'
);
insert into public.categories (id, business_id, name, position, is_active)
select gen_random_uuid(), 'fd45b87b-3a41-4540-a107-5b1c186e817f', 'VODKA', 5, true
where not exists (
  select 1 from public.categories
  where business_id = 'fd45b87b-3a41-4540-a107-5b1c186e817f' and name = 'VODKA'
);
insert into public.categories (id, business_id, name, position, is_active)
select gen_random_uuid(), 'fd45b87b-3a41-4540-a107-5b1c186e817f', 'COGNAC', 6, true
where not exists (
  select 1 from public.categories
  where business_id = 'fd45b87b-3a41-4540-a107-5b1c186e817f' and name = 'COGNAC'
);
insert into public.categories (id, business_id, name, position, is_active)
select gen_random_uuid(), 'fd45b87b-3a41-4540-a107-5b1c186e817f', 'CHAMPAGNE', 7, true
where not exists (
  select 1 from public.categories
  where business_id = 'fd45b87b-3a41-4540-a107-5b1c186e817f' and name = 'CHAMPAGNE'
);
insert into public.categories (id, business_id, name, position, is_active)
select gen_random_uuid(), 'fd45b87b-3a41-4540-a107-5b1c186e817f', 'VINO TINTO', 8, true
where not exists (
  select 1 from public.categories
  where business_id = 'fd45b87b-3a41-4540-a107-5b1c186e817f' and name = 'VINO TINTO'
);

-- ----------------------------------------------------------------------------
-- 2) Productos
-- ----------------------------------------------------------------------------

do $$
declare
  v_business uuid := 'fd45b87b-3a41-4540-a107-5b1c186e817f';
  v_cat_cerveza   uuid;
  v_cat_cocteles  uuid;
  v_cat_ron       uuid;
  v_cat_whisky    uuid;
  v_cat_tequila   uuid;
  v_cat_vodka     uuid;
  v_cat_cognac    uuid;
  v_cat_champagne uuid;
  v_cat_vino      uuid;
begin
  select id into v_cat_cerveza
    from public.categories where business_id = v_business and name = 'CERVEZA' limit 1;
  select id into v_cat_cocteles
    from public.categories where business_id = v_business and name = 'COCTELES' limit 1;
  select id into v_cat_ron
    from public.categories where business_id = v_business and name = 'RON' limit 1;
  select id into v_cat_whisky
    from public.categories where business_id = v_business and name = 'WHISKY' limit 1;
  select id into v_cat_tequila
    from public.categories where business_id = v_business and name = 'TEQUILA' limit 1;
  select id into v_cat_vodka
    from public.categories where business_id = v_business and name = 'VODKA' limit 1;
  select id into v_cat_cognac
    from public.categories where business_id = v_business and name = 'COGNAC' limit 1;
  select id into v_cat_champagne
    from public.categories where business_id = v_business and name = 'CHAMPAGNE' limit 1;
  select id into v_cat_vino
    from public.categories where business_id = v_business and name = 'VINO TINTO' limit 1;

  -- ==========================================================================
  -- CERVEZA (8 productos)
  -- ==========================================================================
  insert into public.menu_items (
    business_id, category_id, name, price, tax_mode,
    is_active, has_prep, position
  )
  select
    v_business, v_cat_cerveza, n.name, n.price::numeric(12,2),
    'exclusive', true, true, n.pos
  from (values
    ('Cerveza Presidente Pequeña', 200.00, 0),
    ('Cerveza Corona', 250.00, 1),
    ('Cerveza Smirnoff', 300.00, 2),
    ('Cerveza Modelo', 250.00, 3),
    ('Cerveza Heineken', 250.00, 4),
    ('Cerveza Miller', 250.00, 5),
    ('Cerveza One Pequeña', 150.00, 6),
    ('Cerveza Paulaner', 350.00, 7)
  ) as n(name, price, pos)
  where not exists (
    select 1 from public.menu_items mi
    where mi.business_id = v_business and mi.name = n.name
  );

  -- ==========================================================================
  -- COCTELES (2 productos)
  -- ==========================================================================
  insert into public.menu_items (
    business_id, category_id, name, price, tax_mode,
    is_active, has_prep, position
  )
  select
    v_business, v_cat_cocteles, n.name, n.price::numeric(12,2),
    'exclusive', true, true, n.pos
  from (values
    ('Buzzball Cocktail', 400.00, 8),
    ('Four Loko Cocktail', 400.00, 9)
  ) as n(name, price, pos)
  where not exists (
    select 1 from public.menu_items mi
    where mi.business_id = v_business and mi.name = n.name
  );

  -- ==========================================================================
  -- RON (1 producto)
  -- ==========================================================================
  insert into public.menu_items (
    business_id, category_id, name, price, tax_mode,
    is_active, has_prep, position
  )
  select
    v_business, v_cat_ron, n.name, n.price::numeric(12,2),
    'exclusive', true, true, n.pos
  from (values
    ('Brugal Doble Reserva', 2000.00, 10)
  ) as n(name, price, pos)
  where not exists (
    select 1 from public.menu_items mi
    where mi.business_id = v_business and mi.name = n.name
  );

  -- ==========================================================================
  -- WHISKY (10 productos)
  -- ==========================================================================
  insert into public.menu_items (
    business_id, category_id, name, price, tax_mode,
    is_active, has_prep, position
  )
  select
    v_business, v_cat_whisky, n.name, n.price::numeric(12,2),
    'exclusive', true, true, n.pos
  from (values
    ('Old Parr 12 Años', 4000.00, 11),
    ('Old Parr Silver', 3750.00, 12),
    ('Whisky Johnnie Black Label', 4500.00, 13),
    ('Whisky Johnnie Gold Label', 7000.00, 14),
    ('Whisky Johnnie Green Label', 8500.00, 15),
    ('Whisky Johnnie Blue Label', 24000.00, 16),
    ('Whisky Buchanans', 4500.00, 17),
    ('Fireball Cinnamon Whisky', 2800.00, 18),
    ('Whisky Dewars 12 Años', 4000.00, 19),
    ('Whisky Chivas Regal 12 Años', 3500.00, 20)
  ) as n(name, price, pos)
  where not exists (
    select 1 from public.menu_items mi
    where mi.business_id = v_business and mi.name = n.name
  );

  -- ==========================================================================
  -- TEQUILA (3 productos)
  -- ==========================================================================
  insert into public.menu_items (
    business_id, category_id, name, price, tax_mode,
    is_active, has_prep, position
  )
  select
    v_business, v_cat_tequila, n.name, n.price::numeric(12,2),
    'exclusive', true, true, n.pos
  from (values
    ('Tequila Don Julio Reposado', 8000.00, 21),
    ('Tequila Patron Silver', 7500.00, 22),
    ('Tequila Don Julio 70 Cristalino', 8500.00, 23)
  ) as n(name, price, pos)
  where not exists (
    select 1 from public.menu_items mi
    where mi.business_id = v_business and mi.name = n.name
  );

  -- ==========================================================================
  -- VODKA (3 productos)
  -- ==========================================================================
  insert into public.menu_items (
    business_id, category_id, name, price, tax_mode,
    is_active, has_prep, position
  )
  select
    v_business, v_cat_vodka, n.name, n.price::numeric(12,2),
    'exclusive', true, true, n.pos
  from (values
    ('Vodka Stolichnaya', 2000.00, 24),
    ('Vodka Grey Goose', 3500.00, 25),
    ('Vodka Ciroc', 3800.00, 26)
  ) as n(name, price, pos)
  where not exists (
    select 1 from public.menu_items mi
    where mi.business_id = v_business and mi.name = n.name
  );

  -- ==========================================================================
  -- COGNAC (2 productos)
  -- ==========================================================================
  insert into public.menu_items (
    business_id, category_id, name, price, tax_mode,
    is_active, has_prep, position
  )
  select
    v_business, v_cat_cognac, n.name, n.price::numeric(12,2),
    'exclusive', true, true, n.pos
  from (values
    ('Remy Martin Cognac', 6500.00, 27),
    ('Hennessy Cognac', 4500.00, 28)
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
    v_business, v_cat_champagne, n.name, n.price::numeric(12,2),
    'exclusive', true, true, n.pos
  from (values
    ('Moët & Chandon GB', 9500.00, 29),
    ('Moët & Chandon Impérial Brut', 9000.00, 30)
  ) as n(name, price, pos)
  where not exists (
    select 1 from public.menu_items mi
    where mi.business_id = v_business and mi.name = n.name
  );

  -- ==========================================================================
  -- VINO TINTO (3 productos)
  -- ==========================================================================
  insert into public.menu_items (
    business_id, category_id, name, price, tax_mode,
    is_active, has_prep, position
  )
  select
    v_business, v_cat_vino, n.name, n.price::numeric(12,2),
    'exclusive', true, true, n.pos
  from (values
    ('Vino Tinto Apothic Red', 2500.00, 31),
    ('Vino Tinto 689 Red Blend', 2500.00, 32),
    ('Vino Tinto 19 Crimes', 2800.00, 33)
  ) as n(name, price, pos)
  where not exists (
    select 1 from public.menu_items mi
    where mi.business_id = v_business and mi.name = n.name
  );

end $$;

commit;
