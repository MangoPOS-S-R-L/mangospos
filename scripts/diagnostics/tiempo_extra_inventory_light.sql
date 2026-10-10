-- Tiempo Extra: consultas pequeñas para comprobar Studio y la configuración.
-- SOLO LECTURA. Ejecutar cada consulta POR SEPARADO en el SQL Editor.
-- Si la consulta 0 falla, su mensaje no depende del inventario ni del esquema.
-- No consulta el historial de ventas ni de movimientos.

-- 0. Comprobar si Studio puede ejecutar SQL.
select 1 as prueba;

-- 1. Resolver el negocio por nombre o sucursal, sin asumir su UUID.
select b.id as business_id, b.business_name as negocio,
       to_jsonb(b)->>'branch_name' as sucursal
from public.businesses b
where b.business_name ilike '%tiempo%extra%'
   or (to_jsonb(b)->>'branch_name') ilike '%tiempo%extra%'
order by b.business_name, b.id
limit 20;

-- 2. Revisar hasta 20 empanadas: tracking, modo y vínculo al inventario.
-- existencia_link_directo suma todas las bodegas; no es el badge de la POS.
-- Si hay receta, el motor consume sus ingredientes y omite el link directo.
with productos as materialized (
  select mi.*, b.business_name,
         nullif(to_jsonb(mi)->>'inventory_item_id', '')::uuid as directo_id
  from public.businesses b
  join public.menu_items mi on mi.business_id = b.id
  where (b.business_name ilike '%tiempo%extra%'
     or (to_jsonb(b)->>'branch_name') ilike '%tiempo%extra%')
    and mi.name ilike '%empanad%'
  order by b.business_name, mi.name, mi.id
  limit 20
)
select mi.business_name as negocio, mi.business_id, mi.id as producto_id,
       mi.name as producto,
       to_jsonb(mi)->>'is_inventory_tracked' as inventariable,
       coalesce(to_jsonb(bs)->>'inventory_mode', 'none') as modo_inventario,
       mi.directo_id as inventory_item_id, ii.name as link_directo,
       (select count(*) from public.recipes r where r.menu_item_id = mi.id) as recetas,
       (select count(*) from public.recipes r
        join public.recipe_ingredients ri on ri.recipe_id = r.id
        where r.menu_item_id = mi.id and ri.inventory_item_id is not null
          and ri.quantity > 0) as ingredientes_positivos,
       (select sum(s.quantity) from public.inventory_stock s
        join public.warehouses w on w.id = s.warehouse_id
        where s.item_id = mi.directo_id and w.business_id = mi.business_id
       ) as existencia_link_directo
from productos mi
left join public.business_settings bs on bs.business_id = mi.business_id
left join public.inventory_items ii on ii.id = mi.directo_id
order by mi.business_name, mi.name, mi.id;
