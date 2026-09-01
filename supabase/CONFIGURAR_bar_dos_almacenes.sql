-- =============================================================================
-- Bar con 2 almacenes: que la POS muestre SOLO lo que hay en el Bar.
--
-- DESDE 20260901_0005 ESTO SE HACE EN LA APP, NO ACÁ:
--   Inventario → Bodegas → editar la bodega "Bar" → tildar
--   «Mostrar los productos de esta bodega en el punto de venta».
--
--   Con eso el mesero ve la existencia del Bar y la venta descuenta del Bar.
--   Un producto en cero en el Bar no se puede agregar aunque haya 20 en el
--   Principal. Reponer deja de ser un permiso y pasa a ser un traslado.
--
--   No hace falta rutear productos a un área ni prender
--   `warehouse_sections_enabled`: eso es para un restaurante donde cada
--   plato sale de un lado distinto (Cocina, Bar, Food Shop).
--
-- ESTE ARCHIVO SIRVE PARA UNA SOLA COSA: ver qué se va a bloquear ANTES de
-- tildar la casilla. Si la mercancía está toda registrada en el Principal,
-- tildarla bloquea el menú entero en pleno servicio.
--
-- REQUIERE aplicadas: 20260901_0002, 0004 y 0005.
--   Sin la 0004 la vista sigue sumando las dos bodegas: el grid mostraría el
--   total mientras la venta descuenta del Bar. Es la peor combinación.
-- =============================================================================

-- ── 1. El negocio y sus bodegas ─────────────────────────────────────────────
select b.id as business_id, b.business_name,
       w.id as warehouse_id, w.name, w.is_main, w.shows_in_pos, w.is_active
  from public.businesses b
  join public.warehouses w on w.business_id = b.id
 where b.business_name ilike '%<NOMBRE DEL BAR>%'
 order by w.is_main desc, w.name;

-- ── 2. SIMULACIÓN: qué se va a bloquear ─────────────────────────────────────
-- No cambia nada. Compara la existencia del Bar contra el total del negocio.
-- Todo lo que salga marcado deja de poder venderse al tildar la casilla.
select mi.name                                  as producto,
       coalesce(bar.quantity, 0)                as en_el_bar,
       coalesce(tot.total, 0)                   as en_todo_el_negocio,
       case when coalesce(bar.quantity, 0) <= 0
             and coalesce(tot.total, 0) > 0
            then 'SE VA A BLOQUEAR' else '' end as aviso
  from public.menu_items mi
  join public.inventory_items ii on ii.id = mi.inventory_item_id
  left join public.inventory_stock bar
    on bar.item_id = ii.id and bar.warehouse_id = '<WAREHOUSE_ID_DEL_BAR>'
  left join lateral (
    select sum(s.quantity) as total
      from public.inventory_stock s where s.item_id = ii.id
  ) tot on true
 where mi.business_id = '<BUSINESS_ID>'
   and coalesce(mi.is_inventory_tracked, false) = true
   and coalesce(mi.is_active, true)
 order by aviso desc, mi.name;

-- ── 3. ¿Bloquear o solo avisar? ─────────────────────────────────────────────
-- allow_negative_sale = false → el grid BLOQUEA el tap (lo que pidieron).
-- allow_negative_sale = true  → deja vender igual, solo muestra "Agotado".
select coalesce(allow_negative_sale, false) as permite_vender_en_cero,
       count(*) as productos
  from public.menu_items
 where business_id = '<BUSINESS_ID>'
   and coalesce(is_inventory_tracked, false) = true
 group by 1;

-- Para bloquear de verdad (revisar el conteo de arriba antes):
-- update public.menu_items
--    set allow_negative_sale = false
--  where business_id = '<BUSINESS_ID>'
--    and coalesce(is_inventory_tracked, false) = true;

-- ── 4. Cargar el Bar antes de tildar ────────────────────────────────────────
-- Conteo físico del Bar (deja la existencia real) o transferencia
-- Principal → Bar desde Inventario → Transferencias. NO por SQL: los dos
-- caminos dejan kardex y este no.

-- ── SALIDA DE EMERGENCIA, si algo sale mal en pleno servicio ────────────────
-- Destildar la casilla en la app, o:
-- update public.warehouses set shows_in_pos = false
--  where business_id = '<BUSINESS_ID>';
-- Vuelve al instante a la bodega principal. No hay que reiniciar nada.
