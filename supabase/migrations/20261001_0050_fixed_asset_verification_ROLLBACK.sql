-- =============================================================================
-- ROLLBACK de 20261001_0050_fixed_asset_verification.sql
--
-- GENERADO POR SCRIPT, no transcrito a mano: las funciones que vuelven
-- (historia, alta, edición, traslado y estado) son el texto exacto de
-- 20260930_0052. Copiar a mano una versión intermedia ya borró funcionalidad
-- en silencio una vez.
--
-- SE NIEGA si ya hay datos que dependen de esta migración: grupos con
-- cantidad > 1 (quitar la columna los volvería «1»), verificaciones, o
-- historia de cantidad / verificación. Los códigos propios de etiqueta se
-- quedan: la columna `code` es de la 0052.
-- =============================================================================

begin;

set local lock_timeout = '5s';

do $$
begin
  if exists (select 1 from public.fixed_assets where quantity > 1) then
    raise exception 'ROLLBACK_BLOCKED: hay activos con cantidad mayor que 1.';
  end if;
  if exists (select 1 from public.fixed_asset_verifications) then
    raise exception 'ROLLBACK_BLOCKED: ya hay verificaciones registradas.';
  end if;
  if exists (select 1 from public.fixed_asset_movements
              where event_type in ('quantity_changed', 'verified')) then
    raise exception 'ROLLBACK_BLOCKED: la historia ya tiene cambios de cantidad o verificaciones.';
  end if;
end
$$;

drop function if exists public.fn_fixed_asset_verification_start(uuid, uuid, text);
drop function if exists public.fn_fixed_asset_verification_check(uuid, uuid, integer, text, text);
drop function if exists public.fn_fixed_asset_verification_uncheck(uuid, uuid);
drop function if exists public.fn_fixed_asset_verification_add_asset(uuid, jsonb);
drop function if exists public.fn_fixed_asset_verification_close(uuid, jsonb, text);
drop function if exists public.fn_fixed_asset_verification_cancel(uuid, text);
drop function if exists public.fn_fixed_asset_verification_lock(uuid);
drop function if exists public.fn_fixed_asset_verification_to_json(uuid);
drop function if exists public.fn_fixed_asset_check_code(uuid, text, uuid);
drop function if exists public.fn_fixed_asset_parse_quantity(text);

alter table public.fixed_assets
  drop constraint if exists fixed_assets_last_verification_fkey;
drop table if exists public.fixed_asset_verification_lines;
drop table if exists public.fixed_asset_verifications;

drop index if exists public.uq_fixed_assets_business_code_ci;

alter table public.fixed_assets
  drop constraint if exists fixed_assets_quantity_positive,
  drop column if exists quantity,
  drop column if exists last_verified_at,
  drop column if exists last_verification_id;

alter table public.fixed_asset_movements
  drop column if exists from_quantity,
  drop column if exists to_quantity,
  drop column if exists verification_id;

alter table public.fixed_asset_movements
  drop constraint if exists fixed_asset_movements_event_type_check;
alter table public.fixed_asset_movements
  add constraint fixed_asset_movements_event_type_check
  check (event_type in ('created','updated','relocated','reassigned',
                        'status_changed','retired','reactivated'));

drop function if exists public.fn_fixed_asset_log(
  uuid, uuid, text, uuid, uuid, text, text, uuid, uuid, text, text, text, jsonb,
  integer, integer, uuid);

-- ── Historia, tal cual 20260930_0052 ──
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

revoke all on function public.fn_fixed_asset_log(
  uuid, uuid, text, uuid, uuid, text, text, uuid, uuid, text, text, text, jsonb)
  from public, anon, authenticated;

-- ── Alta, edición, traslado y estado, tal cual 20260930_0052 ──
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

comment on column public.fixed_assets.purchase_cost is null;
comment on column public.fixed_assets.code is null;

notify pgrst, 'reload schema';

commit;
