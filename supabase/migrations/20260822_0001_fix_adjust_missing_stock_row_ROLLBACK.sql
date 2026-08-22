-- ROLLBACK de 20260822_0001_fix_adjust_missing_stock_row.sql
--
-- Restaura `fn_inventory_adjust` tal cual la dejó 20260513_0017, es decir CON
-- el bug: ajustar un insumo que no tiene fila en `inventory_stock` vuelve a
-- fallar con INVALID_QUANTITY. Sólo tiene sentido correrlo si el fix rompió
-- algo inesperado. No hay datos que deshacer: los ajustes ya aplicados son
-- movimientos normales de `inventory_movements`.

begin;

create or replace function public.fn_inventory_adjust(
  p_business_id uuid,
  p_warehouse_id uuid,
  p_item_id uuid,
  p_counted_quantity numeric,
  p_reason_code text,
  p_notes text default null,
  p_cost_per_unit numeric default null
)
returns public.inventory_movements
language plpgsql
security definer
set search_path = public
as $$
declare
  v_current_stock numeric := 0;
  v_delta numeric;
  v_role text;
  v_movement public.inventory_movements;
  v_ref_uuid uuid;
begin
  if p_business_id is null or p_warehouse_id is null or p_item_id is null then
    raise exception 'MISSING_REQUIRED_PARAMS';
  end if;
  if p_counted_quantity is null or p_counted_quantity < 0 then
    raise exception 'INVALID_COUNTED_QUANTITY';
  end if;
  if p_reason_code is null or btrim(p_reason_code) = '' then
    raise exception 'REASON_REQUIRED';
  end if;
  if p_reason_code = 'other' and (p_notes is null or btrim(p_notes) = '') then
    raise exception 'NOTES_REQUIRED_FOR_OTHER';
  end if;

  v_role := public.user_business_role(auth.uid(), p_business_id);
  if v_role not in ('owner', 'admin', 'manager') then
    raise exception 'INSUFFICIENT_ROLE: % no puede ajustar inventario', v_role;
  end if;

  select coalesce(quantity, 0) into v_current_stock
  from public.inventory_stock
  where warehouse_id = p_warehouse_id
    and item_id = p_item_id
  for update;

  v_delta := p_counted_quantity - v_current_stock;
  if v_delta = 0 then
    raise exception 'NO_CHANGE: stock contado igual al actual (%)', v_current_stock;
  end if;

  v_ref_uuid := gen_random_uuid();

  perform public.fn_inventory_record_movement(
    p_business_id    => p_business_id,
    p_warehouse_id   => p_warehouse_id,
    p_item_id        => p_item_id,
    p_movement_type  => 'adjustment'::public.movement_type,
    p_quantity       => v_delta,
    p_cost_per_unit  => p_cost_per_unit,
    p_reference_id   => v_ref_uuid,
    p_reference_type => 'stock_adjustment',
    p_notes          => p_notes
  );

  select * into v_movement
  from public.inventory_movements
  where reference_id = v_ref_uuid
  order by created_at desc
  limit 1;

  update public.inventory_movements
  set reason_code = p_reason_code
  where id = v_movement.id
  returning * into v_movement;

  return v_movement;
end;
$$;

grant execute on function public.fn_inventory_adjust(uuid, uuid, uuid, numeric, text, text, numeric)
  to authenticated;

commit;
