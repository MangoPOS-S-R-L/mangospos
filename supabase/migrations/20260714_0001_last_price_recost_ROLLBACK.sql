-- =============================================================================
-- ROLLBACK de 20260714_0001_last_price_recost.
-- Restaura el costeo promedio ponderado de la mig 20260516_0004 tal cual
-- (función + trigger con gate inventory_mode='advanced' y transfer_in).
-- OJO: mientras la app siga mandando updateItemCost=true al registrar
-- compras, el promedio queda pisado igual (el bug de convivencia original).
-- =============================================================================

begin;

create or replace function public.fn_recompute_item_cost_weighted_avg(
  p_item_id uuid,
  p_received_qty numeric,
  p_received_cost numeric
) returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_current_stock numeric;
  v_current_cost numeric;
  v_new_cost numeric;
begin
  if p_item_id is null then return; end if;
  if p_received_qty is null or p_received_qty <= 0 then return; end if;
  if p_received_cost is null or p_received_cost <= 0 then return; end if;

  select coalesce(sum(quantity), 0)
    into v_current_stock
  from public.inventory_stock
  where item_id = p_item_id;

  v_current_stock := greatest(v_current_stock - p_received_qty, 0);

  select coalesce(cost, 0)
    into v_current_cost
  from public.inventory_items
  where id = p_item_id;

  if v_current_stock + p_received_qty > 0 then
    v_new_cost := (
      (v_current_stock * v_current_cost) +
      (p_received_qty * p_received_cost)
    ) / (v_current_stock + p_received_qty);
  else
    v_new_cost := p_received_cost;
  end if;

  update public.inventory_items
     set cost = round(v_new_cost::numeric, 4)
   where id = p_item_id;
end;
$$;

comment on function public.fn_recompute_item_cost_weighted_avg(uuid, numeric, numeric) is
  'Recalcula inventory_items.cost como promedio ponderado: '
  '(stock_actual * cost_actual + qty_recibida * cost_recibido) / total. '
  'Llamado por trigger en inventory_movements al recibir purchase/transfer_in.';

create or replace function public.fn_inventory_movement_recost()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  v_mode text;
begin
  if new.movement_type not in ('purchase', 'transfer_in') then
    return new;
  end if;
  if new.cost_per_unit is null or new.cost_per_unit <= 0 then
    return new;
  end if;
  if new.quantity is null or new.quantity <= 0 then
    return new;
  end if;

  select coalesce(inventory_mode, 'none')
    into v_mode
  from public.business_settings
  where business_id = new.business_id;

  if coalesce(v_mode, 'none') <> 'advanced' then
    return new;
  end if;

  perform public.fn_recompute_item_cost_weighted_avg(
    new.item_id,
    new.quantity,
    new.cost_per_unit
  );

  return new;
end;
$$;

drop trigger if exists trg_inventory_movement_recost on public.inventory_movements;
create trigger trg_inventory_movement_recost
  after insert on public.inventory_movements
  for each row
  execute function public.fn_inventory_movement_recost();

comment on trigger trg_inventory_movement_recost on public.inventory_movements is
  'Recalcula el costo promedio ponderado del item al recibir compras o '
  'transferencias entrantes. Solo activo en negocios con inventory_mode=advanced.';

commit;
