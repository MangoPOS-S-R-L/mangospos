-- =============================================================================
-- LA PENDA EXPRESS · RECETAS — revisar errores de mapeo y de unidad
-- business_id = 35c5076a-bd85-4a1b-8d1c-ce719c4f9ae6
--
-- SOLO LECTURA. UNA sola consulta. Mira TODAS las recetas (encendidas o no).
--
--   M1  INGREDIENTE QUE ES MERCANCÍA DE REVENTA: el insumo de la receta es el
--       de un producto que se vende tal cual (tiene vínculo directo en el
--       menú). Así entró «Huevos Sorpresa» (un dulce de la tienda) como el
--       huevo del Desayuno Americano. Casi siempre es un error del emparejador
--       del recetario. (Los productos de cocina que también se venden solos,
--       como PAPAS FRITAS o un quipe, pueden ser legítimos: revisar uno a uno.)
--   M2  INSUMO «COCINA ·» CON EXISTENCIA SOSPECHOSA: está en g o ml y tiene
--       una existencia chica (menos de 50). Lo más probable es que se haya
--       contado en fundas, frascos o libras: 13 g de alitas no alcanzan ni
--       para un plato.
--   M3  LOS HUEVOS de verdad que hay en el catálogo (para cambiar el del
--       desayuno): unidad, costo y existencia.
--   M4  plato con receta cuya área NO es COCINA ni BAR (o es BAR siendo un
--       plato de cocina): descontaría del almacén equivocado.
-- =============================================================================

with
biz as (select '35c5076a-bd85-4a1b-8d1c-ce719c4f9ae6'::uuid as id),
stock as (
  select st.item_id, sum(st.quantity) as total
    from public.inventory_stock st
    join public.warehouses w on w.id = st.warehouse_id, biz
   where w.business_id = biz.id
   group by st.item_id
),
rec as (
  select m.id as menu_item_id, m.name as plato, coalesce(m.is_active, true) as activo,
         coalesce(m.is_inventory_tracked, false) as encendida,
         i.id as item_id, i.name as insumo, i.unit, ri.quantity
    from public.menu_items m
    join public.recipes r on r.menu_item_id = m.id
    join public.recipe_ingredients ri on ri.recipe_id = r.id
    join public.inventory_items i on i.id = ri.inventory_item_id, biz
   where m.business_id = biz.id
),
area as (
  select m.id,
         coalesce(
           (select string_agg(pa.name, ' + ' order by pa.name)
              from public.menu_item_print_areas x
              join public.print_areas pa on pa.id = x.print_area_id
             where x.menu_item_id = m.id),
           (select pa.name from public.print_areas pa
             where pa.business_id = m.business_id and pa.code = m.print_area_code
             limit 1),
           '(sin área)') as area
    from public.menu_items m, biz
   where m.business_id = biz.id
)
select seccion, dato, valor from (
  -- M1
  select 1 as orden, 'M1 ingrediente que es reventa' as seccion,
         r.plato || case when r.encendida then ' [ENCENDIDA]' else '' end
                 || case when not r.activo then ' (inactivo)' else '' end as dato,
         r.insumo || ' ' || regexp_replace(round(r.quantity, 3)::text, '\.?0+$', '')
         || ' ' || coalesce(r.unit, '') || ' · se vende como «'
         || (select string_agg(v.name, '», «' order by v.name)
               from public.menu_items v
              where v.inventory_item_id = r.item_id and v.id <> r.menu_item_id) || '»' as valor
    from rec r
   where exists (select 1 from public.menu_items v
                  where v.inventory_item_id = r.item_id and v.id <> r.menu_item_id
                    and coalesce(v.is_active, true))
  union all
  -- M2
  select 2, 'M2 «COCINA ·» con existencia sospechosa', i.name || ' (' || i.unit || ')',
         'hay ' || regexp_replace(round(s.total, 2)::text, '\.?0+$', '') || ' ' || i.unit
         || ' · lo usan: '
         || (select string_agg(distinct r.plato || ' ' ||
                               regexp_replace(round(r.quantity, 2)::text, '\.?0+$', ''), ', ')
               from rec r where r.item_id = i.id)
    from public.inventory_items i
    join stock s on s.item_id = i.id, biz
   where i.business_id = biz.id
     and i.name like 'COCINA · %'
     and i.unit in ('g','ml')
     and s.total > 0 and s.total < 50
  union all
  -- M3
  select 3, 'M3 huevos en el catálogo', i.name || ' (' || coalesce(i.unit, '?') || ')',
         'costo RD$' || to_char(coalesce(i.cost, 0), 'FM999,990.00')
         || ' · existencia ' || regexp_replace(round(coalesce(s.total, 0), 2)::text, '\.?0+$', '')
         || coalesce(' · 1 ' || i.unit || ' = '
                     || regexp_replace(round((to_jsonb(i)->>'conversion_factor')::numeric, 2)::text,
                                       '\.?0+$', '')
                     || ' ' || (to_jsonb(i)->>'conversion_unit'), '')
         || case when coalesce(i.is_active, true) then '' else ' · INACTIVO' end
    from public.inventory_items i
    left join stock s on s.item_id = i.id, biz
   where i.business_id = biz.id
     and upper(i.name) ~ '\mHUEVO'
  union all
  -- M4
  select 4, 'M4 plato con receta en área rara', r.plato || case when r.encendida
              then ' [ENCENDIDA]' else '' end || case when not r.activo then ' (inactivo)' else '' end,
         'área: ' || a.area
    from (select distinct menu_item_id, plato, encendida, activo from rec) r
    join area a on a.id = r.menu_item_id
   where upper(a.area) not in ('COCINA')
     and (upper(a.area) <> 'BAR'
          or upper(r.plato) ~ '\m(DESAYUNO|OMELETTE|MANGU|SANDWICH|PECHUGA|BURGER|PIZZA|PASTA|ARROZ|ENSALADA|MOFONGO|CHICHARRON|PAPAS|CROISSANT|BAGEL|WRAP|TABLA)')
) x
order by orden, dato;
