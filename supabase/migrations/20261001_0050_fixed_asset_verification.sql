-- =============================================================================
-- 20261001_0050 — Activos fijos: cantidad, el código de la etiqueta que ya
-- tienen, y el VERIFICADOR (levantamiento físico por ubicación).
--
-- Numerada en el rango 0050+ a propósito (el dueño y el asistente trabajan en
-- paralelo y los dos contaban desde 0001). Va DESPUÉS de 20260930_0052 y no la
-- edita: la 0052 pudo haberse aplicado ya.
--
-- PEDIDO DEL DUEÑO (2026-10-01): «actualmente están etiquetados ya; que sea un
-- verificador de activos, pero que me permita crearlos y decir la cantidad que
-- hay y su valor».
--
-- QUÉ CAMBIA EN LA FICHA:
--   · `quantity`: un registro puede ser un GRUPO con una sola etiqueta («Silla
--     de madera ×40») o una pieza («Horno ×1»). purchase_cost pasa a leerse
--     como VALOR UNITARIO (lo que costó o lo que vale hoy); el valor del
--     registro es quantity × purchase_cost.
--   · `code`: la persona puede escribir el código de SU etiqueta. Vacío = el
--     servidor asigna AF-00001 como hasta ahora. Único por negocio SIN
--     distinguir mayúsculas (la pistola y el teclado no siempre coinciden).
--   · Un cambio de cantidad deja su propio evento (`quantity_changed`, con el
--     antes y el después) en vez de perderse dentro de «editado».
--   · `last_verified_at`: cuándo se vio por última vez en una verificación.
--
-- EL VERIFICADOR (por qué no es el Conteo físico de inventario): en un insumo
-- se cuenta CUÁNTOS hay; en un activo se confirma SI está cada uno, dónde y
-- cómo. Al abrir una verificación de una ubicación se congela la lista de lo
-- que DEBERÍA estar ahí; se escanea o se marca lo que se encuentra (con la
-- cantidad, para los grupos), se registra en el acto lo que no estaba dado de
-- alta, y al cerrar se DECIDE —nada se aplica solo— qué hacer con lo que
-- faltó (pendiente de búsqueda o perdido), lo que sobró, lo que estaba en otra
-- ubicación y lo que se vio en otro estado.
--
-- RPC NUEVOS (SECURITY DEFINER; escribir pide owner/admin/manager o
-- `inventario.activos.gestionar`, igual que el resto del módulo):
--   fn_fixed_asset_verification_start(p_business_id, p_warehouse_id, p_notes)
--        p_warehouse_id null = todas las ubicaciones. Si ya hay una ABIERTA del
--        mismo alcance la devuelve (`resumed: true`) en vez de fallar.
--   fn_fixed_asset_verification_check(p_verification_id, p_asset_id,
--        p_found_qty, p_observed_status, p_notes)
--        FIJA lo encontrado (no suma): repetirlo no cuenta dos veces. Un activo
--        de otra ubicación entra como «fuera de lugar». p_observed_status null
--        conserva lo anotado; igual al estado actual del activo = «sin cambio».
--   fn_fixed_asset_verification_uncheck(p_verification_id, p_asset_id)
--   fn_fixed_asset_verification_add_asset(p_verification_id, p_data)
--        Alta en el acto (mismo p_data que fn_fixed_asset_create), ubicada en
--        la bodega de la verificación.
--   fn_fixed_asset_verification_close(p_verification_id, p_decisions, p_notes)
--        p_decisions = [{asset_id, action}], action ∈ mark_lost | set_quantity
--        | move_here | apply_condition. Lo que no tiene decisión queda como
--        está («pendiente»). Todo lo encontrado queda verificado con su
--        evento en la historia.
--   fn_fixed_asset_verification_cancel(p_verification_id, p_reason)
--
-- CONTRATO DE ERRORES (además de los de 0052):
--   FIXED_ASSET_CODE_TAKEN, FIXED_ASSET_INVALID_CODE,
--   FIXED_ASSET_INVALID_QUANTITY, FIXED_ASSET_VERIFICATION_NOT_FOUND,
--   FIXED_ASSET_VERIFICATION_NOT_OPEN, FIXED_ASSET_VERIFICATION_IS_NEW,
--   FIXED_ASSET_VERIFICATION_BAD_DECISION,
--   FIXED_ASSET_VERIFICATION_REASON_REQUIRED.
--
-- ANTES DE APLICAR: la 0052 tiene que estar aplicada
--   select to_regclass('public.fixed_assets') is not null;
--
-- IDEMPOTENTE: sí. REVERSIBLE: sí (_ROLLBACK, generado por script desde la
-- 0052; se niega si ya hay grupos con cantidad > 1 o verificaciones).
-- =============================================================================

begin;

set local lock_timeout = '5s';

-- ---------------------------------------------------------------------------
-- 1. La ficha: cantidad, código propio, última verificación
-- ---------------------------------------------------------------------------

alter table public.fixed_assets
  add column if not exists quantity integer not null default 1,
  add column if not exists last_verified_at timestamptz,
  add column if not exists last_verification_id uuid;

do $$
begin
  if not exists (
    select 1 from pg_constraint
     where conname = 'fixed_assets_quantity_positive'
       and conrelid = 'public.fixed_assets'::regclass
  ) then
    alter table public.fixed_assets
      add constraint fixed_assets_quantity_positive check (quantity >= 1);
  end if;
end
$$;

-- El código de la etiqueta, único por negocio sin distinguir mayúsculas:
-- «mb-001» escrito a mano y «MB-001» de la pistola son la misma silla.
create unique index if not exists uq_fixed_assets_business_code_ci
  on public.fixed_assets (business_id, lower(code));

comment on column public.fixed_assets.quantity is
  'Unidades del registro: 1 para una pieza, N para un grupo con una sola '
  'etiqueta (40 sillas). Valor del registro = quantity × purchase_cost.';
comment on column public.fixed_assets.purchase_cost is
  'Valor UNITARIO: lo que costó o lo que vale hoy. El valor del registro es '
  'quantity × purchase_cost. Sin depreciación.';
comment on column public.fixed_assets.code is
  'Código de la etiqueta. El de la persona si lo escribió; si no, AF-00001 '
  'del servidor. Único por negocio sin distinguir mayúsculas.';

-- ---------------------------------------------------------------------------
-- 2. La historia: cantidad y verificación
-- ---------------------------------------------------------------------------

alter table public.fixed_asset_movements
  add column if not exists from_quantity integer,
  add column if not exists to_quantity integer,
  add column if not exists verification_id uuid;

alter table public.fixed_asset_movements
  drop constraint if exists fixed_asset_movements_event_type_check;
alter table public.fixed_asset_movements
  add constraint fixed_asset_movements_event_type_check
  check (event_type in ('created','updated','relocated','reassigned',
                        'status_changed','retired','reactivated',
                        'quantity_changed','verified'));

-- ---------------------------------------------------------------------------
-- 3. Las verificaciones
-- ---------------------------------------------------------------------------

create table if not exists public.fixed_asset_verifications (
  id              uuid primary key default gen_random_uuid(),
  business_id     uuid not null references public.businesses(id) on delete cascade,
  -- #1, #2, #3… por negocio: es como se nombra en el acta.
  number          integer not null,
  -- null = todas las ubicaciones.
  warehouse_id    uuid references public.warehouses(id) on delete set null,
  warehouse_name  text not null,
  status          text not null default 'open'
                    check (status in ('open','closed','cancelled')),
  notes           text,
  started_by      uuid references auth.users(id) on delete set null,
  started_by_name text,
  started_at      timestamptz not null default now(),
  closed_by       uuid references auth.users(id) on delete set null,
  closed_by_name  text,
  closed_at       timestamptz,
  cancel_reason   text,
  -- Al cerrar: los números del acta, congelados.
  summary         jsonb,
  constraint fixed_asset_verifications_number_unique unique (business_id, number)
);

-- Una sola ABIERTA por alcance: dos tabletas abriendo «Cocina» a la vez
-- caen en la misma.
create unique index if not exists uq_fixed_asset_verifications_open_scope
  on public.fixed_asset_verifications (
    business_id,
    coalesce(warehouse_id, '00000000-0000-0000-0000-000000000000'::uuid))
  where status = 'open';
create index if not exists idx_fixed_asset_verifications_business
  on public.fixed_asset_verifications (business_id, started_at desc);

create table if not exists public.fixed_asset_verification_lines (
  id                        uuid primary key default gen_random_uuid(),
  verification_id           uuid not null
                              references public.fixed_asset_verifications(id)
                              on delete cascade,
  business_id               uuid not null
                              references public.businesses(id) on delete cascade,
  asset_id                  uuid not null
                              references public.fixed_assets(id) on delete cascade,
  -- Fotos al crear la línea: el acta no cambia si mañana se edita la ficha.
  asset_code                text not null,
  asset_name                text not null,
  unit_value                numeric(14,2),
  registered_warehouse_id   uuid references public.warehouses(id) on delete set null,
  registered_warehouse_name text,
  -- Estaba en la lista de la ubicación al abrir.
  expected                  boolean not null,
  expected_qty              integer,
  -- null = sin revisar; 0 = «no está».
  found_qty                 integer check (found_qty is null or found_qty >= 0),
  expected_status           text,
  -- Estado VISTO, si difiere del registrado. null = sin cambio.
  observed_status           text
                              check (observed_status is null or observed_status in
                                ('active','needs_repair','in_repair','damaged','lost')),
  is_new                    boolean not null default false,
  notes                     text,
  checked_by                uuid references auth.users(id) on delete set null,
  checked_by_name           text,
  checked_at                timestamptz,
  resolution                text
                              check (resolution is null or resolution in
                                ('ok','pending','lost','quantity_set','moved','new')),
  condition_applied         boolean not null default false,
  created_at                timestamptz not null default now(),
  constraint fixed_asset_verification_lines_unique unique (verification_id, asset_id)
);

create index if not exists idx_fixed_asset_verification_lines_ver
  on public.fixed_asset_verification_lines (verification_id);
create index if not exists idx_fixed_asset_verification_lines_asset
  on public.fixed_asset_verification_lines (asset_id);

do $$
begin
  if not exists (
    select 1 from pg_constraint
     where conname = 'fixed_assets_last_verification_fkey'
       and conrelid = 'public.fixed_assets'::regclass
  ) then
    alter table public.fixed_assets
      add constraint fixed_assets_last_verification_fkey
      foreign key (last_verification_id)
      references public.fixed_asset_verifications(id) on delete set null;
  end if;
end
$$;

comment on table public.fixed_asset_verifications is
  'Verificación física de activos fijos por ubicación (o de todas). Se '
  'escribe solo con fn_fixed_asset_verification_*. 20261001_0050.';
comment on table public.fixed_asset_verification_lines is
  'Un activo dentro de una verificación: esperado vs encontrado, estado visto '
  'y qué se decidió al cerrar. 20261001_0050.';

alter table public.fixed_asset_verifications enable row level security;
alter table public.fixed_asset_verification_lines enable row level security;

drop policy if exists fixed_asset_verifications_select
  on public.fixed_asset_verifications;
create policy fixed_asset_verifications_select
  on public.fixed_asset_verifications
  for select to authenticated
  using (public.user_has_business_access(auth.uid(), business_id));

drop policy if exists fixed_asset_verification_lines_select
  on public.fixed_asset_verification_lines;
create policy fixed_asset_verification_lines_select
  on public.fixed_asset_verification_lines
  for select to authenticated
  using (public.user_has_business_access(auth.uid(), business_id));

grant select on public.fixed_asset_verifications to authenticated;
grant select on public.fixed_asset_verification_lines to authenticated;

-- ---------------------------------------------------------------------------
-- 4. Historia con cantidad y verificación
-- ---------------------------------------------------------------------------
-- Firma nueva (+3 parámetros). Se quita la vieja: dos versiones con nombre y
-- parámetros con default hacen ambigua cualquier llamada por nombre.

drop function if exists public.fn_fixed_asset_log(
  uuid, uuid, text, uuid, uuid, text, text, uuid, uuid, text, text, text, jsonb);

create or replace function public.fn_fixed_asset_log(
  p_asset_id          uuid,
  p_business_id       uuid,
  p_event_type        text,
  p_from_warehouse_id uuid default null,
  p_to_warehouse_id   uuid default null,
  p_from_location     text default null,
  p_to_location       text default null,
  p_from_employee_id  uuid default null,
  p_to_employee_id    uuid default null,
  p_from_status       text default null,
  p_to_status         text default null,
  p_notes             text default null,
  p_changes           jsonb default null,
  p_from_quantity     integer default null,
  p_to_quantity       integer default null,
  p_verification_id   uuid default null
) returns void
language sql
volatile
set search_path = public
as $$
  insert into public.fixed_asset_movements (
    asset_id, business_id, event_type,
    from_warehouse_id, to_warehouse_id, from_warehouse_name, to_warehouse_name,
    from_location_note, to_location_note,
    from_employee_id, to_employee_id, from_employee_name, to_employee_name,
    from_status, to_status, changes, notes, created_by, created_by_name,
    from_quantity, to_quantity, verification_id,
    created_at
  ) values (
    p_asset_id, p_business_id, p_event_type,
    p_from_warehouse_id, p_to_warehouse_id,
    (select w.name from public.warehouses w where w.id = p_from_warehouse_id),
    (select w.name from public.warehouses w where w.id = p_to_warehouse_id),
    p_from_location, p_to_location,
    p_from_employee_id, p_to_employee_id,
    (select nullif(btrim(concat_ws(' ', e.first_name, e.last_name)), '')
       from public.employees e where e.id = p_from_employee_id),
    (select nullif(btrim(concat_ws(' ', e.first_name, e.last_name)), '')
       from public.employees e where e.id = p_to_employee_id),
    p_from_status, p_to_status, p_changes,
    nullif(btrim(coalesce(p_notes, '')), ''),
    auth.uid(),
    public.fn_fixed_asset_actor_name(p_business_id),
    p_from_quantity, p_to_quantity, p_verification_id,
    clock_timestamp()
  );
$$;

revoke all on function public.fn_fixed_asset_log(
  uuid, uuid, text, uuid, uuid, text, text, uuid, uuid, text, text, text, jsonb,
  integer, integer, uuid)
  from public, anon, authenticated;

-- Cantidad y código que vienen en p_data. Las dos funciones de abajo (alta y
-- edición) las leen igual.
create or replace function public.fn_fixed_asset_parse_quantity(p_raw text)
returns integer
language plpgsql
immutable
set search_path = public
as $$
declare
  v numeric;
begin
  if p_raw is null or btrim(p_raw) = '' then
    return null;
  end if;
  begin
    v := btrim(p_raw)::numeric;
  exception when others then
    raise exception 'FIXED_ASSET_INVALID_QUANTITY';
  end;
  if v < 1 or v <> trunc(v) or v > 2147483647 then
    raise exception 'FIXED_ASSET_INVALID_QUANTITY';
  end if;
  return v::integer;
end;
$$;

-- ¿Ese código ya lo usa OTRO activo del negocio? Sin distinguir mayúsculas.
create or replace function public.fn_fixed_asset_check_code(
  p_business_id uuid,
  p_code        text,
  p_except_id   uuid
) returns void
language plpgsql
stable
security definer
set search_path = public
as $$
begin
  if length(p_code) > 40 then
    raise exception 'FIXED_ASSET_INVALID_CODE';
  end if;
  if exists (
    select 1 from public.fixed_assets a
     where a.business_id = p_business_id
       and lower(a.code) = lower(p_code)
       and a.id is distinct from p_except_id
  ) then
    raise exception 'FIXED_ASSET_CODE_TAKEN';
  end if;
end;
$$;

revoke all on function public.fn_fixed_asset_parse_quantity(text)
  from public, anon, authenticated;
revoke all on function public.fn_fixed_asset_check_code(uuid, text, uuid)
  from public, anon, authenticated;

-- ---------------------------------------------------------------------------
-- 5. Alta: código propio y cantidad
-- ---------------------------------------------------------------------------

create or replace function public.fn_fixed_asset_create(
  p_business_id uuid,
  p_data        jsonb
) returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_data    jsonb := coalesce(p_data, '{}'::jsonb);
  v_asset   public.fixed_assets;
  v_request uuid := nullif(btrim(coalesce(v_data->>'client_request_id', '')), '')::uuid;
  v_name    text := nullif(btrim(coalesce(v_data->>'name', '')), '');
  v_code    text := nullif(btrim(coalesce(v_data->>'code', '')), '');
  v_status  text := coalesce(nullif(btrim(coalesce(v_data->>'status', '')), ''), 'active');
  v_cost    numeric := nullif(btrim(coalesce(v_data->>'purchase_cost', '')), '')::numeric;
  v_wh      uuid := nullif(btrim(coalesce(v_data->>'warehouse_id', '')), '')::uuid;
  v_emp     uuid := nullif(btrim(coalesce(v_data->>'assigned_employee_id', '')), '')::uuid;
  v_qty     integer := coalesce(public.fn_fixed_asset_parse_quantity(v_data->>'quantity'), 1);
  v_seq     bigint;
begin
  if p_business_id is null then
    raise exception 'MISSING_REQUIRED_PARAMS';
  end if;
  if not public.user_has_business_access(auth.uid(), p_business_id) then
    raise exception 'NOT_AUTHORIZED';
  end if;
  if not public.fn_fixed_asset_can_manage(p_business_id) then
    raise exception 'FIXED_ASSET_DENIED';
  end if;
  if v_name is null then
    raise exception 'FIXED_ASSET_NAME_REQUIRED';
  end if;
  -- Nadie da de alta algo ya dado de baja: eso es otro flujo.
  if v_status not in ('active','needs_repair','in_repair','damaged','lost') then
    raise exception 'FIXED_ASSET_INVALID_STATUS';
  end if;
  if v_cost is not null and v_cost < 0 then
    raise exception 'FIXED_ASSET_INVALID_COST';
  end if;
  perform public.fn_fixed_asset_check_refs(p_business_id, v_wh, v_emp);

  -- Numeración y códigos: candado por negocio. El reintento se busca DESPUÉS
  -- de tomarlo, para que dos envíos del mismo formulario se serialicen y el
  -- segundo encuentre al primero ya confirmado.
  perform pg_advisory_xact_lock(
    hashtextextended(p_business_id::text || ':fixed_asset_code', 0));

  if v_request is not null then
    select * into v_asset
      from public.fixed_assets
     where business_id = p_business_id and client_request_id = v_request;
    if v_asset.id is not null then
      return public.fn_fixed_asset_to_json(v_asset);
    end if;
  end if;

  if v_code is not null then
    perform public.fn_fixed_asset_check_code(p_business_id, v_code, null);
  else
    -- El cast adentro del max: AF-100000 no pierde contra AF-99999 comparando
    -- como texto. Y el lpad con largo mínimo: lpad('100000', 5) RECORTA a
    -- '10000' y repetiría un código. Sin distinguir mayúsculas: un «af-00007»
    -- escrito a mano también ocupa su número.
    select coalesce(max(substring(code from 4)::bigint), 0) + 1
      into v_seq
      from public.fixed_assets
     where business_id = p_business_id
       and code ~* '^AF-[0-9]+$';
    v_code := 'AF-' || lpad(v_seq::text, greatest(5, length(v_seq::text)), '0');
  end if;

  begin
    insert into public.fixed_assets (
      business_id, code, name, category, brand, model, serial_number,
      purchase_date, purchase_cost, supplier_name, warranty_until,
      warehouse_id, location_note, assigned_employee_id, status, notes,
      quantity, client_request_id, created_by
    ) values (
      p_business_id,
      v_code,
      v_name,
      nullif(btrim(coalesce(v_data->>'category', '')), ''),
      nullif(btrim(coalesce(v_data->>'brand', '')), ''),
      nullif(btrim(coalesce(v_data->>'model', '')), ''),
      nullif(btrim(coalesce(v_data->>'serial_number', '')), ''),
      nullif(btrim(coalesce(v_data->>'purchase_date', '')), '')::date,
      v_cost,
      nullif(btrim(coalesce(v_data->>'supplier_name', '')), ''),
      nullif(btrim(coalesce(v_data->>'warranty_until', '')), '')::date,
      v_wh,
      nullif(btrim(coalesce(v_data->>'location_note', '')), ''),
      v_emp,
      v_status,
      nullif(btrim(coalesce(v_data->>'notes', '')), ''),
      v_qty,
      v_request,
      auth.uid()
    ) returning * into v_asset;
  exception when unique_violation then
    -- Otro alta con el mismo código entre la revisión y el insert.
    raise exception 'FIXED_ASSET_CODE_TAKEN';
  end;

  perform public.fn_fixed_asset_log(
    p_asset_id        => v_asset.id,
    p_business_id     => p_business_id,
    p_event_type      => 'created',
    p_to_warehouse_id => v_asset.warehouse_id,
    p_to_location     => v_asset.location_note,
    p_to_employee_id  => v_asset.assigned_employee_id,
    p_to_status       => v_asset.status,
    p_to_quantity     => v_asset.quantity
  );

  return public.fn_fixed_asset_to_json(v_asset);
end;
$$;

-- ---------------------------------------------------------------------------
-- 6. Edición: + código y cantidad
-- ---------------------------------------------------------------------------
-- p_data: solo las claves que vienen se tocan (una clave con null la borra).
-- `quantity` deja su propio evento con `change_note` como motivo. Ubicación,
-- responsable y estado se IGNORAN: tienen su RPC y su evento.

create or replace function public.fn_fixed_asset_update(
  p_asset_id uuid,
  p_data     jsonb
) returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_data    jsonb := coalesce(p_data, '{}'::jsonb);
  v_old     public.fixed_assets;
  v_new     public.fixed_assets;
  v_changes jsonb;
  v_qty     integer;
begin
  if p_asset_id is null then
    raise exception 'MISSING_REQUIRED_PARAMS';
  end if;

  select * into v_old from public.fixed_assets where id = p_asset_id for update;
  if v_old.id is null then
    raise exception 'FIXED_ASSET_NOT_FOUND';
  end if;
  if not public.user_has_business_access(auth.uid(), v_old.business_id) then
    raise exception 'NOT_AUTHORIZED';
  end if;
  if not public.fn_fixed_asset_can_manage(v_old.business_id) then
    raise exception 'FIXED_ASSET_DENIED';
  end if;

  v_new := v_old;
  if v_data ? 'name' then
    v_new.name := nullif(btrim(coalesce(v_data->>'name', '')), '');
    if v_new.name is null then
      raise exception 'FIXED_ASSET_NAME_REQUIRED';
    end if;
  end if;
  if v_data ? 'code' then
    -- Vacío = se queda el que tiene: un activo nunca se queda sin código.
    v_new.code := coalesce(nullif(btrim(coalesce(v_data->>'code', '')), ''), v_old.code);
    if v_new.code is distinct from v_old.code then
      perform public.fn_fixed_asset_check_code(v_old.business_id, v_new.code, v_old.id);
    end if;
  end if;
  if v_data ? 'category' then
    v_new.category := nullif(btrim(coalesce(v_data->>'category', '')), '');
  end if;
  if v_data ? 'brand' then
    v_new.brand := nullif(btrim(coalesce(v_data->>'brand', '')), '');
  end if;
  if v_data ? 'model' then
    v_new.model := nullif(btrim(coalesce(v_data->>'model', '')), '');
  end if;
  if v_data ? 'serial_number' then
    v_new.serial_number :=
      nullif(btrim(coalesce(v_data->>'serial_number', '')), '');
  end if;
  if v_data ? 'purchase_date' then
    v_new.purchase_date :=
      nullif(btrim(coalesce(v_data->>'purchase_date', '')), '')::date;
  end if;
  if v_data ? 'purchase_cost' then
    v_new.purchase_cost :=
      nullif(btrim(coalesce(v_data->>'purchase_cost', '')), '')::numeric;
    if v_new.purchase_cost is not null and v_new.purchase_cost < 0 then
      raise exception 'FIXED_ASSET_INVALID_COST';
    end if;
  end if;
  if v_data ? 'supplier_name' then
    v_new.supplier_name :=
      nullif(btrim(coalesce(v_data->>'supplier_name', '')), '');
  end if;
  if v_data ? 'warranty_until' then
    v_new.warranty_until :=
      nullif(btrim(coalesce(v_data->>'warranty_until', '')), '')::date;
  end if;
  if v_data ? 'notes' then
    v_new.notes := nullif(btrim(coalesce(v_data->>'notes', '')), '');
  end if;
  if v_data ? 'quantity' then
    v_qty := public.fn_fixed_asset_parse_quantity(v_data->>'quantity');
    if v_qty is null then
      raise exception 'FIXED_ASSET_INVALID_QUANTITY';
    end if;
    v_new.quantity := v_qty;
  end if;

  -- Qué cambió, campo por campo (la cantidad va aparte, con su evento).
  select coalesce(
           jsonb_object_agg(n.key, jsonb_build_object('from', o.value,
                                                      'to', n.value)),
           '{}'::jsonb)
    into v_changes
    from jsonb_each(to_jsonb(v_new)) n
    join jsonb_each(to_jsonb(v_old)) o using (key)
   where n.key in ('name','code','category','brand','model','serial_number',
                   'purchase_date','purchase_cost','supplier_name',
                   'warranty_until','notes')
     and n.value is distinct from o.value;

  if v_changes = '{}'::jsonb and v_new.quantity = v_old.quantity then
    return public.fn_fixed_asset_to_json(v_old);
  end if;

  begin
    update public.fixed_assets
       set name           = v_new.name,
           code           = v_new.code,
           category       = v_new.category,
           brand          = v_new.brand,
           model          = v_new.model,
           serial_number  = v_new.serial_number,
           purchase_date  = v_new.purchase_date,
           purchase_cost  = v_new.purchase_cost,
           supplier_name  = v_new.supplier_name,
           warranty_until = v_new.warranty_until,
           notes          = v_new.notes,
           quantity       = v_new.quantity,
           updated_at     = now()
     where id = v_old.id
     returning * into v_new;
  exception when unique_violation then
    raise exception 'FIXED_ASSET_CODE_TAKEN';
  end;

  if v_changes <> '{}'::jsonb then
    perform public.fn_fixed_asset_log(
      p_asset_id    => v_old.id,
      p_business_id => v_old.business_id,
      p_event_type  => 'updated',
      p_changes     => v_changes
    );
  end if;
  if v_new.quantity <> v_old.quantity then
    perform public.fn_fixed_asset_log(
      p_asset_id      => v_old.id,
      p_business_id   => v_old.business_id,
      p_event_type    => 'quantity_changed',
      p_from_quantity => v_old.quantity,
      p_to_quantity   => v_new.quantity,
      p_notes         => v_data->>'change_note'
    );
  end if;

  return public.fn_fixed_asset_to_json(v_new);
end;
$$;

-- ---------------------------------------------------------------------------
-- 7. Traslado y estado: el mismo cuerpo que 0052, recreado para que tomen la
--    firma nueva de la historia y la fila con las columnas nuevas.
-- ---------------------------------------------------------------------------

create or replace function public.fn_fixed_asset_move(
  p_asset_id      uuid,
  p_warehouse_id  uuid,
  p_location_note text,
  p_employee_id   uuid,
  p_notes         text default null
) returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_old        public.fixed_assets;
  v_new        public.fixed_assets;
  v_location   text := nullif(btrim(coalesce(p_location_note, '')), '');
  v_relocated  boolean;
  v_reassigned boolean;
begin
  if p_asset_id is null then
    raise exception 'MISSING_REQUIRED_PARAMS';
  end if;

  select * into v_old from public.fixed_assets where id = p_asset_id for update;
  if v_old.id is null then
    raise exception 'FIXED_ASSET_NOT_FOUND';
  end if;
  if not public.user_has_business_access(auth.uid(), v_old.business_id) then
    raise exception 'NOT_AUTHORIZED';
  end if;
  if not public.fn_fixed_asset_can_manage(v_old.business_id) then
    raise exception 'FIXED_ASSET_DENIED';
  end if;
  -- Lo dado de baja ya no está en ningún lado: primero se reactiva.
  if v_old.status = 'retired' then
    raise exception 'FIXED_ASSET_RETIRED';
  end if;
  perform public.fn_fixed_asset_check_refs(
    v_old.business_id, p_warehouse_id, p_employee_id);

  v_relocated := v_old.warehouse_id is distinct from p_warehouse_id
              or v_old.location_note is distinct from v_location;
  v_reassigned := v_old.assigned_employee_id is distinct from p_employee_id;

  if not v_relocated and not v_reassigned then
    return public.fn_fixed_asset_to_json(v_old);
  end if;

  update public.fixed_assets
     set warehouse_id         = p_warehouse_id,
         location_note        = v_location,
         assigned_employee_id = p_employee_id,
         updated_at           = now()
   where id = v_old.id
   returning * into v_new;

  if v_relocated then
    perform public.fn_fixed_asset_log(
      p_asset_id          => v_old.id,
      p_business_id       => v_old.business_id,
      p_event_type        => 'relocated',
      p_from_warehouse_id => v_old.warehouse_id,
      p_to_warehouse_id   => v_new.warehouse_id,
      p_from_location     => v_old.location_note,
      p_to_location       => v_new.location_note,
      p_notes             => p_notes
    );
  end if;
  if v_reassigned then
    perform public.fn_fixed_asset_log(
      p_asset_id         => v_old.id,
      p_business_id      => v_old.business_id,
      p_event_type       => 'reassigned',
      p_from_employee_id => v_old.assigned_employee_id,
      p_to_employee_id   => v_new.assigned_employee_id,
      p_notes            => p_notes
    );
  end if;

  return public.fn_fixed_asset_to_json(v_new);
end;
$$;

create or replace function public.fn_fixed_asset_set_status(
  p_asset_id uuid,
  p_status   text,
  p_notes    text default null
) returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_old    public.fixed_assets;
  v_new    public.fixed_assets;
  v_status text := btrim(coalesce(p_status, ''));
  v_note   text := nullif(btrim(coalesce(p_notes, '')), '');
begin
  if p_asset_id is null or v_status = '' then
    raise exception 'MISSING_REQUIRED_PARAMS';
  end if;
  if v_status not in ('active','needs_repair','in_repair','damaged','lost',
                      'retired') then
    raise exception 'FIXED_ASSET_INVALID_STATUS';
  end if;

  select * into v_old from public.fixed_assets where id = p_asset_id for update;
  if v_old.id is null then
    raise exception 'FIXED_ASSET_NOT_FOUND';
  end if;
  if not public.user_has_business_access(auth.uid(), v_old.business_id) then
    raise exception 'NOT_AUTHORIZED';
  end if;
  if not public.fn_fixed_asset_can_manage(v_old.business_id) then
    raise exception 'FIXED_ASSET_DENIED';
  end if;

  -- El mismo estado otra vez (doble toque): nada que registrar.
  if v_old.status = v_status then
    return public.fn_fixed_asset_to_json(v_old);
  end if;

  if v_status = 'retired' then
    -- Una baja sin motivo no sirve en una auditoría: ¿se vendió, se botó,
    -- se lo robaron?
    if v_note is null then
      raise exception 'FIXED_ASSET_RETIRE_REASON_REQUIRED';
    end if;
    update public.fixed_assets
       set status         = 'retired',
           retired_at     = now(),
           retired_reason = v_note,
           updated_at     = now()
     where id = v_old.id
     returning * into v_new;
  else
    update public.fixed_assets
       set status         = v_status,
           retired_at     = null,
           retired_reason = null,
           updated_at     = now()
     where id = v_old.id
     returning * into v_new;
  end if;

  perform public.fn_fixed_asset_log(
    p_asset_id    => v_old.id,
    p_business_id => v_old.business_id,
    p_event_type  => case
                       when v_status = 'retired' then 'retired'
                       when v_old.status = 'retired' then 'reactivated'
                       else 'status_changed'
                     end,
    p_from_status => v_old.status,
    p_to_status   => v_new.status,
    p_notes       => v_note
  );

  return public.fn_fixed_asset_to_json(v_new);
end;
$$;

-- ---------------------------------------------------------------------------
-- 8. Verificador: piezas internas
-- ---------------------------------------------------------------------------

-- La verificación como la lee la app: la fila + sus líneas.
create or replace function public.fn_fixed_asset_verification_to_json(p_id uuid)
returns jsonb
language sql
stable
set search_path = public
as $$
  select to_jsonb(v) || jsonb_build_object(
           'lines',
           coalesce((
             select jsonb_agg(to_jsonb(l)
                              order by l.expected desc, l.is_new, l.asset_code)
               from public.fixed_asset_verification_lines l
              where l.verification_id = v.id), '[]'::jsonb))
    from public.fixed_asset_verifications v
   where v.id = p_id;
$$;

-- Abre la verificación con candado, valida acceso, permiso y que siga
-- abierta. Devuelve la fila.
create or replace function public.fn_fixed_asset_verification_lock(
  p_verification_id uuid
) returns public.fixed_asset_verifications
language plpgsql
volatile
security definer
set search_path = public
as $$
declare
  v_ver public.fixed_asset_verifications;
begin
  if p_verification_id is null then
    raise exception 'MISSING_REQUIRED_PARAMS';
  end if;
  select * into v_ver
    from public.fixed_asset_verifications
   where id = p_verification_id
     for update;
  if v_ver.id is null then
    raise exception 'FIXED_ASSET_VERIFICATION_NOT_FOUND';
  end if;
  if not public.user_has_business_access(auth.uid(), v_ver.business_id) then
    raise exception 'NOT_AUTHORIZED';
  end if;
  if not public.fn_fixed_asset_can_manage(v_ver.business_id) then
    raise exception 'FIXED_ASSET_DENIED';
  end if;
  if v_ver.status <> 'open' then
    raise exception 'FIXED_ASSET_VERIFICATION_NOT_OPEN';
  end if;
  return v_ver;
end;
$$;

revoke all on function public.fn_fixed_asset_verification_to_json(uuid)
  from public, anon, authenticated;
revoke all on function public.fn_fixed_asset_verification_lock(uuid)
  from public, anon, authenticated;

-- ---------------------------------------------------------------------------
-- 9. Abrir
-- ---------------------------------------------------------------------------

create or replace function public.fn_fixed_asset_verification_start(
  p_business_id  uuid,
  p_warehouse_id uuid,
  p_notes        text default null
) returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_ver    public.fixed_asset_verifications;
  v_number integer;
begin
  if p_business_id is null then
    raise exception 'MISSING_REQUIRED_PARAMS';
  end if;
  if not public.user_has_business_access(auth.uid(), p_business_id) then
    raise exception 'NOT_AUTHORIZED';
  end if;
  if not public.fn_fixed_asset_can_manage(p_business_id) then
    raise exception 'FIXED_ASSET_DENIED';
  end if;
  perform public.fn_fixed_asset_check_refs(p_business_id, p_warehouse_id, null);

  perform pg_advisory_xact_lock(
    hashtextextended(p_business_id::text || ':fixed_asset_verification', 0));

  -- ¿Ya hay una abierta de este alcance? Se sigue con esa.
  select * into v_ver
    from public.fixed_asset_verifications
   where business_id = p_business_id
     and status = 'open'
     and warehouse_id is not distinct from p_warehouse_id
   limit 1;
  if v_ver.id is not null then
    return public.fn_fixed_asset_verification_to_json(v_ver.id)
           || jsonb_build_object('resumed', true);
  end if;

  select coalesce(max(number), 0) + 1 into v_number
    from public.fixed_asset_verifications
   where business_id = p_business_id;

  insert into public.fixed_asset_verifications (
    business_id, number, warehouse_id, warehouse_name, notes,
    started_by, started_by_name
  ) values (
    p_business_id, v_number, p_warehouse_id,
    coalesce((select w.name from public.warehouses w where w.id = p_warehouse_id),
             'Todas las ubicaciones'),
    nullif(btrim(coalesce(p_notes, '')), ''),
    auth.uid(),
    public.fn_fixed_asset_actor_name(p_business_id)
  ) returning * into v_ver;

  -- La lista de lo que DEBERÍA estar: los vigentes de esa ubicación (o
  -- todos), con su cantidad y su estado de este momento.
  insert into public.fixed_asset_verification_lines (
    verification_id, business_id, asset_id, asset_code, asset_name,
    unit_value, registered_warehouse_id, registered_warehouse_name,
    expected, expected_qty, expected_status
  )
  select v_ver.id, a.business_id, a.id, a.code, a.name,
         a.purchase_cost, a.warehouse_id, w.name,
         true, a.quantity, a.status
    from public.fixed_assets a
    left join public.warehouses w on w.id = a.warehouse_id
   where a.business_id = p_business_id
     and a.status <> 'retired'
     and (p_warehouse_id is null or a.warehouse_id = p_warehouse_id);

  return public.fn_fixed_asset_verification_to_json(v_ver.id)
         || jsonb_build_object('resumed', false);
end;
$$;

-- ---------------------------------------------------------------------------
-- 10. Marcar lo encontrado / deshacer
-- ---------------------------------------------------------------------------

create or replace function public.fn_fixed_asset_verification_check(
  p_verification_id uuid,
  p_asset_id        uuid,
  p_found_qty       integer,
  p_observed_status text default null,
  p_notes           text default null
) returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_ver   public.fixed_asset_verifications;
  v_asset public.fixed_assets;
  v_line  public.fixed_asset_verification_lines;
  v_obs   text := nullif(btrim(coalesce(p_observed_status, '')), '');
  v_note  text := nullif(btrim(coalesce(p_notes, '')), '');
begin
  v_ver := public.fn_fixed_asset_verification_lock(p_verification_id);

  if p_asset_id is null then
    raise exception 'MISSING_REQUIRED_PARAMS';
  end if;
  if p_found_qty is null or p_found_qty < 0 then
    raise exception 'FIXED_ASSET_INVALID_QUANTITY';
  end if;
  if v_obs is not null
     and v_obs not in ('active','needs_repair','in_repair','damaged','lost') then
    raise exception 'FIXED_ASSET_INVALID_STATUS';
  end if;

  select * into v_asset
    from public.fixed_assets
   where id = p_asset_id and business_id = v_ver.business_id;
  if v_asset.id is null then
    raise exception 'FIXED_ASSET_NOT_FOUND';
  end if;

  -- Visto igual que como está registrado = sin cambio.
  if v_obs = v_asset.status then
    v_obs := '';
  end if;

  select * into v_line
    from public.fixed_asset_verification_lines
   where verification_id = v_ver.id and asset_id = p_asset_id;

  if v_line.id is null then
    -- No estaba en la lista: está registrado en otra ubicación (o en
    -- ninguna). Lo dado de baja no se verifica: primero se reactiva.
    if v_asset.status = 'retired' then
      raise exception 'FIXED_ASSET_RETIRED';
    end if;
    insert into public.fixed_asset_verification_lines (
      verification_id, business_id, asset_id, asset_code, asset_name,
      unit_value, registered_warehouse_id, registered_warehouse_name,
      expected, expected_qty, expected_status,
      found_qty, observed_status, notes,
      checked_by, checked_by_name, checked_at
    ) values (
      v_ver.id, v_ver.business_id, v_asset.id, v_asset.code, v_asset.name,
      v_asset.purchase_cost, v_asset.warehouse_id,
      (select w.name from public.warehouses w where w.id = v_asset.warehouse_id),
      false, null, v_asset.status,
      p_found_qty, nullif(v_obs, ''), v_note,
      auth.uid(), public.fn_fixed_asset_actor_name(v_ver.business_id),
      clock_timestamp()
    ) returning * into v_line;
  else
    update public.fixed_asset_verification_lines
       set found_qty       = p_found_qty,
           -- null = se conserva lo anotado; '' = sin cambio.
           observed_status = case when v_obs is null then observed_status
                                  else nullif(v_obs, '') end,
           notes           = coalesce(v_note, notes),
           checked_by      = auth.uid(),
           checked_by_name = public.fn_fixed_asset_actor_name(v_ver.business_id),
           checked_at      = clock_timestamp()
     where id = v_line.id
     returning * into v_line;
  end if;

  return to_jsonb(v_line);
end;
$$;

create or replace function public.fn_fixed_asset_verification_uncheck(
  p_verification_id uuid,
  p_asset_id        uuid
) returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_ver  public.fixed_asset_verifications;
  v_line public.fixed_asset_verification_lines;
begin
  v_ver := public.fn_fixed_asset_verification_lock(p_verification_id);

  select * into v_line
    from public.fixed_asset_verification_lines
   where verification_id = v_ver.id and asset_id = p_asset_id;
  if v_line.id is null then
    return jsonb_build_object('removed', false, 'line', null);
  end if;
  -- Un alta hecha en la verificación ya es un activo real: se corrige desde
  -- su ficha, no deshaciendo la línea.
  if v_line.is_new then
    raise exception 'FIXED_ASSET_VERIFICATION_IS_NEW';
  end if;

  if not v_line.expected then
    delete from public.fixed_asset_verification_lines where id = v_line.id;
    return jsonb_build_object('removed', true, 'line', null);
  end if;

  update public.fixed_asset_verification_lines
     set found_qty = null, observed_status = null,
         checked_by = null, checked_by_name = null, checked_at = null
   where id = v_line.id
   returning * into v_line;
  return jsonb_build_object('removed', false, 'line', to_jsonb(v_line));
end;
$$;

-- ---------------------------------------------------------------------------
-- 11. Alta en el acto
-- ---------------------------------------------------------------------------

create or replace function public.fn_fixed_asset_verification_add_asset(
  p_verification_id uuid,
  p_data            jsonb
) returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_ver   public.fixed_asset_verifications;
  v_data  jsonb := coalesce(p_data, '{}'::jsonb);
  v_json  jsonb;
  v_asset public.fixed_assets;
  v_line  public.fixed_asset_verification_lines;
begin
  v_ver := public.fn_fixed_asset_verification_lock(p_verification_id);

  -- Lo que se registra al verificar una ubicación queda EN esa ubicación.
  if v_ver.warehouse_id is not null then
    v_data := v_data || jsonb_build_object('warehouse_id', v_ver.warehouse_id);
  end if;

  -- Mismas validaciones, código y reintento (client_request_id) que el alta
  -- normal.
  v_json := public.fn_fixed_asset_create(v_ver.business_id, v_data);
  select * into v_asset from public.fixed_assets where id = (v_json->>'id')::uuid;

  insert into public.fixed_asset_verification_lines (
    verification_id, business_id, asset_id, asset_code, asset_name,
    unit_value, registered_warehouse_id, registered_warehouse_name,
    expected, expected_qty, expected_status, found_qty, is_new,
    checked_by, checked_by_name, checked_at
  ) values (
    v_ver.id, v_ver.business_id, v_asset.id, v_asset.code, v_asset.name,
    v_asset.purchase_cost, v_asset.warehouse_id,
    (select w.name from public.warehouses w where w.id = v_asset.warehouse_id),
    false, null, v_asset.status, v_asset.quantity, true,
    auth.uid(), public.fn_fixed_asset_actor_name(v_ver.business_id),
    clock_timestamp()
  )
  on conflict (verification_id, asset_id) do nothing;

  select * into v_line
    from public.fixed_asset_verification_lines
   where verification_id = v_ver.id and asset_id = v_asset.id;

  return jsonb_build_object('asset', v_json, 'line', to_jsonb(v_line));
end;
$$;

-- ---------------------------------------------------------------------------
-- 12. Cerrar
-- ---------------------------------------------------------------------------

create or replace function public.fn_fixed_asset_verification_close(
  p_verification_id uuid,
  p_decisions       jsonb,
  p_notes           text default null
) returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_ver       public.fixed_asset_verifications;
  v_decisions jsonb := coalesce(p_decisions, '[]'::jsonb);
  v_d         record;
  v_line      public.fixed_asset_verification_lines;
  v_asset     public.fixed_assets;
  v_acts      text[];
  v_found     integer;
  v_short     boolean;
  v_res       text;
  v_cond      boolean;
  v_tag       text;
  v_summary   jsonb;
begin
  v_ver := public.fn_fixed_asset_verification_lock(p_verification_id);
  v_tag := 'verificación #' || v_ver.number;

  if jsonb_typeof(v_decisions) <> 'array' then
    raise exception 'FIXED_ASSET_VERIFICATION_BAD_DECISION';
  end if;

  -- 1) Validar TODAS las decisiones antes de tocar nada.
  for v_d in
    select (x->>'asset_id')::uuid as asset_id, x->>'action' as action
      from jsonb_array_elements(v_decisions) x
  loop
    select * into v_line
      from public.fixed_asset_verification_lines
     where verification_id = v_ver.id and asset_id = v_d.asset_id;
    if v_line.id is null then
      raise exception 'FIXED_ASSET_VERIFICATION_BAD_DECISION';
    end if;
    v_found := coalesce(v_line.found_qty, 0);
    if not (
         (v_d.action = 'mark_lost' and v_line.expected
            and v_found < coalesce(v_line.expected_qty, 0))
      or (v_d.action = 'set_quantity' and v_line.found_qty is not null
            and v_line.found_qty >= 1)
      or (v_d.action = 'move_here' and v_ver.warehouse_id is not null
            and not v_line.expected and not v_line.is_new and v_found > 0)
      or (v_d.action = 'apply_condition' and v_line.observed_status is not null)
    ) then
      raise exception 'FIXED_ASSET_VERIFICATION_BAD_DECISION';
    end if;
  end loop;

  -- Perdido y «la cantidad es la encontrada» sobre el mismo activo se
  -- contradicen.
  if exists (
    select 1
      from jsonb_array_elements(v_decisions) x
     group by x->>'asset_id'
    having bool_or(x->>'action' = 'mark_lost')
       and bool_or(x->>'action' = 'set_quantity')
  ) then
    raise exception 'FIXED_ASSET_VERIFICATION_BAD_DECISION';
  end if;

  -- 2) Aplicar, línea por línea.
  for v_line in
    select * from public.fixed_asset_verification_lines
     where verification_id = v_ver.id
     order by asset_code
  loop
    select coalesce(array_agg(distinct x->>'action'), '{}')
      into v_acts
      from jsonb_array_elements(v_decisions) x
     where (x->>'asset_id')::uuid = v_line.asset_id;

    select * into v_asset from public.fixed_assets where id = v_line.asset_id;
    v_found := coalesce(v_line.found_qty, 0);
    v_short := v_line.expected and v_found < coalesce(v_line.expected_qty, 0);
    v_cond  := false;

    -- Dado de baja mientras la verificación estaba abierta: no se le aplica
    -- nada; queda en el acta como estaba.
    if v_asset.id is null or v_asset.status = 'retired' then
      v_res := case when v_short then 'pending' else 'ok' end;
    else
      if 'mark_lost' = any (v_acts) then
        if v_found = 0 then
          perform public.fn_fixed_asset_set_status(
            v_asset.id, 'lost', 'No apareció en la ' || v_tag);
        else
          perform public.fn_fixed_asset_update(
            v_asset.id,
            jsonb_build_object(
              'quantity', v_found,
              'change_note', 'Faltaron ' || (v_line.expected_qty - v_found)
                             || ' en la ' || v_tag));
        end if;
        v_res := 'lost';
      elsif 'set_quantity' = any (v_acts) then
        perform public.fn_fixed_asset_update(
          v_asset.id,
          jsonb_build_object(
            'quantity', v_line.found_qty,
            'change_note', 'Contadas ' || v_line.found_qty || ' en la ' || v_tag));
        v_res := 'quantity_set';
      elsif v_line.is_new then
        v_res := 'new';
      elsif v_short then
        v_res := 'pending';
      else
        v_res := 'ok';
      end if;

      if 'move_here' = any (v_acts) then
        perform public.fn_fixed_asset_move(
          v_asset.id, v_ver.warehouse_id, null, v_asset.assigned_employee_id,
          'Encontrado en ' || v_ver.warehouse_name || ' en la ' || v_tag);
        if v_res in ('ok', 'pending') then
          v_res := 'moved';
        end if;
      end if;

      -- El estado visto, salvo que ya quedó «perdido» porque no apareció.
      if 'apply_condition' = any (v_acts)
         and not ('mark_lost' = any (v_acts) and v_found = 0) then
        perform public.fn_fixed_asset_set_status(
          v_asset.id, v_line.observed_status, 'Estado visto en la ' || v_tag);
        v_cond := true;
      end if;

      -- Lo que se vio queda verificado, con su evento en la historia.
      if v_found > 0 then
        update public.fixed_assets
           set last_verified_at = now(),
               last_verification_id = v_ver.id
         where id = v_asset.id;
        perform public.fn_fixed_asset_log(
          p_asset_id        => v_asset.id,
          p_business_id     => v_ver.business_id,
          p_event_type      => 'verified',
          p_from_quantity   => v_line.expected_qty,
          p_to_quantity     => v_found,
          p_verification_id => v_ver.id,
          p_notes           => initcap(v_tag) || ' (' || v_ver.warehouse_name
                               || '): ' || v_found
                               || coalesce(' de ' || v_line.expected_qty, '')
        );
      end if;
    end if;

    update public.fixed_asset_verification_lines
       set resolution = v_res, condition_applied = v_cond
     where id = v_line.id;
  end loop;

  -- 3) Los números del acta, congelados.
  select jsonb_build_object(
           'expected_count',  count(*) filter (where l.expected),
           'checked_count',   count(*) filter (where l.found_qty is not null),
           'ok_count',        count(*) filter (where l.resolution = 'ok'),
           'missing_count',   count(*) filter (
                                where l.expected
                                  and coalesce(l.found_qty, 0) < l.expected_qty),
           'missing_units',   coalesce(sum(l.expected_qty - coalesce(l.found_qty, 0))
                                filter (where l.expected
                                  and coalesce(l.found_qty, 0) < l.expected_qty), 0),
           'missing_value',   round(coalesce(sum(
                                (l.expected_qty - coalesce(l.found_qty, 0))
                                * coalesce(l.unit_value, 0))
                                filter (where l.expected
                                  and coalesce(l.found_qty, 0) < l.expected_qty), 0), 2),
           'extra_count',     count(*) filter (
                                where l.expected and l.found_qty > l.expected_qty),
           'misplaced_count', count(*) filter (where not l.expected and not l.is_new),
           'new_count',       count(*) filter (where l.is_new),
           'lost_count',      count(*) filter (where l.resolution = 'lost'),
           'pending_count',   count(*) filter (where l.resolution = 'pending'),
           'found_value',     round(coalesce(sum(coalesce(l.found_qty, 0)
                                * coalesce(l.unit_value, 0)), 0), 2)
         )
    into v_summary
    from public.fixed_asset_verification_lines l
   where l.verification_id = v_ver.id;

  update public.fixed_asset_verifications
     set status         = 'closed',
         closed_by      = auth.uid(),
         closed_by_name = public.fn_fixed_asset_actor_name(v_ver.business_id),
         closed_at      = now(),
         summary        = v_summary,
         notes          = nullif(concat_ws(' · ', notes,
                                   nullif(btrim(coalesce(p_notes, '')), '')), '')
   where id = v_ver.id;

  return public.fn_fixed_asset_verification_to_json(v_ver.id);
end;
$$;

-- ---------------------------------------------------------------------------
-- 13. Cancelar
-- ---------------------------------------------------------------------------

create or replace function public.fn_fixed_asset_verification_cancel(
  p_verification_id uuid,
  p_reason          text
) returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_ver    public.fixed_asset_verifications;
  v_reason text := nullif(btrim(coalesce(p_reason, '')), '');
begin
  v_ver := public.fn_fixed_asset_verification_lock(p_verification_id);
  if v_reason is null then
    raise exception 'FIXED_ASSET_VERIFICATION_REASON_REQUIRED';
  end if;

  -- Lo dado de alta durante la verificación se queda: son activos reales.
  update public.fixed_asset_verifications
     set status         = 'cancelled',
         cancel_reason  = v_reason,
         closed_by      = auth.uid(),
         closed_by_name = public.fn_fixed_asset_actor_name(v_ver.business_id),
         closed_at      = now()
   where id = v_ver.id;

  return public.fn_fixed_asset_verification_to_json(v_ver.id);
end;
$$;

-- ---------------------------------------------------------------------------
-- 14. Grants
-- ---------------------------------------------------------------------------

revoke all on function public.fn_fixed_asset_verification_start(uuid, uuid, text)
  from public, anon;
revoke all on function public.fn_fixed_asset_verification_check(uuid, uuid, integer, text, text)
  from public, anon;
revoke all on function public.fn_fixed_asset_verification_uncheck(uuid, uuid)
  from public, anon;
revoke all on function public.fn_fixed_asset_verification_add_asset(uuid, jsonb)
  from public, anon;
revoke all on function public.fn_fixed_asset_verification_close(uuid, jsonb, text)
  from public, anon;
revoke all on function public.fn_fixed_asset_verification_cancel(uuid, text)
  from public, anon;
grant execute on function public.fn_fixed_asset_verification_start(uuid, uuid, text)
  to authenticated, service_role;
grant execute on function public.fn_fixed_asset_verification_check(uuid, uuid, integer, text, text)
  to authenticated, service_role;
grant execute on function public.fn_fixed_asset_verification_uncheck(uuid, uuid)
  to authenticated, service_role;
grant execute on function public.fn_fixed_asset_verification_add_asset(uuid, jsonb)
  to authenticated, service_role;
grant execute on function public.fn_fixed_asset_verification_close(uuid, jsonb, text)
  to authenticated, service_role;
grant execute on function public.fn_fixed_asset_verification_cancel(uuid, text)
  to authenticated, service_role;

-- Las de 0052 se recrearon con `create or replace`: conservan sus grants.

notify pgrst, 'reload schema';

commit;
