-- =============================================================================
-- THE PIZZA HOT — dejar el inventario como debe estar.
--
-- Negocio: fd09dab6-0333-40f1-8148-9912063c82b3 (Sucursal Principal)
--          6eac0321-1e35-41a9-bee8-0dc6eda02522 (Villa Tapia) — ver PASO 6
--
-- DE DÓNDE SALE ESTO (diagnóstico del 2026-09-10, ver
-- `DIAGNOSTICO_ajustes_inventario_solos.sql`):
--   · La app NO estaba haciendo ajustes. En 30 días hubo 4 ajustes, todos de
--     Cesar Flete (22-ago), más 2 mermas de Abreu. Los otros 381 movimientos
--     son el descuento normal por venta.
--   · El 20-ago se activó `is_inventory_tracked` en TODO el catálogo —las 4
--     pizzas, Palitos Locos y Jugos incluidos—, que es justo lo que el dueño
--     había pedido NO hacer: su modelo era inventariar solo lo embotellado.
--   · Una pizza no se repone nunca, así que su saldo solo baja. Al llegar a
--     cero entra el auto-86 (`20260516_0015`): el producto se apaga solo y
--     desaparece del catálogo del cajero. Palitos Locos ya está en 0.
--   · Aparte, órdenes ANULADAS se quedaron con el consumo pegado. Eso es un
--     bug del motor, y lo arregla la migración `20260910_0002`.
--
-- ORDEN DE EJECUCIÓN:
--   0. Preflight (no escribe nada).
--   1. Aplicar la migración 20260910_0002 — SIN ESO, el paso 2 no hace nada.
--   2. Devolver el inventario de las órdenes anuladas.
--   3. Apagar el tracking donde el dueño no lo quiere.
--   4. Reactivar los productos que el auto-86 escondió.
--   5. Verificar.
--   6. Repetir en Villa Tapia si aplica.
--
-- Corre UN PASO A LA VEZ y lee el resultado antes de seguir.
-- =============================================================================


-- =============================================================================
-- PASO 0 — PREFLIGHT. No escribe. Mira antes de tocar.
-- =============================================================================

-- 0a. ¿Qué productos descuentan hoy, y cuál está en cero (o escondido)?
select
  mi.name                                        as producto,
  mi.is_inventory_tracked                        as descuenta,
  mi.is_active                                   as visible_en_caja,
  mi.auto_disabled                               as lo_escondio_el_auto86,
  ii.name                                        as insumo,
  round(coalesce(s.quantity, 0)::numeric, 3)     as stock
from public.menu_items mi
left join public.inventory_items ii on ii.id = mi.inventory_item_id
left join public.inventory_stock  s on s.item_id = mi.inventory_item_id
where mi.business_id = 'fd09dab6-0333-40f1-8148-9912063c82b3'
  and (mi.is_inventory_tracked or mi.auto_disabled)
order by mi.auto_disabled desc, coalesce(s.quantity, 0) asc;

-- 0b. ¿Cuánto inventario está atrapado en órdenes anuladas? Esto es lo que
--     el PASO 2 va a devolver. Si sale vacío, sáltate el paso 2.
select
  ii.name                              as insumo,
  count(distinct o.id)                 as ordenes_anuladas,
  round(sum(m.quantity)::numeric, 3)   as neto_pegado,
  round(-sum(m.quantity)::numeric, 3)  as se_devolvera
from public.inventory_movements m
join public.orders o           on o.id = m.reference_id
join public.inventory_items ii on ii.id = m.item_id
where m.business_id = 'fd09dab6-0333-40f1-8148-9912063c82b3'
  and m.reference_type = 'order'
  and m.movement_type::text = 'sale'
  and (o.status = 'canceled' or o.status_ext = 'void'::public.order_status)
group by ii.name
having sum(m.quantity) <> 0
order by abs(sum(m.quantity)) desc;


-- =============================================================================
-- PASO 1 — Aplicar la migración del motor.
--
--   supabase/migrations/20260910_0002_consume_skip_voided_orders.sql
--
-- ANTES de aplicarla, cotejar la definición viva como avisa su encabezado:
--
--   select pg_get_functiondef(
--     'public.consume_inventory_from_order(uuid)'::regprocedure);
--
-- El 10-sep la viva medía 7172 caracteres, que corresponde a la versión de
-- 20260907_0003. Si en tu base mide otra cosa, PARA y avísame.
-- =============================================================================


-- =============================================================================
-- PASO 2 — Devolver el inventario atrapado en órdenes anuladas.
--
-- No hace un UPDATE a mano: le pide a la propia función que reconcilie cada
-- orden anulada. Con la migración puesta, "reconciliar una orden anulada"
-- significa exactamente "devolver lo que se consumió", y deja el movimiento
-- escrito con su nota, auditable en el kardex.
--
-- Idempotente: correrlo dos veces no devuelve dos veces.
-- =============================================================================

do $$
declare
  v_biz uuid := 'fd09dab6-0333-40f1-8148-9912063c82b3';
  v_order uuid;
  v_n int := 0;
begin
  for v_order in
    select distinct o.id
    from public.inventory_movements m
    join public.orders o on o.id = m.reference_id
    where m.business_id = v_biz
      and m.reference_type = 'order'
      and m.movement_type = 'sale'
      and (o.status = 'canceled' or o.status_ext = 'void'::public.order_status)
  loop
    perform public.consume_inventory_from_order(v_order);
    v_n := v_n + 1;
  end loop;

  raise notice 'Órdenes anuladas reconciliadas: %', v_n;
end $$;


-- =============================================================================
-- PASO 3 — Apagar el tracking donde el dueño no lo quiere.
--
-- LA LISTA de abajo es el modelo que pidió el dueño en agosto: inventario
-- SOLO para lo embotellado. Pizzas, palitos y jugos dejan de descontar.
--
-- SI EL DUEÑO CAMBIÓ DE OPINIÓN y ahora quiere llevar stock de pizzas, NO
-- corras este paso: lo que hay que hacer entonces es cargar la producción
-- del día (una recepción directa por tanda), o el auto-86 va a seguir
-- escondiendo productos cada vez que el saldo llegue a cero.
--
-- Apagar el tracking NO borra el histórico: el kardex de esos insumos queda
-- intacto y auditable. Solo deja de escribirse de aquí en adelante.
-- =============================================================================

update public.menu_items mi
   set is_inventory_tracked = false,
       inventory_item_id    = null
 where mi.business_id = 'fd09dab6-0333-40f1-8148-9912063c82b3'
   and mi.is_inventory_tracked
   and mi.name in (
     'Pizza Familiar 12 Pedazos',
     'Pizza Grande 10 Pedazos',
     'Pizza 6 Pedazos',
     'Pizza 4 Pedazos',
     'Palitos Locos',
     'Jugos'
   )
returning mi.name as apagado, mi.is_inventory_tracked, mi.inventory_item_id;

-- Los insumos correspondientes quedan sin producto que los mueva. No se
-- borran (arrastran kardex y capas de costo); se desactivan para que dejen
-- de ensuciar la pantalla de Insumos.
update public.inventory_items ii
   set is_active = false
 where ii.business_id = 'fd09dab6-0333-40f1-8148-9912063c82b3'
   and ii.name in (
     'Pizza Familiar 12 Pedazos',
     'Pizza Grande 10 Pedazos',
     'Pizza 6 Pedazos',
     'Pizza 4 Pedazos',
     'Palitos Locos',
     'Jugos'
   )
   and not exists (
     select 1 from public.menu_items mi
     where mi.inventory_item_id = ii.id and mi.is_inventory_tracked
   )
returning ii.name as insumo_desactivado;


-- =============================================================================
-- PASO 4 — Devolver al catálogo los productos que el auto-86 escondió.
--
-- El auto-86 solo reactiva cuando vuelve a entrar stock. Si le apagaste el
-- tracking en el paso 3, ese stock no va a volver nunca y el producto se
-- quedaría escondido para siempre. Esto lo devuelve a la vista.
--
-- `auto_disabled = true` es la marca de que lo apagó el sistema y no una
-- persona: los que el admin apagó a mano NO se tocan.
-- =============================================================================

update public.menu_items mi
   set is_active     = true,
       auto_disabled = false
 where mi.business_id = 'fd09dab6-0333-40f1-8148-9912063c82b3'
   and mi.auto_disabled
returning mi.name as reactivado, mi.is_active;


-- =============================================================================
-- PASO 5 — Verificar. Corre las tres.
-- =============================================================================

-- 5a. Qué sigue descontando. Deberían quedar SOLO los embotellados:
--     refrescos, agua y las dos Presidente.
select
  mi.name                                     as producto,
  ii.name                                     as insumo,
  round(coalesce(s.quantity, 0)::numeric, 3)  as stock,
  mi.is_active                                as visible_en_caja
from public.menu_items mi
join public.inventory_items ii on ii.id = mi.inventory_item_id
left join public.inventory_stock s on s.item_id = mi.inventory_item_id
where mi.business_id = 'fd09dab6-0333-40f1-8148-9912063c82b3'
  and mi.is_inventory_tracked
order by mi.name;

-- 5b. Que no quede nada escondido por el sistema.
select count(*) as productos_escondidos_por_el_auto86
from public.menu_items
where business_id = 'fd09dab6-0333-40f1-8148-9912063c82b3'
  and auto_disabled;

-- 5c. Que no quede inventario atrapado en órdenes anuladas (debe dar 0 filas).
select
  ii.name                            as insumo,
  round(sum(m.quantity)::numeric, 3) as neto_pegado
from public.inventory_movements m
join public.orders o           on o.id = m.reference_id
join public.inventory_items ii on ii.id = m.item_id
where m.business_id = 'fd09dab6-0333-40f1-8148-9912063c82b3'
  and m.reference_type = 'order'
  and m.movement_type::text = 'sale'
  and (o.status = 'canceled' or o.status_ext = 'void'::public.order_status)
group by ii.name
having sum(m.quantity) <> 0;


-- =============================================================================
-- PASO 6 — Villa Tapia (6eac0321-1e35-41a9-bee8-0dc6eda02522).
--
-- Es la MISMA pizzería en otra sucursal, con el mismo menú. Antes de repetir
-- nada, corre el PASO 0 con ese business_id: puede que ahí nunca se activara
-- el tracking, y entonces no hay nada que apagar.
--
-- Si el preflight muestra el mismo cuadro, repite los pasos 2, 3 y 4
-- cambiando el business_id en las cuatro sentencias.
-- =============================================================================
