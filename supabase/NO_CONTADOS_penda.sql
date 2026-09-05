-- =============================================================================
-- LA PENDA EXPRESS — NO CONTADOS EN NINGÚN ALMACÉN
-- business_id = 35c5076a-bd85-4a1b-8d1c-ce719c4f9ae6
--
-- Una sola consulta. Todo lo que NO aparece contado en ninguna de las cinco
-- sesiones, con lo que hace falta para decidir qué hacer con cada uno.
--
-- POR QUÉ IMPORTA: el cierre solo genera ajuste para las líneas CON cantidad.
-- Una línea en blanco ni se mira, así que estos insumos conservan su
-- existencia tal cual — es inventario que nadie verificó.
--
-- CÓMO SE LEE, en dos columnas:
--
--   `tipo`    Producto  = se vende en el menú y descuenta directo del stock
--             Receta    = es materia prima de un plato
--             Insumo    = no está ligado a nada todavía
--
--   `estado`  NEGATIVO  = bajo cero; se vendió más de lo que entró. Un conteo
--                         no lo arregla si nadie lo cuenta.
--             REVISAR   = tiene existencia y vale plata → hay que contarlo
--             SIN COSTO = tiene existencia pero vale 0 → no mueve el total
--             EN CERO   = no tiene nada → no afecta el cierre
--
-- El orden pone arriba lo que hay que atender: negativos, después lo que más
-- vale, y al final el relleno del catálogo.
--
-- EXPORTAR: correr y usar «Download CSV» en el SQL Editor de Supabase.
-- =============================================================================

with contado as (
  -- los que SÍ tienen cantidad en alguna sesión
  select distinct l.item_id
  from public.physical_count_lines l
  join public.physical_count_sessions s on s.id = l.session_id
  where s.business_id = '35c5076a-bd85-4a1b-8d1c-ce719c4f9ae6'
    and s.status in ('draft', 'in_progress', 'completed')
    and l.counted_quantity is not null
),
stock as (
  select st.item_id, sum(st.quantity) as total
  from public.inventory_stock st
  group by st.item_id
)
select
  coalesce(i.sku, '')                                  as codigo,
  i.name                                               as articulo,
  case
    when exists (select 1 from public.menu_items mi
                  where mi.inventory_item_id = i.id)   then 'Producto'
    when exists (select 1 from public.recipe_ingredients ri
                  where ri.inventory_item_id = i.id)   then 'Receta'
    else                                                    'Insumo'
  end                                                  as tipo,
  coalesce(i.unit, 'unidad')                           as unidad,
  coalesce(s.total, 0)                                 as existencia,
  round(coalesce(i.cost, 0), 2)                        as costo,
  round(coalesce(s.total, 0) * coalesce(i.cost, 0), 2) as valor,
  case
    when coalesce(s.total, 0) <  0                     then 'NEGATIVO'
    when coalesce(s.total, 0) =  0                     then 'EN CERO'
    when coalesce(i.cost,  0) =  0                     then 'SIN COSTO'
    else                                                    'REVISAR'
  end                                                  as estado,
  to_char((select max(m.created_at) from public.inventory_movements m
            where m.item_id = i.id) at time zone 'America/Santo_Domingo',
          'DD/MM/YYYY')                                as ultimo_movimiento
from public.inventory_items i
left join stock s on s.item_id = i.id
where i.business_id = '35c5076a-bd85-4a1b-8d1c-ce719c4f9ae6'
  and coalesce(i.is_active, true)
  and i.id not in (select item_id from contado)
order by
  case
    when coalesce(s.total, 0) < 0                            then 0  -- negativos
    when coalesce(s.total, 0) * coalesce(i.cost, 0) > 0      then 1  -- con valor
    when coalesce(s.total, 0) > 0                            then 2  -- sin costo
    else                                                          3  -- en cero
  end,
  coalesce(s.total, 0) * coalesce(i.cost, 0) desc,
  i.name;
