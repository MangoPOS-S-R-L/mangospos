-- =============================================================================
-- Exponer las capas de costo al esquema `analytics` (API de lectura del cliente).
--
-- POR QUÉ ESTA MIGRACIÓN EXISTE:
--   DH Delgado Hernández no consulta la app: consulta el esquema `analytics`
--   (así levantaron el informe del 02-09-2026). Sin esto, las capas de costo,
--   el costo de venta y el reporte de faltantes existen pero son invisibles
--   para el auditor, y los entregables 1, 2 y 5 quedan sin comprobar.
--
-- POR QUÉ NO SE REUSAN LAS VISTAS DE `public`:
--   Las vistas v_inventory_* de la 20260902_0013 son `security_invoker = on`
--   para que la RLS aplique al usuario de la app. La API de lectura funciona
--   al revés: vistas SIN security_invoker, cuyo owner (mango_analytics_view_owner)
--   sí es miembro de authenticated, mientras `analytics_ro` no tiene ningún
--   grant sobre public. Encadenar una invoker dentro de una definer rompe ese
--   diseño. Por eso acá se construye directo sobre las tablas base.
--
-- OJO CON LA ZONA HORARIA:
--   PostgREST corre en UTC. Un `created_at::date` pelado manda toda venta
--   después de las 8 PM al día siguiente. Todas las fechas de este archivo van
--   casteadas con `at time zone 'America/Santo_Domingo'`.
--
-- REQUIERE: 20260829_0002 (API de lectura) y 20260902_0012/0013 (capas).
-- IDEMPOTENTE: sí. REVERSIBLE: sí (ver _ROLLBACK).
-- =============================================================================

begin;

-- ---------------------------------------------------------------------------
-- 0. Guardas: sin la API de lectura ni las capas, esto no tiene sentido.
-- ---------------------------------------------------------------------------

do $$
begin
  if to_regnamespace('analytics') is null then
    raise exception 'ANALYTICS_API_NOT_INSTALLED: aplicar 20260829_0002 primero';
  end if;
  if to_regclass('public.inventory_cost_layers') is null then
    raise exception 'COST_LAYERS_NOT_INSTALLED: aplicar 20260902_0012 primero';
  end if;
  if not exists (select 1 from pg_roles where rolname = 'analytics_ro') then
    raise exception 'ANALYTICS_RO_MISSING: aplicar 20260829_0002 primero';
  end if;
end $$;

-- ---------------------------------------------------------------------------
-- 1. Las dos tablas nuevas, con el mismo patrón del generador de 0829_0002:
--    vista definer sobre public, filtrada por allowed_business_ids().
-- ---------------------------------------------------------------------------

do $$
declare
  v_rel text;
begin
  foreach v_rel in array array['inventory_cost_layers', 'inventory_cost_consumptions']
  loop
    execute format('drop view if exists analytics.%I cascade', v_rel);
    execute format(
      'create view analytics.%I as select src.* from public.%I src '
      'where src.business_id in (select analytics.allowed_business_ids())',
      v_rel, v_rel);
    execute format(
      'alter view analytics.%I owner to mango_analytics_view_owner', v_rel);
    execute format('grant select on analytics.%I to analytics_ro', v_rel);
  end loop;
end $$;

-- ---------------------------------------------------------------------------
-- 2. Capas de costo con su documento — la evidencia del entregable 1.
--    Una fila por capa: qué entró, cuándo, con qué NCF y de qué proveedor.
-- ---------------------------------------------------------------------------

create or replace view analytics.capas_de_costo as
select
  l.business_id,
  ii.sku                                          as codigo,
  ii.name                                         as articulo,
  ii.unit                                         as unidad,
  w.name                                          as bodega,
  case l.source_type
    when 'opening'       then 'Inventario inicial'
    when 'purchase'      then 'Compra'
    when 'transfer_in'   then 'Transferencia recibida'
    when 'return'        then 'Devolución'
    when 'production_in' then 'Producción'
    else 'Ajuste'
  end                                             as origen,
  l.document_number                               as ncf_o_factura,
  l.document_date                                 as fecha_documento,
  s.name                                          as proveedor,
  (l.received_at at time zone 'America/Santo_Domingo')::date as fecha_entrada,
  l.quantity_in                                   as cantidad_entrada,
  l.quantity_remaining                            as cantidad_disponible,
  l.unit_cost                                     as costo_unitario,
  round(l.quantity_remaining * l.unit_cost, 2)    as valor_disponible,
  l.is_estimated                                  as sin_respaldo_documental,
  l.id                                            as capa_id,
  l.item_id,
  l.warehouse_id
from public.inventory_cost_layers l
join public.inventory_items ii on ii.id = l.item_id
join public.warehouses w on w.id = l.warehouse_id
left join public.suppliers s on s.id = l.supplier_id
where l.business_id in (select analytics.allowed_business_ids());

alter view analytics.capas_de_costo owner to mango_analytics_view_owner;
grant select on analytics.capas_de_costo to analytics_ro;

comment on view analytics.capas_de_costo is
  'Una fila por capa de costo, con su documento (NCF o factura), fecha y '
  'proveedor. sin_respaldo_documental = true marca la entrada que no tiene '
  'comprobante que sustente su costo (Art. 57 Regl. 139-98).';

-- ---------------------------------------------------------------------------
-- 3. Inventario valorado por capas, contra la valuación a último precio.
--    La diferencia es la partida de conciliación del informe.
-- ---------------------------------------------------------------------------

create or replace view analytics.inventario_valorado_capas as
select
  l.business_id,
  ii.sku                                          as codigo,
  ii.name                                         as articulo,
  ii.unit                                         as unidad,
  w.name                                          as bodega,
  sum(l.quantity_remaining)                       as existencia,
  round(sum(l.quantity_remaining * l.unit_cost), 2)
                                                  as valor_por_capas,
  case when sum(l.quantity_remaining) > 0
    then round(sum(l.quantity_remaining * l.unit_cost)
               / sum(l.quantity_remaining), 4)
    else 0 end                                    as costo_unitario_efectivo,
  ii.cost                                         as costo_ultimo_precio,
  round(sum(l.quantity_remaining) * coalesce(ii.cost, 0), 2)
                                                  as valor_ultimo_precio,
  round(sum(l.quantity_remaining) * coalesce(ii.cost, 0)
        - sum(l.quantity_remaining * l.unit_cost), 2)
                                                  as diferencia,
  count(*)                                        as capas_abiertas,
  count(*) filter (where l.is_estimated)          as capas_sin_respaldo,
  round(coalesce(sum(l.quantity_remaining * l.unit_cost)
        filter (where l.is_estimated), 0), 2)     as valor_sin_respaldo,
  l.item_id,
  l.warehouse_id
from public.inventory_cost_layers l
join public.inventory_items ii on ii.id = l.item_id
join public.warehouses w on w.id = l.warehouse_id
where l.quantity_remaining > 0
  and l.business_id in (select analytics.allowed_business_ids())
group by l.business_id, l.item_id, ii.sku, ii.name, ii.unit, ii.cost,
         l.warehouse_id, w.name;

alter view analytics.inventario_valorado_capas owner to mango_analytics_view_owner;
grant select on analytics.inventario_valorado_capas to analytics_ro;

comment on view analytics.inventario_valorado_capas is
  'Inventario valorado por capas de costo, con la valuación a último precio al '
  'lado y la diferencia explícita. valor_sin_respaldo = la porción que no tiene '
  'comprobante fiscal que la sustente.';

-- ---------------------------------------------------------------------------
-- 4. Costo de venta, neto de devoluciones por edición o cancelación de orden.
-- ---------------------------------------------------------------------------

create or replace view analytics.costo_de_ventas as
select
  c.business_id,
  (m.created_at at time zone 'America/Santo_Domingo')::date as fecha,
  ii.sku                                          as codigo,
  ii.name                                         as articulo,
  ii.unit                                         as unidad,
  w.name                                          as bodega,
  m.movement_type::text                           as tipo_salida,
  sum(c.quantity - c.quantity_returned)           as cantidad,
  round(sum((c.quantity - c.quantity_returned) * c.unit_cost), 2)
                                                  as costo,
  bool_or(c.is_shortfall)                         as incluye_faltante,
  c.item_id,
  c.warehouse_id
from public.inventory_cost_consumptions c
join public.inventory_movements m on m.id = c.movement_id
join public.inventory_items ii on ii.id = c.item_id
join public.warehouses w on w.id = c.warehouse_id
where c.quantity > c.quantity_returned
  and c.business_id in (select analytics.allowed_business_ids())
group by c.business_id,
         (m.created_at at time zone 'America/Santo_Domingo')::date,
         ii.sku, ii.name, ii.unit, w.name, m.movement_type,
         c.item_id, c.warehouse_id;

alter view analytics.costo_de_ventas owner to mango_analytics_view_owner;
grant select on analytics.costo_de_ventas to analytics_ro;

comment on view analytics.costo_de_ventas is
  'Costo de venta por día y artículo, neto de las devoluciones que genera la '
  'edición o cancelación de órdenes. Filtrar tipo_salida = sale para el costo '
  'de venta del período; waste y transfer_out son otras salidas.';

-- ---------------------------------------------------------------------------
-- 5. Faltantes: salidas sin capa que las respalde (las existencias negativas).
-- ---------------------------------------------------------------------------

create or replace view analytics.inventario_faltantes as
select
  c.business_id,
  ii.sku                                          as codigo,
  ii.name                                         as articulo,
  ii.unit                                         as unidad,
  w.name                                          as bodega,
  count(*)                                        as movimientos,
  sum(c.quantity - c.quantity_returned)           as cantidad_sin_respaldo,
  round(sum((c.quantity - c.quantity_returned) * c.unit_cost), 2)
                                                  as valor_estimado,
  (min(c.created_at) at time zone 'America/Santo_Domingo')::date as desde,
  (max(c.created_at) at time zone 'America/Santo_Domingo')::date as hasta,
  c.item_id,
  c.warehouse_id
from public.inventory_cost_consumptions c
join public.inventory_items ii on ii.id = c.item_id
join public.warehouses w on w.id = c.warehouse_id
where c.is_shortfall
  and c.quantity > c.quantity_returned
  and c.business_id in (select analytics.allowed_business_ids())
group by c.business_id, ii.sku, ii.name, ii.unit, w.name,
         c.item_id, c.warehouse_id;

alter view analytics.inventario_faltantes owner to mango_analytics_view_owner;
grant select on analytics.inventario_faltantes to analytics_ro;

comment on view analytics.inventario_faltantes is
  'Salidas que no encontraron capa disponible: se costearon al último costo '
  'conocido. Es la cara contable de las existencias negativas del hallazgo 5 '
  'del informe DH. Se reconcilia contra el conteo físico.';

commit;
