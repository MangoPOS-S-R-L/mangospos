-- =============================================================================
-- Inventario PRD: costo promedio ponderado.
--
-- CONCEPTO:
--   Al recibir mercancía (movement_type='purchase' o 'transfer_in'), el
--   costo del item debe recalcularse como promedio ponderado:
--
--     new_cost = (old_stock * old_cost + received_qty * received_cost)
--                / (old_stock + received_qty)
--
--   Esto estabiliza el costo histórico cuando un mismo item se compra a
--   diferentes precios a lo largo del tiempo, lo que da reportes de
--   valorización y margen consistentes.
--
-- ENTREGA:
--   1. Función `fn_recompute_item_cost_weighted_avg(p_item_id, p_received_qty,
--      p_received_cost)` que actualiza `inventory_items.cost` aplicando la
--      fórmula de promedio ponderado.
--   2. Trigger AFTER INSERT en `inventory_movements` que llama a la función
--      cuando type='purchase' o 'transfer_in' y `cost_per_unit > 0`.
--
-- GATE:
--   Solo se aplica si el business está en `inventory_mode = 'advanced'`. En
--   `basic` el costo se mantiene como estaba (manual). Negocios en `none`
--   ni siquiera tienen movimientos de inventario.
--
-- IMPACTO EN PRODUCCIÓN:
--   ⚠️ Negocios en modo `advanced` van a empezar a recibir actualizaciones
--   automáticas del costo. El admin debe estar consciente que el cost
--   ahora se mueve con las compras (antes lo editaba manual). Es lo
--   esperado en flujo profesional.
--
--   ⚠️ El cost_per_unit que viene en `inventory_movements` debe ser >0
--   para que el trigger lo considere. Movimientos sin cost (purchase
--   gratuita o transferencia interna sin recosteo) NO recalculan.
--
-- IDEMPOTENTE: CREATE OR REPLACE / DROP TRIGGER + CREATE.
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

  -- Stock total ACTUAL del item across todas las bodegas, ANTES de aplicar
  -- el movimiento que disparó el trigger. inventory_stock ya fue actualizado
  -- por el trigger de stock (orden de triggers), así que restamos el
  -- received para "deshacer" el efecto en el cálculo.
  select coalesce(sum(quantity), 0)
    into v_current_stock
  from public.inventory_stock
  where item_id = p_item_id;

  v_current_stock := greatest(v_current_stock - p_received_qty, 0);

  select coalesce(cost, 0)
    into v_current_cost
  from public.inventory_items
  where id = p_item_id;

  -- Fórmula de promedio ponderado.
  if v_current_stock + p_received_qty > 0 then
    v_new_cost := (
      (v_current_stock * v_current_cost) +
      (p_received_qty * p_received_cost)
    ) / (v_current_stock + p_received_qty);
  else
    -- Borde: no había stock previo. El nuevo costo = costo recibido.
    v_new_cost := p_received_cost;
  end if;

  -- Truncar a 4 decimales para evitar arrastre de float.
  update public.inventory_items
     set cost = round(v_new_cost::numeric, 4)
   where id = p_item_id;
end;
$$;

comment on function public.fn_recompute_item_cost_weighted_avg(uuid, numeric, numeric) is
  'Recalcula inventory_items.cost como promedio ponderado: '
  '(stock_actual * cost_actual + qty_recibida * cost_recibido) / total. '
  'Llamado por trigger en inventory_movements al recibir purchase/transfer_in.';

-- ---------------------------------------------------------------------------
-- Trigger: AFTER INSERT en inventory_movements
-- ---------------------------------------------------------------------------

create or replace function public.fn_inventory_movement_recost()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  v_mode text;
begin
  -- Solo aplica a entradas de mercancía con costo conocido.
  if new.movement_type not in ('purchase', 'transfer_in') then
    return new;
  end if;
  if new.cost_per_unit is null or new.cost_per_unit <= 0 then
    return new;
  end if;
  if new.quantity is null or new.quantity <= 0 then
    return new;
  end if;

  -- Gate por inventory_mode. Solo recalcula en modo avanzado.
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
