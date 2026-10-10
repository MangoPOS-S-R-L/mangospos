-- =============================================================================
-- Definiciones VIVAS (producción) de apertura, carga, cierre y salón de mesas.
-- Fuente: pg_get_functiondef / pg_get_viewdef / pg_indexes corridos por el
-- dueño en el SQL Editor el 2026-10-10 (~14:15 RD). Evidencia F0 del plan
-- docs/PLAN_IMPLEMENTACION_HUB_FOOD_SHOP_2026_10_10.md. NO es una migración:
-- no ejecutar contra ninguna base.
--
-- Hallazgos:
--   - fn_open_table = 20260516_0001_multimesero_setup.sql (sin diferencias de
--     lógica). Toma la última sesión abierta y la última orden viva de la mesa.
--   - fn_open_table_and_load solo delega en fn_open_table + fn_get_order_bundle:
--     cambiar la elección de orden en fn_open_table cubre a las dos.
--   - fn_close_order_and_table libera sesión y mesa SOLO si no queda ninguna
--     orden viva en la sesión.
--   - v_zone_table_status = 20260605_0007: total suma TODAS las órdenes vivas
--     de la sesión; una sola sesión por mesa (lateral limit 1).
--   - uniq_open_session_per_table existe: dos sesiones abiertas en una mesa
--     son imposibles.
--
-- Relacionado, verificado el mismo día:
--   - fn_release_empty_tables: md5(prosrc) = f681b45052c86bb3ad2b586cf8ef93a2
--     (20261010_0004_contain_auto_releases aplicada; antes 0f4f14c5... = 20260814_0002).
--   - cron: '*/15 * * * *' -> select public.fn_release_empty_tables(20);
--     corridas 12:45–13:45 'succeeded'.
--   - fn_release_empty_table viva: la de 20261010_0003_table_release_acks_ROLLBACK
--     (hoy 20261010_0030_..._ROLLBACK), FOR UPDATE de dining_tables.
-- =============================================================================

-- ---------------------------------------------------------------------------
-- fn_open_table
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.fn_open_table(p_table_id uuid, p_user_id uuid, p_people_count integer DEFAULT 1, p_opened_by_employee_id uuid DEFAULT NULL::uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
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
$function$;

-- ---------------------------------------------------------------------------
-- fn_open_table_and_load (solo existe en la base viva)
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.fn_open_table_and_load(p_table_id uuid, p_user_id uuid DEFAULT NULL::uuid, p_people_count integer DEFAULT 1, p_opened_by_employee_id uuid DEFAULT NULL::uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  v_open_result jsonb;
  v_order_id uuid;
  v_bundle jsonb;
  v_items_enriched jsonb;
BEGIN
  -- 1) Delegar a fn_open_table
  v_open_result := fn_open_table(
    p_people_count := p_people_count,
    p_table_id := p_table_id,
    p_user_id := p_user_id,
    p_opened_by_employee_id := p_opened_by_employee_id
  );

  v_order_id := (v_open_result->>'order_id')::uuid;
  IF v_order_id IS NULL THEN
    RAISE EXCEPTION 'fn_open_table no retornó order_id';
  END IF;

  -- 2) Bundle completo
  v_bundle := fn_get_order_bundle(v_order_id);

  -- 3) Enriquecer cada item con modifiers + tax_lines
  WITH item_ids AS (
    SELECT (item->>'id')::uuid AS id
    FROM jsonb_array_elements(COALESCE(v_bundle->'items', '[]'::jsonb)) item
  ),
  mods AS (
    SELECT
      m.item_id,
      jsonb_agg(jsonb_build_object(
        'id', m.id,
        'item_id', m.item_id,
        'name', m.name,
        'qty', m.qty,
        'price', m.price
      ) ORDER BY m.id) AS list
    FROM order_item_modifiers m
    WHERE m.item_id IN (SELECT id FROM item_ids)
    GROUP BY m.item_id
  ),
  taxes AS (
    SELECT
      t.order_item_id,
      jsonb_agg(jsonb_build_object(
        'id', t.id,
        'order_item_id', t.order_item_id,
        'tax_id', t.tax_id,
        'tax_name', t.tax_name,
        'tax_rate', t.tax_rate,
        'amount', t.amount
      ) ORDER BY t.id) AS list
    FROM order_item_tax_lines t
    WHERE t.order_item_id IN (SELECT id FROM item_ids)
    GROUP BY t.order_item_id
  )
  SELECT COALESCE(jsonb_agg(
    item || jsonb_build_object(
      'modifiers', COALESCE(mods.list, '[]'::jsonb),
      'tax_lines', COALESCE(taxes.list, '[]'::jsonb)
    )
  ), '[]'::jsonb)
  INTO v_items_enriched
  FROM jsonb_array_elements(COALESCE(v_bundle->'items', '[]'::jsonb)) item
  LEFT JOIN mods ON mods.item_id = (item->>'id')::uuid
  LEFT JOIN taxes ON taxes.order_item_id = (item->>'id')::uuid;

  -- 4) Reemplazar items en el bundle
  v_bundle := jsonb_set(v_bundle, '{items}', v_items_enriched);

  -- 5) Resultado unificado
  RETURN jsonb_build_object(
    'order_id', v_order_id,
    'open_result', v_open_result,
    'bundle', v_bundle
  );
END;
$function$;

-- ---------------------------------------------------------------------------
-- fn_get_order_bundle
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.fn_get_order_bundle(p_order_id uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  v_payload jsonb;
begin
  if p_order_id is null then
    raise exception 'ORDER_ID_REQUIRED';
  end if;

  with target_order as (
    select o.*
    from public.orders o
    where o.id = p_order_id
    limit 1
  ),
  order_customer as (
    select ts.customer_id, ts.customer_name
    from target_order o
    join public.table_sessions ts on ts.id = o.session_id
  )
  select jsonb_build_object(
    'order',
      (select to_jsonb(o) from target_order o),
    'checks',
      coalesce(
        (
          select jsonb_agg(to_jsonb(oc) order by oc.position)
          from public.order_checks oc
          where oc.order_id = p_order_id
        ),
        '[]'::jsonb
      ),
    'items',
      coalesce(
        (
          select jsonb_agg(
            to_jsonb(oi) || jsonb_build_object(
              'employees', (
                select jsonb_build_object(
                  'first_name', e.first_name,
                  'last_name', e.last_name
                )
                from public.employees e
                where e.id = oi.created_by_employee_id
              ),
              'modifiers', coalesce(
                (
                  select jsonb_agg(to_jsonb(m) order by m.id)
                  from public.order_item_modifiers m
                  where m.item_id = oi.id
                ),
                '[]'::jsonb
              ),
              'tax_lines', coalesce(
                (
                  select jsonb_agg(to_jsonb(tl) order by tl.created_at)
                  from public.order_item_tax_lines tl
                  where tl.order_item_id = oi.id
                ),
                '[]'::jsonb
              )
            )
            order by oi.created_at, oi.id
          )
          from public.order_items oi
          join target_order o on o.id = oi.order_id
          where oi.status not in ('paid'::public.item_status, 'void'::public.item_status)
            and (o.closed_at is null or o.status_ext not in ('void', 'paid'))
        ),
        '[]'::jsonb
      ),
    'customer_id',
      (select customer_id from order_customer limit 1),
    'customer_name',
      (select customer_name from order_customer limit 1)
  )
  into v_payload;

  if v_payload is null or (v_payload -> 'order') is null then
    raise exception 'ORDER_NOT_FOUND';
  end if;

  return v_payload;
end;
$function$;

-- ---------------------------------------------------------------------------
-- fn_close_order_and_table
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.fn_close_order_and_table(p_order_id uuid, p_status order_status)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  v_session uuid;
  v_open_count int;
  v_table_id uuid;
  v_legacy_status text;
begin
  -- Mapeo enum → text legacy. Mantenemos compatibilidad con queries
  -- que aún leen `status` (KDS, reportes, etc.).
  v_legacy_status := case p_status
    when 'paid'::public.order_status then 'paid'
    when 'void'::public.order_status then 'canceled'
    else null
  end;

  update public.orders
  set status_ext = p_status,
      status     = coalesce(v_legacy_status, status),
      closed_at  = now()
  where id = p_order_id;

  -- FIX 2026-06-24: cierre atómico de checks. Sin esto, un cobro a nivel de
  -- orden dejaba el/los order_checks con is_closed=false → cuenta editable tras
  -- el pago (ver caso NCF B0200070797). Idempotente: solo cierra los abiertos.
  update public.order_checks
  set is_closed = true,
      closed_at = now()
  where order_id = p_order_id
    and coalesce(is_closed, false) = false;

  select session_id into v_session from public.orders where id = p_order_id;
  select table_id into v_table_id from public.table_sessions where id = v_session;

  select count(*) into v_open_count
  from public.orders
  where session_id = v_session
    and closed_at is null
    and status_ext not in ('paid', 'void');

  if coalesce(v_open_count, 0) = 0 then
    update public.table_sessions
    set closed_at = now()
    where id = v_session and closed_at is null;

    if v_table_id is not null then
      update public.dining_tables
      set state = 'available'
      where id = v_table_id;
    end if;
  end if;
end;
$function$;

-- ---------------------------------------------------------------------------
-- uniq_open_session_per_table
-- ---------------------------------------------------------------------------
-- CREATE UNIQUE INDEX uniq_open_session_per_table ON public.table_sessions USING btree (table_id) WHERE (closed_at IS NULL)

-- ---------------------------------------------------------------------------
-- v_zone_table_status (pg_get_viewdef, pretty)
-- ---------------------------------------------------------------------------
-- CREATE OR REPLACE VIEW public.v_zone_table_status AS
--  SELECT t.id AS table_id,
--     z.id AS zone_id,
--     z.name AS zone_name,
--     z.business_id,
--     t.code,
--     t.label,
--     t.shape,
--     t.capacity,
--     t.state,
--     s.id AS session_id,
--     s.opened_by,
--     s.opened_at,
--     s.waiter_user_id,
--     s.customer_name,
--     s.people_count,
--     COALESCE(( SELECT NULLIF(split_part(btrim(e.first_name), ' '::text, 1), ''::text) AS "nullif"
--            FROM employees e
--           WHERE e.id = s.opened_by_employee_id), ( SELECT NULLIF(split_part(btrim(e.first_name), ' '::text, 1), ''::text) AS "nullif"
--            FROM employees e
--           WHERE e.user_id = s.waiter_user_id AND e.business_id = z.business_id
--          LIMIT 1), ( SELECT NULLIF(split_part(btrim(p.full_name), ' '::text, 1), ''::text) AS "nullif"
--            FROM profiles p
--           WHERE p.id = s.waiter_user_id), ( SELECT NULLIF(split_part(btrim(e.first_name), ' '::text, 1), ''::text) AS "nullif"
--            FROM employees e
--           WHERE e.user_id = s.opened_by AND e.business_id = z.business_id
--          LIMIT 1), ( SELECT NULLIF(split_part(btrim(p.full_name), ' '::text, 1), ''::text) AS "nullif"
--            FROM profiles p
--           WHERE p.id = s.opened_by)) AS waiter_name,
--     uid() IS NOT NULL AND uid() = COALESCE(s.waiter_user_id, s.opened_by) AS is_own,
--         CASE
--             WHEN s.opened_at IS NOT NULL AND s.closed_at IS NULL THEN EXTRACT(epoch FROM now() - s.opened_at)::integer / 60
--             ELSE NULL::integer
--         END AS minutes_open,
--     COALESCE(( SELECT count(*) AS count
--            FROM orders o
--           WHERE o.session_id = s.id), 0::bigint) AS orders_count,
--     COALESCE(( SELECT round(sum(
--                 CASE
--                     WHEN oi.tax_mode = 'inclusive'::text THEN oi.unit_price * COALESCE(oi.qty, oi.quantity, 1::numeric) + COALESCE(( SELECT sum(m.price * m.qty) AS sum
--                        FROM order_item_modifiers m
--                       WHERE m.item_id = oi.id), 0::numeric) - COALESCE(oi.discounts, 0::numeric)
--                     ELSE oi.total
--                 END), 2) AS round
--            FROM order_items oi
--              JOIN orders o2 ON o2.id = oi.order_id
--           WHERE o2.session_id = s.id AND o2.closed_at IS NULL AND (o2.status_ext <> ALL (ARRAY['paid'::order_status, 'void'::order_status])) AND (oi.status <> ALL (ARRAY['paid'::item_status, 'void'::item_status]))), 0::numeric) AS total,
--         CASE
--             WHEN s.precheck_printed_at IS NOT NULL AND s.closed_at IS NULL THEN 'paying'::text
--             ELSE NULL::text
--         END AS status
--    FROM dining_tables t
--      JOIN zones z ON z.id = t.zone_id
--      LEFT JOIN LATERAL ( SELECT s2.id,
--             s2.table_id,
--             s2.opened_by,
--             s2.opened_at,
--             s2.closed_at,
--             s2.customer_name,
--             s2.note,
--             s2.origin,
--             s2.waiter_user_id,
--             s2.people_count,
--             s2.business_id,
--             s2.customer_id,
--             s2.delivery_type,
--             s2.opened_by_employee_id,
--             s2.precheck_printed_at,
--             s2.delivery_address
--            FROM table_sessions s2
--           WHERE s2.table_id = t.id AND s2.closed_at IS NULL
--           ORDER BY s2.opened_at DESC
--          LIMIT 1) s ON true;
