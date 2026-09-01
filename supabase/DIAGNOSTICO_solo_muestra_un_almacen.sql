-- =============================================================================
-- "Activé 2 almacenes y solo me muestra los artículos de 1"
--
-- Las dos causas posibles, y cómo se distinguen:
--
--   A) Los productos NO están ruteados a un área. Entonces NINGUNO resuelve
--      por área y todos caen en el mismo sitio: la bodega marcada para el
--      punto de venta, o la principal. Da igual cuántos almacenes tengan
--      área asignada — el ruteo del producto es lo que decide.
--
--   B) Los productos SÍ están ruteados, pero la segunda bodega está en cero,
--      así que sus productos aparecen agotados (o se auto-apagaron y
--      desaparecieron del menú).
--
-- Correr una sentencia a la vez.
-- =============================================================================

-- ── 1. RESUMEN: a qué bodega va a parar cada producto ───────────────────────
-- Si TODO cae en una sola fila, es la causa A: falta rutear los productos.
with resuelto as (
  select mi.id, mi.name, mi.inventory_item_id,
         public.fn_resolve_consumption_warehouse(
           mi.business_id, mi.id,
           (select w.id from public.warehouses w
             where w.business_id = mi.business_id
             order by w.is_main desc, w.created_at asc nulls first, w.id asc
             limit 1)
         ) as wid
    from public.menu_items mi
   where mi.business_id = '<BUSINESS_ID>'
     and coalesce(mi.is_inventory_tracked, false) = true
     and coalesce(mi.is_active, true)
)
select coalesce(w.name, '(sin resolver)') as bodega_que_usa,
       w.warehouse_type, w.shows_in_pos,
       count(*)                            as productos
  from resuelto r
  left join public.warehouses w on w.id = r.wid
 group by 1, 2, 3
 order by 4 desc;

-- ── 2. ¿Están ruteados los productos? ───────────────────────────────────────
-- "— SIN ÁREA —" grande = causa A confirmada.
select coalesce(pa.name, '— SIN ÁREA —') as area, count(*) as productos
  from public.menu_items mi
  left join public.menu_item_print_areas mipa on mipa.menu_item_id = mi.id
  left join public.print_areas pa
    on pa.id = mipa.print_area_id
    or (mipa.print_area_id is null and pa.business_id = mi.business_id
        and pa.code = mi.print_area_code)
 where mi.business_id = '<BUSINESS_ID>'
   and coalesce(mi.is_inventory_tracked, false) = true
   and coalesce(mi.is_active, true)
 group by 1 order by 2 desc;

-- ── 3. ¿Se auto-apagaron productos? ─────────────────────────────────────────
-- Si esto devuelve filas, el auto-86 los sacó del menú por falta de
-- existencia en su bodega. Desaparecen del grid, no salen "agotados".
select name, auto_disabled, is_active
  from public.menu_items
 where business_id = '<BUSINESS_ID>'
   and auto_disabled = true
   and is_active = false
 order by name;

-- ── 4. Cómo está configurado cada almacén ───────────────────────────────────
select w.name, w.is_main, w.is_active, w.warehouse_type, w.shows_in_pos,
       pa.name as area_asignada,
       (select count(*) from public.inventory_stock s
         where s.warehouse_id = w.id and s.quantity > 0) as insumos_con_existencia
  from public.warehouses w
  left join public.print_areas pa on pa.id = w.production_area_id
 where w.business_id = '<BUSINESS_ID>'
 order by w.is_main desc, w.name;

-- ── SALIDA DE EMERGENCIA ────────────────────────────────────────────────────
-- Vuelve todo a como estaba, al instante, sin reiniciar nada:
-- update public.business_settings
--    set warehouse_sections_enabled = false where business_id = '<BUSINESS_ID>';
-- update public.warehouses set shows_in_pos = false
--  where business_id = '<BUSINESS_ID>';
--
-- Y si el auto-86 apagó productos, esto los devuelve al menú:
-- update public.menu_items set is_active = true, auto_disabled = false
--  where business_id = '<BUSINESS_ID>' and auto_disabled = true;
