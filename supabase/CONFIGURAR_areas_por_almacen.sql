-- =============================================================================
-- Mismo insumo, dos formas de venderlo: "Brugal botella" del Food Shop y
-- "Brugal trago" del Bar, cada uno con su propio número.
--
-- ESTO NO SE RESUELVE MARCANDO VARIAS BODEGAS PARA LA POS. Sumarlas mostraría
-- el mismo total en los dos productos y ninguno diría la verdad. Se resuelve
-- por ÁREA: cada producto lee de la bodega de su área.
--
-- QUÉ HAY QUE CONFIGURAR (en la app, no acá):
--   1. Inventario → Bodegas → cada almacén: tildar «Está asignado a un área
--      de producción» y elegir la suya (Bar → área Bar, Food Shop → área
--      Food Shop).
--   2. Cada producto ruteado a su área — es el mismo ruteo que ya manda la
--      comanda a su impresora.
--   3. Ajustes → Funciones del negocio → «Almacenes por área de producción».
--
-- ESTE ARCHIVO ES PARA VER SI EL PASO 2 ESTÁ HECHO Y QUÉ VA A PASAR ANTES DE
-- PRENDER NADA. Correr una sentencia a la vez.
--
-- REQUIERE aplicadas: 20260901_0002, 0004 y 0005.
-- =============================================================================

-- ── 1. Áreas y qué almacén tiene cada una ───────────────────────────────────
select pa.id as area_id, pa.name as area, pa.code,
       w.name as almacen_asignado, w.warehouse_type, w.shows_in_pos
  from public.print_areas pa
  left join public.warehouses w on w.production_area_id = pa.id
 where pa.business_id = '<BUSINESS_ID>'
 order by pa.display_order, pa.name;

-- ── 2. ¿Los productos están ruteados? ───────────────────────────────────────
-- Un producto SIN área cae en la bodega marcada para la POS, y si no hay
-- ninguna, en la principal. Los "sin_area" son los que hay que rutear.
select coalesce(pa.name, '— SIN ÁREA —') as area,
       count(*)                          as productos
  from public.menu_items mi
  left join public.menu_item_print_areas mipa on mipa.menu_item_id = mi.id
  left join public.print_areas pa
    on pa.id = mipa.print_area_id
    or (mipa.print_area_id is null
        and pa.business_id = mi.business_id
        and pa.code = mi.print_area_code)
 where mi.business_id = '<BUSINESS_ID>'
   and coalesce(mi.is_inventory_tracked, false) = true
   and coalesce(mi.is_active, true)
 group by 1
 order by 2 desc;

-- ── 3. SIMULACIÓN: qué bodega y qué número va a ver cada producto ───────────
-- Replica la resolución SIN depender de la bandera, para verlo antes de
-- prenderla. La columna `va_a_mostrar` es lo que verá el mesero; `muestra_hoy`
-- es lo que ve ahora sumando todas las bodegas. Donde difieran, ahí está el
-- cambio.
--
-- Los que caigan en «(la de siempre)» son los que NO tienen área: van a leer
-- de la bodega principal, no de la suma. Si no querés que ninguno caiga ahí,
-- hay que rutearlos (consulta 2).
with principal as (
  select w.id
    from public.warehouses w
   where w.business_id = '<BUSINESS_ID>'
   order by w.is_main desc, w.created_at asc nulls first, w.id asc
   limit 1
),
resuelto as (
  select
    mi.id, mi.name, mi.inventory_item_id,
    coalesce(
      (
        select w.id
          from public.warehouses w
          join public.print_areas pa on pa.id = w.production_area_id
         where w.business_id = mi.business_id
           and coalesce(w.is_active, true)
           and w.warehouse_type = 'production'
           and pa.id in (
             select x.print_area_id from public.menu_item_print_areas x
              where x.menu_item_id = mi.id
             union all
             select pa2.id from public.print_areas pa2
              where pa2.business_id = mi.business_id
                and pa2.code = mi.print_area_code
                and mi.print_area_code is not null
                and not exists (select 1 from public.menu_item_print_areas y
                                 where y.menu_item_id = mi.id)
           )
         order by coalesce(pa.display_order, 0), pa.name, w.id
         limit 1
      ),
      (select w.id from public.warehouses w
        where w.business_id = mi.business_id
          and coalesce(w.is_active, true) and w.shows_in_pos limit 1),
      (select id from principal)
    ) as wid,
    exists (
      select 1 from public.menu_item_print_areas x where x.menu_item_id = mi.id
    ) or mi.print_area_code is not null as tiene_area
  from public.menu_items mi
 where mi.business_id = '<BUSINESS_ID>'
   and coalesce(mi.is_inventory_tracked, false) = true
   and coalesce(mi.is_active, true)
)
select r.name                                        as producto,
       case when r.tiene_area then coalesce(w.name, '?')
            else coalesce(w.name, '?') || '  (la de siempre)' end
                                                     as bodega_que_va_a_usar,
       coalesce(sc.qty, 0)                           as va_a_mostrar,
       coalesce(tot.total, 0)                        as muestra_hoy,
       case when coalesce(sc.qty, 0) <= 0 and coalesce(tot.total, 0) > 0
            then 'SE VA A BLOQUEAR' else '' end      as aviso
  from resuelto r
  left join public.warehouses w on w.id = r.wid
  left join lateral (
    select sum(s.quantity) as qty from public.inventory_stock s
     where s.item_id = r.inventory_item_id and s.warehouse_id = r.wid
  ) sc on true
  left join lateral (
    select sum(s.quantity) as total from public.inventory_stock s
     where s.item_id = r.inventory_item_id
  ) tot on true
 order by aviso desc, r.tiene_area, r.name;
