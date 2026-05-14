-- =============================================================================
-- Sprint Inventario V1.1 — Fase B: Transferencias entre bodegas.
--
-- PROBLEMA:
--   Hoy mover stock entre dos bodegas requiere 2 movimientos manuales
--   (transfer_out + transfer_in) sin atomicidad ni tracking. Si el
--   conductor pierde mercancía en el camino, no hay forma de auditar
--   "salió X de bodega A pero llegó X-2 a bodega B".
--
-- ENTREGA:
--   1. Tablas `stock_transfers` (header) + `stock_transfer_items` (detalle).
--   2. Bodega virtual `__IN_TRANSIT__` por business (helper
--      `ensure_in_transit_warehouse`) para retener stock en tránsito.
--   3. RPC `fn_inventory_transfer_send`:
--        Crea el header en status='sent', registra `transfer_out` desde
--        la bodega origen y `transfer_in` hacia __IN_TRANSIT__ por cada
--        item (atómico).
--   4. RPC `fn_inventory_transfer_receive`:
--        Marca header como 'received'. Por cada item, registra
--        `transfer_out` desde __IN_TRANSIT__ y `transfer_in` hacia
--        bodega destino con la cantidad realmente recibida. Si
--        recibido < enviado, registra ajuste `adjustment` con
--        reason_code='theft' (faltante en tránsito) sobre __IN_TRANSIT__.
--   5. RPC `fn_inventory_transfer_cancel`:
--        Solo si status='sent'. Devuelve la mercancía a la bodega origen.
--   6. Vista `v_inventory_transfers_log` para reportes.
--
-- BACKWARDS-COMPATIBLE:
--   - Todo nuevo: no modifica RPCs ni tablas existentes.
--   - Usa `fn_inventory_record_movement` para mantener un solo path de
--     inserción de movimientos (que dispara triggers de stock).
-- =============================================================================

begin;

-- ---------------------------------------------------------------------------
-- 1. Tablas
-- ---------------------------------------------------------------------------

create table if not exists public.stock_transfers (
  id                uuid not null default gen_random_uuid() primary key,
  business_id       uuid not null references public.businesses(id) on delete cascade,
  from_warehouse_id uuid not null references public.warehouses(id),
  to_warehouse_id   uuid not null references public.warehouses(id),
  transfer_number   text not null,
  status            text not null default 'sent'
                      check (status in ('sent','received','cancelled')),
  sent_at           timestamptz not null default now(),
  received_at       timestamptz,
  cancelled_at      timestamptz,
  notes             text,
  created_by        uuid references auth.users(id),
  received_by       uuid references auth.users(id),
  cancelled_by      uuid references auth.users(id),
  created_at        timestamptz not null default now(),
  unique (business_id, transfer_number),
  check (from_warehouse_id <> to_warehouse_id)
);

create index if not exists idx_stock_transfers_business_status
  on public.stock_transfers (business_id, status, sent_at desc);

alter table public.stock_transfers enable row level security;

drop policy if exists "st_select" on public.stock_transfers;
create policy "st_select" on public.stock_transfers
  for select to authenticated
  using (public.user_has_business_access(auth.uid(), business_id));

drop policy if exists "st_write" on public.stock_transfers;
create policy "st_write" on public.stock_transfers
  to authenticated
  using (
    public.user_business_role(auth.uid(), business_id)
      = any (array['owner','admin','manager'])
  )
  with check (
    public.user_business_role(auth.uid(), business_id)
      = any (array['owner','admin','manager'])
  );

create table if not exists public.stock_transfer_items (
  id                  uuid not null default gen_random_uuid() primary key,
  stock_transfer_id   uuid not null references public.stock_transfers(id) on delete cascade,
  item_id             uuid not null references public.inventory_items(id),
  quantity_sent       numeric(14,4) not null check (quantity_sent > 0),
  quantity_received   numeric(14,4),
  cost_per_unit       numeric(14,4),
  variance_reason     text
);

create index if not exists idx_stock_transfer_items_parent
  on public.stock_transfer_items (stock_transfer_id);

alter table public.stock_transfer_items enable row level security;

drop policy if exists "sti_select" on public.stock_transfer_items;
create policy "sti_select" on public.stock_transfer_items
  for select to authenticated
  using (
    exists (
      select 1 from public.stock_transfers t
      where t.id = stock_transfer_items.stock_transfer_id
        and public.user_has_business_access(auth.uid(), t.business_id)
    )
  );

drop policy if exists "sti_write" on public.stock_transfer_items;
create policy "sti_write" on public.stock_transfer_items
  to authenticated
  using (
    exists (
      select 1 from public.stock_transfers t
      where t.id = stock_transfer_items.stock_transfer_id
        and public.user_business_role(auth.uid(), t.business_id)
              = any (array['owner','admin','manager'])
    )
  )
  with check (
    exists (
      select 1 from public.stock_transfers t
      where t.id = stock_transfer_items.stock_transfer_id
        and public.user_business_role(auth.uid(), t.business_id)
              = any (array['owner','admin','manager'])
    )
  );

-- ---------------------------------------------------------------------------
-- 2. Helper: ensure_in_transit_warehouse(business_id)
-- ---------------------------------------------------------------------------

create or replace function public.ensure_in_transit_warehouse(
  p_business_id uuid
) returns uuid
language plpgsql
security definer
set search_path = public
as $$
declare
  v_id uuid;
begin
  if auth.uid() is null then
    raise exception 'AUTH_REQUIRED';
  end if;

  if public.user_business_role(auth.uid(), p_business_id) is null then
    raise exception 'NOT_AUTHORIZED';
  end if;

  select id into v_id
  from public.warehouses
  where business_id = p_business_id
    and name = '__IN_TRANSIT__'
  limit 1;

  if v_id is null then
    insert into public.warehouses (business_id, name, address, is_main, is_active)
    values (p_business_id, '__IN_TRANSIT__', null, false, true)
    returning id into v_id;
  end if;

  return v_id;
end;
$$;

grant execute on function public.ensure_in_transit_warehouse(uuid) to authenticated;

-- ---------------------------------------------------------------------------
-- 3. Helper: generar transfer_number autoincremental por business
-- ---------------------------------------------------------------------------

create or replace function public.fn_next_transfer_number(
  p_business_id uuid
) returns text
language plpgsql
security definer
set search_path = public
as $$
declare
  v_next int;
begin
  select coalesce(max(
    nullif(regexp_replace(transfer_number, '\D', '', 'g'), '')::int
  ), 0) + 1
  into v_next
  from public.stock_transfers
  where business_id = p_business_id
    and transfer_number ~ '^T-\d+$';

  return 'T-' || lpad(v_next::text, 6, '0');
end;
$$;

grant execute on function public.fn_next_transfer_number(uuid) to authenticated;

-- ---------------------------------------------------------------------------
-- 4. RPC: fn_inventory_transfer_send
--
-- p_items: jsonb array de objetos `[{"item_id": uuid, "quantity": num,
--          "cost_per_unit": num | null}]`
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
  v_in_transit_id uuid;
  v_transfer public.stock_transfers;
  v_item jsonb;
  v_item_id uuid;
  v_qty numeric;
  v_cost numeric;
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

  -- Validar que las bodegas pertenecen al business.
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

  -- Crear bodega IN_TRANSIT si no existe.
  v_in_transit_id := public.ensure_in_transit_warehouse(p_business_id);

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
    'sent',
    p_notes,
    auth.uid()
  )
  returning * into v_transfer;

  -- Por cada item: insertar detalle + transfer_out de origen + transfer_in
  -- a IN_TRANSIT. Usamos fn_inventory_record_movement para reutilizar la
  -- lógica de signo y triggers de stock.
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

    -- Salida del origen.
    perform public.fn_inventory_record_movement(
      p_business_id    => p_business_id,
      p_warehouse_id   => p_from_warehouse_id,
      p_item_id        => v_item_id,
      p_movement_type  => 'transfer_out'::public.movement_type,
      p_quantity       => v_qty,
      p_cost_per_unit  => v_cost,
      p_reference_id   => v_transfer.id,
      p_reference_type => 'stock_transfer',
      p_notes          => null
    );

    -- Entrada a IN_TRANSIT.
    perform public.fn_inventory_record_movement(
      p_business_id    => p_business_id,
      p_warehouse_id   => v_in_transit_id,
      p_item_id        => v_item_id,
      p_movement_type  => 'transfer_in'::public.movement_type,
      p_quantity       => v_qty,
      p_cost_per_unit  => v_cost,
      p_reference_id   => v_transfer.id,
      p_reference_type => 'stock_transfer',
      p_notes          => null
    );
  end loop;

  return v_transfer;
end;
$$;

grant execute on function public.fn_inventory_transfer_send(uuid, uuid, uuid, jsonb, text)
  to authenticated;

comment on function public.fn_inventory_transfer_send(uuid, uuid, uuid, jsonb, text) is
  'Envía mercancía desde bodega origen hacia __IN_TRANSIT__. Crea header '
  'stock_transfers en status=sent + 2 movimientos por item (out origen, '
  'in IN_TRANSIT). Atómico.';

-- ---------------------------------------------------------------------------
-- 5. RPC: fn_inventory_transfer_receive
--
-- p_received_items: jsonb array `[{"transfer_item_id": uuid,
--                                  "quantity_received": num}]`
-- Si quantity_received < quantity_sent → ajuste sobre IN_TRANSIT con
-- reason_code='theft' (faltante en tránsito).
-- ---------------------------------------------------------------------------

create or replace function public.fn_inventory_transfer_receive(
  p_transfer_id uuid,
  p_received_items jsonb,
  p_variance_notes text default null
) returns public.stock_transfers
language plpgsql
security definer
set search_path = public
as $$
declare
  v_role text;
  v_transfer public.stock_transfers;
  v_in_transit_id uuid;
  v_row jsonb;
  v_ti_id uuid;
  v_qty_received numeric;
  v_ti public.stock_transfer_items;
  v_variance numeric;
  v_adjust_movement_id uuid;
begin
  if p_transfer_id is null then
    raise exception 'MISSING_REQUIRED_PARAMS';
  end if;
  if p_received_items is null
     or jsonb_typeof(p_received_items) <> 'array'
     or jsonb_array_length(p_received_items) = 0 then
    raise exception 'EMPTY_ITEMS';
  end if;

  select * into v_transfer
  from public.stock_transfers
  where id = p_transfer_id
  for update;

  if v_transfer.id is null then
    raise exception 'TRANSFER_NOT_FOUND';
  end if;
  if v_transfer.status <> 'sent' then
    raise exception 'TRANSFER_NOT_PENDING: status=%', v_transfer.status;
  end if;

  v_role := public.user_business_role(auth.uid(), v_transfer.business_id);
  if v_role not in ('owner','admin','manager') then
    raise exception 'INSUFFICIENT_ROLE';
  end if;

  v_in_transit_id := public.ensure_in_transit_warehouse(v_transfer.business_id);

  for v_row in select * from jsonb_array_elements(p_received_items)
  loop
    v_ti_id := (v_row->>'transfer_item_id')::uuid;
    v_qty_received := (v_row->>'quantity_received')::numeric;

    if v_ti_id is null or v_qty_received is null or v_qty_received < 0 then
      raise exception 'INVALID_ITEM_ROW';
    end if;

    select * into v_ti
    from public.stock_transfer_items
    where id = v_ti_id and stock_transfer_id = v_transfer.id
    for update;

    if v_ti.id is null then
      raise exception 'TRANSFER_ITEM_NOT_FOUND: %', v_ti_id;
    end if;
    if v_qty_received > v_ti.quantity_sent then
      raise exception 'RECEIVED_EXCEEDS_SENT: % > %', v_qty_received, v_ti.quantity_sent;
    end if;

    update public.stock_transfer_items
    set quantity_received = v_qty_received,
        variance_reason   = case
          when v_qty_received < v_ti.quantity_sent then 'in_transit_loss'
          else null
        end
    where id = v_ti.id;

    v_variance := v_ti.quantity_sent - v_qty_received;

    -- Salida de IN_TRANSIT (lo que efectivamente sale para llegar al destino +
    -- lo que se perdió en tránsito).
    if v_qty_received > 0 then
      perform public.fn_inventory_record_movement(
        p_business_id    => v_transfer.business_id,
        p_warehouse_id   => v_in_transit_id,
        p_item_id        => v_ti.item_id,
        p_movement_type  => 'transfer_out'::public.movement_type,
        p_quantity       => v_qty_received,
        p_cost_per_unit  => v_ti.cost_per_unit,
        p_reference_id   => v_transfer.id,
        p_reference_type => 'stock_transfer',
        p_notes          => null
      );

      -- Entrada al destino.
      perform public.fn_inventory_record_movement(
        p_business_id    => v_transfer.business_id,
        p_warehouse_id   => v_transfer.to_warehouse_id,
        p_item_id        => v_ti.item_id,
        p_movement_type  => 'transfer_in'::public.movement_type,
        p_quantity       => v_qty_received,
        p_cost_per_unit  => v_ti.cost_per_unit,
        p_reference_id   => v_transfer.id,
        p_reference_type => 'stock_transfer',
        p_notes          => null
      );
    end if;

    -- Si hubo merma, registrarla como ajuste sobre IN_TRANSIT.
    if v_variance > 0 then
      perform public.fn_inventory_record_movement(
        p_business_id    => v_transfer.business_id,
        p_warehouse_id   => v_in_transit_id,
        p_item_id        => v_ti.item_id,
        p_movement_type  => 'adjustment'::public.movement_type,
        p_quantity       => -v_variance,
        p_cost_per_unit  => v_ti.cost_per_unit,
        p_reference_id   => v_transfer.id,
        p_reference_type => 'stock_transfer_variance',
        p_notes          => coalesce(p_variance_notes, 'Faltante en tránsito')
      );

      -- Setear reason_code en el último movimiento de ajuste de este transfer.
      select id into v_adjust_movement_id
      from public.inventory_movements
      where reference_id = v_transfer.id
        and reference_type = 'stock_transfer_variance'
        and item_id = v_ti.item_id
      order by created_at desc
      limit 1;

      if v_adjust_movement_id is not null then
        update public.inventory_movements
        set reason_code = 'theft'
        where id = v_adjust_movement_id;
      end if;
    end if;
  end loop;

  update public.stock_transfers
  set status        = 'received',
      received_at   = now(),
      received_by   = auth.uid(),
      notes         = case
        when p_variance_notes is null or btrim(p_variance_notes) = '' then notes
        else coalesce(notes || E'\n','') || 'Recepción: ' || p_variance_notes
      end
  where id = v_transfer.id
  returning * into v_transfer;

  return v_transfer;
end;
$$;

grant execute on function public.fn_inventory_transfer_receive(uuid, jsonb, text)
  to authenticated;

comment on function public.fn_inventory_transfer_receive(uuid, jsonb, text) is
  'Recibe una transferencia en status=sent. Mueve de __IN_TRANSIT__ al '
  'destino la cantidad recibida y registra merma (reason_code=theft) si '
  'recibido < enviado.';

-- ---------------------------------------------------------------------------
-- 6. RPC: fn_inventory_transfer_cancel
-- Devuelve la mercancía desde IN_TRANSIT a la bodega origen.
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
  v_role text;
  v_transfer public.stock_transfers;
  v_in_transit_id uuid;
  v_ti record;
begin
  if p_transfer_id is null then
    raise exception 'MISSING_REQUIRED_PARAMS';
  end if;

  select * into v_transfer
  from public.stock_transfers
  where id = p_transfer_id
  for update;

  if v_transfer.id is null then
    raise exception 'TRANSFER_NOT_FOUND';
  end if;
  if v_transfer.status <> 'sent' then
    raise exception 'TRANSFER_NOT_CANCELLABLE: status=%', v_transfer.status;
  end if;

  v_role := public.user_business_role(auth.uid(), v_transfer.business_id);
  if v_role not in ('owner','admin','manager') then
    raise exception 'INSUFFICIENT_ROLE';
  end if;

  v_in_transit_id := public.ensure_in_transit_warehouse(v_transfer.business_id);

  for v_ti in
    select * from public.stock_transfer_items where stock_transfer_id = v_transfer.id
  loop
    -- Saca de IN_TRANSIT.
    perform public.fn_inventory_record_movement(
      p_business_id    => v_transfer.business_id,
      p_warehouse_id   => v_in_transit_id,
      p_item_id        => v_ti.item_id,
      p_movement_type  => 'transfer_out'::public.movement_type,
      p_quantity       => v_ti.quantity_sent,
      p_cost_per_unit  => v_ti.cost_per_unit,
      p_reference_id   => v_transfer.id,
      p_reference_type => 'stock_transfer_cancel',
      p_notes          => p_reason
    );
    -- Devuelve al origen.
    perform public.fn_inventory_record_movement(
      p_business_id    => v_transfer.business_id,
      p_warehouse_id   => v_transfer.from_warehouse_id,
      p_item_id        => v_ti.item_id,
      p_movement_type  => 'transfer_in'::public.movement_type,
      p_quantity       => v_ti.quantity_sent,
      p_cost_per_unit  => v_ti.cost_per_unit,
      p_reference_id   => v_transfer.id,
      p_reference_type => 'stock_transfer_cancel',
      p_notes          => p_reason
    );
  end loop;

  update public.stock_transfers
  set status       = 'cancelled',
      cancelled_at = now(),
      cancelled_by = auth.uid(),
      notes        = case
        when p_reason is null or btrim(p_reason) = '' then notes
        else coalesce(notes || E'\n','') || 'Cancelación: ' || p_reason
      end
  where id = v_transfer.id
  returning * into v_transfer;

  return v_transfer;
end;
$$;

grant execute on function public.fn_inventory_transfer_cancel(uuid, text)
  to authenticated;

-- ---------------------------------------------------------------------------
-- 7. Vista de log de transferencias para reportes.
-- ---------------------------------------------------------------------------

create or replace view public.v_inventory_transfers_log as
select
  st.id                as transfer_id,
  st.business_id,
  st.transfer_number,
  st.status,
  st.from_warehouse_id,
  wf.name              as from_warehouse_name,
  st.to_warehouse_id,
  wt.name              as to_warehouse_name,
  st.sent_at,
  st.received_at,
  st.cancelled_at,
  st.notes,
  st.created_by,
  pc.full_name         as created_by_name,
  st.received_by,
  pr.full_name         as received_by_name,
  (select count(*) from public.stock_transfer_items sti where sti.stock_transfer_id = st.id)
                       as item_count,
  (select coalesce(sum(sti.quantity_sent), 0)
     from public.stock_transfer_items sti where sti.stock_transfer_id = st.id)
                       as total_sent,
  (select coalesce(sum(coalesce(sti.quantity_received, 0)), 0)
     from public.stock_transfer_items sti where sti.stock_transfer_id = st.id)
                       as total_received
from public.stock_transfers st
left join public.warehouses wf on wf.id = st.from_warehouse_id
left join public.warehouses wt on wt.id = st.to_warehouse_id
left join public.profiles pc   on pc.id = st.created_by
left join public.profiles pr   on pr.id = st.received_by;

comment on view public.v_inventory_transfers_log is
  'Log de transferencias entre bodegas con cantidades enviadas y '
  'recibidas. Consumido por el reporte de transferencias.';

commit;
