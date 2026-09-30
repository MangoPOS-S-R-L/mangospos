-- =============================================================================
-- 20260930_0052 — Activos fijos: el equipo y el mobiliario, UNO POR UNO.
--
-- Numerada en el rango 0050+ a propósito (el dueño y el asistente trabajan en
-- paralelo y los dos contaban desde 0001). La 0051 es de Gastables/Menaje.
--
-- PEDIDO DEL DUEÑO (2026-09-30): controlar lo que no es comida. Se partió en
-- tres cosas distintas, y ESTA migración es solo la tercera:
--   · Gastables (papel de baño, fundas): insumo de inventario, se consume.
--   · Menaje (vasos, platos, ollas): insumo de inventario, se cuenta por
--     CANTIDAD. La «vajilla» del bosquejo del PRD §5.7 va ahí, no acá.
--   · Activos fijos (hornos, neveras, freidoras, licuadoras, TV, equipos de
--     caja, aires, mesas y sillas, el motor de delivery): cada uno es UNA
--     ficha con su código, su serie, dónde está y quién responde por él.
--
-- POR QUÉ NO ES UN INSUMO MÁS:
--   Un insumo tiene existencia, costo promedio y kardex; se vende o se merma.
--   Un horno no: no se consume, no entra en el costo de venta ni en la
--   valuación del inventario. Es un registro PARALELO: qué hay, dónde está,
--   quién lo tiene a cargo y qué le ha pasado. Por eso tablas propias y
--   ningún movimiento en inventory_movements.
--
-- QUÉ ENTREGA:
--   1. `fixed_assets`: la ficha. Código AF-00001 por negocio, generado en el
--      servidor bajo un candado por negocio (dos tabletas dando de alta a la
--      vez no sacan el mismo número). Estado: active | needs_repair |
--      in_repair | damaged | lost | retired.
--   2. `fixed_asset_movements`: la historia. Cada cambio deja una fila con
--      qué pasó, de dónde a dónde, quién y cuándo. Los NOMBRES (bodega,
--      responsable, quien hizo el cambio) se guardan como foto: si mañana se
--      borra el empleado, la historia sigue diciendo quién tenía el equipo.
--   3. RLS de SOLO LECTURA para quien tenga acceso al negocio. Toda escritura
--      pasa por los RPC de abajo (SECURITY DEFINER), que son los que validan
--      el permiso y escriben la historia. Si la historia dependiera de que la
--      app se acuerde de insertarla, un cliente viejo la saltaría.
--   4. Permisos `inventario.activos.acceso` e `inventario.activos.gestionar`
--      en el catálogo de la BD. Sin la fila, el join del RPC de permisos los
--      descarta EN SILENCIO y el gate en Flutter nunca deja pasar a nadie.
--
-- RPC (todos devuelven la ficha como jsonb, con la bodega y el responsable
-- embebidos igual que el SELECT de PostgREST):
--   fn_fixed_asset_create(p_business_id, p_data)        → 'created'
--   fn_fixed_asset_update(p_asset_id, p_data)           → 'updated' (con los
--        campos cambiados en `changes`). NO toca ubicación, responsable ni
--        estado: para eso están los dos de abajo, que dejan su evento propio.
--   fn_fixed_asset_move(p_asset_id, p_warehouse_id, p_location_note,
--        p_employee_id, p_notes)                         → 'relocated' y/o
--        'reassigned'. Recibe el estado FINAL (null = sin bodega / sin
--        responsable), no la diferencia.
--   fn_fixed_asset_set_status(p_asset_id, p_status, p_notes)
--        → 'status_changed' | 'retired' (motivo obligatorio; guarda
--        retired_at/retired_reason) | 'reactivated' (desde 'retired'; los
--        limpia).
--   Repetir la misma operación (doble toque, reintento) no escribe nada ni
--   deja historia: devuelve la ficha como está. El alta acepta
--   `client_request_id` para que un reintento tras un timeout no cree dos.
--
-- QUIÉN ESCRIBE: owner / admin / manager del negocio, o quien tenga
--   `inventario.activos.gestionar` en su rol. Mismo criterio que la anulación
--   de compras (20260929_0050).
--
-- CONTRATO DE ERRORES (strings mapeables en Dart):
--   MISSING_REQUIRED_PARAMS, NOT_AUTHORIZED, FIXED_ASSET_DENIED,
--   FIXED_ASSET_NOT_FOUND, FIXED_ASSET_NAME_REQUIRED, FIXED_ASSET_INVALID_COST,
--   FIXED_ASSET_INVALID_STATUS, FIXED_ASSET_RETIRE_REASON_REQUIRED,
--   FIXED_ASSET_RETIRED, WAREHOUSE_NOT_IN_BUSINESS, EMPLOYEE_NOT_IN_BUSINESS.
--
-- LO QUE NO HACE (decisión del dueño): depreciación. Tampoco toca inventario,
--   ventas, caja ni compras.
--
-- REQUIERE: nada nuevo. Usa businesses, warehouses, employees, profiles,
--   permissions/roles/role_permissions y los helpers de acceso
--   (user_has_business_access, user_business_role y
--   user_has_business_permission de 20260803_0001).
-- IDEMPOTENTE: sí. REVERSIBLE: sí (_ROLLBACK; borra el registro).
-- =============================================================================

begin;

set local lock_timeout = '5s';

-- ---------------------------------------------------------------------------
-- 1. La ficha
-- ---------------------------------------------------------------------------

create table if not exists public.fixed_assets (
  id                   uuid primary key default gen_random_uuid(),
  business_id          uuid not null
                         references public.businesses(id) on delete cascade,
  code                 text not null,
  name                 text not null check (btrim(name) <> ''),
  -- Texto libre: la app sugiere Equipo de cocina, Refrigeración, Mobiliario,
  -- Electrónica, Climatización, Vehículo, Otro, pero cada negocio nombra lo
  -- suyo. Un catálogo cerrado se quedaría corto al primer caso raro.
  category             text,
  brand                text,
  model                text,
  serial_number        text,
  purchase_date        date,
  purchase_cost        numeric(14,2)
                         check (purchase_cost is null or purchase_cost >= 0),
  -- Texto libre a propósito: muchos equipos se compran a quien no es
  -- proveedor de mercancía (una tienda, un particular).
  supplier_name        text,
  warranty_until       date,
  -- Dónde está. Si se borra la bodega, el activo queda «sin ubicación»; la
  -- historia conserva el nombre.
  warehouse_id         uuid references public.warehouses(id) on delete set null,
  location_note        text,
  -- Quién responde por él.
  assigned_employee_id uuid references public.employees(id) on delete set null,
  status               text not null default 'active'
                         check (status in ('active','needs_repair','in_repair',
                                           'damaged','lost','retired')),
  retired_at           timestamptz,
  retired_reason       text,
  notes                text,
  -- Idempotencia del alta: el formulario manda un uuid por intento.
  client_request_id    uuid,
  created_by           uuid references auth.users(id) on delete set null,
  created_at           timestamptz not null default now(),
  updated_at           timestamptz not null default now(),
  constraint fixed_assets_code_business_unique unique (business_id, code),
  -- Dado de baja siempre con fecha: es lo que el reporte muestra.
  constraint fixed_assets_retired_has_date
    check (status <> 'retired' or retired_at is not null)
);

create index if not exists idx_fixed_assets_business_status
  on public.fixed_assets (business_id, status);
create index if not exists idx_fixed_assets_warehouse
  on public.fixed_assets (warehouse_id) where warehouse_id is not null;
create index if not exists idx_fixed_assets_employee
  on public.fixed_assets (assigned_employee_id)
  where assigned_employee_id is not null;
create unique index if not exists uq_fixed_assets_client_request
  on public.fixed_assets (business_id, client_request_id)
  where client_request_id is not null;

comment on table public.fixed_assets is
  'Activos fijos (equipo y mobiliario) uno por uno: código AF-00001 por '
  'negocio, ubicación, responsable y estado. Registro paralelo: NO entra en '
  'la valuación del inventario ni en el costo de venta. Sin depreciación. '
  'Se escribe solo con fn_fixed_asset_*. 20260930_0052.';
comment on column public.fixed_assets.status is
  'active = en uso · needs_repair · in_repair · damaged · lost · retired = '
  'dado de baja (con retired_at y retired_reason).';

-- ---------------------------------------------------------------------------
-- 2. La historia
-- ---------------------------------------------------------------------------

create table if not exists public.fixed_asset_movements (
  id                  uuid primary key default gen_random_uuid(),
  asset_id            uuid not null
                        references public.fixed_assets(id) on delete cascade,
  business_id         uuid not null
                        references public.businesses(id) on delete cascade,
  event_type          text not null
                        check (event_type in ('created','updated','relocated',
                                              'reassigned','status_changed',
                                              'retired','reactivated')),
  from_warehouse_id   uuid references public.warehouses(id) on delete set null,
  to_warehouse_id     uuid references public.warehouses(id) on delete set null,
  -- Foto del nombre al momento del cambio: la FK puede quedar en null.
  from_warehouse_name text,
  to_warehouse_name   text,
  from_location_note  text,
  to_location_note    text,
  from_employee_id    uuid references public.employees(id) on delete set null,
  to_employee_id      uuid references public.employees(id) on delete set null,
  from_employee_name  text,
  to_employee_name    text,
  from_status         text,
  to_status           text,
  -- Solo en 'updated': { campo: { from, to } }.
  changes             jsonb,
  notes               text,
  created_by          uuid default auth.uid()
                        references auth.users(id) on delete set null,
  created_by_name     text,
  created_at          timestamptz not null default now()
);

create index if not exists idx_fixed_asset_movements_asset
  on public.fixed_asset_movements (asset_id, created_at desc);
create index if not exists idx_fixed_asset_movements_business
  on public.fixed_asset_movements (business_id, created_at desc);

comment on table public.fixed_asset_movements is
  'Historia de cada activo fijo: alta, edición, traslado, reasignación, '
  'cambio de estado, baja y reactivación. Una fila por evento, con quién y '
  'cuándo, y los nombres como foto. 20260930_0052.';

-- ---------------------------------------------------------------------------
-- 3. RLS: leer sí, escribir solo por RPC
-- ---------------------------------------------------------------------------

alter table public.fixed_assets enable row level security;
alter table public.fixed_asset_movements enable row level security;

drop policy if exists fixed_assets_select on public.fixed_assets;
create policy fixed_assets_select on public.fixed_assets
  for select to authenticated
  using (public.user_has_business_access(auth.uid(), business_id));

drop policy if exists fixed_asset_movements_select
  on public.fixed_asset_movements;
create policy fixed_asset_movements_select on public.fixed_asset_movements
  for select to authenticated
  using (public.user_has_business_access(auth.uid(), business_id));

-- Sin policies de escritura a propósito: todo pasa por los RPC, que son los
-- que validan el permiso y dejan la historia.
grant select on public.fixed_assets to authenticated;
grant select on public.fixed_asset_movements to authenticated;

-- ---------------------------------------------------------------------------
-- 4. Piezas internas (no se exponen a la app)
-- ---------------------------------------------------------------------------

-- ¿Puede el usuario actual escribir activos de este negocio?
create or replace function public.fn_fixed_asset_can_manage(p_business_id uuid)
returns boolean
language sql
stable
security definer
set search_path = public
as $$
  select coalesce(public.user_business_role(auth.uid(), p_business_id), '')
           in ('owner', 'admin', 'manager')
      or public.user_has_business_permission(
           p_business_id, 'inventario.activos.gestionar');
$$;

-- Nombre de quien hace el cambio: el empleado del negocio; si no es
-- empleado (el dueño muchas veces no lo es), su perfil.
create or replace function public.fn_fixed_asset_actor_name(p_business_id uuid)
returns text
language sql
stable
security definer
set search_path = public
as $$
  select coalesce(
    (select nullif(btrim(concat_ws(' ', e.first_name, e.last_name)), '')
       from public.employees e
      where e.user_id = auth.uid()
        and e.business_id = p_business_id
      order by (coalesce(e.status, 'active') = 'active') desc
      limit 1),
    (select nullif(btrim(p.full_name), '')
       from public.profiles p where p.id = auth.uid()),
    (select nullif(btrim(p.email), '')
       from public.profiles p where p.id = auth.uid())
  );
$$;

-- La ficha como la lee la app: la fila + la bodega y el responsable
-- embebidos con la misma forma que el SELECT de PostgREST
-- (`warehouses(name)`, `employees(first_name, last_name)`).
-- SECURITY INVOKER: solo la llaman los RPC (que ya corren como definer).
create or replace function public.fn_fixed_asset_to_json(p_asset public.fixed_assets)
returns jsonb
language sql
stable
set search_path = public
as $$
  select (to_jsonb(p_asset) - 'client_request_id')
    || jsonb_build_object(
         'warehouses',
         (select jsonb_build_object('name', w.name)
            from public.warehouses w where w.id = p_asset.warehouse_id),
         'employees',
         (select jsonb_build_object('first_name', e.first_name,
                                    'last_name', e.last_name)
            from public.employees e where e.id = p_asset.assigned_employee_id)
       );
$$;

-- Una fila de historia. Resuelve los nombres en el momento del cambio.
-- SECURITY INVOKER a propósito: llamada directo por un cliente, el RLS (sin
-- policy de INSERT) la rechaza; desde los RPC corre como definer.
-- `clock_timestamp()` y no `now()`: un traslado con cambio de responsable
-- deja dos filas en la MISMA transacción, y con now() empatarían y la línea
-- de tiempo no sabría cuál va primero.
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
  p_changes           jsonb default null
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
    clock_timestamp()
  );
$$;

-- La bodega y el responsable tienen que ser del negocio: un id de otro
-- tenant dejaría una ficha cruzada. La bodega virtual de tránsito no es un
-- lugar donde pueda estar un horno.
create or replace function public.fn_fixed_asset_check_refs(
  p_business_id  uuid,
  p_warehouse_id uuid,
  p_employee_id  uuid
) returns void
language plpgsql
stable
security definer
set search_path = public
as $$
begin
  if p_warehouse_id is not null and not exists (
    select 1 from public.warehouses w
     where w.id = p_warehouse_id
       and w.business_id = p_business_id
       and w.name <> '__IN_TRANSIT__'
  ) then
    raise exception 'WAREHOUSE_NOT_IN_BUSINESS';
  end if;
  if p_employee_id is not null and not exists (
    select 1 from public.employees e
     where e.id = p_employee_id
       and e.business_id = p_business_id
  ) then
    raise exception 'EMPLOYEE_NOT_IN_BUSINESS';
  end if;
end;
$$;

-- Supabase le da EXECUTE a anon/authenticated sobre toda función nueva de
-- `public` (default privileges). Estas no son API: se les quita.
revoke all on function public.fn_fixed_asset_can_manage(uuid)
  from public, anon, authenticated;
revoke all on function public.fn_fixed_asset_actor_name(uuid)
  from public, anon, authenticated;
revoke all on function public.fn_fixed_asset_to_json(public.fixed_assets)
  from public, anon, authenticated;
revoke all on function public.fn_fixed_asset_log(
  uuid, uuid, text, uuid, uuid, text, text, uuid, uuid, text, text, text, jsonb)
  from public, anon, authenticated;
revoke all on function public.fn_fixed_asset_check_refs(uuid, uuid, uuid)
  from public, anon, authenticated;

-- ---------------------------------------------------------------------------
-- 5. Alta
-- ---------------------------------------------------------------------------
-- p_data: { name*, category, brand, model, serial_number, purchase_date
--   (YYYY-MM-DD), purchase_cost, supplier_name, warranty_until,
--   warehouse_id, location_note, assigned_employee_id, status (sin
--   'retired'), notes, client_request_id }

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
  v_status  text := coalesce(nullif(btrim(coalesce(v_data->>'status', '')), ''), 'active');
  v_cost    numeric := nullif(btrim(coalesce(v_data->>'purchase_cost', '')), '')::numeric;
  v_wh      uuid := nullif(btrim(coalesce(v_data->>'warehouse_id', '')), '')::uuid;
  v_emp     uuid := nullif(btrim(coalesce(v_data->>'assigned_employee_id', '')), '')::uuid;
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

  -- Numeración: candado propio por negocio. El reintento se busca DESPUÉS de
  -- tomarlo, para que dos envíos del mismo formulario se serialicen y el
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

  -- El cast adentro del max: AF-100000 no pierde contra AF-99999 comparando
  -- como texto. Y el lpad con largo mínimo: lpad('100000', 5) RECORTA a
  -- '10000' y repetiría un código.
  select coalesce(max(substring(code from 4)::bigint), 0) + 1
    into v_seq
    from public.fixed_assets
   where business_id = p_business_id
     and code ~ '^AF-[0-9]+$';

  insert into public.fixed_assets (
    business_id, code, name, category, brand, model, serial_number,
    purchase_date, purchase_cost, supplier_name, warranty_until,
    warehouse_id, location_note, assigned_employee_id, status, notes,
    client_request_id, created_by
  ) values (
    p_business_id,
    'AF-' || lpad(v_seq::text, greatest(5, length(v_seq::text)), '0'),
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
    v_request,
    auth.uid()
  ) returning * into v_asset;

  perform public.fn_fixed_asset_log(
    p_asset_id        => v_asset.id,
    p_business_id     => p_business_id,
    p_event_type      => 'created',
    p_to_warehouse_id => v_asset.warehouse_id,
    p_to_location     => v_asset.location_note,
    p_to_employee_id  => v_asset.assigned_employee_id,
    p_to_status       => v_asset.status
  );

  return public.fn_fixed_asset_to_json(v_asset);
end;
$$;

-- ---------------------------------------------------------------------------
-- 6. Edición de los datos de la ficha
-- ---------------------------------------------------------------------------
-- p_data: solo las claves que vienen se tocan (una clave con null la borra).
-- Ubicación, responsable y estado se IGNORAN acá: tienen su propio RPC y su
-- propio evento en la historia.

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

  -- Qué cambió, campo por campo. Si nada, no se escribe ni se deja historia
  -- (un «Guardar» sin tocar nada no es un evento).
  select coalesce(
           jsonb_object_agg(n.key, jsonb_build_object('from', o.value,
                                                      'to', n.value)),
           '{}'::jsonb)
    into v_changes
    from jsonb_each(to_jsonb(v_new)) n
    join jsonb_each(to_jsonb(v_old)) o using (key)
   where n.key in ('name','category','brand','model','serial_number',
                   'purchase_date','purchase_cost','supplier_name',
                   'warranty_until','notes')
     and n.value is distinct from o.value;

  if v_changes = '{}'::jsonb then
    return public.fn_fixed_asset_to_json(v_old);
  end if;

  update public.fixed_assets
     set name           = v_new.name,
         category       = v_new.category,
         brand          = v_new.brand,
         model          = v_new.model,
         serial_number  = v_new.serial_number,
         purchase_date  = v_new.purchase_date,
         purchase_cost  = v_new.purchase_cost,
         supplier_name  = v_new.supplier_name,
         warranty_until = v_new.warranty_until,
         notes          = v_new.notes,
         updated_at     = now()
   where id = v_old.id
   returning * into v_new;

  perform public.fn_fixed_asset_log(
    p_asset_id    => v_old.id,
    p_business_id => v_old.business_id,
    p_event_type  => 'updated',
    p_changes     => v_changes
  );

  return public.fn_fixed_asset_to_json(v_new);
end;
$$;

-- ---------------------------------------------------------------------------
-- 7. Traslado / reasignación
-- ---------------------------------------------------------------------------
-- Recibe el estado FINAL: p_warehouse_id / p_employee_id null = «sin bodega»
-- / «sin responsable». Si cambia la bodega o la nota de ubicación queda un
-- 'relocated'; si cambia el responsable, un 'reassigned'. Las dos cosas en
-- una misma llamada dejan dos filas, con la misma nota.

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

-- ---------------------------------------------------------------------------
-- 8. Estado, baja y reactivación
-- ---------------------------------------------------------------------------

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

revoke all on function public.fn_fixed_asset_create(uuid, jsonb) from public, anon;
revoke all on function public.fn_fixed_asset_update(uuid, jsonb) from public, anon;
revoke all on function public.fn_fixed_asset_move(uuid, uuid, text, uuid, text)
  from public, anon;
revoke all on function public.fn_fixed_asset_set_status(uuid, text, text)
  from public, anon;
grant execute on function public.fn_fixed_asset_create(uuid, jsonb)
  to authenticated, service_role;
grant execute on function public.fn_fixed_asset_update(uuid, jsonb)
  to authenticated, service_role;
grant execute on function public.fn_fixed_asset_move(uuid, uuid, text, uuid, text)
  to authenticated, service_role;
grant execute on function public.fn_fixed_asset_set_status(uuid, text, text)
  to authenticated, service_role;

-- ---------------------------------------------------------------------------
-- 9. Permisos en el catálogo de la BD
-- ---------------------------------------------------------------------------
-- Un código que no esté acá lo descarta EN SILENCIO el join del RPC de
-- permisos: el gate en Flutter existe y nunca deja pasar a nadie.

insert into public.permissions (code, name, module, description) values
  ('inventario.activos.acceso',
   'Acceso a activos fijos',
   'inventory',
   'Abre el registro de activos fijos (equipos y mobiliario): ver fichas, historia e imprimir.'),
  ('inventario.activos.gestionar',
   'Gestionar activos fijos',
   'inventory',
   'Da de alta, edita, traslada, reasigna, cambia el estado y da de baja activos fijos.')
on conflict (code) do nothing;

-- Los roles de sistema que ya administran el inventario los reciben. Los
-- roles a la medida no se tocan: el dueño los tilda en Roles y permisos.
insert into public.role_permissions (role_id, permission_id, allow)
select r.id, p.id, true
  from public.roles r
 cross join public.permissions p
 where r.is_system = true
   and lower(r.name) in ('owner', 'admin', 'manager')
   and p.code in ('inventario.activos.acceso', 'inventario.activos.gestionar')
on conflict (role_id, permission_id) do nothing;

notify pgrst, 'reload schema';

commit;
