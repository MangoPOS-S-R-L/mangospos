-- =============================================================================
-- LA PENDA EXPRESS · RECETAS — las que están ENCENDIDAS, renglón por renglón
-- business_id = 35c5076a-bd85-4a1b-8d1c-ce719c4f9ae6
--
-- SOLO LECTURA. UNA sola consulta (una fila por ingrediente).
--
-- Cómo leerla:
--   · «descuenta» es lo que sale del inventario por CADA plato vendido, en la
--     unidad del insumo (la que usa el sistema, no la del recetario).
--   · «en Cocina» / «en total» es la existencia de hoy de ese insumo.
--   · «costo plato» suma todos los renglones; «% del precio» lo compara con
--     el precio de venta. Un % disparatado (más de 100) es una receta o un
--     costo mal puesto.
--   · «vendidos» = unidades del plato vendidas desde el conteo del 1-oct.
-- =============================================================================

with
biz as (select '35c5076a-bd85-4a1b-8d1c-ce719c4f9ae6'::uuid as id),
coc as (select w.id from public.warehouses w, biz
         where w.business_id = biz.id and w.name = 'Cocina'),
activas as (
  select m.id, m.name, coalesce(m.price, 0) as precio, coalesce(m.is_active, true) as activo,
         coalesce(
           (select string_agg(pa.name, ' + ' order by pa.name)
              from public.menu_item_print_areas x
              join public.print_areas pa on pa.id = x.print_area_id
             where x.menu_item_id = m.id),
           (select pa.name from public.print_areas pa
             where pa.business_id = m.business_id and pa.code = m.print_area_code
             limit 1),
           '(sin área)') as area,
         r.id as recipe_id
    from public.menu_items m
    join public.recipes r on r.menu_item_id = m.id, biz
   where m.business_id = biz.id
     and coalesce(m.is_inventory_tracked, false)
),
vendidos as (
  select oi.product_id, sum(coalesce(oi.qty, oi.quantity::numeric, 0)) as un
    from public.order_items oi
   where oi.product_id in (select id from activas)
     and oi.status <> 'void'
     and oi.created_at >= '2026-10-01 08:00-04'
   group by oi.product_id
),
lineas as (
  select a.name as producto, a.area, a.precio, a.activo,
         i.name as ingrediente, i.unit as unidad, ri.quantity as descuenta,
         coalesce(i.cost, 0) as costo,
         ri.quantity * coalesce(i.cost, 0) as costo_linea,
         coalesce((select st.quantity from public.inventory_stock st, coc
                    where st.item_id = i.id and st.warehouse_id = coc.id), 0) as en_cocina,
         coalesce((select sum(st.quantity) from public.inventory_stock st
                    join public.warehouses w on w.id = st.warehouse_id, biz
                   where st.item_id = i.id and w.business_id = biz.id), 0) as en_total,
         coalesce(v.un, 0) as vendidos
    from activas a
    join public.recipe_ingredients ri on ri.recipe_id = a.recipe_id
    join public.inventory_items i on i.id = ri.inventory_item_id
    left join vendidos v on v.product_id = a.id
)
select producto
         || case when not activo then ' (INACTIVO)' else '' end      as producto,
       area,
       ingrediente,
       regexp_replace(round(descuenta, 3)::text, '\.?0+$', '') || ' ' || coalesce(unidad, '')
                                                                    as descuenta,
       to_char(costo_linea, 'FM999,999,990.00')                     as costo_renglon,
       regexp_replace(round(en_cocina, 2)::text, '\.?0+$', '')       as en_cocina,
       regexp_replace(round(en_total, 2)::text, '\.?0+$', '')        as en_total,
       to_char(sum(costo_linea) over (partition by producto), 'FM999,999,990.00')
                                                                    as costo_plato,
       case when precio > 0
            then round(100 * sum(costo_linea) over (partition by producto) / precio)::text || '%'
            else 'sin precio' end                                   as pct_del_precio,
       vendidos::int                                                as vendidos
  from lineas
 order by lineas.producto, costo_linea desc, ingrediente;
