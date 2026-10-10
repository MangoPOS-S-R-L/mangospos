-- Diagnóstico de ventas que no descuentan o parecen devolver inventario.
-- SOLO LECTURA: este archivo contiene únicamente SELECT; no llama al motor.
-- Ejecutar CADA BLOQUE por separado en Supabase Studio (muestra el último).
-- Negocio: Tiempo Extra, resuelto por nombre o sucursal; no elige un UUID
-- arbitrario. Bloque 0 permite confirmar las coincidencias antes de continuar.
-- Bloques 2–5: todas las empanadas de esas coincidencias, últimos 7 días.
-- Si el bloque 0 no devuelve filas, buscar el nombre registrado en businesses.
-- Las columnas incorporadas por migraciones se leen con to_jsonb para que
-- una instalación anterior pueda mostrar qué configuración le falta.
-- Las cantidades son unidades BASE de inventario, no necesariamente piezas.
-- Las fechas se muestran en hora de República Dominicana (UTC-4).

-- 0. Identificar Tiempo Extra y sus sucursales. No requiere conocer su UUID.
select
  b.id as business_id,
  b.business_name as negocio,
  to_jsonb(b)->>'branch_name' as sucursal
from public.businesses b
where b.business_name ilike '%tiempo%extra%'
   or (to_jsonb(b)->>'branch_name') ilike '%tiempo%extra%'
order by b.business_name, sucursal, b.id;

-- 1. Versión del motor y disparadores realmente instalados/habilitados.
select
  p.proname as funcion,
  pg_catalog.pg_get_function_identity_arguments(p.oid) as argumentos,
  length(pg_catalog.pg_get_functiondef(p.oid)) as largo_definicion,
  md5(pg_catalog.pg_get_functiondef(p.oid)) as md5_definicion,
  pg_catalog.pg_get_functiondef(p.oid) like '%UNIFICADA 20260915_0002%'
    as marca_unificada,
  pg_catalog.pg_get_functiondef(p.oid) like '%fn_resolve_area_warehouse%'
    as usa_resolucion_area,
  pg_catalog.pg_get_functiondef(p.oid) like '%modifier_ingredients%'
    as usa_insumos_modificadores,
  pg_catalog.pg_get_functiondef(p.oid) as definicion
from pg_catalog.pg_proc p
join pg_catalog.pg_namespace n on n.oid = p.pronamespace
where n.nspname = 'public'
  and p.proname in (
    'consume_inventory_from_order', 'fn_order_items_reconcile_inventory',
    'fn_orders_reconcile_inventory_on_status', 'trigger_inventory_on_order_sent',
    'fn_sync_inventory_stock_on_movement', 'fn_pos_stock_warehouses',
    'fn_resolve_area_warehouse', 'fn_close_order_and_table',
    'fn_oi_sync_qty_quantity', 'fn_compute_item_totals'
  )
order by p.proname, argumentos;

-- 1b. D = deshabilitado; O = normal; A = siempre; R = solo réplica.
select
  c.relname as tabla,
  t.tgname as trigger,
  t.tgenabled as habilitacion,
  pg_catalog.pg_get_triggerdef(t.oid, true) as definicion
from pg_catalog.pg_trigger t
join pg_catalog.pg_class c on c.oid = t.tgrelid
join pg_catalog.pg_namespace n on n.oid = c.relnamespace
where n.nspname = 'public'
  and c.relname in ('orders', 'order_items', 'inventory_movements')
  and not t.tgisinternal
order by c.relname, t.tgname;

-- 1c. El badge del catálogo necesita cambios de stock por Realtime.
-- false puede explicar un 5 visible aunque el inventario real ya sea 4.
select
  objetivo.tabla,
  exists (
    select 1 from pg_catalog.pg_publication_tables pt
    where pt.pubname = 'supabase_realtime' and pt.schemaname = 'public'
      and pt.tablename = objetivo.tabla
  ) as publicada_en_supabase_realtime
from (values ('inventory_stock'), ('menu_items')) as objetivo(tabla);

-- 2. Producto → receta/link directo → existencia por bodega.
-- Un link directo con receta existente NO lo consume la versión unificada.
-- Una receta vacía, tracking apagado o inventory_mode=none requiere revisión.
with parametros as (
  select b.id as business_id, '%empanad%'::text as nombre
  from public.businesses b
  where b.business_name ilike '%tiempo%extra%'
     or (to_jsonb(b)->>'branch_name') ilike '%tiempo%extra%'
), productos as (
  select mi.*,
    nullif(to_jsonb(mi)->>'inventory_item_id', '')::uuid as directo_id,
    coalesce((to_jsonb(mi)->>'is_inventory_tracked')::boolean, false) as tracking,
    coalesce(to_jsonb(mi)->>'item_type', 'product') as tipo
  from public.menu_items mi
  cross join parametros p
  where mi.business_id = p.business_id
    and mi.name ilike p.nombre
), enlaces as (
  select mi.id as producto_id, 'receta'::text as ruta,
    ri.inventory_item_id as item_id, ri.quantity as por_unidad
  from productos mi
  join public.recipes r on r.menu_item_id = mi.id
  join public.recipe_ingredients ri on ri.recipe_id = r.id
  union all
  select mi.id, 'directo', mi.directo_id, 1::numeric
  from productos mi
  where mi.directo_id is not null
)
select
  b.business_name as negocio, mi.business_id, mi.id as producto_id,
  mi.name as producto, mi.tracking, mi.tipo, mi.is_active,
  bs.config->>'inventory_mode' as inventory_mode,
  bs.config->>'warehouse_sections_enabled' as areas_habilitadas,
  rc.recetas, rc.ingredientes_validos,
  e.ruta, e.item_id as inventory_item_id, ii.name as inventariable,
  ii.unit as unidad_base, e.por_unidad,
  case
    when not mi.tracking then 'No descuenta: tracking apagado'
    when coalesce(bs.config->>'inventory_mode', 'none') = 'none'
      then 'No descuenta: inventory_mode none o configuración ausente'
    when mi.tipo = 'combo' then 'Combo: revisar componentes y modificadores'
    when e.ruta = 'directo' and rc.recetas > 0
      then 'Link directo omitido por existir receta; revisar sus ingredientes'
    when rc.recetas > 0 and rc.ingredientes_validos = 0
      then 'Receta sin ingredientes positivos: no produce consumo base'
    when e.item_id is null then 'Sin link directo ni ingrediente'
    else 'Ruta base configurada'
  end as revision,
  stock.bodegas
from productos mi
left join public.businesses b on b.id = mi.business_id
left join lateral (
  select to_jsonb(s) as config
  from public.business_settings s where s.business_id = mi.business_id limit 1
) bs on true
left join lateral (
  select count(distinct r.id) as recetas,
    count(ri.id) filter (
      where ri.inventory_item_id is not null and ri.quantity > 0
    ) as ingredientes_validos
  from public.recipes r
  left join public.recipe_ingredients ri on ri.recipe_id = r.id
  where r.menu_item_id = mi.id
) rc on true
left join enlaces e on e.producto_id = mi.id
left join public.inventory_items ii on ii.id = e.item_id
left join lateral (
  select jsonb_agg(jsonb_build_object(
    'bodega_id', w.id, 'bodega', w.name,
    'existencia', coalesce(s.quantity, 0), 'principal', w.is_main,
    'activa', w.is_active, 'shows_in_pos', to_jsonb(w)->>'shows_in_pos',
    'tipo', to_jsonb(w)->>'warehouse_type',
    'area_id', to_jsonb(w)->>'production_area_id'
  ) order by w.is_main desc, w.created_at, w.id) as bodegas
  from public.warehouses w
  left join public.inventory_stock s on s.warehouse_id = w.id and s.item_id = e.item_id
  where w.business_id = mi.business_id
) stock on true
order by b.business_name, mi.name, e.ruta, ii.name;

-- 3. Ventas pagadas recientes: cantidad guardada vs consumo NETO de la orden.
-- El neto suma TODO el historial de esa orden/insumo, también movimientos
-- anteriores a la ventana. Evita tomar una devolución aislada por saldo final.
-- esperado_base excluye combos y NO añade/resta insumos de modificadores.
-- Varios productos pueden compartir un insumo: el neto pertenece a la orden
-- completa; no debe compararse 1:1 con una sola fila si ocurre ese caso.
-- Primero limita a 300 renglones elegibles, ordenados por fecha de la orden.
-- Calcula cada par orden/insumo UNA vez, sobre todo su historial. Una receta
-- con varios insumos expande un renglón; la salida conserva el límite de 300.
with parametros as (
  select b.id as business_id, '%empanad%'::text as nombre,
    now() - interval '7 days' as desde
  from public.businesses b
  where b.business_name ilike '%tiempo%extra%'
     or (to_jsonb(b)->>'branch_name') ilike '%tiempo%extra%'
), productos as (
  select mi.*,
    nullif(to_jsonb(mi)->>'inventory_item_id', '')::uuid as directo_id,
    coalesce((to_jsonb(mi)->>'is_inventory_tracked')::boolean, false) as tracking,
    coalesce(to_jsonb(mi)->>'item_type', 'product') as tipo
  from public.menu_items mi cross join parametros p
  where mi.business_id = p.business_id
    and mi.name ilike p.nombre
), enlaces as (
  select mi.id as producto_id, ri.inventory_item_id as item_id,
    sum(ri.quantity) as por_unidad, 'receta'::text as ruta
  from productos mi
  join public.recipes r on r.menu_item_id = mi.id
  join public.recipe_ingredients ri on ri.recipe_id = r.id
  where ri.inventory_item_id is not null
  group by mi.id, ri.inventory_item_id
  union all
  select mi.id, mi.directo_id, 1::numeric, 'directo'
  from productos mi
  where mi.directo_id is not null
    and not exists (select 1 from public.recipes r where r.menu_item_id = mi.id)
), lineas_elegibles as materialized (
  select oi.*
  from public.order_items oi
  join productos mi on mi.id = oi.product_id
  join public.orders o on o.id = oi.order_id
  join parametros p on p.business_id = mi.business_id
  where (o.status = 'paid' or o.status_ext::text = 'paid' or exists (
    select 1 from public.payments pay
    where pay.order_id = o.id and pay.status = 'completed'
  ))
    and (o.created_at >= p.desde or o.closed_at >= p.desde or exists (
      select 1 from public.inventory_movements im
      where im.reference_id = o.id and im.reference_type = 'order'
        and im.created_at >= p.desde
    ))
  order by o.created_at desc, o.id, oi.id
  limit 300
), pares as materialized (
  select distinct oi.order_id, e.item_id
  from lineas_elegibles oi
  join enlaces e on e.producto_id = oi.product_id
  where e.item_id is not null
), consumos as (
  select p.order_id, p.item_id,
    coalesce(-sum(im.quantity), 0) as consumo_neto_orden_insumo,
    coalesce(-sum(im.quantity) filter (where im.quantity < 0), 0) as salidas,
    coalesce(sum(im.quantity) filter (where im.quantity > 0), 0) as devoluciones,
    max(im.created_at) as ultimo_movimiento
  from pares p
  left join public.inventory_movements im
    on im.reference_id = p.order_id and im.item_id = p.item_id
   and im.reference_type = 'order' and im.movement_type::text = 'sale'
  group by p.order_id, p.item_id
)
select
  mi.business_id, b.business_name as negocio, o.id as orden_id,
  o.created_at at time zone 'America/Santo_Domingo' as orden_fecha_rd,
  o.closed_at at time zone 'America/Santo_Domingo' as cierre_fecha_rd,
  o.status as orden_status, o.status_ext::text as orden_status_ext,
  oi.id as renglon_id, mi.name as producto, oi.status::text as renglon_status,
  oi.qty, oi.quantity,
  coalesce(oi.qty, oi.quantity::numeric, 0) as qty_efectiva_motor,
  coalesce(nullif(oi.qty, 0), oi.quantity::numeric, 0) as qty_si_cero_es_legacy,
  mi.tracking, e.ruta, e.item_id, ii.name as inventariable, ii.unit,
  case when mi.tracking and mi.tipo <> 'combo' and oi.status::text <> 'void'
              and o.status <> 'canceled' and o.status_ext::text <> 'void'
    then greatest(coalesce(oi.qty, oi.quantity::numeric, 0) * coalesce(e.por_unidad, 0), 0)
    else 0 end as esperado_base_sin_modificadores,
  coalesce(mov.consumo_neto_orden_insumo, 0) as consumo_neto_orden_insumo,
  coalesce(mov.salidas, 0) as salidas, coalesce(mov.devoluciones, 0) as devoluciones,
  mov.ultimo_movimiento at time zone 'America/Santo_Domingo' as ultimo_movimiento_rd
from lineas_elegibles oi
join productos mi on mi.id = oi.product_id
join public.orders o on o.id = oi.order_id
left join public.businesses b on b.id = mi.business_id
left join enlaces e on e.producto_id = mi.id
left join public.inventory_items ii on ii.id = e.item_id
left join consumos mov on mov.order_id = o.id and mov.item_id = e.item_id
order by o.created_at desc, o.id, oi.id, ii.name
limit 300;

-- 4. Devoluciones recientes y saldo final por orden/insumo y por bodega.
-- Neto 0 = todo lo consumido fue devuelto; neto > 0 = queda consumo real.
-- Una devolución en una bodega NO implica devolución total: si el neto total
-- conserva consumo, revisar los saldos de otras bodegas y la cronología.
-- Si hay positivos y negativos en el MISMO timestamp que suman 0, hay indicio
-- de redistribución; no prueba qué operación de la app la causó.
-- Selecciona los 200 pares orden/insumo con devolución más reciente ANTES de
-- sumar su historial completo. No es un total de todas las devoluciones.
with parametros as (
  select b.id as business_id, '%empanad%'::text as nombre,
    now() - interval '7 days' as desde
  from public.businesses b
  where b.business_name ilike '%tiempo%extra%'
     or (to_jsonb(b)->>'branch_name') ilike '%tiempo%extra%'
), productos as (
  select mi.id, mi.business_id, mi.name,
    nullif(to_jsonb(mi)->>'inventory_item_id', '')::uuid as directo_id
  from public.menu_items mi cross join parametros p
  where mi.business_id = p.business_id and mi.name ilike p.nombre
), insumos as (
  select business_id, directo_id as item_id from productos where directo_id is not null
  union
  select mi.business_id, ri.inventory_item_id
  from productos mi join public.recipes r on r.menu_item_id = mi.id
  join public.recipe_ingredients ri on ri.recipe_id = r.id
  where ri.inventory_item_id is not null
  union
  select ii.business_id, ii.id from public.inventory_items ii cross join parametros p
  where ii.business_id = p.business_id and ii.name ilike p.nombre
), afectadas as materialized (
  select im.business_id, im.reference_id as orden_id, im.item_id,
    max(im.created_at) as ultima_devolucion
  from public.inventory_movements im
  join insumos i on i.item_id = im.item_id and i.business_id = im.business_id
  cross join parametros p
  where im.business_id = p.business_id
    and im.reference_type = 'order' and im.movement_type::text = 'sale'
    and im.quantity > 0 and im.created_at >= p.desde
  group by im.business_id, im.reference_id, im.item_id
  order by ultima_devolucion desc, im.business_id, im.reference_id, im.item_id
  limit 200
), movimientos_afectados as materialized (
  select im.*
  from afectadas a join public.inventory_movements im
    on im.business_id = a.business_id and im.reference_id = a.orden_id and im.item_id = a.item_id
  where im.reference_type = 'order' and im.movement_type::text = 'sale'
), por_bodega as (
  select im.business_id, im.reference_id as orden_id, im.item_id, im.warehouse_id,
    -sum(im.quantity) as consumo_neto,
    coalesce(-sum(im.quantity) filter (where im.quantity < 0), 0) as salidas,
    coalesce(sum(im.quantity) filter (where im.quantity > 0), 0) as devoluciones,
    max(im.created_at) as ultimo_movimiento
  from movimientos_afectados im
  group by im.business_id, im.reference_id, im.item_id, im.warehouse_id
), totales as (
  select pb.business_id, pb.orden_id, pb.item_id,
    sum(pb.consumo_neto) as consumo_neto_total,
    sum(pb.salidas) as salidas, sum(pb.devoluciones) as devoluciones,
    max(pb.ultimo_movimiento) as ultimo_movimiento,
    jsonb_agg(jsonb_build_object(
      'bodega_id', pb.warehouse_id, 'bodega', w.name,
      'consumo_neto', pb.consumo_neto, 'salidas', pb.salidas, 'devoluciones', pb.devoluciones
    ) order by w.name, pb.warehouse_id) as saldos_por_bodega
  from por_bodega pb left join public.warehouses w on w.id = pb.warehouse_id
  group by pb.business_id, pb.orden_id, pb.item_id
), redistribuciones as (
  select distinct im.business_id, im.reference_id as orden_id, im.item_id
  from movimientos_afectados im
  join parametros p on p.business_id = im.business_id
  where im.created_at >= p.desde
  group by im.business_id, im.reference_id, im.item_id, im.created_at
  having sum(im.quantity) = 0 and min(im.quantity) < 0 and max(im.quantity) > 0
     and count(distinct im.warehouse_id) > 1
), renglones_por_orden as (
  select oi.order_id,
    jsonb_agg(jsonb_build_object(
      'renglon_id', oi.id, 'product_id', oi.product_id,
      'producto', coalesce(mi.name, oi.product_name), 'status', oi.status::text,
      'qty', oi.qty, 'quantity', oi.quantity,
      'qty_efectiva_motor', coalesce(oi.qty, oi.quantity::numeric, 0),
      'qty_si_cero_es_legacy', coalesce(nullif(oi.qty, 0), oi.quantity::numeric, 0),
      'tracking', to_jsonb(mi)->>'is_inventory_tracked',
      'link_directo', to_jsonb(mi)->>'inventory_item_id'
    ) order by oi.id) as items_actuales
  from (select distinct orden_id from afectadas) a
  join public.order_items oi on oi.order_id = a.orden_id
  left join public.menu_items mi on mi.id = oi.product_id
  group by oi.order_id
)
select
  t.business_id, b.business_name as negocio, t.orden_id,
  o.status as orden_status, o.status_ext::text as orden_status_ext,
  o.closed_at at time zone 'America/Santo_Domingo' as cierre_rd,
  t.item_id, ii.name as inventariable, ii.unit,
  t.consumo_neto_total, t.salidas, t.devoluciones,
  case
    when t.consumo_neto_total = 0 then 'Devolución TOTAL del consumo de este insumo'
    when t.consumo_neto_total < 0 then 'Devolvió MÁS de lo consumido: revisar historial'
    else 'Aún hay consumo: devolución parcial o redistribución entre bodegas'
  end as lectura_neto,
  rd.orden_id is not null as indicio_redistribucion_mismo_timestamp,
  t.saldos_por_bodega,
  renglones.items_actuales,
  t.ultimo_movimiento at time zone 'America/Santo_Domingo' as ultimo_movimiento_rd
from totales t
left join public.orders o on o.id = t.orden_id
left join public.businesses b on b.id = t.business_id
left join public.inventory_items ii on ii.id = t.item_id
left join redistribuciones rd
  on rd.business_id = t.business_id and rd.orden_id = t.orden_id and rd.item_id = t.item_id
left join renglones_por_orden renglones on renglones.order_id = t.orden_id
order by t.ultimo_movimiento desc, t.orden_id, ii.name
limit 200;

-- 5. Cronología: movimientos de los insumos encontrados, incluidos positivos.
-- Los renglones/estados de la orden son su estado ACTUAL, no el histórico.
-- Comparar reference_id, item_id, bodega, signo y notes en una misma orden.
with parametros as (
  select b.id as business_id, '%empanad%'::text as nombre,
    now() - interval '7 days' as desde
  from public.businesses b
  where b.business_name ilike '%tiempo%extra%'
     or (to_jsonb(b)->>'branch_name') ilike '%tiempo%extra%'
), productos as (
  select mi.id, mi.business_id,
    nullif(to_jsonb(mi)->>'inventory_item_id', '')::uuid as directo_id
  from public.menu_items mi cross join parametros p
  where mi.business_id = p.business_id and mi.name ilike p.nombre
), insumos as (
  select business_id, directo_id as item_id from productos where directo_id is not null
  union
  select mi.business_id, ri.inventory_item_id
  from productos mi join public.recipes r on r.menu_item_id = mi.id
  join public.recipe_ingredients ri on ri.recipe_id = r.id
  where ri.inventory_item_id is not null
  union
  select ii.business_id, ii.id from public.inventory_items ii cross join parametros p
  where ii.business_id = p.business_id and ii.name ilike p.nombre
)
select
  im.created_at at time zone 'America/Santo_Domingo' as fecha_rd,
  im.id as movimiento_id, im.business_id, b.business_name as negocio,
  im.reference_id as orden_id, im.item_id, ii.name as inventariable,
  w.name as bodega, im.warehouse_id, im.quantity,
  case when im.quantity > 0 then 'ENTRA / devolución'
       when im.quantity < 0 then 'SALE / consumo' else 'Cero' end as sentido,
  im.notes, o.status as orden_status_actual, o.status_ext::text as orden_status_ext_actual,
  o.closed_at at time zone 'America/Santo_Domingo' as cierre_rd
from public.inventory_movements im
join insumos i on i.item_id = im.item_id and i.business_id = im.business_id
cross join parametros p
left join public.businesses b on b.id = im.business_id
left join public.inventory_items ii on ii.id = im.item_id
left join public.warehouses w on w.id = im.warehouse_id
left join public.orders o on o.id = im.reference_id
where im.business_id = p.business_id
  and im.reference_type = 'order' and im.movement_type::text = 'sale' and im.created_at >= p.desde
order by im.created_at desc, im.reference_id, im.id
limit 300;
