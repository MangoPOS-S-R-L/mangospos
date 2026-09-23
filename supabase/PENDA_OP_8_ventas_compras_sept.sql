-- =============================================================================
-- LA PENDA EXPRESS · OPERACIÓN INVENTARIO — PASO 8: ventas y compras de sept.
-- business_id = 35c5076a-bd85-4a1b-8d1c-ce719c4f9ae6
--
-- SOLO LECTURA. UNA sola consulta. No escribe nada.
--
-- PARA QUÉ: ver la magnitud antes de ejecutar. Cuánto se vendió, cuánto se
-- compró, y —lo importante— cuánto de lo vendido NO descontó nada.
--
-- LA VENTANA es desde el congelado del conteo (1-sep) hasta ahora, la misma
-- que va a reaplicar el rollforward. Así los números cuadran entre los dos.
--
-- CÓMO LEER `descuenta`:
--   RECETA    el producto tiene receta → descuenta ingredientes
--   DIRECTO   tiene `inventory_item_id` y no receta → se descuenta a sí mismo
--   NO        el inventario está apagado, o está prendido pero sin receta ni
--             vínculo → **no descuenta nada**. Esto es el hueco: son las
--             ventas de cocina de septiembre que nadie descontó.
--
-- H4 es el contraste que importa: las unidades vendidas que SÍ movieron
-- inventario contra las que no. El rollforward solo puede reaplicar las
-- primeras; las segundas no se recuperan cargando recetas ahora.
-- =============================================================================

with
biz as (select '35c5076a-bd85-4a1b-8d1c-ce719c4f9ae6'::uuid as id),

corte as (
  select coalesce(
           min(coalesce((to_jsonb(s)->>'frozen_at')::timestamptz,
                        (to_jsonb(s)->>'created_at')::timestamptz)),
           date_trunc('month', now())) as desde
    from public.physical_count_sessions s, biz
   where s.business_id = biz.id and s.status in ('draft','in_progress')
),

-- ventas del periodo, por producto
ventas as (
  select oi.product_id,
         min(oi.product_name)                             as producto,
         sum(coalesce(oi.qty, oi.quantity::numeric, 0))   as unidades,
         sum(coalesce(oi.total, 0))                       as importe,
         count(*)                                         as lineas
    from public.order_items oi
    join public.orders o          on o.id = oi.order_id
    join public.table_sessions ts on ts.id = o.session_id
   cross join biz
   cross join corte c
   where ts.business_id = biz.id
     and oi.status <> 'void'
     and oi.created_at >= c.desde
     and oi.product_id is not null
   group by oi.product_id
),

-- ¿ese producto descuenta inventario hoy?
clasif as (
  select v.*,
         case
           when not coalesce(m.is_inventory_tracked, false)            then 'NO'
           when exists (select 1 from public.recipes r
                         where r.menu_item_id = v.product_id)           then 'RECETA'
           when m.inventory_item_id is not null                         then 'DIRECTO'
           else 'NO'
         end as descuenta,
         m.name as nombre_menu
    from ventas v
    left join public.menu_items m on m.id = v.product_id
),

-- compras del periodo, por insumo
compras as (
  select im.item_id,
         min(i.name)                          as insumo,
         min(i.unit)                          as unidad,
         sum(im.quantity)                     as unidades,
         sum(im.quantity * im.cost_per_unit)  as importe,
         count(*)                             as veces
    from public.inventory_movements im
    join public.inventory_items i on i.id = im.item_id
   cross join biz
   cross join corte c
   where im.business_id = biz.id
     and im.movement_type = 'purchase'
     and im.created_at >= c.desde
   group by im.item_id
),

h1 as (
  select 1 as orden, 'H1 el periodo' as seccion, dato, valor from (
    select 'desde / hasta' as dato,
           to_char((select desde from corte), 'DD-Mon-YYYY') || '  →  ' ||
           to_char(now(), 'DD-Mon-YYYY') || '   (' ||
           round(extract(epoch from (now() - (select desde from corte)))/86400) ||
           ' días)' as valor
    union all select 'productos distintos vendidos',
           (select count(*)::text from clasif)
    union all select 'unidades vendidas',
           (select trim(to_char(sum(unidades),'FM999,999,990.0')) from clasif)
    union all select 'importe vendido',
           (select trim(to_char(sum(importe),'FM999,999,999.00')) from clasif)
    union all select 'insumos comprados',
           (select count(*)::text from compras)
    union all select 'importe comprado',
           (select trim(to_char(sum(importe),'FM999,999,999.00')) from compras)
  ) x
),

-- ── H2 · EL CONTRASTE: qué descuenta y qué no ───────────────────────────────
h2 as (
  select 2, 'H2 ¿descuenta inventario?', descuenta,
         count(*)                                              || ' productos · ' ||
         trim(to_char(sum(unidades),'FM999,999,990.0'))        || ' unidades · ' ||
         trim(to_char(sum(importe),'FM999,999,999.00'))        || ' vendido'
    from clasif group by descuenta
),

-- ── H3 · los más vendidos que NO descuentan (el hueco, por tamaño) ──────────
h3 as (
  select 3, 'H3 vendido SIN descontar',
         lpad(row_number() over (order by unidades desc)::text, 2, '0') || '. ' || producto,
         trim(to_char(unidades,'FM999,990.0')) || ' unidades · ' ||
         trim(to_char(importe,'FM999,999,990.00')) || ' · ' || lineas || ' líneas'
    from clasif where descuenta = 'NO'
   order by unidades desc
   limit 50
),

-- ── H4 · los más vendidos que SÍ descuentan ─────────────────────────────────
h4 as (
  select 4, 'H4 vendido y descontado',
         lpad(row_number() over (order by unidades desc)::text, 2, '0') || '. ' || producto,
         trim(to_char(unidades,'FM999,990.0')) || ' unidades · ' ||
         trim(to_char(importe,'FM999,999,990.00')) || ' · ' || descuenta
    from clasif where descuenta <> 'NO'
   order by unidades desc
   limit 40
),

-- ── H5 · las compras, por importe ───────────────────────────────────────────
h5 as (
  select 5, 'H5 comprado',
         lpad(row_number() over (order by importe desc nulls last)::text, 2, '0') || '. ' || insumo,
         trim(to_char(unidades,'FM999,999,990.00')) || ' ' || coalesce(unidad,'?') ||
         ' · ' || trim(to_char(importe,'FM999,999,990.00')) ||
         ' · ' || veces || ' compras'
    from compras
   order by importe desc nulls last
   limit 50
)

select seccion, dato, valor from (
  select * from h1 union all select * from h2 union all select * from h3
  union all select * from h4 union all select * from h5
) todo
order by orden, dato;
