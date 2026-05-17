-- =============================================================================
-- Inventario PRO: Sugerencias de reorden estilo Toast.
--
-- CONCEPTO:
--   Para cada insumo activo con `min_stock > 0`, si el stock actual (suma
--   sobre bodegas reales) es <= min_stock, sugerimos una compra. La
--   cantidad sugerida es:
--     - Si hay max_stock definido: max_stock - current_stock.
--     - Si no, una "reposición a 2× el mínimo": (min_stock * 2) - current_stock.
--   El proveedor sugerido es el de la última OC con ese insumo (heurística
--   simple — el admin puede cambiarlo al crear la OC).
--
-- ENTREGA:
--   - Vista `v_inventory_reorder_suggestions` con todo lo necesario para
--     la UI: item, stock, faltante, sugerido, último costo, proveedor
--     sugerido.
--
-- EXCLUYE:
--   - Bodegas con name = '__IN_TRANSIT__' (no es stock real disponible).
--   - Items inactivos.
--   - Items con min_stock <= 0 (no hay umbral configurado).
--
-- IDEMPOTENTE: CREATE OR REPLACE.
-- =============================================================================

begin;

create or replace view public.v_inventory_reorder_suggestions
with (security_invoker = on) as
with stock_per_item as (
  select
    ii.id           as inventory_item_id,
    ii.business_id,
    coalesce(sum(ist.quantity), 0) as current_stock
  from public.inventory_items ii
  left join public.inventory_stock ist on ist.item_id = ii.id
  left join public.warehouses w on w.id = ist.warehouse_id
  where coalesce(ii.is_active, true) = true
    and (w.name is null or w.name <> '__IN_TRANSIT__')
  group by ii.id, ii.business_id
),
last_purchase as (
  -- Última OC por insumo: proveedor + costo unitario.
  select distinct on (poi.inventory_item_id)
    poi.inventory_item_id,
    po.supplier_id,
    poi.unit_cost     as last_unit_cost,
    po.created_at     as last_purchase_at
  from public.purchase_order_items poi
  join public.purchase_orders po on po.id = poi.purchase_order_id
  where poi.inventory_item_id is not null
  order by poi.inventory_item_id, po.created_at desc
)
select
  ii.id                                as inventory_item_id,
  ii.business_id,
  ii.sku,
  ii.name,
  ii.unit,
  coalesce(ii.cost, 0)                 as cost,
  ii.min_stock,
  ii.max_stock,
  s.current_stock,
  greatest(coalesce(ii.min_stock, 0) - s.current_stock, 0) as deficit,
  greatest(
    coalesce(ii.max_stock, coalesce(ii.min_stock, 0) * 2) - s.current_stock,
    coalesce(ii.min_stock, 0) - s.current_stock,
    0
  )::numeric                            as suggested_qty,
  lp.supplier_id                       as suggested_supplier_id,
  sup.name                             as suggested_supplier_name,
  lp.last_unit_cost,
  lp.last_purchase_at
from public.inventory_items ii
join stock_per_item s on s.inventory_item_id = ii.id
left join last_purchase lp on lp.inventory_item_id = ii.id
left join public.suppliers sup on sup.id = lp.supplier_id
where coalesce(ii.is_active, true) = true
  and coalesce(ii.min_stock, 0) > 0
  and s.current_stock <= coalesce(ii.min_stock, 0);

grant select on public.v_inventory_reorder_suggestions to authenticated;

comment on view public.v_inventory_reorder_suggestions is
  'Sugerencias de reorden: insumos cuyo stock está en o bajo min_stock. '
  'Incluye proveedor sugerido (última OC), último costo y cantidad '
  'recomendada para reponer hasta max_stock (o 2× min_stock si max no '
  'está definido). Excluye bodega __IN_TRANSIT__.';

commit;
