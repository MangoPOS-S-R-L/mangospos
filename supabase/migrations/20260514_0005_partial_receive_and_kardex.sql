-- =============================================================================
-- Sprint 3 Inventario — Recepción parcial de OC + Vista Kardex.
--
-- ENTREGA:
--
-- A) Recepción parcial de Órdenes de Compra:
--    - Nueva RPC `fn_receive_purchase_order_partial(order_id, line_items, notes)`
--      que recibe ÚNICAMENTE las cantidades indicadas por línea (no toda la OC).
--    - Recalcula automáticamente el `status` de la OC:
--        * Todas las líneas con received >= ordered → 'received'
--        * Al menos una línea con 0 < received < ordered → 'partial'
--        * Ninguna línea con received > 0 → mantiene 'sent'
--    - Idempotente: si una línea ya tiene received = ordered, la salta.
--    - Mantiene la RPC `fn_receive_purchase_order` original como atajo
--      "recibir todo lo pendiente" (no se modifica).
--
-- B) Vista Kardex `v_inventory_movements_with_balance`:
--    - Histórico completo de movimientos con saldo corrido por (warehouse, item).
--    - Incluye nombres descriptivos de item, bodega y usuario.
--    - Soporte de filtros via WHERE en el cliente (item_id, warehouse_id,
--      movement_type, created_at, created_by).
--    - Saldo corrido vía window function SUM() OVER (PARTITION BY ...).
--    - Índice de soporte para hot path del Kardex.
--
-- IDEMPOTENTE / BACKWARDS-COMPATIBLE:
--    - No modifica tablas existentes.
--    - No modifica la RPC original `fn_receive_purchase_order`.
--    - El cliente puede seguir llamando la RPC vieja para recibir-todo.
-- =============================================================================

begin;

-- ---------------------------------------------------------------------------
-- 1. RPC: fn_receive_purchase_order_partial
--
--    p_line_items: jsonb array `[{"poi_id": uuid, "quantity": numeric}]`
--    p_notes: opcional, se guarda en cada movimiento de inventario creado.
-- ---------------------------------------------------------------------------

create or replace function public.fn_receive_purchase_order_partial(
  p_order_id uuid,
  p_line_items jsonb,
  p_notes text default null
) returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_user_id uuid := auth.uid();
  v_role text;
  v_order public.purchase_orders;
  v_row jsonb;
  v_poi_id uuid;
  v_qty numeric;
  v_line public.purchase_order_items;
  v_pending numeric;
  v_posted_lines integer := 0;
  v_outstanding integer;
  v_final_status text;
begin
  if v_user_id is null then
    raise exception 'AUTH_REQUIRED';
  end if;
  if p_order_id is null then
    raise exception 'MISSING_REQUIRED_PARAMS';
  end if;
  if p_line_items is null
     or jsonb_typeof(p_line_items) <> 'array'
     or jsonb_array_length(p_line_items) = 0 then
    raise exception 'EMPTY_LINE_ITEMS';
  end if;

  select * into v_order
    from public.purchase_orders
    where id = p_order_id
    for update;

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
  if v_order.status = 'received' then
    raise exception 'PURCHASE_ORDER_ALREADY_RECEIVED';
  end if;
  if v_order.warehouse_id is null then
    raise exception 'PURCHASE_ORDER_WAREHOUSE_REQUIRED';
  end if;

  -- Procesar cada línea solicitada.
  for v_row in select * from jsonb_array_elements(p_line_items)
  loop
    v_poi_id := nullif(v_row->>'poi_id','')::uuid;
    v_qty    := nullif(v_row->>'quantity','')::numeric;

    if v_poi_id is null or v_qty is null then
      raise exception 'INVALID_LINE_ROW';
    end if;
    if v_qty <= 0 then
      -- Cantidad 0 o negativa: ignorar silenciosamente.
      continue;
    end if;

    select * into v_line
      from public.purchase_order_items
      where id = v_poi_id and purchase_order_id = p_order_id
      for update;

    if not found then
      raise exception 'LINE_NOT_IN_ORDER: %', v_poi_id;
    end if;

    v_pending := greatest(
      coalesce(v_line.quantity_ordered, 0) - coalesce(v_line.quantity_received, 0),
      0
    );

    if v_pending = 0 then
      -- Línea ya completada: saltar sin error (idempotencia).
      continue;
    end if;

    if v_qty > v_pending then
      raise exception 'QUANTITY_EXCEEDS_PENDING: line=% requested=% pending=%',
        v_poi_id, v_qty, v_pending;
    end if;

    -- Crear el movimiento de inventario sólo si la línea está vinculada a
    -- un insumo. Las líneas "libres" (sin inventory_item_id) avanzan en
    -- recepción pero no afectan stock.
    if v_line.inventory_item_id is not null then
      if not exists (
        select 1 from public.inventory_items ii
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
        v_qty,
        v_line.unit_cost,
        p_order_id,
        'purchase_order',
        coalesce(
          nullif(trim(p_notes), ''),
          concat('Recepcion parcial de ', v_order.order_number)
        ),
        v_user_id
      );

      v_posted_lines := v_posted_lines + 1;
    end if;

    update public.purchase_order_items
       set quantity_received = coalesce(quantity_received, 0) + v_qty
     where id = v_poi_id;
  end loop;

  -- Recalcular status final.
  select count(*)
    into v_outstanding
    from public.purchase_order_items poi
    where poi.purchase_order_id = p_order_id
      and coalesce(poi.quantity_ordered, 0) > coalesce(poi.quantity_received, 0);

  if v_outstanding = 0 then
    v_final_status := 'received';
  else
    -- Si ya hay algo recibido en cualquier línea, status = 'partial'.
    if exists (
      select 1 from public.purchase_order_items poi
      where poi.purchase_order_id = p_order_id
        and coalesce(poi.quantity_received, 0) > 0
    ) then
      v_final_status := 'partial';
    else
      v_final_status := v_order.status; -- mantiene 'draft'/'sent'
    end if;
  end if;

  update public.purchase_orders
     set status = v_final_status,
         received_date = case
           when v_final_status = 'received' then coalesce(received_date, current_date)
           else received_date
         end
   where id = p_order_id;

  return jsonb_build_object(
    'order_id', p_order_id,
    'status', v_final_status,
    'movements_created', v_posted_lines,
    'pending_lines', v_outstanding
  );
end;
$$;

grant execute on function public.fn_receive_purchase_order_partial(uuid, jsonb, text)
  to authenticated;

comment on function public.fn_receive_purchase_order_partial(uuid, jsonb, text) is
  'Recibe cantidades parciales por línea de una OC. Idempotente: salta líneas '
  'ya completas. Recalcula el status final (partial / received) automáticamente.';

-- ---------------------------------------------------------------------------
-- 2. Índice para Kardex: queries por (business, item, fecha) son el hot path.
-- ---------------------------------------------------------------------------

create index if not exists idx_inventory_movements_kardex
  on public.inventory_movements (business_id, item_id, created_at desc);

create index if not exists idx_inventory_movements_warehouse_item_time
  on public.inventory_movements (warehouse_id, item_id, created_at);

-- ---------------------------------------------------------------------------
-- 3. Vista Kardex con saldo corrido por (warehouse_id, item_id).
--
--    NOTA: el signo de `quantity` ya viene aplicado por
--    `fn_inventory_record_movement` (negativo para sale/transfer_out/waste,
--    positivo para purchase/transfer_in/return). Los movimientos creados
--    directamente por `fn_receive_purchase_order` también son positivos
--    porque son de tipo 'purchase'. Por lo tanto SUM(quantity) sobre el
--    window funciona sin necesidad de CASE.
-- ---------------------------------------------------------------------------

drop view if exists public.v_inventory_movements_with_balance;

create or replace view public.v_inventory_movements_with_balance as
select
  im.id,
  im.business_id,
  im.warehouse_id,
  w.name                 as warehouse_name,
  im.item_id,
  ii.name                as item_name,
  ii.sku                 as item_sku,
  ii.unit                as item_unit,
  im.movement_type,
  im.quantity,
  abs(im.quantity)       as quantity_abs,
  im.cost_per_unit,
  (abs(im.quantity) * coalesce(im.cost_per_unit, 0)) as total_value,
  im.reason_code,
  im.reference_id,
  im.reference_type,
  im.notes,
  im.created_by,
  pr.full_name           as created_by_name,
  im.created_at,
  sum(im.quantity) over (
    partition by im.warehouse_id, im.item_id
    order by im.created_at, im.id
    rows between unbounded preceding and current row
  )                      as running_balance
from public.inventory_movements im
left join public.inventory_items ii on ii.id = im.item_id
left join public.warehouses     w  on w.id  = im.warehouse_id
left join public.profiles       pr on pr.id = im.created_by;

comment on view public.v_inventory_movements_with_balance is
  'Kardex de inventario: historial de movimientos con saldo corrido por '
  '(warehouse_id, item_id). Consumido por la vista Kardex del UI.';

commit;
