-- =============================================================================
-- 20260929_0001_add_item_idempotent.sql
-- Alta de ítem idempotente por client_op_id.
-- Plan de cierre offline (docs/PLAN_CIERRE_OFFLINE_INTRANET_WINDOWS.md),
-- P0 "Ventas, items": respuesta perdida + reintento no puede duplicar ítems.
--
-- Problema: fn_add_item_from_menu no tiene llave de idempotencia. Si el INSERT
-- hace commit y se pierde la respuesta (timeout, WAN mala, proxy del Hub que
-- corta a los 5 s, app cerrada antes del acuse), la app encola la misma alta y
-- el replay crea un SEGUNDO ítem: se cobra doble, sale doble comanda y se
-- descuenta doble inventario.
--
-- Solución: la app genera un client_op_id (uuid) por cada toque y lo manda en
-- el intento online, en la acción encolada y en el proxy del Hub. Este wrapper
-- registra el op en order_item_client_ops EN LA MISMA TRANSACCIÓN que el
-- INSERT del ítem. Un reintento con el mismo id devuelve el ítem ya creado.
--
--   * Dos reintentos simultáneos: el segundo espera en el índice único de la
--     bitácora hasta que el primero termine; si el primero hizo commit devuelve
--     su ítem, si hizo rollback el segundo hace el alta.
--   * Si el alta falla (orden cobrada MP401, producto inexistente, etc.) la
--     fila de la bitácora se revierte con todo lo demás: el reintento es un
--     alta nueva.
--   * Si el ítem se borró después, el op queda registrado y el reintento NO lo
--     resucita: devuelve replayed=true, item_exists=false.
--
-- NO reemplaza fn_add_item_from_menu: la BD viva diverge del repo, así que el
-- wrapper la llama tal cual, con la firma de 6 args que la app ya usa. La app
-- nueva BLOQUEA el alta si esta función no existe (PGRST202): aplicar esta
-- migración antes de desplegar el cliente nuevo.
--
-- Seguridad: la función SECURITY DEFINER comprueba pertenencia al negocio
-- antes de consultar la bitácora. La tabla tiene RLS sin políticas.
--
-- Incluye además (misma familia de problema):
--   * fn_add_offer_deal_idempotent: el tile de oferta con el mismo contrato.
--   * fn_replace_order_item_modifiers: reemplazo atómico de los extras de un
--     ítem (antes DELETE e INSERT en dos viajes; un corte entre ambos dejaba
--     el ítem sin extras).
--
-- Rollback: 20260929_0001_add_item_idempotent_ROLLBACK.sql
-- =============================================================================

begin;

create table if not exists public.order_item_client_ops (
  client_op_id uuid primary key,
  order_id uuid not null,
  request_payload jsonb not null,
  -- Se llena en la misma transacción del alta: una fila confirmada siempre
  -- tiene item_id. Sin FK a order_items a propósito: si el ítem se borra, el
  -- op debe seguir registrado para que un reintento tardío no lo recree.
  item_id uuid,
  created_at timestamptz not null default now()
);

comment on table public.order_item_client_ops is
  'Bitácora de altas de ítem por client_op_id (idempotencia). Solo la escribe fn_add_item_from_menu_idempotent.';

alter table public.order_item_client_ops enable row level security;
revoke all on table public.order_item_client_ops from anon, authenticated;

create or replace function public.fn_add_item_from_menu_idempotent(
  p_client_op_id uuid,
  p_order_id uuid,
  p_menu_item_id uuid,
  p_qty numeric default 1,
  p_check_position integer default 1,
  p_is_takeout boolean default false,
  p_notes text default null,
  p_created_by_employee_id uuid default null
) returns jsonb
language plpgsql
security definer
set search_path to 'public'
as $$
declare
  v_existing public.order_item_client_ops%rowtype;
  v_item_id uuid;
  v_rows integer;
  v_business_id uuid;
  v_request jsonb;
begin
  if p_client_op_id is null then
    raise exception 'CLIENT_OP_ID_REQUIRED' using errcode = '22004';
  end if;
  select coalesce(ts.business_id, z.business_id) into v_business_id
  from public.orders o
  join public.table_sessions ts on ts.id = o.session_id
  left join public.dining_tables dt on dt.id = ts.table_id
  left join public.zones z on z.id = dt.zone_id
  where o.id = p_order_id;
  if v_business_id is null or not (
    coalesce(auth.role(), '') = 'service_role'
    or coalesce(public.is_member_of_business(v_business_id), false)
  ) then
    raise exception 'UNAUTHORIZED_BUSINESS' using errcode = '42501';
  end if;
  v_request := jsonb_build_object(
    'kind', 'menu', 'menu_item_id', p_menu_item_id,
    'qty', p_qty, 'check_position', p_check_position,
    'is_takeout', p_is_takeout, 'notes', p_notes,
    'employee_id', p_created_by_employee_id
  );

  -- Reclamar el op ANTES del alta. Un reintento concurrente con el mismo id
  -- queda esperando aquí hasta que esta transacción termine.
  insert into public.order_item_client_ops (client_op_id, order_id, request_payload)
  values (p_client_op_id, p_order_id, v_request)
  on conflict (client_op_id) do nothing;
  get diagnostics v_rows = row_count;

  if v_rows = 0 then
    select * into v_existing
    from public.order_item_client_ops
    where client_op_id = p_client_op_id;

    if v_existing.order_id is distinct from p_order_id
       or v_existing.request_payload is distinct from v_request then
      raise exception 'CLIENT_OP_ID_CONFLICT'
        using errcode = 'MP410',
              detail = format('op %s pertenece a otra orden', p_client_op_id);
    end if;

    return jsonb_build_object(
      'item_id', v_existing.item_id,
      'replayed', true,
      'item_exists', exists (
        select 1 from public.order_items where id = v_existing.item_id
      )
    );
  end if;

  v_item_id := public.fn_add_item_from_menu(
    p_order_id,
    p_menu_item_id,
    p_qty,
    p_check_position,
    p_is_takeout,
    p_notes
  );

  -- Autor del ítem en la misma transacción (antes era un UPDATE aparte desde
  -- la app, que se perdía si caía la red justo después del alta).
  if p_created_by_employee_id is not null then
    update public.order_items
       set created_by_employee_id = p_created_by_employee_id
     where id = v_item_id;
  end if;

  update public.order_item_client_ops
     set item_id = v_item_id
   where client_op_id = p_client_op_id;

  return jsonb_build_object(
    'item_id', v_item_id,
    'replayed', false,
    'item_exists', true
  );
end;
$$;

-- Supabase concede EXECUTE a anon por privilegios por defecto: revocar
-- explícito además de public.
revoke all on function public.fn_add_item_from_menu_idempotent(
  uuid, uuid, uuid, numeric, integer, boolean, text, uuid
) from public, anon;
grant execute on function public.fn_add_item_from_menu_idempotent(
  uuid, uuid, uuid, numeric, integer, boolean, text, uuid
) to authenticated, service_role;

-- -----------------------------------------------------------------------------
-- Oferta (tile "deal"): mismo contrato que el alta normal, sobre la misma
-- bitácora. Llama a la fn_add_offer_deal viva tal cual. Si esa función falla
-- (p. ej. el resolvedor de impuestos), todo se revierte y la app puede caer al
-- alta normal con el MISMO client_op_id sin riesgo de duplicar.
-- -----------------------------------------------------------------------------
create or replace function public.fn_add_offer_deal_idempotent(
  p_client_op_id uuid,
  p_order_id uuid,
  p_menu_item_id uuid,
  p_qty numeric default 1,
  p_discount numeric default 0,
  p_name text default null,
  p_promotion_id uuid default null,
  p_check_position integer default 1,
  p_created_by_employee_id uuid default null
) returns jsonb
language plpgsql
security definer
set search_path to 'public'
as $$
declare
  v_existing public.order_item_client_ops%rowtype;
  v_item_id uuid;
  v_rows integer;
  v_business_id uuid;
  v_request jsonb;
begin
  if p_client_op_id is null then
    raise exception 'CLIENT_OP_ID_REQUIRED' using errcode = '22004';
  end if;
  select coalesce(ts.business_id, z.business_id) into v_business_id
  from public.orders o
  join public.table_sessions ts on ts.id = o.session_id
  left join public.dining_tables dt on dt.id = ts.table_id
  left join public.zones z on z.id = dt.zone_id
  where o.id = p_order_id;
  if v_business_id is null or not (
    coalesce(auth.role(), '') = 'service_role'
    or coalesce(public.is_member_of_business(v_business_id), false)
  ) then
    raise exception 'UNAUTHORIZED_BUSINESS' using errcode = '42501';
  end if;
  v_request := jsonb_build_object(
    'kind', 'deal', 'menu_item_id', p_menu_item_id, 'qty', p_qty,
    'discount', p_discount, 'name', p_name,
    'promotion_id', p_promotion_id, 'check_position', p_check_position,
    'employee_id', p_created_by_employee_id
  );

  insert into public.order_item_client_ops (client_op_id, order_id, request_payload)
  values (p_client_op_id, p_order_id, v_request)
  on conflict (client_op_id) do nothing;
  get diagnostics v_rows = row_count;

  if v_rows = 0 then
    select * into v_existing
    from public.order_item_client_ops
    where client_op_id = p_client_op_id;

    if v_existing.order_id is distinct from p_order_id
       or v_existing.request_payload is distinct from v_request then
      raise exception 'CLIENT_OP_ID_CONFLICT'
        using errcode = 'MP410',
              detail = format('op %s pertenece a otra orden', p_client_op_id);
    end if;

    return jsonb_build_object(
      'item_id', v_existing.item_id,
      'replayed', true,
      'item_exists', exists (
        select 1 from public.order_items where id = v_existing.item_id
      )
    );
  end if;

  v_item_id := public.fn_add_offer_deal(
    p_order_id,
    p_menu_item_id,
    p_qty,
    p_discount,
    p_name,
    p_promotion_id,
    p_check_position
  );

  if p_created_by_employee_id is not null then
    update public.order_items
       set created_by_employee_id = p_created_by_employee_id
     where id = v_item_id;
  end if;

  update public.order_item_client_ops
     set item_id = v_item_id
   where client_op_id = p_client_op_id;

  return jsonb_build_object(
    'item_id', v_item_id,
    'replayed', false,
    'item_exists', true
  );
end;
$$;

revoke all on function public.fn_add_offer_deal_idempotent(
  uuid, uuid, uuid, numeric, numeric, text, uuid, integer, uuid
) from public, anon;
grant execute on function public.fn_add_offer_deal_idempotent(
  uuid, uuid, uuid, numeric, numeric, text, uuid, integer, uuid
) to authenticated, service_role;

-- -----------------------------------------------------------------------------
-- Reemplazo ATÓMICO de modificadores. Antes eran dos viajes (DELETE y luego
-- INSERT): si caía la red entre ambos, el ítem quedaba SIN sus extras (se
-- cobraba de menos y no coincidía con la comanda). Ahora es una transacción.
--
-- SECURITY INVOKER a propósito: respeta la RLS de order_item_modifiers igual
-- que las escrituras directas que reemplaza. Candado por ítem: dos reemplazos
-- simultáneos se serializan (sin él, ambos podían insertar y dejar los extras
-- duplicados). Las columnas opcionales (menu_item_id 20260605_0002,
-- modifier_id 20260907_0002) se usan solo si existen en esta base.
-- -----------------------------------------------------------------------------
create or replace function public.fn_replace_order_item_modifiers(
  p_item_id uuid,
  p_modifiers jsonb default '[]'::jsonb
) returns integer
language plpgsql
security invoker
set search_path to 'public'
as $$
declare
  v_modifiers jsonb := coalesce(p_modifiers, '[]'::jsonb);
  v_cols text := 'item_id, name, qty, price';
  v_vals text := '$1, m->>''name'', coalesce((m->>''qty'')::numeric, 1), '
                 'coalesce((m->>''price'')::numeric, 0)';
  v_count integer;
begin
  if p_item_id is null then
    raise exception 'ITEM_ID_REQUIRED' using errcode = '22004';
  end if;
  if jsonb_typeof(v_modifiers) <> 'array' then
    raise exception 'MODIFIERS_MUST_BE_ARRAY' using errcode = '22023';
  end if;

  perform pg_advisory_xact_lock(
    hashtextextended('order_item_modifiers:' || p_item_id::text, 0)
  );

  if not exists (select 1 from public.order_items where id = p_item_id) then
    raise exception 'ITEM_NOT_FOUND' using errcode = 'P0002';
  end if;

  delete from public.order_item_modifiers where item_id = p_item_id;

  if exists (
    select 1 from pg_attribute
    where attrelid = 'public.order_item_modifiers'::regclass
      and attname = 'menu_item_id' and not attisdropped
  ) then
    v_cols := v_cols || ', menu_item_id';
    v_vals := v_vals || ', nullif(m->>''menu_item_id'', '''')::uuid';
  end if;
  if exists (
    select 1 from pg_attribute
    where attrelid = 'public.order_item_modifiers'::regclass
      and attname = 'modifier_id' and not attisdropped
  ) then
    v_cols := v_cols || ', modifier_id';
    v_vals := v_vals || ', nullif(m->>''modifier_id'', '''')::uuid';
  end if;

  execute format(
    'insert into public.order_item_modifiers (%s) '
    'select %s from jsonb_array_elements($2) as m',
    v_cols, v_vals
  ) using p_item_id, v_modifiers;
  get diagnostics v_count = row_count;
  return v_count;
end;
$$;

revoke all on function public.fn_replace_order_item_modifiers(uuid, jsonb)
  from public, anon;
grant execute on function public.fn_replace_order_item_modifiers(uuid, jsonb)
  to authenticated, service_role;

commit;

notify pgrst, 'reload schema';
