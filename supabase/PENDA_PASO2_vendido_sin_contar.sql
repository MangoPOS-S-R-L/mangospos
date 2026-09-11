-- =============================================================================
-- LA PENDA EXPRESS · PASO 2 — Qué se estaba vendiendo que no se contó
-- business_id = 35c5076a-bd85-4a1b-8d1c-ce719c4f9ae6
--
-- SOLO LECTURA.
--
-- Va ANTES de crear almacenes y recetas: si el conteo tiene huecos, todo lo que
-- se construya encima los hereda.
--
--   >>> PON LA FECHA DE CORTE que salió en el paso 1 (columna `congelado`). <<<
--       Está en las 4 consultas, al inicio de cada una.
-- =============================================================================


-- A ─── LO PRINCIPAL: productos vendidos que NO descuentan nada ───────────────
--     Sin receta y sin producto terminado directo = la venta es invisible para
--     el inventario. Ordenado por unidades, que es el orden en que conviene
--     crear las recetas.
with params as (
  select '35c5076a-bd85-4a1b-8d1c-ce719c4f9ae6'::uuid as biz,
         timestamptz '2026-09-01 00:00:00-04'          as corte   -- <<< CAMBIAR
),
vendidos as (
  select oi.product_id,
         sum(oi.quantity)              as unidades,
         round(sum(oi.subtotal), 2)    as venta,
         count(*)                      as veces
  from public.order_items oi
  join public.orders o          on o.id = oi.order_id
  join public.table_sessions ts on ts.id = o.session_id
  cross join params p
  where ts.business_id = p.biz
    and oi.status <> 'void'
    and oi.created_at >= p.corte
    and oi.product_id is not null
  group by oi.product_id
)
select
  m.name                                        as producto,
  c.name                                        as categoria,
  v.unidades, v.venta, v.veces,
  m.is_inventory_tracked                        as marcado_inventariable,
  (m.inventory_item_id is not null)             as tiene_insumo_directo,
  (r.id is not null)                            as tiene_receta,
  coalesce(ri.n, 0)                             as ingredientes
from vendidos v
join public.menu_items m on m.id = v.product_id
left join public.categories c on c.id = m.category_id
left join public.recipes r on r.menu_item_id = m.id
left join lateral (select count(*) n from public.recipe_ingredients z where z.recipe_id = r.id) ri on true
where r.id is null                      -- sin receta
  and m.inventory_item_id is null       -- y sin insumo directo
order by v.unidades desc;


-- B ─── El resumen de A: cuánto del volumen queda sin descontar ───────────────
with params as (
  select '35c5076a-bd85-4a1b-8d1c-ce719c4f9ae6'::uuid as biz,
         timestamptz '2026-09-01 00:00:00-04'          as corte   -- <<< CAMBIAR
),
vendidos as (
  select oi.product_id, sum(oi.quantity) as unidades, sum(oi.subtotal) as venta
  from public.order_items oi
  join public.orders o          on o.id = oi.order_id
  join public.table_sessions ts on ts.id = o.session_id
  cross join params p
  where ts.business_id = p.biz and oi.status <> 'void'
    and oi.created_at >= p.corte and oi.product_id is not null
  group by oi.product_id
),
clas as (
  select v.*,
    case when m.inventory_item_id is not null then 'insumo directo'
         when r.id is not null                then 'con receta'
         else                                      'SIN DESCUENTO' end as estado
  from vendidos v
  join public.menu_items m on m.id = v.product_id
  left join public.recipes r on r.menu_item_id = m.id
)
select estado,
       count(*)                                                  as productos,
       round(sum(unidades), 0)                                   as unidades,
       round(sum(venta), 2)                                      as venta,
       round(100.0 * sum(venta) / sum(sum(venta)) over (), 1)     as pct_de_la_venta
from clas
group by estado
order by venta desc;


-- C ─── Insumos que ENTRARON por compra pero no están en el conteo ────────────
--     Se recibió mercancía de algo que nadie contó.
with params as (
  select '35c5076a-bd85-4a1b-8d1c-ce719c4f9ae6'::uuid as biz,
         timestamptz '2026-09-01 00:00:00-04'          as corte   -- <<< CAMBIAR
),
contados as (
  select distinct l.item_id
  from public.physical_count_lines l
  join public.physical_count_sessions s on s.id = l.session_id
  cross join params p
  where s.business_id = p.biz
),
comprado as (
  select poi.inventory_item_id as item_id,
         round(sum(coalesce(poi.quantity_received, 0)), 2) as recibido,
         count(distinct po.id)                             as ordenes,
         max(po.received_date)                             as ultima_compra
  from public.purchase_order_items poi
  join public.purchase_orders po on po.id = poi.purchase_order_id
  cross join params p
  where po.business_id = p.biz
    and coalesce(poi.quantity_received, 0) > 0
    and coalesce(po.received_date, po.created_at::date) >= p.corte::date
  group by poi.inventory_item_id
)
select i.name as insumo, i.unit, i.cost,
       cp.recibido, cp.ordenes, cp.ultima_compra
from comprado cp
join public.inventory_items i on i.id = cp.item_id
where cp.item_id not in (select item_id from contados)
order by cp.recibido desc;


-- D ─── Líneas del conteo que quedaron SIN CONTAR pero sí tienen movimiento ───
--     Nadie las pesó, pero el insumo se mueve. Son las más urgentes de contar:
--     si se cargan como 0, se declara cero stock de algo que sí existe.
with params as (
  select '35c5076a-bd85-4a1b-8d1c-ce719c4f9ae6'::uuid as biz
),
sin_contar as (
  select l.item_id, s.code as sesion
  from public.physical_count_lines l
  join public.physical_count_sessions s on s.id = l.session_id
  cross join params p
  where s.business_id = p.biz
    and l.counted_quantity is null
),
con_movimiento as (
  select m.item_id, count(*) movs, max(m.created_at) ultimo
  from public.inventory_movements m
  cross join params p
  where m.business_id = p.biz
  group by m.item_id
)
select i.name as insumo, i.unit, sc.sesion, cm.movs,
       (cm.ultimo at time zone 'America/Santo_Domingo')::date as ultimo_movimiento
from sin_contar sc
join con_movimiento cm on cm.item_id = sc.item_id
join public.inventory_items i on i.id = sc.item_id
order by cm.movs desc
limit 100;
