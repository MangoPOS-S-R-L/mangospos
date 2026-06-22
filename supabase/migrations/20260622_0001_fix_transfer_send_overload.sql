-- ===========================================================================
-- Fix: overload ambiguo de fn_inventory_transfer_send (PGRST203)
--
-- Causa raíz: la BD quedó con DOS versiones de la función coexistiendo:
--   (a) 5-args  (uuid, uuid, uuid, jsonb, text)         ← 20260516_0009 (aprobación)
--   (b) 6-args  (uuid, uuid, uuid, jsonb, text, uuid)   ← 20260514_0004 (cross-business)
-- La migración 0009 hizo `create or replace` de la 5-args pero NO dropeó la
-- 6-args de 0004 (firma distinta ⇒ no la reemplaza, crea un overload nuevo).
-- En una transferencia intra-business el cliente manda 5 args y AMBAS firmas
-- son candidatas ⇒ PostgREST devuelve PGRST203 "Could not choose the best
-- candidate function".
--
-- Además cada versión tenía solo una mitad de la funcionalidad:
--   - la 5-args (0009): flujo de APROBACIÓN, sin cross-business.
--   - la 6-args (0004): CROSS-BUSINESS, sin aprobación.
-- La UI usa las dos (pestaña "Por aprobar" + toggle inter-sucursal).
--
-- Fix: dejar UNA sola función 6-args que combine AMBAS features y eliminar la
-- 5-args. El helper fn_inventory_transfer_apply_movements ya es válido para
-- cross-business (mueve stock solo del lado origen: out bodega origen →
-- IN_TRANSIT del origen; el destino recibe al confirmar), así que no cambia.
--
-- Idempotente y seguro de re-correr.
-- ===========================================================================

-- 1. Eliminar la 5-args (la de 0009). Su lógica de aprobación se conserva en la
--    6-args fusionada de abajo.
drop function if exists public.fn_inventory_transfer_send(uuid, uuid, uuid, jsonb, text);

-- 2. Reemplazar la 6-args por la versión fusionada (aprobación + cross-business).
create or replace function public.fn_inventory_transfer_send(
  p_business_id uuid,
  p_from_warehouse_id uuid,
  p_to_warehouse_id uuid,
  p_items jsonb,
  p_notes text default null,
  p_target_business_id uuid default null
) returns public.stock_transfers
language plpgsql
security definer
set search_path = public
as $$
declare
  v_target_bid uuid;
  v_is_cross boolean;
  v_role_src text;
  v_role_tgt text;
  v_transfer public.stock_transfers;
  v_item jsonb;
  v_item_id uuid;
  v_qty numeric;
  v_cost numeric;
  v_requires_approval boolean;
  v_initial_status text;
begin
  if p_business_id is null
     or p_from_warehouse_id is null
     or p_to_warehouse_id is null then
    raise exception 'MISSING_REQUIRED_PARAMS';
  end if;
  if p_from_warehouse_id = p_to_warehouse_id then
    raise exception 'SAME_WAREHOUSE';
  end if;
  if p_items is null or jsonb_typeof(p_items) <> 'array' or jsonb_array_length(p_items) = 0 then
    raise exception 'EMPTY_ITEMS';
  end if;

  v_target_bid := coalesce(p_target_business_id, p_business_id);
  v_is_cross := v_target_bid <> p_business_id;

  -- Rol en source (sender) obligatorio.
  v_role_src := public.user_business_role(auth.uid(), p_business_id);
  if v_role_src not in ('owner','admin','manager') then
    raise exception 'INSUFFICIENT_ROLE_SOURCE';
  end if;

  -- Cross-business: el usuario también debe tener rol en target.
  if v_is_cross then
    v_role_tgt := public.user_business_role(auth.uid(), v_target_bid);
    if v_role_tgt not in ('owner','admin','manager') then
      raise exception 'INSUFFICIENT_ROLE_TARGET';
    end if;
  end if;

  -- Validar warehouses: origen pertenece al source, destino al target.
  if not exists (
    select 1 from public.warehouses
    where id = p_from_warehouse_id and business_id = p_business_id
  ) then
    raise exception 'FROM_WAREHOUSE_NOT_FOUND';
  end if;
  if not exists (
    select 1 from public.warehouses
    where id = p_to_warehouse_id and business_id = v_target_bid
  ) then
    raise exception 'TO_WAREHOUSE_NOT_FOUND';
  end if;

  -- Flag de aprobación del business (origen). Cuando está activo, la
  -- transferencia queda 'pending_approval' y el stock NO se mueve hasta aprobar.
  select coalesce(transfers_require_approval, false)
    into v_requires_approval
  from public.business_settings
  where business_id = p_business_id;

  v_initial_status := case
    when coalesce(v_requires_approval, false) then 'pending_approval'
    else 'sent'
  end;

  -- Header. business_id legacy = from_business_id (source). IN_TRANSIT vive en
  -- el source business hasta que el destino confirme la recepción.
  insert into public.stock_transfers (
    business_id,
    from_business_id,
    to_business_id,
    from_warehouse_id,
    to_warehouse_id,
    transfer_number,
    status,
    notes,
    created_by
  )
  values (
    p_business_id,
    p_business_id,
    v_target_bid,
    p_from_warehouse_id,
    p_to_warehouse_id,
    public.fn_next_transfer_number(p_business_id),
    v_initial_status,
    p_notes,
    auth.uid()
  )
  returning * into v_transfer;

  -- Detalle. El item debe pertenecer al SOURCE business (el target_item_id se
  -- resuelve al recibir, no acá).
  for v_item in select * from jsonb_array_elements(p_items)
  loop
    v_item_id := (v_item->>'item_id')::uuid;
    v_qty := (v_item->>'quantity')::numeric;
    v_cost := nullif(v_item->>'cost_per_unit','')::numeric;

    if v_item_id is null or v_qty is null or v_qty <= 0 then
      raise exception 'INVALID_ITEM_ROW';
    end if;

    if not exists (
      select 1 from public.inventory_items
      where id = v_item_id and business_id = p_business_id
    ) then
      raise exception 'ITEM_NOT_FROM_SOURCE: %', v_item_id;
    end if;

    insert into public.stock_transfer_items (
      stock_transfer_id,
      item_id,
      quantity_sent,
      cost_per_unit
    )
    values (v_transfer.id, v_item_id, v_qty, v_cost);
  end loop;

  -- Si no requiere aprobación, mover el stock ahora (out origen → IN_TRANSIT
  -- origen). El helper es válido también para cross-business.
  if v_initial_status = 'sent' then
    perform public.fn_inventory_transfer_apply_movements(v_transfer.id);
  end if;

  return v_transfer;
end;
$$;

grant execute on function public.fn_inventory_transfer_send(uuid, uuid, uuid, jsonb, text, uuid)
  to authenticated;

comment on function public.fn_inventory_transfer_send(uuid, uuid, uuid, jsonb, text, uuid) is
  'Crea una transferencia entre bodegas (intra o inter-business). Respeta '
  'business_settings.transfers_require_approval (pending_approval vs sent). '
  'Fusiona aprobación (0009) + cross-business (0004); resuelve el overload '
  'ambiguo PGRST203 al dejar una sola firma (20260622_0001).';
