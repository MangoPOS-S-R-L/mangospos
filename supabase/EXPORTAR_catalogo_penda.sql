-- =============================================================================
-- LA PENDA EXPRESS — el catálogo completo, para trabajarlo fuera
-- business_id = 35c5076a-bd85-4a1b-8d1c-ce719c4f9ae6
--
-- Dos consultas, dos CSV. Traen el `id` a propósito: con él se puede generar
-- después el SQL exacto de cada cambio, sin emparejar por nombre — que es
-- donde se rompió todo esta semana («AGUA SANTA ANNA» con doble N,
-- «C4 PINK LEMONADE» escrito «Limanade»).
--
-- ⚠️ Al abrir en Excel: Datos › Obtener datos › Desde texto/CSV, origen UTF-8.
--    Con doble clic «PEQUEÑA» sale como «PEQUEÃA».
--
-- ⚠️ Y la columna del código: formatearla como TEXTO antes de mirarla, o
--    Excel la convierte a notación científica y se pierden los dígitos. Eso
--    ya pasó con la primera hoja que llegó.
-- =============================================================================

-- ── 1. INSUMOS — todo lo que hace falta para el trabajo de unidades ────────
select
  i.id,
  i.name                                          as nombre,
  coalesce(nullif(btrim(i.sku), ''), '')          as sku,
  coalesce(nullif(btrim(i.barcode), ''), '')      as codigo_barras,
  i.unit                                          as unidad_base,
  coalesce(i.purchase_unit, '')                   as unidad_compra,
  i.pack_size                                     as contenido_empaque,
  -- La equivalencia declarada, en texto, para leerla de un vistazo:
  case when i.purchase_unit is not null and coalesce(i.pack_size,1) <> 1
       then '1 ' || i.purchase_unit || ' = ' || i.pack_size || ' ' || i.unit
  end                                             as equivalencia,
  round(coalesce(i.cost, 0), 4)                   as costo_unitario,
  coalesce((select sum(s.quantity) from public.inventory_stock s
             where s.item_id = i.id), 0)          as existencia,
  round(coalesce((select sum(s.quantity) from public.inventory_stock s
                   where s.item_id = i.id), 0)
        * coalesce(i.cost, 0), 2)                 as valor,
  coalesce(i.min_stock, 0)                        as minimo,
  coalesce(i.item_classification, '')             as clasificacion,
  case when coalesce(i.is_active, true) then 'Activo' else 'Inactivo' end as estado,
  -- Con qué está enganchado. Un insumo con receta o con producto enlazado no
  -- se le puede cambiar la unidad base a la ligera: las recetas guardan la
  -- cantidad EN esa unidad.
  (select count(*) from public.recipe_ingredients ri
    where ri.inventory_item_id = i.id)            as en_recetas,
  (select string_agg(mi.name, ' | ') from public.menu_items mi
    where mi.inventory_item_id = i.id)            as producto_enlazado,
  (select count(*) from public.inventory_movements m
    where m.item_id = i.id)                       as movimientos,
  -- Señales de datos sucios, para no tener que buscarlas después:
  case
    when i.name ~ '^[0-9]{6,}$'                       then 'NOMBRE ES UN CÓDIGO'
    when coalesce(i.sku,'') ~ '[()=]'                 then 'CÓDIGO MAL FORMADO'
    when coalesce(i.barcode,'') ~ '[()=]'             then 'CÓDIGO MAL FORMADO'
    when i.name ilike '%[FUSIONADO]%'                 then 'fusionado'
    when coalesce(i.cost,0) = 0                       then 'SIN COSTO'
  end                                             as alerta
from public.inventory_items i
where i.business_id = '35c5076a-bd85-4a1b-8d1c-ce719c4f9ae6'
order by coalesce(i.is_active, true) desc, i.name;


-- ── 2. PRODUCTOS DEL MENÚ — para ver cuáles descuentan y cuáles no ─────────
select
  mi.id,
  mi.name                                         as producto,
  coalesce(nullif(btrim(mi.sku), ''), '')         as sku,
  coalesce(nullif(btrim(mi.barcode), ''), '')     as codigo_barras,
  round(coalesce(mi.price, 0), 2)                 as precio,
  case when coalesce(mi.is_inventory_tracked, false)
       then 'Sí' else 'NO' end                    as inventariable,
  ii.name                                         as insumo_enlazado,
  ii.unit                                         as unidad_del_insumo,
  (select count(*) from public.recipes r where r.menu_item_id = mi.id)
                                                  as tiene_receta,
  case when coalesce(mi.is_active, true) then 'Activo' else 'Inactivo' end as estado,
  -- El caso que apareció con COCOA AMARGA y MALAGUETA: se vende y no
  -- descuenta nada, y la cocina lo reporta como «no está en el sistema»
  -- porque en Insumos efectivamente no está.
  case when not coalesce(mi.is_inventory_tracked, false)
            and mi.inventory_item_id is null
            and not exists (select 1 from public.recipes r
                             where r.menu_item_id = mi.id)
       then 'SE VENDE SIN DESCONTAR' end          as alerta
from public.menu_items mi
left join public.inventory_items ii on ii.id = mi.inventory_item_id
where mi.business_id = '35c5076a-bd85-4a1b-8d1c-ce719c4f9ae6'
order by coalesce(mi.is_active, true) desc, mi.name;
