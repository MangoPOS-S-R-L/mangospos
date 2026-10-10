-- Tiempo Extra: localizar lasaña/lasana/lasagna sin asumir su UUID.
-- SOLO LECTURA. Ejecutar cada bloque POR SEPARADO en Supabase SQL Editor.
-- Incluye fichas inactivas y no inventariables; no exige la palabra empanada.

-- 1. Fichas del menú: stock POS, tracking, vínculo directo y recetas.
with productos as materialized (
  select mi.*
  from public.menu_items mi
  where mi.business_id = '1eee0122-3181-496c-969e-0a0c06448932'::uuid
    and translate(lower(mi.name), 'áéíóúñ', 'aeioun') ~ '(lasan|lasagn|lazan|lazagn)'
  order by mi.name, mi.id
  limit 20
)
select mi.id as producto_id, mi.name as producto, mi.is_active as activo,
  to_jsonb(mi)->>'item_type' as tipo_producto,
  to_jsonb(mi)->>'is_inventory_tracked' as inventariable,
  coalesce(to_jsonb(bs)->>'inventory_mode', 'none') as modo_inventario,
  to_jsonb(mi)->>'inventory_item_id' as vinculo_directo,
  ii.name as inventariable_directo,
  s.available_units as stock_pos,
  to_jsonb(s)->>'inventory_item_id' as insumo_vista_pos,
  to_jsonb(s)->>'raw_ingredient_stock' as stock_insumo_vista_pos,
  to_jsonb(s)->>'ingredient_per_unit' as insumo_por_unidad_vista_pos,
  coalesce((
    select jsonb_agg(jsonb_build_object(
      'receta_id', r.id,
      'ingredientes', coalesce((
        select jsonb_agg(jsonb_build_object(
          'item_id', ri.inventory_item_id, 'inventariable', i.name,
          'cantidad_por_unidad', ri.quantity, 'unidad', ri.unit
        ) order by ri.id)
        from public.recipe_ingredients ri
        left join public.inventory_items i
          on i.id = ri.inventory_item_id and i.business_id = mi.business_id
        where ri.recipe_id = r.id
      ), '[]'::jsonb)
    ) order by r.id)
    from public.recipes r where r.menu_item_id = mi.id
  ), '[]'::jsonb) as recetas
from productos mi
left join public.business_settings bs on bs.business_id = mi.business_id
left join public.inventory_items ii
  on ii.id = nullif(to_jsonb(mi)->>'inventory_item_id', '')::uuid
  and ii.business_id = mi.business_id
left join public.v_menu_items_stock s on s.menu_item_id = mi.id
order by mi.name, mi.id;

-- 2. Fichas del inventario con nombre lasaña y sus productos relacionados.
-- Una ficha nominal del inventario NO demuestra que la POS la consuma.
-- existencia_total suma todas las bodegas; no equivale al stock POS.
with insumos as materialized (
  select ii.*
  from public.inventory_items ii
  where ii.business_id = '1eee0122-3181-496c-969e-0a0c06448932'::uuid
    and translate(lower(ii.name), 'áéíóúñ', 'aeioun') ~ '(lasan|lasagn|lazan|lazagn)'
  order by ii.name, ii.id
  limit 20
)
select ii.id as item_id, ii.name as inventariable, ii.is_active as activo, ii.unit,
  (select sum(s.quantity) from public.inventory_stock s
   join public.warehouses w on w.id = s.warehouse_id
   where s.item_id = ii.id and w.business_id = ii.business_id) as existencia_total,
  coalesce((
    select jsonb_agg(jsonb_build_object(
      'producto_id', mi.id, 'producto', mi.name, 'activo', mi.is_active,
      'tracking', to_jsonb(mi)->>'is_inventory_tracked',
      'link_directo', to_jsonb(mi)->>'inventory_item_id'
    ) order by mi.name, mi.id)
    from public.menu_items mi
    where mi.business_id = ii.business_id
      and (nullif(to_jsonb(mi)->>'inventory_item_id', '')::uuid = ii.id
        or exists (
          select 1 from public.recipes r
          join public.recipe_ingredients ri on ri.recipe_id = r.id
          where r.menu_item_id = mi.id and ri.inventory_item_id = ii.id
        ))
  ), '[]'::jsonb) as productos_relacionados
from insumos ii
order by ii.name, ii.id;

-- 3. Últimos 50 movimientos de los insumos encontrados por nombre o vínculo.
-- Incluye todas las clases/referencias: venta, devolución, merma y entradas.
-- Los insumos de receta pueden compartirse con otros productos: el nombre
-- por sí solo NO atribuye cada movimiento a una venta de empanada de lasaña.
-- Los estados de las órdenes son actuales. Esta muestra no es un saldo total.
with productos as materialized (
  select mi.id, mi.business_id,
    nullif(to_jsonb(mi)->>'inventory_item_id', '')::uuid as directo_id
  from public.menu_items mi
  where mi.business_id = '1eee0122-3181-496c-969e-0a0c06448932'::uuid
    and translate(lower(mi.name), 'áéíóúñ', 'aeioun') ~ '(lasan|lasagn|lazan|lazagn)'
), insumos as (
  select directo_id as item_id from productos where directo_id is not null
  union
  select ri.inventory_item_id
  from productos mi join public.recipes r on r.menu_item_id = mi.id
  join public.recipe_ingredients ri on ri.recipe_id = r.id
  union
  select ii.id from public.inventory_items ii
  where ii.business_id = '1eee0122-3181-496c-969e-0a0c06448932'::uuid
    and translate(lower(ii.name), 'áéíóúñ', 'aeioun') ~ '(lasan|lasagn|lazan|lazagn)'
), ultimos as materialized (
  select im.*
  from public.inventory_movements im
  join insumos i on i.item_id = im.item_id
  where im.business_id = '1eee0122-3181-496c-969e-0a0c06448932'::uuid
  order by im.created_at desc, im.id desc
  limit 50
)
select im.created_at at time zone 'America/Santo_Domingo' as fecha_rd,
  im.id as movimiento_id, im.item_id, ii.name as inventariable,
  im.movement_type::text as tipo, im.quantity,
  im.reference_type, im.reference_id, w.name as bodega,
  im.notes, o.status as orden_estado_actual,
  o.status_ext::text as orden_estado_ext_actual,
  o.closed_at at time zone 'America/Santo_Domingo' as orden_cierre_rd
from ultimos im
left join public.inventory_items ii on ii.id = im.item_id and ii.business_id = im.business_id
left join public.warehouses w on w.id = im.warehouse_id and w.business_id = im.business_id
left join public.orders o on o.id = im.reference_id
  and im.reference_type in ('order', 'order_item_removal')
  and exists (
    select 1 from public.table_sessions ts
    where ts.id = o.session_id and ts.business_id = im.business_id
  )
order by im.created_at desc, im.id desc;

-- 4. Seleccionar y ejecutar SOLO este bloque para la orden del 2 de octubre.
-- Devolvió 4 lasañas y luego consumió 4 unidades del insumo DONA PIZZA 3.
-- Verifica renglones actuales, fechas de pago y renglones del comprobante.
-- Un comprobante cancelado no prueba qué se cobró finalmente. Las recetas
-- mostradas son actuales y no reconstruyen su configuración histórica.
with parametros as (
  select '1eee0122-3181-496c-969e-0a0c06448932'::uuid as business_id,
    'd26981a8-8db6-4ba8-854f-5ab48c22d5b7'::uuid as orden_id
), orden as materialized (
  select o.*, ts.origin::text as origen
  from parametros p join public.orders o on o.id = p.orden_id
  join public.table_sessions ts on ts.id = o.session_id and ts.business_id = p.business_id
), movimientos as materialized (
  select im.*
  from parametros p join public.inventory_movements im
    on im.business_id = p.business_id and im.reference_id = p.orden_id
  where im.reference_type in ('order', 'order_item_removal')
), netos as (
  select im.item_id, im.warehouse_id,
    coalesce(-sum(im.quantity) filter (where im.movement_type::text = 'sale'), 0) as consumo_venta_neto,
    coalesce(-sum(im.quantity) filter (where im.movement_type::text = 'waste'), 0) as consumo_merma_neto,
    -sum(im.quantity) as consumo_total_neto
  from movimientos im group by im.item_id, im.warehouse_id
)
select p.orden_id, o.id is not null as orden_encontrada_en_negocio,
  o.status as estado_actual, o.status_ext::text as estado_ext_actual, o.origen,
  o.total as total_orden_actual,
  o.closed_at at time zone 'America/Santo_Domingo' as cierre_rd,
  to_regclass('public.order_item_removals') is not null as tiene_auditoria,
  coalesce((
    select jsonb_agg(jsonb_build_object(
      'renglon_id', oi.id, 'product_id', oi.product_id,
      'nombre_menu_actual', mi.name, 'nombre_guardado_en_venta', oi.product_name,
      'status', oi.status::text, 'qty', oi.qty, 'quantity', oi.quantity,
      'unit_price', oi.unit_price, 'check_id', oi.check_id,
      'creado_rd', oi.created_at at time zone 'America/Santo_Domingo',
      'tracking_actual', to_jsonb(mi)->>'is_inventory_tracked',
      'tipo_producto_actual', to_jsonb(mi)->>'item_type',
      'link_directo_actual', to_jsonb(mi)->>'inventory_item_id',
      'recetas_actuales', coalesce((
        select jsonb_agg(jsonb_build_object(
          'receta_id', r.id,
          'ingredientes', coalesce((
            select jsonb_agg(jsonb_build_object(
              'item_id', ri.inventory_item_id, 'cantidad_por_unidad', ri.quantity
            ) order by ri.id)
            from public.recipe_ingredients ri where ri.recipe_id = r.id
          ), '[]'::jsonb)
        ) order by r.id)
        from public.recipes r where r.menu_item_id = mi.id
      ), '[]'::jsonb)
    ) order by oi.created_at, oi.id)
    from public.order_items oi
    left join public.menu_items mi on mi.id = oi.product_id and mi.business_id = p.business_id
    where oi.order_id = o.id
  ), '[]'::jsonb) as items_actuales,
  coalesce((
    select jsonb_agg(jsonb_build_object(
      'pago_id', pay.id, 'fecha_rd', pay.created_at at time zone 'America/Santo_Domingo',
      'status', pay.status, 'amount', pay.amount, 'check_id', pay.check_id
    ) order by pay.created_at, pay.id)
    from public.payments pay where pay.business_id = p.business_id and pay.order_id = p.orden_id
  ), '[]'::jsonb) as pagos,
  coalesce((
    select jsonb_agg(jsonb_build_object(
      'documento_id', fd.id, 'status', fd.status,
      'emitido_rd', fd.issued_at at time zone 'America/Santo_Domingo', 'total', fd.total,
      'items', coalesce((
        select jsonb_agg(jsonb_build_object(
          'order_item_id', fdi.order_item_id, 'producto', fdi.product_name,
          'quantity', fdi.quantity, 'unit_price', fdi.unit_price, 'total', fdi.total
        ) order by fdi.id)
        from public.fiscal_document_items fdi where fdi.document_id = fd.id
      ), '[]'::jsonb)
    ) order by fd.issued_at, fd.id)
    from public.fiscal_documents fd where fd.business_id = p.business_id and fd.order_id = p.orden_id
  ), '[]'::jsonb) as comprobantes_fiscales,
  coalesce((
    select jsonb_agg(jsonb_build_object(
      'item_id', n.item_id, 'inventariable', ii.name, 'bodega', w.name,
      'consumo_venta_neto', n.consumo_venta_neto,
      'consumo_merma_neto', n.consumo_merma_neto,
      'consumo_total_neto', n.consumo_total_neto
    ) order by ii.name, n.item_id, n.warehouse_id)
    from netos n
    left join public.inventory_items ii on ii.id = n.item_id and ii.business_id = p.business_id
    left join public.warehouses w on w.id = n.warehouse_id and w.business_id = p.business_id
  ), '[]'::jsonb) as netos_por_insumo_y_bodega,
  coalesce((
    select jsonb_agg(jsonb_build_object(
      'fecha_rd', im.created_at at time zone 'America/Santo_Domingo', 'movimiento_id', im.id,
      'item_id', im.item_id, 'inventariable', ii.name, 'tipo', im.movement_type::text,
      'quantity', im.quantity, 'referencia_tipo', im.reference_type, 'notes', im.notes
    ) order by im.created_at, im.id)
    from movimientos im
    left join public.inventory_items ii on ii.id = im.item_id and ii.business_id = p.business_id
  ), '[]'::jsonb) as movimientos
from parametros p left join orden o on o.id = p.orden_id;

-- 5. Ejecutar SOLO si tiene_auditoria = true en el resultado del bloque 4.
-- Incluye acciones de usuario e internas. Draft y ciertas reducciones
-- internas pueden no estar auditados: ausencia de registros no los descarta.
select r.order_id as orden_id, r.item_id as renglon_id, r.product_id,
  r.removed_at at time zone 'America/Santo_Domingo' as eliminada_rd,
  r.product_name as producto, r.change_type, r.quantity, r.qty_before, r.qty_after,
  r.item_status, r.reason as motivo, r.is_user_action, r.request_path,
  to_jsonb(r)->>'reason_code' as reason_code,
  to_jsonb(r)->>'is_waste' as es_merma,
  to_jsonb(r)->>'waste_booked' as merma_contabilizada
from public.order_item_removals r
where r.business_id = '1eee0122-3181-496c-969e-0a0c06448932'::uuid
  and r.order_id = 'd26981a8-8db6-4ba8-854f-5ab48c22d5b7'::uuid
order by r.removed_at, r.id;
