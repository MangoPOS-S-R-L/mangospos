-- 20260308_0018_purchase_receiving_inventory.sql
-- Scope:
-- 1) Allow authenticated admins/owners to write purchase_order_items under RLS.
-- 2) Expose a secure RPC to receive purchase orders and post stock into inventory.

begin;

drop policy if exists "poi_write" on public.purchase_order_items;

create policy "poi_write"
on public.purchase_order_items
to authenticated
using (
  exists (
    select 1
    from public.purchase_orders po
    where po.id = purchase_order_items.purchase_order_id
      and public.user_business_role(auth.uid(), po.business_id) = any (
        array['owner'::text, 'admin'::text]
      )
  )
)
with check (
  exists (
    select 1
    from public.purchase_orders po
    where po.id = purchase_order_items.purchase_order_id
      and public.user_business_role(auth.uid(), po.business_id) = any (
        array['owner'::text, 'admin'::text]
      )
  )
  and (
    purchase_order_items.inventory_item_id is null
    or exists (
      select 1
      from public.inventory_items ii
      join public.purchase_orders po
        on po.id = purchase_order_items.purchase_order_id
      where ii.id = purchase_order_items.inventory_item_id
        and ii.business_id = po.business_id
    )
  )
);

create or replace function public.fn_receive_purchase_order(
  p_order_id uuid,
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
  v_order public.purchase_orders;
  v_outstanding_lines integer := 0;
  v_posted_lines integer := 0;
  v_pending_qty numeric;
  v_line record;
begin
  if v_user_id is null then
    raise exception 'AUTH_REQUIRED';
  end if;

  select *
    into v_order
  from public.purchase_orders
  where id = p_order_id;

  if not found then
    raise exception 'PURCHASE_ORDER_NOT_FOUND';
  end if;

  select public.user_business_role(v_user_id, v_order.business_id)
    into v_role;

  if coalesce(v_role, '') not in ('owner', 'admin', 'manager') then
    raise exception 'PURCHASE_RECEIVE_ACCESS_DENIED';
  end if;

  if v_order.status = 'cancelled' then
    raise exception 'PURCHASE_ORDER_CANCELLED';
  end if;

  if v_order.warehouse_id is null then
    raise exception 'PURCHASE_ORDER_WAREHOUSE_REQUIRED';
  end if;

  select count(*)
    into v_outstanding_lines
  from public.purchase_order_items poi
  where poi.purchase_order_id = p_order_id
    and coalesce(poi.quantity_ordered, 0) > coalesce(poi.quantity_received, 0);

  if coalesce(v_outstanding_lines, 0) = 0 then
    update public.purchase_orders
       set status = 'received',
           received_date = coalesce(received_date, current_date)
     where id = p_order_id
       and status <> 'received';

    return jsonb_build_object(
      'order_id', p_order_id,
      'status', 'received',
      'movements_created', 0,
      'already_received', true
    );
  end if;

  for v_line in
    select
      poi.id,
      poi.inventory_item_id,
      poi.unit_cost,
      poi.description,
      greatest(
        coalesce(poi.quantity_ordered, 0) - coalesce(poi.quantity_received, 0),
        0
      ) as pending_quantity
    from public.purchase_order_items poi
    where poi.purchase_order_id = p_order_id
      and coalesce(poi.quantity_ordered, 0) > coalesce(poi.quantity_received, 0)
  loop
    v_pending_qty := coalesce(v_line.pending_quantity, 0);
    if v_pending_qty <= 0 then
      continue;
    end if;

    if v_line.inventory_item_id is not null then
      if not exists (
        select 1
        from public.inventory_items ii
        where ii.id = v_line.inventory_item_id
          and ii.business_id = v_order.business_id
      ) then
        raise exception 'PURCHASE_ORDER_ITEM_INVALID';
      end if;

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
        v_order.business_id,
        v_order.warehouse_id,
        v_line.inventory_item_id,
        'purchase',
        v_pending_qty,
        v_line.unit_cost,
        p_order_id,
        'purchase_order',
        coalesce(
          nullif(trim(p_notes), ''),
          concat('Recepcion de compra ', v_order.order_number)
        ),
        v_user_id
      );

      v_posted_lines := v_posted_lines + 1;
    end if;
  end loop;

  update public.purchase_order_items
     set quantity_received = quantity_ordered
   where purchase_order_id = p_order_id
     and coalesce(quantity_ordered, 0) > coalesce(quantity_received, 0);

  update public.purchase_orders
     set status = 'received',
         received_date = current_date
   where id = p_order_id;

  return jsonb_build_object(
    'order_id', p_order_id,
    'status', 'received',
    'movements_created', v_posted_lines,
    'already_received', false
  );
end;
$$;

grant execute on function public.fn_receive_purchase_order(
  uuid,
  text
) to authenticated;

commit;
