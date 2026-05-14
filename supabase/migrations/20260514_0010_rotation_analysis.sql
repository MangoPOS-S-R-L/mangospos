-- =============================================================================
-- Sprint 5 Inventario (Fase B) — Análisis de rotación.
--
-- ENTREGA:
--   - RPC `fn_inventory_rotation_analysis(business_id, days_back)` que
--     devuelve por insumo:
--         * Stock actual (suma de bodegas activas, sin __IN_TRANSIT__).
--         * outflow_qty: total consumido en el período (sale +
--           transfer_out + waste + ajustes negativos).
--         * inflow_qty: total recibido en el período.
--         * outflow_per_day: velocidad de consumo.
--         * days_of_supply: cuántos días dura el stock actual a la
--           velocidad reciente (NULL si outflow = 0).
--         * rotation_class:
--             - 'dormant'  → sin outflow en el período (stock estancado).
--             - 'star'     → top 20% por outflow_qty (más vendido).
--             - 'active'   → percentiles 20-50.
--             - 'slow'     → resto (movimiento bajo pero existente).
--
-- IMPORTANTE:
--   - SECURITY DEFINER + check de acceso al business (consistent con el
--     resto del módulo).
--   - Solo LEE datos. No modifica nada.
-- =============================================================================

begin;

create or replace function public.fn_inventory_rotation_analysis(
  p_business_id uuid,
  p_days_back int default 30
) returns table (
  item_id uuid,
  item_sku text,
  item_name text,
  item_unit text,
  unit_cost numeric,
  min_stock numeric,
  tracks_lots boolean,
  current_stock numeric,
  outflow_qty numeric,
  inflow_qty numeric,
  outflow_value numeric,
  movement_count int,
  outflow_per_day numeric,
  days_of_supply numeric,
  rotation_class text
)
language plpgsql
security definer
set search_path = public
as $$
declare
  v_days int;
begin
  if p_business_id is null then
    raise exception 'MISSING_REQUIRED_PARAMS';
  end if;

  if not public.user_has_business_access(auth.uid(), p_business_id) then
    raise exception 'NOT_AUTHORIZED';
  end if;

  -- Defensivo: si days_back viene null o <=0, usar 30.
  v_days := coalesce(nullif(p_days_back, 0), 30);
  if v_days < 0 then
    v_days := abs(v_days);
  end if;

  return query
  with movements_in_period as (
    select
      im.item_id,
      sum(case when im.quantity > 0 then im.quantity else 0 end)
        as inflow,
      sum(case when im.quantity < 0 then -im.quantity else 0 end)
        as outflow,
      sum(case
        when im.quantity < 0
          then -im.quantity * coalesce(im.cost_per_unit, 0)
        else 0
      end)                                                  as outflow_value_sum,
      count(*)                                              as movement_count
    from public.inventory_movements im
    where im.business_id = p_business_id
      and im.created_at >= (now() - (v_days || ' days')::interval)
    group by im.item_id
  ),
  stock_per_item as (
    select
      s.item_id,
      sum(s.quantity) as current_stock
    from public.inventory_stock s
    join public.warehouses w
      on w.id = s.warehouse_id
     and coalesce(w.is_active, true)
     and w.name is distinct from '__IN_TRANSIT__'
    where w.business_id = p_business_id
    group by s.item_id
  ),
  combined as (
    select
      ii.id                                                 as item_id,
      ii.sku                                                as item_sku,
      ii.name                                               as item_name,
      ii.unit                                               as item_unit,
      ii.cost                                               as unit_cost,
      coalesce(ii.min_stock, 0)                             as min_stock,
      coalesce(ii.tracks_lots, false)                       as tracks_lots,
      coalesce(sp.current_stock, 0)                         as current_stock,
      coalesce(mp.outflow, 0)                               as outflow_qty,
      coalesce(mp.inflow, 0)                                as inflow_qty,
      coalesce(mp.outflow_value_sum, 0)                     as outflow_value,
      coalesce(mp.movement_count, 0)::int                   as movement_count,
      coalesce(mp.outflow, 0) / v_days::numeric             as outflow_per_day,
      case
        when coalesce(mp.outflow, 0) <= 0 then null::numeric
        else coalesce(sp.current_stock, 0) /
             (mp.outflow / v_days::numeric)
      end                                                   as days_of_supply,
      -- NTILE solo sobre items CON outflow > 0. Los demás caen en 'dormant'.
      case
        when coalesce(mp.outflow, 0) > 0 then
          ntile(10) over (
            partition by (mp.outflow is null or mp.outflow <= 0)
            order by mp.outflow desc nulls last
          )
        else null
      end                                                   as decile
    from public.inventory_items ii
    left join movements_in_period mp on mp.item_id = ii.id
    left join stock_per_item     sp on sp.item_id = ii.id
    where ii.business_id = p_business_id
      and coalesce(ii.is_active, true)
  )
  select
    c.item_id,
    c.item_sku,
    c.item_name,
    c.item_unit,
    c.unit_cost,
    c.min_stock,
    c.tracks_lots,
    c.current_stock,
    c.outflow_qty,
    c.inflow_qty,
    c.outflow_value,
    c.movement_count,
    c.outflow_per_day,
    c.days_of_supply,
    case
      when c.outflow_qty <= 0 then 'dormant'
      when c.decile <= 2 then 'star'
      when c.decile <= 5 then 'active'
      else 'slow'
    end as rotation_class
  from combined c
  order by c.outflow_qty desc nulls last, c.item_name asc;
end;
$$;

grant execute on function public.fn_inventory_rotation_analysis(uuid, int)
  to authenticated;

comment on function public.fn_inventory_rotation_analysis(uuid, int) is
  'Análisis de rotación de inventario en una ventana de p_days_back días '
  '(default 30). Devuelve outflow, velocidad, días de supply y clase '
  'star/active/slow/dormant por insumo activo. SECURITY DEFINER con check '
  'de acceso al business.';

commit;
