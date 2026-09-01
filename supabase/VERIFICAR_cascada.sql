-- =============================================================================
-- Verificar el reparto en cascada después de aplicar 20260901_0006.
--
-- La lógica del reparto NO está probada contra un servidor (no hay Postgres
-- local). Estas cuatro consultas la comprueban sobre datos reales antes de
-- confiarle una venta.
--
-- Correr una a la vez.
-- =============================================================================

-- ── 1. ¿Quedó aplicada? ─────────────────────────────────────────────────────
select
  exists (select 1 from pg_proc p join pg_namespace n on n.oid=p.pronamespace
           where n.nspname='public' and p.proname='fn_pos_stock_warehouses')
    as helper_existe,                       -- true
  exists (select 1 from pg_proc p join pg_namespace n on n.oid=p.pronamespace
           where n.nspname='public' and p.proname='fn_resolve_area_warehouse')
    as area_existe,                         -- true
  exists (select 1 from pg_indexes
           where schemaname='public' and indexname='uq_warehouses_pos_source')
    as indice_unico_todavia,                -- false: ya se puede marcar varias
  exists (select 1 from pg_indexes
           where schemaname='public' and indexname='idx_warehouses_pos_source')
    as indice_nuevo;                        -- true

-- ── 2. El orden de la cascada ───────────────────────────────────────────────
-- La primera fila es de donde descuenta primero.
select w.name, w.is_main, w.created_at,
       row_number() over (order by w.is_main desc,
                                   w.created_at asc nulls first,
                                   w.id asc) as orden_de_cascada
  from public.warehouses w
 where w.business_id = '<BUSINESS_ID>'
   and coalesce(w.is_active, true)
   and w.shows_in_pos
 order by orden_de_cascada;

-- ── 3. Qué bodegas ve cada producto ─────────────────────────────────────────
-- Un solo id = resuelve por área. Varios = usa la cascada. NULL = todas.
select mi.name as producto,
       (select array_agg(w.name order by array_position(ids.arr, w.id))
          from public.warehouses w
         where w.id = any(ids.arr)) as bodegas_que_ve
  from public.menu_items mi
  cross join lateral (
    select public.fn_pos_stock_warehouses(mi.business_id, mi.id) as arr
  ) ids
 where mi.business_id = '<BUSINESS_ID>'
   and coalesce(mi.is_inventory_tracked, false) = true
   and coalesce(mi.is_active, true)
 order by mi.name;

-- ── 4. LA PRUEBA DE FUEGO ───────────────────────────────────────────────────
-- Después de vender UN producto que use la cascada, mirar sus movimientos.
-- Si el reparto funciona, una venta que supere la existencia de la primera
-- bodega tiene que salir en DOS filas (una por bodega), no en una sola.
--
-- Pegar el id de la orden recién cobrada:
select w.name as bodega, im.item_id, im.quantity, im.notes, im.created_at
  from public.inventory_movements im
  join public.warehouses w on w.id = im.warehouse_id
 where im.reference_id = '<ORDER_ID>'
   and im.reference_type = 'order'
   and im.movement_type = 'sale'
 order by im.created_at, w.name;

-- QUÉ TIENE QUE PASAR, con la barra en 6 y vendiendo 10:
--   barra   -6
--   nevera  -4
-- LO QUE NO PUEDE PASAR (sería el bug que esta migración viene a evitar):
--   barra   -6  y después  +6
--   nevera  -10
