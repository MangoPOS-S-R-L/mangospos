-- =============================================================================
-- LA PENDA EXPRESS · COMPRAS — PASO 0: ¿qué compras NO entraron al inventario?
-- business_id = 35c5076a-bd85-4a1b-8d1c-ce719c4f9ae6
--
-- SOLO LECTURA. Una fila por orden de compra desde el 1-sep, con lo que la
-- orden dice que entró y lo que de verdad llegó al kardex (inventory_movements
-- tipo 'purchase' ligados a la orden por cualquiera de sus caminos:
-- recepción vieja, recepción parcial, conduce v2, corrección y anulación).
--
-- estado_inv:
--   NO ENTRÓ     → la orden no movió stock (borrador/enviada sin recibir, o
--                  recibida sin movimientos)
--   PARCIAL      → entró menos de lo pedido
--   ENTRÓ        → entró todo lo pedido
--   ANULADA      → orden cancelada (lo que entró ya se devolvió)
--   SIN INSUMO   → hay renglones sin inventory_item_id: esos nunca mueven stock
--
-- vs_conteo: la compra se registró ANTES o DESPUÉS del conteo del 1-oct
-- (terminó 01-oct 15:12). Lo de ANTES que no entró probablemente ya está
-- dentro de lo contado: cargarlo ahora lo duplicaría.
-- =============================================================================

with biz as (
  select '35c5076a-bd85-4a1b-8d1c-ce719c4f9ae6'::uuid as id
),
po as (
  select o.*
    from public.purchase_orders o, biz
   where o.business_id = biz.id
     and o.created_at >= timestamptz '2026-09-01 00:00 America/Santo_Domingo'
),
lines as (
  select poi.purchase_order_id,
         count(*)                                              as n_lineas,
         count(*) filter (where poi.inventory_item_id is null) as sin_insumo,
         sum(poi.quantity_ordered)                             as pedido,
         sum(coalesce(poi.quantity_received, 0))               as recibido_segun_orden,
         sum(poi.quantity_ordered * poi.unit_cost)             as valor_pedido
    from public.purchase_order_items poi
   where poi.purchase_order_id in (select id from po)
   group by poi.purchase_order_id
),
movs as (
  -- recepción vieja / parcial / anulación: reference_id = la orden
  select m.reference_id as po_id, m.quantity, m.cost_per_unit
    from public.inventory_movements m
   where m.reference_type in ('purchase_order', 'purchase_order_cancel')
     and m.reference_id in (select id from po)
  union all
  -- corrección y renglón: reference_id = el renglón de la orden
  select poi.purchase_order_id, m.quantity, m.cost_per_unit
    from public.inventory_movements m
    join public.purchase_order_items poi on poi.id = m.reference_id
   where m.reference_type in ('purchase_order_item', 'purchase_order_edit',
                              'purchase_order_edit_reversal')
     and poi.purchase_order_id in (select id from po)
  union all
  -- conduce v2: reference_id = la línea de la recepción
  select pr.purchase_order_id, m.quantity, m.cost_per_unit
    from public.inventory_movements m
    join public.purchase_reception_lines prl on prl.id = m.reference_id
    join public.purchase_receptions pr on pr.id = prl.reception_id
   where m.reference_type = 'purchase_reception_line'
     and pr.purchase_order_id in (select id from po)
),
kardex as (
  select po_id,
         count(*)                                         as n_movs,
         sum(quantity)                                    as entro,
         sum(quantity * coalesce(cost_per_unit, 0))       as valor_entro
    from movs
   group by po_id
)
select
  case
    when po.status = 'cancelled'                     then 'ANULADA'
    when coalesce(l.sin_insumo, 0) > 0
         and coalesce(k.entro, 0) = 0                then 'SIN INSUMO'
    when coalesce(k.entro, 0) <= 0                   then 'NO ENTRÓ'
    when k.entro < l.pedido - 0.0001                 then 'PARCIAL'
    else                                                  'ENTRÓ'
  end                                                       as estado_inv,
  case when po.created_at < timestamptz '2026-10-01 15:12 America/Santo_Domingo'
       then 'ANTES' else 'DESPUÉS' end                      as vs_conteo,
  po.order_number                                           as orden,
  coalesce(nullif(po.ncf, ''), po.invoice_number)           as factura,
  s.name                                                    as suplidor,
  w.name                                                    as almacen,
  po.status::text                                           as estado_orden,
  to_char(po.created_at at time zone 'America/Santo_Domingo',
          'DD-Mon HH24:MI')                                 as registrada,
  po.received_date                                          as fecha_recibida,
  l.n_lineas                                                as lineas,
  l.sin_insumo                                              as lineas_sin_insumo,
  round(l.pedido, 2)                                        as unidades_pedidas,
  round(coalesce(k.entro, 0), 2)                            as unidades_entraron,
  round(po.total, 2)                                        as total_orden,
  round(coalesce(k.valor_entro, 0), 2)                      as valor_entro,
  (select string_agg(coalesce(p.full_name, p.email, ''), ', ')
     from public.profiles p where p.id = po.created_by)     as registrada_por,
  po.id                                                     as purchase_order_id
from po
left join lines l on l.purchase_order_id = po.id
left join kardex k on k.po_id = po.id
left join public.suppliers  s on s.id = po.supplier_id
left join public.warehouses w on w.id = po.warehouse_id
order by
  case
    when po.status = 'cancelled'            then 5
    when coalesce(k.entro, 0) <= 0          then 1
    when k.entro < l.pedido - 0.0001        then 2
    else 4
  end,
  po.created_at desc;
