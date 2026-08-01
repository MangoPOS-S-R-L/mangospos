-- =============================================================================
-- ROLLBACK de 20260801_0002_physical_count_blind_recount.sql
--
-- Restaura las funciones y la vista al estado de 20260516_0011.
--
-- OJO: las columnas nuevas NO se eliminan. Las sesiones ya completadas
-- guardan en ellas la trazabilidad del ajuste (stock_at_complete, unit_cost,
-- variance_value) y borrarlas perdería la auditoría de esos cierres.
-- Si de verdad necesitas quitarlas, el bloque comentado al final lo hace.
-- =============================================================================

begin;

-- 1. Vista summary sin is_blind / recuento / valuación.
-- Se suelta primero: quitar una columna del medio con `create or replace`
-- falla con 42P16 (cannot change name of view column).
drop view if exists public.v_physical_count_sessions_summary;

create view public.v_physical_count_sessions_summary
with (security_invoker = on) as
select
  s.id,
  s.business_id,
  s.code,
  s.status,
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
    where l.session_id = s.id and l.applied_adjustment_id is not null) as adjustments_count
from public.physical_count_sessions s
join public.warehouses w on w.id = s.warehouse_id;

grant select on public.v_physical_count_sessions_summary to authenticated;

drop view if exists public.v_physical_count_lines_detail;

-- 2. Quitar el RPC de recuento.
drop function if exists public.fn_physical_count_request_recount(uuid, uuid[]);

-- 3. create — volver a la firma de 3 argumentos.
drop function if exists public.fn_physical_count_create(uuid, uuid, text, boolean);

create or replace function public.fn_physical_count_create(
  p_business_id uuid,
  p_warehouse_id uuid,
  p_notes text default null
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
    business_id, warehouse_id, notes, started_by, status
  )
  values (p_business_id, p_warehouse_id, p_notes, auth.uid(), 'draft')
  returning id, code into v_session_id, v_code;

  return jsonb_build_object('id', v_session_id, 'code', v_code);
end;
$$;

grant execute on function public.fn_physical_count_create(uuid, uuid, text)
  to authenticated;

-- 4. freeze — volver a incluir solo items con fila en inventory_stock.
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
    ist.item_id,
    coalesce(ist.quantity, 0)
  from public.inventory_stock ist
  join public.inventory_items ii
    on ii.id = ist.item_id and ii.business_id = v_session.business_id
  where ist.warehouse_id = v_session.warehouse_id
    and coalesce(ii.is_active, true);

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

-- 5. set_count — sin lógica de recuento.
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
  v_line_id uuid;
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

  update public.physical_count_lines
     set counted_quantity = p_counted_quantity,
         counter_notes = nullif(btrim(coalesce(p_notes, '')), ''),
         updated_at = now()
   where session_id = p_session_id and item_id = p_item_id
   returning id into v_line_id;

  if v_line_id is null then
    raise exception 'LINE_NOT_FOUND_IN_SESSION';
  end if;

  return jsonb_build_object('line_id', v_line_id);
end;
$$;

grant execute on function
  public.fn_physical_count_set_count(uuid, uuid, numeric, text) to authenticated;

-- 6. complete — volver a ajustar contra el snapshot (delta, sin valuación).
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
  v_variance numeric;
  v_movement jsonb;
  v_movement_id uuid;
  v_adjustments_count int := 0;
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
  loop
    v_variance := v_line.counted_quantity - v_line.snapshot_quantity;
    if abs(v_variance) < 0.0001 then
      continue;
    end if;

    v_movement := public.fn_inventory_record_movement(
      p_business_id    => v_session.business_id,
      p_warehouse_id   => v_session.warehouse_id,
      p_item_id        => v_line.item_id,
      p_movement_type  => 'adjustment'::public.movement_type,
      p_quantity       => v_variance,
      p_cost_per_unit  => null,
      p_reference_id   => v_session.id,
      p_reference_type => 'physical_count',
      p_notes          => 'Ajuste por conteo físico ' || v_session.code
    );

    v_movement_id := (v_movement->>'id')::uuid;

    update public.physical_count_lines
       set applied_adjustment_id = v_movement_id
     where id = v_line.id;

    v_adjustments_count := v_adjustments_count + 1;
  end loop;

  update public.physical_count_sessions
     set status = 'completed',
         completed_at = now(),
         completed_by = auth.uid()
   where id = p_session_id;

  return jsonb_build_object(
    'id', p_session_id,
    'status', 'completed',
    'adjustments_count', v_adjustments_count
  );
end;
$$;

grant execute on function public.fn_physical_count_complete(uuid) to authenticated;

commit;

-- ---------------------------------------------------------------------------
-- Solo si además quieres borrar las columnas nuevas (pierdes la auditoría
-- de los cierres ya hechos con la versión R2):
-- ---------------------------------------------------------------------------
-- begin;
-- alter table public.physical_count_sessions drop column if exists is_blind;
-- alter table public.physical_count_lines
--   drop column if exists first_count_quantity,
--   drop column if exists recount_requested,
--   drop column if exists recounted_at,
--   drop column if exists stock_at_complete,
--   drop column if exists applied_variance,
--   drop column if exists unit_cost,
--   drop column if exists variance_value;
-- commit;
