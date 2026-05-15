-- =============================================================================
-- Inventario PRD: Conteo físico con congelamiento.
--
-- CONCEPTO:
--   Un conteo físico profesional sigue 4 etapas:
--     1. CREAR sesión (admin): selecciona bodega.
--     2. CONGELAR: snapshot del stock actual de cada item en la bodega.
--        El stock que tiene el sistema en ese momento queda registrado por
--        línea para comparar después contra el conteo manual.
--     3. CONTAR: operador recorre la bodega y registra `counted_quantity`
--        por item (puede ir guardándolos en cualquier orden).
--     4. COMPLETAR: el sistema genera movimientos de ajuste por cada
--        diferencia y la sesión queda cerrada.
--
-- WORKFLOW:
--   draft → in_progress → completed
--    └──── cancelled ─────┘
--
-- ENTREGA:
--   1. `physical_count_sessions` (cabecera con workflow + audit trail).
--   2. `physical_count_lines` (snapshot + conteo por item).
--   3. Trigger auto-code PC-YYYY-NNNNNN.
--   4. RLS por business + role.
--   5. RPCs: create, freeze, set_count, complete, cancel.
--
-- IDEMPOTENTE: CREATE TABLE IF NOT EXISTS + CREATE OR REPLACE.
-- =============================================================================

begin;

-- ---------------------------------------------------------------------------
-- 1. Tabla sessions
-- ---------------------------------------------------------------------------

create table if not exists public.physical_count_sessions (
  id uuid primary key default gen_random_uuid(),
  business_id uuid not null references public.businesses(id) on delete cascade,
  warehouse_id uuid not null references public.warehouses(id) on delete restrict,
  code text not null,
  status text not null default 'draft'
    check (status in ('draft', 'in_progress', 'completed', 'cancelled')),
  notes text,
  cancellation_reason text,
  started_by uuid references auth.users(id) on delete set null,
  frozen_by uuid references auth.users(id) on delete set null,
  completed_by uuid references auth.users(id) on delete set null,
  cancelled_by uuid references auth.users(id) on delete set null,
  started_at timestamptz not null default now(),
  frozen_at timestamptz,
  completed_at timestamptz,
  cancelled_at timestamptz,
  constraint physical_count_sessions_code_business_unique unique (business_id, code)
);

create index if not exists idx_physical_count_sessions_business_status
  on public.physical_count_sessions (business_id, status);
create index if not exists idx_physical_count_sessions_warehouse
  on public.physical_count_sessions (warehouse_id);

comment on table public.physical_count_sessions is
  'Sesiones de conteo físico. Workflow: draft → in_progress (al congelar) '
  '→ completed (al aplicar ajustes) | cancelled.';

-- ---------------------------------------------------------------------------
-- 2. Tabla lines
-- ---------------------------------------------------------------------------

create table if not exists public.physical_count_lines (
  id uuid primary key default gen_random_uuid(),
  session_id uuid not null references public.physical_count_sessions(id) on delete cascade,
  item_id uuid not null references public.inventory_items(id) on delete restrict,
  snapshot_quantity numeric(14,4) not null,
  counted_quantity numeric(14,4),
  counter_notes text,
  applied_adjustment_id uuid references public.inventory_movements(id) on delete set null,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint physical_count_lines_unique unique (session_id, item_id)
);

create index if not exists idx_physical_count_lines_session
  on public.physical_count_lines (session_id);
create index if not exists idx_physical_count_lines_item
  on public.physical_count_lines (item_id);

comment on table public.physical_count_lines is
  'Una fila por item incluido en la sesión. snapshot_quantity = stock al '
  'congelar; counted_quantity = lo que el operador contó físicamente; '
  'applied_adjustment_id = movimiento generado al completar.';

-- ---------------------------------------------------------------------------
-- 3. Trigger autocode
-- ---------------------------------------------------------------------------

create or replace function public.fn_physical_count_assign_code()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  v_year int := extract(year from now())::int;
  v_count int;
begin
  if new.code is not null and length(trim(new.code)) > 0 then
    return new;
  end if;
  perform pg_advisory_xact_lock(
    hashtextextended('pc:' || new.business_id::text || ':' || v_year::text, 0)
  );
  select count(*) + 1 into v_count
  from public.physical_count_sessions
  where business_id = new.business_id
    and extract(year from started_at) = v_year;
  new.code := 'PC-' || v_year || '-' || lpad(v_count::text, 6, '0');
  return new;
end;
$$;

drop trigger if exists trg_physical_count_assign_code on public.physical_count_sessions;
create trigger trg_physical_count_assign_code
  before insert on public.physical_count_sessions
  for each row execute function public.fn_physical_count_assign_code();

-- ---------------------------------------------------------------------------
-- 4. RLS
-- ---------------------------------------------------------------------------

alter table public.physical_count_sessions enable row level security;
alter table public.physical_count_lines enable row level security;

drop policy if exists "pcs_select" on public.physical_count_sessions;
create policy "pcs_select" on public.physical_count_sessions
  for select to authenticated
  using (public.user_has_business_access(auth.uid(), business_id));

drop policy if exists "pcs_write" on public.physical_count_sessions;
create policy "pcs_write" on public.physical_count_sessions
  for all to authenticated
  using (public.user_business_role(auth.uid(), business_id)
         in ('owner', 'admin', 'manager'))
  with check (public.user_business_role(auth.uid(), business_id)
              in ('owner', 'admin', 'manager'));

drop policy if exists "pcl_select" on public.physical_count_lines;
create policy "pcl_select" on public.physical_count_lines
  for select to authenticated
  using (
    exists (
      select 1 from public.physical_count_sessions s
      where s.id = physical_count_lines.session_id
        and public.user_has_business_access(auth.uid(), s.business_id)
    )
  );

drop policy if exists "pcl_write" on public.physical_count_lines;
create policy "pcl_write" on public.physical_count_lines
  for all to authenticated
  using (
    exists (
      select 1 from public.physical_count_sessions s
      where s.id = physical_count_lines.session_id
        and public.user_business_role(auth.uid(), s.business_id)
            in ('owner', 'admin', 'manager')
    )
  )
  with check (
    exists (
      select 1 from public.physical_count_sessions s
      where s.id = physical_count_lines.session_id
        and public.user_business_role(auth.uid(), s.business_id)
            in ('owner', 'admin', 'manager')
    )
  );

-- ---------------------------------------------------------------------------
-- 5. RPC fn_physical_count_create
-- ---------------------------------------------------------------------------

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

-- ---------------------------------------------------------------------------
-- 6. RPC fn_physical_count_freeze — toma snapshot del stock actual.
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

  -- Snapshot: una línea por cada item con stock != 0 en la bodega.
  -- Items con stock 0 también se incluyen si quieres permitir descubrir
  -- positivos ocultos — los incluimos para apoyar conteos "totales".
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

-- ---------------------------------------------------------------------------
-- 7. RPC fn_physical_count_set_count — registra/actualiza una línea.
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

grant execute on function public.fn_physical_count_set_count(uuid, uuid, numeric, text)
  to authenticated;

-- ---------------------------------------------------------------------------
-- 8. RPC fn_physical_count_complete — aplica ajustes y cierra.
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
      -- Sin diferencia, no genera ajuste.
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

-- ---------------------------------------------------------------------------
-- 9. RPC fn_physical_count_cancel
-- ---------------------------------------------------------------------------

create or replace function public.fn_physical_count_cancel(
  p_session_id uuid,
  p_reason text default null
) returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_session public.physical_count_sessions;
  v_role text;
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
  if v_session.status not in ('draft', 'in_progress') then
    raise exception 'INVALID_STATUS_TRANSITION';
  end if;

  update public.physical_count_sessions
     set status = 'cancelled',
         cancelled_at = now(),
         cancelled_by = auth.uid(),
         cancellation_reason = nullif(btrim(coalesce(p_reason, '')), '')
   where id = p_session_id;

  return jsonb_build_object('id', p_session_id, 'status', 'cancelled');
end;
$$;

grant execute on function public.fn_physical_count_cancel(uuid, text) to authenticated;

-- ---------------------------------------------------------------------------
-- 10. Vista helper
-- ---------------------------------------------------------------------------

create or replace view public.v_physical_count_sessions_summary
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

commit;
