-- =============================================================================
-- 20260602_0004 — fn_open_retail_cart: ventas rápidas SIMULTÁNEAS en retail
-- =============================================================================
--
-- PROBLEMA QUE RESUELVE
-- ─────────────────────
-- `fn_open_manual_or_quick` comparte UNA sola mesa virtual por negocio+origen
-- (`fn_get_or_create_virtual_table(business, 'quick')`, code='quick'). Al abrir
-- una nueva venta rápida CIERRA/anula (void) cualquier sesión quick abierta
-- previa en esa mesa. Esto fuerza "una sola venta rápida abierta por negocio":
-- abrir un segundo carrito mata el primero, y reabrir venta rápida tras salir
-- anula la venta en curso.
--
-- En modo RETAIL el cajero necesita varios carritos de venta rápida abiertos a
-- la vez (un cliente cada uno). Para eso cada carrito necesita su propia mesa
-- virtual / sesión / orden, independientes entre sí.
--
-- FIX
-- ───
-- Nuevo RPC `fn_open_retail_cart(business, user, slot, people_count)`:
--   - Mesa virtual DEDICADA por carrito: `dining_tables.code = p_slot` dentro de
--     la zona "Ventas rapidas". Idempotente por slot (reabrir el mismo slot
--     devuelve su orden abierta → recargar/recuperar el mismo carrito).
--   - NO toca otras mesas/sesiones quick → los carritos coexisten.
--   - Valida pertenencia al negocio (anti tenant-injection), igual que
--     fn_open_manual_or_quick.
--
-- `fn_open_manual_or_quick` queda INTACTA (restaurante y venta rápida legacy la
-- siguen usando). Este RPC es exclusivo del flujo de carritos retail.
--
-- NOTA OPERATIVA
-- ──────────────
-- Cada carrito crea una fila en `dining_tables` (code = slot uuid) dentro de la
-- zona virtual "Ventas rapidas" (no visible en el salón). Se acumulan con el
-- tiempo. Un cron de limpieza (mesas virtuales quick con sesión cerrada y sin
-- órdenes abiertas) puede recogerlas más adelante; no es bloqueante.
-- =============================================================================

begin;

create or replace function public.fn_open_retail_cart(
  p_business_id uuid,
  p_user_id uuid,
  p_slot text,
  p_people_count integer default 1
) returns jsonb
  language plpgsql
  security definer
  set search_path = public
as $$
declare
  v_user_id uuid := coalesce(p_user_id, auth.uid());
  v_business_id uuid := p_business_id;
  v_belongs boolean;
  v_zone_id uuid;
  v_table_id uuid;
  v_table_code text;
  v_session_id uuid;
  v_order_id uuid;
begin
  if v_user_id is null then
    raise exception 'fn_open_retail_cart: user id is required';
  end if;
  if v_business_id is null then
    raise exception 'fn_open_retail_cart: business id is required';
  end if;
  if p_slot is null or btrim(p_slot) = '' then
    raise exception 'fn_open_retail_cart: slot is required';
  end if;

  -- Anti tenant-injection: el usuario debe pertenecer al negocio.
  select exists(
    select 1
    from public.user_businesses
    where user_id = v_user_id
      and business_id = v_business_id
  ) into v_belongs;
  if not v_belongs then
    raise exception 'fn_open_retail_cart: user % does not belong to business %',
      v_user_id, v_business_id;
  end if;

  -- Zona virtual de ventas rápidas (misma que usa fn_get_or_create_virtual_table).
  select id into v_zone_id
  from public.zones
  where business_id = v_business_id
    and name = 'Ventas rapidas'
  limit 1;
  if v_zone_id is null then
    begin
      insert into public.zones (business_id, name, sort_index, is_active)
      values (v_business_id, 'Ventas rapidas', 901, true)
      returning id into v_zone_id;
    exception when unique_violation then
      select id into v_zone_id
      from public.zones
      where business_id = v_business_id
        and name = 'Ventas rapidas'
      limit 1;
    end;
  end if;

  -- Mesa virtual DEDICADA por carrito: code = slot. El slot del cliente es
  -- 'quick-<uuid>' (≠ 'quick' de la mesa compartida legacy). Idempotente.
  v_table_code := left(btrim(p_slot), 60);
  select id into v_table_id
  from public.dining_tables
  where zone_id = v_zone_id
    and code = v_table_code
  limit 1;
  if v_table_id is null then
    begin
      insert into public.dining_tables (
        zone_id, code, label, shape, state, capacity,
        pos_x, pos_y, width, height, rotation, is_active
      ) values (
        v_zone_id, v_table_code, 'Venta rapida', 'square', 'available', 2,
        0, 0, 1, 1, 0, true
      ) returning id into v_table_id;
    exception when unique_violation then
      select id into v_table_id
      from public.dining_tables
      where zone_id = v_zone_id
        and code = v_table_code
      limit 1;
    end;
  end if;

  -- Reusar la sesión/orden ABIERTA de ESTA mesa (mismo carrito) si existe; si
  -- no, crear nuevas. NO se tocan otras mesas/sesiones → carritos simultáneos.
  select id into v_session_id
  from public.table_sessions
  where table_id = v_table_id
    and closed_at is null
  limit 1;

  if v_session_id is not null then
    select id into v_order_id
    from public.orders
    where session_id = v_session_id
      and status_ext = 'open'
    order by created_at desc
    limit 1;
  end if;

  if v_session_id is null then
    insert into public.table_sessions
      (table_id, opened_by, origin, waiter_user_id, people_count)
    values
      (v_table_id, v_user_id, 'quick', v_user_id, greatest(1, p_people_count))
    returning id into v_session_id;
  end if;

  if v_order_id is null then
    insert into public.orders
      (session_id, status_ext, subtotal, discounts, tax, total, total_amount)
    values
      (v_session_id, 'open', 0, 0, 0, 0, 0)
    returning id into v_order_id;

    insert into public.order_checks (order_id, label, position)
    values (v_order_id, 'C1', 1);
  end if;

  return jsonb_build_object(
    'session_id', v_session_id,
    'order_id', v_order_id,
    'business_id', v_business_id
  );
end;
$$;

grant execute on function
  public.fn_open_retail_cart(uuid, uuid, text, integer) to authenticated;

commit;
