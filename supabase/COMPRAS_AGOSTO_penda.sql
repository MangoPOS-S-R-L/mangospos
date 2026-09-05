-- =============================================================================
-- LA PENDA EXPRESS — todas las compras de AGOSTO 2026, insumo por insumo
-- business_id = 35c5076a-bd85-4a1b-8d1c-ce719c4f9ae6
--
-- POR QUÉ ESTA ES LA FUENTE CORRECTA DEL COSTO: una factura es un hecho, un
-- costo derivado de un «hermano» del catálogo es una estimación. Con las
-- compras del mes el costo de cada insumo sale de plata que de verdad se pagó,
-- y si un auditor pregunta, la respuesta es una orden de compra con fecha y
-- proveedor.
--
-- DATO IMPORTANTE: en `purchase_order_items`, `quantity_ordered` y `unit_cost`
-- se guardan YA EN UNIDAD BASE (`purchase_unit` y `pack_size` son solo
-- snapshots para mostrar — así lo dice la migración 20260608_0002). O sea que
-- el `unit_cost` de una compra entra DIRECTO a `inventory_items.cost`, sin
-- convertir nada.
--
-- La fecha que manda es la de RECEPCIÓN, no la de la orden: la política del
-- negocio es que el costo maestro se mueve AL RECIBIR. Donde no haya
-- `received_date` se usa la fecha de creación.
--
-- CORRER UNA SENTENCIA A LA VEZ.
-- =============================================================================

-- ---------------------------------------------------------------------------
-- 1. EL MES DE UN VISTAZO — cuántas órdenes hubo y en qué estado.
--
--    Las `draft` y `sent` NO entraron al inventario todavía, así que su costo
--    es una intención, no un hecho. Para costear sirven las `received` y las
--    `partial`.
-- ---------------------------------------------------------------------------
select
  po.status,
  count(*)                                   as ordenes,
  count(distinct po.supplier_id)             as proveedores,
  round(sum(coalesce(po.total, 0)), 2)       as total_rd,
  min(coalesce(po.received_date, po.created_at::date)) as desde,
  max(coalesce(po.received_date, po.created_at::date)) as hasta
from public.purchase_orders po
where po.business_id = '35c5076a-bd85-4a1b-8d1c-ce719c4f9ae6'
  and coalesce(po.received_date, po.created_at::date)
      between date '2026-08-01' and date '2026-08-31'
group by po.status
order by 4 desc nulls last;


-- ---------------------------------------------------------------------------
-- 2. TODOS LOS INSUMOS COMPRADOS EN AGOSTO — con su costo.
--
--    Una fila por insumo. `ultimo_costo` es el de la compra más reciente del
--    mes, que es el que debería quedar como costo maestro (política: último
--    precio de compra, no promedio).
--
--    `costo_maestro_hoy` al lado para ver de un golpe cuáles están
--    desactualizados o en cero.
-- ---------------------------------------------------------------------------
with lineas as (
  select
    poi.inventory_item_id                    as item_id,
    poi.unit_cost,
    poi.quantity_ordered,
    poi.quantity_received,
    coalesce(po.received_date, po.created_at::date) as fecha,
    po.status,
    po.order_number,
    po.supplier_id,
    row_number() over (
      partition by poi.inventory_item_id
      order by coalesce(po.received_date, po.created_at::date) desc,
               po.created_at desc)           as rn
  from public.purchase_order_items poi
  join public.purchase_orders po on po.id = poi.purchase_order_id
  where po.business_id = '35c5076a-bd85-4a1b-8d1c-ce719c4f9ae6'
    and poi.inventory_item_id is not null
    and coalesce(po.received_date, po.created_at::date)
        between date '2026-08-01' and date '2026-08-31'
)
select
  i.name                                     as insumo,
  i.unit                                     as unidad,
  round(l.unit_cost, 2)                      as ultimo_costo,
  round(coalesce(i.cost, 0), 2)              as costo_maestro_hoy,
  case
    when coalesce(i.cost, 0) = 0                       then '⚠️ maestro en CERO'
    when abs(coalesce(i.cost,0) - l.unit_cost) < 0.01  then 'igual'
    when coalesce(i.cost,0) > l.unit_cost              then 'maestro MÁS ALTO'
    else                                                    'maestro más bajo'
  end                                        as vs_maestro,
  l.fecha                                    as ultima_compra,
  l.status,
  l.order_number,
  s.name                                     as proveedor,
  (select round(sum(x.quantity_ordered), 4) from lineas x
    where x.item_id = l.item_id)             as comprado_en_agosto,
  (select count(*) from lineas x
    where x.item_id = l.item_id)             as veces,
  i.id
from lineas l
join public.inventory_items i on i.id = l.item_id
left join public.suppliers s on s.id = l.supplier_id
where l.rn = 1
order by i.name;


-- ---------------------------------------------------------------------------
-- 3. EL CRUCE QUE IMPORTA — de lo que se contó en cocina, ¿qué tiene compra
--    de agosto y qué no?
--
--    Los que salgan con `costo_de_agosto` son los que se pueden costear con
--    un documento. Los que salgan sin nada hay que preguntarlos.
-- ---------------------------------------------------------------------------
with agosto as (
  select distinct on (poi.inventory_item_id)
    poi.inventory_item_id                    as item_id,
    poi.unit_cost,
    coalesce(po.received_date, po.created_at::date) as fecha,
    po.order_number,
    po.status
  from public.purchase_order_items poi
  join public.purchase_orders po on po.id = poi.purchase_order_id
  where po.business_id = '35c5076a-bd85-4a1b-8d1c-ce719c4f9ae6'
    and poi.inventory_item_id is not null
    and coalesce(po.received_date, po.created_at::date)
        between date '2026-08-01' and date '2026-08-31'
  order by poi.inventory_item_id,
           coalesce(po.received_date, po.created_at::date) desc,
           po.created_at desc
)
select
  i.name                                     as insumo,
  i.unit                                     as unidad,
  l.counted_quantity                         as contado,
  round(coalesce(i.cost, 0), 2)              as costo_maestro,
  round(a.unit_cost, 2)                      as costo_de_agosto,
  a.fecha,
  a.order_number,
  round(l.counted_quantity * coalesce(a.unit_cost, i.cost, 0), 2) as valor_con_agosto,
  case
    when a.item_id is null and coalesce(i.cost,0) = 0
      then '❌ sin costo y sin compra — hay que preguntar'
    when a.item_id is null
      then 'sin compra en agosto (usa el maestro)'
    when coalesce(i.cost,0) = 0
      then '✅ se puede costear con la compra'
    when abs(coalesce(i.cost,0) - a.unit_cost) >= 0.01
      then '⚠️ el maestro difiere de la compra'
    else 'ok'
  end                                        as estado,
  i.id
from public.physical_count_lines l
join public.physical_count_sessions s on s.id = l.session_id
join public.inventory_items i on i.id = l.item_id
left join agosto a on a.item_id = i.id
where s.business_id = '35c5076a-bd85-4a1b-8d1c-ce719c4f9ae6'
  and s.code = 'PC-2026-000003'
  and l.counted_quantity is not null
  and l.counted_quantity > 0
order by
  (case when a.item_id is null and coalesce(i.cost,0) = 0 then 0
        when coalesce(i.cost,0) = 0 then 1
        else 2 end),
  l.counted_quantity * coalesce(a.unit_cost, i.cost, 0) desc;


-- ---------------------------------------------------------------------------
-- 4. EL DETALLE DE CADA ORDEN — por si hay que ir a buscar una factura.
-- ---------------------------------------------------------------------------
select
  po.order_number,
  coalesce(po.received_date, po.created_at::date) as fecha,
  po.status,
  s.name                                     as proveedor,
  i.name                                     as insumo,
  i.unit                                     as unidad_base,
  poi.purchase_unit                          as se_compro_en,
  poi.pack_size                              as contenido,
  poi.quantity_ordered                       as cant_base,
  poi.quantity_received                      as recibido_base,
  round(poi.unit_cost, 2)                    as costo_unitario_base,
  round(poi.total, 2)                        as total_linea
from public.purchase_order_items poi
join public.purchase_orders po on po.id = poi.purchase_order_id
left join public.inventory_items i on i.id = poi.inventory_item_id
left join public.suppliers s on s.id = po.supplier_id
where po.business_id = '35c5076a-bd85-4a1b-8d1c-ce719c4f9ae6'
  and coalesce(po.received_date, po.created_at::date)
      between date '2026-08-01' and date '2026-08-31'
order by po.created_at desc, i.name;


-- ---------------------------------------------------------------------------
-- 5. ¿HAY COMPRAS FUERA DE AGOSTO? — por si el mes sale flaco.
--
--    Si agosto trae pocas órdenes, esto dice si el negocio registra las
--    compras en el sistema o las lleva por fuera. Con eso se sabe si vale la
--    pena ampliar la ventana o si hay que ir a las facturas en papel.
-- ---------------------------------------------------------------------------
with ordenes as (
  select
    po.id,
    to_char(coalesce(po.received_date, po.created_at::date), 'YYYY-MM') as mes,
    coalesce(po.total, 0) as total
  from public.purchase_orders po
  where po.business_id = '35c5076a-bd85-4a1b-8d1c-ce719c4f9ae6'
),
lineas as (
  select o.mes, poi.inventory_item_id
  from ordenes o
  join public.purchase_order_items poi on poi.purchase_order_id = o.id
)
select
  o.mes,
  count(*)                                          as ordenes,
  (select count(distinct l.inventory_item_id) from lineas l
    where l.mes = o.mes)                            as insumos_distintos,
  round(sum(o.total), 2)                            as total_rd
from ordenes o
group by o.mes
order by o.mes desc
limit 12;
