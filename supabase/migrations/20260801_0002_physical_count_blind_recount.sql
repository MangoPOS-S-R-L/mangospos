-- =============================================================================
-- Conteo físico R2: modo a ciegas, recuento (2ª vuelta), valuación y
-- ajuste contra el stock vivo.
--
-- Extiende `20260516_0011_physical_count.sql`. Cambios:
--
--   1. MODO A CIEGAS (`is_blind`): la sesión se marca al crearla. La app
--      oculta snapshot y diferencia mientras se cuenta y los revela al
--      completar. Es una bandera de proceso — quien cuenta tiene rol
--      owner/admin/manager y puede ver el stock en la pantalla de Insumos,
--      así que el blindaje real es de procedimiento, no de permisos.
--
--   2. AJUSTE CONTRA STOCK VIVO (cambio de comportamiento):
--      Antes el ajuste era `contado - snapshot` aplicado como delta sobre
--      el stock actual. Si había ventas entre congelar y completar el stock
--      final quedaba desfasado:
--        snapshot 100 → se venden 5 (stock 95) → cuentas 98
--        → delta -2 → stock final 93, no 98.
--      Ahora el delta es `contado - stock_al_completar`, así que el stock
--      SIEMPRE termina exactamente en lo contado. El snapshot se conserva
--      como referencia de auditoría.
--
--   3. RECUENTO: `fn_physical_count_request_recount` marca líneas para una
--      2ª vuelta. Al re-registrar, el 1er valor se preserva en
--      `first_count_quantity`.
--
--   4. VALUACIÓN: al completar se congela `unit_cost` (inventory_items.cost)
--      y se calcula `variance_value` = ajuste aplicado × costo.
--
--   5. FREEZE COMPLETO: incluye todos los insumos activos del negocio,
--      no solo los que ya tienen fila en `inventory_stock` de esa bodega.
--      Los que no la tienen entran con snapshot 0, para poder registrar
--      sobrantes que el sistema no sabía que existían.
--
-- IDEMPOTENTE: add column if not exists + create or replace.
-- =============================================================================

begin;

-- ---------------------------------------------------------------------------
-- 1. Columnas nuevas
-- ---------------------------------------------------------------------------

alter table public.physical_count_sessions
  add column if not exists is_blind boolean not null default false;

comment on column public.physical_count_sessions.is_blind is
  'Conteo a ciegas: la app oculta el stock del sistema mientras se cuenta.';

alter table public.physical_count_lines
  add column if not exists first_count_quantity numeric(14,4),
  add column if not exists recount_requested boolean not null default false,
  add column if not exists recounted_at timestamptz,
  add column if not exists stock_at_complete numeric(14,4),
  add column if not exists applied_variance numeric(14,4),
  add column if not exists unit_cost numeric(14,4),
  add column if not exists variance_value numeric(14,4);

comment on column public.physical_count_lines.first_count_quantity is
  'Cantidad de la 1ª vuelta, preservada cuando la línea se recontó.';
comment on column public.physical_count_lines.recount_requested is
  'Marcada para 2ª vuelta. Se limpia al registrar el nuevo conteo.';
comment on column public.physical_count_lines.stock_at_complete is
  'Stock del sistema en el momento de completar. Base real del ajuste.';
comment on column public.physical_count_lines.applied_variance is
  'Delta aplicado al inventario = counted_quantity - stock_at_complete.';
comment on column public.physical_count_lines.unit_cost is
  'Costo unitario congelado al completar (inventory_items.cost).';
comment on column public.physical_count_lines.variance_value is
  'Impacto en costo del ajuste = applied_variance * unit_cost.';

create index if not exists idx_physical_count_lines_recount
  on public.physical_count_lines (session_id)
  where recount_requested;

-- ---------------------------------------------------------------------------
-- 2. fn_physical_count_create — nuevo parámetro p_is_blind.
--
-- La firma vieja (uuid, uuid, text) se elimina: si quedaran ambas, una
-- llamada de 3 argumentos seguiría resolviendo a la vieja e ignoraría el
-- modo a ciegas en silencio.
-- ---------------------------------------------------------------------------

drop function if exists public.fn_physical_count_create(uuid, uuid, text);

create or replace function public.fn_physical_count_create(
  p_business_id uuid,
  p_warehouse_id uuid,
  p_notes text default null,
  p_is_blind boolean default false
) returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_role text;
  v_session_id uuid;
  v_code text;
begin
  if p_business_id is null or p_warehouse_id is null then
    raise exception 'INVALID_INPUT';
  end if;
  v_role := public.user_business_role(auth.uid(), p_business_id);
  if coalesce(v_role, '') not in ('owner', 'admin', 'manager') then
    raise exception 'INSUFFICIENT_ROLE';
  end if;
  if not exists (
    select 1 from public.warehouses
    where id = p_warehouse_id and business_id = p_business_id
  ) then
    raise exception 'WAREHOUSE_NOT_FOUND';
  end if;

  insert into public.physical_count_sessions (
    business_id, warehouse_id, notes, started_by, status, is_blind
  )
  values (
    p_business_id, p_warehouse_id, p_notes, auth.uid(), 'draft',
    coalesce(p_is_blind, false)
  )
  returning id, code into v_session_id, v_code;

  return jsonb_build_object(
    'id', v_session_id,
    'code', v_code,
    'is_blind', coalesce(p_is_blind, false)
  );
end;
$$;

grant execute on function
  public.fn_physical_count_create(uuid, uuid, text, boolean) to authenticated;

-- ---------------------------------------------------------------------------
-- 3. fn_physical_count_freeze — ahora incluye TODOS los insumos activos.
--
-- El left join hace que un insumo activo sin fila en `inventory_stock` para
-- esa bodega entre igual con snapshot 0. Sin esto, un sobrante físico de un
-- item que el sistema cree inexistente no se puede registrar.
-- ---------------------------------------------------------------------------

create or replace function public.fn_physical_count_freeze(
  p_session_id uuid
) returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_session public.physical_count_sessions;
  v_role text;
  v_count int := 0;
begin
  if p_session_id is null then
    raise exception 'SESSION_ID_REQUIRED';
  end if;
  select * into v_session from public.physical_count_sessions where id = p_session_id;
  if v_session.id is null then
    raise exception 'SESSION_NOT_FOUND';
  end if;
  v_role := public.user_business_role(auth.uid(), v_session.business_id);
  if coalesce(v_role, '') not in ('owner', 'admin', 'manager') then
    raise exception 'INSUFFICIENT_ROLE';
  end if;
  if v_session.status <> 'draft' then
    raise exception 'INVALID_STATUS_TRANSITION: solo se puede congelar desde draft';
  end if;

  insert into public.physical_count_lines (
    session_id, item_id, snapshot_quantity
  )
  select
    v_session.id,
    ii.id,
    coalesce(ist.quantity, 0)
  from public.inventory_items ii
  left join public.inventory_stock ist
    on ist.item_id = ii.id
   and ist.warehouse_id = v_session.warehouse_id
  where ii.business_id = v_session.business_id
    and coalesce(ii.is_active, true)
  on conflict (session_id, item_id) do nothing;

  get diagnostics v_count = row_count;

  update public.physical_count_sessions
     set status = 'in_progress',
         frozen_at = now(),
         frozen_by = auth.uid()
   where id = p_session_id;

  return jsonb_build_object(
    'id', v_session.id,
    'status', 'in_progress',
    'lines_count', v_count
  );
end;
$$;

grant execute on function public.fn_physical_count_freeze(uuid) to authenticated;

-- ---------------------------------------------------------------------------
-- 4. fn_physical_count_set_count — preserva la 1ª vuelta al recontar.
-- ---------------------------------------------------------------------------

create or replace function public.fn_physical_count_set_count(
  p_session_id uuid,
  p_item_id uuid,
  p_counted_quantity numeric,
  p_notes text default null
) returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_session public.physical_count_sessions;
  v_role text;
  v_line public.physical_count_lines;
  v_is_recount boolean := false;
begin
  if p_session_id is null or p_item_id is null then
    raise exception 'INVALID_INPUT';
  end if;
  if p_counted_quantity is null or p_counted_quantity < 0 then
    raise exception 'INVALID_QUANTITY';
  end if;
  select * into v_session from public.physical_count_sessions where id = p_session_id;
  if v_session.id is null then
    raise exception 'SESSION_NOT_FOUND';
  end if;
  v_role := public.user_business_role(auth.uid(), v_session.business_id);
  if coalesce(v_role, '') not in ('owner', 'admin', 'manager') then
    raise exception 'INSUFFICIENT_ROLE';
  end if;
  if v_session.status <> 'in_progress' then
    raise exception 'INVALID_STATUS: la sesión no está en in_progress';
  end if;

  select * into v_line
  from public.physical_count_lines
  where session_id = p_session_id and item_id = p_item_id;

  if v_line.id is null then
    raise exception 'LINE_NOT_FOUND_IN_SESSION';
  end if;

  v_is_recount := v_line.recount_requested and v_line.counted_quantity is not null;

  update public.physical_count_lines
     set counted_quantity = p_counted_quantity,
         first_count_quantity = case
           when v_is_recount
             then coalesce(first_count_quantity, v_line.counted_quantity)
           else first_count_quantity
         end,
         recounted_at = case when v_is_recount then now() else recounted_at end,
         recount_requested = false,
         counter_notes = nullif(btrim(coalesce(p_notes, '')), ''),
         updated_at = now()
   where id = v_line.id;

  return jsonb_build_object('line_id', v_line.id, 'was_recount', v_is_recount);
end;
$$;

grant execute on function
  public.fn_physical_count_set_count(uuid, uuid, numeric, text) to authenticated;

-- ---------------------------------------------------------------------------
-- 5. fn_physical_count_request_recount — marca líneas para 2ª vuelta.
-- ---------------------------------------------------------------------------

create or replace function public.fn_physical_count_request_recount(
  p_session_id uuid,
  p_item_ids uuid[]
) returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_session public.physical_count_sessions;
  v_role text;
  v_count int := 0;
begin
  if p_session_id is null then
    raise exception 'SESSION_ID_REQUIRED';
  end if;
  if p_item_ids is null or array_length(p_item_ids, 1) is null then
    raise exception 'NO_ITEMS_SELECTED';
  end if;
  select * into v_session from public.physical_count_sessions where id = p_session_id;
  if v_session.id is null then
    raise exception 'SESSION_NOT_FOUND';
  end if;
  v_role := public.user_business_role(auth.uid(), v_session.business_id);
  if coalesce(v_role, '') not in ('owner', 'admin', 'manager') then
    raise exception 'INSUFFICIENT_ROLE';
  end if;
  if v_session.status <> 'in_progress' then
    raise exception 'INVALID_STATUS: la sesión no está en in_progress';
  end if;

  update public.physical_count_lines
     set recount_requested = true,
         updated_at = now()
   where session_id = p_session_id
     and item_id = any(p_item_ids);

  get diagnostics v_count = row_count;

  return jsonb_build_object('flagged', v_count);
end;
$$;

grant execute on function
  public.fn_physical_count_request_recount(uuid, uuid[]) to authenticated;

-- ---------------------------------------------------------------------------
-- 6. fn_physical_count_complete — ajusta contra el stock vivo + valúa.
-- ---------------------------------------------------------------------------

create or replace function public.fn_physical_count_complete(
  p_session_id uuid
) returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_session public.physical_count_sessions;
  v_role text;
  v_line record;
  v_current numeric;
  v_applied numeric;
  v_cost numeric;
  v_movement jsonb;
  v_movement_id uuid;
  v_adjustments_count int := 0;
  v_value_total numeric := 0;
begin
  if p_session_id is null then
    raise exception 'SESSION_ID_REQUIRED';
  end if;
  select * into v_session from public.physical_count_sessions where id = p_session_id;
  if v_session.id is null then
    raise exception 'SESSION_NOT_FOUND';
  end if;
  v_role := public.user_business_role(auth.uid(), v_session.business_id);
  if coalesce(v_role, '') not in ('owner', 'admin', 'manager') then
    raise exception 'INSUFFICIENT_ROLE';
  end if;
  if v_session.status <> 'in_progress' then
    raise exception 'INVALID_STATUS_TRANSITION: solo se puede completar desde in_progress';
  end if;

  for v_line in
    select * from public.physical_count_lines
    where session_id = p_session_id
      and counted_quantity is not null
    -- Bloquea las líneas para que dos cierres simultáneos no dupliquen ajustes.
    for update
  loop
    -- Stock vivo AHORA, no el snapshot: incluye ventas/transferencias
    -- ocurridas durante el conteo.
    select coalesce(ist.quantity, 0) into v_current
    from public.inventory_stock ist
    where ist.warehouse_id = v_session.warehouse_id
      and ist.item_id = v_line.item_id;
    v_current := coalesce(v_current, 0);

    select coalesce(ii.cost, 0) into v_cost
    from public.inventory_items ii
    where ii.id = v_line.item_id;
    v_cost := coalesce(v_cost, 0);

    v_applied := v_line.counted_quantity - v_current;

    update public.physical_count_lines
       set stock_at_complete = v_current,
           applied_variance  = v_applied,
           unit_cost         = v_cost,
           variance_value    = v_applied * v_cost
     where id = v_line.id;

    if abs(v_applied) < 0.0001 then
      -- El sistema ya coincide con lo contado, no hay nada que ajustar.
      continue;
    end if;

    v_movement := public.fn_inventory_record_movement(
      p_business_id    => v_session.business_id,
      p_warehouse_id   => v_session.warehouse_id,
      p_item_id        => v_line.item_id,
      p_movement_type  => 'adjustment'::public.movement_type,
      p_quantity       => v_applied,
      p_cost_per_unit  => nullif(v_cost, 0),
      p_reference_id   => v_session.id,
      p_reference_type => 'physical_count',
      p_notes          => 'Ajuste por conteo físico ' || v_session.code
    );

    v_movement_id := (v_movement->>'id')::uuid;

    update public.physical_count_lines
       set applied_adjustment_id = v_movement_id
     where id = v_line.id;

    v_adjustments_count := v_adjustments_count + 1;
    v_value_total := v_value_total + (v_applied * v_cost);
  end loop;

  update public.physical_count_sessions
     set status = 'completed',
         completed_at = now(),
         completed_by = auth.uid()
   where id = p_session_id;

  return jsonb_build_object(
    'id', p_session_id,
    'status', 'completed',
    'adjustments_count', v_adjustments_count,
    'variance_value_total', v_value_total
  );
end;
$$;

grant execute on function public.fn_physical_count_complete(uuid) to authenticated;

-- ---------------------------------------------------------------------------
-- 7. Vistas
-- ---------------------------------------------------------------------------

-- `create or replace view` solo deja AGREGAR columnas al final: renombrar o
-- insertar en medio falla con 42P16. Como `is_blind` va junto a `status`, hay
-- que soltar la vista y recrearla.
drop view if exists public.v_physical_count_sessions_summary;

create view public.v_physical_count_sessions_summary
with (security_invoker = on) as
select
  s.id,
  s.business_id,
  s.code,
  s.status,
  s.is_blind,
  s.warehouse_id,
  w.name as warehouse_name,
  s.notes,
  s.cancellation_reason,
  s.started_at,
  s.frozen_at,
  s.completed_at,
  s.cancelled_at,
  (select count(*) from public.physical_count_lines l
    where l.session_id = s.id) as lines_count,
  (select count(*) from public.physical_count_lines l
    where l.session_id = s.id and l.counted_quantity is not null) as counted_lines,
  (select count(*) from public.physical_count_lines l
    where l.session_id = s.id and l.applied_adjustment_id is not null) as adjustments_count,
  (select count(*) from public.physical_count_lines l
    where l.session_id = s.id and l.recount_requested) as pending_recount,
  (select coalesce(sum(l.variance_value), 0) from public.physical_count_lines l
    where l.session_id = s.id) as variance_value_total,
  (select coalesce(sum(l.variance_value), 0) from public.physical_count_lines l
    where l.session_id = s.id and coalesce(l.variance_value, 0) < 0) as shrinkage_value
from public.physical_count_sessions s
join public.warehouses w on w.id = s.warehouse_id;

grant select on public.v_physical_count_sessions_summary to authenticated;

-- Líneas con nombre/unidad/costo resueltos. `unit_cost_current` permite
-- valuar diferencias en pantalla ANTES de completar (cuando `unit_cost`
-- todavía es null porque no se ha congelado el costo).
drop view if exists public.v_physical_count_lines_detail;

create view public.v_physical_count_lines_detail
with (security_invoker = on) as
select
  l.id,
  l.session_id,
  l.item_id,
  ii.name  as item_name,
  ii.sku   as item_sku,
  coalesce(ii.unit, 'unidad') as unit,
  coalesce(ii.cost, 0)        as unit_cost_current,
  l.snapshot_quantity,
  l.counted_quantity,
  l.first_count_quantity,
  l.recount_requested,
  l.recounted_at,
  l.stock_at_complete,
  l.applied_variance,
  l.unit_cost,
  l.variance_value,
  l.counter_notes,
  l.applied_adjustment_id,
  l.created_at,
  l.updated_at
from public.physical_count_lines l
join public.inventory_items ii on ii.id = l.item_id;

grant select on public.v_physical_count_lines_detail to authenticated;

commit;
