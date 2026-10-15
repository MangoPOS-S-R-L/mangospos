-- =============================================================================
-- LA PENDA EXPRESS · los MOFONGOS: cómo están armados y de dónde descuentan
-- business_id = 35c5076a-bd85-4a1b-8d1c-ce719c4f9ae6
--
-- SOLO LECTURA. UNA sola consulta.
--   V1  cada producto «mofongo»: activo, descuenta, venta en negativo, área,
--       y si descuenta por RECETA o por VÍNCULO DIRECTO (un producto con
--       receta descuenta la receta y deja de usar el vínculo)
--   V2  renglón por renglón de lo que descuenta: el ingrediente de su receta
--       o el insumo vinculado, con lo que hay en Cocina y en total
--   V3  recetas de OTROS platos que usan un insumo «mofongo»
--   V4  los insumos «mofongo»: existencia por almacén
-- =============================================================================

with
biz as (select '35c5076a-bd85-4a1b-8d1c-ce719c4f9ae6'::uuid as id),
mof as (
  select m.*,
         exists (select 1 from public.recipes r where r.menu_item_id = m.id) as con_receta,
         coalesce((select string_agg(pa.name, ' + ') from public.menu_item_print_areas x
                     join public.print_areas pa on pa.id = x.print_area_id
                    where x.menu_item_id = m.id), m.print_area_code, '(sin área)') as area
    from public.menu_items m, biz
   where m.business_id = biz.id and upper(m.name) like '%MOFONGO%'
),
existencia as (
  select st.item_id,
         sum(st.quantity) filter (where w.name = 'Cocina')            as cocina,
         sum(st.quantity) filter (where w.name = 'Almacen Principal') as principal,
         sum(st.quantity) filter (where w.name = 'FoodShop')          as foodshop,
         sum(st.quantity)                                             as total
    from public.inventory_stock st
    join public.warehouses w on w.id = st.warehouse_id, biz
   where w.business_id = biz.id
   group by st.item_id
),
fmt as (select 1)
select seccion, dato, valor from (
  -- V1
  select 1 as orden, 'V1 producto' as seccion, m.name as dato,
         concat_ws(' · ',
           case when coalesce(m.is_active, true) then 'activo' else 'INACTIVO' end
             || case when coalesce(m.auto_disabled, false) then ' (por auto-86)' else '' end,
           case when coalesce(m.is_inventory_tracked, false) then 'DESCUENTA' else 'no descuenta' end,
           case when coalesce(m.allow_negative_sale, false) then 'venta en negativo: sí'
                else 'venta en negativo: NO' end,
           'área ' || m.area,
           case when m.con_receta then 'por RECETA'
                when m.inventory_item_id is not null then 'por VÍNCULO'
                else 'sin receta ni vínculo' end,
           'precio RD$' || to_char(coalesce(m.price, 0), 'FM999,990')) as valor
    from mof m
  union all
  -- V2: receta
  select 2, 'V2 descuenta', m.name || ' ← receta',
         i.name || ' ' || regexp_replace(round(ri.quantity, 3)::text, '\.?0+$', '') || ' '
         || coalesce(i.unit, '') || ' · Cocina '
         || regexp_replace(round(coalesce(e.cocina, 0), 2)::text, '\.?0+$', '')
         || ' · total ' || regexp_replace(round(coalesce(e.total, 0), 2)::text, '\.?0+$', '')
    from mof m
    join public.recipes r on r.menu_item_id = m.id
    join public.recipe_ingredients ri on ri.recipe_id = r.id
    join public.inventory_items i on i.id = ri.inventory_item_id
    left join existencia e on e.item_id = i.id
  union all
  -- V2: vínculo directo (solo si no tiene receta: con receta el vínculo no se usa)
  select 2, 'V2 descuenta', m.name || ' ← vínculo',
         i.name || ' 1 ' || coalesce(i.unit, '') || ' · Cocina '
         || regexp_replace(round(coalesce(e.cocina, 0), 2)::text, '\.?0+$', '')
         || ' · Principal ' || regexp_replace(round(coalesce(e.principal, 0), 2)::text, '\.?0+$', '')
         || ' · FoodShop ' || regexp_replace(round(coalesce(e.foodshop, 0), 2)::text, '\.?0+$', '')
    from mof m
    join public.inventory_items i on i.id = m.inventory_item_id
    left join existencia e on e.item_id = i.id
   where not m.con_receta
  union all
  -- V3
  select 3, 'V3 otras recetas que usan mofongo', p.name
         || case when coalesce(p.is_inventory_tracked, false) then ' [ENCENDIDA]' else '' end,
         i.name || ' ' || regexp_replace(round(ri.quantity, 3)::text, '\.?0+$', '') || ' '
         || coalesce(i.unit, '')
    from public.recipe_ingredients ri
    join public.inventory_items i on i.id = ri.inventory_item_id
    join public.recipes r on r.id = ri.recipe_id
    join public.menu_items p on p.id = r.menu_item_id, biz
   where p.business_id = biz.id
     and upper(i.name) like '%MOFONGO%'
     and upper(p.name) not like '%MOFONGO%'
  union all
  -- V4
  select 4, 'V4 insumo', i.name || ' (' || coalesce(i.unit, '?') || ')',
         'Cocina ' || regexp_replace(round(coalesce(e.cocina, 0), 2)::text, '\.?0+$', '')
         || ' · Principal ' || regexp_replace(round(coalesce(e.principal, 0), 2)::text, '\.?0+$', '')
         || ' · FoodShop ' || regexp_replace(round(coalesce(e.foodshop, 0), 2)::text, '\.?0+$', '')
         || ' · costo RD$' || to_char(coalesce(i.cost, 0), 'FM999,990.00')
    from public.inventory_items i
    left join existencia e on e.item_id = i.id, biz
   where i.business_id = biz.id and upper(i.name) like '%MOFONGO%'
     and coalesce(i.is_active, true)
) x
order by orden, dato, valor;
