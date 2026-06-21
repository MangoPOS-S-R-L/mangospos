-- 2026-06-19  Módulo de Reservas (add-on activado por plataforma)
--
-- Entrega:
--   1. business_modules  — entitlements de add-ons controlados por PLATAFORMA
--      (solo service_role / panel administrativo escribe; el negocio solo lee).
--   2. fn_business_module_enabled / fn_set_business_module  — helpers de gate.
--      Al activar 'reservations' se siembran los permisos reservas.* a los roles
--      owner/admin/manager de ESE negocio (autocontenido, sin tocar el seeder
--      monolítico fn_seed_business_rbac_defaults).
--   3. reservations  — reserva de una mesa específica para fecha/hora futura,
--      con anti doble-reserva por EXCLUDE constraint (btree_gist).
--   4. RPCs: crear / editar / sentar / cancelar / expirar (no-show).
--   5. Catálogo de permisos: reservas.acceso, reservas.gestionar.
--
-- Online-first (F1): el módulo NO entra a la cola offline. Idempotente.

-- ============================================================================
-- 1. business_modules — entitlements de add-ons (plataforma)
-- ============================================================================

create table if not exists public.business_modules (
  business_id uuid not null references public.businesses(id) on delete cascade,
  module      text not null,
  enabled     boolean not null default false,
  enabled_at  timestamptz,
  enabled_by  uuid,
  notes       text,
  created_at  timestamptz not null default now(),
  updated_at  timestamptz not null default now(),
  primary key (business_id, module)
);

alter table public.business_modules enable row level security;

-- Lectura: cualquier miembro del negocio puede consultar sus add-ons (el POS
-- necesita saber si el módulo está activo para mostrarlo).
drop policy if exists business_modules_select on public.business_modules;
create policy business_modules_select on public.business_modules
  for select to authenticated
  using (public.user_has_business_access(auth.uid(), business_id));

-- Escritura: PLATAFORMA únicamente. No hay policy de insert/update/delete para
-- `authenticated`, así que RLS niega por defecto → el dueño/admin del negocio NO
-- puede auto-activar el add-on. service_role (panel administrativo) sí, porque
-- bypassa RLS.
grant select on public.business_modules to authenticated;
grant all    on public.business_modules to service_role;

drop trigger if exists set_business_modules_updated_at on public.business_modules;
create trigger set_business_modules_updated_at
  before update on public.business_modules
  for each row execute function public.trigger_set_updated_at();

-- Helper: ¿el add-on está activo para el negocio? Usado por los RPCs como gate.
create or replace function public.fn_business_module_enabled(
  p_business_id uuid,
  p_module text
) returns boolean
language sql stable security definer set search_path = public
as $$
  select coalesce(
    (select enabled from public.business_modules
      where business_id = p_business_id and module = p_module),
    false);
$$;

grant execute on function public.fn_business_module_enabled(uuid, text) to authenticated, service_role;

-- Activador/desactivador del add-on (panel administrativo). SOLO service_role.
-- Al ACTIVAR 'reservations' siembra los permisos reservas.* a owner/admin/
-- manager del negocio para que aparezcan en el editor de roles y en el menú.
create or replace function public.fn_set_business_module(
  p_business_id uuid,
  p_module text,
  p_enabled boolean,
  p_enabled_by uuid default null,
  p_notes text default null
) returns public.business_modules
language plpgsql security definer set search_path = public
as $$
declare
  v_row public.business_modules;
begin
  insert into public.business_modules(business_id, module, enabled, enabled_at, enabled_by, notes)
  values (p_business_id, p_module, p_enabled,
          case when p_enabled then now() else null end, p_enabled_by, p_notes)
  on conflict (business_id, module) do update
    set enabled    = excluded.enabled,
        enabled_at = case when excluded.enabled then now() else null end,
        enabled_by = excluded.enabled_by,
        notes      = excluded.notes,
        updated_at = now()
  returning * into v_row;

  -- Auto-seed de permisos cuando se activa Reservas.
  if p_enabled and p_module = 'reservations' then
    insert into public.role_permissions (role_id, permission_id, allow)
    select r.id, p.id, true
    from public.roles r
    cross join public.permissions p
    where r.business_id = p_business_id
      and r.is_system = true
      and lower(r.name) in ('owner', 'admin', 'manager')
      and p.code in ('reservas.acceso', 'reservas.gestionar')
    on conflict (role_id, permission_id) do nothing;
  end if;

  return v_row;
end;
$$;

-- Restringido a plataforma: el negocio no puede llamarlo para auto-activarse.
revoke all on function public.fn_set_business_module(uuid, text, boolean, uuid, text) from public;
grant execute on function public.fn_set_business_module(uuid, text, boolean, uuid, text) to service_role;

-- ============================================================================
-- 2. Catálogo de permisos del módulo
-- ============================================================================

insert into public.permissions (code, name, module, description) values
  ('reservas.acceso', 'Acceso a Reservas', 'reservas',
   'Abre el módulo de reservas y la agenda del día.'),
  ('reservas.gestionar', 'Gestionar Reservas', 'reservas',
   'Crear, editar, sentar y cancelar reservas.')
on conflict (code) do update
  set name = excluded.name,
      module = excluded.module,
      description = excluded.description;

-- ============================================================================
-- 3. reservations — enum + tabla + índices + anti doble-reserva + RLS
-- ============================================================================

do $$ begin
  create type public.reservation_status as enum
    ('pending', 'confirmed', 'seated', 'completed', 'cancelled', 'no_show');
exception when duplicate_object then null; end $$;

create table if not exists public.reservations (
  id               uuid primary key default gen_random_uuid(),
  business_id      uuid not null references public.businesses(id) on delete cascade,
  -- branch_id queda como columna plana para paridad futura multi-sucursal
  -- (no existe tabla `branches`; igual que zones.branch_id, hoy sin uso).
  branch_id        uuid,
  table_id         uuid not null references public.dining_tables(id),
  customer_id      uuid references public.customers(id),
  customer_name    text not null,
  customer_phone   text,
  party_size       integer not null check (party_size > 0),
  reserved_for     timestamptz not null,
  duration_minutes integer not null default 90 check (duration_minutes > 0),
  status           public.reservation_status not null default 'confirmed',
  notes            text,
  session_id       uuid references public.table_sessions(id),
  created_by       uuid not null default auth.uid(),
  created_at       timestamptz not null default now(),
  updated_at       timestamptz not null default now(),
  -- Rango temporal materializado para el EXCLUDE. NO es columna generada:
  -- `timestamptz + interval` es STABLE (no IMMUTABLE) — depende del timezone de
  -- sesión — y Postgres rechaza expresiones no-inmutables en GENERATED ALWAYS
  -- (error 42P17). Se mantiene con el trigger BEFORE de abajo, que corre antes
  -- de que se evalúe el EXCLUDE.
  time_range       tstzrange
);

-- Mantiene time_range sincronizado con reserved_for/duration_minutes. BEFORE,
-- así que el valor ya está puesto cuando se chequea el EXCLUDE constraint.
create or replace function public.fn_reservations_set_time_range()
returns trigger
language plpgsql
as $$
begin
  new.time_range := tstzrange(
    new.reserved_for,
    new.reserved_for + make_interval(mins => new.duration_minutes));
  return new;
end;
$$;

drop trigger if exists set_reservations_time_range on public.reservations;
create trigger set_reservations_time_range
  before insert or update of reserved_for, duration_minutes
  on public.reservations
  for each row execute function public.fn_reservations_set_time_range();

create index if not exists idx_reservations_business_for
  on public.reservations (business_id, reserved_for);
create index if not exists idx_reservations_table_for
  on public.reservations (table_id, reserved_for);
create index if not exists idx_reservations_customer
  on public.reservations (customer_id);

-- Red de seguridad contra doble reserva (carreras): una mesa no puede tener dos
-- reservas ACTIVAS solapadas. La validación en el RPC traduce el error a un
-- mensaje amigable, pero el constraint es la garantía dura.
create extension if not exists btree_gist;
do $$ begin
  alter table public.reservations
    add constraint reservations_no_overlap
    exclude using gist (table_id with =, time_range with &&)
    where (status in ('pending', 'confirmed', 'seated'));
exception when duplicate_object then null; end $$;

alter table public.reservations enable row level security;

drop policy if exists reservations_select on public.reservations;
create policy reservations_select on public.reservations
  for select to authenticated
  using (public.user_has_business_access(auth.uid(), business_id));

-- Escrituras directas permitidas a miembros del negocio (consistente con el
-- resto del esquema); el gate de "módulo activo" vive en los RPCs SECURITY
-- DEFINER, que es por donde escribe la app.
drop policy if exists reservations_write on public.reservations;
create policy reservations_write on public.reservations
  for all to authenticated
  using (public.user_has_business_access(auth.uid(), business_id))
  with check (public.user_has_business_access(auth.uid(), business_id));

grant select, insert, update, delete on public.reservations to authenticated;
grant all on public.reservations to service_role;

drop trigger if exists set_reservations_updated_at on public.reservations;
create trigger set_reservations_updated_at
  before update on public.reservations
  for each row execute function public.trigger_set_updated_at();

-- ============================================================================
-- 4. RPCs
-- ============================================================================

-- Crear reserva. Gate: acceso al negocio + módulo activo. El choque de mesa lo
-- atrapa el EXCLUDE y se reporta como TABLE_ALREADY_RESERVED.
create or replace function public.fn_create_reservation(
  p_business_id uuid,
  p_table_id uuid,
  p_customer_name text,
  p_party_size int,
  p_reserved_for timestamptz,
  p_duration_minutes int default 90,
  p_customer_id uuid default null,
  p_customer_phone text default null,
  p_notes text default null
) returns public.reservations
language plpgsql security definer set search_path = public
as $$
declare
  v_row public.reservations;
begin
  if not public.user_has_business_access(auth.uid(), p_business_id) then
    raise exception 'NO_BUSINESS_ACCESS';
  end if;
  if not public.fn_business_module_enabled(p_business_id, 'reservations') then
    raise exception 'MODULE_NOT_ENABLED';
  end if;
  if coalesce(trim(p_customer_name), '') = '' then
    raise exception 'CUSTOMER_NAME_REQUIRED';
  end if;

  begin
    insert into public.reservations(
      business_id, table_id, customer_id, customer_name, customer_phone,
      party_size, reserved_for, duration_minutes, notes, created_by, status)
    values (
      p_business_id, p_table_id, p_customer_id, p_customer_name, p_customer_phone,
      greatest(1, p_party_size), p_reserved_for,
      greatest(1, coalesce(p_duration_minutes, 90)),
      p_notes, auth.uid(), 'confirmed')
    returning * into v_row;
  exception when exclusion_violation then
    raise exception 'TABLE_ALREADY_RESERVED';
  end;

  return v_row;
end;
$$;

grant execute on function public.fn_create_reservation(uuid, uuid, text, int, timestamptz, int, uuid, text, text) to authenticated;

-- Editar reserva. Bloqueada una vez sentada/completada/cancelada/no_show.
create or replace function public.fn_update_reservation(
  p_id uuid,
  p_table_id uuid,
  p_customer_name text,
  p_party_size int,
  p_reserved_for timestamptz,
  p_duration_minutes int default 90,
  p_customer_id uuid default null,
  p_customer_phone text default null,
  p_notes text default null
) returns public.reservations
language plpgsql security definer set search_path = public
as $$
declare
  v_row public.reservations;
begin
  select * into v_row from public.reservations where id = p_id for update;
  if not found then
    raise exception 'RESERVATION_NOT_FOUND';
  end if;
  if not public.user_has_business_access(auth.uid(), v_row.business_id) then
    raise exception 'NO_BUSINESS_ACCESS';
  end if;
  if v_row.status in ('seated', 'completed', 'cancelled', 'no_show') then
    raise exception 'RESERVATION_LOCKED';
  end if;

  begin
    update public.reservations set
      table_id = p_table_id,
      customer_name = p_customer_name,
      customer_phone = p_customer_phone,
      customer_id = p_customer_id,
      party_size = greatest(1, p_party_size),
      reserved_for = p_reserved_for,
      duration_minutes = greatest(1, coalesce(p_duration_minutes, 90)),
      notes = p_notes
    where id = p_id
    returning * into v_row;
  exception when exclusion_violation then
    raise exception 'TABLE_ALREADY_RESERVED';
  end;

  return v_row;
end;
$$;

grant execute on function public.fn_update_reservation(uuid, uuid, text, int, timestamptz, int, uuid, text, text) to authenticated;

-- Sentar reserva: reusa el camino dine-in existente (fn_open_table) para abrir
-- la sesión, copia el nombre del cliente y enlaza la reserva. Idempotente.
create or replace function public.fn_seat_reservation(p_id uuid)
returns jsonb
language plpgsql security definer set search_path = public
as $$
declare
  v_row     public.reservations;
  v_open    jsonb;
  v_session uuid;
begin
  select * into v_row from public.reservations where id = p_id for update;
  if not found then
    raise exception 'RESERVATION_NOT_FOUND';
  end if;
  if not public.user_has_business_access(auth.uid(), v_row.business_id) then
    raise exception 'NO_BUSINESS_ACCESS';
  end if;
  if v_row.status in ('cancelled', 'no_show') then
    raise exception 'RESERVATION_NOT_SEATABLE';
  end if;

  -- Ya sentada: idempotente, devuelve la sesión existente.
  if v_row.session_id is not null then
    return jsonb_build_object(
      'session_id', v_row.session_id,
      'reservation_id', v_row.id,
      'already', true);
  end if;

  v_open := public.fn_open_table(v_row.table_id, auth.uid(), v_row.party_size);
  v_session := (v_open->>'session_id')::uuid;

  update public.table_sessions
    set customer_name = coalesce(customer_name, v_row.customer_name)
    where id = v_session;

  update public.reservations
    set status = 'seated', session_id = v_session
    where id = p_id
    returning * into v_row;

  return jsonb_build_object(
    'session_id', v_session,
    'order_id', v_open->>'order_id',
    'reservation_id', v_row.id,
    'already', false);
end;
$$;

grant execute on function public.fn_seat_reservation(uuid) to authenticated;

-- Cancelar reserva. Opcional: anexa el motivo a las notas.
create or replace function public.fn_cancel_reservation(
  p_id uuid,
  p_reason text default null
) returns public.reservations
language plpgsql security definer set search_path = public
as $$
declare
  v_row public.reservations;
begin
  select * into v_row from public.reservations where id = p_id for update;
  if not found then
    raise exception 'RESERVATION_NOT_FOUND';
  end if;
  if not public.user_has_business_access(auth.uid(), v_row.business_id) then
    raise exception 'NO_BUSINESS_ACCESS';
  end if;

  update public.reservations
    set status = 'cancelled',
        notes = case
          when coalesce(trim(p_reason), '') = '' then notes
          else trim(both E'\n' from coalesce(notes, '') || E'\n[Cancelada] ' || p_reason)
        end
    where id = p_id
    returning * into v_row;

  return v_row;
end;
$$;

grant execute on function public.fn_cancel_reservation(uuid, text) to authenticated;

-- Marcar no-show las reservas confirmadas vencidas sin sentar. Para cron
-- (service_role). Devuelve cuántas marcó.
create or replace function public.fn_expire_overdue_reservations(
  p_grace_minutes int default 20
) returns int
language plpgsql security definer set search_path = public
as $$
declare
  v_count int;
begin
  update public.reservations
    set status = 'no_show'
    where status = 'confirmed'
      and session_id is null
      and reserved_for + make_interval(mins => greatest(0, coalesce(p_grace_minutes, 20))) < now();
  get diagnostics v_count = row_count;
  return v_count;
end;
$$;

grant execute on function public.fn_expire_overdue_reservations(int) to service_role;
