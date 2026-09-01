-- =============================================================================
-- Dos bodegas alimentando la POS, cada una con sus productos.
--
-- SITUACIÓN (diagnóstico 2026-08-31):
--   · Bodega Principal  → área Bar, 40 insumos con existencia
--   · Bode Real Food Park → sin área, marcada shows_in_pos, 2 insumos
--   · 6 productos ruteados a Bar, 2 a Cocina
--   · Cocina no tiene bodega → sus 2 productos caen en la principal
--
-- LO QUE FALTA: darle a Cocina su bodega. Marcar las DOS con la casilla del
-- punto de venta no serviría: eso sumaría las dos y los 8 productos verían el
-- mismo total. El área es lo que reparte producto por producto.
--
-- Correr una sentencia a la vez y leer lo que devuelve.
-- =============================================================================

-- ── 1. Simulación ANTES de tocar nada ───────────────────────────────────────
-- Qué existencia tendría cada producto si Cocina se atara a Bode Real.
-- Lo que salga marcado se va a bloquear en la venta.
with cfg as (
  select
    (select id from public.warehouses
      where business_id = '<BUSINESS_ID>' and name = 'Bodega Principal') as w_bar,
    (select id from public.warehouses
      where business_id = '<BUSINESS_ID>' and name = 'Bode Real Food Park') as w_cocina
),
ruteo as (
  select mi.id, mi.name, mi.inventory_item_id,
         max(pa.name) as area
    from public.menu_items mi
    left join public.menu_item_print_areas mipa on mipa.menu_item_id = mi.id
    left join public.print_areas pa
      on pa.id = mipa.print_area_id
      or (mipa.print_area_id is null and pa.business_id = mi.business_id
          and pa.code = mi.print_area_code)
   where mi.business_id = '<BUSINESS_ID>'
     and coalesce(mi.is_inventory_tracked, false) = true
     and coalesce(mi.is_active, true)
   group by mi.id, mi.name, mi.inventory_item_id
)
select r.name as producto, r.area,
       case r.area when 'Bar' then 'Bodega Principal'
                   when 'Cocina' then 'Bode Real Food Park'
                   else '(sin área → la principal)' end as bodega_que_usaria,
       coalesce((
         select sum(s.quantity) from public.inventory_stock s
          where s.item_id = r.inventory_item_id
            and s.warehouse_id = case r.area when 'Cocina' then c.w_cocina
                                             else c.w_bar end
       ), 0) as va_a_mostrar,
       coalesce((
         select sum(s.quantity) from public.inventory_stock s
          where s.item_id = r.inventory_item_id
       ), 0) as muestra_hoy
  from ruteo r cross join cfg c
 order by r.area, r.name;

-- ── 2. Atar Cocina a su bodega ──────────────────────────────────────────────
-- (o hacerlo en la app: Inventario → Bodegas → editar → «Está asignado a un
--  área de producción» → Cocina. Es lo mismo.)
update public.warehouses
   set warehouse_type     = 'production',
       production_area_id = (select id from public.print_areas
                              where business_id = '<BUSINESS_ID>'
                                and name = 'Cocina' limit 1),
       shows_in_pos       = false   -- ya no hace falta: el área la reemplaza
 where business_id = '<BUSINESS_ID>'
   and name = 'Bode Real Food Park';

-- ── 3. Prender la resolución por área ───────────────────────────────────────
-- Solo después de que la 1 salga limpia.
update public.business_settings
   set warehouse_sections_enabled = true
 where business_id = '<BUSINESS_ID>';

-- ── 4. Comprobar ────────────────────────────────────────────────────────────
-- Ahora tienen que salir DOS filas, una por bodega.
select coalesce(w.name, '(sin resolver)') as bodega_que_usa,
       count(*) as productos
  from public.menu_items mi
  left join public.warehouses w
    on w.id = public.fn_resolve_consumption_warehouse(
                mi.business_id, mi.id, null)
 where mi.business_id = '<BUSINESS_ID>'
   and coalesce(mi.is_inventory_tracked, false) = true
   and coalesce(mi.is_active, true)
 group by 1 order by 2 desc;

-- ── SALIDA DE EMERGENCIA ────────────────────────────────────────────────────
-- update public.business_settings
--    set warehouse_sections_enabled = false where business_id = '<BUSINESS_ID>';
