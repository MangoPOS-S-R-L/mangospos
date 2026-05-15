-- =============================================================================
-- Inventario PRD: workflow de aprobación de transferencias.
--
-- CONCEPTO:
--   Hoy las transferencias entre bodegas se ejecutan al instante: el creador
--   las marca como 'sent' y el stock se mueve a IN_TRANSIT inmediatamente.
--
--   Con aprobación activa: el creador deja la transferencia en
--   'pending_approval' SIN mover stock. Un usuario con permiso de aprobación
--   la revisa y la aprueba; recién ahí se mueve el stock a IN_TRANSIT y
--   queda como 'sent' (lista para que la bodega destino la reciba).
--
-- WORKFLOW (flag ON):
--   create → pending_approval → sent → received | cancelled
--                            └────────────────→ cancelled
--
-- WORKFLOW (flag OFF, legacy):
--   create → sent → received | cancelled
--
-- ENTREGA:
--   1. CHECK constraint extendido para `stock_transfers.status` con
--      'pending_approval'.
--   2. Columnas `approved_at`, `approved_by` en `stock_transfers`.
--   3. `business_settings.transfers_require_approval BOOLEAN DEFAULT false`.
--   4. Helper interno `fn_inventory_transfer_apply_movements(transfer_id)`
--      que ejecuta los movimientos out/in_transit. Reutilizable desde send
--      (flag off) y approve.
--   5. Modificación a `fn_inventory_transfer_send`: si flag ON, crea
--      header + items en 'pending_approval' SIN mover stock. Si OFF, se
--      comporta igual que antes.
--   6. Nuevo RPC `fn_inventory_transfer_approve(transfer_id)`: valida rol,
--      mueve stock vía helper, marca status='sent' + approved_at/by.
--   7. `fn_inventory_transfer_cancel` ahora también acepta cancelar desde
--      'pending_approval'.
--
-- IDEMPOTENTE: ADD COLUMN IF NOT EXISTS + CREATE OR REPLACE.
-- =============================================================================

begin;

-- ---------------------------------------------------------------------------
-- 1. Extender CHECK del status
-- ---------------------------------------------------------------------------

alter table public.stock_transfers
  drop constraint if exists stock_transfers_status_check;

alter table public.stock_transfers
  add constraint stock_transfers_status_check
  check (status in ('pending_approval', 'sent', 'received', 'cancelled'));

-- ---------------------------------------------------------------------------
-- 2. Columnas de aprobación
-- ---------------------------------------------------------------------------

alter table public.stock_transfers
  add column if not exists approved_at timestamptz;

alter table public.stock_transfers
  add column if not exists approved_by uuid;

-- FK a auth.users (idempotente)
do $$
begin
  if not exists (
    select 1 from pg_constraint
    where conname = 'stock_transfers_approved_by_fkey'
  ) then
    alter table public.stock_transfers
      add constraint stock_transfers_approved_by_fkey
      foreign key (approved_by)
      references auth.users(id)
      on delete set null;
  end if;
end $$;

-- ---------------------------------------------------------------------------
-- 3. business_settings.transfers_require_approval
-- ---------------------------------------------------------------------------

alter table public.business_settings
  add column if not exists transfers_require_approval boolean
    not null default false;

comment on column public.business_settings.transfers_require_approval is
  'Si true, las transferencias entre bodegas quedan en pending_approval al '
  'crearse y necesitan ser aprobadas por un usuario con permiso antes de '
  'mover stock. Default false = comportamiento legacy directo.';

-- ---------------------------------------------------------------------------
-- 4. Helper interno: aplicar movimientos de stock
-- ---------------------------------------------------------------------------

create or replace function public.fn_inventory_transfer_apply_movements(
  p_transfer_id uuid
) returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_transfer public.stock_transfers;
  v_in_transit_id uuid;
  v_item public.stock_transfer_items;
begin
  select * into v_transfer
  from public.stock_transfers
  where id = p_transfer_id;

  if v_transfer.id is null then
    raise exception 'TRANSFER_NOT_FOUND';
  end if;

  v_in_transit_id := public.ensure_in_transit_warehouse(v_transfer.business_id);

  for v_item in
    select * from public.stock_transfer_items
    where stock_transfer_id = p_transfer_id
  loop
    -- Salida del origen.
    perform public.fn_inventory_record_movement(
      p_business_id    => v_transfer.business_id,
      p_warehouse_id   => v_transfer.from_warehouse_id,
      p_item_id        => v_item.item_id,
      p_movement_type  => 'transfer_out'::public.movement_type,
      p_quantity       => v_item.quantity_sent,
      p_cost_per_unit  => v_item.cost_per_unit,
      p_reference_id   => v_transfer.id,
      p_reference_type => 'stock_transfer',
      p_notes          => null
    );

    -- Entrada a IN_TRANSIT.
    perform public.fn_inventory_record_movement(
      p_business_id    => v_transfer.business_id,
      p_warehouse_id   => v_in_transit_id,
      p_item_id        => v_item.item_id,
      p_movement_type  => 'transfer_in'::public.movement_type,
      p_quantity       => v_item.quantity_sent,
      p_cost_per_unit  => v_item.cost_per_unit,
      p_reference_id   => v_transfer.id,
      p_reference_type => 'stock_transfer',
      p_notes          => null
    );
  end loop;
end;
$$;

-- ---------------------------------------------------------------------------
-- 5. fn_inventory_transfer_send (modificado)
--
--    Comportamiento según `business_settings.transfers_require_approval`:
--      - false (default) → status='sent', stock se mueve (legacy).
--      - true → status='pending_approval', stock NO se mueve.
-- ---------------------------------------------------------------------------

create or replace function public.fn_inventory_transfer_send(
  p_business_id uuid,
  p_from_warehouse_id uuid,
  p_to_warehouse_id uuid,
  p_items jsonb,
  p_notes text default null
) returns public.stock_transfers
language plpgsql
security definer
set search_path = public
as $$
declare
  v_role text;
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

  v_role := public.user_business_role(auth.uid(), p_business_id);
  if v_role not in ('owner','admin','manager') then
    raise exception 'INSUFFICIENT_ROLE';
  end if;

  if not exists (
    select 1 from public.warehouses
    where id = p_from_warehouse_id and business_id = p_business_id
  ) then
    raise exception 'FROM_WAREHOUSE_NOT_FOUND';
  end if;
  if not exists (
    select 1 from public.warehouses
    where id = p_to_warehouse_id and business_id = p_business_id
  ) then
    raise exception 'TO_WAREHOUSE_NOT_FOUND';
  end if;

  -- Leer flag de aprobación del business.
  select coalesce(transfers_require_approval, false)
    into v_requires_approval
  from public.business_settings
  where business_id = p_business_id;

  v_initial_status := case
    when coalesce(v_requires_approval, false) then 'pending_approval'
    else 'sent'
  end;

  -- Crear header.
  insert into public.stock_transfers (
    business_id,
    from_warehouse_id,
    to_warehouse_id,
    transfer_number,
    status,
    notes,
    created_by
  )
  values (
    p_business_id,
    p_from_warehouse_id,
    p_to_warehouse_id,
    public.fn_next_transfer_number(p_business_id),
    v_initial_status,
    p_notes,
    auth.uid()
  )
  returning * into v_transfer;

  -- Insertar items.
  for v_item in select * from jsonb_array_elements(p_items)
  loop
    v_item_id := (v_item->>'item_id')::uuid;
    v_qty := (v_item->>'quantity')::numeric;
    v_cost := nullif(v_item->>'cost_per_unit','')::numeric;

    if v_item_id is null or v_qty is null or v_qty <= 0 then
      raise exception 'INVALID_ITEM_ROW';
    end if;

    insert into public.stock_transfer_items (
      stock_transfer_id,
      item_id,
      quantity_sent,
      cost_per_unit
    )
    values (v_transfer.id, v_item_id, v_qty, v_cost);
  end loop;

  -- Si no requiere aprobación, mover stock ahora (comportamiento legacy).
  if v_initial_status = 'sent' then
    perform public.fn_inventory_transfer_apply_movements(v_transfer.id);
  end if;

  return v_transfer;
end;
$$;

grant execute on function public.fn_inventory_transfer_send(uuid, uuid, uuid, jsonb, text)
  to authenticated;

comment on function public.fn_inventory_transfer_send(uuid, uuid, uuid, jsonb, text) is
  'Crea una transferencia entre bodegas. Si business_settings.'
  'transfers_require_approval=true, queda en pending_approval sin mover '
  'stock. Si false, se marca sent y stock se mueve a IN_TRANSIT al instante.';

-- ---------------------------------------------------------------------------
-- 6. fn_inventory_transfer_approve
-- ---------------------------------------------------------------------------

create or replace function public.fn_inventory_transfer_approve(
  p_transfer_id uuid
) returns public.stock_transfers
language plpgsql
security definer
set search_path = public
as $$
declare
  v_transfer public.stock_transfers;
  v_role text;
begin
  if p_transfer_id is null then
    raise exception 'MISSING_REQUIRED_PARAMS';
  end if;

  select * into v_transfer from public.stock_transfers where id = p_transfer_id;
  if v_transfer.id is null then
    raise exception 'TRANSFER_NOT_FOUND';
  end if;

  v_role := public.user_business_role(auth.uid(), v_transfer.business_id);
  if v_role not in ('owner','admin','manager') then
    raise exception 'INSUFFICIENT_ROLE';
  end if;

  if v_transfer.status <> 'pending_approval' then
    raise exception 'INVALID_STATUS_TRANSITION: solo se aprueba desde pending_approval';
  end if;

  -- Aplicar movimientos.
  perform public.fn_inventory_transfer_apply_movements(p_transfer_id);

  -- Marcar aprobada.
  update public.stock_transfers
     set status = 'sent',
         approved_at = now(),
         approved_by = auth.uid(),
         sent_at = now()  -- el momento real de salida del stock
   where id = p_transfer_id
   returning * into v_transfer;

  return v_transfer;
end;
$$;

grant execute on function public.fn_inventory_transfer_approve(uuid) to authenticated;

comment on function public.fn_inventory_transfer_approve(uuid) is
  'Aprueba una transferencia en pending_approval. Mueve el stock a '
  'IN_TRANSIT y marca status=sent. Requiere rol owner/admin/manager.';

-- ---------------------------------------------------------------------------
-- 7. fn_inventory_transfer_cancel: aceptar cancelar desde pending_approval
-- ---------------------------------------------------------------------------

create or replace function public.fn_inventory_transfer_cancel(
  p_transfer_id uuid,
  p_reason text default null
) returns public.stock_transfers
language plpgsql
security definer
set search_path = public
as $$
declare
  v_transfer public.stock_transfers;
  v_role text;
  v_item public.stock_transfer_items;
  v_in_transit_id uuid;
begin
  if p_transfer_id is null then
    raise exception 'MISSING_REQUIRED_PARAMS';
  end if;

  select * into v_transfer from public.stock_transfers where id = p_transfer_id;
  if v_transfer.id is null then
    raise exception 'TRANSFER_NOT_FOUND';
  end if;

  v_role := public.user_business_role(auth.uid(), v_transfer.business_id);
  if v_role not in ('owner','admin','manager') then
    raise exception 'INSUFFICIENT_ROLE';
  end if;

  if v_transfer.status not in ('pending_approval', 'sent') then
    raise exception 'INVALID_STATUS_TRANSITION';
  end if;

  -- Si está en 'sent', hay que revertir el stock de IN_TRANSIT al origen.
  -- Si está en 'pending_approval', no hay movimientos que revertir.
  if v_transfer.status = 'sent' then
    v_in_transit_id := public.ensure_in_transit_warehouse(v_transfer.business_id);

    for v_item in
      select * from public.stock_transfer_items
      where stock_transfer_id = p_transfer_id
    loop
      -- Saca de IN_TRANSIT (revertir lo que entró ahí al enviar).
      perform public.fn_inventory_record_movement(
        p_business_id    => v_transfer.business_id,
        p_warehouse_id   => v_in_transit_id,
        p_item_id        => v_item.item_id,
        p_movement_type  => 'transfer_out'::public.movement_type,
        p_quantity       => v_item.quantity_sent,
        p_cost_per_unit  => v_item.cost_per_unit,
        p_reference_id   => v_transfer.id,
        p_reference_type => 'stock_transfer_cancel',
        p_notes          => 'Cancelación: devolver a origen'
      );
      -- Devuelve al origen.
      perform public.fn_inventory_record_movement(
        p_business_id    => v_transfer.business_id,
        p_warehouse_id   => v_transfer.from_warehouse_id,
        p_item_id        => v_item.item_id,
        p_movement_type  => 'transfer_in'::public.movement_type,
        p_quantity       => v_item.quantity_sent,
        p_cost_per_unit  => v_item.cost_per_unit,
        p_reference_id   => v_transfer.id,
        p_reference_type => 'stock_transfer_cancel',
        p_notes          => 'Cancelación: stock devuelto'
      );
    end loop;
  end if;

  update public.stock_transfers
     set status = 'cancelled',
         cancelled_at = now(),
         cancelled_by = auth.uid(),
         notes = case
                   when p_reason is not null and length(btrim(p_reason)) > 0
                     then coalesce(notes || E'\n', '') || 'CANCELACIÓN: ' || p_reason
                   else notes
                 end
   where id = p_transfer_id
   returning * into v_transfer;

  return v_transfer;
end;
$$;

grant execute on function public.fn_inventory_transfer_cancel(uuid, text) to authenticated;

comment on function public.fn_inventory_transfer_cancel(uuid, text) is
  'Cancela una transferencia. Si estaba en sent, revierte el stock de '
  'IN_TRANSIT a la bodega origen. Si estaba en pending_approval, no '
  'hay stock que revertir.';

commit;
