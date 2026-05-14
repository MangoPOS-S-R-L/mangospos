-- =============================================================================
-- Sprint 2 Inventario — Transferencias inter-sucursal (cross-business).
--
-- PROBLEMA:
--   Hoy `fn_inventory_transfer_send` valida que ambas bodegas (from/to)
--   pertenezcan al MISMO `business_id`. Por lo tanto es imposible mover
--   stock desde un almacén principal (Business A) hacia una sucursal
--   (Business B) cuando A y B son `businesses` distintos vinculados al
--   mismo dueño via `user_businesses`.
--
-- DECISIÓN DE DISEÑO:
--   Unificamos el modelo: una transferencia siempre tiene `from_business_id`
--   y `to_business_id`. Cuando son iguales, es intra-sucursal (caso actual).
--   Cuando difieren, es inter-sucursal. La columna legacy `business_id`
--   se conserva como alias del source (`= from_business_id`) para no
--   romper consumidores existentes.
--
--   Items: `inventory_items` es per-business. En cross-business, el item del
--   payload pertenece al source. Al recibir, se busca por SKU en target;
--   si no existe, se auto-crea copiando `name`/`unit`/`cost`. El stock se
--   incrementa en el item resuelto del target, que queda registrado en
--   `stock_transfer_items.target_item_id`.
--
--   Movimientos: cada `inventory_movements.business_id` queda scopeado al
--   business donde realmente ocurre (source para out/in_transit, target
--   para in al recibir). Una transferencia cross-business genera 4
--   movimientos en total + ajuste de merma si aplica.
--
-- IDEMPOTENTE / BACKWARDS-COMPATIBLE:
--   - Agrega columnas nullables, hace backfill, luego NOT NULL.
--   - Recrea RPCs preservando la firma original (parámetro nuevo con default).
--   - Mantiene `business_id` como alias del source.
--   - Una transferencia intra-business sigue funcionando exactamente igual.
-- =============================================================================

begin;

-- ---------------------------------------------------------------------------
-- 1. Schema: agregar from_business_id / to_business_id / target_item_id.
--    Idempotente: usa `IF NOT EXISTS` y backfill defensivo.
-- ---------------------------------------------------------------------------

alter table public.stock_transfers
  add column if not exists from_business_id uuid references public.businesses(id),
  add column if not exists to_business_id   uuid references public.businesses(id);

-- Backfill: para transfers existentes, source = target = business_id legacy.
update public.stock_transfers
   set from_business_id = business_id
 where from_business_id is null;

update public.stock_transfers
   set to_business_id = business_id
 where to_business_id is null;

-- Hacer NOT NULL una vez backfilled. Idempotente: solo aplica si todavía es nullable.
do $$
begin
  if exists (
    select 1
    from information_schema.columns
    where table_schema = 'public'
      and table_name = 'stock_transfers'
      and column_name = 'from_business_id'
      and is_nullable = 'YES'
  ) then
    alter table public.stock_transfers
      alter column from_business_id set not null;
  end if;

  if exists (
    select 1
    from information_schema.columns
    where table_schema = 'public'
      and table_name = 'stock_transfers'
      and column_name = 'to_business_id'
      and is_nullable = 'YES'
  ) then
    alter table public.stock_transfers
      alter column to_business_id set not null;
  end if;
end $$;

create index if not exists idx_stock_transfers_to_business
  on public.stock_transfers (to_business_id, status, sent_at desc);

-- Detalle: target_item_id (item resuelto/creado en target business al recibir).
alter table public.stock_transfer_items
  add column if not exists target_item_id uuid references public.inventory_items(id);

-- ---------------------------------------------------------------------------
-- 2. RLS: en cross-business, el receiver (target) también necesita poder ver
--    y actualizar la transferencia. Actualizamos las políticas para que
--    cualquier usuario con acceso a from_business_id O to_business_id pueda
--    leer; y cualquier usuario con rol owner/admin/manager en al menos uno
--    de los dos pueda escribir. El control fino lo enforce el RPC.
-- ---------------------------------------------------------------------------

drop policy if exists "st_select" on public.stock_transfers;
create policy "st_select" on public.stock_transfers
  for select to authenticated
  using (
       public.user_has_business_access(auth.uid(), from_business_id)
    or public.user_has_business_access(auth.uid(), to_business_id)
  );

drop policy if exists "st_write" on public.stock_transfers;
create policy "st_write" on public.stock_transfers
  to authenticated
  using (
       public.user_business_role(auth.uid(), from_business_id)
         = any (array['owner','admin','manager'])
    or public.user_business_role(auth.uid(), to_business_id)
         = any (array['owner','admin','manager'])
  )
  with check (
       public.user_business_role(auth.uid(), from_business_id)
         = any (array['owner','admin','manager'])
    or public.user_business_role(auth.uid(), to_business_id)
         = any (array['owner','admin','manager'])
  );

drop policy if exists "sti_select" on public.stock_transfer_items;
create policy "sti_select" on public.stock_transfer_items
  for select to authenticated
  using (
    exists (
      select 1 from public.stock_transfers t
      where t.id = stock_transfer_items.stock_transfer_id
        and (
             public.user_has_business_access(auth.uid(), t.from_business_id)
          or public.user_has_business_access(auth.uid(), t.to_business_id)
        )
    )
  );

drop policy if exists "sti_write" on public.stock_transfer_items;
create policy "sti_write" on public.stock_transfer_items
  to authenticated
  using (
    exists (
      select 1 from public.stock_transfers t
      where t.id = stock_transfer_items.stock_transfer_id
        and (
             public.user_business_role(auth.uid(), t.from_business_id)
               = any (array['owner','admin','manager'])
          or public.user_business_role(auth.uid(), t.to_business_id)
               = any (array['owner','admin','manager'])
        )
    )
  )
  with check (
    exists (
      select 1 from public.stock_transfers t
      where t.id = stock_transfer_items.stock_transfer_id
        and (
             public.user_business_role(auth.uid(), t.from_business_id)
               = any (array['owner','admin','manager'])
          or public.user_business_role(auth.uid(), t.to_business_id)
               = any (array['owner','admin','manager'])
        )
    )
  );

-- ---------------------------------------------------------------------------
-- 3. Helper: resolver o crear el item equivalente en otro business.
--    Busca primero por SKU (si no es null/vacío), después por nombre exacto.
--    Si no encuentra, crea el item en el target copiando name/unit/cost.
--    Se usa al recibir una transferencia inter-sucursal.
-- ---------------------------------------------------------------------------

create or replace function public.fn_inventory_resolve_item_for_business(
  p_target_business_id uuid,
  p_source_item_id uuid
) returns uuid
language plpgsql
security definer
set search_path = public
as $$
declare
  v_src record;
  v_target_id uuid;
  v_sku_norm text;
begin
  if p_target_business_id is null or p_source_item_id is null then
    raise exception 'MISSING_REQUIRED_PARAMS';
  end if;

  select id, business_id, sku, name, description, unit, cost,
         min_stock, max_stock
    into v_src
    from public.inventory_items
   where id = p_source_item_id;

  if v_src.id is null then
    raise exception 'SOURCE_ITEM_NOT_FOUND';
  end if;

  -- Si por algún motivo el item ya es del target business, devolver ese mismo id.
  if v_src.business_id = p_target_business_id then
    return v_src.id;
  end if;

  v_sku_norm := nullif(btrim(v_src.sku), '');

  -- 1) Match por SKU (case-insensitive si está presente).
  if v_sku_norm is not null then
    select id into v_target_id
      from public.inventory_items
     where business_id = p_target_business_id
       and lower(btrim(sku)) = lower(v_sku_norm)
     limit 1;
  end if;

  -- 2) Fallback: match por nombre exacto (case-insensitive trimmed).
  if v_target_id is null then
    select id into v_target_id
      from public.inventory_items
     where business_id = p_target_business_id
       and lower(btrim(name)) = lower(btrim(v_src.name))
     limit 1;
  end if;

  -- 3) Crear si no existe. Copia los campos descriptivos del source.
  if v_target_id is null then
    insert into public.inventory_items (
      business_id, sku, name, description, unit, cost, min_stock, max_stock,
      is_active
    )
    values (
      p_target_business_id,
      v_src.sku,
      v_src.name,
      v_src.description,
      coalesce(v_src.unit, 'unidad'),
      coalesce(v_src.cost, 0),
      coalesce(v_src.min_stock, 0),
      v_src.max_stock,
      true
    )
    returning id into v_target_id;
  end if;

  return v_target_id;
end;
$$;

grant execute on function public.fn_inventory_resolve_item_for_business(uuid, uuid)
  to authenticated;

comment on function public.fn_inventory_resolve_item_for_business(uuid, uuid) is
  'Devuelve el id del inventory_item equivalente en otro business. Match por '
  'SKU (case-insensitive), fallback a nombre exacto, fallback a auto-crear '
  'copiando atributos descriptivos. Idempotente.';

-- ---------------------------------------------------------------------------
-- 4. RPC: fn_inventory_transfer_send con soporte cross-business.
--    Firma extendida: nuevo parámetro p_target_business_id (default NULL =
--    intra-business, comportamiento idéntico al anterior).
-- ---------------------------------------------------------------------------

drop function if exists public.fn_inventory_transfer_send(uuid, uuid, uuid, jsonb, text);

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

  v_target_bid := coalesce(p_target_business_id, p_business_id);
  v_is_cross := v_target_bid <> p_business_id;

  -- Rol en source (sender) es obligatorio.
  v_role_src := public.user_business_role(auth.uid(), p_business_id);
  if v_role_src not in ('owner','admin','manager') then
    raise exception 'INSUFFICIENT_ROLE_SOURCE';
  end if;

  -- Para cross-business: el usuario también debe tener rol en target.
  -- Esto evita que un usuario envíe stock a un negocio donde no participa.
  if v_is_cross then
    v_role_tgt := public.user_business_role(auth.uid(), v_target_bid);
    if v_role_tgt not in ('owner','admin','manager') then
      raise exception 'INSUFFICIENT_ROLE_TARGET';
    end if;
  end if;

  -- Validar warehouses: source warehouse pertenece a source business,
  -- target warehouse pertenece a target business.
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

  -- IN_TRANSIT vive en el SOURCE business: ahí queda la mercancía hasta
  -- que el destino confirme la recepción.
  v_in_transit_id := public.ensure_in_transit_warehouse(p_business_id);

  -- Header. business_id legacy = from_business_id (source).
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
    'sent',
    p_notes,
    auth.uid()
  )
  returning * into v_transfer;

  -- Detalle + movimientos atómicos. Por cada item:
  --   1) Validar que el item pertenece al SOURCE business
  --   2) Insertar detalle
  --   3) transfer_out source warehouse (business=source)
  --   4) transfer_in IN_TRANSIT source (business=source)
  -- target_item_id se resuelve al recibir (no acá: si nunca se recibe,
  -- no queremos polutar inventory_items con auto-creaciones).
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

grant execute on function public.fn_inventory_transfer_send(uuid, uuid, uuid, jsonb, text, uuid)
  to authenticated;

comment on function public.fn_inventory_transfer_send(uuid, uuid, uuid, jsonb, text, uuid) is
  'Envía mercancía desde bodega origen del source business hacia IN_TRANSIT '
  'del mismo source. Si p_target_business_id es distinto de p_business_id, '
  'la transferencia es inter-sucursal: target_warehouse debe pertenecer al '
  'target business y el usuario debe tener rol owner/admin/manager en ambos.';

-- ---------------------------------------------------------------------------
-- 5. RPC: fn_inventory_transfer_receive con soporte cross-business.
--    Misma firma. Internamente:
--      - Determina source/target desde el header.
--      - Para cada item: resuelve target_item_id en target business
--        (auto-crea si no existe), guarda en stock_transfer_items.target_item_id.
--      - Mueve de IN_TRANSIT(source) hacia to_warehouse(target) con
--        movimientos en el business correspondiente.
--      - Variance: ajuste sobre IN_TRANSIT(source).
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
  v_transfer public.stock_transfers;
  v_is_cross boolean;
  v_role_tgt text;
  v_in_transit_id uuid;
  v_row jsonb;
  v_ti_id uuid;
  v_qty_received numeric;
  v_ti public.stock_transfer_items;
  v_variance numeric;
  v_target_item_id uuid;
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

  v_is_cross := v_transfer.from_business_id <> v_transfer.to_business_id;

  -- Recepción la hace alguien con rol owner/admin/manager en el target business.
  v_role_tgt := public.user_business_role(auth.uid(), v_transfer.to_business_id);
  if v_role_tgt not in ('owner','admin','manager') then
    raise exception 'INSUFFICIENT_ROLE_TARGET';
  end if;

  -- IN_TRANSIT siempre vive en el source business.
  v_in_transit_id := public.ensure_in_transit_warehouse(v_transfer.from_business_id);

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

    -- Resolver el item del target. En intra-business es el mismo source.
    if v_is_cross then
      v_target_item_id := public.fn_inventory_resolve_item_for_business(
        v_transfer.to_business_id, v_ti.item_id
      );
    else
      v_target_item_id := v_ti.item_id;
    end if;

    update public.stock_transfer_items
    set quantity_received = v_qty_received,
        target_item_id    = v_target_item_id,
        variance_reason   = case
          when v_qty_received < v_ti.quantity_sent then 'in_transit_loss'
          else null
        end
    where id = v_ti.id;

    v_variance := v_ti.quantity_sent - v_qty_received;

    if v_qty_received > 0 then
      -- Salida desde IN_TRANSIT del source (mov en source business).
      perform public.fn_inventory_record_movement(
        p_business_id    => v_transfer.from_business_id,
        p_warehouse_id   => v_in_transit_id,
        p_item_id        => v_ti.item_id,
        p_movement_type  => 'transfer_out'::public.movement_type,
        p_quantity       => v_qty_received,
        p_cost_per_unit  => v_ti.cost_per_unit,
        p_reference_id   => v_transfer.id,
        p_reference_type => 'stock_transfer',
        p_notes          => null
      );

      -- Entrada al warehouse destino (mov en target business, target_item_id).
      perform public.fn_inventory_record_movement(
        p_business_id    => v_transfer.to_business_id,
        p_warehouse_id   => v_transfer.to_warehouse_id,
        p_item_id        => v_target_item_id,
        p_movement_type  => 'transfer_in'::public.movement_type,
        p_quantity       => v_qty_received,
        p_cost_per_unit  => v_ti.cost_per_unit,
        p_reference_id   => v_transfer.id,
        p_reference_type => 'stock_transfer',
        p_notes          => null
      );
    end if;

    -- Merma: ajuste negativo sobre IN_TRANSIT del source. Usa item_id source.
    if v_variance > 0 then
      perform public.fn_inventory_record_movement(
        p_business_id    => v_transfer.from_business_id,
        p_warehouse_id   => v_in_transit_id,
        p_item_id        => v_ti.item_id,
        p_movement_type  => 'adjustment'::public.movement_type,
        p_quantity       => -v_variance,
        p_cost_per_unit  => v_ti.cost_per_unit,
        p_reference_id   => v_transfer.id,
        p_reference_type => 'stock_transfer_variance',
        p_notes          => coalesce(p_variance_notes, 'Faltante en tránsito')
      );

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
  'Recibe una transferencia en status=sent. Resuelve target_item_id en el '
  'target business (auto-creando por SKU/nombre si no existe) y mueve el '
  'stock desde IN_TRANSIT(source) hacia el warehouse destino. Soporta '
  'transferencias intra e inter-sucursal indistintamente.';

-- ---------------------------------------------------------------------------
-- 6. RPC: fn_inventory_transfer_cancel con soporte cross-business.
--    Solo el SOURCE (sender) puede cancelar. Devuelve mercancía a la
--    bodega origen del source business.
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

  -- Cancela solo el source (quien envió). Receiver puede rechazar via
  -- "receive con quantity 0" (variance completa) si quisiéramos exponerlo
  -- como opción, pero por ahora la cancelación es prerrogativa del sender.
  v_role := public.user_business_role(auth.uid(), v_transfer.from_business_id);
  if v_role not in ('owner','admin','manager') then
    raise exception 'INSUFFICIENT_ROLE_SOURCE';
  end if;

  v_in_transit_id := public.ensure_in_transit_warehouse(v_transfer.from_business_id);

  for v_ti in
    select * from public.stock_transfer_items where stock_transfer_id = v_transfer.id
  loop
    perform public.fn_inventory_record_movement(
      p_business_id    => v_transfer.from_business_id,
      p_warehouse_id   => v_in_transit_id,
      p_item_id        => v_ti.item_id,
      p_movement_type  => 'transfer_out'::public.movement_type,
      p_quantity       => v_ti.quantity_sent,
      p_cost_per_unit  => v_ti.cost_per_unit,
      p_reference_id   => v_transfer.id,
      p_reference_type => 'stock_transfer_cancel',
      p_notes          => p_reason
    );
    perform public.fn_inventory_record_movement(
      p_business_id    => v_transfer.from_business_id,
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
-- 7. Vista v_inventory_transfers_log con contexto cross-business.
--    Agrega from_business_id, to_business_id, nombres y is_cross_business
--    para que reportes y UI puedan distinguir el tipo de transferencia.
-- ---------------------------------------------------------------------------

drop view if exists public.v_inventory_transfers_log;

create or replace view public.v_inventory_transfers_log as
select
  st.id                  as transfer_id,
  st.business_id,
  st.from_business_id,
  bf.business_name       as from_business_name,
  st.to_business_id,
  bt.business_name       as to_business_name,
  (st.from_business_id <> st.to_business_id) as is_cross_business,
  st.transfer_number,
  st.status,
  st.from_warehouse_id,
  wf.name                as from_warehouse_name,
  st.to_warehouse_id,
  wt.name                as to_warehouse_name,
  st.sent_at,
  st.received_at,
  st.cancelled_at,
  st.notes,
  st.created_by,
  pc.full_name           as created_by_name,
  st.received_by,
  pr.full_name           as received_by_name,
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
left join public.businesses bf on bf.id = st.from_business_id
left join public.businesses bt on bt.id = st.to_business_id
left join public.profiles   pc on pc.id = st.created_by
left join public.profiles   pr on pr.id = st.received_by;

comment on view public.v_inventory_transfers_log is
  'Log de transferencias entre bodegas con contexto cross-business. '
  'Incluye nombres de business origen/destino y flag is_cross_business.';

commit;
