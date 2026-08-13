-- ============================================================================
-- Seed de menú — Business 6da31542-72e1-4f55-bc28-9837da98a119
-- ============================================================================
--
-- Carga completa del menú (pizzería italiana):
--   9 categorías, 49 productos, 5 grupos de modificadores.
--
-- IMPUESTOS — decisión explícita del dueño:
--   * TODOS los productos entran con tax_mode = 'exclusive'.
--   * Este script NO crea impuestos ni vincula nada en menu_item_taxes.
--     El 18% de ITBIS y el 10% de ley los configura el dueño después.
--   * Los precios se cargan TAL CUAL vienen en el menú (200, 550, 850...),
--     sin desglosar ni descontar nada.
--
--   OJO: en MangoPOS `menu_item_taxes` es la ÚNICA fuente del impuesto.
--   Mientras no se vincule un impuesto a cada producto, el POS cobrará
--   estos items con ITBIS 0. Eso es lo esperado hasta que el dueño
--   configure los impuestos (ver "SIGUIENTE PASO" al final del archivo).
--
-- VARIANTES (mismo precio → grupo de modificadores $0, selección obligatoria):
--   Ciao Tonic → Rosada / Blanca
--   Mojitos    → Coco / Chinola / Limón
--   Presidente → Normal / Light
--   Frozen     → Limón / Chinola / Limonada de coco
--
-- EXTRAS DE PIZZA (grupo "Extras Pizza", opcional, hasta 2):
--   Agregar burrata +350, Borde relleno +200
--   → se vincula a las 14 pizzas (Clásicas + Especiales).
--
-- IDEMPOTENTE: todo se inserta con NOT EXISTS. Re-ejecutar no duplica.
--   - Categorías / grupos: por (business_id, name)
--   - Productos: por (business_id, lower(name))
--   - Modificadores: por (group_id, name)
--   - Vínculos producto↔grupo: por PK (menu_item_id, group_id)
--
-- Ejecutar en Supabase Studio → SQL Editor (o psql). Un solo commit.
-- ============================================================================

begin;

-- ----------------------------------------------------------------------------
-- 1) Categorías
-- ----------------------------------------------------------------------------

insert into public.categories (id, business_id, name, position, is_active)
select
  gen_random_uuid(),
  '6da31542-72e1-4f55-bc28-9837da98a119'::uuid,
  c.name,
  c.pos,
  true
from (values
  ('Entrada'::text,          0),
  ('Pizzas Clásicas',        1),
  ('Pizzas Especiales',      2),
  ('Ensalada',               3),
  ('Sandwich',               4),
  ('Cocktails',              5),
  ('Tragos',                 6),
  ('Cervezas',               7),
  ('Bebidas',                8)
) as c(name, pos)
where not exists (
  select 1
  from public.categories x
  where x.business_id = '6da31542-72e1-4f55-bc28-9837da98a119'::uuid
    and x.name = c.name
);

-- ----------------------------------------------------------------------------
-- 2) Productos
--    tax_mode = 'exclusive' en todos. is_beverage = true en barra/bebidas.
--    `sku` guarda el código del menú original (ENT-001, PZE-004...) para
--    trazabilidad y para poder cruzar contra el JSON de origen.
-- ----------------------------------------------------------------------------

insert into public.menu_items (
  id, business_id, category_id, name, description,
  price, tax_mode, sku, is_active, is_beverage, position
)
select
  gen_random_uuid(),
  '6da31542-72e1-4f55-bc28-9837da98a119'::uuid,
  cat.id,
  i.name,
  i.descr,
  i.price,
  'exclusive',
  i.sku,
  true,
  i.is_bev,
  i.pos
from (values
  -- ===================== ENTRADA =====================
  ('Entrada'::text, 'ENT-001'::text, 'Una ñanga'''::text,
   'Focaccia con ajo acompañado de salsa marinada'::text, 200::numeric, false, 0),
  ('Entrada', 'ENT-002', 'Nuditos',
   'Nuditos de nuestra masa artesanal, con mantequilla de ajo rostizados y cebolla, acompañado de salsa marinada', 200, false, 1),
  ('Entrada', 'ENT-003', 'Burrata in love',
   'Burrata, tomate rostizados y prosciutto di Parma', 600, false, 2),

  -- ================= PIZZAS CLÁSICAS =================
  ('Pizzas Clásicas', 'PZC-001', 'Pizza Margarita',                null, 550, false, 0),
  ('Pizzas Clásicas', 'PZC-002', 'Pizza Amore de pepperoni',       null, 600, false, 1),
  ('Pizzas Clásicas', 'PZC-003', 'Pizza Clásica de maíz y jamón',  null, 600, false, 2),

  -- ================ PIZZAS ESPECIALES ================
  ('Pizzas Especiales', 'PZE-001', 'Pizza Trufada',
   'Pepperoni, queso ricotta y miel trufada', 800, false, 0),
  ('Pizzas Especiales', 'PZE-002', 'Pizza Ardiente',
   'Chorizo, queso ricotta y miel picante', 800, false, 1),
  ('Pizzas Especiales', 'PZE-003', 'Pizza La finalista',
   'Crema de ajo, bruschetta, burrata y rúcula', 850, false, 2),
  ('Pizzas Especiales', 'PZE-004', 'Pizza Pimentón',
   'Mozzarella fresco, pimientos rostizados, prosciutto di Parma, balsamic glazed y parmesano', 850, false, 3),
  ('Pizzas Especiales', 'PZE-005', 'Pizza Atipical',
   'Tomate cherry, marcapone, prosciutto di Parma y rúcula', 850, false, 4),
  ('Pizzas Especiales', 'PZE-006', 'Pizza Bianca',
   'Pizza en salsa blanca - Alfredo, queso mozzarella, salchicha italiana, tocineta y un toque de parmesano', 850, false, 5),
  ('Pizzas Especiales', 'PZE-007', 'Pizza Estrella',
   'Pizza con salsa pesto, toques de salsa pomodoro, queso mozzarella, queso ricotta, chorizo y miel trufada', 850, false, 6),
  ('Pizzas Especiales', 'PZE-008', 'Pizza 5 quesos',
   'Salsa blanca, queso mozzarella, gorgonzola, parmesano, queso de cabra, stracciatella', 850, false, 7),
  ('Pizzas Especiales', 'PZE-009', 'Pizza Carnívora',
   'Pizza en salsa marinada, queso mozzarella, salchicha italiana, tocineta, chorizo, pepperoni, jamón, prosciutto di Parma y un toque de parmesano', 900, false, 8),
  ('Pizzas Especiales', 'PZE-010', 'Pizza BBQ',
   'Pizza en salsa BBQ, queso mozzarella, cebolla blanca, tocineta y toques de crema queso azul', 850, false, 9),
  ('Pizzas Especiales', 'PZE-011', 'Pizza Regina',
   'Pizza en forma de lazo, rellena de una burrata fresca, salsa marinada, pesto, jamón serrano y toques de glazed balsamic y miel trufada', 850, false, 10),

  -- ===================== ENSALADA ====================
  ('Ensalada', 'ENS-001', 'Ensalada de la casa',
   'Rúcula, burrata, tomate cherry, fruta de temporada, dressing de balsámico y honey mustard', 500, false, 0),

  -- ===================== SANDWICH ====================
  ('Sandwich', 'SND-001', 'Sandwich Italiano',
   'Pan recién horneado, prosciutto di Parma, chorizo, mozzarella, rúcula y glazed balsamic, servido con Lays', 400, false, 0),

  -- ===================== COCKTAILS ===================
  ('Cocktails', 'COC-001', 'Ciao Spritz',
   'St. Germain, Prosecco, agua con gas', 400, true, 0),
  ('Cocktails', 'COC-002', 'Lychee Martini',            null, 425, true, 1),
  ('Cocktails', 'COC-003', 'Venecia Spritz',
   'Bebida italiana hecha con Select, Prosecco y Aranciata Rossa', 450, true, 2),
  ('Cocktails', 'COC-004', 'Aperol Spritz',
   'Aperol, Prosecco, agua con gas, toque de naranja', 400, true, 3),
  ('Cocktails', 'COC-005', 'Amore Milano',
   'Campari, Prosecco, jugo de naranja', 400, true, 4),
  ('Cocktails', 'COC-006', 'Limoncello Sprizt',
   'Limoncello, Prosecco, agua con gas', 400, true, 5),
  ('Cocktails', 'COC-007', 'Ciao Tonic',
   'Ginebra Beefeater (rosada o blanca), agua tónica, especiado y frutado', 350, true, 6),
  ('Cocktails', 'COC-008', 'Sunset Paloma',
   'Tequila, jugo de toronja, frutos rojos y tajín', 350, true, 7),
  ('Cocktails', 'COC-009', 'Tamarindo Bloom',
   'Ron, tamarindo, limón, con un toque de canela', 300, true, 8),
  ('Cocktails', 'COC-010', 'Mojitos',
   'Coco, chinola y limón', 250, true, 9),

  -- ====================== TRAGOS =====================
  ('Tragos', 'TRG-001', 'Cuba Libre',            null, 200, true, 0),
  ('Tragos', 'TRG-002', 'Doble Reserva',         null, 200, true, 1),
  ('Tragos', 'TRG-003', 'Old Parr',              null, 350, true, 2),
  ('Tragos', 'TRG-004', 'Johnnie Walker Black',  null, 450, true, 3),
  ('Tragos', 'TRG-005', 'Johnnie Walker Gold',   null, 550, true, 4),

  -- ===================== CERVEZAS ====================
  ('Cervezas', 'CRV-001', 'Stella',                    null, 200, true, 0),
  ('Cervezas', 'CRV-002', 'Coors Original',            null, 200, true, 1),
  ('Cervezas', 'CRV-003', 'Presidente Normal & Light', null, 150, true, 2),
  ('Cervezas', 'CRV-004', 'Desperado',                 null, 200, true, 3),
  ('Cervezas', 'CRV-005', 'Paulaner',                  null, 250, true, 4),
  ('Cervezas', 'CRV-006', 'Smirnoff Manzana',          null, 200, true, 5),
  ('Cervezas', 'CRV-007', 'Corona',                    null, 200, true, 6),
  ('Cervezas', 'CRV-008', 'Blue Moon',                 null, 225, true, 7),
  ('Cervezas', 'CRV-009', 'Modelo',                    null, 200, true, 8),

  -- ===================== BEBIDAS =====================
  ('Bebidas', 'BEB-001', 'Piña Colada',            'Sin alcohol', 200, true, 0),
  ('Bebidas', 'BEB-002', 'Piña Colada c/ Alcohol', null, 250, true, 1),
  ('Bebidas', 'BEB-003', 'Frozen',
   'Limón, chinola, limonada coco', 200, true, 2),
  ('Bebidas', 'BEB-004', 'Refresco ½ litro',       null, 100, true, 3),
  ('Bebidas', 'BEB-005', 'Agua',                   null,  25, true, 4),
  ('Bebidas', 'BEB-006', 'S. Pellegrino',          null, 450, true, 5)
) as i(cat, sku, name, descr, price, is_bev, pos)
join public.categories cat
  on cat.business_id = '6da31542-72e1-4f55-bc28-9837da98a119'::uuid
 and cat.name = i.cat
where not exists (
  select 1
  from public.menu_items m
  where m.business_id = '6da31542-72e1-4f55-bc28-9837da98a119'::uuid
    and lower(m.name) = lower(i.name)
);

-- ----------------------------------------------------------------------------
-- 3) Grupos de modificadores
--    "Extras Pizza"  → opcional, hasta 2 (min 0 / max 2)
--    Grupos de sabor → obligatorio, exactamente 1 (min 1 / max 1)
-- ----------------------------------------------------------------------------

insert into public.modifier_groups (id, business_id, name, min_select, max_select, is_active)
select
  gen_random_uuid(),
  '6da31542-72e1-4f55-bc28-9837da98a119'::uuid,
  g.name,
  g.mn,
  g.mx,
  true
from (values
  ('Extras Pizza'::text,      0, 2),
  ('Ciao Tonic',              1, 1),
  ('Sabor Mojito',            1, 1),
  ('Presidente',              1, 1),
  ('Sabor Frozen',            1, 1)
) as g(name, mn, mx)
where not exists (
  select 1
  from public.modifier_groups x
  where x.business_id = '6da31542-72e1-4f55-bc28-9837da98a119'::uuid
    and x.name = g.name
);

-- ----------------------------------------------------------------------------
-- 4) Modificadores (opciones de cada grupo)
-- ----------------------------------------------------------------------------

insert into public.modifiers (id, business_id, group_id, name, price_delta, is_active)
select
  gen_random_uuid(),
  '6da31542-72e1-4f55-bc28-9837da98a119'::uuid,
  g.id,
  m.name,
  m.price,
  true
from (values
  -- Extras de pizza (con costo)
  ('Extras Pizza'::text, 'Agregar burrata'::text, 350::numeric),
  ('Extras Pizza',       'Borde relleno',         200),

  -- Variantes (sin costo, mismo precio de venta)
  ('Ciao Tonic',   'Rosada',            0),
  ('Ciao Tonic',   'Blanca',            0),

  ('Sabor Mojito', 'Coco',              0),
  ('Sabor Mojito', 'Chinola',           0),
  ('Sabor Mojito', 'Limón',             0),

  ('Presidente',   'Normal',            0),
  ('Presidente',   'Light',             0),

  ('Sabor Frozen', 'Limón',             0),
  ('Sabor Frozen', 'Chinola',           0),
  ('Sabor Frozen', 'Limonada de coco',  0)
) as m(grp, name, price)
join public.modifier_groups g
  on g.business_id = '6da31542-72e1-4f55-bc28-9837da98a119'::uuid
 and g.name = m.grp
where not exists (
  select 1
  from public.modifiers x
  where x.group_id = g.id
    and x.name = m.name
);

-- ----------------------------------------------------------------------------
-- 5) Vínculos producto ↔ grupo de modificadores
-- ----------------------------------------------------------------------------

-- 5a) "Extras Pizza" → las 14 pizzas (Clásicas + Especiales)
insert into public.menu_item_groups (menu_item_id, group_id)
select mi.id, g.id
from public.menu_items mi
join public.categories cat
  on cat.id = mi.category_id
join public.modifier_groups g
  on g.business_id = '6da31542-72e1-4f55-bc28-9837da98a119'::uuid
 and g.name = 'Extras Pizza'
where mi.business_id = '6da31542-72e1-4f55-bc28-9837da98a119'::uuid
  and cat.name in ('Pizzas Clásicas', 'Pizzas Especiales')
  and not exists (
    select 1
    from public.menu_item_groups x
    where x.menu_item_id = mi.id
      and x.group_id = g.id
  );

-- 5b) Grupos de sabor → su producto específico
insert into public.menu_item_groups (menu_item_id, group_id)
select mi.id, g.id
from (values
  ('Ciao Tonic'::text,                'Ciao Tonic'::text),
  ('Mojitos',                         'Sabor Mojito'),
  ('Presidente Normal & Light',       'Presidente'),
  ('Frozen',                          'Sabor Frozen')
) as v(item_name, group_name)
join public.menu_items mi
  on mi.business_id = '6da31542-72e1-4f55-bc28-9837da98a119'::uuid
 and lower(mi.name) = lower(v.item_name)
join public.modifier_groups g
  on g.business_id = '6da31542-72e1-4f55-bc28-9837da98a119'::uuid
 and g.name = v.group_name
where not exists (
  select 1
  from public.menu_item_groups x
  where x.menu_item_id = mi.id
    and x.group_id = g.id
);

commit;

-- ============================================================================
-- VERIFICACIÓN (correr después del commit)
-- ============================================================================

-- Conteo por categoría — esperado:
--   Entrada 3 | Pizzas Clásicas 3 | Pizzas Especiales 11 | Ensalada 1
--   Sandwich 1 | Cocktails 10 | Tragos 5 | Cervezas 9 | Bebidas 6  = 49
select c.position, c.name as categoria, count(mi.id) as productos
from public.categories c
left join public.menu_items mi
  on mi.category_id = c.id
 and mi.business_id = c.business_id
 and mi.is_active
where c.business_id = '6da31542-72e1-4f55-bc28-9837da98a119'::uuid
group by c.position, c.name
order by c.position;

-- Modificadores por grupo — esperado:
--   Extras Pizza 2 (14 productos) | Ciao Tonic 2 (1) | Sabor Mojito 3 (1)
--   Presidente 2 (1) | Sabor Frozen 3 (1)
select
  g.name as grupo,
  g.min_select,
  g.max_select,
  count(distinct m.id)   as opciones,
  count(distinct mig.menu_item_id) as productos_vinculados
from public.modifier_groups g
left join public.modifiers m         on m.group_id = g.id and m.is_active
left join public.menu_item_groups mig on mig.group_id = g.id
where g.business_id = '6da31542-72e1-4f55-bc28-9837da98a119'::uuid
group by g.name, g.min_select, g.max_select
order by g.name;

-- Confirmar que TODO quedó exclusive y SIN impuesto vinculado (esperado: 49 / 0)
select
  count(*)                                          as total,
  count(*) filter (where mi.tax_mode = 'exclusive') as exclusivos,
  count(*) filter (where mit.item_id is not null)   as con_impuesto_vinculado
from public.menu_items mi
left join public.menu_item_taxes mit on mit.item_id = mi.id
where mi.business_id = '6da31542-72e1-4f55-bc28-9837da98a119'::uuid
  and mi.is_active;

-- ============================================================================
-- SIGUIENTE PASO (lo hace el dueño, NO este script)
-- ============================================================================
-- 1. Crear los impuestos en Ajustes → Impuestos:
--      ITBIS 18   |   Ley 10
-- 2. Vincular cada impuesto a los productos que correspondan.
--    En MangoPOS `menu_item_taxes` es la ÚNICA fuente del impuesto:
--    producto sin vínculo = se cobra con ITBIS 0.
-- 3. Opcional: asignar áreas de impresión (cocina / barra) para que las
--    comandas salgan separadas. Las bebidas ya quedaron marcadas con
--    is_beverage = true, lo que ayuda a filtrarlas:
--      select name from public.menu_items
--      where business_id = '6da31542-72e1-4f55-bc28-9837da98a119'
--        and is_beverage;
-- ============================================================================
