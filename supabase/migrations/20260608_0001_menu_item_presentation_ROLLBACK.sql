-- ROLLBACK de 20260608_0001_menu_item_presentation.sql
-- Restaura v_menu_items_list sin presentation y elimina la columna.

begin;

-- Restaurar la vista a su versión previa (sin i.presentation).
-- DROP previo porque quitar la última columna cambia el tipo de retorno.
drop view if exists public.v_menu_items_list;

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
  ), 0)::numeric as effective_tax_rate
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

alter table public.menu_items drop column if exists presentation;

commit;
