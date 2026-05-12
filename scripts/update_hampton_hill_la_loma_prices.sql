-- ============================================================================
-- Update de precios + alta de nuevos productos: Hampton Hill La Loma
-- Business: 020320c7-275b-45f4-801f-ebc81ed4732d
-- ============================================================================
--
-- Aplica la lista escrita a mano del dueño. Dos secciones:
--
--   1) UPDATE de precios para productos que YA existen del seed inicial
--      (los que tenían price = 0 a la espera de precio confirmado).
--   2) INSERT de productos nuevos que no estaban en el seed (Brugal XV,
--      Mackalbert, Ballantine, cigarrillos, fósforos, etc.).
--
-- Todos los precios se mantienen con tax_mode = 'inclusive' (ITBIS
-- incluido en el precio que se le cobra al cliente).
--
-- Decisiones tomadas (avisame si querés cambiar):
--   - Items con doble precio ("solo" vs "con jugo"): usé el precio "solo".
--     Combo con Jugo Mots queda como follow-up.
--   - "Buchana" (handwritten) → match contra "Buchanans" en DB.
--   - "Jhony Gold" (6000) y "Jhoni Gold full" (7500) son productos
--     distintos. El primero ya existe; "Jhonny Gold Full" se inserta nuevo.
--   - "Menta 5 x 25" interpretado como pack de 5 unidades a 25 pesos.
--   - Cigarrillos, fósforos, etc. caen en categoría "Bebidas" porque
--     no son comida y no hay una "Otros" creada. Crear una categoría
--     aparte es trivial si después se quiere mejor agrupación.
--
-- Idempotente:
--   - Los UPDATEs sobrescriben siempre — re-ejecutar repone el precio
--     que dice la lista (no se acumulan).
--   - Los INSERTs usan WHERE NOT EXISTS por (business_id, name).
-- ============================================================================

begin;

do $$
declare
  v_business uuid := '020320c7-275b-45f4-801f-ebc81ed4732d';
  v_cat_bebidas uuid;
begin
  select id into v_cat_bebidas
    from public.categories
    where business_id = v_business and name = 'Bebidas'
    limit 1;

  if v_cat_bebidas is null then
    raise exception
      'Categoría "Bebidas" no encontrada para business %. Corré primero el seed inicial.',
      v_business;
  end if;

  -- ==========================================================================
  -- 1) UPDATEs sobre productos existentes
  -- ==========================================================================

  update public.menu_items set price = 1400
    where business_id = v_business and name = 'Brugal Extra Viejo';

  update public.menu_items set price = 2000
    where business_id = v_business and name = 'Brugal Leyenda';

  update public.menu_items set price = 1300
    where business_id = v_business and name = 'Barceló Gran Añejo';

  update public.menu_items set price = 3500
    where business_id = v_business and name = 'Buchanans';

  update public.menu_items set price = 6000
    where business_id = v_business and name = 'Jhonny Gold';

  update public.menu_items set price = 3500
    where business_id = v_business and name = 'Old Park';

  update public.menu_items set price = 3700
    where business_id = v_business and name = 'Chiva 12 Años';

  update public.menu_items set price = 300
    where business_id = v_business and name = 'Piña Colada';

  update public.menu_items set price = 300
    where business_id = v_business and name = 'Margarita';

  update public.menu_items set price = 250
    where business_id = v_business and name = 'Mojito';

  update public.menu_items set price = 200
    where business_id = v_business and name = 'Cuba Libre';

  update public.menu_items set price = 200
    where business_id = v_business and name = 'Trago Vodka';

  update public.menu_items set price = 200
    where business_id = v_business and name = 'Shot de Tequila';

  -- ==========================================================================
  -- 2) INSERTs de productos nuevos
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
    -- Brugales adicionales (precio "solo", sin jugo)
    ('Brugal Doble Reserva',  1800, 50),
    ('Brugal XV',             1200, 51),
    ('Brugal Triple Reserva', 1600, 52),
    -- Whiskies / rones que no estaban en el seed
    ('Mackalbert',            1000, 53),
    ('Sonthy',                1500, 54),
    ('Ballantine',            1800, 55),
    -- Variante Jhonny Gold
    ('Jhonny Gold Full',      7500, 56),
    -- Mixers / sodas / aguas saborizadas
    ('Agua de Coco',           300, 57),
    ('Soda Amarga',            100, 58),
    ('Clamato',                100, 59),
    ('Piña Cherry',            300, 60),
    -- Cerveza nueva
    ('Michelob',               200, 61),
    -- Misceláneos (cigarrillos, dulces, fósforos)
    ('Trident',                100, 62),
    ('Cigarrillo Newport',     250, 63),
    ('Pall Mall',              200, 64),
    ('Fósforo',                 10, 65),
    ('Menta (5 unidades)',      25, 66)
  ) as n(name, price, pos)
  where not exists (
    select 1 from public.menu_items mi
    where mi.business_id = v_business and mi.name = n.name
  );

end$$;

commit;

-- ============================================================================
-- Verificación (opcional, descomentar para confirmar precios aplicados)
-- ============================================================================
-- select name, price
-- from public.menu_items
-- where business_id = '020320c7-275b-45f4-801f-ebc81ed4732d'
--   and is_beverage = true
-- order by price desc, name asc;
