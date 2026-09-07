-- ============================================================================
-- Import de catálogo — BARRA PAYÁN
-- Business e0aef218-ab95-4ba4-b8ef-036fab1c07c7
-- ============================================================================
--
-- PASO 2 — Categorías (4) y productos (54).
--
-- PRECIOS CON IMPUESTO DENTRO: los 54 entran con tax_mode = 'inclusive'.
--   El menú dice "impuestos incluidos", así que el $450 del Club Sándwich es
--   lo que el cliente paga en caja; el ITBIS se desglosa hacia adentro
--   ($450 → base $381.36 + ITBIS $68.64). NO se suma nada encima.
--   Si entrara como 'exclusive' el POS cobraría $531 y el menú sería mentira.
--
--   El vínculo con el ITBIS lo hace el PASO 3. Hasta correrlo, estos productos
--   facturan ITBIS 0: `menu_item_taxes` es la ÚNICA fuente del impuesto por
--   producto (el PRD 2.5 quitó el fallback a default_tax_rate). Los dos pasos
--   van juntos.
--
-- IDEMPOTENTE: inserta por NOT EXISTS contra lower(name). Re-ejecutarlo no
--   duplica ni pisa precios que ya se hayan editado en la app.
--
-- Requiere el PASO 1.
-- ============================================================================

begin;

-- ---------------------------------------------------------------------------
-- 2a) Categorías
-- ---------------------------------------------------------------------------

insert into public.categories (id, business_id, name, position, is_active)
select gen_random_uuid(), 'e0aef218-ab95-4ba4-b8ef-036fab1c07c7'::uuid, c.name, c.pos, true
from (values
  ('Sándwiches', 0),
  ('Otros', 1),
  ('Jugos', 2),
  ('Bebidas', 3)
) as c(name, pos)
where not exists (
  select 1 from public.categories x
  where x.business_id = 'e0aef218-ab95-4ba4-b8ef-036fab1c07c7'::uuid and x.name = c.name
);

-- ---------------------------------------------------------------------------
-- 2b) Productos
--     `is_beverage` = true en jugos y bebidas (40). Lo usan los reportes y el
--     ruteo de comandas para separar barra de cocina.
--     Sin SKU ni código de barra: el menú impreso no los trae y este negocio
--     no vende por escáner.
-- ---------------------------------------------------------------------------

insert into public.menu_items (
  id, business_id, category_id, name, description, price,
  tax_mode, is_active, is_beverage, position
)
select
  gen_random_uuid(),
  'e0aef218-ab95-4ba4-b8ef-036fab1c07c7'::uuid,
  cat.id,
  s.name,
  s.descr,
  s.price,
  'inclusive',
  true,
  s.is_bev,
  s.posicion
from public._import_e0aef218 s
join public.categories cat
  on cat.business_id = 'e0aef218-ab95-4ba4-b8ef-036fab1c07c7'::uuid
 and cat.name = s.categoria
where not exists (
  select 1 from public.menu_items m
  where m.business_id = 'e0aef218-ab95-4ba4-b8ef-036fab1c07c7'::uuid
    and lower(m.name) = lower(s.name)
);

commit;

-- ============================================================================
-- VERIFICACIÓN — esperado: Sándwiches 10 · Otros 4 · Jugos 28 · Bebidas 12
-- ============================================================================

select c.position, c.name as categoria, count(mi.id) as productos
from public.categories c
left join public.menu_items mi
  on mi.category_id = c.id and mi.business_id = c.business_id and mi.is_active
where c.business_id = 'e0aef218-ab95-4ba4-b8ef-036fab1c07c7'::uuid
group by c.position, c.name
order by c.position;

-- Debe dar 0 filas: productos del staging que no entraron.
select s.name, s.categoria
from public._import_e0aef218 s
where not exists (
  select 1 from public.menu_items m
  where m.business_id = 'e0aef218-ab95-4ba4-b8ef-036fab1c07c7'::uuid
    and lower(m.name) = lower(s.name)
);

-- Debe dar 0 filas: algo quedó en 'exclusive' y cobraría de más.
select name, price, tax_mode
from public.menu_items
where business_id = 'e0aef218-ab95-4ba4-b8ef-036fab1c07c7'::uuid
  and is_active and tax_mode <> 'inclusive';
