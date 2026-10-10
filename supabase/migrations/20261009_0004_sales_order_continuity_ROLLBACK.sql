-- =============================================================================
-- ROLLBACK manual de 20261009_0004_sales_order_continuity.sql
-- =============================================================================
--
-- BASE REPO, NO BASE VIVA: restaura los cuerpos ANTERIORES DEL REPO. La BD viva
-- puede diferir del repo (ver memoria "BD viva diverge del repo"); el rollback
-- REAL es la salida del bloque 1 de
-- scripts/diagnostics/encuentro_food_shop_order_continuity.sql (definición +
-- ACL de cada función) tomada ANTES de aplicar la migración. Si existe esa
-- salida, usar esas definiciones en lugar de las de abajo.
--
-- QUÉ RESTAURA (copiado tal cual del repo):
--   · fn_open_manual_or_quick(order_origin, uuid, integer, uuid)
--       ← 20260526_0003. OJO: vuelve a ANULAR (void) las ventas 'open' de la
--       mesa compartida 'quick'/'manual' y a cerrar su sesión al abrir otra
--       venta, aunque haya otras órdenes vivas (quedan huérfanas).
--   · fn_open_retail_cart(uuid, uuid, text, integer) ← 20260602_0004 (retoma solo
--       órdenes 'open', sin locks).
--   · fn_open_delivery_order(uuid, text, integer) ← 20260408_0002 (plpgsql, sin
--       lock ':delivery', LPAD de 3: DEL-1000 vuelve a truncarse a DEL-100).
--
-- QUÉ CONSERVA (no tienen cuerpo anterior en el repo y la app nueva los usa):
--   · fn_open_offline_sale, fn_open_delivery_order de 4 argumentos y los helpers
--     internos fn_sales_*. Si se borraran, las ventas offline y los delivery de
--     la app nueva fallarían con PGRST202; tras 8 intentos fallidos sin ser de
--     conectividad la cola los pasa a "dead" (no los borra, pero hay que
--     reencolarlos a mano). Para quitarlos de verdad hay que volver la app a una
--     versión que no los llame y luego correr el bloque comentado del final.
--
-- PERMISOS: CREATE OR REPLACE conserva el ACL que dejó la migración (sin anon ni
-- PUBLIC; authenticated y service_role con EXECUTE). No se le devuelve EXECUTE a
-- anon ni a authenticated sobre fn_get_or_create_virtual_table (ningún cliente la
-- llama; el cuerpo restaurado la usa como postgres). Re-otorgar a mano solo si
-- el volcado previo lo mostraba y se quiere conservar.
--
-- DATOS: no toca filas. Los carriles 'quick#n'/'manual#n', sus sesiones y
-- órdenes quedan como datos válidos (se cobran o anulan por el flujo normal).
-- No recrea el overload legacy de 3 argumentos de fn_open_manual_or_quick.
-- =============================================================================

begin;

-- ─── fn_open_manual_or_quick ← 20260526_0003 ────────────────────────────────
create or replace function public.fn_open_manual_or_quick(
  p_origin public.order_origin,
  p_user_id uuid,
  p_people_count integer default 1,
  p_business_id uuid default null
) returns jsonb
  language plpgsql
  security definer
  set search_path = public
as $$
declare
  v_user_id uuid := coalesce(p_user_id, auth.uid());
  v_business_id uuid;
  v_belongs boolean;
  v_table_id uuid;
  v_session_id uuid;
  v_order_id uuid;
  v_existing_session uuid;
  v_open_order_id uuid;
begin
  if v_user_id is null then
    raise exception 'fn_open_manual_or_quick: user id is required';
  end if;

  if p_business_id is not null then
    -- Validar pertenencia. Sin esto un Owner podría abrir órdenes en
    -- cualquier tenant pasando un business_id arbitrario.
    select exists(
      select 1
      from public.user_businesses
      where user_id = v_user_id
        and business_id = p_business_id
    ) into v_belongs;

    if not v_belongs then
      raise exception 'fn_open_manual_or_quick: user % does not belong to business %',
        v_user_id, p_business_id;
    end if;

    v_business_id := p_business_id;
  else
    -- Fallback legacy: usado por clientes que no fueron actualizados
    -- todavía. Elige el negocio más antiguo del usuario. Para usuarios
    -- single-tenant es correcto; para Owners multi-tenant es exactamente
    -- el comportamiento defectuoso que estamos arreglando — por eso el
    -- cliente debe pasar siempre p_business_id.
    select business_id
      into v_business_id
    from public.user_businesses
    where user_id = v_user_id
    order by created_at
    limit 1;

    if v_business_id is null then
      select bid
        into v_business_id
      from public.current_user_business_ids() as bid
      limit 1;
    end if;
  end if;

  if v_business_id is null then
    raise exception 'fn_open_manual_or_quick: no business found for user %', v_user_id;
  end if;

  v_table_id := public.fn_get_or_create_virtual_table(v_business_id, p_origin);

  -- Cierra cualquier sesion abierta previa en esta mesa virtual.
  select id
    into v_existing_session
  from public.table_sessions
  where table_id = v_table_id
    and closed_at is null
  limit 1;

  if v_existing_session is not null then
    for v_open_order_id in
      select id
      from public.orders
      where session_id = v_existing_session
        and status_ext = 'open'
    loop
      perform public.fn_close_order_and_table(v_open_order_id, 'void');
    end loop;

    update public.table_sessions
    set closed_at = now()
    where id = v_existing_session;
  end if;

  insert into public.table_sessions (table_id, opened_by, origin, waiter_user_id, people_count)
  values (v_table_id, v_user_id, p_origin, v_user_id, greatest(1, p_people_count))
  returning id into v_session_id;

  insert into public.orders (session_id, status_ext, subtotal, discounts, tax, total, total_amount)
  values (v_session_id, 'open', 0, 0, 0, 0, 0)
  returning id into v_order_id;

  insert into public.order_checks (order_id, label, position)
  values (v_order_id, 'C1', 1);

  return jsonb_build_object(
    'session_id', v_session_id,
    'order_id', v_order_id,
    'business_id', v_business_id
  );
end;
$$;

alter function public.fn_open_manual_or_quick(
  public.order_origin, uuid, integer, uuid
) owner to postgres;

grant execute on function public.fn_open_manual_or_quick(
  public.order_origin, uuid, integer, uuid
) to authenticated;
grant execute on function public.fn_open_manual_or_quick(
  public.order_origin, uuid, integer, uuid
) to service_role;

-- ─── fn_open_retail_cart ← 20260602_0004 ───────────────────────────────────
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

-- ─── fn_open_delivery_order (3 argumentos) ← 20260408_0002 ─────────────────
CREATE OR REPLACE FUNCTION public.fn_open_delivery_order(
  p_user_id uuid,
  p_delivery_type text DEFAULT 'own',
  p_people_count int DEFAULT 1
) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public
AS $$
DECLARE
  v_user_id uuid := coalesce(p_user_id, auth.uid());
  v_business_id uuid;
  v_zone_id uuid;
  v_table_id uuid;
  v_session_id uuid;
  v_order_id uuid;
  v_seq int;
  v_table_code text;
BEGIN
  -- Resolver business
  SELECT business_id INTO v_business_id
    FROM public.user_businesses WHERE user_id = v_user_id
    ORDER BY created_at LIMIT 1;
  IF v_business_id IS NULL THEN
    SELECT bid INTO v_business_id FROM public.current_user_business_ids() AS bid LIMIT 1;
  END IF;
  IF v_business_id IS NULL THEN
    RAISE EXCEPTION 'fn_open_delivery_order: no business found';
  END IF;

  -- Asegurar zona "Delivery" (sort_index=902)
  SELECT id INTO v_zone_id FROM public.zones
    WHERE business_id = v_business_id AND name = 'Delivery' LIMIT 1;
  IF v_zone_id IS NULL THEN
    INSERT INTO public.zones (business_id, name, sort_index, is_active)
      VALUES (v_business_id, 'Delivery', 902, true)
      RETURNING id INTO v_zone_id;
  END IF;

  -- Código secuencial: DEL-001, DEL-002...
  SELECT COALESCE(MAX(
    CASE WHEN code ~ '^DEL-[0-9]+$'
      THEN CAST(REPLACE(code, 'DEL-', '') AS int)
      ELSE 0
    END
  ), 0) + 1 INTO v_seq
    FROM public.dining_tables WHERE zone_id = v_zone_id;
  v_table_code := 'DEL-' || LPAD(v_seq::text, 3, '0');

  -- Crear mesa temporal
  INSERT INTO public.dining_tables (
    zone_id, code, label, shape, state, capacity,
    pos_x, pos_y, width, height, rotation, is_active
  ) VALUES (
    v_zone_id, v_table_code,
    CASE p_delivery_type
      WHEN 'uber_eats' THEN 'Uber Eats'
      WHEN 'pedidos_ya' THEN 'Pedidos Ya'
      ELSE 'Delivery Propio'
    END,
    'square', 'occupied', 1, 0, 0, 1, 1, 0, true
  ) RETURNING id INTO v_table_id;

  -- Crear sesión con delivery_type
  INSERT INTO public.table_sessions (
    table_id, opened_by, origin, waiter_user_id, people_count, delivery_type, business_id
  ) VALUES (
    v_table_id, v_user_id, 'delivery', v_user_id,
    greatest(1, p_people_count), p_delivery_type, v_business_id
  ) RETURNING id INTO v_session_id;

  -- Crear orden + check por defecto
  INSERT INTO public.orders (session_id, status_ext, subtotal, discounts, tax, total, total_amount)
    VALUES (v_session_id, 'open', 0, 0, 0, 0, 0)
    RETURNING id INTO v_order_id;
  INSERT INTO public.order_checks (order_id, label, position)
    VALUES (v_order_id, 'C1', 1);

  RETURN jsonb_build_object(
    'session_id', v_session_id,
    'order_id', v_order_id,
    'table_id', v_table_id,
    'table_code', v_table_code,
    'delivery_type', p_delivery_type
  );
END;
$$;

GRANT EXECUTE ON FUNCTION public.fn_open_delivery_order(uuid, text, int) TO authenticated;

-- Opcional, SOLO junto con volver la app a una versión que no los llame:
-- drop function if exists public.fn_open_offline_sale(uuid, uuid, text, public.order_origin, integer);
-- drop function if exists public.fn_open_delivery_order(uuid, text, integer, uuid);
-- drop function if exists public.fn_sales_virtual_open(text, uuid, uuid, public.order_origin, integer, text);
-- drop function if exists public.fn_sales_default_business(uuid);
-- drop function if exists public.fn_sales_user_can_open(uuid, uuid);
-- drop function if exists public.fn_sales_open_actor(uuid, text);

notify pgrst, 'reload schema';
commit;
