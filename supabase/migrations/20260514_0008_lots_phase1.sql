-- =============================================================================
-- Sprint 4 Inventario — Lotes y vencimientos (Fase 1: bitácora).
--
-- ALCANCE FASE 1:
--   - Opt-in por insumo via `inventory_items.tracks_lots`. Sin backfill:
--     items existentes mantienen comportamiento plano.
--   - Tabla `inventory_lots` registra cada recepción con número, vencimiento
--     y `remaining_quantity`. Es una bitácora paralela al stock plano —
--     no reemplaza `inventory_stock`.
--   - Las entradas (direct receipt + recepción parcial de OC) ahora aceptan
--     lot_number/expiry_date opcionales por línea. Si el item tiene
--     `tracks_lots = true` y el lote no se llena, se autogenera.
--   - El usuario "dispone" lotes manualmente (botón en la UI) — registra
--     un ajuste negativo si quedaba saldo y marca el lote como dispuesto.
--
-- LO QUE NO HACE (queda para Fase 2):
--   - FEFO automático al consumir (sale, transfer_out, waste).
--   - Sincronización rígida entre SUM(lots.remaining) e inventory_stock.
--   - Los movimientos siguen sin `lot_id` (eso requiere refactor de
--     fn_inventory_record_movement, que es donde está el costo de la fase 2).
--
-- IDEMPOTENTE:
--   - ADD COLUMN IF NOT EXISTS, CREATE TABLE IF NOT EXISTS, etc.
--   - CREATE OR REPLACE FUNCTION para las RPCs.
-- =============================================================================

begin;

-- ---------------------------------------------------------------------------
-- 1. Flag opt-in en inventory_items.
-- ---------------------------------------------------------------------------

alter table public.inventory_items
  add column if not exists tracks_lots boolean not null default false;

comment on column public.inventory_items.tracks_lots is
  'Si true, las entradas de este insumo registran un lote (número + fecha '
  'de vencimiento) en inventory_lots. Default false — comportamiento legacy.';

-- ---------------------------------------------------------------------------
-- 2. Tabla inventory_lots
-- ---------------------------------------------------------------------------

create table if not exists public.inventory_lots (
  id                   uuid not null default gen_random_uuid() primary key,
  business_id          uuid not null references public.businesses(id) on delete cascade,
  item_id              uuid not null references public.inventory_items(id),
  warehouse_id         uuid not null references public.warehouses(id),
  lot_number           text not null,
  expiry_date          date,
  received_date        date not null default current_date,
  received_quantity    numeric(14,4) not null check (received_quantity > 0),
  remaining_quantity   numeric(14,4) not null check (remaining_quantity >= 0),
  cost_per_unit        numeric(14,4),
  source_type          text not null
                         check (source_type in (
                           'direct_receipt','purchase_order','transfer','manual'
                         )),
  source_id            uuid,
  status               text not null default 'active'
                         check (status in ('active','depleted','disposed')),
  notes                text,
  disposed_reason      text,
  disposed_at          timestamptz,
  disposed_by          uuid references auth.users(id),
  created_by           uuid references auth.users(id),
  created_at           timestamptz not null default now(),
  unique (business_id, item_id, warehouse_id, lot_number)
);

create index if not exists idx_inventory_lots_item_warehouse
  on public.inventory_lots (item_id, warehouse_id, status);

create index if not exists idx_inventory_lots_expiry
  on public.inventory_lots (business_id, expiry_date)
  where status = 'active' and expiry_date is not null;

create index if not exists idx_inventory_lots_business_created
  on public.inventory_lots (business_id, created_at desc);

alter table public.inventory_lots enable row level security;

drop policy if exists "lots_select" on public.inventory_lots;
create policy "lots_select" on public.inventory_lots
  for select to authenticated
  using (public.user_has_business_access(auth.uid(), business_id));

drop policy if exists "lots_write" on public.inventory_lots;
create policy "lots_write" on public.inventory_lots
  to authenticated
  using (
    public.user_business_role(auth.uid(), business_id)
      = any (array['owner','admin','manager'])
  )
  with check (
    public.user_business_role(auth.uid(), business_id)
      = any (array['owner','admin','manager'])
  );

-- ---------------------------------------------------------------------------
-- 3. Helper: número correlativo `L-YYYYMMDD-NNN` por (business, item, warehouse).
-- ---------------------------------------------------------------------------

create or replace function public.fn_next_lot_number(
  p_business_id uuid,
  p_item_id uuid,
  p_warehouse_id uuid
) returns text
language plpgsql
security definer
set search_path = public
as $$
declare
  v_prefix text;
  v_seq int;
begin
  v_prefix := 'L-' || to_char(current_date, 'YYYYMMDD') || '-';

  select coalesce(max(
    nullif(regexp_replace(
      lot_number, '^' || v_prefix, ''
    ), '')::int
  ), 0) + 1
  into v_seq
  from public.inventory_lots
  where business_id = p_business_id
    and item_id = p_item_id
    and warehouse_id = p_warehouse_id
    and lot_number like (v_prefix || '%')
    and lot_number ~ ('^' || v_prefix || '\d+$');

  return v_prefix || lpad(v_seq::text, 3, '0');
end;
$$;

grant execute on function public.fn_next_lot_number(uuid, uuid, uuid) to authenticated;

-- ---------------------------------------------------------------------------
-- 4. RPC: fn_inventory_register_lot
--
--    Crea (o vuelve a abrir) un lote para un insumo+bodega. Usado por las
--    entradas (direct receipt y purchase receive partial). Si lot_number
--    viene null, se autogenera.
-- ---------------------------------------------------------------------------

create or replace function public.fn_inventory_register_lot(
  p_business_id uuid,
  p_item_id uuid,
  p_warehouse_id uuid,
  p_quantity numeric,
  p_lot_number text default null,
  p_expiry_date date default null,
  p_cost_per_unit numeric default null,
  p_source_type text default 'manual',
  p_source_id uuid default null,
  p_notes text default null
) returns public.inventory_lots
language plpgsql
security definer
set search_path = public
as $$
declare
  v_role text;
  v_lot public.inventory_lots;
  v_lot_number text;
  v_existing public.inventory_lots;
begin
  if p_business_id is null or p_item_id is null
     or p_warehouse_id is null or p_quantity is null or p_quantity <= 0 then
    raise exception 'MISSING_REQUIRED_PARAMS';
  end if;
  if p_source_type not in ('direct_receipt','purchase_order','transfer','manual') then
    raise exception 'INVALID_SOURCE_TYPE';
  end if;

  v_role := public.user_business_role(auth.uid(), p_business_id);
  if v_role not in ('owner','admin','manager') then
    raise exception 'INSUFFICIENT_ROLE';
  end if;

  -- Validar item y warehouse pertenecen al business.
  if not exists (
    select 1 from public.inventory_items
    where id = p_item_id and business_id = p_business_id
  ) then
    raise exception 'ITEM_NOT_IN_BUSINESS';
  end if;
  if not exists (
    select 1 from public.warehouses
    where id = p_warehouse_id and business_id = p_business_id
  ) then
    raise exception 'WAREHOUSE_NOT_IN_BUSINESS';
  end if;

  v_lot_number := nullif(btrim(p_lot_number), '');
  if v_lot_number is null then
    v_lot_number := public.fn_next_lot_number(p_business_id, p_item_id, p_warehouse_id);
  end if;

  -- Si ya existe un lote con ese número (item+warehouse+number unique),
  -- sumamos cantidad al existente. Esto permite que el usuario reciba
  -- en dos tandas el mismo lote físico (ej. "LOT-2024-08-XYZ").
  select * into v_existing
    from public.inventory_lots
   where business_id = p_business_id
     and item_id = p_item_id
     and warehouse_id = p_warehouse_id
     and lot_number = v_lot_number
   for update;

  if v_existing.id is not null then
    update public.inventory_lots
       set received_quantity  = received_quantity + p_quantity,
           remaining_quantity = remaining_quantity + p_quantity,
           expiry_date        = coalesce(p_expiry_date, expiry_date),
           cost_per_unit      = coalesce(p_cost_per_unit, cost_per_unit),
           status             = 'active'
     where id = v_existing.id
    returning * into v_lot;
    return v_lot;
  end if;

  insert into public.inventory_lots (
    business_id,
    item_id,
    warehouse_id,
    lot_number,
    expiry_date,
    received_quantity,
    remaining_quantity,
    cost_per_unit,
    source_type,
    source_id,
    notes,
    created_by
  )
  values (
    p_business_id,
    p_item_id,
    p_warehouse_id,
    v_lot_number,
    p_expiry_date,
    p_quantity,
    p_quantity,
    p_cost_per_unit,
    p_source_type,
    p_source_id,
    p_notes,
    auth.uid()
  )
  returning * into v_lot;

  return v_lot;
end;
$$;

grant execute on function public.fn_inventory_register_lot(
  uuid, uuid, uuid, numeric, text, date, numeric, text, uuid, text
) to authenticated;

comment on function public.fn_inventory_register_lot(
  uuid, uuid, uuid, numeric, text, date, numeric, text, uuid, text
) is
  'Registra un lote de mercancía. Si el lot_number ya existe para el item+'
  'warehouse, suma la cantidad al lote existente (re-recepción del mismo '
  'lote físico). lot_number se autogenera si viene null.';

-- ---------------------------------------------------------------------------
-- 5. RPC: fn_inventory_lot_dispose
--
--    Marca un lote como dispuesto. Si quedaba saldo, registra un ajuste
--    negativo en la bodega para reflejarlo en el stock plano. Razón se
--    guarda en el header del lote.
-- ---------------------------------------------------------------------------

create or replace function public.fn_inventory_lot_dispose(
  p_lot_id uuid,
  p_reason text default null
) returns public.inventory_lots
language plpgsql
security definer
set search_path = public
as $$
declare
  v_role text;
  v_lot public.inventory_lots;
  v_qty_to_dispose numeric;
begin
  if p_lot_id is null then
    raise exception 'MISSING_REQUIRED_PARAMS';
  end if;

  select * into v_lot
    from public.inventory_lots
    where id = p_lot_id
    for update;

  if not found then
    raise exception 'LOT_NOT_FOUND';
  end if;
  if v_lot.status <> 'active' then
    raise exception 'LOT_NOT_DISPOSABLE: status=%', v_lot.status;
  end if;

  v_role := public.user_business_role(auth.uid(), v_lot.business_id);
  if v_role not in ('owner','admin','manager') then
    raise exception 'INSUFFICIENT_ROLE';
  end if;

  v_qty_to_dispose := v_lot.remaining_quantity;

  -- Si quedaba saldo, registrar ajuste negativo en el stock plano.
  if v_qty_to_dispose > 0 then
    perform public.fn_inventory_record_movement(
      p_business_id    => v_lot.business_id,
      p_warehouse_id   => v_lot.warehouse_id,
      p_item_id        => v_lot.item_id,
      p_movement_type  => 'adjustment'::public.movement_type,
      p_quantity       => -v_qty_to_dispose,
      p_cost_per_unit  => v_lot.cost_per_unit,
      p_reference_id   => v_lot.id,
      p_reference_type => 'lot_disposal',
      p_notes          => coalesce(
        p_reason,
        concat('Disposición de lote ', v_lot.lot_number)
      )
    );

    -- Marcar el movimiento con reason_code adecuado (expiration si está
    -- vencido, breakage por default para disposiciones tempranas).
    update public.inventory_movements
       set reason_code = case
         when v_lot.expiry_date is not null and v_lot.expiry_date < current_date
           then 'expiration'
         else 'breakage'
       end
     where reference_id = v_lot.id
       and reference_type = 'lot_disposal'
       and reason_code is null;
  end if;

  update public.inventory_lots
     set remaining_quantity = 0,
         status             = 'disposed',
         disposed_at        = now(),
         disposed_by        = auth.uid(),
         disposed_reason    = p_reason
   where id = v_lot.id
  returning * into v_lot;

  return v_lot;
end;
$$;

grant execute on function public.fn_inventory_lot_dispose(uuid, text)
  to authenticated;

comment on function public.fn_inventory_lot_dispose(uuid, text) is
  'Marca un lote como dispuesto. Si tiene saldo, registra ajuste negativo '
  'en stock plano (reason_code: expiration si está vencido, breakage si no). '
  'El header queda con status=disposed para auditoría.';

-- ---------------------------------------------------------------------------
-- 6. Vista v_inventory_lots_with_status: lotes con días hasta vencimiento.
-- ---------------------------------------------------------------------------

drop view if exists public.v_inventory_lots_with_status;

create or replace view public.v_inventory_lots_with_status as
select
  l.id,
  l.business_id,
  l.item_id,
  ii.name                  as item_name,
  ii.sku                   as item_sku,
  ii.unit                  as item_unit,
  l.warehouse_id,
  w.name                   as warehouse_name,
  l.lot_number,
  l.expiry_date,
  l.received_date,
  l.received_quantity,
  l.remaining_quantity,
  l.cost_per_unit,
  (l.remaining_quantity * coalesce(l.cost_per_unit, 0)) as remaining_value,
  l.source_type,
  l.source_id,
  l.status,
  l.notes,
  l.disposed_reason,
  l.disposed_at,
  l.disposed_by,
  pd.full_name             as disposed_by_name,
  l.created_by,
  pc.full_name             as created_by_name,
  l.created_at,
  case
    when l.expiry_date is null then null
    else (l.expiry_date - current_date)
  end                      as days_until_expiry,
  case
    when l.status = 'disposed' then 'disposed'
    when l.status = 'depleted' then 'depleted'
    when l.expiry_date is not null and l.expiry_date < current_date
      then 'expired'
    when l.expiry_date is not null and l.expiry_date <= current_date + interval '7 days'
      then 'critical'
    when l.expiry_date is not null and l.expiry_date <= current_date + interval '30 days'
      then 'warning'
    else 'fresh'
  end                      as expiry_status
from public.inventory_lots l
left join public.inventory_items ii on ii.id = l.item_id
left join public.warehouses     w  on w.id  = l.warehouse_id
left join public.profiles       pc on pc.id = l.created_by
left join public.profiles       pd on pd.id = l.disposed_by;

comment on view public.v_inventory_lots_with_status is
  'Lotes con días hasta vencimiento y estado calculado. expiry_status: '
  'fresh | warning (≤30d) | critical (≤7d) | expired | depleted | disposed.';

-- ---------------------------------------------------------------------------
-- 7. MODIFICAR fn_inventory_direct_receipt: ahora cada item puede traer
--    lot_number/expiry_date opcionales. Si el item tiene tracks_lots y se
--    proveen estos campos, se registra el lote en la misma transacción.
-- ---------------------------------------------------------------------------

create or replace function public.fn_inventory_direct_receipt(
  p_business_id uuid,
  p_warehouse_id uuid,
  p_items jsonb,
  p_supplier_id uuid default null,
  p_notes text default null
) returns public.direct_receipts
language plpgsql
security definer
set search_path = public
as $$
declare
  v_role text;
  v_header public.direct_receipts;
  v_row jsonb;
  v_item_id uuid;
  v_qty numeric;
  v_cost numeric;
  v_line_notes text;
  v_lot_number text;
  v_expiry date;
  v_tracks_lots boolean;
  v_total numeric := 0;
  v_line_total numeric;
begin
  if p_business_id is null or p_warehouse_id is null then
    raise exception 'MISSING_REQUIRED_PARAMS';
  end if;
  if p_items is null
     or jsonb_typeof(p_items) <> 'array'
     or jsonb_array_length(p_items) = 0 then
    raise exception 'EMPTY_ITEMS';
  end if;

  v_role := public.user_business_role(auth.uid(), p_business_id);
  if v_role not in ('owner','admin','manager') then
    raise exception 'INSUFFICIENT_ROLE';
  end if;

  if not exists (
    select 1 from public.warehouses
    where id = p_warehouse_id
      and business_id = p_business_id
      and coalesce(is_active, true)
  ) then
    raise exception 'WAREHOUSE_NOT_FOUND_OR_INACTIVE';
  end if;

  if p_supplier_id is not null then
    if not exists (
      select 1 from public.suppliers
      where id = p_supplier_id and business_id = p_business_id
    ) then
      raise exception 'SUPPLIER_NOT_FOUND';
    end if;
  end if;

  insert into public.direct_receipts (
    business_id, warehouse_id, supplier_id, receipt_number,
    status, total, notes, created_by
  )
  values (
    p_business_id, p_warehouse_id, p_supplier_id,
    public.fn_next_direct_receipt_number(p_business_id),
    'received', 0, p_notes, auth.uid()
  )
  returning * into v_header;

  for v_row in select * from jsonb_array_elements(p_items)
  loop
    v_item_id    := (v_row->>'item_id')::uuid;
    v_qty        := (v_row->>'quantity')::numeric;
    v_cost       := nullif(v_row->>'unit_cost','')::numeric;
    v_line_notes := nullif(trim(coalesce(v_row->>'notes','')), '');
    v_lot_number := nullif(trim(coalesce(v_row->>'lot_number','')), '');
    v_expiry     := nullif(v_row->>'expiry_date','')::date;

    if v_item_id is null or v_qty is null or v_qty <= 0 then
      raise exception 'INVALID_ITEM_ROW';
    end if;

    select coalesce(tracks_lots, false) into v_tracks_lots
      from public.inventory_items
      where id = v_item_id and business_id = p_business_id;

    if v_tracks_lots is null then
      raise exception 'ITEM_NOT_IN_BUSINESS: %', v_item_id;
    end if;

    insert into public.direct_receipt_items (
      direct_receipt_id, item_id, quantity, unit_cost, notes
    )
    values (v_header.id, v_item_id, v_qty, v_cost, v_line_notes);

    v_line_total := v_qty * coalesce(v_cost, 0);
    v_total := v_total + v_line_total;

    perform public.fn_inventory_record_movement(
      p_business_id    => p_business_id,
      p_warehouse_id   => p_warehouse_id,
      p_item_id        => v_item_id,
      p_movement_type  => 'purchase'::public.movement_type,
      p_quantity       => v_qty,
      p_cost_per_unit  => v_cost,
      p_reference_id   => v_header.id,
      p_reference_type => 'direct_receipt',
      p_notes          => coalesce(
        v_line_notes,
        concat('Recepción directa ', v_header.receipt_number)
      )
    );

    -- Si el item rastrea lotes, registrar el lote (atómico con la entrada).
    -- Si lot_number es null se autogenera. Si tracks_lots = false, se ignora
    -- el lot_number aunque venga (para no contaminar items que no rastrean).
    if v_tracks_lots then
      perform public.fn_inventory_register_lot(
        p_business_id   => p_business_id,
        p_item_id       => v_item_id,
        p_warehouse_id  => p_warehouse_id,
        p_quantity      => v_qty,
        p_lot_number    => v_lot_number,
        p_expiry_date   => v_expiry,
        p_cost_per_unit => v_cost,
        p_source_type   => 'direct_receipt',
        p_source_id     => v_header.id,
        p_notes         => v_line_notes
      );
    end if;
  end loop;

  update public.direct_receipts
     set total = v_total
   where id = v_header.id
  returning * into v_header;

  return v_header;
end;
$$;

-- Comentario actualizado.
comment on function public.fn_inventory_direct_receipt(uuid, uuid, jsonb, uuid, text) is
  'Recepción directa de mercancía sin OC. Crea header + items + movimientos. '
  'Para items con tracks_lots=true, cada elemento de p_items puede incluir '
  '`lot_number` y `expiry_date` (opcionales): si se proveen o si tracks_lots '
  'está activo, se registra el lote en inventory_lots de forma atómica.';

-- ---------------------------------------------------------------------------
-- 8. MODIFICAR fn_receive_purchase_order_partial: análogo a la recepción
--    directa. Cada línea recibida puede traer lot_number/expiry_date.
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
  v_lot_number text;
  v_expiry date;
  v_line public.purchase_order_items;
  v_pending numeric;
  v_posted_lines integer := 0;
  v_outstanding integer;
  v_final_status text;
  v_tracks_lots boolean;
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

  if coalesce(v_role, '') not in ('owner','admin','manager') then
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

  for v_row in select * from jsonb_array_elements(p_line_items)
  loop
    v_poi_id     := nullif(v_row->>'poi_id','')::uuid;
    v_qty        := nullif(v_row->>'quantity','')::numeric;
    v_lot_number := nullif(trim(coalesce(v_row->>'lot_number','')), '');
    v_expiry     := nullif(v_row->>'expiry_date','')::date;

    if v_poi_id is null or v_qty is null then
      raise exception 'INVALID_LINE_ROW';
    end if;
    if v_qty <= 0 then
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
      continue;
    end if;

    if v_qty > v_pending then
      raise exception 'QUANTITY_EXCEEDS_PENDING: line=% requested=% pending=%',
        v_poi_id, v_qty, v_pending;
    end if;

    if v_line.inventory_item_id is not null then
      select coalesce(tracks_lots, false) into v_tracks_lots
        from public.inventory_items
        where id = v_line.inventory_item_id
          and business_id = v_order.business_id;

      if v_tracks_lots is null then
        raise exception 'PURCHASE_ORDER_ITEM_INVALID';
      end if;

      insert into public.inventory_movements (
        business_id, warehouse_id, item_id, movement_type, quantity,
        cost_per_unit, reference_id, reference_type, notes, created_by
      )
      values (
        v_order.business_id, v_order.warehouse_id, v_line.inventory_item_id,
        'purchase', v_qty, v_line.unit_cost, p_order_id, 'purchase_order',
        coalesce(
          nullif(trim(p_notes), ''),
          concat('Recepcion parcial de ', v_order.order_number)
        ),
        v_user_id
      );

      -- Registrar lote si aplica.
      if v_tracks_lots then
        perform public.fn_inventory_register_lot(
          p_business_id   => v_order.business_id,
          p_item_id       => v_line.inventory_item_id,
          p_warehouse_id  => v_order.warehouse_id,
          p_quantity      => v_qty,
          p_lot_number    => v_lot_number,
          p_expiry_date   => v_expiry,
          p_cost_per_unit => v_line.unit_cost,
          p_source_type   => 'purchase_order',
          p_source_id     => p_order_id,
          p_notes         => null
        );
      end if;

      v_posted_lines := v_posted_lines + 1;
    end if;

    update public.purchase_order_items
       set quantity_received = coalesce(quantity_received, 0) + v_qty
     where id = v_poi_id;
  end loop;

  select count(*)
    into v_outstanding
    from public.purchase_order_items poi
    where poi.purchase_order_id = p_order_id
      and coalesce(poi.quantity_ordered, 0) > coalesce(poi.quantity_received, 0);

  if v_outstanding = 0 then
    v_final_status := 'received';
  else
    if exists (
      select 1 from public.purchase_order_items poi
      where poi.purchase_order_id = p_order_id
        and coalesce(poi.quantity_received, 0) > 0
    ) then
      v_final_status := 'partial';
    else
      v_final_status := v_order.status;
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

commit;
