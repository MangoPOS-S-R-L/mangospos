-- =============================================================================
-- LA PENDA EXPRESS — entrega a DH de las capas de costo
-- business_id = 35c5076a-bd85-4a1b-8d1c-ce719c4f9ae6
--
-- QUÉ ES: las mismas cuatro consultas que expondría la API de lectura, en
-- forma de exportación. Se usa esto y NO el esquema `analytics` porque la API
-- de lectura (20260829_0002) nunca se aplicó en producción: no existe el
-- esquema, ni los roles, ni la key firmada. Montarla es un despliegue aparte,
-- con usuario propio y exposición en PostgREST; no se mezcla con la entrega
-- del motor de costeo.
--
-- CÓMO SE USA: correr UNA consulta a la vez en el SQL Editor y exportar cada
-- resultado a CSV con el botón de descarga. Cuatro hojas, una por consulta.
--
-- REQUIERE: 20260902_0012 y 20260902_0013 aplicadas, la apertura sembrada
-- (PASO B) y el motor encendido (PASO C). Antes de eso devuelven 0 filas, que
-- es la respuesta correcta: todavía no hay capas.
--
-- OJO CON LAS FECHAS: PostgREST y el servidor corren en UTC. Todas las fechas
-- de acá van casteadas a 'America/Santo_Domingo', si no toda venta después de
-- las 8 PM se va al día siguiente.
-- =============================================================================


-- ===========================================================================
-- HOJA 1 · CAPAS DE COSTO — la evidencia del entregable 1.
-- Una fila por capa: qué entró, cuándo, con qué NCF y de qué proveedor.
-- ===========================================================================
select
  ii.sku                                          as codigo,
  ii.name                                         as articulo,
  ii.unit                                         as unidad,
  w.name                                          as bodega,
  case l.source_type
    when 'opening'       then 'Inventario inicial'
    when 'purchase'      then 'Compra'
    when 'transfer_in'   then 'Transferencia recibida'
    when 'return'        then 'Devolucion'
    when 'production_in' then 'Produccion'
    else 'Ajuste'
  end                                             as origen,
  l.document_number                               as ncf_o_factura,
  l.document_date                                 as fecha_documento,
  s.name                                          as proveedor,
  (l.received_at at time zone 'America/Santo_Domingo')::date as fecha_entrada,
  l.quantity_in                                   as cantidad_entrada,
  l.quantity_remaining                            as cantidad_disponible,
  l.unit_cost                                     as costo_unitario,
  round(l.quantity_remaining * l.unit_cost, 2)    as valor_disponible,
  case when l.is_estimated then 'SIN RESPALDO' else 'con comprobante' end
                                                  as sustento
from public.inventory_cost_layers l
join public.inventory_items ii on ii.id = l.item_id
join public.warehouses w on w.id = l.warehouse_id
left join public.suppliers s on s.id = l.supplier_id
where l.business_id = '35c5076a-bd85-4a1b-8d1c-ce719c4f9ae6'
order by ii.name, l.received_at, l.seq;


-- ===========================================================================
-- HOJA 2 · INVENTARIO VALORADO POR CAPAS vs. ÚLTIMO PRECIO.
-- La columna `diferencia` es la partida de conciliación del informe.
-- ===========================================================================
select
  ii.sku                                          as codigo,
  ii.name                                         as articulo,
  ii.unit                                         as unidad,
  w.name                                          as bodega,
  sum(l.quantity_remaining)                       as existencia,
  round(sum(l.quantity_remaining * l.unit_cost), 2)
                                                  as valor_por_capas,
  case when sum(l.quantity_remaining) > 0
    then round(sum(l.quantity_remaining * l.unit_cost)
               / sum(l.quantity_remaining), 4)
    else 0 end                                    as costo_unitario_efectivo,
  ii.cost                                         as costo_ultimo_precio,
  round(sum(l.quantity_remaining) * coalesce(ii.cost, 0), 2)
                                                  as valor_ultimo_precio,
  round(sum(l.quantity_remaining) * coalesce(ii.cost, 0)
        - sum(l.quantity_remaining * l.unit_cost), 2)
                                                  as diferencia,
  count(*)                                        as capas_abiertas,
  count(*) filter (where l.is_estimated)          as capas_sin_respaldo,
  round(coalesce(sum(l.quantity_remaining * l.unit_cost)
        filter (where l.is_estimated), 0), 2)     as valor_sin_respaldo
from public.inventory_cost_layers l
join public.inventory_items ii on ii.id = l.item_id
join public.warehouses w on w.id = l.warehouse_id
where l.quantity_remaining > 0
  and l.business_id = '35c5076a-bd85-4a1b-8d1c-ce719c4f9ae6'
group by ii.sku, ii.name, ii.unit, ii.cost, w.name
order by abs(sum(l.quantity_remaining) * coalesce(ii.cost, 0)
             - sum(l.quantity_remaining * l.unit_cost)) desc;


-- ===========================================================================
-- HOJA 3 · COSTO DE VENTA por día y artículo.
-- Neto de las devoluciones que genera editar o cancelar una orden.
-- Filtrar tipo_salida = 'sale' para el costo de venta del período.
-- ===========================================================================
select
  (m.created_at at time zone 'America/Santo_Domingo')::date as fecha,
  ii.sku                                          as codigo,
  ii.name                                         as articulo,
  ii.unit                                         as unidad,
  w.name                                          as bodega,
  m.movement_type::text                           as tipo_salida,
  sum(c.quantity - c.quantity_returned)           as cantidad,
  round(sum((c.quantity - c.quantity_returned) * c.unit_cost), 2) as costo,
  case when bool_or(c.is_shortfall) then 'SI' else 'no' end
                                                  as incluye_faltante
from public.inventory_cost_consumptions c
join public.inventory_movements m on m.id = c.movement_id
join public.inventory_items ii on ii.id = c.item_id
join public.warehouses w on w.id = c.warehouse_id
where c.quantity > c.quantity_returned
  and c.business_id = '35c5076a-bd85-4a1b-8d1c-ce719c4f9ae6'
group by 1, ii.sku, ii.name, ii.unit, w.name, m.movement_type
order by 1, ii.name;


-- ===========================================================================
-- HOJA 4 · FALTANTES — salidas sin capa que las respalde.
-- Es la cara contable de las existencias negativas del hallazgo 5.
-- ===========================================================================
select
  ii.sku                                          as codigo,
  ii.name                                         as articulo,
  ii.unit                                         as unidad,
  w.name                                          as bodega,
  count(*)                                        as movimientos,
  sum(c.quantity - c.quantity_returned)           as cantidad_sin_respaldo,
  round(sum((c.quantity - c.quantity_returned) * c.unit_cost), 2)
                                                  as valor_estimado,
  (min(c.created_at) at time zone 'America/Santo_Domingo')::date as desde,
  (max(c.created_at) at time zone 'America/Santo_Domingo')::date as hasta
from public.inventory_cost_consumptions c
join public.inventory_items ii on ii.id = c.item_id
join public.warehouses w on w.id = c.warehouse_id
where c.is_shortfall
  and c.quantity > c.quantity_returned
  and c.business_id = '35c5076a-bd85-4a1b-8d1c-ce719c4f9ae6'
group by ii.sku, ii.name, ii.unit, w.name
order by round(sum((c.quantity - c.quantity_returned) * c.unit_cost), 2) desc;
