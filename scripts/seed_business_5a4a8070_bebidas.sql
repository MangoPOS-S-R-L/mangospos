-- ============================================================================
-- Seed de bebidas (ALCOHOL / SIN ALCOHOL)
-- Business: 5a4a8070-c72d-4203-a269-9c53d8e20fcc
-- ============================================================================
--
-- 25 productos en 2 categorías (11 ALCOHOL, 14 SIN ALCOHOL).
-- Mismo patrón idempotente que scripts/seed_business_fd45b87b_bebidas.sql.
--
-- Idempotente:
--   - Categorías: se crean sólo si no existen para este business.
--   - Productos: se insertan sólo si no hay un menu_item con el mismo
--     nombre en este business. Re-ejecutar el script no duplica items.
--
-- Defaults aplicados:
--   - tax_mode = 'inclusive'  → el PRECIO VENTA de la hoja YA incluye ITBIS
--     (18%). Ej: Red Bull 250 = base 211.86 + ITBIS 38.14. (Confirmado.)
--   - cost                    → tomado de la columna COSTO de la hoja.
--   - has_prep = true         → imprime comanda al bar.
--   - is_beverage = true      → marcados como bebida.
--   - is_active = true        → visibles en POS desde el inicio.
--   - sold_by = 'unit' (default), sin tracking de inventario (activar por
--     producto desde el form cuando configures bodega/receta).
--
-- Normalizaciones aplicadas al texto de la hoja (revisar):
--   - "CHIVAS 12/18 ANOS"  → "AÑOS"  (se restauró la ñ)
--   - "HEINKEN LATA"       → "HEINEKEN LATA"  (marca)
--   - "BRUGAL 188 + MEZCLA"→ "BRUGAL 1888 + MEZCLA"  (los otros Brugal son 1888)
-- ============================================================================

begin;

-- ----------------------------------------------------------------------------
-- 1) Categorías
-- ----------------------------------------------------------------------------
insert into public.categories (id, business_id, name, position, is_active)
select gen_random_uuid(), '5a4a8070-c72d-4203-a269-9c53d8e20fcc', 'ALCOHOL', 0, true
where not exists (
  select 1 from public.categories
  where business_id = '5a4a8070-c72d-4203-a269-9c53d8e20fcc' and name = 'ALCOHOL'
);
insert into public.categories (id, business_id, name, position, is_active)
select gen_random_uuid(), '5a4a8070-c72d-4203-a269-9c53d8e20fcc', 'SIN ALCOHOL', 1, true
where not exists (
  select 1 from public.categories
  where business_id = '5a4a8070-c72d-4203-a269-9c53d8e20fcc' and name = 'SIN ALCOHOL'
);

-- ----------------------------------------------------------------------------
-- 2) Productos
-- ----------------------------------------------------------------------------
do $$
declare
  v_business    uuid := '5a4a8070-c72d-4203-a269-9c53d8e20fcc';
  v_cat_alcohol uuid;
  v_cat_sin     uuid;
begin
  select id into v_cat_alcohol
    from public.categories where business_id = v_business and name = 'ALCOHOL' limit 1;
  select id into v_cat_sin
    from public.categories where business_id = v_business and name = 'SIN ALCOHOL' limit 1;

  -- ==========================================================================
  -- ALCOHOL (11 productos)   name, price(PRECIO VENTA), cost(COSTO), pos
  -- ==========================================================================
  insert into public.menu_items (
    business_id, category_id, name, price, cost, tax_mode,
    is_active, has_prep, is_beverage, position
  )
  select
    v_business, v_cat_alcohol, n.name, n.price::numeric(12,2), n.cost::numeric,
    'inclusive', true, true, true, n.pos
  from (values
    ('BRUGAL 1888 - Botella',                       5000.00, 2495.00, 0),
    ('BRUGAL 1888 + MEZCLA',                         650.00,  325.00, 1),
    ('BRUGAL 1888 - TRAGO',                          600.00,  250.00, 2),
    ('CHIVAS 12 AÑOS',                              5000.00, 2600.00, 3),
    ('CHIVAS 18 AÑOS',                              8900.00, 6500.00, 4),
    ('CHIVAS 12 AÑOS + MEZCLA',                      600.00,  260.00, 5),
    ('VODKA TITOS + MEZCLA',                         600.00,  270.00, 6),
    ('VODKA TITOS + REDBULL NORMAL O WATERMELON',    575.00,  300.00, 7),
    ('GIN BEEFEATER + REDBULL TROPICAL',             575.00,  300.00, 8),
    ('GIN BEEFEATER + MEZCLA',                       600.00,  300.00, 9),
    ('HEINEKEN LATA',                                200.00,   75.00, 10)
  ) as n(name, price, cost, pos)
  where not exists (
    select 1 from public.menu_items mi
    where mi.business_id = v_business and mi.name = n.name
  );

  -- ==========================================================================
  -- SIN ALCOHOL (14 productos)
  -- ==========================================================================
  insert into public.menu_items (
    business_id, category_id, name, price, cost, tax_mode,
    is_active, has_prep, is_beverage, position
  )
  select
    v_business, v_cat_sin, n.name, n.price::numeric(12,2), n.cost::numeric,
    'inclusive', true, true, true, n.pos
  from (values
    ('COCACOLA',                           120.00,  35.00, 0),
    ('SPRITE',                             120.00,  35.00, 1),
    ('AGUA TONICA SAN PELLEGRINO',         250.00, 125.00, 2),
    ('COCACOLA SIN AZUCAR',                120.00,  35.00, 3),
    ('HEINEKEN 0.0',                       250.00, 125.00, 4),
    ('AGUA SAN PELLEGRINO NORMAL 500ML',   250.00, 125.00, 5),
    ('AGUA SABORISADA 330ML',              250.00, 130.00, 6),
    ('AGUA PANNA',                         195.00, 108.00, 7),
    ('REDBULL PIT STOP TROPICAL',          350.00, 220.00, 8),
    ('REDBULL YELLOW FLAG | WATERMELON',   350.00, 220.00, 9),
    ('RED BULL NORMAL',                    250.00, 120.00, 10),
    ('REDBULL SIN AZUCAR',                 250.00, 120.00, 11),
    ('RED BULL TROPICAL',                  250.00, 120.00, 12),
    ('RED BULL WATER MELON',               250.00, 120.00, 13)
  ) as n(name, price, cost, pos)
  where not exists (
    select 1 from public.menu_items mi
    where mi.business_id = v_business and mi.name = n.name
  );
end $$;

commit;

-- ----------------------------------------------------------------------------
-- Verificación (opcional): correr después del commit
-- ----------------------------------------------------------------------------
-- select c.name as categoria, mi.name, mi.price, mi.cost, mi.tax_mode
-- from public.menu_items mi
-- join public.categories c on c.id = mi.category_id
-- where mi.business_id = '5a4a8070-c72d-4203-a269-9c53d8e20fcc'
-- order by c.position, mi.position;
