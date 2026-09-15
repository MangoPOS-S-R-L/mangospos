-- =============================================================================
-- VERIFICAR 20260915_0002 (consumo unificado) — SOLO LECTURA
--
-- Después de reemplazar la función que descuenta inventario en cada venta, lo
-- que importa es que las ventas SIGAN descontando. Si la función fallara, la
-- POS no podría guardar renglones (los triggers la llaman en la misma
-- transacción); si no descontara, las órdenes quedarían sin movimientos.
-- Correr cada bloque por separado.
-- =============================================================================

-- 1) La viva es la unificada, sin copias, y el trigger de anulación está.
select
  (select pg_get_functiondef(p.oid) like '%UNIFICADA 20260915_0002%'
     from pg_proc p join pg_namespace n on n.oid = p.pronamespace
    where n.nspname = 'public' and p.proname = 'consume_inventory_from_order'
    limit 1)                                                    as es_unificada,
  (select count(*) from pg_proc p join pg_namespace n on n.oid = p.pronamespace
    where n.nspname = 'public' and p.proname = 'consume_inventory_from_order') as copias,
  exists (select 1 from pg_trigger
           where tgname = 'trg_orders_reconcile_inventory_on_status'
             and not tgisinternal)                               as trigger_anulacion;


-- 2) La Penda, últimas 3 horas: órdenes con productos inventariables y cuántas
--    ya tienen su movimiento de venta. Tienen que coincidir (salvo alguna que
--    se esté tomando justo ahora).
with ordenes as (
  select o.id
    from public.orders o
    join public.table_sessions ts on ts.id = o.session_id
   where ts.business_id = '35c5076a-bd85-4a1b-8d1c-ce719c4f9ae6'
     and o.created_at > now() - interval '3 hours'
     and exists (
       select 1
         from public.order_items oi
         join public.menu_items mi on mi.id = oi.product_id
        where oi.order_id = o.id
          and oi.status <> 'void'
          and coalesce(mi.is_inventory_tracked, false))
)
select count(*)                                                        as ordenes_con_inventariables,
       count(*) filter (where exists (
         select 1 from public.inventory_movements im
          where im.reference_id = ordenes.id
            and im.reference_type = 'order'))                          as con_movimiento,
       count(*) filter (where not exists (
         select 1 from public.inventory_movements im
          where im.reference_id = ordenes.id
            and im.reference_type = 'order'))                          as sin_movimiento
  from ordenes;


-- 3) Todos los negocios, última hora: movimientos que escribió la función, por
--    tipo de nota. «Auto-consumo por venta» tiene que seguir apareciendo.
select b.business_name,
       im.notes,
       count(*)            as movimientos,
       max(im.created_at)  as el_ultimo
  from public.inventory_movements im
  join public.businesses b on b.id = im.business_id
 where im.reference_type = 'order'
   and im.created_at > now() - interval '1 hour'
 group by b.business_name, im.notes
 order by el_ultimo desc
 limit 30;


-- 4) La Penda, últimas 3 horas: de qué bodega sale lo vendido. Con Principal y
--    FoodShop marcadas para la POS, primero descuenta Principal y, cuando se
--    acaba, FoodShop. Cocina y Bar no deberían aparecer mientras
--    warehouse_sections_enabled siga en false.
select w.name as bodega,
       count(*) as movimientos,
       sum(-im.quantity) as unidades_descontadas
  from public.inventory_movements im
  join public.warehouses w on w.id = im.warehouse_id
 where im.business_id = '35c5076a-bd85-4a1b-8d1c-ce719c4f9ae6'
   and im.reference_type = 'order'
   and im.created_at > now() - interval '3 hours'
 group by w.name
 order by movimientos desc;
