-- =============================================================================
-- Sprint 4 Inventario — Recepción directa (sin OC formal).
--
-- PROBLEMA:
--   Hoy las únicas formas de subir stock son: recibir contra OC, ajuste
--   con razón, o recepción de transferencia. Para casos cotidianos
--   pequeños (compra ad-hoc en el supermercado, inventario inicial al
--   abrir un negocio, donaciones de mercancía, devoluciones de cliente
--   que entran a stock) crear una OC formal es overkill.
--
-- ENTREGA:
--   - Tabla `direct_receipts` (header) y `direct_receipt_items` (líneas).
--   - RPC `fn_inventory_direct_receipt(business_id, warehouse_id, items,
--     supplier_id?, notes?)` que crea ambos atómicamente y dispara los
--     movimientos de inventario tipo 'purchase' usando la pipeline
--     estándar `fn_inventory_record_movement`.
--   - Helper `fn_next_direct_receipt_number(business_id)` para generar
--     número correlativo `RD-000001`, `RD-000002`, etc.
--   - RPC `fn_inventory_direct_receipt_cancel` que revierte la recepción
--     (registra ajuste negativo en la bodega) — útil cuando se digita mal.
--   - Vista `v_direct_receipts_log` para reportes y la lista UI.
--   - RLS: lectura/escritura solo por usuarios con rol owner/admin/manager
--     en el business correspondiente.
--
-- IDEMPOTENTE / BACKWARDS-COMPATIBLE:
--   - Tablas nuevas con IF NOT EXISTS.
--   - RPCs con CREATE OR REPLACE.
--   - Reutiliza `fn_inventory_record_movement` para que los triggers de
--     stock se disparen de forma consistente.
-- =============================================================================

begin;

-- ---------------------------------------------------------------------------
-- 1. Tablas
-- ---------------------------------------------------------------------------

create table if not exists public.direct_receipts (
  id              uuid not null default gen_random_uuid() primary key,
  business_id     uuid not null references public.businesses(id) on delete cascade,
  warehouse_id    uuid not null references public.warehouses(id),
  supplier_id     uuid references public.suppliers(id),
  receipt_number  text not null,
  status          text not null default 'received'
                    check (status in ('received','cancelled')),
  total           numeric(14,4) not null default 0,
  notes           text,
  created_by      uuid references auth.users(id),
  created_at      timestamptz not null default now(),
  cancelled_by    uuid references auth.users(id),
  cancelled_at    timestamptz,
  cancel_reason   text,
  unique (business_id, receipt_number)
);

create index if not exists idx_direct_receipts_business_created
  on public.direct_receipts (business_id, created_at desc);

create index if not exists idx_direct_receipts_supplier
  on public.direct_receipts (supplier_id);

alter table public.direct_receipts enable row level security;

drop policy if exists "dr_select" on public.direct_receipts;
create policy "dr_select" on public.direct_receipts
  for select to authenticated
  using (public.user_has_business_access(auth.uid(), business_id));

drop policy if exists "dr_write" on public.direct_receipts;
create policy "dr_write" on public.direct_receipts
  to authenticated
  using (
    public.user_business_role(auth.uid(), business_id)
      = any (array['owner','admin','manager'])
  )
  with check (
    public.user_business_role(auth.uid(), business_id)
      = any (array['owner','admin','manager'])
  );

create table if not exists public.direct_receipt_items (
  id                   uuid not null default gen_random_uuid() primary key,
  direct_receipt_id    uuid not null references public.direct_receipts(id) on delete cascade,
  item_id              uuid not null references public.inventory_items(id),
  quantity             numeric(14,4) not null check (quantity > 0),
  unit_cost            numeric(14,4),
  line_total           numeric(14,4)
                         generated always as (quantity * coalesce(unit_cost, 0)) stored,
  notes                text
);

create index if not exists idx_direct_receipt_items_parent
  on public.direct_receipt_items (direct_receipt_id);

alter table public.direct_receipt_items enable row level security;

drop policy if exists "dri_select" on public.direct_receipt_items;
create policy "dri_select" on public.direct_receipt_items
  for select to authenticated
  using (
    exists (
      select 1 from public.direct_receipts dr
      where dr.id = direct_receipt_items.direct_receipt_id
        and public.user_has_business_access(auth.uid(), dr.business_id)
    )
  );

drop policy if exists "dri_write" on public.direct_receipt_items;
create policy "dri_write" on public.direct_receipt_items
  to authenticated
  using (
    exists (
      select 1 from public.direct_receipts dr
      where dr.id = direct_receipt_items.direct_receipt_id
        and public.user_business_role(auth.uid(), dr.business_id)
              = any (array['owner','admin','manager'])
    )
  )
  with check (
    exists (
      select 1 from public.direct_receipts dr
      where dr.id = direct_receipt_items.direct_receipt_id
        and public.user_business_role(auth.uid(), dr.business_id)
              = any (array['owner','admin','manager'])
    )
  );

-- ---------------------------------------------------------------------------
-- 2. Helper: número correlativo `RD-XXXXXX` por business.
-- ---------------------------------------------------------------------------

create or replace function public.fn_next_direct_receipt_number(
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
    nullif(regexp_replace(receipt_number, '\D', '', 'g'), '')::int
  ), 0) + 1
  into v_next
  from public.direct_receipts
  where business_id = p_business_id
    and receipt_number ~ '^RD-\d+$';

  return 'RD-' || lpad(v_next::text, 6, '0');
end;
$$;

grant execute on function public.fn_next_direct_receipt_number(uuid) to authenticated;

-- ---------------------------------------------------------------------------
-- 3. RPC: fn_inventory_direct_receipt
--
--    p_items: jsonb array `[{"item_id": uuid, "quantity": num,
--                            "unit_cost": num | null, "notes": text | null}]`
--    p_supplier_id: opcional (puede ser proveedor casual / sin formalizar).
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

  -- Warehouse pertenece al business y está activo.
  if not exists (
    select 1 from public.warehouses
    where id = p_warehouse_id
      and business_id = p_business_id
      and coalesce(is_active, true)
  ) then
    raise exception 'WAREHOUSE_NOT_FOUND_OR_INACTIVE';
  end if;

  -- Si hay supplier, validar que pertenezca al business.
  if p_supplier_id is not null then
    if not exists (
      select 1 from public.suppliers
      where id = p_supplier_id and business_id = p_business_id
    ) then
      raise exception 'SUPPLIER_NOT_FOUND';
    end if;
  end if;

  -- Crear header con total temporal = 0; lo actualizamos al final.
  insert into public.direct_receipts (
    business_id,
    warehouse_id,
    supplier_id,
    receipt_number,
    status,
    total,
    notes,
    created_by
  )
  values (
    p_business_id,
    p_warehouse_id,
    p_supplier_id,
    public.fn_next_direct_receipt_number(p_business_id),
    'received',
    0,
    p_notes,
    auth.uid()
  )
  returning * into v_header;

  -- Por cada item: validar + crear detalle + movimiento de inventario.
  for v_row in select * from jsonb_array_elements(p_items)
  loop
    v_item_id   := (v_row->>'item_id')::uuid;
    v_qty       := (v_row->>'quantity')::numeric;
    v_cost      := nullif(v_row->>'unit_cost','')::numeric;
    v_line_notes:= nullif(trim(coalesce(v_row->>'notes','')), '');

    if v_item_id is null or v_qty is null or v_qty <= 0 then
      raise exception 'INVALID_ITEM_ROW';
    end if;

    if not exists (
      select 1 from public.inventory_items ii
      where ii.id = v_item_id and ii.business_id = p_business_id
    ) then
      raise exception 'ITEM_NOT_IN_BUSINESS: %', v_item_id;
    end if;

    insert into public.direct_receipt_items (
      direct_receipt_id,
      item_id,
      quantity,
      unit_cost,
      notes
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
  end loop;

  update public.direct_receipts
     set total = v_total
   where id = v_header.id
  returning * into v_header;

  return v_header;
end;
$$;

grant execute on function public.fn_inventory_direct_receipt(uuid, uuid, jsonb, uuid, text)
  to authenticated;

comment on function public.fn_inventory_direct_receipt(uuid, uuid, jsonb, uuid, text) is
  'Recepción directa de mercancía sin OC formal. Crea header + items + '
  'movimientos de inventario tipo purchase (atómico). Acepta supplier '
  'opcional. Retorna el header con número correlativo y total calculado.';

-- ---------------------------------------------------------------------------
-- 4. RPC: fn_inventory_direct_receipt_cancel
--
--    Revierte una recepción: registra ajustes negativos en la bodega
--    destino por la cantidad recibida en cada línea. NO borra el header
--    (queda con status='cancelled' para auditoría). Solo permitido si
--    todavía no se cancela y si las cantidades reversibles existen.
-- ---------------------------------------------------------------------------

create or replace function public.fn_inventory_direct_receipt_cancel(
  p_receipt_id uuid,
  p_reason text default null
) returns public.direct_receipts
language plpgsql
security definer
set search_path = public
as $$
declare
  v_role text;
  v_header public.direct_receipts;
  v_line record;
begin
  if p_receipt_id is null then
    raise exception 'MISSING_REQUIRED_PARAMS';
  end if;

  select * into v_header
    from public.direct_receipts
    where id = p_receipt_id
    for update;

  if not found then
    raise exception 'RECEIPT_NOT_FOUND';
  end if;
  if v_header.status <> 'received' then
    raise exception 'RECEIPT_NOT_CANCELLABLE: status=%', v_header.status;
  end if;

  v_role := public.user_business_role(auth.uid(), v_header.business_id);
  if v_role not in ('owner','admin','manager') then
    raise exception 'INSUFFICIENT_ROLE';
  end if;

  for v_line in
    select item_id, quantity, unit_cost
      from public.direct_receipt_items
     where direct_receipt_id = v_header.id
  loop
    perform public.fn_inventory_record_movement(
      p_business_id    => v_header.business_id,
      p_warehouse_id   => v_header.warehouse_id,
      p_item_id        => v_line.item_id,
      p_movement_type  => 'adjustment'::public.movement_type,
      p_quantity       => -v_line.quantity,
      p_cost_per_unit  => v_line.unit_cost,
      p_reference_id   => v_header.id,
      p_reference_type => 'direct_receipt_cancel',
      p_notes          => coalesce(
        p_reason,
        concat('Cancelación de recepción directa ', v_header.receipt_number)
      )
    );
  end loop;

  -- Marcar movimientos generados como ajuste por cancelación.
  update public.inventory_movements
     set reason_code = 'correction'
   where reference_id = v_header.id
     and reference_type = 'direct_receipt_cancel'
     and reason_code is null;

  update public.direct_receipts
     set status        = 'cancelled',
         cancelled_at  = now(),
         cancelled_by  = auth.uid(),
         cancel_reason = p_reason
   where id = v_header.id
  returning * into v_header;

  return v_header;
end;
$$;

grant execute on function public.fn_inventory_direct_receipt_cancel(uuid, text)
  to authenticated;

comment on function public.fn_inventory_direct_receipt_cancel(uuid, text) is
  'Cancela una recepción directa: registra ajustes negativos por cada línea '
  'en la bodega y marca el header como cancelled. NO borra el header — queda '
  'para auditoría.';

-- ---------------------------------------------------------------------------
-- 5. Vista de log para reportes y listado en UI.
-- ---------------------------------------------------------------------------

drop view if exists public.v_direct_receipts_log;

create or replace view public.v_direct_receipts_log as
select
  dr.id              as receipt_id,
  dr.business_id,
  dr.warehouse_id,
  w.name             as warehouse_name,
  dr.supplier_id,
  s.name             as supplier_name,
  dr.receipt_number,
  dr.status,
  dr.total,
  dr.notes,
  dr.cancel_reason,
  dr.created_by,
  pc.full_name       as created_by_name,
  dr.cancelled_by,
  pcx.full_name      as cancelled_by_name,
  dr.created_at,
  dr.cancelled_at,
  (select count(*) from public.direct_receipt_items dri where dri.direct_receipt_id = dr.id)
                      as item_count,
  (select coalesce(sum(dri.quantity), 0)
     from public.direct_receipt_items dri where dri.direct_receipt_id = dr.id)
                      as total_quantity
from public.direct_receipts dr
left join public.warehouses w   on w.id  = dr.warehouse_id
left join public.suppliers  s   on s.id  = dr.supplier_id
left join public.profiles   pc  on pc.id = dr.created_by
left join public.profiles   pcx on pcx.id = dr.cancelled_by;

comment on view public.v_direct_receipts_log is
  'Log de recepciones directas (sin OC). Headers con totales agregados y '
  'nombres legibles de bodega, proveedor y usuarios. Consumido por la vista '
  '"Recepciones" del módulo Inventario.';

commit;
