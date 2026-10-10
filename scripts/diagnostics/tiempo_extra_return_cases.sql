-- Tiempo Extra: las cuatro órdenes con devoluciones del resultado recibido.
-- SOLO LECTURA. Ejecutar cada bloque POR SEPARADO en Supabase SQL Editor.
-- Los estados y existencias son ACTUALES; las fechas permiten reconstruir
-- la secuencia. No se presume que una devolución fue causada por un pago.

-- 0. Comprobar si existen la auditoría y la vista de stock para los bloques 2 y 3.
select to_regclass('public.order_item_removals') is not null as tiene_auditoria,
       to_regclass('public.v_menu_items_stock') is not null as tiene_vista_stock_pos;

-- 1. Órdenes, renglones actuales, pagos, movimientos y consumo neto.
-- Incluye merma: una entrada sale +1 seguida de waste -1 NO repone stock.
-- Los netos usan todo el historial de estas órdenes, sin corte de fechas.
with parametros as (
  select '1eee0122-3181-496c-969e-0a0c06448932'::uuid as business_id
), objetivos(orden_id, caso) as (
  values
    ('a6e1c6be-a27b-450a-971d-794f29c58ad6'::uuid, '08 oct: devolución de queso; orden anulada'),
    ('17c71afe-1c56-414b-9fa7-b731e0934858'::uuid, '07 oct: devolución de queso antes del cierre'),
    ('1fd9a1d3-c787-409b-9131-3e93a97a3ff7'::uuid, '05 oct: devolución de jamón antes del cierre'),
    ('b729ab5f-2582-49b8-a0b3-a7f3c71c244a'::uuid, '03 oct: crema devuelta; después sale pollo con queso')
), ordenes as materialized (
  select o.*, ts.origin::text as origen
  from objetivos x
  join public.orders o on o.id = x.orden_id
  join public.table_sessions ts on ts.id = o.session_id
  join parametros p on ts.business_id = p.business_id
), movimientos as materialized (
  select im.*
  from objetivos x
  join public.inventory_movements im on im.reference_id = x.orden_id
  join parametros p on im.business_id = p.business_id
  where im.reference_type in ('order', 'order_item_removal')
), netos as (
  select im.reference_id as orden_id, im.item_id, im.warehouse_id,
    coalesce(-sum(im.quantity) filter (where im.movement_type::text = 'sale'), 0) as consumo_venta_neto,
    coalesce(-sum(im.quantity) filter (where im.movement_type::text = 'waste'), 0) as consumo_merma_neto,
    -sum(im.quantity) as consumo_total_neto
  from movimientos im
  group by im.reference_id, im.item_id, im.warehouse_id
), netos_por_orden as (
  select n.orden_id,
    jsonb_agg(jsonb_build_object(
      'item_id', n.item_id, 'inventariable', ii.name, 'unidad', ii.unit,
      'warehouse_id', n.warehouse_id, 'bodega', w.name,
      'consumo_venta_neto', n.consumo_venta_neto,
      'consumo_merma_neto', n.consumo_merma_neto,
      'consumo_total_neto', n.consumo_total_neto,
      'existencia_actual_bodega', stock.quantity
    ) order by ii.name, n.item_id, w.name, n.warehouse_id) as netos
  from netos n
  left join public.inventory_items ii on ii.id = n.item_id
  left join public.warehouses w on w.id = n.warehouse_id
  left join lateral (
    select sum(s.quantity) as quantity from public.inventory_stock s
    where s.item_id = n.item_id and s.warehouse_id = n.warehouse_id
  ) stock on true
  group by n.orden_id
), cronologia as (
  select im.reference_id as orden_id,
    jsonb_agg(jsonb_build_object(
      'fecha_rd', im.created_at at time zone 'America/Santo_Domingo',
      'movimiento_id', im.id, 'tipo', im.movement_type::text,
      'referencia_tipo', im.reference_type, 'item_id', im.item_id,
      'inventariable', ii.name, 'bodega', w.name,
      'quantity', im.quantity, 'notes', im.notes
    ) order by im.created_at, im.id) as movimientos
  from movimientos im
  left join public.inventory_items ii on ii.id = im.item_id
  left join public.warehouses w on w.id = im.warehouse_id
  group by im.reference_id
), renglones as (
  select oi.order_id,
    jsonb_agg(jsonb_build_object(
      'renglon_id', oi.id, 'product_id', oi.product_id,
      'producto', coalesce(mi.name, oi.product_name), 'status', oi.status::text,
      'qty', oi.qty, 'quantity', oi.quantity,
      'creado_rd', oi.created_at at time zone 'America/Santo_Domingo',
      'kitchen_sent_at', to_jsonb(oi)->>'kitchen_sent_at',
      'notes', oi.notes
    ) order by oi.created_at, oi.id) as items_actuales
  from ordenes o join public.order_items oi on oi.order_id = o.id
  left join public.menu_items mi on mi.id = oi.product_id
  group by oi.order_id
), pagos as (
  select pay.order_id,
    jsonb_agg(jsonb_build_object(
      'pago_id', pay.id, 'fecha_rd', pay.created_at at time zone 'America/Santo_Domingo',
      'status', pay.status, 'amount', pay.amount, 'check_id', pay.check_id
    ) order by pay.created_at, pay.id) as pagos
  from ordenes o join public.payments pay on pay.order_id = o.id
  join parametros p on pay.business_id = p.business_id
  group by pay.order_id
)
select x.caso, x.orden_id, o.id is not null as orden_encontrada_en_negocio,
  o.session_id, o.origen, o.status as estado_actual,
  o.status_ext::text as estado_ext_actual,
  o.created_at at time zone 'America/Santo_Domingo' as creada_rd,
  o.closed_at at time zone 'America/Santo_Domingo' as cierre_rd,
  coalesce(r.items_actuales, '[]'::jsonb) as items_actuales,
  coalesce(p.pagos, '[]'::jsonb) as pagos,
  coalesce(n.netos, '[]'::jsonb) as netos_por_insumo_y_bodega,
  coalesce(c.movimientos, '[]'::jsonb) as movimientos
from objetivos x
left join ordenes o on o.id = x.orden_id
left join renglones r on r.order_id = x.orden_id
left join pagos p on p.order_id = x.orden_id
left join netos_por_orden n on n.orden_id = x.orden_id
left join cronologia c on c.orden_id = x.orden_id
order by x.caso;

-- 2. Ejecutar SOLO si tiene_auditoria = true en el bloque 0.
-- La auditoría puede omitir borrados de renglones draft o reducciones
-- internas: un resultado vacío no prueba que no hubo edición/borrado.
select r.order_id as orden_id, r.item_id as renglon_id,
  r.removed_at at time zone 'America/Santo_Domingo' as eliminada_rd,
  r.change_type, r.product_name as producto, r.quantity, r.qty_before, r.qty_after,
  r.item_status, r.reason as motivo, r.is_user_action, r.request_path,
  to_jsonb(r)->>'reason_code' as reason_code,
  to_jsonb(r)->>'is_waste' as es_merma,
  to_jsonb(r)->>'waste_booked' as merma_contabilizada
from public.order_item_removals r
where r.business_id = '1eee0122-3181-496c-969e-0a0c06448932'::uuid
  and r.order_id in (
    'a6e1c6be-a27b-450a-971d-794f29c58ad6'::uuid,
    '17c71afe-1c56-414b-9fa7-b731e0934858'::uuid,
    '1fd9a1d3-c787-409b-9131-3e93a97a3ff7'::uuid,
    'b729ab5f-2582-49b8-a0b3-a7f3c71c244a'::uuid
  )
order by r.order_id, r.removed_at, r.id;

-- 3. Ejecutar SOLO si tiene_vista_stock_pos = true en el bloque 0.
-- Es la misma vista que lee el número de stock del catálogo de la POS.
-- Comparar stock_servidor con la pantalla en el mismo momento.
-- NULL indica que la vista no entrega cantidad para ese producto.
with productos as materialized (
  select mi.*
  from public.menu_items mi
  where mi.business_id = '1eee0122-3181-496c-969e-0a0c06448932'::uuid
    and mi.name ilike '%empanad%'
  order by mi.name, mi.id
  limit 20
)
select now() at time zone 'America/Santo_Domingo' as consulta_rd,
  mi.id as producto_id, mi.name as producto,
  to_jsonb(mi)->>'is_inventory_tracked' as inventariable,
  coalesce(to_jsonb(bs)->>'inventory_mode', 'none') as modo_inventario,
  s.available_units as stock_servidor
from productos mi
left join public.business_settings bs on bs.business_id = mi.business_id
left join public.v_menu_items_stock s on s.menu_item_id = mi.id
order by mi.name, mi.id;
