-- ============================================================================
-- Import de catálogo Square → MangoPOS
-- Business 882ef5a4-93eb-4e58-92c3-bf532e179d45 (licorería MONCION)
-- Fuente: MLYH9X2TGPA28_catalog-2026-08-11-0140.csv (export de Square)
-- ============================================================================
--
-- PASO 2 — Categorías y productos.
--
-- IMPUESTOS: los 1516 productos entran en tax_mode = 'exclusive' y SIN
--   ningún vínculo en menu_item_taxes. En MangoPOS esa tabla es la ÚNICA fuente
--   del impuesto por producto: sin vínculo, el POS cobra el precio tal cual,
--   con ITBIS 0. Es lo pedido — el precio del CSV es el precio que se cobra.
--
-- IDEMPOTENTE: inserta por NOT EXISTS contra lower(name). Re-ejecutar no
--   duplica ni pisa precios ya editados en la app.
--
-- Requiere el PASO 1.
-- ============================================================================

begin;

-- ---------------------------------------------------------------------------
-- 2a) Categorías (26)
-- ---------------------------------------------------------------------------

insert into public.categories (id, business_id, name, position, is_active)
select gen_random_uuid(), '882ef5a4-93eb-4e58-92c3-bf532e179d45'::uuid, c.name, c.pos, true
from (values
  ('Cerveza', 0),
  ('Wine', 1),
  ('Whiskey', 2),
  ('Rum', 3),
  ('Tequila', 4),
  ('Vodka', 5),
  ('Ginebra', 6),
  ('Cognac', 7),
  ('Brandy', 8),
  ('Licores', 9),
  ('Champaña', 10),
  ('Pre-Mix', 11),
  ('Mix', 12),
  ('Tragos', 13),
  ('Cócteles', 14),
  ('Fiesta', 15),
  ('Comida', 16),
  ('Hookah', 17),
  ('Jugos', 18),
  ('Papitas', 19),
  ('Chicle', 20),
  ('Cigarros', 21),
  ('Cigarrillos', 22),
  ('Tabaco', 23),
  ('E-Cig', 24),
  ('Misc', 25)
) as c(name, pos)
where not exists (
  select 1 from public.categories x
  where x.business_id = '882ef5a4-93eb-4e58-92c3-bf532e179d45'::uuid and x.name = c.name
);

-- ---------------------------------------------------------------------------
-- 2b) Productos
--     `barcode` ← GTIN de Square, más 33 que estaban guardados en la columna
--     SKU con el GTIN vacío (se reconocen por la forma: 8/12/13/14 dígitos).
--     Sin ese rescate quedarían sin escanear teniendo el número ahí mismo.
--     Cero duplicados en todo el catálogo, así que el scanner nunca va a
--     traer el producto equivocado.
-- ---------------------------------------------------------------------------

insert into public.menu_items (
  id, business_id, category_id, name, description, price, cost,
  tax_mode, sku, barcode, is_active, is_beverage, position
)
select
  gen_random_uuid(),
  '882ef5a4-93eb-4e58-92c3-bf532e179d45'::uuid,
  cat.id,
  s.name,
  s.descr,
  s.price,
  s.cost,
  'exclusive',
  s.sku,
  s.barcode,
  true,
  s.is_bev,
  s.posicion
from public._import_882ef5a4 s
join public.categories cat
  on cat.business_id = '882ef5a4-93eb-4e58-92c3-bf532e179d45'::uuid
 and cat.name = s.categoria
where not exists (
  select 1 from public.menu_items m
  where m.business_id = '882ef5a4-93eb-4e58-92c3-bf532e179d45'::uuid
    and lower(m.name) = lower(s.name)
);

commit;

-- ============================================================================
-- VERIFICACIÓN
-- ============================================================================

-- Conteo por categoría (esperado abajo, en 05_verificacion.sql)
select c.position, c.name as categoria, count(mi.id) as productos
from public.categories c
left join public.menu_items mi
  on mi.category_id = c.id and mi.business_id = c.business_id and mi.is_active
where c.business_id = '882ef5a4-93eb-4e58-92c3-bf532e179d45'::uuid
group by c.position, c.name
order by c.position;

-- Nada debe salir aquí: productos del staging que no entraron
select s.name, s.categoria
from public._import_882ef5a4 s
where not exists (
  select 1 from public.menu_items m
  where m.business_id = '882ef5a4-93eb-4e58-92c3-bf532e179d45'::uuid and lower(m.name) = lower(s.name)
);
