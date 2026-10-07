-- ============================================================================
-- MODIFICADORES DE FOODTROPOLIS — DIAGNÓSTICO (solo lee)
--
-- Para copiarlos a LA COCINA MEXICANA AUTENTICA (b0bd6f20). Es UNA sola
-- consulta (el SQL Editor de Supabase solo muestra la última). Pégame el
-- resultado.
--    1) qué negocio es Foodtropolis: busca "foodtrop" en el nombre, la
--       sucursal, la dirección y las cajas; además muestra las otras
--       sucursales de La Cocina Mexicana y los negocios del mismo dueño
--    2) cada grupo de modificadores de esos negocios, con sus opciones y precio
--    3) a qué productos está ligado cada grupo
-- ============================================================================

with
destino as (
  select id, owner_id from public.businesses
  where id = 'b0bd6f20-850c-4e9a-85ae-4cd619e1a0ee'
),
cand as (
  select b.id, b.business_name, b.branch_name, b.address,
         concat_ws(', ',
           case when b.business_name ilike '%foodtrop%' or b.branch_name ilike '%foodtrop%'
                     or b.address ilike '%foodtrop%' then 'nombre/dirección dice Foodtropolis' end,
           case when exists (select 1 from public.cash_registers r
                             where r.business_id = b.id and r.name ilike '%foodtrop%')
                then 'caja "' || (select string_agg(r.name, '", "') from public.cash_registers r
                                  where r.business_id = b.id and r.name ilike '%foodtrop%') || '"' end,
           case when b.business_name ilike '%cocina mexicana%' then 'La Cocina Mexicana' end,
           case when b.owner_id = (select owner_id from destino) then 'mismo dueño' end) as por_que
  from public.businesses b
  where b.id <> 'b0bd6f20-850c-4e9a-85ae-4cd619e1a0ee'
    and (b.business_name ilike '%foodtrop%' or b.branch_name ilike '%foodtrop%'
         or b.address ilike '%foodtrop%'
         or exists (select 1 from public.cash_registers r
                    where r.business_id = b.id and r.name ilike '%foodtrop%')
         or b.business_name ilike '%cocina mexicana%'
         or b.owner_id = (select owner_id from destino))
),
grupos as (
  select g.*, c.business_name, c.branch_name,
         left(g.business_id::text, 8) as biz
  from public.modifier_groups g
  join cand c on c.id = g.business_id
),
r(orden, biz, sub, seccion, detalle) as (
  select 1, left(c.id::text, 8), 0, '1 Negocio',
         format('%s · %s · sucursal %s · dir %s · por: %s · productos activos %s · grupos %s (activos %s) · opciones %s',
                c.id, c.business_name, coalesce(c.branch_name, '—'), coalesce(c.address, '—'),
                c.por_que,
                (select count(*) from public.menu_items mi where mi.business_id = c.id and mi.is_active),
                (select count(*) from public.modifier_groups g where g.business_id = c.id),
                (select count(*) from public.modifier_groups g where g.business_id = c.id and g.is_active),
                (select count(*) from public.modifiers m
                 join public.modifier_groups g on g.id = m.group_id where g.business_id = c.id))
  from cand c
  union all
  select 1, '—', 0, '1 Negocio', 'NINGUNO coincide: dime el nombre exacto del negocio de Foodtropolis'
  where not exists (select 1 from cand)

  union all
  select 2, g.biz, coalesce(g.sort_order, 0), '2 Grupo',
         format('[%s] %s · min=%s max=%s · %s · obligatorio=%s · activo=%s · %s productos · opciones: %s',
                g.biz, g.name, g.min_select, g.max_select,
                coalesce(to_jsonb(g)->>'display_type', '—'),
                coalesce(to_jsonb(g)->>'is_required', '—'), g.is_active,
                (select count(*) from public.menu_item_groups y
                 join public.menu_items mi on mi.id = y.menu_item_id
                 where y.group_id = g.id and mi.is_active),
                coalesce((select string_agg(
                            m.name || ' $' || m.price_delta
                              || case when m.is_active then '' else ' (INACTIVA)' end,
                            ', ' order by coalesce((to_jsonb(m)->>'sort_order')::int, 0), m.name)
                          from public.modifiers m where m.group_id = g.id), '—'))
  from grupos g

  union all
  select 3, g.biz, coalesce(g.sort_order, 0), '3 Productos del grupo',
         format('[%s] %s ← %s', g.biz, g.name,
                coalesce((select string_agg(mi.name, ', ' order by mi.name)
                          from public.menu_item_groups y
                          join public.menu_items mi on mi.id = y.menu_item_id
                          where y.group_id = g.id and mi.is_active), 'ninguno'))
  from grupos g
)
select seccion, detalle
from r
order by orden, biz, sub, detalle;
