-- =============================================================================
-- Multimesero (Sprint Permisos+Trazabilidad): setup de columnas y funciones.
--
-- CONCEPTO:
--   Negocios con varios meseros operando un POS compartido. Cuando un mesero
--   abre/entra a una mesa, el sistema le pide PIN para identificarlo. Cada
--   item agregado registra quién lo agregó. El "dueño" de la mesa (el primero
--   que la abrió) nunca cambia.
--
--   Activación: toggle por negocio (`business_settings.multimesero_enabled`).
--   Si está OFF, el comportamiento queda igual a hoy.
--
-- ENTREGA:
--   1. `business_settings.multimesero_enabled BOOLEAN DEFAULT false`.
--   2. `table_sessions.opened_by_employee_id UUID` (nullable, FK employees).
--   3. `order_items.created_by_employee_id UUID` (nullable, FK employees).
--   4. UNIQUE partial index en `employees(business_id, pin)` para empleados
--      activos con pin no-vacío. Inactivos pueden tener pin null o duplicado
--      (no afectan al sistema porque no operan).
--   5. `fn_open_table` modificada: nuevo parámetro opcional
--      `p_opened_by_employee_id` (default null). Backwards compatible.
--   6. RPC `fn_verify_employee_pin(business_id, pin)` que devuelve el
--      employee si el PIN es válido (validado contra business membership).
--
-- IMPACTO EN PRODUCCIÓN:
--   ⚠️ Negocios con PINs duplicados van a fallar al aplicar el UNIQUE index.
--   Antes de correr esta migration, asegurate de haber corrido el script de
--   limpieza de duplicados.
--
--   ⚠️ Negocios con `multimesero_enabled=false` (todos al aplicar esta
--   migration, default false) NO van a notar ningún cambio operativo.
--
-- IDEMPOTENTE:
--   - ADD COLUMN IF NOT EXISTS, CREATE UNIQUE INDEX IF NOT EXISTS.
--   - DROP FUNCTION + CREATE para fn_open_table (signature cambia, hay que
--     dropear primero).
--   - CREATE OR REPLACE para fn_verify_employee_pin.
-- =============================================================================

begin;

-- ---------------------------------------------------------------------------
-- 1. business_settings.multimesero_enabled
-- ---------------------------------------------------------------------------

alter table public.business_settings
  add column if not exists multimesero_enabled boolean not null default false;

comment on column public.business_settings.multimesero_enabled is
  'Si true, al abrir/entrar a una mesa el sistema pide PIN del mesero. '
  'Cada item agregado se atribuye al mesero validado. La mesa conserva '
  'su mesero "dueño" (opened_by_employee_id) aunque otros le agreguen items.';

-- ---------------------------------------------------------------------------
-- 2. table_sessions.opened_by_employee_id
-- ---------------------------------------------------------------------------

alter table public.table_sessions
  add column if not exists opened_by_employee_id uuid;

-- FK (idempotente)
do $$
begin
  if not exists (
    select 1 from pg_constraint
    where conname = 'table_sessions_opened_by_employee_fk'
  ) then
    alter table public.table_sessions
      add constraint table_sessions_opened_by_employee_fk
      foreign key (opened_by_employee_id)
      references public.employees(id)
      on delete set null;
  end if;
end $$;

create index if not exists idx_table_sessions_opened_by_employee
  on public.table_sessions (opened_by_employee_id)
  where opened_by_employee_id is not null;

comment on column public.table_sessions.opened_by_employee_id is
  'Empleado (mesero) que abrió la mesa. Null si el negocio no está en modo '
  'multimesero o si la mesa se abrió antes del feature. Distinto de '
  '`opened_by` (auth.users.id del cajero/owner del dispositivo).';

-- ---------------------------------------------------------------------------
-- 3. order_items.created_by_employee_id
-- ---------------------------------------------------------------------------

alter table public.order_items
  add column if not exists created_by_employee_id uuid;

do $$
begin
  if not exists (
    select 1 from pg_constraint
    where conname = 'order_items_created_by_employee_fk'
  ) then
    alter table public.order_items
      add constraint order_items_created_by_employee_fk
      foreign key (created_by_employee_id)
      references public.employees(id)
      on delete set null;
  end if;
end $$;

create index if not exists idx_order_items_created_by_employee
  on public.order_items (created_by_employee_id)
  where created_by_employee_id is not null;

comment on column public.order_items.created_by_employee_id is
  'Empleado que agregó esta línea a la orden. Solo se setea cuando el '
  'negocio está en modo multimesero. Permite trazabilidad por línea para '
  'reportes de "qué mesero vendió qué".';

-- ---------------------------------------------------------------------------
-- 4. UNIQUE partial index en employees(business_id, pin)
--    Solo afecta empleados activos con PIN no-vacío. Los inactivos
--    pueden tener PIN duplicado o NULL.
-- ---------------------------------------------------------------------------

create unique index if not exists employees_business_pin_unique
  on public.employees (business_id, pin)
  where pin is not null
    and length(trim(pin)) > 0
    and status = 'active';

comment on index public.employees_business_pin_unique is
  'PINs únicos dentro de un mismo business para empleados activos. '
  'Necesario para el modo multimesero donde el PIN identifica al mesero.';

-- ---------------------------------------------------------------------------
-- 5. fn_open_table: agregar p_opened_by_employee_id (opcional)
--    Mantengo backwards compat: callers que no pasen el nuevo param siguen
--    funcionando, y `opened_by_employee_id` queda null en esos casos.
-- ---------------------------------------------------------------------------

drop function if exists public.fn_open_table(uuid, uuid, integer);
drop function if exists public.fn_open_table(uuid, uuid, integer, uuid);

create function public.fn_open_table(
  p_table_id uuid,
  p_user_id uuid,
  p_people_count integer default 1,
  p_opened_by_employee_id uuid default null
)
returns jsonb
language plpgsql
security definer
set search_path=public
as $$
declare
  v_session_id uuid;
  v_order_id uuid;
  v_user_id uuid;
  v_business_id uuid;
begin
  if p_table_id is null then
    raise exception 'TABLE_ID_REQUIRED';
  end if;

  if auth.uid() is not null and p_user_id is not null and p_user_id <> auth.uid() then
    raise exception 'INVALID_USER_CONTEXT';
  end if;

  v_user_id := coalesce(auth.uid(), p_user_id);

  if v_user_id is null then
    raise exception 'USER_REQUIRED';
  end if;

  -- Validar que el empleado pertenece al business de la mesa si se pasó.
  if p_opened_by_employee_id is not null then
    select z.business_id
      into v_business_id
    from public.dining_tables t
    join public.zones z on z.id = t.zone_id
    where t.id = p_table_id;

    if v_business_id is null then
      raise exception 'TABLE_BUSINESS_NOT_FOUND';
    end if;

    if not exists (
      select 1 from public.employees e
      where e.id = p_opened_by_employee_id
        and e.business_id = v_business_id
        and e.status = 'active'
    ) then
      raise exception 'EMPLOYEE_NOT_IN_BUSINESS';
    end if;
  end if;

  perform public.fn_require_open_cash_session(v_user_id);

  -- Serialize by table to avoid double-open races.
  perform pg_advisory_xact_lock(hashtextextended(p_table_id::text, 0));

  select ts.id
    into v_session_id
  from public.table_sessions ts
  where ts.table_id = p_table_id
    and ts.closed_at is null
  order by ts.opened_at desc
  limit 1;

  if v_session_id is null then
    insert into public.table_sessions (
      table_id, opened_by, origin, waiter_user_id, people_count,
      opened_by_employee_id
    )
    values (
      p_table_id, v_user_id, 'dine_in', v_user_id,
      greatest(1, coalesce(p_people_count, 1)),
      p_opened_by_employee_id
    )
    returning id into v_session_id;
  end if;

  update public.dining_tables
     set state = 'occupied'
   where id = p_table_id
     and state is distinct from 'occupied';

  select o.id
    into v_order_id
  from public.orders o
  where o.session_id = v_session_id
    and o.closed_at is null
    and o.status_ext not in ('paid', 'void')
  order by o.created_at desc
  limit 1;

  if v_order_id is null then
    insert into public.orders (session_id, status_ext, subtotal, discounts, tax, total, total_amount)
    values (v_session_id, 'open', 0, 0, 0, 0, 0)
    returning id into v_order_id;

    insert into public.order_checks (order_id, label, position)
    values (v_order_id, 'C1', 1)
    on conflict (order_id, position) do nothing;
  end if;

  return jsonb_build_object('session_id', v_session_id, 'order_id', v_order_id);
end;
$$;

grant execute on function public.fn_open_table(uuid, uuid, integer, uuid)
  to authenticated;

-- ---------------------------------------------------------------------------
-- 6. fn_verify_employee_pin: valida PIN y devuelve el empleado.
--
--    SEGURIDAD: el caller debe pertenecer al business (chequeado via
--    user_has_business_access). El PIN se compara en texto plano contra
--    employees.pin (que NO está hasheado — tema de seguridad fuera del
--    alcance de este feature; cuando se hashee, esta RPC debe actualizarse).
--
--    LIMITACIÓN: no hay ratelimit. Un usuario malicioso del business podría
--    forzar PINs (9000 posibles). Mitigación futura: contador de intentos
--    fallidos por user_id en una tabla auxiliar.
-- ---------------------------------------------------------------------------

create or replace function public.fn_verify_employee_pin(
  p_business_id uuid,
  p_pin text
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_employee record;
begin
  if p_business_id is null or p_pin is null or length(trim(p_pin)) = 0 then
    return null;
  end if;

  -- El caller debe pertenecer al business. Sin esto, cualquier autenticado
  -- podría sondear PINs de cualquier negocio.
  if not public.user_has_business_access(auth.uid(), p_business_id) then
    raise exception 'UNAUTHORIZED_BUSINESS';
  end if;

  select e.id, e.first_name, e.last_name, e.business_id, e.user_id
    into v_employee
  from public.employees e
  where e.business_id = p_business_id
    and e.pin = trim(p_pin)
    and e.status = 'active'
  limit 1;

  if v_employee.id is null then
    return null;
  end if;

  return jsonb_build_object(
    'employee_id', v_employee.id,
    'first_name', v_employee.first_name,
    'last_name', v_employee.last_name,
    'business_id', v_employee.business_id,
    'user_id', v_employee.user_id
  );
end;
$$;

grant execute on function public.fn_verify_employee_pin(uuid, text)
  to authenticated;

comment on function public.fn_verify_employee_pin(uuid, text) is
  'Valida un PIN contra los empleados activos de un business. Retorna el '
  'employee (jsonb) si match, NULL si no. Requiere que el caller pertenezca '
  'al business. Usado por el modo multimesero para identificar al mesero '
  'que opera una mesa.';

commit;
