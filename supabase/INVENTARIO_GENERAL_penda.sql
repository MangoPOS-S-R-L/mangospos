-- =============================================================================
-- LA PENDA EXPRESS — HOJA MAESTRA DEL INVENTARIO
-- business_id = 35c5076a-bd85-4a1b-8d1c-ce719c4f9ae6
--
-- Una sola consulta con TODO el catálogo activo: lo contado y lo no contado,
-- las cinco sesiones sumadas, y la diferencia donde la hay.
--
-- ── CÓMO SE CALCULA LA DIFERENCIA ────────────────────────────────────────
-- Las cinco sesiones están sobre la MISMA bodega, así que un artículo puede
-- aparecer en varias. `contado_total` los SUMA — es la regla del dueño: lo
-- que hay en cocina más lo que hay en el bar es lo que hay.
--
-- El `segun_sistema` NO se suma: es el mismo snapshot repetido en las cinco
-- sesiones (se congelaron sobre la misma bodega), así que se toma una vez.
-- Sumarlo daría cinco veces la existencia y la diferencia sería un disparate.
--
--     diferencia = contado_total  −  segun_sistema
--
-- Ese es el ajuste REAL que va a aplicar el cierre una vez combinadas las
-- áreas. No es la suma de los ajustes de las cinco hojas — esa suma cuenta
-- cinco veces los artículos que están en más de un área.
--
-- ── LAS DOS COLUMNAS QUE SE LEEN PRIMERO ─────────────────────────────────
--   `tipo`     Producto = se vende en el menú y descuenta directo
--              Receta   = es materia prima de un plato
--              Insumo   = no está ligado a nada todavía
--
--   `estado`   NO CONTADO  = ningún área lo miró; conserva su existencia
--              NEGATIVO    = bajo cero; se vendió más de lo que entró
--              SIN COSTO   = contado pero vale 0; no mueve el total
--              SOBRA       = se contó más de lo que decía el sistema
--              FALTA       = se contó menos
--              CUADRA      = contado y sin diferencia
--
-- EXPORTAR: correr y usar «Download CSV» en el SQL Editor de Supabase.
-- =============================================================================

with lineas as (
  -- lo contado en las CINCO sesiones, agregado por artículo
  select
    l.item_id,
    sum(l.counted_quantity)                     as contado_total,
    count(*)                                    as areas,
    max(l.snapshot_quantity)                    as snapshot,
    string_agg(coalesce(nullif(btrim(s.notes), ''), s.code)
               || ': ' || l.counted_quantity::text,
               '  |  ' order by s.code)         as desglose
  from public.physical_count_lines l
  join public.physical_count_sessions s on s.id = l.session_id
  where s.business_id = '35c5076a-bd85-4a1b-8d1c-ce719c4f9ae6'
    and s.status in ('draft', 'in_progress', 'completed')
    and l.counted_quantity is not null
  group by l.item_id
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

  -- lo que dice el sistema: el snapshot si se contó, la existencia si no
  coalesce(x.snapshot, s.total, 0)                     as segun_sistema,
  x.contado_total                                      as contado,
  coalesce(x.areas, 0)                                 as areas_que_contaron,
  case when x.item_id is null then null
       else round(x.contado_total - coalesce(x.snapshot, 0), 4) end
                                                       as diferencia,

  round(coalesce(i.cost, 0), 2)                        as costo,
  round(coalesce(x.contado_total, s.total, 0) * coalesce(i.cost, 0), 2)
                                                       as valor,
  case when x.item_id is null then null
       else round((x.contado_total - coalesce(x.snapshot, 0))
                  * coalesce(i.cost, 0), 2) end        as valor_diferencia,

  case
    when x.item_id is null and coalesce(s.total, 0) < 0    then 'NEGATIVO'
    when x.item_id is null                                 then 'NO CONTADO'
    when coalesce(i.cost, 0) = 0                           then 'SIN COSTO'
    when abs(x.contado_total - coalesce(x.snapshot,0)) < 0.0001 then 'CUADRA'
    when x.contado_total > coalesce(x.snapshot, 0)         then 'SOBRA'
    else                                                        'FALTA'
  end                                                  as estado,

  coalesce(x.desglose, '')                             as desglose_por_area
from public.inventory_items i
left join lineas x on x.item_id = i.id
left join stock  s on s.item_id = i.id
where i.business_id = '35c5076a-bd85-4a1b-8d1c-ce719c4f9ae6'
  and coalesce(i.is_active, true)
order by
  -- primero lo que mueve plata, en cualquier dirección; después lo no contado
  -- con existencia; al final el relleno del catálogo
  case
    when x.item_id is not null
         and abs((x.contado_total - coalesce(x.snapshot,0))
                 * coalesce(i.cost,0)) > 0                     then 0
    when x.item_id is null and coalesce(s.total,0) < 0         then 1
    when x.item_id is null and coalesce(s.total,0) * coalesce(i.cost,0) > 0
                                                                then 2
    when x.item_id is not null                                  then 3
    else                                                             4
  end,
  abs(coalesce((x.contado_total - coalesce(x.snapshot,0)) * coalesce(i.cost,0),
               coalesce(s.total,0) * coalesce(i.cost,0))) desc,
  i.name;
