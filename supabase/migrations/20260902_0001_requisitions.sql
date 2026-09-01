-- =============================================================================
-- F2 — Requisición de mercancía: la cocina pide, el almacén despacha.
--
-- POR QUÉ NO ALCANZA CON LA TRANSFERENCIA QUE YA EXISTE:
--   La transferencia la inicia quien ENVÍA. La requisición la inicia quien
--   NECESITA. Es la diferencia entre "Santiago decide mandarle queso a la
--   cocina" y "la cocina pide queso y Santiago despacha lo que hay". El
--   documento, la autorización y el faltante pendiente sólo existen en el
--   segundo caso.
--
-- FLUJO:
--   pending → dispatched   (se despachó todo lo pedido)
--           → partial      (se despachó menos; el faltante queda a la vista)
--           → received     (la cocina confirma lo que llegó)
--           → cancelled    (desde pending)
--
--   El stock se mueve en el DESPACHO, no en la solicitud. Por debajo se
--   reusa `fn_inventory_transfer_send`: la requisición es el documento y la
--   autorización, la transferencia es el asiento. Sin eso habría dos motores
--   de movimientos que se desincronizarían al primer cambio.
--
-- EL CANDADO DEL RESPONSABLE:
--   Despacha el responsable de la bodega de origen (`keeper_employee_id`),
--   o alguien con rol owner/admin. Vive ACÁ y no en Flutter: si viviera en
--   la app, un cliente viejo lo saltaría. Cuando la bodega no tiene
--   responsable asignado, cualquiera con acceso al negocio puede despachar
--   — no se tranca la operación de los negocios que no usan esto.
--
-- REQUIERE: 20260901_0001 (keeper_employee_id, requires_requisition).
-- IDEMPOTENTE: sí. REVERSIBLE: sí (ver _ROLLBACK).
-- =============================================================================

begin;

-- ---------------------------------------------------------------------------
-- 1. Tablas
-- ---------------------------------------------------------------------------

create table if not exists public.requisitions (
  id                uuid primary key default gen_random_uuid(),
  business_id       uuid not null references public.businesses(id) on delete cascade,
  code              text not null,
  status            text not null default 'pending'
                      check (status in ('pending','partial','dispatched',
                                        'received','cancelled')),
  from_warehouse_id uuid not null references public.warehouses(id),
  to_warehouse_id   uuid not null references public.warehouses(id),
  transfer_id       uuid references public.stock_transfers(id),
  requested_by      uuid references auth.users(id) on delete set null,
  requested_at      timestamptz not null default now(),
  dispatched_by     uuid references auth.users(id) on delete set null,
  dispatched_at     timestamptz,
  received_by       uuid references auth.users(id) on delete set null,
  received_at       timestamptz,
  cancelled_by      uuid references auth.users(id) on delete set null,
  cancelled_at      timestamptz,
  cancel_reason     text,
  notes             text,
  constraint requisitions_code_business_unique unique (business_id, code),
  constraint requisitions_distinct_warehouses
    check (from_warehouse_id <> to_warehouse_id)
);

create index if not exists idx_requisitions_business_status
  on public.requisitions (business_id, status, requested_at desc);
create index if not exists idx_requisitions_from_wh
  on public.requisitions (from_warehouse_id, status);
create index if not exists idx_requisitions_to_wh
  on public.requisitions (to_warehouse_id, status);

create table if not exists public.requisition_lines (
  id              uuid primary key default gen_random_uuid(),
  requisition_id  uuid not null
                    references public.requisitions(id) on delete cascade,
  item_id         uuid not null references public.inventory_items(id),
  requested_qty   numeric(14,4) not null check (requested_qty > 0),
  -- NULL = todavía no se despachó. 0 = se despachó y no había nada, que es
  -- una respuesta distinta de "no lo miré".
  dispatched_qty  numeric(14,4) check (dispatched_qty >= 0),
  received_qty    numeric(14,4) check (received_qty >= 0),
  unit            text not null,
  line_notes      text,
  constraint requisition_lines_unique unique (requisition_id, item_id)
);

create index if not exists idx_requisition_lines_req
  on public.requisition_lines (requisition_id);

comment on table public.requisitions is
  'Pedido de una bodega a otra. La pide quien necesita; el stock se mueve '
  'cuando el almacén despacha, vía fn_inventory_transfer_send. F2.';
comment on column public.requisitions.transfer_id is
  'La transferencia que ejecutó el despacho. La requisición es el documento; '
  'el asiento de inventario sigue siendo uno solo, el de transferencias.';
comment on column public.requisition_lines.dispatched_qty is
  'Lo que el almacén entregó de esta línea. NULL = sin despachar todavía; '
  '0 = se despachó la requisición y de esta línea no había nada. El faltante '
  'es requested_qty - dispatched_qty y queda a la vista para reclamarlo.';

-- ---------------------------------------------------------------------------
-- 2. RLS
-- ---------------------------------------------------------------------------

alter table public.requisitions enable row level security;
alter table public.requisition_lines enable row level security;

drop policy if exists req_select on public.requisitions;
create policy req_select on public.requisitions
  for select to authenticated
  using (public.user_has_business_access(auth.uid(), business_id));

drop policy if exists req_lines_select on public.requisition_lines;
create policy req_lines_select on public.requisition_lines
  for select to authenticated
  using (exists (
    select 1 from public.requisitions r
     where r.id = requisition_id
       and public.user_has_business_access(auth.uid(), r.business_id)
  ));

-- Sin policies de escritura a propósito: todo pasa por los RPC de abajo,
-- que son los que aplican el candado del responsable y mueven el stock.

-- ---------------------------------------------------------------------------
-- 3. ¿Puede esta persona despachar de esta bodega?
-- ---------------------------------------------------------------------------

create or replace function public.fn_can_dispatch_warehouse(
  p_user_id      uuid,
  p_warehouse_id uuid
) returns boolean
language sql
stable
security definer
set search_path to 'public'
as $$
  select
    -- Owner y admin siempre pueden: si el responsable no está, la operación
    -- no se puede trancar.
    coalesce(public.user_business_role(p_user_id, w.business_id), '')
      in ('owner', 'admin')
    -- Bodega sin responsable asignado: cualquiera con acceso al negocio.
    or w.keeper_employee_id is null
    -- O es el responsable.
    or exists (
      select 1 from public.employees e
       where e.id = w.keeper_employee_id
         and e.user_id = p_user_id
    )
  from public.warehouses w
  where w.id = p_warehouse_id;
$$;

comment on function public.fn_can_dispatch_warehouse(uuid, uuid) is
  'Candado del responsable de bodega. Owner y admin siempre pueden; una '
  'bodega sin responsable no restringe a nadie. F2.';

grant execute on function public.fn_can_dispatch_warehouse(uuid, uuid)
  to authenticated, service_role;

-- ---------------------------------------------------------------------------
-- 4. Crear la solicitud
-- ---------------------------------------------------------------------------

create or replace function public.fn_requisition_create(
  p_business_id       uuid,
  p_from_warehouse_id uuid,
  p_to_warehouse_id   uuid,
  p_lines             jsonb,
  p_notes             text default null
) returns public.requisitions
language plpgsql
security definer
set search_path to 'public'
as $$
declare
  v_req public.requisitions;
  v_code text;
  v_seq bigint;
  v_line jsonb;
  v_item_id uuid;
  v_qty numeric;
  v_unit text;
begin
  if p_business_id is null or p_from_warehouse_id is null
     or p_to_warehouse_id is null then
    raise exception 'MISSING_REQUIRED_PARAMS';
  end if;
  if p_from_warehouse_id = p_to_warehouse_id then
    raise exception 'SAME_WAREHOUSE';
  end if;
  if p_lines is null or jsonb_array_length(p_lines) = 0 then
    raise exception 'EMPTY_ITEMS';
  end if;
  if not public.user_has_business_access(auth.uid(), p_business_id) then
    raise exception 'NOT_AUTHORIZED';
  end if;

  -- Las dos bodegas tienen que ser del negocio: un id de otro tenant crearía
  -- un documento cruzado.
  if not exists (select 1 from public.warehouses w
                  where w.id = p_from_warehouse_id
                    and w.business_id = p_business_id)
     or not exists (select 1 from public.warehouses w
                     where w.id = p_to_warehouse_id
                       and w.business_id = p_business_id) then
    raise exception 'WAREHOUSE_NOT_IN_BUSINESS';
  end if;

  -- Numeración: lock propio por negocio, y el cast adentro del max para que
  -- REQ-100000 no pierda contra REQ-99999 comparando como texto.
  perform pg_advisory_xact_lock(
    hashtextextended(p_business_id::text || ':requisition_code', 0));
  select coalesce(
           max(nullif(regexp_replace(code, '\D', '', 'g'), '')::bigint), 0) + 1
    into v_seq
    from public.requisitions
   where business_id = p_business_id;
  v_code := 'REQ-' || lpad(v_seq::text, 5, '0');

  insert into public.requisitions (
    business_id, code, status, from_warehouse_id, to_warehouse_id,
    requested_by, notes
  ) values (
    p_business_id, v_code, 'pending', p_from_warehouse_id, p_to_warehouse_id,
    auth.uid(), nullif(trim(coalesce(p_notes, '')), '')
  ) returning * into v_req;

  for v_line in select * from jsonb_array_elements(p_lines)
  loop
    v_item_id := (v_line->>'item_id')::uuid;
    v_qty     := (v_line->>'requested_qty')::numeric;
    v_unit    := coalesce(nullif(v_line->>'unit', ''), 'unidad');

    if v_item_id is null or v_qty is null or v_qty <= 0 then
      raise exception 'INVALID_ITEM_ROW';
    end if;
    if not exists (select 1 from public.inventory_items ii
                    where ii.id = v_item_id
                      and ii.business_id = p_business_id) then
      raise exception 'ITEM_NOT_IN_BUSINESS: %', v_item_id;
    end if;

    insert into public.requisition_lines (
      requisition_id, item_id, requested_qty, unit, line_notes
    ) values (
      v_req.id, v_item_id, v_qty, v_unit,
      nullif(trim(coalesce(v_line->>'line_notes', '')), '')
    )
    on conflict (requisition_id, item_id) do update
      set requested_qty = excluded.requested_qty,
          unit          = excluded.unit,
          line_notes    = excluded.line_notes;
  end loop;

  return v_req;
end;
$$;

-- ---------------------------------------------------------------------------
-- 5. Despachar (parcial permitido)
-- ---------------------------------------------------------------------------

create or replace function public.fn_requisition_dispatch(
  p_requisition_id uuid,
  p_lines          jsonb,
  p_notes          text default null
) returns public.requisitions
language plpgsql
security definer
set search_path to 'public'
as $$
declare
  v_req public.requisitions;
  v_role text;
  v_line jsonb;
  v_item_id uuid;
  v_qty numeric;
  v_items jsonb := '[]'::jsonb;
  v_transfer public.stock_transfers;
  v_pendientes int;
begin
  if p_requisition_id is null then
    raise exception 'MISSING_REQUIRED_PARAMS';
  end if;

  select * into v_req from public.requisitions where id = p_requisition_id;
  if v_req.id is null then
    raise exception 'REQUISITION_NOT_FOUND';
  end if;
  if v_req.status <> 'pending' then
    raise exception 'INVALID_STATUS_TRANSITION: solo se despacha desde pending (status=%)',
      v_req.status;
  end if;
  if not public.user_has_business_access(auth.uid(), v_req.business_id) then
    raise exception 'NOT_AUTHORIZED';
  end if;

  -- El candado del responsable.
  if not public.fn_can_dispatch_warehouse(auth.uid(), v_req.from_warehouse_id) then
    raise exception 'NOT_WAREHOUSE_KEEPER';
  end if;

  -- Y el rol que ya exige el motor de transferencias. Se comprueba ACÁ para
  -- fallar con un mensaje claro antes de escribir nada, en vez de reventar a
  -- mitad del despacho.
  v_role := public.user_business_role(auth.uid(), v_req.business_id);
  if coalesce(v_role, '') not in ('owner', 'admin', 'manager') then
    raise exception 'INSUFFICIENT_ROLE';
  end if;

  -- Lo despachado, línea por línea. Una línea que no venga en p_lines se
  -- despacha en CERO: el almacén miró la requisición completa y de eso no
  -- había. Distinto de NULL, que era "todavía no se despachó".
  update public.requisition_lines set dispatched_qty = 0
   where requisition_id = v_req.id;

  for v_line in select * from jsonb_array_elements(coalesce(p_lines, '[]'::jsonb))
  loop
    v_item_id := (v_line->>'item_id')::uuid;
    v_qty     := (v_line->>'dispatched_qty')::numeric;
    if v_item_id is null or v_qty is null or v_qty < 0 then
      raise exception 'INVALID_ITEM_ROW';
    end if;

    update public.requisition_lines
       set dispatched_qty = v_qty
     where requisition_id = v_req.id and item_id = v_item_id;
    if not found then
      raise exception 'LINE_NOT_IN_REQUISITION: %', v_item_id;
    end if;

    if v_qty > 0 then
      v_items := v_items || jsonb_build_array(
        jsonb_build_object('item_id', v_item_id, 'quantity', v_qty));
    end if;
  end loop;

  -- El asiento: una transferencia. La requisición no mueve stock por su
  -- cuenta, para que haya UN solo motor de movimientos.
  if jsonb_array_length(v_items) > 0 then
    v_transfer := public.fn_inventory_transfer_send(
      p_business_id       => v_req.business_id,
      p_from_warehouse_id => v_req.from_warehouse_id,
      p_to_warehouse_id   => v_req.to_warehouse_id,
      p_items             => v_items,
      p_notes             => 'Requisición ' || v_req.code ||
                             coalesce(' — ' || nullif(trim(coalesce(p_notes,'')), ''), '')
    );
  end if;

  -- ¿Quedó algo sin despachar?
  select count(*) into v_pendientes
    from public.requisition_lines l
   where l.requisition_id = v_req.id
     and coalesce(l.dispatched_qty, 0) < l.requested_qty;

  update public.requisitions
     set status         = case when v_pendientes > 0 then 'partial'
                               else 'dispatched' end,
         transfer_id    = coalesce(v_transfer.id, transfer_id),
         dispatched_by  = auth.uid(),
         dispatched_at  = now(),
         notes          = coalesce(
                            nullif(trim(coalesce(p_notes, '')), ''), notes)
   where id = v_req.id
   returning * into v_req;

  return v_req;
end;
$$;

-- ---------------------------------------------------------------------------
-- 6. Recibir
-- ---------------------------------------------------------------------------

create or replace function public.fn_requisition_receive(
  p_requisition_id uuid,
  p_lines          jsonb default null,
  p_notes          text default null
) returns public.requisitions
language plpgsql
security definer
set search_path to 'public'
as $$
declare
  v_req public.requisitions;
  v_line jsonb;
  v_item_id uuid;
  v_qty numeric;
  v_received jsonb := '[]'::jsonb;
  v_ti_id uuid;
begin
  if p_requisition_id is null then
    raise exception 'MISSING_REQUIRED_PARAMS';
  end if;

  select * into v_req from public.requisitions where id = p_requisition_id;
  if v_req.id is null then
    raise exception 'REQUISITION_NOT_FOUND';
  end if;
  if v_req.status not in ('dispatched', 'partial') then
    raise exception 'INVALID_STATUS_TRANSITION: solo se recibe lo despachado (status=%)',
      v_req.status;
  end if;
  if not public.user_has_business_access(auth.uid(), v_req.business_id) then
    raise exception 'NOT_AUTHORIZED';
  end if;

  -- Por defecto se recibe lo despachado. `p_lines` sirve para declarar una
  -- diferencia: llegó menos de lo que salió.
  update public.requisition_lines
     set received_qty = coalesce(dispatched_qty, 0)
   where requisition_id = v_req.id;

  for v_line in select * from jsonb_array_elements(coalesce(p_lines, '[]'::jsonb))
  loop
    v_item_id := (v_line->>'item_id')::uuid;
    v_qty     := (v_line->>'received_qty')::numeric;
    if v_item_id is null or v_qty is null or v_qty < 0 then
      raise exception 'INVALID_ITEM_ROW';
    end if;
    update public.requisition_lines
       set received_qty = v_qty
     where requisition_id = v_req.id and item_id = v_item_id;
  end loop;

  -- Cerrar la transferencia con lo realmente recibido: es lo que saca la
  -- mercancía de __IN_TRANSIT__ y la mete en la bodega destino.
  if v_req.transfer_id is not null then
    select coalesce(jsonb_agg(jsonb_build_object(
             'transfer_item_id', sti.id,
             'quantity_received', coalesce(l.received_qty, sti.quantity_sent)
           )), '[]'::jsonb)
      into v_received
      from public.stock_transfer_items sti
      left join public.requisition_lines l
        on l.requisition_id = v_req.id and l.item_id = sti.item_id
     where sti.stock_transfer_id = v_req.transfer_id;

    if jsonb_array_length(v_received) > 0 then
      perform public.fn_inventory_transfer_receive(
        p_transfer_id    => v_req.transfer_id,
        p_received_items => v_received,
        p_variance_notes => nullif(trim(coalesce(p_notes, '')), '')
      );
    end if;
  end if;

  update public.requisitions
     set status      = 'received',
         received_by = auth.uid(),
         received_at = now()
   where id = v_req.id
   returning * into v_req;

  return v_req;
end;
$$;

-- ---------------------------------------------------------------------------
-- 7. Cancelar (solo antes de despachar)
-- ---------------------------------------------------------------------------

create or replace function public.fn_requisition_cancel(
  p_requisition_id uuid,
  p_reason         text default null
) returns public.requisitions
language plpgsql
security definer
set search_path to 'public'
as $$
declare
  v_req public.requisitions;
begin
  select * into v_req from public.requisitions where id = p_requisition_id;
  if v_req.id is null then
    raise exception 'REQUISITION_NOT_FOUND';
  end if;
  -- Después del despacho ya hay mercancía moviéndose: cancelar sería otra
  -- cosa (una devolución), no una cancelación.
  if v_req.status <> 'pending' then
    raise exception 'INVALID_STATUS_TRANSITION: solo se cancela lo pendiente (status=%)',
      v_req.status;
  end if;
  if not public.user_has_business_access(auth.uid(), v_req.business_id) then
    raise exception 'NOT_AUTHORIZED';
  end if;

  update public.requisitions
     set status        = 'cancelled',
         cancelled_by  = auth.uid(),
         cancelled_at  = now(),
         cancel_reason = nullif(trim(coalesce(p_reason, '')), '')
   where id = v_req.id
   returning * into v_req;

  return v_req;
end;
$$;

grant execute on function public.fn_requisition_create(uuid, uuid, uuid, jsonb, text) to authenticated;
grant execute on function public.fn_requisition_dispatch(uuid, jsonb, text) to authenticated;
grant execute on function public.fn_requisition_receive(uuid, jsonb, text) to authenticated;
grant execute on function public.fn_requisition_cancel(uuid, text) to authenticated;

-- ---------------------------------------------------------------------------
-- 8. Permisos en el catálogo de la BD
-- ---------------------------------------------------------------------------
-- Un código que no esté acá lo descarta EN SILENCIO el join del RPC de
-- permisos: el gate en Flutter existe y nunca deja pasar a nadie.

insert into public.permissions (code, name, module, description) values
  ('inventario.requisiciones.crear', 'Solicitar mercancía', 'inventory',
   'Crea requisiciones de una bodega a otra.'),
  ('inventario.requisiciones.despachar', 'Despachar requisiciones', 'inventory',
   'Entrega la mercancía pedida. Además hay que ser el responsable de la bodega de origen.'),
  ('inventario.requisiciones.recibir', 'Recibir requisiciones', 'inventory',
   'Confirma lo que llegó a la bodega destino.')
on conflict (code) do nothing;

commit;
