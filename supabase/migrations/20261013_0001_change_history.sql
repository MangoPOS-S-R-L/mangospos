-- =============================================================================
-- 20261013_0001 — Historial de cambios: quién creó, cambió o borró qué, y cuándo
-- =============================================================================
--
-- POR QUÉ. El dueño quiere ver en el dashboard todo lo que se crea, cambia o
-- borra en su negocio, quién lo hizo y qué cambió (antes → después), y que
-- nadie lo pueda editar ni borrar, ni siquiera él. Hoy cada cosa deja rastro
-- en un sitio distinto (order_item_removals, purchase_order_edits,
-- fixed_asset_movements…) y la configuración no deja ninguno. `audit_logs`
-- no sirve: cualquier miembro puede editarla o borrarla.
--
-- CÓMO. La base de datos lo llena sola con triggers; la app solo lo lee. Por
-- eso funciona igual si el cambio viene del POS, del dashboard, del panel de
-- administración o de Supabase Studio.
--
-- QUÉ SE ANOTA
--   1. Configuración y datos maestros (crear, editar y borrar): productos,
--      categorías, menús, modificadores, combos, impuestos y su vínculo con
--      los productos, ofertas, cupones, recetas, insumos, almacenes,
--      empleados, roles, permisos de roles y de usuarios, accesos, clientes,
--      proveedores, zonas, mesas, impresoras, áreas de impresión, cajas,
--      motivos de caja, métodos de pago, cuentas de banco, secuencias NCF y
--      configuración fiscal. `businesses` y `business_settings`: solo edición.
--   2. De la operación, solo lo delicado y con filtros estrechos (WHEN):
--      productos quitados de una cuenta ya enviada (copia de
--      order_item_removals con is_user_action), cuentas anuladas con algo
--      enviado o cobrado, y pagos anulados de una cuenta que sigue viva.
--      No se vigilan órdenes, ítems ni pagos en general: cambian cientos de
--      veces por noche.
--
-- QUÉ NO SE ANOTA (ruido)
--   * Lo que cae en cascada (llaves foráneas, triggers de stock, semillas al
--     crear un negocio): pg_trigger_depth() > 1. Ya lo dice el cambio que lo
--     provocó.
--   * Columnas que se mueven solas: updated_at, posiciones/orden, last_*,
--     latidos de impresoras, el auto-86 (menu_items.auto_disabled y el
--     is_active que lo acompaña), el contador de notas de venta, el número
--     actual de una secuencia NCF cuando lo sube una función (cada factura),
--     usos de un cupón, estado de las mesas. Mesas y negocio usan lista
--     blanca.
--   * Borrar y volver a insertar lo mismo en un guardado (impuestos de un
--     producto, permisos de un rol): se anota el resultado neto de la
--     transacción, no cada paso.
--
-- QUIÉN. auth.uid() es la cuenta logueada (en una tablet compartida es la
-- cuenta de la tablet). El nombre se guarda como foto al momento del cambio
-- (empleado → profiles.full_name → correo), porque borrar una cuenta anonimiza
-- profiles. Sin usuario (cron, service_role, Studio) = «Sistema». En los
-- productos quitados se usa el empleado del PIN (aprobó o anotó el motivo)
-- cuando la app lo manda.
--
-- QUIÉN LO VE. Solo dueño y administradores del negocio
-- (is_admin_of_business). Nadie puede insertar, editar ni borrar desde la app.
--
-- SEGURIDAD. Cada trigger envuelve su cuerpo en un bloque con excepción:
-- si algo falla, avisa con WARNING y el cambio del usuario sigue. Nunca
-- bloquea una venta. Las tablas que no existan en vivo se saltan.
--
-- ATRASADO. Copia al historial los productos quitados por usuarios que ya
-- estaban en order_item_removals (desde 2026-09-19).
--
-- IDEMPOTENTE. ROLLBACK: 20261013_0001_change_history_ROLLBACK.sql
-- Prueba: supabase/tests/change_history_local_test.sh
-- Aplicar en horario de poca venta: crear triggers en orders y payments
-- espera su candado (lock_timeout 5 s; si vence, se vuelve a correr).
-- =============================================================================

begin;

set local lock_timeout = '5s';

create schema if not exists private;

-- ---------------------------------------------------------------------------
-- 1. Tabla
-- ---------------------------------------------------------------------------
create table if not exists public.change_history (
  id                bigserial primary key,
  business_id       uuid not null references public.businesses(id) on delete cascade,
  -- Tabla de origen: menu_items, taxes, order_items, orders, payments…
  table_name        text not null,
  -- Id de lo que cambió (en tablas de vínculo, los dos ids con «:»).
  row_id            text not null,
  -- create | update | delete | void (anular)
  action            text not null
                    check (action in ('create', 'update', 'delete', 'void')),
  -- Lo que cambió, legible: «Pollo frito», «MUEBLE12», «B02»…
  label             text not null default '',
  -- Lo segundo, en vínculos y cuentas: «ITBIS 18%», «Mesero», la mesa…
  context           text not null default '',
  actor_user_id     uuid,
  actor_employee_id uuid,
  -- Foto del nombre al momento del cambio.
  actor_name        text not null default '',
  changed_at        timestamptz not null default clock_timestamp(),
  -- update: {campo: [antes, después]} · create/delete/void: la fila.
  changes           jsonb not null default '{}'::jsonb,
  -- request.path de PostgREST: '/menu_items', '/rpc/fn_x'; null = interno.
  source            text,
  -- Fila de origen cuando se copia de otro registro (order_item_removals.id).
  ref_id            uuid,
  txid              bigint not null default txid_current()
);

create index if not exists change_history_business_time
  on public.change_history (business_id, changed_at desc, id desc);
create index if not exists change_history_business_table_time
  on public.change_history (business_id, table_name, changed_at desc);
create index if not exists change_history_business_row
  on public.change_history (business_id, row_id);
create unique index if not exists change_history_ref_uq
  on public.change_history (ref_id)
  where ref_id is not null;

comment on table public.change_history is
  'Historial de cambios (quién creó, cambió o borró qué). Lo llenan triggers; '
  'la app solo lo lee. Solo dueño y administradores. Ver 20261013_0001.';

-- ---------------------------------------------------------------------------
-- 2. Lectura: solo dueño y administradores; nadie escribe desde la app
-- ---------------------------------------------------------------------------
create or replace function public.fn_change_history_business_ids()
returns setof uuid
language sql
stable
security definer
set search_path = public
as $$
  select b
  from public.current_user_business_ids() b
  where public.is_admin_of_business(b)
$$;

alter table public.change_history enable row level security;

drop policy if exists change_history_select on public.change_history;
create policy change_history_select
  on public.change_history
  for select
  to authenticated
  using (business_id in (select public.fn_change_history_business_ids()));

revoke all on public.change_history from anon, authenticated;
grant select on public.change_history to authenticated;
revoke all on sequence public.change_history_id_seq from anon, authenticated;

revoke all on function public.fn_change_history_business_ids() from public, anon;
grant execute on function public.fn_change_history_business_ids() to authenticated;

-- ---------------------------------------------------------------------------
-- 3. Ayudantes
-- ---------------------------------------------------------------------------

-- Nombre de una persona: el empleado (PIN) o la cuenta que operó.
create or replace function private.fn_change_history_person(
  p_business uuid,
  p_user     uuid,
  p_employee uuid default null
)
returns text
language plpgsql
stable
set search_path = public
as $$
declare
  v_name text;
begin
  if p_employee is not null then
    select nullif(trim(concat_ws(' ', e.first_name, e.last_name)), '')
      into v_name
    from public.employees e
    where e.id = p_employee;
    if v_name is not null then
      return v_name;
    end if;
  end if;

  if p_user is null then
    return 'Sistema';
  end if;

  select nullif(trim(concat_ws(' ', e.first_name, e.last_name)), '')
    into v_name
  from public.employees e
  where e.user_id = p_user
  order by (e.business_id = p_business) desc, e.created_at
  limit 1;
  if v_name is not null then
    return v_name;
  end if;

  select nullif(trim(p.full_name), '')
    into v_name
  from public.profiles p
  where p.id = p_user;
  if v_name is not null then
    return v_name;
  end if;

  select nullif(split_part(u.email, '@', 1), '')
    into v_name
  from auth.users u
  where u.id = p_user;
  return coalesce(v_name, 'Usuario');
end;
$$;

-- ¿Esta columna le dice algo a quien lee el historial?
create or replace function private.fn_change_history_keep(
  p_table  text,
  p_column text,
  p_source text
)
returns boolean
language sql
immutable
as $$
  select case
    when p_column in ('id', 'business_id', 'created_at', 'updated_at',
                      'created_by', 'updated_by', 'version',
                      'sort_order', 'sort_index', 'display_order')
      then false
    -- Orden en la lista; en employees es el puesto y sí cuenta.
    when p_column = 'position' and p_table <> 'employees'
      then false
    when p_column like 'last\_%' or p_column like '%heartbeat%'
      then false
    -- Lista blanca: el resto se mueve solo (estado de la mesa, posición en el
    -- plano, suscripción y cobros del negocio).
    when p_table = 'dining_tables'
      then p_column in ('zone_id', 'code', 'label', 'shape', 'capacity',
                        'is_active')
    when p_table = 'businesses'
      then p_column in ('business_name', 'branch_name', 'business_type',
                        'country', 'address', 'phone', 'email', 'fiscal_name',
                        'fiscal_rnc', 'logo_url', 'slogan',
                        'ticket_footer_message', 'prefer_electronic_billing')
    when p_table = 'menu_items'
      then p_column <> 'auto_disabled'
    when p_table = 'printers'
      then p_column not in ('online', 'status')
    -- El número actual sube con cada factura (una función): solo cuenta si
    -- alguien lo escribió directo en la tabla (Ajustes › NCF).
    when p_table = 'ncf_sequences'
      then p_column <> 'device_id'
       and (p_column <> 'current_number'
            or (p_source is not null and p_source not like '%/rpc/%'))
    when p_table = 'business_settings'
      then p_column not in ('sales_note_count', 'agent_url', 'lan_token')
    when p_table = 'coupons'
      then p_column <> 'times_used'
    when p_table = 'user_businesses'
      then p_column <> 'permissions'
    else true
  end
$$;

-- Valor para mostrar: secretos tapados, imágenes como «imagen», y los ids
-- conocidos como el nombre de lo que señalan (foto al momento del cambio).
create or replace function private.fn_change_history_value(
  p_column text,
  p_value  jsonb,
  p_side   text default 'snap'   -- old | new | snap
)
returns jsonb
language plpgsql
stable
set search_path = public
as $$
declare
  v_text  text := p_value #>> '{}';
  v_ref   text;
  v_row   jsonb;
  v_name  text;
begin
  if p_value is null or jsonb_typeof(p_value) = 'null' then
    return p_value;
  end if;

  if p_column in ('pin', 'pin_hash', 'lan_token')
     or p_column ~ '(password|secret|token|_hash$)' then
    return to_jsonb(case when p_side = 'new' then '•••• (nuevo)' else '••••' end);
  end if;

  if p_column in ('image_url', 'image_path', 'logo_url', 'logo_storage_path') then
    if coalesce(v_text, '') = '' then
      return 'null'::jsonb;
    end if;
    return to_jsonb(case when p_side = 'new' then 'imagen nueva' else 'imagen' end);
  end if;

  if jsonb_typeof(p_value) <> 'string'
     or v_text !~* '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$' then
    return p_value;
  end if;

  if p_column = 'user_id' then
    return to_jsonb(private.fn_change_history_person(null, v_text::uuid));
  end if;

  v_ref := case p_column
    when 'category_id'           then 'categories'
    when 'zone_id'               then 'zones'
    when 'tax_id'                then 'taxes'
    when 'role_id'               then 'roles'
    when 'group_id'              then 'modifier_groups'
    when 'menu_id'               then 'menus'
    when 'menu_item_id'          then 'menu_items'
    when 'item_id'               then 'menu_items'
    when 'inventory_item_id'     then 'inventory_items'
    when 'warehouse_id'          then 'warehouses'
    when 'supplier_id'           then 'suppliers'
    when 'preferred_supplier_id' then 'suppliers'
    when 'promotion_id'          then 'promotions'
    when 'print_area_id'         then 'print_areas'
    when 'printer_id'            then 'printers'
    when 'receipt_printer_id'    then 'printers'
    when 'fallback_printer_id'   then 'printers'
    when 'permission_id'         then 'permissions'
    when 'payment_method_id'     then 'payment_methods'
    when 'cash_register_id'      then 'cash_registers'
    when 'employee_id'           then 'employees'
    when 'keeper_employee_id'    then 'employees'
    when 'accounting_account_id' then 'accounting_accounts'
  end;
  if v_ref is null or to_regclass('public.' || v_ref) is null then
    return p_value;
  end if;

  -- Sin bloque de excepción propio (sería una subtransacción por columna):
  -- si algo falla, lo ataja el trigger que llamó.
  execute format('select to_jsonb(t) from public.%I t where t.id = $1', v_ref)
    into v_row
    using v_text::uuid;
  v_name := coalesce(
    nullif(trim(concat_ws(' ', v_row ->> 'first_name', v_row ->> 'last_name')), ''),
    nullif(v_row ->> 'name', ''),
    nullif(v_row ->> 'label', ''),
    nullif(v_row ->> 'code', ''));
  return coalesce(to_jsonb(v_name), p_value);
end;
$$;

-- Foto de una fila (crear/borrar) sin lo que no le dice nada a nadie.
create or replace function private.fn_change_history_snapshot(
  p_table  text,
  p_row    jsonb,
  p_source text
)
returns jsonb
language sql
stable
as $$
  select coalesce(jsonb_object_agg(
           e.key, private.fn_change_history_value(e.key, e.value)), '{}'::jsonb)
  from jsonb_each(p_row) e
  where private.fn_change_history_keep(p_table, e.key, p_source)
    and jsonb_typeof(e.value) <> 'null'
$$;

-- Negocio, id y etiquetas de una fila. Las tablas de vínculo no traen
-- business_id: sale del padre.
create or replace function private.fn_change_history_scope(
  p_table text,
  p_row   jsonb,
  out business_id uuid,
  out row_id      text,
  out label       text,
  out context     text
)
language plpgsql
stable
set search_path = public
as $$
declare
  v_parent jsonb;
begin
  row_id := p_row ->> 'id';

  case p_table
    when 'businesses' then
      business_id := (p_row ->> 'id')::uuid;
      label := concat_ws(' · ', nullif(p_row ->> 'business_name', ''),
                                nullif(p_row ->> 'branch_name', ''));

    when 'dining_tables' then
      select z.business_id, z.name
        into business_id, context
      from public.zones z
      where z.id = (p_row ->> 'zone_id')::uuid;
      label := coalesce(nullif(p_row ->> 'label', ''), p_row ->> 'code');

    when 'employees' then
      business_id := (p_row ->> 'business_id')::uuid;
      label := trim(concat_ws(' ', p_row ->> 'first_name', p_row ->> 'last_name'));

    when 'user_businesses' then
      business_id := (p_row ->> 'business_id')::uuid;
      label := private.fn_change_history_person(business_id, (p_row ->> 'user_id')::uuid);
      context := p_row ->> 'role';

    when 'menu_item_taxes' then
      select m.business_id, m.name
        into business_id, label
      from public.menu_items m
      where m.id = (p_row ->> 'item_id')::uuid;
      select t.name into context
      from public.taxes t
      where t.id = (p_row ->> 'tax_id')::uuid;
      row_id := concat(p_row ->> 'item_id', ':', p_row ->> 'tax_id');

    when 'menu_item_groups' then
      select m.business_id, m.name
        into business_id, label
      from public.menu_items m
      where m.id = (p_row ->> 'menu_item_id')::uuid;
      select g.name into context
      from public.modifier_groups g
      where g.id = (p_row ->> 'group_id')::uuid;
      row_id := concat(p_row ->> 'menu_item_id', ':', p_row ->> 'group_id');

    when 'employee_roles' then
      select e.business_id, trim(concat_ws(' ', e.first_name, e.last_name))
        into business_id, label
      from public.employees e
      where e.id = (p_row ->> 'employee_id')::uuid;
      select r.name into context
      from public.roles r
      where r.id = (p_row ->> 'role_id')::uuid;
      row_id := concat(p_row ->> 'employee_id', ':', p_row ->> 'role_id');

    when 'role_permissions' then
      select r.business_id, r.name
        into business_id, label
      from public.roles r
      where r.id = (p_row ->> 'role_id')::uuid;
      select coalesce(nullif(p.name, ''), p.code) into context
      from public.permissions p
      where p.id = (p_row ->> 'permission_id')::uuid;
      row_id := concat(p_row ->> 'role_id', ':', p_row ->> 'permission_id');

    when 'user_permission_overrides' then
      business_id := (p_row ->> 'business_id')::uuid;
      label := private.fn_change_history_person(business_id, (p_row ->> 'user_id')::uuid);
      select coalesce(nullif(p.name, ''), p.code) into context
      from public.permissions p
      where p.id = (p_row ->> 'permission_id')::uuid;
      row_id := concat(p_row ->> 'user_id', ':', p_row ->> 'permission_id');

    when 'recipes' then
      if p_row ->> 'menu_item_id' is not null then
        select m.business_id, m.name
          into business_id, label
        from public.menu_items m
        where m.id = (p_row ->> 'menu_item_id')::uuid;
      end if;
      if business_id is null and p_row ->> 'inventory_item_id' is not null then
        select i.business_id, i.name
          into business_id, label
        from public.inventory_items i
        where i.id = (p_row ->> 'inventory_item_id')::uuid;
      end if;

    when 'recipe_ingredients' then
      select to_jsonb(r) into v_parent
      from public.recipes r
      where r.id = (p_row ->> 'recipe_id')::uuid;
      if v_parent is not null then
        select s.business_id, s.label
          into business_id, label
        from private.fn_change_history_scope('recipes', v_parent) s;
      end if;
      select i.name into context
      from public.inventory_items i
      where i.id = (p_row ->> 'inventory_item_id')::uuid;

    when 'bank_accounts' then
      business_id := (p_row ->> 'business_id')::uuid;
      label := concat_ws(' · ', nullif(p_row ->> 'bank_name', ''),
                                nullif(p_row ->> 'alias', ''));

    else
      business_id := (p_row ->> 'business_id')::uuid;
      label := coalesce(
        nullif(p_row ->> 'name', ''),
        nullif(p_row ->> 'label', ''),
        nullif(p_row ->> 'code', ''),
        nullif(p_row ->> 'prefix', ''),
        nullif(p_row ->> 'business_legal_name', ''),
        '');
  end case;

  label := coalesce(label, '');
  context := coalesce(context, '');
end;
$$;

-- Junta dos pasos de la misma fila en la misma transacción.
--   null           → no queda nada (crear y borrar; borrar y volver a crear igual)
--   {action,changes} → reemplaza el paso anterior
--   {}             → no se juntan: se anota aparte
create or replace function private.fn_change_history_merge(
  p_prev_action  text,
  p_prev_changes jsonb,
  p_action       text,
  p_changes      jsonb
)
returns jsonb
language plpgsql
immutable
as $$
declare
  v_out jsonb;
  v_before jsonb;
  k text;
begin
  if p_prev_action = 'create' and p_action = 'update' then
    v_out := p_prev_changes;
    for k in select jsonb_object_keys(p_changes) loop
      if jsonb_typeof(p_changes -> k -> 1) = 'null' then
        v_out := v_out - k;
      else
        v_out := v_out || jsonb_build_object(k, p_changes -> k -> 1);
      end if;
    end loop;
    return jsonb_build_object('action', 'create', 'changes', v_out);
  end if;

  if p_prev_action = 'create' and p_action = 'delete' then
    return null;
  end if;

  if p_prev_action = 'update' and p_action = 'update' then
    v_out := p_prev_changes;
    for k in select jsonb_object_keys(p_changes) loop
      v_before := case when v_out ? k then v_out -> k -> 0 else p_changes -> k -> 0 end;
      if v_before is not distinct from p_changes -> k -> 1 then
        v_out := v_out - k;
      else
        v_out := v_out || jsonb_build_object(k, jsonb_build_array(v_before, p_changes -> k -> 1));
      end if;
    end loop;
    if v_out = '{}'::jsonb then
      return null;
    end if;
    return jsonb_build_object('action', 'update', 'changes', v_out);
  end if;

  if p_prev_action = 'update' and p_action = 'delete' then
    -- Se borró lo editado: la foto queda como estaba antes de editar.
    v_out := p_changes;
    for k in select jsonb_object_keys(p_prev_changes) loop
      if jsonb_typeof(p_prev_changes -> k -> 0) = 'null' then
        v_out := v_out - k;
      else
        v_out := v_out || jsonb_build_object(k, p_prev_changes -> k -> 0);
      end if;
    end loop;
    return jsonb_build_object('action', 'delete', 'changes', v_out);
  end if;

  if p_prev_action = 'delete' and p_action = 'create' then
    -- Borrar y volver a insertar: solo cuenta lo que cambió.
    v_out := '{}'::jsonb;
    for k in
      select jsonb_object_keys(p_prev_changes)
      union
      select jsonb_object_keys(p_changes)
    loop
      if (p_prev_changes -> k) is distinct from (p_changes -> k) then
        v_out := v_out || jsonb_build_object(k, jsonb_build_array(
          coalesce(p_prev_changes -> k, 'null'::jsonb),
          coalesce(p_changes -> k, 'null'::jsonb)));
      end if;
    end loop;
    if v_out = '{}'::jsonb then
      return null;
    end if;
    return jsonb_build_object('action', 'update', 'changes', v_out);
  end if;

  return '{}'::jsonb;
end;
$$;

-- ---------------------------------------------------------------------------
-- 4. Trigger general (configuración y datos maestros)
-- ---------------------------------------------------------------------------
create or replace function public.fn_change_history_record()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  v_old     jsonb := case when tg_op <> 'INSERT' then to_jsonb(old) end;
  v_new     jsonb := case when tg_op <> 'DELETE' then to_jsonb(new) end;
  v_source  text  := nullif(current_setting('request.path', true), '');
  v_actor   uuid  := auth.uid();
  v_scope   record;
  v_action  text;
  v_changes jsonb := '{}'::jsonb;
  v_prev    record;
  v_merged  jsonb;
  k         text;
begin
  -- Lo que cae en cascada ya lo dice el cambio que lo provocó.
  if pg_trigger_depth() > 1 then
    return null;
  end if;
  -- Valores por defecto que siembra el sistema: no son cambios de nadie.
  if v_source like '%/rpc/fn_seed\_%' then
    return null;
  end if;

  begin
    select * into v_scope
    from private.fn_change_history_scope(tg_table_name, coalesce(v_new, v_old));
    if v_scope.business_id is null or v_scope.row_id is null then
      return null;
    end if;
    -- Se está borrando el negocio completo: no hay a quién contárselo.
    if not exists (select 1 from public.businesses b where b.id = v_scope.business_id) then
      return null;
    end if;

    if tg_op = 'UPDATE' then
      v_action := 'update';
      for k in select jsonb_object_keys(v_old || v_new) loop
        continue when not private.fn_change_history_keep(tg_table_name, k, v_source);
        if (v_old -> k) is distinct from (v_new -> k) then
          v_changes := v_changes || jsonb_build_object(k, jsonb_build_array(
            coalesce(private.fn_change_history_value(k, v_old -> k, 'old'), 'null'::jsonb),
            coalesce(private.fn_change_history_value(k, v_new -> k, 'new'), 'null'::jsonb)));
        end if;
      end loop;
      -- El auto-86 (stock en cero) apaga y prende el producto solo.
      if tg_table_name = 'menu_items'
         and (v_old -> 'auto_disabled') is distinct from (v_new -> 'auto_disabled') then
        v_changes := v_changes - 'is_active';
      end if;
      if v_changes = '{}'::jsonb then
        return null;
      end if;
    else
      v_action := case tg_op when 'INSERT' then 'create' else 'delete' end;
      v_changes := private.fn_change_history_snapshot(
        tg_table_name, coalesce(v_new, v_old), v_source);
    end if;

    -- Un mismo guardado puede tocar la fila varias veces: se anota el neto.
    select h.id, h.action, h.changes
      into v_prev
    from public.change_history h
    where h.business_id = v_scope.business_id
      and h.row_id = v_scope.row_id
      and h.table_name = tg_table_name
      and h.txid = txid_current()
      and h.ref_id is null
    order by h.id desc
    limit 1;

    if v_prev.id is not null then
      v_merged := private.fn_change_history_merge(
        v_prev.action, v_prev.changes, v_action, v_changes);
      if v_merged is null then
        delete from public.change_history h where h.id = v_prev.id;
        return null;
      elsif v_merged ? 'action' then
        update public.change_history h
           set action  = v_merged ->> 'action',
               changes = v_merged -> 'changes',
               label   = coalesce(nullif(v_scope.label, ''), h.label),
               context = coalesce(nullif(v_scope.context, ''), h.context)
         where h.id = v_prev.id;
        return null;
      end if;
    end if;

    insert into public.change_history (
      business_id, table_name, row_id, action, label, context,
      actor_user_id, actor_name, changes, source
    )
    values (
      v_scope.business_id, tg_table_name, v_scope.row_id, v_action,
      v_scope.label, v_scope.context, v_actor,
      private.fn_change_history_person(v_scope.business_id, v_actor),
      v_changes, v_source
    );
  exception when others then
    raise warning 'fn_change_history_record(%): % (%)', tg_table_name, sqlerrm, sqlstate;
  end;
  return null;
end;
$$;

-- ---------------------------------------------------------------------------
-- 5. Operación: productos quitados de una cuenta (copia de order_item_removals)
-- ---------------------------------------------------------------------------
-- order_item_removals ya anota cada producto ENVIADO que se quita o se baja
-- (lo no enviado nunca se anota). Aquí solo se copian los que hizo un usuario
-- (is_user_action); dividir la cuenta reescribe ítems y no es nadie borrando.
-- El motivo y el empleado del PIN llegan después (fn_note_order_item_removal,
-- fn_approve_order_item_removal): la misma fila del historial se actualiza.
create or replace function private.fn_change_history_upsert_removal(p jsonb)
returns void
language plpgsql
set search_path = public
as $$
declare
  v_business uuid := (p ->> 'business_id')::uuid;
  v_user     uuid := (p ->> 'removed_by')::uuid;
  v_employee uuid := coalesce((p ->> 'approved_by_employee_id')::uuid,
                              (p ->> 'reason_employee_id')::uuid);
  v_reduced  boolean := p ->> 'change_type' = 'reduced';
  v_author   text;
  v_changes  jsonb;
begin
  if v_business is null or coalesce((p ->> 'is_user_action')::boolean, false) = false then
    return;
  end if;

  if p ->> 'author_employee_id' is not null then
    v_author := private.fn_change_history_person(
      v_business, null, (p ->> 'author_employee_id')::uuid);
  end if;

  v_changes := jsonb_strip_nulls(jsonb_build_object(
    'quantity', case
                  when v_reduced then jsonb_build_array(
                    (p -> 'qty_before'), (p -> 'qty_after'))
                  else p -> 'quantity'
                end,
    'unit_price', p -> 'unit_price',
    'amount', to_jsonb(round(coalesce((p ->> 'quantity')::numeric, 0)
                             * coalesce((p ->> 'unit_price')::numeric, 0), 2)),
    'reason', nullif(p ->> 'reason', ''),
    'kitchen_sent', to_jsonb(p ->> 'kitchen_sent_at' is not null),
    'added_by', v_author,
    'notes', nullif(p ->> 'notes', '')));

  insert into public.change_history (
    business_id, table_name, row_id, action, label, context,
    actor_user_id, actor_employee_id, actor_name, changed_at, changes,
    source, ref_id
  )
  values (
    v_business, 'order_items', coalesce(p ->> 'item_id', p ->> 'id'),
    case when v_reduced then 'update' else 'delete' end,
    coalesce(nullif(p ->> 'product_name', ''), 'Producto'),
    coalesce(nullif(p ->> 'table_name', ''), ''),
    v_user, v_employee,
    private.fn_change_history_person(v_business, v_user, v_employee),
    coalesce((p ->> 'removed_at')::timestamptz, clock_timestamp()),
    v_changes, nullif(p ->> 'request_path', ''), (p ->> 'id')::uuid
  )
  on conflict (ref_id) where ref_id is not null do update
    set actor_employee_id = excluded.actor_employee_id,
        actor_name        = excluded.actor_name,
        changes           = excluded.changes;
end;
$$;

create or replace function public.fn_change_history_on_removal()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  begin
    perform private.fn_change_history_upsert_removal(to_jsonb(new));
  exception when others then
    raise warning 'fn_change_history_on_removal: % (%)', sqlerrm, sqlstate;
  end;
  return null;
end;
$$;

-- ---------------------------------------------------------------------------
-- 6. Operación: cuenta anulada (con algo enviado a cocina o cobrado)
-- ---------------------------------------------------------------------------
create or replace function public.fn_change_history_on_order_void()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  v_business uuid;
  v_table    text;
  v_paid     numeric;
  v_items    integer;
  v_ncf      text;
  v_actor    uuid := auth.uid();
begin
  begin
    select ts.business_id,
           case
             when dt.id is not null then coalesce(dt.label, dt.code, 'Mesa')
             when ts.origin::text = 'manual' then 'Venta manual'
             when ts.origin::text in ('quick', 'quick_sale') then 'Venta rápida'
             else 'Venta'
           end
      into v_business, v_table
    from public.table_sessions ts
    left join public.dining_tables dt on dt.id = ts.table_id
    where ts.id = new.session_id;
    v_business := coalesce((to_jsonb(new) ->> 'business_id')::uuid, v_business);
    if v_business is null then
      return null;
    end if;

    if exists (
      select 1 from public.change_history h
      where h.business_id = v_business
        and h.table_name = 'orders'
        and h.row_id = new.id::text
        and h.action = 'void'
    ) then
      return null;
    end if;

    -- La anulación pasa la orden a 'void' ANTES de cancelar los pagos y los
    -- ítems: aquí todavía se ven como estaban.
    select coalesce(sum(p.amount), 0)
      into v_paid
    from public.payments p
    where p.order_id = new.id
      and p.status = 'completed';

    select count(*)
      into v_items
    from public.order_items i
    where i.order_id = new.id
      and coalesce(i.status::text, 'draft') <> 'void'
      and (coalesce(i.status::text, 'draft') <> 'draft'
           or to_jsonb(i) ->> 'kitchen_sent_at' is not null);

    -- Mesa vacía o solo borradores: no salió nada ni se cobró nada.
    if v_paid = 0 and v_items = 0 then
      return null;
    end if;

    select string_agg(distinct coalesce(to_jsonb(fd) ->> 'ncf',
                                        to_jsonb(fd) ->> 'ncf_number'), ', ')
      into v_ncf
    from public.payments p
    join public.fiscal_documents fd on fd.id = p.fiscal_document_id
    where p.order_id = new.id
      and p.status = 'completed';

    insert into public.change_history (
      business_id, table_name, row_id, action, label, context,
      actor_user_id, actor_name, changes, source
    )
    values (
      v_business, 'orders', new.id::text, 'void', coalesce(v_table, 'Venta'),
      coalesce(v_ncf, ''), v_actor,
      private.fn_change_history_person(v_business, v_actor),
      jsonb_strip_nulls(jsonb_build_object(
        'total', new.total,
        'paid_total', nullif(v_paid, 0),
        'items_count', v_items,
        'ncf', v_ncf)),
      nullif(current_setting('request.path', true), '')
    );
  exception when others then
    raise warning 'fn_change_history_on_order_void: % (%)', sqlerrm, sqlstate;
  end;
  return null;
end;
$$;

-- ---------------------------------------------------------------------------
-- 7. Operación: pago anulado de una cuenta que sigue viva
-- ---------------------------------------------------------------------------
create or replace function public.fn_change_history_on_payment_void()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  v_status   text;
  v_table    text;
  v_method   text;
  v_ncf      text;
  v_actor    uuid := auth.uid();
begin
  begin
    if new.order_id is null or new.business_id is null then
      return null;
    end if;

    select o.status_ext::text,
           case
             when dt.id is not null then coalesce(dt.label, dt.code, 'Mesa')
             when ts.origin::text = 'manual' then 'Venta manual'
             when ts.origin::text in ('quick', 'quick_sale') then 'Venta rápida'
             else 'Venta'
           end
      into v_status, v_table
    from public.orders o
    left join public.table_sessions ts on ts.id = o.session_id
    left join public.dining_tables dt on dt.id = ts.table_id
    where o.id = new.order_id;
    -- Anulación total: ya la anotó la orden.
    if v_status is null or v_status = 'void' then
      return null;
    end if;

    select pm.name into v_method
    from public.payment_methods pm
    where pm.id = new.payment_method_id;

    if new.fiscal_document_id is not null then
      select coalesce(to_jsonb(fd) ->> 'ncf', to_jsonb(fd) ->> 'ncf_number')
        into v_ncf
      from public.fiscal_documents fd
      where fd.id = new.fiscal_document_id;
    end if;

    insert into public.change_history (
      business_id, table_name, row_id, action, label, context,
      actor_user_id, actor_name, changes, source
    )
    values (
      new.business_id, 'payments', new.id::text, 'void', coalesce(v_table, 'Venta'),
      coalesce(v_method, ''), v_actor,
      private.fn_change_history_person(new.business_id, v_actor),
      jsonb_strip_nulls(jsonb_build_object(
        'amount', new.amount,
        'payment_method', v_method,
        'reference', nullif(new.reference, ''),
        'ncf', v_ncf,
        'status', jsonb_build_array(old.status, new.status))),
      nullif(current_setting('request.path', true), '')
    );
  exception when others then
    raise warning 'fn_change_history_on_payment_void: % (%)', sqlerrm, sqlstate;
  end;
  return null;
end;
$$;

-- ---------------------------------------------------------------------------
-- 8. Lo que ya estaba: productos quitados por usuarios desde 2026-09-19
-- ---------------------------------------------------------------------------
-- ANTES de crear los triggers: crear un trigger toma un candado que frena las
-- escrituras en esa tabla hasta el COMMIT. Si la copia fuera después, orders,
-- payments y menu_items quedarían frenadas mientras dura (= ventas paradas).
do $$
begin
  perform private.fn_change_history_upsert_removal(to_jsonb(r))
  from public.order_item_removals r
  where r.is_user_action
    and not exists (
      select 1 from public.change_history h where h.ref_id = r.id);
end;
$$;

-- ---------------------------------------------------------------------------
-- 9. Triggers (lo último: sus candados duran hasta el COMMIT)
-- ---------------------------------------------------------------------------
do $$
declare
  t text;
begin
  foreach t in array array[
    -- Menú
    'menu_items', 'categories', 'menus', 'modifier_groups', 'modifiers',
    'menu_item_groups', 'menu_item_taxes', 'combo_groups', 'promotions',
    'coupons', 'taxes',
    -- Recetas e inventario
    'recipes', 'recipe_ingredients', 'inventory_items', 'warehouses',
    -- Personal y permisos
    'employees', 'employee_roles', 'roles', 'role_permissions',
    'user_permission_overrides', 'user_businesses',
    -- Clientes y proveedores
    'customers', 'suppliers',
    -- Salón e impresión
    'zones', 'dining_tables', 'printers', 'print_areas',
    -- Caja y fiscal
    'cash_registers', 'cash_transaction_reasons', 'payment_methods',
    'bank_accounts', 'ncf_sequences', 'fiscal_settings'
  ] loop
    if to_regclass('public.' || t) is null then
      raise notice 'change_history: la tabla % no existe, se salta', t;
      continue;
    end if;
    execute format('drop trigger if exists trg_zz_change_history on public.%I', t);
    execute format(
      'create trigger trg_zz_change_history '
      'after insert or update or delete on public.%I '
      'for each row execute function public.fn_change_history_record()', t);
  end loop;

  -- Una fila por negocio: solo la edición.
  foreach t in array array['businesses', 'business_settings'] loop
    if to_regclass('public.' || t) is null then
      continue;
    end if;
    execute format('drop trigger if exists trg_zz_change_history on public.%I', t);
    execute format(
      'create trigger trg_zz_change_history '
      'after update on public.%I '
      'for each row execute function public.fn_change_history_record()', t);
  end loop;
end;
$$;

drop trigger if exists trg_zz_change_history on public.order_item_removals;
create trigger trg_zz_change_history
  after insert or update on public.order_item_removals
  for each row
  execute function public.fn_change_history_on_removal();

drop trigger if exists trg_zz_change_history_void on public.orders;
create trigger trg_zz_change_history_void
  after update of status_ext on public.orders
  for each row
  when (new.status_ext::text = 'void'
        and old.status_ext::text is distinct from 'void')
  execute function public.fn_change_history_on_order_void();

drop trigger if exists trg_zz_change_history_void on public.payments;
create trigger trg_zz_change_history_void
  after update of status on public.payments
  for each row
  when (old.status = 'completed'
        and new.status in ('cancelled', 'void', 'refunded'))
  execute function public.fn_change_history_on_payment_void();

-- Lo quitado mientras corría la copia de arriba (ya con el trigger puesto):
-- segunda pasada, corta. La guarda de ref_id evita duplicar.
do $$
begin
  perform private.fn_change_history_upsert_removal(to_jsonb(r))
  from public.order_item_removals r
  where r.is_user_action
    and not exists (
      select 1 from public.change_history h where h.ref_id = r.id);
end;
$$;

-- ---------------------------------------------------------------------------
-- 10. Permisos de las funciones
-- ---------------------------------------------------------------------------
revoke all on function private.fn_change_history_person(uuid, uuid, uuid) from public;
revoke all on function private.fn_change_history_keep(text, text, text) from public;
revoke all on function private.fn_change_history_value(text, jsonb, text) from public;
revoke all on function private.fn_change_history_snapshot(text, jsonb, text) from public;
revoke all on function private.fn_change_history_scope(text, jsonb) from public;
revoke all on function private.fn_change_history_merge(text, jsonb, text, jsonb) from public;
revoke all on function private.fn_change_history_upsert_removal(jsonb) from public;
revoke all on function public.fn_change_history_record() from public, anon, authenticated;
revoke all on function public.fn_change_history_on_removal() from public, anon, authenticated;
revoke all on function public.fn_change_history_on_order_void() from public, anon, authenticated;
revoke all on function public.fn_change_history_on_payment_void() from public, anon, authenticated;

commit;
