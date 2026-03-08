-- 20260308_0016_inventory_mvp.sql
-- Scope:
-- 1) Keep inventory_stock synchronized from inventory_movements.
-- 2) Expose a secure RPC for manual inventory movements from the app.

begin;

create or replace function public.fn_sync_inventory_stock_on_movement()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  insert into public.inventory_stock (
    warehouse_id,
    item_id,
    quantity,
    last_updated
  )
  values (
    new.warehouse_id,
    new.item_id,
    new.quantity,
    now()
  )
  on conflict (warehouse_id, item_id)
  do update
     set quantity = public.inventory_stock.quantity + excluded.quantity,
         last_updated = now();

  return new;
end;
$$;

drop trigger if exists trg_inventory_stock_sync on public.inventory_movements;

create trigger trg_inventory_stock_sync
after insert on public.inventory_movements
for each row
execute function public.fn_sync_inventory_stock_on_movement();

create or replace function public.fn_inventory_record_movement(
  p_business_id uuid,
  p_warehouse_id uuid,
  p_item_id uuid,
  p_movement_type public.movement_type,
  p_quantity numeric,
  p_cost_per_unit numeric default null,
  p_reference_id uuid default null,
  p_reference_type text default null,
  p_notes text default null
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_user_id uuid := auth.uid();
  v_role text;
  v_signed_quantity numeric;
  v_movement public.inventory_movements;
begin
  if v_user_id is null then
    raise exception 'AUTH_REQUIRED';
  end if;

  select public.user_business_role(v_user_id, p_business_id)
    into v_role;

  if coalesce(v_role, '') not in ('owner', 'admin', 'manager') then
    raise exception 'INVENTORY_ACCESS_DENIED';
  end if;

  if p_quantity is null or p_quantity = 0 then
    raise exception 'INVALID_QUANTITY';
  end if;

  if not exists (
    select 1
    from public.inventory_items ii
    where ii.id = p_item_id
      and ii.business_id = p_business_id
  ) then
    raise exception 'ITEM_NOT_FOUND';
  end if;

  if not exists (
    select 1
    from public.warehouses w
    where w.id = p_warehouse_id
      and w.business_id = p_business_id
      and coalesce(w.is_active, true)
  ) then
    raise exception 'WAREHOUSE_NOT_FOUND';
  end if;

  v_signed_quantity :=
    case
      when p_movement_type in ('sale', 'transfer_out', 'waste')
        then -abs(p_quantity)
      when p_movement_type in ('purchase', 'transfer_in', 'return')
        then abs(p_quantity)
      else p_quantity
    end;

  insert into public.inventory_movements (
    business_id,
    warehouse_id,
    item_id,
    movement_type,
    quantity,
    cost_per_unit,
    reference_id,
    reference_type,
    notes,
    created_by
  )
  values (
    p_business_id,
    p_warehouse_id,
    p_item_id,
    p_movement_type,
    v_signed_quantity,
    p_cost_per_unit,
    p_reference_id,
    p_reference_type,
    p_notes,
    v_user_id
  )
  returning *
  into v_movement;

  return jsonb_build_object(
    'id', v_movement.id,
    'business_id', v_movement.business_id,
    'warehouse_id', v_movement.warehouse_id,
    'item_id', v_movement.item_id,
    'movement_type', v_movement.movement_type,
    'quantity', v_movement.quantity,
    'created_at', v_movement.created_at
  );
end;
$$;

grant execute on function public.fn_inventory_record_movement(
  uuid,
  uuid,
  uuid,
  public.movement_type,
  numeric,
  numeric,
  uuid,
  text,
  text
) to authenticated;

commit;
