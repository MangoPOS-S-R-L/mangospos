-- =============================================================================
-- 20261009_0004 — Venta rápida/manual: cada apertura es una venta NUEVA en su
-- propio carril. Nunca se entrega ni se anula la cuenta de otra caja.
-- =============================================================================
--
-- PROBLEMA
-- ────────
-- 1. `fn_open_manual_or_quick` usaba UNA mesa virtual por negocio y origen
--    (code 'quick'/'manual'). La versión del repo (20260526_0003) ANULABA la
--    venta abierta de esa mesa al abrir otra; el borrador anterior de esta
--    migración, en cambio, devolvía la venta viva más reciente a cualquier caja:
--    dos cajas compartían orden y el replay offline de una app vieja metía sus
--    productos y su cobro en la cuenta de otra caja.
-- 2. Una sesión abierta sin orden viva (todo cobrado/anulado) hacía chocar el
--    INSERT con `uniq_open_session_per_table` (23505) para todo el negocio.
-- 3. Dueños y usuarios compartidos entre sucursales (acceso vía
--    `current_user_business_ids()`, sin fila directa en user_businesses) no
--    podían abrir venta rápida/manual ni delivery.
--
-- DISEÑO
-- ──────
-- · `fn_open_manual_or_quick` (app nueva y vieja) es SOLO-NUEVA: bajo el lock de
--   negocio ':sales_virtual' + lock de mesa toma el PRIMER carril libre del
--   negocio: 'quick', 'quick#2', 'quick#3'… ('manual', 'manual#2'…), etiquetas
--   'Venta rapida', 'Venta rapida 2'… / 'Venta manual', 'Venta manual 2'…
--   Un carril está libre si no tiene sesión abierta con orden viva (closed_at
--   null y status_ext no en paid/void). Si tiene sesión abierta con CERO órdenes
--   vivas, esa sesión se cierra (no hay dinero) y se abre una nueva: nunca 23505.
--   "Por equipo" lo resuelve el CLIENTE retomando por id explícito desde su
--   snapshot local; el servidor no retoma por identidad (el id de equipo se
--   clona en backups y se comparte entre pestañas web).
-- · `fn_open_retail_cart` (slot 'quick-<uuid>') y `fn_open_offline_sale` (slot
--   'quick-<local>'/'manual-<local>') conservan "retomar por slot exacto"
--   (replays idempotentes) sobre el mismo helper interno.
-- · Zona determinista (homónimas: la de sort_index canónico, activa, más
--   antigua), sort_index canónico (quick 901, manual 900), mesas buscadas por
--   código en todas las zonas homónimas.
-- · Membresía: fila directa del actor, o actor = auth.uid() y negocio en
--   current_user_business_ids(). Anti-suplantación: con JWT, p_user_id debe ser
--   auth.uid(). anon y PUBLIC sin EXECUTE; helpers internos sin EXECUTE para
--   clientes.
-- · Locks: negocio (':sales_virtual' / ':delivery') y luego mesa con
--   hashtextextended(table_id::text, 0), la MISMA llave de fn_open_table,
--   fn_release_empty_table(s) y el trigger de 20260819_0004.
--
-- NO TOCA DATOS: no anula, no cierra ni edita órdenes, ítems, checks ni pagos.
-- La única escritura sobre filas existentes es cerrar, al abrir, una sesión
-- abierta SIN órdenes vivas de la mesa elegida. Las órdenes vivas que ya estén
-- en las mesas compartidas 'quick'/'manual' quedan intactas (el carril sigue
-- ocupado y la siguiente venta toma 'quick#2'); las lista el diagnóstico
-- scripts/diagnostics/encuentro_food_shop_order_continuity.sql (bloques 6-7).
--
-- DESPLIEGUE — APLICAR ANTES DE PUBLICAR LA APP. La app nueva llama a
-- fn_open_offline_sale y a fn_open_delivery_order de 4 argumentos, que solo
-- existen tras esta migración (sin ella: PGRST202). La app anterior sigue
-- funcionando con esta migración aplicada.
--
-- PROVISIONAL — VALIDAR CONTRA LA BD VIVA ANTES DE APLICAR (bloques 1, 8-10 del
-- diagnóstico): cuerpos/ACL vivos de las funciones de apertura, que no exista
-- otro overload, uniq_open_session_per_table, dining_tables_zone_id_code_key,
-- trigger de business_id en table_sessions/orders.
-- OJO: esta migración NO detecta que un cuerpo vivo difiera del repo. CREATE OR
-- REPLACE solo falla si cambia la firma, el nombre de un parámetro, un default
-- o el tipo de retorno; un cuerpo o un ACL distinto se reemplaza SIN error, y
-- un índice o trigger faltante tampoco la detiene. La transacción entera solo
-- se revierte si:
--   · la verificación previa (sección 0) encuentra en algún overload vivo de
--     fn_open_manual_or_quick, fn_open_retail_cart o fn_open_delivery_order
--     las guardas fn_require_open_cash_session u ORIGIN_NOT_ALLOWED, que los
--     cuerpos del repo no tienen y que se borrarían en silencio;
--   · la guarda final (sección 7) encuentra overloads inesperados o defaults en
--     el delivery de 4 argumentos.
-- Cualquier otra diferencia se revisa A MANO: guardar la salida del bloque 1
-- (definición completa) y compararla con los cuerpos del repo antes de aplicar.
-- No se comparan huellas md5 automáticamente: dependen de cómo se aplicó cada
-- cuerpo y las vivas todavía no se conocen.
-- Rollback: 20261009_0004_sales_order_continuity_ROLLBACK.sql (base repo).
-- =============================================================================

begin;

-- ─── 0. Verificación previa: lógica viva que esta migración borraría ────────
-- CREATE OR REPLACE y DROP reemplazan un cuerpo distinto SIN error. Ningún
-- cuerpo del repo de estas funciones exige caja abierta ni lanza
-- ORIGIN_NOT_ALLOWED; si un overload VIVO lo hace (p. ej. el de 3 argumentos de
-- database/supabase_backup.sql), se aborta ANTES de tocar nada para que quitar
-- esa guarda sea una decisión explícita. Va antes del drop del overload legacy
-- para revisarlo también. Búsqueda de texto sin distinguir mayúsculas; no se
-- comparan huellas md5.
do $$
declare
  v_hits text;
begin
  select string_agg(format('%s [%s]', x.firma, array_to_string(x.marcas, ', ')),
                    '; ' order by x.firma)
    into v_hits
  from (
    select p.oid::regprocedure::text as firma,
           array_remove(array[
             case when strpos(lower(pg_get_functiondef(p.oid)), 'fn_require_open_cash_session') > 0
                  then 'fn_require_open_cash_session' end,
             case when strpos(lower(pg_get_functiondef(p.oid)), 'origin_not_allowed') > 0
                  then 'ORIGIN_NOT_ALLOWED' end
           ], null) as marcas
    from pg_proc p
    where p.pronamespace = 'public'::regnamespace
      and p.prokind = 'f'
      and p.proname in ('fn_open_manual_or_quick', 'fn_open_retail_cart',
                        'fn_open_delivery_order')
  ) x
  where cardinality(x.marcas) > 0;

  if v_hits is not null then
    raise exception '20261009_0004 abortada, no se cambió nada: la BD viva tiene guardas que esta migración borraría sin aviso: %',
      v_hits
      using detail = 'CREATE OR REPLACE y DROP reemplazan el cuerpo vivo sin error aunque difiera '
                     'del repo, y los cuerpos del repo no llaman a fn_require_open_cash_session ni '
                     'lanzan ORIGIN_NOT_ALLOWED.',
            hint = 'Guarda la definición viva (bloque 1 de '
                   'scripts/diagnostics/encuentro_food_shop_order_continuity.sql) y decide de forma '
                   'explícita: conservar la guarda (agregarla al cuerpo nuevo y ajustar esta '
                   'verificación) o eliminarla (quitarla a mano de la BD viva y dejar constancia). '
                   'Después vuelve a aplicar la migración.';
  end if;
end $$;

-- ─── 0b. Overload legacy de 3 argumentos ────────────────────────────────────
-- 20260526_0003 lo eliminó, pero si sobrevivió en la BD viva PostgREST no puede
-- elegir entre él y el de 4 (PGRST203) y su cuerpo ANULA ventas abiertas.
drop function if exists public.fn_open_manual_or_quick(public.order_origin, uuid, integer);

-- ─── 1. Helpers internos (no ejecutables por clientes) ──────────────────────

-- Actor de la apertura. Con JWT es SIEMPRE auth.uid(): p_user_id null se toma
-- como auth.uid() y uno distinto se rechaza. Sin JWT solo llega service_role
-- (anon no tiene EXECUTE, ver permisos al final) y debe indicar el usuario.
create or replace function public.fn_sales_open_actor(
  p_user_id uuid,
  p_caller text
) returns uuid
  language plpgsql
  stable
  security definer
  set search_path = public
as $$
declare
  v_auth uuid := auth.uid();
begin
  if v_auth is null then
    if p_user_id is null then
      raise exception '%: user id is required', p_caller;
    end if;
    return p_user_id;
  end if;
  if p_user_id is not null and p_user_id <> v_auth then
    raise exception '%: user id must match authenticated user', p_caller;
  end if;
  return v_auth;
end;
$$;

-- Pertenencia: fila directa del actor, o acceso del usuario autenticado (dueño
-- por owner_id / usuario compartido entre sucursales). current_user_business_ids()
-- devuelve SETOF uuid: se usa con IN (select ...), nunca x.business_id.
-- El coalesce externo es obligatorio: `exists(...) or null` daría NULL.
create or replace function public.fn_sales_user_can_open(
  p_user_id uuid,
  p_business_id uuid
) returns boolean
  language sql
  stable
  security definer
  set search_path = public
as $$
  select coalesce(
    p_user_id is not null and p_business_id is not null and (
      exists (
        select 1 from public.user_businesses ub
        where ub.user_id = p_user_id and ub.business_id = p_business_id
      )
      or (
        p_user_id = auth.uid()
        and p_business_id in (select public.current_user_business_ids())
      )
    ),
    false
  );
$$;

-- Negocio por defecto para clientes que no envían sucursal. Determinista:
-- 1) la fila directa más antigua (como antes; desempate por negocio más antiguo
-- e id), 2) si no hay, el negocio accesible más antiguo (businesses.created_at,
-- luego id) — solo para el usuario autenticado.
create or replace function public.fn_sales_default_business(
  p_user_id uuid
) returns uuid
  language sql
  stable
  security definer
  set search_path = public
as $$
  select coalesce(
    (select ub.business_id
       from public.user_businesses ub
       left join public.businesses b on b.id = ub.business_id
      where ub.user_id = p_user_id
      order by ub.created_at, b.created_at nulls last, ub.business_id
      limit 1),
    (select bid
       from public.current_user_business_ids() as bid
       left join public.businesses b on b.id = bid
      where p_user_id = auth.uid()
      order by b.created_at nulls last, bid
      limit 1)
  );
$$;

-- Núcleo de apertura en mesas virtuales de venta.
--   p_slot null  → carril del negocio: SIEMPRE venta nueva en el primer carril
--                  libre ('quick', 'quick#2'…). Nunca retoma.
--   p_slot texto → slot exacto (carrito retail / venta offline): retoma su venta
--                  viva si existe; si no, abre una nueva en la mesa del slot.
-- Nunca anula ni modifica órdenes. Solo cierra una sesión abierta SIN órdenes
-- vivas de la mesa elegida, dentro del lock de esa mesa.
create or replace function public.fn_sales_virtual_open(
  p_caller text,
  p_business_id uuid,
  p_user_id uuid,
  p_origin public.order_origin,
  p_people_count integer,
  p_slot text
) returns jsonb
  language plpgsql
  security definer
  set search_path = public
as $$
declare
  c_max_lanes constant integer := 50;
  v_caller text := coalesce(nullif(btrim(p_caller), ''), 'fn_sales_virtual_open');
  v_zone_name text;
  v_zone_sort integer;
  v_label_base text;
  v_zone_id uuid;
  v_lane integer := 0;
  v_code text;
  v_label text;
  v_table_id uuid;
  v_session_id uuid;
  v_order_id uuid;
  r record;
begin
  if p_business_id is null or p_user_id is null or p_origin is null
     or p_origin::text not in ('quick', 'manual') then
    raise exception '%: invalid arguments', v_caller;
  end if;
  v_zone_name := case when p_origin = 'quick' then 'Ventas rapidas' else 'Ventas manuales' end;
  v_zone_sort := case when p_origin = 'quick' then 901 else 900 end;
  v_label_base := case when p_origin = 'quick' then 'Venta rapida' else 'Venta manual' end;

  -- Serializa zona, mesas y elección de carril del negocio (misma llave para
  -- legacy, retail y offline: así no se crean dos zonas ni dos carriles iguales).
  perform pg_advisory_xact_lock(hashtextextended(p_business_id::text || ':sales_virtual', 0));

  -- Puede haber zonas homónimas (no hay UNIQUE): la canónica es la del
  -- sort_index de venta virtual, activa y más antigua.
  select z.id into v_zone_id
  from public.zones z
  where z.business_id = p_business_id
    and z.name = v_zone_name
  order by (z.sort_index = v_zone_sort) desc, z.is_active desc,
    z.created_at nulls last, z.id
  limit 1;
  if v_zone_id is null then
    begin
      insert into public.zones (business_id, name, sort_index, is_active)
      values (p_business_id, v_zone_name, v_zone_sort, true)
      returning id into v_zone_id;
    exception when unique_violation then
      select z.id into v_zone_id
      from public.zones z
      where z.business_id = p_business_id
        and z.name = v_zone_name
      order by (z.sort_index = v_zone_sort) desc, z.is_active desc,
        z.created_at nulls last, z.id
      limit 1;
    end;
  end if;

  -- Slot exacto: retomar SU venta viva (en cualquier zona homónima).
  if p_slot is not null then
    for r in
      select o.id as order_id, ts.id as session_id, dt.id as table_id, dt.code as table_code
      from public.dining_tables dt
      join public.zones z on z.id = dt.zone_id
      join public.table_sessions ts on ts.table_id = dt.id and ts.closed_at is null
      join public.orders o on o.session_id = ts.id
      where z.business_id = p_business_id
        and z.name = v_zone_name
        and dt.code = p_slot
        and o.closed_at is null
        and o.status_ext::text not in ('paid', 'void')
      order by o.created_at desc, o.id desc
    loop
      perform pg_advisory_xact_lock(hashtextextended(r.table_id::text, 0));
      -- Re-chequeo dentro del lock: un cobro o el barrido pudo cerrarla.
      if exists (
        select 1
        from public.orders o
        join public.table_sessions ts on ts.id = o.session_id
        where o.id = r.order_id and ts.id = r.session_id
          and ts.closed_at is null and o.closed_at is null
          and o.status_ext::text not in ('paid', 'void')
      ) then
        return jsonb_build_object(
          'session_id', r.session_id,
          'order_id', r.order_id,
          'business_id', p_business_id,
          'table_id', r.table_id,
          'table_code', r.table_code,
          'resumed', true
        );
      end if;
    end loop;
  end if;

  loop
    v_lane := v_lane + 1;
    if p_slot is not null then
      v_code := p_slot;
      v_label := v_label_base;
    else
      if v_lane > c_max_lanes then
        raise exception '%: no hay carril libre; hay % ventas sin cobrar en "%". Cobra o anula alguna para abrir otra.',
          v_caller, c_max_lanes, v_zone_name;
      end if;
      v_code := case when v_lane = 1 then p_origin::text else p_origin::text || '#' || v_lane end;
      v_label := case when v_lane = 1 then v_label_base else v_label_base || ' ' || v_lane end;
      -- Carril ocupado si alguna mesa con ese código (en zonas homónimas) tiene
      -- una orden viva: la venta de otra caja nunca se toca.
      if exists (
        select 1
        from public.dining_tables dt
        join public.zones z on z.id = dt.zone_id
        join public.table_sessions ts on ts.table_id = dt.id and ts.closed_at is null
        join public.orders o on o.session_id = ts.id
        where z.business_id = p_business_id
          and z.name = v_zone_name
          and dt.code = v_code
          and o.closed_at is null
          and o.status_ext::text not in ('paid', 'void')
      ) then
        continue;
      end if;
    end if;

    -- Mesa determinista: la de la zona canónica primero, luego la más antigua.
    v_table_id := null;
    select dt.id into v_table_id
    from public.dining_tables dt
    join public.zones z on z.id = dt.zone_id
    where z.business_id = p_business_id
      and z.name = v_zone_name
      and dt.code = v_code
    order by (dt.zone_id = v_zone_id) desc, dt.created_at nulls last, dt.id
    limit 1;
    if v_table_id is null then
      begin
        insert into public.dining_tables (
          zone_id, code, label, shape, state, capacity,
          pos_x, pos_y, width, height, rotation, is_active
        ) values (
          v_zone_id, v_code, v_label, 'square', 'available', 2,
          0, 0, 1, 1, 0, true
        ) returning id into v_table_id;
      exception when unique_violation then
        select dt.id into v_table_id
        from public.dining_tables dt
        where dt.zone_id = v_zone_id
          and dt.code = v_code;
      end;
    end if;

    perform pg_advisory_xact_lock(hashtextextended(v_table_id::text, 0));

    -- Re-chequeo dentro del lock de la mesa (p. ej. el trigger de 20260819_0004
    -- reanimó una orden de esta mesa sin pasar por el lock de negocio).
    select o.id, ts.id into v_order_id, v_session_id
    from public.table_sessions ts
    join public.orders o on o.session_id = ts.id
    where ts.table_id = v_table_id
      and ts.closed_at is null
      and o.closed_at is null
      and o.status_ext::text not in ('paid', 'void')
    order by o.created_at desc, o.id desc
    limit 1;
    if v_order_id is not null then
      if p_slot is not null then
        return jsonb_build_object(
          'session_id', v_session_id,
          'order_id', v_order_id,
          'business_id', p_business_id,
          'table_id', v_table_id,
          'table_code', v_code,
          'resumed', true
        );
      end if;
      continue;
    end if;

    -- Sesión abierta sin órdenes vivas: se cierra (no hay dinero; no se anula
    -- nada) para no chocar con uniq_open_session_per_table. Cada venta abre su
    -- propia sesión: el cajero que abre queda como opened_by/mesero.
    update public.table_sessions
    set closed_at = now()
    where table_id = v_table_id
      and closed_at is null;

    insert into public.table_sessions
      (table_id, opened_by, origin, waiter_user_id, people_count, business_id)
    values
      (v_table_id, p_user_id, p_origin, p_user_id,
       greatest(1, coalesce(p_people_count, 1)), p_business_id)
    returning id into v_session_id;

    insert into public.orders
      (session_id, status_ext, subtotal, discounts, tax, total, total_amount)
    values
      (v_session_id, 'open', 0, 0, 0, 0, 0)
    returning id into v_order_id;

    insert into public.order_checks (order_id, label, position)
    values (v_order_id, 'C1', 1);

    return jsonb_build_object(
      'session_id', v_session_id,
      'order_id', v_order_id,
      'business_id', p_business_id,
      'table_id', v_table_id,
      'table_code', v_code,
      'resumed', false
    );
  end loop;
end;
$$;

-- ─── 2. Venta rápida/manual (app nueva y vieja): SIEMPRE venta nueva ────────
-- Misma firma: CREATE OR REPLACE conserva identidad; los permisos se fijan al
-- final de forma explícita.
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
  v_user_id uuid;
  v_business_id uuid;
begin
  v_user_id := public.fn_sales_open_actor(p_user_id, 'fn_open_manual_or_quick');
  if p_origin is null or p_origin::text not in ('quick', 'manual') then
    raise exception 'fn_open_manual_or_quick: invalid origin %', p_origin;
  end if;

  if p_business_id is not null then
    -- Anti tenant-injection: el actor debe pertenecer al negocio.
    if not public.fn_sales_user_can_open(v_user_id, p_business_id) then
      raise exception 'fn_open_manual_or_quick: user % does not belong to business %',
        v_user_id, p_business_id;
    end if;
    v_business_id := p_business_id;
  else
    -- Fallback legacy (cliente que no envía sucursal), determinista.
    v_business_id := public.fn_sales_default_business(v_user_id);
  end if;

  if v_business_id is null then
    raise exception 'fn_open_manual_or_quick: no business found for user %', v_user_id;
  end if;

  -- Las apps anteriores esperan una venta NUEVA en cada apertura: aplican el
  -- cliente "siguiente" a lo recibido y reproducen ventas offline por aquí.
  -- Nunca se entrega ni se anula una cuenta existente.
  return public.fn_sales_virtual_open(
    'fn_open_manual_or_quick', v_business_id, v_user_id, p_origin, p_people_count, null
  );
end;
$$;

-- ─── 3. Carrito retail: retoma por slot exacto ──────────────────────────────
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
  v_user_id uuid;
  v_slot text;
begin
  v_user_id := public.fn_sales_open_actor(p_user_id, 'fn_open_retail_cart');
  if p_business_id is null then
    raise exception 'fn_open_retail_cart: business id is required';
  end if;
  v_slot := left(btrim(coalesce(p_slot, '')), 60);
  if v_slot = '' then
    raise exception 'fn_open_retail_cart: slot is required';
  end if;
  -- Los carriles del negocio ('quick', 'quick#2'…) no son de ningún carrito:
  -- un slot así retomaría la venta de otra caja.
  if v_slot in ('quick', 'manual') or position('#' in v_slot) > 0 then
    raise exception 'fn_open_retail_cart: invalid slot';
  end if;

  -- Anti tenant-injection: el actor debe pertenecer al negocio.
  if not public.fn_sales_user_can_open(v_user_id, p_business_id) then
    raise exception 'fn_open_retail_cart: user % does not belong to business %',
      v_user_id, p_business_id;
  end if;

  return public.fn_sales_virtual_open(
    'fn_open_retail_cart', p_business_id, v_user_id, 'quick', p_people_count, v_slot
  );
end;
$$;

-- ─── 4. Venta offline: identidad por venta local, replays idempotentes ──────
create or replace function public.fn_open_offline_sale(
  p_business_id uuid,
  p_user_id uuid,
  p_slot text,
  p_origin public.order_origin,
  p_people_count integer default 1
) returns jsonb
  language plpgsql
  security definer
  set search_path = public
as $$
declare
  v_user_id uuid;
  v_slot text;
begin
  if p_origin is null or p_origin::text not in ('quick', 'manual') then
    raise exception 'fn_open_offline_sale: invalid origin';
  end if;
  v_user_id := public.fn_sales_open_actor(p_user_id, 'fn_open_offline_sale');
  if p_business_id is null then
    raise exception 'fn_open_offline_sale: business id is required';
  end if;
  v_slot := left(btrim(coalesce(p_slot, '')), 60);
  if v_slot = '' then
    raise exception 'fn_open_offline_sale: slot is required';
  end if;
  -- Los carriles del negocio no son de ninguna venta local (ver retail).
  if v_slot in ('quick', 'manual') or position('#' in v_slot) > 0 then
    raise exception 'fn_open_offline_sale: invalid slot';
  end if;

  -- Anti tenant-injection: el actor debe pertenecer al negocio.
  if not public.fn_sales_user_can_open(v_user_id, p_business_id) then
    raise exception 'fn_open_offline_sale: user % does not belong to business %',
      v_user_id, p_business_id;
  end if;

  return public.fn_sales_virtual_open(
    'fn_open_offline_sale', p_business_id, v_user_id, p_origin, p_people_count, v_slot
  );
end;
$$;

-- ─── 5. Delivery ────────────────────────────────────────────────────────────
-- p_business_id SIN default a propósito: con default, la llamada de 3 argumentos
-- con nombre coincidiría con ambos overloads (PGRST203).
CREATE OR REPLACE FUNCTION public.fn_open_delivery_order(
  p_user_id uuid,
  p_delivery_type text,
  p_people_count int,
  p_business_id uuid
) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public
AS $$
DECLARE
  v_user_id uuid;
  v_business_id uuid;
  v_zone_id uuid;
  v_table_id uuid;
  v_session_id uuid;
  v_order_id uuid;
  v_seq int;
  v_table_code text;
BEGIN
  v_user_id := public.fn_sales_open_actor(p_user_id, 'fn_open_delivery_order');
  IF p_business_id IS NOT NULL THEN
    IF NOT public.fn_sales_user_can_open(v_user_id, p_business_id) THEN
      RAISE EXCEPTION 'fn_open_delivery_order: user does not belong to business';
    END IF;
    v_business_id := p_business_id;
  ELSE
    -- Cliente anterior sin sucursal: fila directa más antigua, o negocio
    -- accesible más antiguo (dueño / usuario compartido), determinista.
    v_business_id := public.fn_sales_default_business(v_user_id);
  END IF;
  IF v_business_id IS NULL THEN
    RAISE EXCEPTION 'fn_open_delivery_order: no business found';
  END IF;
  -- Evita colisión DEL-NNN cuando dos cajas crean delivery simultáneamente.
  PERFORM pg_advisory_xact_lock(hashtextextended(v_business_id::text || ':delivery', 0));

  -- Asegurar zona "Delivery" (sort_index=902). Homónimas: canónica determinista.
  SELECT z.id INTO v_zone_id FROM public.zones z
    WHERE z.business_id = v_business_id AND z.name = 'Delivery'
    ORDER BY (z.sort_index = 902) DESC, z.is_active DESC, z.created_at NULLS LAST, z.id
    LIMIT 1;
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
  -- LPAD con largo fijo trunca 1000 a 100 y choca con una mesa histórica.
  v_table_code := 'DEL-' || LPAD(v_seq::text, greatest(3, length(v_seq::text)), '0');

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
    greatest(1, coalesce(p_people_count, 1)), p_delivery_type, v_business_id
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

-- Compatibilidad con clientes anteriores; la app nueva envía sucursal explícita.
CREATE OR REPLACE FUNCTION public.fn_open_delivery_order(
  p_user_id uuid, p_delivery_type text DEFAULT 'own', p_people_count int DEFAULT 1
) RETURNS jsonb LANGUAGE sql SECURITY DEFINER SET search_path = public AS $$
  SELECT public.fn_open_delivery_order(p_user_id, p_delivery_type, p_people_count, null::uuid)
$$;

-- ─── 6. Dueño y permisos ────────────────────────────────────────────────────
alter function public.fn_sales_open_actor(uuid, text) owner to postgres;
alter function public.fn_sales_user_can_open(uuid, uuid) owner to postgres;
alter function public.fn_sales_default_business(uuid) owner to postgres;
alter function public.fn_sales_virtual_open(text, uuid, uuid, public.order_origin, integer, text) owner to postgres;
alter function public.fn_open_manual_or_quick(public.order_origin, uuid, integer, uuid) owner to postgres;
alter function public.fn_open_retail_cart(uuid, uuid, text, integer) owner to postgres;
alter function public.fn_open_offline_sale(uuid, uuid, text, public.order_origin, integer) owner to postgres;
alter function public.fn_open_delivery_order(uuid, text, integer, uuid) owner to postgres;
alter function public.fn_open_delivery_order(uuid, text, integer) owner to postgres;

-- Helpers internos: solo los llaman las funciones de apertura (SECURITY DEFINER,
-- dueño postgres). Los privilegios por defecto de Supabase les darían EXECUTE a
-- anon/authenticated: se quitan explícitamente.
revoke all on function public.fn_sales_open_actor(uuid, text) from public, anon, authenticated;
revoke all on function public.fn_sales_user_can_open(uuid, uuid) from public, anon, authenticated;
revoke all on function public.fn_sales_default_business(uuid) from public, anon, authenticated;
revoke all on function public.fn_sales_virtual_open(text, uuid, uuid, public.order_origin, integer, text)
  from public, anon, authenticated;

-- RPC de apertura: sin JWT auth.uid() es null y no se puede verificar al usuario,
-- así que anon no recibe nada (CREATE OR REPLACE conserva el ACL viejo, que en
-- Supabase puede incluir anon).
revoke all on function public.fn_open_manual_or_quick(public.order_origin, uuid, integer, uuid) from public, anon;
revoke all on function public.fn_open_retail_cart(uuid, uuid, text, integer) from public, anon;
revoke all on function public.fn_open_offline_sale(uuid, uuid, text, public.order_origin, integer) from public, anon;
revoke all on function public.fn_open_delivery_order(uuid, text, integer, uuid) from public, anon;
revoke all on function public.fn_open_delivery_order(uuid, text, integer) from public, anon;
grant execute on function public.fn_open_manual_or_quick(public.order_origin, uuid, integer, uuid)
  to authenticated, service_role;
grant execute on function public.fn_open_retail_cart(uuid, uuid, text, integer)
  to authenticated, service_role;
grant execute on function public.fn_open_offline_sale(uuid, uuid, text, public.order_origin, integer)
  to authenticated, service_role;
grant execute on function public.fn_open_delivery_order(uuid, text, integer, uuid)
  to authenticated, service_role;
grant execute on function public.fn_open_delivery_order(uuid, text, integer)
  to authenticated, service_role;

-- fn_get_or_create_virtual_table crea zonas/mesas en cualquier negocio sin
-- validar pertenencia. Ningún cliente la llama (verificado en lib/, app Apple,
-- dashboard, administrador, edge functions y agente); solo la usa el cuerpo
-- restaurado por el ROLLBACK, que corre como postgres.
do $$
begin
  if to_regprocedure('public.fn_get_or_create_virtual_table(uuid, public.order_origin)') is not null then
    revoke all on function public.fn_get_or_create_virtual_table(uuid, public.order_origin)
      from public, anon, authenticated;
  end if;
end $$;

-- ─── 7. Guarda final: ningún par de overloads ambiguo ───────────────────────
-- Si la BD viva tiene otra firma de estas funciones, se aborta todo aquí en vez
-- de dejar llamadas con PGRST203.
do $$
declare
  v_bad text;
begin
  select string_agg(format('%s (%s firmas)', proname, n), ', ' order by proname)
    into v_bad
  from (
    select p.proname, count(*) as n
    from pg_proc p
    where p.pronamespace = 'public'::regnamespace
      and p.proname in ('fn_open_manual_or_quick', 'fn_open_retail_cart',
                        'fn_open_offline_sale', 'fn_open_delivery_order')
    group by p.proname
  ) x
  where n <> case when proname = 'fn_open_delivery_order' then 2 else 1 end;
  if v_bad is not null then
    raise exception '20261009_0004: overloads inesperados: %', v_bad;
  end if;
  if (select p.pronargdefaults
        from pg_proc p
       where p.oid = 'public.fn_open_delivery_order(uuid, text, integer, uuid)'::regprocedure) <> 0 then
    raise exception '20261009_0004: fn_open_delivery_order de 4 argumentos no puede tener defaults';
  end if;
end $$;

notify pgrst, 'reload schema';
commit;
