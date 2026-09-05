-- =============================================================================
-- LA PENDA EXPRESS — los 7 renglones de la hoja 2 (productos del menú)
-- business_id = 35c5076a-bd85-4a1b-8d1c-ce719c4f9ae6
--
-- La hoja 2 del Excel no son insumos: son PRODUCTOS DEL MENÚ con precio, y
-- alguien los contó. Son preparaciones que la cocina produce y guarda:
--
--   CASABE                          43 paquetes
--   QUIPE DE POLLO                  42 unidades   ⚠ ver abajo
--   MANGU DE PLATANO - GUARNICION   41 bolsas
--   CROQUETAS DE POLLO              17 servicios
--   PAPAS FRITAS                    16 unidades
--   VEGETALES SALTEADOS             11 bolsas
--   COCOA AMARGA                     2 unidades
--
-- ⚠️ QUIPE DE POLLO ESTÁ CONTADO DOS VECES. En la hoja 1 (insumos) dice 10
--    unidades y en la hoja 2 (menú) dice 42. Los dos tienen el mismo sku
--    00000740. El 10 ya se cargó en la sesión de Cocina. Hay que decidir
--    cuál es el bueno antes de seguir — la consulta 2 muestra los dos.
--
-- Correr una sentencia a la vez.
-- =============================================================================

-- ── 1. ¿QUÉ SON ESTOS SIETE HOY? ───────────────────────────────────────────
--    Para cada uno: si es producto del menú, si descuenta inventario, y si
--    hay un insumo con ese nombre o ese código.
with hoja2(nombre, contado, unidad) as (values
  ('CASABE', 43, 'paquetes'),
  ('QUIPE DE POLLO', 42, 'unidad'),
  ('MANGU DE PLATANO - GUARNICION', 41, 'bolsas'),
  ('CROQUETAS DE POLLO', 17, 'servicio'),
  ('PAPAS FRITAS', 16, 'unidad'),
  ('VEGETALES SALTEADOS', 11, 'bolsas'),
  ('COCOA AMARGA', 2, 'unidad')
)
select
  h.nombre                                     as en_la_hoja,
  h.contado, h.unidad,
  -- El producto del menú
  mi.name                                      as producto_menu,
  coalesce(nullif(btrim(mi.sku),''),'')        as sku_producto,
  case when coalesce(mi.is_inventory_tracked,false) then 'Sí' else 'NO' end
                                               as descuenta_inventario,
  (select count(*) from public.recipes r where r.menu_item_id = mi.id)
                                               as tiene_receta,
  -- El insumo enlazado, si lo hay
  ii.name                                      as insumo_enlazado,
  ii.unit                                      as unidad_insumo,
  coalesce((select sum(s.quantity) from public.inventory_stock s
             where s.item_id = ii.id), 0)      as existencia_insumo,
  -- Un insumo con el MISMO nombre, aunque no esté enlazado
  (select i2.name || ' · ' || i2.unit || ' · ' ||
          coalesce((select sum(s.quantity) from public.inventory_stock s
                     where s.item_id = i2.id), 0)::text
     from public.inventory_items i2
    where i2.business_id = '35c5076a-bd85-4a1b-8d1c-ce719c4f9ae6'
      and lower(i2.name) = lower(h.nombre)
      and coalesce(i2.is_active, true)
    limit 1)                                   as insumo_mismo_nombre,
  case
    when mi.id is null                              then '1. NO existe en el menú'
    when coalesce(mi.is_inventory_tracked,false)
         and mi.inventory_item_id is not null       then '2. Ya inventariado'
    when coalesce(mi.is_inventory_tracked,false)    then '3. Inventariable sin insumo: revisar'
    else '4. SE VENDE SIN DESCONTAR: prenderle Inventariable'
  end                                          as veredicto
from hoja2 h
left join public.menu_items mi
       on mi.business_id = '35c5076a-bd85-4a1b-8d1c-ce719c4f9ae6'
      and lower(mi.name) = lower(h.nombre)
left join public.inventory_items ii on ii.id = mi.inventory_item_id
order by veredicto, h.nombre;


-- ── 2. EL CHOQUE DEL QUIPE ─────────────────────────────────────────────────
--    Todo lo que se llame «quipe» y lleve el sku 00000740, del lado que sea.
select 'insumo' as tabla, i.id, i.name, i.unit, i.sku, round(i.cost,2) as costo,
       coalesce((select sum(s.quantity) from public.inventory_stock s
                  where s.item_id = i.id), 0) as existencia,
       (select l.counted_quantity
          from public.physical_count_lines l
          join public.physical_count_sessions s2 on s2.id = l.session_id
         where l.item_id = i.id and s2.code = 'PC-2026-000003') as contado_en_cocina
from public.inventory_items i
where i.business_id = '35c5076a-bd85-4a1b-8d1c-ce719c4f9ae6'
  and (i.name ilike '%quipe%' or btrim(i.sku) = '00000740')
union all
select 'producto del menú', mi.id, mi.name, '', mi.sku, round(mi.price,2),
       null, null
from public.menu_items mi
where mi.business_id = '35c5076a-bd85-4a1b-8d1c-ce719c4f9ae6'
  and (mi.name ilike '%quipe%' or btrim(mi.sku) = '00000740')
order by 1, 3;
