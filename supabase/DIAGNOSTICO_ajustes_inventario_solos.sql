-- =============================================================================
-- TRAZA DE MOVIMIENTOS DE INVENTARIO — "la app hace ajustes sola"
--
-- Negocio: fd09dab6-0333-40f1-8148-9912063c82b3 = THE PIZZA HOT, Suc. Principal
--          6eac0321-1e35-41a9-bee8-0dc6eda02522 = The Pizza Hot, Villa Tapia
--          (misma pizzería, 2 negocios separados — ojo con mirar la sucursal
--           equivocada; la Q16 las pone lado a lado)
-- Ventana: últimos 30 días (ajusta el interval donde haga falta).
--
-- CÓMO USARLO: corre UNA consulta a la vez en el SQL Editor de Supabase.
-- Van en orden de embudo: primero qué está vivo en la BD, después la forma
-- del ruido, y al final las tres trampas concretas que producen movimientos
-- "solos".
--
-- QUIÉN PUEDE ESCRIBIR EN inventory_movements (mapa del código):
--   1. consume_inventory_from_order()  → trigger en order_items (insert/update/
--      delete). Tipo 'sale'. created_by NULL. Es el que más ruido hace.
--   2. fn_inventory_adjust()           → ajuste manual desde la app. created_by
--      = el usuario. reason_code obligatorio.
--   3. fn_physical_count_complete()    → ajuste por conteo físico.
--   4. recepciones de compra, recepción directa, transferencias, producción,
--      disposición de lotes.
--   5. La cola OFFLINE de la caja, que reencola 'inventory_adjust' e
--      'inventory_movement' y los replaya al recuperar red.
-- =============================================================================


-- -----------------------------------------------------------------------------
-- Q00. ¿ES ESTE EL NEGOCIO? Corre esto PRIMERO si no estás seguro del ID.
--      Lista los negocios con actividad de inventario en los últimos 30 días,
--      ordenados por cuánto se movieron. El que se queja debería estar arriba.
-- -----------------------------------------------------------------------------
select
  b.id                                          as business_id,
  b.business_name,
  b.branch_name,
  bs.inventory_mode,
  bs.warehouse_sections_enabled,
  count(m.id)                                   as movimientos_30d,
  count(m.id) filter (where m.created_by is null)                as del_servidor,
  count(m.id) filter (where m.movement_type::text = 'adjustment') as ajustes,
  max(m.created_at) at time zone 'America/Santo_Domingo'          as ultimo_movimiento
from public.businesses b
left join public.business_settings bs on bs.business_id = b.id
left join public.inventory_movements m
       on m.business_id = b.id
      and m.created_at >= now() - interval '30 days'
where b.status = 'active'
group by b.id, b.business_name, b.branch_name,
         bs.inventory_mode, bs.warehouse_sections_enabled
having count(m.id) > 0
order by movimientos_30d desc;


-- -----------------------------------------------------------------------------
-- Q0. Identidad del negocio y banderas que deciden si el inventario se mueve.
-- -----------------------------------------------------------------------------
select
  b.id,
  b.business_name,
  bs.inventory_mode,                          -- 'none' = no debería moverse NADA
  bs.warehouse_sections_enabled,              -- true = consumo por área/almacén
  (select count(*) from public.warehouses w
    where w.business_id = b.id)                        as almacenes,
  (select count(*) from public.warehouses w
    where w.business_id = b.id and coalesce(w.is_active,true)) as almacenes_activos,
  (select w.name from public.warehouses w
    where w.business_id = b.id
    order by w.is_main desc, w.created_at asc nulls first, w.id asc
    limit 1)                                           as almacen_por_defecto
from public.businesses b
left join public.business_settings bs on bs.business_id = b.id
where b.id = 'fd09dab6-0333-40f1-8148-9912063c82b3';


-- -----------------------------------------------------------------------------
-- Q1. Qué está VIVO en la base (la BD diverge del repo: hay que mirarla).
--     Lista los triggers que pueden disparar movimientos por su cuenta.
-- -----------------------------------------------------------------------------
select
  c.relname                as tabla,
  t.tgname                 as trigger,
  p.proname                as funcion,
  case t.tgenabled when 'O' then 'activo' when 'D' then 'DESACTIVADO'
       else t.tgenabled::text end as estado
from pg_trigger t
join pg_class c on c.oid = t.tgrelid
join pg_proc  p on p.oid = t.tgfoid
where not t.tgisinternal
  and c.relnamespace = 'public'::regnamespace
  and c.relname in ('order_items','orders','inventory_movements',
                    'inventory_stock','inventory_items')
order by c.relname, t.tgname;


-- -----------------------------------------------------------------------------
-- Q1b. Qué VERSIÓN del motor de consumo está viva. Decide si el consumo se
--      reparte por almacén (puede MUDAR stock entre bodegas) y si los
--      modificadores descuentan insumos.
-- -----------------------------------------------------------------------------
select
  (lower(def) like '%fn_resolve_consumption_warehouse%') as consumo_por_area_activo,
  (lower(def) like '%modifier_ingredients%')              as consume_modificadores,
  (lower(def) like '%item_type%')                         as maneja_combos,
  length(def) as largo_def,
  md5(def)    as huella
from (
  select pg_get_functiondef(
    'public.consume_inventory_from_order(uuid)'::regprocedure) as def
) s;


-- -----------------------------------------------------------------------------
-- Q2. La forma del ruido: movimientos por día y por tipo (30 días).
--     Si "hace ajustes solo" es todos los días a toda hora → es el trigger de
--     ventas. Si son picos puntuales → es un humano o un conteo.
-- -----------------------------------------------------------------------------
select
  date_trunc('day', m.created_at at time zone 'America/Santo_Domingo')::date as dia,
  m.movement_type::text as tipo,
  count(*)                                as movimientos,
  count(*) filter (where m.created_by is null) as del_servidor,
  round(sum(m.quantity)::numeric, 3)      as neto_unidades
from public.inventory_movements m
where m.business_id = 'fd09dab6-0333-40f1-8148-9912063c82b3'
  and m.created_at >= now() - interval '30 days'
group by 1, 2
order by 1 desc, 3 desc;


-- -----------------------------------------------------------------------------
-- Q3. La FIRMA de cada movimiento: quién lo escribió y con qué etiqueta.
--     Esta es la consulta que contesta "¿la app o una persona?".
--     created_by NULL = lo escribió el servidor (trigger/RPC security definer).
-- -----------------------------------------------------------------------------
select
  m.movement_type::text                   as tipo,
  coalesce(m.reference_type, '(sin ref)') as origen,
  coalesce(m.reason_code, '(sin razón)')  as razon,
  coalesce(m.notes, '(sin nota)')         as nota,
  case when m.created_by is null then 'SERVIDOR (trigger/RPC)'
       else coalesce(pr.full_name, pr.email, m.created_by::text) end as quien,
  count(*)                                as veces,
  min(m.created_at)                       as primero,
  max(m.created_at)                       as ultimo,
  round(sum(m.quantity)::numeric, 3)      as neto_unidades
from public.inventory_movements m
left join public.profiles pr on pr.id = m.created_by
where m.business_id = 'fd09dab6-0333-40f1-8148-9912063c82b3'
  and m.created_at >= now() - interval '30 days'
group by 1, 2, 3, 4, 5
order by veces desc;


-- -----------------------------------------------------------------------------
-- Q4. DETALLE de los ajustes propiamente dichos (adjustment / waste / return),
--     con el origen resuelto a nombre humano y quién lo hizo.
-- -----------------------------------------------------------------------------
select
  m.created_at at time zone 'America/Santo_Domingo' as fecha_local,
  ii.name                                  as insumo,
  ii.unit                                  as unidad,
  w.name                                   as almacen,
  m.movement_type::text                    as tipo,
  round(m.quantity::numeric, 3)            as cantidad,
  m.cost_per_unit,
  coalesce(m.reason_code, '—')             as razon,
  coalesce(m.reference_type, '—')          as origen,
  coalesce(pcs.code, m.reference_id::text)  as referencia,   -- code si es conteo
  case when m.created_by is null then 'SERVIDOR (trigger/RPC)'
       else coalesce(pr.full_name, pr.email, m.created_by::text) end as quien,
  m.notes,
  m.id                                     as movimiento_id
from public.inventory_movements m
join public.inventory_items ii on ii.id = m.item_id
left join public.warehouses  w  on w.id  = m.warehouse_id
left join public.profiles    pr on pr.id = m.created_by
left join public.physical_count_sessions pcs on pcs.id = m.reference_id
where m.business_id = 'fd09dab6-0333-40f1-8148-9912063c82b3'
  and m.movement_type::text in ('adjustment','waste','return')
  and m.created_at >= now() - interval '30 days'
order by m.created_at desc
limit 500;


-- -----------------------------------------------------------------------------
-- Q5. TRAMPA 1 — La mudanza de almacén.
--     Si `warehouse_sections_enabled` está prendida (Q0) y a un producto le
--     cambian el área, la reconciliación DEVUELVE el stock en un almacén y lo
--     DESCUENTA en otro. Al cliente le parecen "ajustes solos".
--     Filas aquí = el mismo insumo, la misma orden, dos almacenes, signos
--     opuestos.
-- -----------------------------------------------------------------------------
select
  m.reference_id                            as orden_id,
  ii.name                                   as insumo,
  count(distinct m.warehouse_id)            as almacenes_tocados,
  string_agg(distinct w.name, ' | ')        as cuales,
  round(sum(m.quantity) filter (where m.quantity > 0)::numeric, 3) as devuelto,
  round(sum(m.quantity) filter (where m.quantity < 0)::numeric, 3) as descontado,
  min(m.created_at)                         as primero,
  max(m.created_at)                         as ultimo
from public.inventory_movements m
join public.inventory_items ii on ii.id = m.item_id
left join public.warehouses w on w.id = m.warehouse_id
where m.business_id = 'fd09dab6-0333-40f1-8148-9912063c82b3'
  and m.reference_type = 'order'
  and m.movement_type::text = 'sale'
  and m.created_at >= now() - interval '30 days'
group by 1, 2
having count(distinct m.warehouse_id) > 1
order by ultimo desc
limit 200;


-- -----------------------------------------------------------------------------
-- Q6. TRAMPA 2 — Reconciliación repetida.
--     El trigger se dispara en CADA insert/update/delete de order_items. Con
--     una orden que se edita mucho verás una fila por cada cambio. Normal son
--     1-2 movimientos por (orden, insumo, almacén); 5+ es que algo la está
--     tocando en bucle (dos terminales, cola offline, mesero editando).
-- -----------------------------------------------------------------------------
select
  m.reference_id                       as orden_id,
  ii.name                              as insumo,
  w.name                               as almacen,
  count(*)                             as movimientos,
  round(sum(m.quantity)::numeric, 3)   as neto,
  min(m.created_at)                    as primero,
  max(m.created_at)                    as ultimo,
  max(m.created_at) - min(m.created_at) as ventana
from public.inventory_movements m
join public.inventory_items ii on ii.id = m.item_id
left join public.warehouses w on w.id = m.warehouse_id
where m.business_id = 'fd09dab6-0333-40f1-8148-9912063c82b3'
  and m.reference_type = 'order'
  and m.created_at >= now() - interval '30 days'
group by 1, 2, 3
having count(*) >= 4
order by movimientos desc
limit 200;


-- -----------------------------------------------------------------------------
-- Q7. TRAMPA 3 — Movimientos TARDÍOS: inventario que se mueve DESPUÉS de que
--     la orden ya se cerró/cobró. Es la huella del ítem que cae sobre una
--     orden muerta, del replay de la cola offline, o de una edición póstuma.
-- -----------------------------------------------------------------------------
select
  o.id                                  as orden_id,
  o.status,
  o.closed_at at time zone 'America/Santo_Domingo' as cerrada,
  m.created_at at time zone 'America/Santo_Domingo' as movimiento,
  m.created_at - o.closed_at            as retraso,
  ii.name                               as insumo,
  round(m.quantity::numeric, 3)         as cantidad,
  m.notes
from public.inventory_movements m
join public.orders o on o.id = m.reference_id
join public.inventory_items ii on ii.id = m.item_id
where m.business_id = 'fd09dab6-0333-40f1-8148-9912063c82b3'
  and m.reference_type = 'order'
  and o.closed_at is not null
  and m.created_at > o.closed_at + interval '2 minutes'
  and m.created_at >= now() - interval '30 days'
order by m.created_at desc
limit 200;


-- -----------------------------------------------------------------------------
-- Q8. Duplicados casi-instantáneos: mismo insumo, mismo almacén, misma
--     cantidad, en menos de 10 segundos. Huella de un reintento (cola offline
--     o doble tap) que entró dos veces.
-- -----------------------------------------------------------------------------
with mov as (
  select
    m.*,
    lag(m.created_at) over (
      partition by m.item_id, m.warehouse_id, m.movement_type, m.quantity,
                   coalesce(m.reference_id, '00000000-0000-0000-0000-000000000000'::uuid)
      order by m.created_at
    ) as anterior
  from public.inventory_movements m
  where m.business_id = 'fd09dab6-0333-40f1-8148-9912063c82b3'
    and m.created_at >= now() - interval '30 days'
)
select
  mov.created_at at time zone 'America/Santo_Domingo' as fecha_local,
  ii.name                              as insumo,
  mov.movement_type::text              as tipo,
  round(mov.quantity::numeric, 3)      as cantidad,
  mov.created_at - mov.anterior        as separacion,
  mov.reference_type,
  mov.reference_id,
  mov.notes
from mov
join public.inventory_items ii on ii.id = mov.item_id
where mov.anterior is not null
  and mov.created_at - mov.anterior < interval '10 seconds'
order by mov.created_at desc
limit 200;


-- -----------------------------------------------------------------------------
-- Q9. DESCUADRE: lo que dice inventory_stock vs la suma del kardex.
--     Si no cuadra, alguien escribió el stock SIN dejar movimiento (o al revés)
--     y ninguna traza va a explicar la diferencia.
-- -----------------------------------------------------------------------------
select
  ii.name                                     as insumo,
  w.name                                      as almacen,
  round(coalesce(s.quantity, 0)::numeric, 3)  as stock_tabla,
  round(coalesce(k.suma, 0)::numeric, 3)      as stock_segun_kardex,
  round((coalesce(s.quantity,0) - coalesce(k.suma,0))::numeric, 3) as diferencia,
  s.last_updated at time zone 'America/Santo_Domingo' as stock_actualizado
from public.inventory_items ii
join public.warehouses w on w.business_id = ii.business_id
left join public.inventory_stock s
       on s.item_id = ii.id and s.warehouse_id = w.id
left join (
  select item_id, warehouse_id, sum(quantity) as suma
  from public.inventory_movements
  where business_id = 'fd09dab6-0333-40f1-8148-9912063c82b3'
  group by 1, 2
) k on k.item_id = ii.id and k.warehouse_id = w.id
where ii.business_id = 'fd09dab6-0333-40f1-8148-9912063c82b3'
  and (s.id is not null or k.suma is not null)
  and abs(coalesce(s.quantity,0) - coalesce(k.suma,0)) > 0.001
order by abs(coalesce(s.quantity,0) - coalesce(k.suma,0)) desc
limit 200;


-- -----------------------------------------------------------------------------
-- Q10. Conteos físicos: qué sesiones se completaron y cuánto ajustaron.
--      Un conteo aplicado mueve MUCHAS líneas de golpe y se ve como
--      "la app ajustó todo sola".
-- -----------------------------------------------------------------------------
select
  pcs.code,
  pcs.status,
  w.name                                                as almacen,
  pcs.completed_at at time zone 'America/Santo_Domingo' as completado,
  coalesce(pc.full_name, pc.email, pcs.completed_by::text) as completado_por,
  count(m.id)                                           as lineas_ajustadas,
  round(sum(m.quantity)::numeric, 3)                    as neto_unidades
from public.physical_count_sessions pcs
left join public.warehouses w  on w.id  = pcs.warehouse_id
left join public.profiles   pc on pc.id = pcs.completed_by
left join public.inventory_movements m
       on m.reference_id = pcs.id and m.reference_type = 'physical_count'
where pcs.business_id = 'fd09dab6-0333-40f1-8148-9912063c82b3'
  and pcs.started_at >= now() - interval '90 days'
group by pcs.id, pcs.code, pcs.status, w.name, pcs.completed_at,
         pc.full_name, pc.email, pcs.completed_by, pcs.started_at
order by pcs.started_at desc;


-- -----------------------------------------------------------------------------
-- Q11. Top insumos por actividad automática (los que el cliente va a nombrar).
-- -----------------------------------------------------------------------------
select
  ii.name                                        as insumo,
  ii.unit,
  count(*)                                       as movimientos,
  count(*) filter (where m.created_by is null)   as automaticos,
  count(*) filter (where m.movement_type::text = 'sale' and m.quantity > 0) as devoluciones,
  round(sum(m.quantity) filter (where m.quantity < 0)::numeric, 3) as salidas,
  round(sum(m.quantity) filter (where m.quantity > 0)::numeric, 3) as entradas,
  round(sum(m.quantity)::numeric, 3)             as neto,
  round(coalesce((
    select sum(s.quantity) from public.inventory_stock s
     join public.warehouses w2 on w2.id = s.warehouse_id
    where s.item_id = ii.id
      and w2.business_id = 'fd09dab6-0333-40f1-8148-9912063c82b3'
  ), 0)::numeric, 3)                             as stock_hoy_todos_los_almacenes
from public.inventory_movements m
join public.inventory_items ii on ii.id = m.item_id
where m.business_id = 'fd09dab6-0333-40f1-8148-9912063c82b3'
  and m.created_at >= now() - interval '30 days'
group by ii.id, ii.name, ii.unit
order by movimientos desc
limit 50;


-- -----------------------------------------------------------------------------
-- Q12. KARDEX de UN insumo, con saldo corrido. Pega aquí el nombre exacto que
--      te diga el cliente ("a la pechuga le bajó solo").
-- -----------------------------------------------------------------------------
select
  v.created_at at time zone 'America/Santo_Domingo' as fecha_local,
  v.warehouse_name                     as almacen,
  v.movement_type::text                as tipo,
  round(v.quantity::numeric, 3)        as cantidad,
  round(v.running_balance::numeric, 3) as saldo,
  coalesce(v.reason_code, '—')         as razon,
  coalesce(v.reference_type, '—')      as origen,
  v.reference_id,
  coalesce(v.created_by_name, 'SERVIDOR (trigger/RPC)') as quien,
  v.notes
from public.v_inventory_movements_with_balance v
where v.business_id = 'fd09dab6-0333-40f1-8148-9912063c82b3'
  and v.item_name ilike '%PECHUGA%'          -- <-- CAMBIA EL NOMBRE
  and v.created_at >= now() - interval '30 days'
order by v.created_at desc
limit 300;


-- -----------------------------------------------------------------------------
-- Q12b. Lo mismo que Q12 pero SIN depender de la vista
--       v_inventory_movements_with_balance (por si no está creada en prod).
-- -----------------------------------------------------------------------------
select
  m.created_at at time zone 'America/Santo_Domingo' as fecha_local,
  w.name                               as almacen,
  m.movement_type::text                as tipo,
  round(m.quantity::numeric, 3)        as cantidad,
  round(sum(m.quantity) over (
    partition by m.warehouse_id, m.item_id
    order by m.created_at, m.id
    rows between unbounded preceding and current row
  )::numeric, 3)                       as saldo,
  coalesce(m.reason_code, '—')         as razon,
  coalesce(m.reference_type, '—')      as origen,
  m.reference_id,
  case when m.created_by is null then 'SERVIDOR (trigger/RPC)'
       else coalesce(pr.full_name, pr.email, m.created_by::text) end as quien,
  m.notes
from public.inventory_movements m
join public.inventory_items ii on ii.id = m.item_id
left join public.warehouses w  on w.id  = m.warehouse_id
left join public.profiles   pr on pr.id = m.created_by
where m.business_id = 'fd09dab6-0333-40f1-8148-9912063c82b3'
  and ii.name ilike '%PECHUGA%'              -- <-- CAMBIA EL NOMBRE
order by m.created_at desc
limit 300;

-- -----------------------------------------------------------------------------
-- Q13. Movimientos huérfanos: apuntan a una orden que ya no existe.
--      Inventario descontado por algo que nadie puede auditar desde la app.
-- -----------------------------------------------------------------------------
select
  m.created_at at time zone 'America/Santo_Domingo' as fecha_local,
  ii.name                          as insumo,
  m.movement_type::text            as tipo,
  round(m.quantity::numeric, 3)    as cantidad,
  m.reference_id                   as orden_inexistente,
  m.notes
from public.inventory_movements m
join public.inventory_items ii on ii.id = m.item_id
where m.business_id = 'fd09dab6-0333-40f1-8148-9912063c82b3'
  and m.reference_type = 'order'
  and m.created_at >= now() - interval '30 days'
  and not exists (select 1 from public.orders o where o.id = m.reference_id)
order by m.created_at desc
limit 200;


-- =============================================================================
-- SECCIÓN THE PIZZA HOT — el modelo de inventario que pidió el dueño
--
--   "SIN recetas, por item contado": SOLO lo embotellado (4 refrescos/agua +
--   2 Presidente) debe llevar `menu_items.inventory_item_id` 1:1. Pizzas,
--   palitos y jugos NO deben descontar nada.
--
--   En el diagnóstico de agosto había links `inventory_item_id` BASURA en
--   pizzas y en "Palitos Locos". Si esos links siguen vivos y el producto
--   tiene `is_inventory_tracked = true`, cada pizza vendida descuenta un
--   insumo que no tiene nada que ver — y eso se ve EXACTAMENTE como
--   "la app hace ajustes sola".
--
--   Además `inventory_mode` estaba en 'basic': en basic el motor SÍ descuenta
--   (desde la migración 20260516_0013), vía recetas 1:1 auto-creadas.
-- =============================================================================


-- -----------------------------------------------------------------------------
-- Q14. EL CATÁLOGO TRAZADO: qué producto descuenta qué insumo y por qué ruta.
--      Esta es la consulta madre para este negocio. Todo lo que salga aquí
--      fuera de refrescos/agua/Presidente es un link que sobra.
-- -----------------------------------------------------------------------------
with rutas as (
  -- Ruta A: receta (incluye las 1:1 auto-creadas del modo basic).
  select
    mi.id                        as menu_item_id,
    mi.name                      as producto,
    mi.is_inventory_tracked,
    mi.is_active                 as producto_activo,
    ri.inventory_item_id         as item_id,
    ri.quantity                  as consume_por_unidad,
    'receta'                     as via
  from public.menu_items mi
  join public.recipes r             on r.menu_item_id = mi.id
  join public.recipe_ingredients ri on ri.recipe_id = r.id
  where mi.business_id = 'fd09dab6-0333-40f1-8148-9912063c82b3'

  union all

  -- Ruta B: link directo de producto terminado (solo si NO tiene receta).
  select
    mi.id, mi.name, mi.is_inventory_tracked, mi.is_active,
    mi.inventory_item_id, 1, 'link directo'
  from public.menu_items mi
  where mi.business_id = 'fd09dab6-0333-40f1-8148-9912063c82b3'
    and mi.inventory_item_id is not null
    and not exists (select 1 from public.recipes r where r.menu_item_id = mi.id)
)
select
  ru.producto,
  ru.producto_activo,
  ru.is_inventory_tracked                       as descuenta,
  ru.via,
  ii.name                                       as insumo_que_toca,
  ii.unit                                       as unidad,
  ru.consume_por_unidad,
  case
    when ru.is_inventory_tracked and ii.id is null then '⚠ apunta a un insumo BORRADO'
    when ru.is_inventory_tracked then 'descuenta al vender'
    else 'link presente pero tracking APAGADO (no descuenta)'
  end                                           as veredicto
from rutas ru
left join public.inventory_items ii on ii.id = ru.item_id
order by ru.is_inventory_tracked desc, ru.producto;


-- -----------------------------------------------------------------------------
-- Q15. QUIÉN MOVIÓ QUÉ: atribuye cada movimiento de venta al producto que lo
--      causó. Con esto le dices al cliente "cada vez que vendes X, te baja Y".
-- -----------------------------------------------------------------------------
with rutas as (
  select mi.id as menu_item_id, mi.name as producto, ri.inventory_item_id as item_id
  from public.menu_items mi
  join public.recipes r             on r.menu_item_id = mi.id
  join public.recipe_ingredients ri on ri.recipe_id = r.id
  where mi.business_id = 'fd09dab6-0333-40f1-8148-9912063c82b3'
  union all
  select mi.id, mi.name, mi.inventory_item_id
  from public.menu_items mi
  where mi.business_id = 'fd09dab6-0333-40f1-8148-9912063c82b3'
    and mi.inventory_item_id is not null
    and not exists (select 1 from public.recipes r where r.menu_item_id = mi.id)
)
select
  ii.name                              as insumo,
  ru.producto                          as producto_que_lo_descuenta,
  count(distinct m.id)                 as movimientos,
  round(sum(m.quantity)::numeric, 3)   as neto_unidades,
  min(m.created_at) at time zone 'America/Santo_Domingo' as primero,
  max(m.created_at) at time zone 'America/Santo_Domingo' as ultimo
from public.inventory_movements m
join public.inventory_items ii on ii.id = m.item_id
join public.order_items oi     on oi.order_id = m.reference_id
join rutas ru                  on ru.menu_item_id = oi.product_id
                              and ru.item_id      = m.item_id
where m.business_id = 'fd09dab6-0333-40f1-8148-9912063c82b3'
  and m.reference_type = 'order'
  and m.created_at >= now() - interval '30 days'
group by ii.name, ru.producto
order by movimientos desc
limit 100;


-- -----------------------------------------------------------------------------
-- Q16. LAS DOS SUCURSALES lado a lado. La misma pizzería son 2 negocios
--      distintos: asegúrate de estar mirando en la que se quejó.
-- -----------------------------------------------------------------------------
select
  b.business_name || ' — ' || coalesce(b.branch_name, '(sin sucursal)') as negocio,
  b.id                                          as business_id,
  bs.inventory_mode,
  bs.warehouse_sections_enabled,
  (select count(*) from public.menu_items mi
    where mi.business_id = b.id and mi.is_inventory_tracked) as productos_que_descuentan,
  (select count(*) from public.inventory_items ii
    where ii.business_id = b.id and coalesce(ii.is_active,true)) as insumos_activos,
  (select count(*) from public.inventory_movements m
    where m.business_id = b.id
      and m.created_at >= now() - interval '30 days')          as movimientos_30d,
  (select count(*) from public.inventory_movements m
    where m.business_id = b.id
      and m.movement_type::text = 'adjustment'
      and m.created_at >= now() - interval '30 days')          as ajustes_30d
from public.businesses b
left join public.business_settings bs on bs.business_id = b.id
where b.id in ('fd09dab6-0333-40f1-8148-9912063c82b3',
               '6eac0321-1e35-41a9-bee8-0dc6eda02522');


-- -----------------------------------------------------------------------------
-- Q17. AUTO-86: productos que la app apagó SOLA por stock en cero.
--
--   El trigger `trg_movements_recompute_menu_availability` (auto-86, estilo
--   Toast) pone `menu_items.is_active = false` + `auto_disabled = true`
--   cuando el stock del insumo del que dependen llega a 0 o negativo. El
--   producto DESAPARECE del catálogo del cajero sin que nadie lo toque, y
--   vuelve solo cuando entra stock.
--
--   Si el reclamo del cliente es "se me desaparecen productos" o "me cambia
--   el inventario solo", esta consulta es la respuesta.
-- -----------------------------------------------------------------------------
with rutas as (
  select mi.id as menu_item_id, mi.name as producto, mi.is_active,
         mi.auto_disabled, mi.is_inventory_tracked,
         ri.inventory_item_id as item_id, 'receta' as via
  from public.menu_items mi
  join public.recipes r             on r.menu_item_id = mi.id
  join public.recipe_ingredients ri on ri.recipe_id = r.id
  where mi.business_id = 'fd09dab6-0333-40f1-8148-9912063c82b3'
  union all
  select mi.id, mi.name, mi.is_active, mi.auto_disabled, mi.is_inventory_tracked,
         mi.inventory_item_id, 'link directo'
  from public.menu_items mi
  where mi.business_id = 'fd09dab6-0333-40f1-8148-9912063c82b3'
    and mi.inventory_item_id is not null
    and not exists (select 1 from public.recipes r where r.menu_item_id = mi.id)
)
select
  ru.producto,
  ii.name                                        as insumo,
  round(coalesce(s.quantity, 0)::numeric, 3)     as stock_actual,
  ru.is_inventory_tracked                        as descuenta_al_vender,
  ru.is_active                                   as visible_en_caja,
  ru.auto_disabled                               as lo_apago_la_app,
  ru.via,
  case
    when ru.auto_disabled                       then '⚠ AUTO-86: la app lo escondió por stock 0'
    when coalesce(s.quantity, 0) <= 0
     and ru.is_inventory_tracked                then '⚠ stock en 0/negativo — se va a esconder'
    when not ru.is_inventory_tracked            then 'no descuenta (tracking apagado)'
    else 'ok'
  end                                            as veredicto,
  s.last_updated at time zone 'America/Santo_Domingo' as stock_actualizado
from rutas ru
left join public.inventory_items ii on ii.id = ru.item_id
left join public.inventory_stock  s on s.item_id = ru.item_id
order by ru.auto_disabled desc, coalesce(s.quantity, 0) asc;


-- -----------------------------------------------------------------------------
-- Q18. EL BACKFILL DEL 20-AGO: qué descontó órdenes de julio de golpe.
--
--   La Q7 mostró decenas de movimientos estampados el 20-ago ~21:55 (hora
--   local) contra órdenes cerradas hasta 35 días antes. Eso es la
--   reconciliación disparándose sobre el histórico justo después de que se
--   activó el tracking de los productos esa misma tarde.
--
--   (a) agrupa por segundo: si son 3-4 tandas, fue un UPDATE masivo sobre
--       order_items (el trigger reconcilia una fila a la vez).
-- -----------------------------------------------------------------------------
select
  date_trunc('second', m.created_at) at time zone 'America/Santo_Domingo' as instante,
  count(*)                              as movimientos,
  count(distinct m.reference_id)        as ordenes_distintas,
  min(o.closed_at)::date                as orden_mas_vieja,
  max(o.closed_at)::date                as orden_mas_nueva,
  round(sum(m.quantity)::numeric, 3)    as neto_unidades
from public.inventory_movements m
left join public.orders o on o.id = m.reference_id
where m.business_id = 'fd09dab6-0333-40f1-8148-9912063c82b3'
  and m.created_at >= timestamptz '2026-08-20 00:00-04'
  and m.created_at <  timestamptz '2026-08-22 00:00-04'
group by 1
order by 1;


-- -----------------------------------------------------------------------------
-- Q18b. ¿Fue un UPDATE masivo? Compara cuándo se tocaron por última vez los
--       renglones de esas órdenes viejas. Si `updated_at` de todos cae en la
--       misma noche, alguien corrió un script sobre order_items.
-- -----------------------------------------------------------------------------
select
  date_trunc('minute', oi.updated_at) at time zone 'America/Santo_Domingo' as minuto,
  count(*)                        as renglones_tocados,
  count(distinct oi.order_id)     as ordenes,
  min(o.created_at)::date         as orden_mas_vieja
from public.order_items oi
join public.orders o        on o.id = oi.order_id
join public.table_sessions ts on ts.id = o.session_id
where ts.business_id = 'fd09dab6-0333-40f1-8148-9912063c82b3'
  and oi.updated_at >= timestamptz '2026-08-20 00:00-04'
  and oi.updated_at <  timestamptz '2026-08-22 00:00-04'
group by 1
order by renglones_tocados desc
limit 50;


-- -----------------------------------------------------------------------------
-- Q19. BUG: órdenes CANCELADAS que igual descontaron inventario.
--
--   `consume_inventory_from_order` filtra por `order_items.status <> 'void'`
--   pero NO mira el status de la ORDEN. Si la orden se canceló sin marcar
--   sus renglones como void, el inventario se descontó igual y nunca volvió.
-- -----------------------------------------------------------------------------
select
  o.id                                  as orden_id,
  o.status                              as estado_orden,
  o.closed_at at time zone 'America/Santo_Domingo' as cerrada,
  ii.name                               as insumo,
  round(sum(m.quantity)::numeric, 3)    as neto_movido,
  count(*)                              as movimientos,
  count(*) filter (where oi.status = 'void') as renglones_void
from public.inventory_movements m
join public.orders o           on o.id = m.reference_id
join public.inventory_items ii on ii.id = m.item_id
left join public.order_items oi on oi.order_id = o.id
where m.business_id = 'fd09dab6-0333-40f1-8148-9912063c82b3'
  and m.reference_type = 'order'
  and o.status = 'canceled'
group by o.id, o.status, o.closed_at, ii.name
having sum(m.quantity) <> 0
order by o.closed_at desc
limit 100;
