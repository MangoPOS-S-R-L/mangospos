-- =============================================================================
-- Sprint 4 (parcial) Inventario — Alertas de stock bajo.
--
-- ENTREGA:
--   Una vista `v_inventory_low_stock` que lista TODOS los insumos activos
--   con `min_stock > 0` cuyo stock total (sumando todas las bodegas activas,
--   excluyendo __IN_TRANSIT__) está en o por debajo del mínimo configurado.
--
--   Cada fila trae:
--     - Datos del insumo (id, sku, nombre, unidad, costo).
--     - `total_stock`: saldo total del insumo en el negocio.
--     - `warehouses_with_stock`: cuántas bodegas tienen al menos algo.
--     - `alert_level`: 'out_of_stock' | 'critical' | 'low'.
--         · out_of_stock → total_stock <= 0
--         · critical     → total_stock <= min_stock * 0.5
--         · low          → resto (entre 50% y 100% del mínimo)
--     - `shortfall`: cuánto falta para alcanzar el mínimo.
--
-- IDEMPOTENTE:
--   - Usa CREATE OR REPLACE VIEW + DROP VIEW IF EXISTS para el caso de
--     que el catalogo de columnas cambie en futuras migraciones.
--   - No modifica tablas existentes.
-- =============================================================================

begin;

-- ---------------------------------------------------------------------------
-- Vista: v_inventory_low_stock
-- ---------------------------------------------------------------------------

drop view if exists public.v_inventory_low_stock;

create or replace view public.v_inventory_low_stock as
with stock_per_item as (
  select
    s.item_id,
    w.business_id,
    sum(s.quantity)                              as total_stock,
    count(*) filter (where s.quantity > 0)       as warehouses_with_stock,
    max(s.last_updated)                          as last_movement_at
  from public.inventory_stock s
  join public.warehouses w on w.id = s.warehouse_id
  where coalesce(w.is_active, true)
    and w.name is distinct from '__IN_TRANSIT__'
  group by s.item_id, w.business_id
)
select
  ii.id                                          as item_id,
  ii.business_id,
  ii.sku,
  ii.name,
  ii.unit,
  ii.cost,
  ii.min_stock,
  ii.max_stock,
  coalesce(s.total_stock, 0)                     as total_stock,
  coalesce(s.warehouses_with_stock, 0)           as warehouses_with_stock,
  s.last_movement_at,
  case
    when coalesce(s.total_stock, 0) <= 0
      then 'out_of_stock'
    when coalesce(s.total_stock, 0) <= ii.min_stock * 0.5
      then 'critical'
    else 'low'
  end                                            as alert_level,
  greatest(ii.min_stock - coalesce(s.total_stock, 0), 0) as shortfall,
  (greatest(ii.min_stock - coalesce(s.total_stock, 0), 0) * coalesce(ii.cost, 0))
                                                 as shortfall_value
from public.inventory_items ii
left join stock_per_item s
       on s.item_id = ii.id
      and s.business_id = ii.business_id
where coalesce(ii.is_active, true)
  and coalesce(ii.min_stock, 0) > 0
  and coalesce(s.total_stock, 0) <= ii.min_stock;

comment on view public.v_inventory_low_stock is
  'Lista insumos activos con stock total (excluyendo __IN_TRANSIT__) menor o '
  'igual al min_stock configurado. Sprint 4 Inventario — alertas de reposición.';

-- ---------------------------------------------------------------------------
-- Vista: v_inventory_stock_by_warehouse (desglose por bodega)
--
--   Útil para ver, junto a una alerta, en qué bodegas hace falta el insumo.
--   También sirve como vista general de inventory_stock con nombres legibles.
-- ---------------------------------------------------------------------------

drop view if exists public.v_inventory_stock_by_warehouse;

create or replace view public.v_inventory_stock_by_warehouse as
select
  s.item_id,
  ii.name                  as item_name,
  ii.sku                   as item_sku,
  ii.unit                  as item_unit,
  ii.min_stock,
  ii.max_stock,
  s.warehouse_id,
  w.name                   as warehouse_name,
  coalesce(w.is_main, false) as warehouse_is_main,
  ii.business_id,
  s.quantity,
  s.last_updated
from public.inventory_stock s
join public.warehouses w        on w.id  = s.warehouse_id
join public.inventory_items ii  on ii.id = s.item_id
where coalesce(w.is_active, true)
  and w.name is distinct from '__IN_TRANSIT__'
  and coalesce(ii.is_active, true);

comment on view public.v_inventory_stock_by_warehouse is
  'Stock por (item, bodega) con nombres legibles. Excluye bodegas inactivas '
  'y __IN_TRANSIT__. Consumida por el desglose del alert detail.';

-- ---------------------------------------------------------------------------
-- Índice de soporte para la query de alertas: filtros por business_id + flags.
-- ---------------------------------------------------------------------------

create index if not exists idx_inventory_items_active_min_stock
  on public.inventory_items (business_id, is_active, min_stock)
  where coalesce(is_active, true) = true and coalesce(min_stock, 0) > 0;

commit;
