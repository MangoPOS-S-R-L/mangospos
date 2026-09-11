-- =============================================================================
-- LA PENDA EXPRESS · PASO 1 — Punto de partida del inventario
-- business_id = 35c5076a-bd85-4a1b-8d1c-ce719c4f9ae6
--
-- SOLO LECTURA. No escribe nada.
--
-- Objetivo: saber DE DÓNDE partimos antes de crear almacenes, recetas y
-- cargar stock. Sobre todo: que ya se esté descontando por su cuenta, porque
-- si aplicamos el rollforward encima, restariamos dos veces.
--
-- NOTA: order_items.business_id existe en prod pero NO esta en el repo, asi que
-- aqui se llega al negocio por orders -> table_sessions, que es el camino que
-- usan las funciones vivas.
-- =============================================================================

-- A ─── Almacenes que ya existen ──────────────────────────────────────────────
select w.id, w.name, w.is_main, w.is_active,
       (select count(*) from public.inventory_stock s where s.warehouse_id = w.id) as items_con_stock,
       (select round(sum(s.quantity), 2) from public.inventory_stock s where s.warehouse_id = w.id) as unidades
from public.warehouses w
where w.business_id = '35c5076a-bd85-4a1b-8d1c-ce719c4f9ae6'
order by w.is_main desc, w.name;


-- B ─── El conteo: en qué estado quedó ────────────────────────────────────────
--     ANOTA EL frozen_at: es la fecha de corte para todo lo demás.
--     OJO con `sin_contar`: una línea en NULL no es un insumo en cero.
select
  s.code, s.status, w.name as bodega,
  coalesce(s.notes, '(sin área)')                          as area,
  (s.frozen_at at time zone 'America/Santo_Domingo')       as congelado,
  count(l.*)                                               as lineas,
  count(l.*) filter (where l.counted_quantity is not null)  as contadas,
  count(l.*) filter (where l.counted_quantity is null)      as sin_contar,
  round(sum(coalesce(l.counted_quantity, 0)), 2)            as unidades_contadas
from public.physical_count_sessions s
join public.warehouses w on w.id = s.warehouse_id
left join public.physical_count_lines l on l.session_id = s.id
where s.business_id = '35c5076a-bd85-4a1b-8d1c-ce719c4f9ae6'
group by s.id, s.code, s.status, w.name, s.notes, s.frozen_at, s.started_at
order by s.started_at desc
limit 15;


-- C ─── Insumos y productos: cuánto hay de cada cosa ──────────────────────────
select
  (select count(*) from public.inventory_items i
    where i.business_id = '35c5076a-bd85-4a1b-8d1c-ce719c4f9ae6')                  as insumos_total,
  (select count(*) from public.inventory_items i
    where i.business_id = '35c5076a-bd85-4a1b-8d1c-ce719c4f9ae6'
      and coalesce(i.is_active, true))                                             as insumos_activos,
  (select count(*) from public.inventory_items i
    where i.business_id = '35c5076a-bd85-4a1b-8d1c-ce719c4f9ae6'
      and coalesce(i.cost, 0) = 0)                                                 as insumos_SIN_COSTO,
  (select count(*) from public.menu_items m
    where m.business_id = '35c5076a-bd85-4a1b-8d1c-ce719c4f9ae6'
      and m.is_active)                                                             as productos_activos,
  (select count(*) from public.menu_items m
    where m.business_id = '35c5076a-bd85-4a1b-8d1c-ce719c4f9ae6'
      and m.is_active and m.is_inventory_tracked)                                  as ya_inventariables,
  (select count(*) from public.menu_items m
    where m.business_id = '35c5076a-bd85-4a1b-8d1c-ce719c4f9ae6'
      and m.is_active and m.inventory_item_id is not null)                         as producto_terminado_directo;


-- D ─── Recetas: cuántas hay y qué tan completas ──────────────────────────────
--     Si esto da 0, todo el consumo de ventas está sin registrar.
select
  count(distinct r.id)                                        as recetas,
  count(ri.*)                                                 as ingredientes,
  count(distinct r.menu_item_id)                              as productos_con_receta,
  count(distinct r.id) filter (where ri.id is null)            as recetas_VACIAS,
  round(avg(x.n), 1)                                          as ingredientes_promedio
from public.recipes r
join public.menu_items m on m.id = r.menu_item_id
                        and m.business_id = '35c5076a-bd85-4a1b-8d1c-ce719c4f9ae6'
left join public.recipe_ingredients ri on ri.recipe_id = r.id
left join lateral (select count(*) n from public.recipe_ingredients z where z.recipe_id = r.id) x on true;


-- E ─── ¿YA se está descontando algo? (la pregunta del doble descuento) ───────
--     Movimientos por tipo desde el congelado. Si hay filas de tipo 'sale',
--     ese consumo YA está aplicado y NO se puede volver a restar.
select
  m.movement_type,
  count(*)                                    as movimientos,
  count(distinct m.item_id)                   as insumos_afectados,
  round(sum(m.quantity), 2)                   as unidades,
  min(m.created_at at time zone 'America/Santo_Domingo')::date as desde,
  max(m.created_at at time zone 'America/Santo_Domingo')::date as hasta
from public.inventory_movements m
where m.business_id = '35c5076a-bd85-4a1b-8d1c-ce719c4f9ae6'
group by m.movement_type
order by movimientos desc;


-- F ─── Compras recibidas: ¿están como movimiento o solo como orden? ──────────
--     Si las compras NO generaron movimiento, hay que sumarlas a mano.
select
  po.status,
  count(*)                                                  as ordenes,
  min(po.created_at at time zone 'America/Santo_Domingo')::date as desde,
  max(po.created_at at time zone 'America/Santo_Domingo')::date as hasta,
  round(sum(coalesce(po.total, 0)), 2)                      as monto
from public.purchase_orders po
where po.business_id = '35c5076a-bd85-4a1b-8d1c-ce719c4f9ae6'
group by po.status
order by ordenes desc;
