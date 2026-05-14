-- =============================================================================
-- Sprint 5 Inventario (Fase A) — Valoración de existencias + ABC analysis.
--
-- ENTREGA:
--   - Vista `v_inventory_valuation` (detalle por item × bodega): cantidad,
--     costo unitario, valor total, datos descriptivos.
--   - Vista `v_inventory_valuation_summary` (agregada por item con
--     clasificación Pareto ABC):
--         * A: top 20% del valor total
--         * B: siguiente 30%
--         * C: 50% restante
--     El cálculo usa window function CUMULATIVE_SUM ordenado por valor desc.
--   - Excluye bodegas inactivas y `__IN_TRANSIT__` (no son stock real).
--
-- IDEMPOTENTE:
--   - DROP VIEW IF EXISTS + CREATE OR REPLACE.
--   - No modifica tablas existentes.
-- =============================================================================

begin;

-- ---------------------------------------------------------------------------
-- 1. Vista detalle: valor por (item, warehouse).
-- ---------------------------------------------------------------------------

drop view if exists public.v_inventory_valuation;

create or replace view public.v_inventory_valuation as
select
  ii.business_id,
  ii.id                                          as item_id,
  ii.sku                                         as item_sku,
  ii.name                                        as item_name,
  ii.unit                                        as item_unit,
  ii.cost                                        as unit_cost,
  ii.min_stock,
  ii.max_stock,
  coalesce(ii.tracks_lots, false)                as tracks_lots,
  w.id                                           as warehouse_id,
  w.name                                         as warehouse_name,
  coalesce(w.is_main, false)                     as warehouse_is_main,
  coalesce(s.quantity, 0)                        as quantity,
  (coalesce(s.quantity, 0) * coalesce(ii.cost, 0)) as value,
  s.last_updated                                 as last_movement_at
from public.inventory_items ii
join public.warehouses w
  on w.business_id = ii.business_id
 and coalesce(w.is_active, true)
 and w.name is distinct from '__IN_TRANSIT__'
left join public.inventory_stock s
  on s.item_id = ii.id
 and s.warehouse_id = w.id
where coalesce(ii.is_active, true);

comment on view public.v_inventory_valuation is
  'Valoración detallada de existencias por (item × bodega). Excluye bodegas '
  'inactivas y __IN_TRANSIT__. value = quantity * cost.';

-- ---------------------------------------------------------------------------
-- 2. Vista agregada con clasificación ABC.
--
--    El cálculo se hace por business:
--      1. Agregar quantity y value por item (suma de todas las bodegas).
--      2. Ordenar por value DESC.
--      3. Calcular CUMULATIVE_SUM y total_business_value.
--      4. cumulative_pct = cumsum / total.
--      5. Asignar clase ABC según el percentil acumulado:
--          ≤ 0.20 → A
--          ≤ 0.50 → B
--          resto  → C
--    Items sin valor (quantity = 0 OR cost = 0) se clasifican como 'no_data'.
-- ---------------------------------------------------------------------------

drop view if exists public.v_inventory_valuation_summary;

create or replace view public.v_inventory_valuation_summary as
with per_item as (
  select
    business_id,
    item_id,
    item_sku,
    item_name,
    item_unit,
    unit_cost,
    min_stock,
    max_stock,
    tracks_lots,
    sum(quantity)                                  as total_quantity,
    sum(value)                                     as total_value,
    count(*) filter (where quantity > 0)           as warehouses_with_stock,
    max(last_movement_at)                          as last_movement_at
  from public.v_inventory_valuation
  group by
    business_id, item_id, item_sku, item_name, item_unit,
    unit_cost, min_stock, max_stock, tracks_lots
),
ranked as (
  select
    *,
    sum(case when total_value > 0 then total_value else 0 end)
      over (partition by business_id)              as business_total_value,
    sum(case when total_value > 0 then total_value else 0 end)
      over (
        partition by business_id
        order by total_value desc, item_name asc
        rows between unbounded preceding and current row
      )                                            as cumulative_value
  from per_item
)
select
  business_id,
  item_id,
  item_sku,
  item_name,
  item_unit,
  unit_cost,
  min_stock,
  max_stock,
  tracks_lots,
  total_quantity,
  total_value,
  warehouses_with_stock,
  last_movement_at,
  business_total_value,
  case
    when coalesce(business_total_value, 0) <= 0 or total_value <= 0
      then null
    else cumulative_value / business_total_value
  end                                              as cumulative_pct,
  case
    when total_value <= 0 then 'no_data'
    when coalesce(business_total_value, 0) <= 0 then 'no_data'
    when (cumulative_value / business_total_value) <= 0.20 then 'A'
    when (cumulative_value / business_total_value) <= 0.50 then 'B'
    else 'C'
  end                                              as abc_class
from ranked;

comment on view public.v_inventory_valuation_summary is
  'Valoración agregada por insumo con clasificación ABC (Pareto): A=20% del '
  'valor, B=siguientes 30%, C=últimos 50%. Items sin valor → no_data.';

-- ---------------------------------------------------------------------------
-- 3. Índices de soporte: la valoración cruza inventory_items × warehouses ×
--    inventory_stock. Los índices existentes en (business_id) son suficientes.
--    No agregamos índices nuevos para no inflar el schema.
-- ---------------------------------------------------------------------------

commit;
