-- =============================================================================
-- LA PENDA EXPRESS · ACTIVAR INVENTARIO — ESTADO FINAL (12-oct)
-- business_id = 35c5076a-bd85-4a1b-8d1c-ce719c4f9ae6
--
-- SOLO LECTURA. UNA sola consulta. Dice qué quedó aplicado y cómo está el
-- stock, sin depender de las tablas auxiliares de los scripts.
--
--   F1  conteos: octubre cerrado, septiembre abierto
--   F2  áreas: cuántos productos por área, y los quipes donde deben (COCINA)
--   F3  recetas: encendidas, venta en negativo, apagados por auto-86
--   F4  consumo hacia atrás (PASO R2) y su cuadre
--   F5  almacenes: quién descuenta qué
--   F6  transferencias registradas hoy
--   F7  stock por almacén: con existencia, en negativo, valor
-- =============================================================================

with
biz as (select '35c5076a-bd85-4a1b-8d1c-ce719c4f9ae6'::uuid as id),
areas_prod as (
  select m.id, m.name, coalesce(m.is_active, true) as activo,
         coalesce(
           (select string_agg(pa.name, ' + ' order by pa.name)
              from public.menu_item_print_areas x
              join public.print_areas pa on pa.id = x.print_area_id
             where x.menu_item_id = m.id),
           (select pa.name from public.print_areas pa
             where pa.business_id = m.business_id and pa.code = m.print_area_code
             limit 1),
           '(sin área)') as area
    from public.menu_items m, biz
   where m.business_id = biz.id
),
filas as (
  -- F1
  select 1 as orden, 'F1 conteos' as seccion, s.code as dato,
         s.status || coalesce(' · cerrado ' || to_char(s.completed_at at time zone
                     'America/Santo_Domingo', 'DD-Mon HH24:MI'), '')
         || ' · ' || coalesce(s.notes, '') as valor
    from public.physical_count_sessions s, biz
   where s.business_id = biz.id and s.started_at >= '2026-09-01'
     and s.status <> 'cancelled'
  union all
  -- F2
  select 2, 'F2 áreas (productos activos)', area, count(*)::text
    from areas_prod where activo group by area
  union all
  select 2, 'F2 áreas (productos activos)', 'quipes → ' || string_agg(distinct area, ', '),
         string_agg(name || ': ' || area, ' · ' order by name)
    from areas_prod where activo and upper(name) like 'QUIPE%'
  union all
  -- F3
  select 3, 'F3 recetas', 'encendidas / total',
         count(*) filter (where m.is_inventory_tracked) || ' / ' || count(*)
    from public.menu_items m, biz
   where m.business_id = biz.id
     and exists (select 1 from public.recipes r where r.menu_item_id = m.id)
  union all
  select 3, 'F3 recetas', 'descuentan SIN venta en negativo (debe ser 0)',
         count(*)::text
    from public.menu_items m, biz
   where m.business_id = biz.id and m.is_inventory_tracked
     and not coalesce(m.allow_negative_sale, false)
     and (m.inventory_item_id is not null
          or exists (select 1 from public.recipes r where r.menu_item_id = m.id))
  union all
  select 3, 'F3 recetas', 'apagados por auto-86 (debe ser 0)',
         count(*)::text
    from public.menu_items m, biz
   where m.business_id = biz.id and coalesce(m.auto_disabled, false)
     and not coalesce(m.is_active, true)
  union all
  select 3, 'F3 recetas', 'inventario por área',
         coalesce((select bs.warehouse_sections_enabled::text from public.business_settings bs, biz
                    where bs.business_id = biz.id), '?')
  union all
  -- F4
  select 4, 'F4 consumo hacia atrás', x.tipo,
         count(*) || ' movimientos · ' || count(distinct x.item_id) || ' insumos · '
         || count(distinct x.reference_id) filter (where x.reference_type = 'order') || ' órdenes'
    from (select im.item_id, im.reference_id, im.reference_type,
                 case when im.reference_type = 'recetas_cuadre'
                      then 'cuadre (' || im.movement_type::text || ')'
                      else 'consumo de recetas' end as tipo
            from public.inventory_movements im, biz
           where im.business_id = biz.id
             and (im.notes like 'Consumo de receta asentado al encender%'
                  or im.reference_type = 'recetas_cuadre')) x
   group by x.tipo
  union all
  -- F5
  select 5, 'F5 almacenes', w.name,
         case when w.warehouse_type = 'production'
                   and coalesce((select bs.warehouse_sections_enabled from public.business_settings bs
                                  where bs.business_id = w.business_id), false)
              then 'descuenta su área: ' || coalesce(pa.name, '(SIN ÁREA)')
              when w.shows_in_pos then 'sale en POS (lo que no tenga almacén de área)'
              else 'no vende' end
    from public.warehouses w
    left join public.print_areas pa on pa.id = w.production_area_id, biz
   where w.business_id = biz.id and coalesce(w.is_active, true)
  union all
  -- F6
  select 6, 'F6 transferencias hoy', coalesce(im.reference_type, '(sin tipo)'),
         count(*) || ' movimientos · ' || count(distinct im.item_id) || ' insumos'
    from public.inventory_movements im, biz
   where im.business_id = biz.id
     and im.movement_type::text in ('transfer_in','transfer_out')
     and im.created_at >= (date_trunc('day', now() at time zone 'America/Santo_Domingo')
                           at time zone 'America/Santo_Domingo')
   group by im.reference_type
  union all
  -- F7
  select 7, 'F7 stock', w.name,
         count(*) filter (where st.quantity > 0) || ' con existencia · '
         || count(*) filter (where st.quantity < 0) || ' en negativo · valor '
         || coalesce(to_char(sum(st.quantity * coalesce(i.cost, 0)) filter (where st.quantity > 0),
                             'FM999,999,990.00'), '0')
    from public.inventory_stock st
    join public.warehouses w on w.id = st.warehouse_id
    join public.inventory_items i on i.id = st.item_id, biz
   where w.business_id = biz.id
   group by w.name
)
select seccion, dato, valor from filas order by orden, dato;
