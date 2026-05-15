-- =============================================================================
-- Inventario PRD: Producción.
--
-- CONCEPTO:
--   Una orden de producción consume materias primas y produce un producto
--   terminado. Workflow profesional:
--     draft → in_progress → completed
--             ↓
--          cancelled (desde draft o in_progress)
--
-- ENTREGA:
--   1. Tablas `production_orders` (cabecera) y `production_order_lines`
--      (insumos a consumir, planeados y reales).
--   2. Trigger BEFORE INSERT que asigna código auto PROD-YYYY-NNNNNN
--      con advisory lock para evitar duplicados en concurrencia.
--   3. RLS policies: SELECT permisivo por business, WRITE solo owner/admin/manager.
--   4. Update a `fn_inventory_record_movement` para manejar signo correcto
--      de production_in (+) y production_out (-).
--   5. RPC `fn_production_order_create(business_id, finished_item_id, planned_yield,
--      source_warehouse_id, destination_warehouse_id, notes?)` — crea draft +
--      genera las lines automáticamente desde la receta del finished_item,
--      escaladas por (planned_yield / recipe.yield_quantity).
--   6. RPC `fn_production_order_start(order_id)` — draft → in_progress.
--   7. RPC `fn_production_order_complete(order_id, actual_yield, line_consumption[])`
--      — in_progress → completed. Genera movimientos en el kardex, recalcula
--      costo del finished_item (promedio ponderado del costo de raws consumidos).
--   8. RPC `fn_production_order_cancel(order_id, reason?)`.
--
-- IDEMPOTENTE: CREATE TABLE IF NOT EXISTS + CREATE OR REPLACE.
-- =============================================================================

begin;

-- ---------------------------------------------------------------------------
-- 1. Tabla production_orders
-- ---------------------------------------------------------------------------

create table if not exists public.production_orders (
  id uuid primary key default gen_random_uuid(),
  business_id uuid not null references public.businesses(id) on delete cascade,
  code text not null,
  status text not null default 'draft'
    check (status in ('draft', 'in_progress', 'completed', 'cancelled')),
  finished_item_id uuid not null
    references public.inventory_items(id) on delete restrict,
  source_warehouse_id uuid not null
    references public.warehouses(id) on delete restrict,
  destination_warehouse_id uuid not null
    references public.warehouses(id) on delete restrict,
  planned_yield numeric(14,4) not null check (planned_yield > 0),
  actual_yield numeric(14,4),
  notes text,
  cancellation_reason text,
  created_by uuid references auth.users(id) on delete set null,
  started_by uuid references auth.users(id) on delete set null,
  completed_by uuid references auth.users(id) on delete set null,
  cancelled_by uuid references auth.users(id) on delete set null,
  created_at timestamptz not null default now(),
  started_at timestamptz,
  completed_at timestamptz,
  cancelled_at timestamptz,
  constraint production_orders_code_business_unique unique (business_id, code)
);

create index if not exists idx_production_orders_business_status
  on public.production_orders (business_id, status);
create index if not exists idx_production_orders_finished_item
  on public.production_orders (finished_item_id);

comment on table public.production_orders is
  'Órdenes de producción que transforman materias primas en productos '
  'terminados. Workflow: draft → in_progress → completed | cancelled.';

-- ---------------------------------------------------------------------------
-- 2. Tabla production_order_lines (insumos consumidos)
-- ---------------------------------------------------------------------------

create table if not exists public.production_order_lines (
  id uuid primary key default gen_random_uuid(),
  production_order_id uuid not null
    references public.production_orders(id) on delete cascade,
  item_id uuid not null references public.inventory_items(id) on delete restrict,
  planned_quantity numeric(14,4) not null check (planned_quantity >= 0),
  consumed_quantity numeric(14,4),
  unit text,
  cost_per_unit numeric(14,4),
  created_at timestamptz not null default now(),
  constraint production_order_lines_unique unique (production_order_id, item_id)
);

create index if not exists idx_production_order_lines_order
  on public.production_order_lines (production_order_id);
create index if not exists idx_production_order_lines_item
  on public.production_order_lines (item_id);

comment on table public.production_order_lines is
  'Insumos (materias primas) que consume una orden de producción. '
  'planned_quantity viene de escalar la receta; consumed_quantity es lo '
  'realmente consumido al completar (puede diferir por mermas).';

-- ---------------------------------------------------------------------------
-- 3. Trigger BEFORE INSERT en production_orders para generar code auto.
--    Formato: PROD-YYYY-NNNNNN (counter por business+year).
--    Usa advisory lock por business para evitar duplicados en concurrencia.
-- ---------------------------------------------------------------------------

create or replace function public.fn_production_order_assign_code()
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
    return new; -- caller provided code explicitly
  end if;

  -- Serializar por business para asegurar counter monotónico.
  perform pg_advisory_xact_lock(
    hashtextextended(new.business_id::text || ':' || v_year::text, 0)
  );

  select count(*) + 1 into v_count
  from public.production_orders
  where business_id = new.business_id
    and extract(year from created_at) = v_year;

  new.code := 'PROD-' || v_year || '-' || lpad(v_count::text, 6, '0');
  return new;
end;
$$;

drop trigger if exists trg_production_orders_assign_code on public.production_orders;
create trigger trg_production_orders_assign_code
  before insert on public.production_orders
  for each row execute function public.fn_production_order_assign_code();

-- ---------------------------------------------------------------------------
-- 4. RLS
-- ---------------------------------------------------------------------------

alter table public.production_orders enable row level security;
alter table public.production_order_lines enable row level security;

drop policy if exists "po_select" on public.production_orders;
create policy "po_select" on public.production_orders
  for select to authenticated
  using (public.user_has_business_access(auth.uid(), business_id));

drop policy if exists "po_write" on public.production_orders;
create policy "po_write" on public.production_orders
  for all to authenticated
  using (
    public.user_business_role(auth.uid(), business_id)
      in ('owner', 'admin', 'manager')
  )
  with check (
    public.user_business_role(auth.uid(), business_id)
      in ('owner', 'admin', 'manager')
  );

drop policy if exists "pol_select" on public.production_order_lines;
create policy "pol_select" on public.production_order_lines
  for select to authenticated
  using (
    exists (
      select 1 from public.production_orders po
      where po.id = production_order_lines.production_order_id
        and public.user_has_business_access(auth.uid(), po.business_id)
    )
  );

drop policy if exists "pol_write" on public.production_order_lines;
create policy "pol_write" on public.production_order_lines
  for all to authenticated
  using (
    exists (
      select 1 from public.production_orders po
      where po.id = production_order_lines.production_order_id
        and public.user_business_role(auth.uid(), po.business_id)
            in ('owner', 'admin', 'manager')
    )
  )
  with check (
    exists (
      select 1 from public.production_orders po
      where po.id = production_order_lines.production_order_id
        and public.user_business_role(auth.uid(), po.business_id)
            in ('owner', 'admin', 'manager')
    )
  );

-- ---------------------------------------------------------------------------
-- 5. fn_inventory_record_movement: actualizar para manejar signos de
--    production_in (+) y production_out (-).
-- ---------------------------------------------------------------------------

create or replace function public.fn_inventory_record_movement(
  p_business_id uuid,
  p_warehouse_id uuid,
  p_item_id uuid,
  p_movement_type public.movement_type,
  p_quantity numeric,
  p_cost_per_unit numeric default null,
  p_reference_id uuid default null,
  p_reference_type text default null,
  p_notes text default null
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_user_id uuid := auth.uid();
  v_role text;
  v_signed_quantity numeric;
  v_movement public.inventory_movements;
begin
  if v_user_id is null then
    raise exception 'AUTH_REQUIRED';
  end if;

  select public.user_business_role(v_user_id, p_business_id)
    into v_role;

  if coalesce(v_role, '') not in ('owner', 'admin', 'manager') then
    raise exception 'INVENTORY_ACCESS_DENIED';
  end if;

  if p_quantity is null or p_quantity = 0 then
    raise exception 'INVALID_QUANTITY';
  end if;

  if not exists (
    select 1 from public.inventory_items ii
    where ii.id = p_item_id and ii.business_id = p_business_id
  ) then
    raise exception 'ITEM_NOT_FOUND';
  end if;

  if not exists (
    select 1 from public.warehouses w
    where w.id = p_warehouse_id
      and w.business_id = p_business_id
      and coalesce(w.is_active, true)
  ) then
    raise exception 'WAREHOUSE_NOT_FOUND';
  end if;

  v_signed_quantity := case
    when p_movement_type in ('sale', 'transfer_out', 'waste', 'production_out')
      then -abs(p_quantity)
    when p_movement_type in ('purchase', 'transfer_in', 'return', 'production_in')
      then abs(p_quantity)
    else p_quantity
  end;

  insert into public.inventory_movements (
    business_id, warehouse_id, item_id, movement_type, quantity,
    cost_per_unit, reference_id, reference_type, notes, created_by
  )
  values (
    p_business_id, p_warehouse_id, p_item_id, p_movement_type,
    v_signed_quantity, p_cost_per_unit, p_reference_id, p_reference_type,
    p_notes, v_user_id
  )
  returning * into v_movement;

  return jsonb_build_object(
    'id', v_movement.id,
    'business_id', v_movement.business_id,
    'warehouse_id', v_movement.warehouse_id,
    'item_id', v_movement.item_id,
    'movement_type', v_movement.movement_type,
    'quantity', v_movement.quantity,
    'created_at', v_movement.created_at
  );
end;
$$;

-- ---------------------------------------------------------------------------
-- 6. RPC fn_production_order_create
-- ---------------------------------------------------------------------------

create or replace function public.fn_production_order_create(
  p_business_id uuid,
  p_finished_item_id uuid,
  p_planned_yield numeric,
  p_source_warehouse_id uuid,
  p_destination_warehouse_id uuid,
  p_notes text default null
) returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_role text;
  v_recipe_id uuid;
  v_recipe_yield numeric;
  v_scale numeric;
  v_order_id uuid;
  v_order_code text;
  v_ing record;
  v_lines_count int := 0;
begin
  if p_business_id is null or p_finished_item_id is null
    or p_planned_yield is null or p_planned_yield <= 0
    or p_source_warehouse_id is null or p_destination_warehouse_id is null then
    raise exception 'INVALID_INPUT';
  end if;

  v_role := public.user_business_role(auth.uid(), p_business_id);
  if coalesce(v_role, '') not in ('owner', 'admin', 'manager') then
    raise exception 'INSUFFICIENT_ROLE';
  end if;

  -- Validar finished_item del business
  if not exists (
    select 1 from public.inventory_items ii
    where ii.id = p_finished_item_id and ii.business_id = p_business_id
  ) then
    raise exception 'FINISHED_ITEM_NOT_FOUND';
  end if;

  -- Validar warehouses del business
  if not exists (
    select 1 from public.warehouses w
    where w.id = p_source_warehouse_id and w.business_id = p_business_id
  ) then
    raise exception 'SOURCE_WAREHOUSE_NOT_FOUND';
  end if;
  if not exists (
    select 1 from public.warehouses w
    where w.id = p_destination_warehouse_id and w.business_id = p_business_id
  ) then
    raise exception 'DESTINATION_WAREHOUSE_NOT_FOUND';
  end if;

  -- Buscar receta del finished_item
  select r.id, coalesce(r.yield_quantity, 1)
    into v_recipe_id, v_recipe_yield
  from public.recipes r
  where r.inventory_item_id = p_finished_item_id
  limit 1;

  if v_recipe_id is null then
    raise exception 'RECIPE_NOT_FOUND: el inventory_item no tiene receta de producción';
  end if;

  v_scale := p_planned_yield / nullif(v_recipe_yield, 0);
  if v_scale is null or v_scale <= 0 then
    raise exception 'INVALID_SCALE';
  end if;

  -- Crear cabecera
  insert into public.production_orders (
    business_id, finished_item_id, planned_yield,
    source_warehouse_id, destination_warehouse_id,
    notes, created_by, status
  )
  values (
    p_business_id, p_finished_item_id, p_planned_yield,
    p_source_warehouse_id, p_destination_warehouse_id,
    p_notes, auth.uid(), 'draft'
  )
  returning id, code into v_order_id, v_order_code;

  -- Generar lines escaladas desde la receta
  for v_ing in
    select ri.inventory_item_id, ri.quantity, ri.unit, ii.cost
    from public.recipe_ingredients ri
    join public.inventory_items ii on ii.id = ri.inventory_item_id
    where ri.recipe_id = v_recipe_id
      and ri.inventory_item_id is not null
  loop
    insert into public.production_order_lines (
      production_order_id, item_id, planned_quantity, unit, cost_per_unit
    )
    values (
      v_order_id, v_ing.inventory_item_id,
      round((v_ing.quantity * v_scale)::numeric, 4),
      v_ing.unit, v_ing.cost
    );
    v_lines_count := v_lines_count + 1;
  end loop;

  return jsonb_build_object(
    'id', v_order_id,
    'code', v_order_code,
    'lines_count', v_lines_count
  );
end;
$$;

grant execute on function public.fn_production_order_create(
  uuid, uuid, numeric, uuid, uuid, text
) to authenticated;

-- ---------------------------------------------------------------------------
-- 7. RPC fn_production_order_start
-- ---------------------------------------------------------------------------

create or replace function public.fn_production_order_start(
  p_order_id uuid
) returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_order public.production_orders;
  v_role text;
begin
  if p_order_id is null then
    raise exception 'ORDER_ID_REQUIRED';
  end if;

  select * into v_order from public.production_orders where id = p_order_id;
  if v_order.id is null then
    raise exception 'ORDER_NOT_FOUND';
  end if;

  v_role := public.user_business_role(auth.uid(), v_order.business_id);
  if coalesce(v_role, '') not in ('owner', 'admin', 'manager') then
    raise exception 'INSUFFICIENT_ROLE';
  end if;

  if v_order.status <> 'draft' then
    raise exception 'INVALID_STATUS_TRANSITION: solo se puede iniciar desde draft';
  end if;

  update public.production_orders
     set status = 'in_progress',
         started_at = now(),
         started_by = auth.uid()
   where id = p_order_id;

  return jsonb_build_object('id', p_order_id, 'status', 'in_progress');
end;
$$;

grant execute on function public.fn_production_order_start(uuid) to authenticated;

-- ---------------------------------------------------------------------------
-- 8. RPC fn_production_order_complete
--    Recibe el actual_yield + consumo real por línea (jsonb array).
--    Genera movimientos en el kardex y recalcula costo del finished_item.
-- ---------------------------------------------------------------------------

create or replace function public.fn_production_order_complete(
  p_order_id uuid,
  p_actual_yield numeric,
  p_line_consumption jsonb default null
) returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_order public.production_orders;
  v_role text;
  v_line record;
  v_consumed numeric;
  v_total_cost numeric := 0;
  v_new_cost numeric;
  v_consumption_map jsonb;
begin
  if p_order_id is null or p_actual_yield is null or p_actual_yield <= 0 then
    raise exception 'INVALID_INPUT';
  end if;

  select * into v_order from public.production_orders where id = p_order_id;
  if v_order.id is null then
    raise exception 'ORDER_NOT_FOUND';
  end if;

  v_role := public.user_business_role(auth.uid(), v_order.business_id);
  if coalesce(v_role, '') not in ('owner', 'admin', 'manager') then
    raise exception 'INSUFFICIENT_ROLE';
  end if;

  if v_order.status not in ('draft', 'in_progress') then
    raise exception 'INVALID_STATUS_TRANSITION: solo se puede completar desde draft o in_progress';
  end if;

  -- Si nos pasaron consumo real, lo aplicamos por línea; sino usamos planned.
  -- p_line_consumption viene como [{ "item_id": "uuid", "consumed": 1.5 }, ...]
  v_consumption_map := coalesce(p_line_consumption, '[]'::jsonb);

  -- Actualizar consumed_quantity de cada line, y generar movimiento de salida.
  for v_line in
    select pol.*
    from public.production_order_lines pol
    where pol.production_order_id = p_order_id
  loop
    -- Resolver consumed: del override si existe, sino planned.
    select (elem->>'consumed')::numeric
      into v_consumed
    from jsonb_array_elements(v_consumption_map) elem
    where (elem->>'item_id')::uuid = v_line.item_id
    limit 1;

    if v_consumed is null then
      v_consumed := v_line.planned_quantity;
    end if;

    if v_consumed <= 0 then
      -- Nada que consumir de esa línea.
      update public.production_order_lines
         set consumed_quantity = 0
       where id = v_line.id;
      continue;
    end if;

    update public.production_order_lines
       set consumed_quantity = v_consumed
     where id = v_line.id;

    -- Generar movimiento de salida desde el source warehouse.
    perform public.fn_inventory_record_movement(
      p_business_id    => v_order.business_id,
      p_warehouse_id   => v_order.source_warehouse_id,
      p_item_id        => v_line.item_id,
      p_movement_type  => 'production_out'::public.movement_type,
      p_quantity       => v_consumed,
      p_cost_per_unit  => v_line.cost_per_unit,
      p_reference_id   => p_order_id,
      p_reference_type => 'production',
      p_notes          => 'Consumo por producción ' || v_order.code
    );

    v_total_cost := v_total_cost + (v_consumed * coalesce(v_line.cost_per_unit, 0));
  end loop;

  -- Generar movimiento de entrada del finished_item.
  v_new_cost := case
    when p_actual_yield > 0 then round((v_total_cost / p_actual_yield)::numeric, 4)
    else 0
  end;

  perform public.fn_inventory_record_movement(
    p_business_id    => v_order.business_id,
    p_warehouse_id   => v_order.destination_warehouse_id,
    p_item_id        => v_order.finished_item_id,
    p_movement_type  => 'production_in'::public.movement_type,
    p_quantity       => p_actual_yield,
    p_cost_per_unit  => v_new_cost,
    p_reference_id   => p_order_id,
    p_reference_type => 'production',
    p_notes          => 'Producción ' || v_order.code
  );

  -- Marcar orden como completada.
  update public.production_orders
     set status = 'completed',
         actual_yield = p_actual_yield,
         completed_at = now(),
         completed_by = auth.uid()
   where id = p_order_id;

  return jsonb_build_object(
    'id', p_order_id,
    'status', 'completed',
    'actual_yield', p_actual_yield,
    'finished_cost', v_new_cost
  );
end;
$$;

grant execute on function public.fn_production_order_complete(uuid, numeric, jsonb)
  to authenticated;

-- ---------------------------------------------------------------------------
-- 9. RPC fn_production_order_cancel
-- ---------------------------------------------------------------------------

create or replace function public.fn_production_order_cancel(
  p_order_id uuid,
  p_reason text default null
) returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_order public.production_orders;
  v_role text;
begin
  if p_order_id is null then
    raise exception 'ORDER_ID_REQUIRED';
  end if;

  select * into v_order from public.production_orders where id = p_order_id;
  if v_order.id is null then
    raise exception 'ORDER_NOT_FOUND';
  end if;

  v_role := public.user_business_role(auth.uid(), v_order.business_id);
  if coalesce(v_role, '') not in ('owner', 'admin', 'manager') then
    raise exception 'INSUFFICIENT_ROLE';
  end if;

  if v_order.status not in ('draft', 'in_progress') then
    raise exception 'INVALID_STATUS_TRANSITION: solo se puede cancelar desde draft o in_progress';
  end if;

  update public.production_orders
     set status = 'cancelled',
         cancelled_at = now(),
         cancelled_by = auth.uid(),
         cancellation_reason = nullif(btrim(coalesce(p_reason, '')), '')
   where id = p_order_id;

  return jsonb_build_object('id', p_order_id, 'status', 'cancelled');
end;
$$;

grant execute on function public.fn_production_order_cancel(uuid, text)
  to authenticated;

-- ---------------------------------------------------------------------------
-- 10. Vista helper: production_orders_summary
-- ---------------------------------------------------------------------------

create or replace view public.v_production_orders_summary
with (security_invoker = on) as
select
  po.id,
  po.business_id,
  po.code,
  po.status,
  po.planned_yield,
  po.actual_yield,
  po.finished_item_id,
  fi.name as finished_item_name,
  fi.unit as finished_item_unit,
  po.source_warehouse_id,
  sw.name as source_warehouse_name,
  po.destination_warehouse_id,
  dw.name as destination_warehouse_name,
  po.created_at,
  po.started_at,
  po.completed_at,
  po.cancelled_at,
  po.notes,
  po.cancellation_reason,
  (select count(*) from public.production_order_lines pol
    where pol.production_order_id = po.id) as lines_count
from public.production_orders po
join public.inventory_items fi on fi.id = po.finished_item_id
join public.warehouses sw on sw.id = po.source_warehouse_id
join public.warehouses dw on dw.id = po.destination_warehouse_id;

grant select on public.v_production_orders_summary to authenticated;

commit;
