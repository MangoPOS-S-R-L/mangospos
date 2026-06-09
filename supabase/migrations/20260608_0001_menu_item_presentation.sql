-- ============================================================
-- Etiqueta de "presentación" por producto (Botella/Trago/Shot…)
-- ============================================================
-- Texto libre opcional. El catálogo genera sub-pestañas por categoría
-- a partir de las etiquetas distintas usadas por sus productos.
-- Aditivo (columna nullable + columna nueva al final de la vista).

begin;

alter table public.menu_items
  add column if not exists presentation text;

comment on column public.menu_items.presentation is
  'Etiqueta de presentación del producto (ej. Botella, Trago, Shot). '
  'Texto libre opcional; el catálogo la usa para sub-pestañas por '
  'categoría. NULL = sin etiqueta.';

-- Recrear la vista agregando i.presentation como ÚLTIMA columna.
-- (CREATE OR REPLACE VIEW permite añadir columnas solo al final.)
create or replace view public.v_menu_items_list
with (security_invoker = 'on') as
select
  i.id,
  i.business_id,
  i.name,
  i.description,
  i.category_id,
  c.name as category_name,
  i.price,
  i.sku,
  i.prep_minutes,
  i.has_variants,
  i.is_active,
  i.image_url,
  i.created_at,
  l.menu_id,
  m.name as menu_name,
  l.position,
  i.tax_mode,
  coalesce((
    select sum(t.rate)
    from public.menu_item_taxes mit
    join public.taxes t
      on t.id = mit.tax_id
    where mit.item_id = i.id
      and coalesce(t.is_active, true)
  ), 0)::numeric as effective_tax_rate,
  i.presentation
from public.menu_items i
left join lateral (
  select l1.menu_id, l1.position
  from public.menu_item_links l1
  where l1.item_id = i.id
  order by l1.position
  limit 1
) l on true
left join public.menus m
  on m.id = l.menu_id
left join public.categories c
  on c.id = i.category_id;

commit;
