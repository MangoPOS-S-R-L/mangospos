-- Tiempo Extra: pollo con crema, único producto del resultado con stock 5.
-- Es un candidato: falta confirmar que sea la empanada afectada.
-- SOLO LECTURA. Ejecutar los bloques POR SEPARADO en Supabase SQL Editor.

-- 1. Configuración actual y relación real entre menú e inventario.
-- Una receta existente tiene prioridad sobre el vínculo directo.
select mi.id as producto_id, mi.name as producto,
  to_jsonb(mi)->>'item_type' as tipo_producto,
  to_jsonb(mi)->>'is_inventory_tracked' as inventariable,
  to_jsonb(mi)->>'inventory_item_id' as vinculo_directo,
  s.available_units as stock_pos,
  to_jsonb(s)->>'inventory_item_id' as insumo_vista_pos,
  to_jsonb(s)->>'raw_ingredient_stock' as stock_insumo_vista_pos,
  to_jsonb(s)->>'ingredient_per_unit' as insumo_por_empanada_vista_pos,
  coalesce((
    select jsonb_agg(jsonb_build_object(
      'receta_id', r.id,
      'ingredientes', coalesce((
        select jsonb_agg(jsonb_build_object(
          'item_id', ri.inventory_item_id, 'inventariable', ii.name,
          'cantidad_por_empanada', ri.quantity, 'unidad', ri.unit
        ) order by ri.id)
        from public.recipe_ingredients ri
        left join public.inventory_items ii on ii.id = ri.inventory_item_id
        where ri.recipe_id = r.id
      ), '[]'::jsonb)
    ) order by r.id)
    from public.recipes r where r.menu_item_id = mi.id
  ), '[]'::jsonb) as recetas
from public.menu_items mi
left join public.v_menu_items_stock s on s.menu_item_id = mi.id
where mi.business_id = '1eee0122-3181-496c-969e-0a0c06448932'::uuid
  and mi.id = 'bff11ba2-dcf5-458b-90a8-746d1b28a49b'::uuid;

-- 2. Últimos 50 movimientos del inventariable de crema identificado antes.
-- Incluye compras, ajustes, merma y devoluciones; NO filtra solo venta.
-- Es una muestra, no el saldo total de todo el historial.
-- Los estados/cierres de las órdenes son actuales, no históricos.
with ultimos as materialized (
  select im.*
  from public.inventory_movements im
  where im.business_id = '1eee0122-3181-496c-969e-0a0c06448932'::uuid
    and im.item_id = 'b5dfb662-3409-4a2c-be56-67743fd1fd2a'::uuid
  order by im.created_at desc, im.id desc
  limit 50
)
select im.created_at at time zone 'America/Santo_Domingo' as fecha_rd,
  im.id as movimiento_id, im.movement_type::text as tipo, im.quantity,
  im.reference_type, im.reference_id, w.name as bodega,
  im.notes, o.status as orden_estado_actual,
  o.status_ext::text as orden_estado_ext_actual,
  o.closed_at at time zone 'America/Santo_Domingo' as orden_cierre_rd
from ultimos im
left join public.warehouses w on w.id = im.warehouse_id
left join public.orders o on o.id = im.reference_id
  and im.reference_type in ('order', 'order_item_removal')
  and exists (
    select 1 from public.table_sessions ts
    where ts.id = o.session_id and ts.business_id = im.business_id
  )
order by im.created_at desc, im.id desc;

-- 3. Existencias actuales del mismo insumo por bodega.
-- El stock POS puede usar solo algunas bodegas según su configuración.
select ii.id as item_id, ii.name as inventariable, ii.unit as unidad,
  w.id as warehouse_id, w.name as bodega, w.is_active,
  to_jsonb(w)->>'shows_in_pos' as muestra_en_pos,
  to_jsonb(w)->>'warehouse_type' as tipo_bodega,
  s.quantity as existencia_actual,
  s.last_updated at time zone 'America/Santo_Domingo' as actualizada_rd
from public.inventory_items ii
join public.warehouses w on w.business_id = ii.business_id
left join public.inventory_stock s on s.item_id = ii.id and s.warehouse_id = w.id
where ii.business_id = '1eee0122-3181-496c-969e-0a0c06448932'::uuid
  and ii.id = 'b5dfb662-3409-4a2c-be56-67743fd1fd2a'::uuid
order by w.name, w.id;
