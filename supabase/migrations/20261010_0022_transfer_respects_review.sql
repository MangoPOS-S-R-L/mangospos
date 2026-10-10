-- =============================================================================
-- 20261010_0022 — Transferir / unir mesa respeta las cuentas en revisión
-- =============================================================================
--
-- POR QUÉ. Con 20261010_0020 (aplicada) una sesión de mesa puede tener una
-- segunda orden «en revisión» (llegó de otro equipo o tarde). La transferencia
-- viva elige «la orden más nueva» de cada sesión:
--   · ORIGEN con cuenta en revisión: movía una de las dos y, al unir/mover todo
--     (o vaciar la elegida en una transferencia parcial), cerraba la sesión
--     origen → la otra cuenta quedaba viva sin mesa (huérfana).
--   · DESTINO con cuenta en revisión: los productos podían caer en ella en vez
--     de en la cuenta actual.
--
-- QUÉ CAMBIA (cuerpo vivo del 10-oct, md5 4eed56f3cecd3beee2273b3f94633190):
--   1. Candado por mesa (el de fn_open_table y las liberaciones) sobre origen y
--      destino, en orden fijo, y re-chequeo de la sesión origen dentro de él.
--   2. Origen con cuenta en revisión → MP412 «Resuélvela antes de transferirla
--      o unirla». La app nueva lo frena antes (ZonesRepository); esto cubre a
--      todas las versiones.
--   3. Origen y destino eligen solo la cuenta principal (review_reason null):
--      la cuenta en revisión del destino queda intacta.
--   Nada más: modos, retornos y efectos iguales.
--
-- IDEMPOTENTE. ROLLBACK: 20261010_0022_transfer_respects_review_ROLLBACK.sql
-- Prueba local: supabase/tests/transfer_respects_review_local_test.sh
-- =============================================================================

begin;

CREATE OR REPLACE FUNCTION public.fn_transfer_table_session(p_source_session_id uuid, p_target_table_id uuid, p_item_ids uuid[] DEFAULT NULL::uuid[])
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  v_business_id          uuid;
  v_source_table_id      uuid;
  v_source_table_state   public.table_state;
  v_source_order_id      uuid;
  v_target_session_id    uuid;
  v_target_business_id   uuid;
  v_target_table_state   public.table_state;
  v_target_order_id      uuid;
  v_target_zone_id       uuid;
  v_caller_id            uuid := auth.uid();
  v_remaining_items      int;
  v_moved_items          int := 0;
  v_mode                 text;
BEGIN
  IF p_source_session_id IS NULL OR p_target_table_id IS NULL THEN
    RAISE EXCEPTION 'INVALID_INPUT';
  END IF;

  SELECT s.business_id, s.table_id, t.state
    INTO v_business_id, v_source_table_id, v_source_table_state
  FROM public.table_sessions s
  JOIN public.dining_tables t ON t.id = s.table_id
  WHERE s.id = p_source_session_id AND s.closed_at IS NULL;

  IF v_business_id IS NULL THEN
    RAISE EXCEPTION 'SOURCE_SESSION_NOT_FOUND_OR_CLOSED';
  END IF;

  SELECT z.business_id, t.state, t.zone_id
    INTO v_target_business_id, v_target_table_state, v_target_zone_id
  FROM public.dining_tables t
  JOIN public.zones z ON z.id = t.zone_id
  WHERE t.id = p_target_table_id;

  IF v_target_business_id IS NULL THEN
    RAISE EXCEPTION 'TARGET_TABLE_NOT_FOUND';
  END IF;

  IF v_target_business_id <> v_business_id THEN
    RAISE EXCEPTION 'SAME_BUSINESS_REQUIRED';
  END IF;

  IF v_source_table_id = p_target_table_id THEN
    RAISE EXCEPTION 'SAME_TABLE_NOT_ALLOWED';
  END IF;

  IF NOT public.is_member_of_business(v_business_id) THEN
    RAISE EXCEPTION 'NOT_AUTHORIZED';
  END IF;

  -- ─── Candado por mesa (20261010_0022) ─────────────────────────────────
  -- El mismo de fn_open_table, las liberaciones y el candado de ítems, en
  -- orden fijo: dos transferencias cruzadas no se esperan en círculo.
  PERFORM pg_advisory_xact_lock(
    hashtextextended(LEAST(v_source_table_id, p_target_table_id)::text, 0));
  PERFORM pg_advisory_xact_lock(
    hashtextextended(GREATEST(v_source_table_id, p_target_table_id)::text, 0));

  -- Re-chequeo dentro del candado: la sesión origen pudo cerrarse mientras
  -- esperábamos.
  IF NOT EXISTS (
    SELECT 1 FROM public.table_sessions
    WHERE id = p_source_session_id AND closed_at IS NULL
  ) THEN
    RAISE EXCEPTION 'SOURCE_SESSION_NOT_FOUND_OR_CLOSED';
  END IF;

  -- Cuenta en revisión en el origen (20261010_0020): mover «la orden más
  -- nueva» y cerrar la sesión dejaría la otra cuenta viva sin mesa.
  IF EXISTS (
    SELECT 1 FROM public.orders
    WHERE session_id = p_source_session_id
      AND closed_at IS NULL
      AND COALESCE(status_ext::text, '') NOT IN ('paid', 'void')
      AND review_reason IS NOT NULL
  ) THEN
    RAISE EXCEPTION 'Esta mesa tiene una cuenta en revisión. Resuélvela antes de transferirla o unirla.'
      USING errcode = 'MP412';
  END IF;

  SELECT id INTO v_source_order_id
  FROM public.orders
  WHERE session_id = p_source_session_id
    AND closed_at IS NULL
    AND COALESCE(status_ext::text, '') NOT IN ('paid', 'void')
    AND review_reason IS NULL
  ORDER BY created_at DESC
  LIMIT 1;

  IF v_source_order_id IS NULL THEN
    RAISE EXCEPTION 'SOURCE_ORDER_NOT_FOUND';
  END IF;

  SELECT id INTO v_target_session_id
  FROM public.table_sessions
  WHERE table_id = p_target_table_id
    AND closed_at IS NULL
  ORDER BY opened_at DESC
  LIMIT 1;

  IF v_target_session_id IS NOT NULL THEN
    SELECT id INTO v_target_order_id
    FROM public.orders
    WHERE session_id = v_target_session_id
      AND closed_at IS NULL
      AND COALESCE(status_ext::text, '') NOT IN ('paid', 'void')
      AND review_reason IS NULL
    ORDER BY created_at DESC
    LIMIT 1;
  END IF;

  -- =====================================================================
  -- MODO A: TODA LA CUENTA
  -- =====================================================================
  IF p_item_ids IS NULL OR array_length(p_item_ids, 1) IS NULL THEN
    v_mode := 'full';

    IF v_target_session_id IS NULL THEN
      -- Destino vacío: reapuntar la sesión.
      UPDATE public.table_sessions
      SET table_id = p_target_table_id
      WHERE id = p_source_session_id;

      UPDATE public.dining_tables
      SET state = 'available'::public.table_state
      WHERE id = v_source_table_id;

      UPDATE public.dining_tables
      SET state = 'occupied'::public.table_state
      WHERE id = p_target_table_id;

      PERFORM public.fn_recalc_order_totals(v_source_order_id);

    ELSIF v_target_order_id IS NULL THEN
      -- Destino tiene sesión abierta PERO sin orden activa (caso raro:
      -- sesión vacía). Reapuntar la orden origen a esa sesión y cerrar
      -- la sesión origen.
      UPDATE public.orders
      SET session_id = v_target_session_id
      WHERE id = v_source_order_id;

      UPDATE public.table_sessions
      SET closed_at = now()
      WHERE id = p_source_session_id;

      UPDATE public.dining_tables
      SET state = 'available'::public.table_state
      WHERE id = v_source_table_id;

      PERFORM public.fn_recalc_order_totals(v_source_order_id);

    ELSE
      -- ★ FIX: destino tiene sesión + orden activa.
      -- Antes: UPDATE orders SET session_id (dejaba 2 orders en la
      -- sesión, UI solo leía una).
      -- Ahora: consolidar items en la ÚNICA orden destino.
      WITH moved AS (
        UPDATE public.order_items
        SET order_id = v_target_order_id,
            check_id = NULL
        WHERE order_id = v_source_order_id
          AND status <> 'void'
        RETURNING id
      )
      SELECT count(*)::int INTO v_moved_items FROM moved;

      -- Cerrar la orden origen (ya sin items abiertos).
      UPDATE public.orders
      SET closed_at = now(),
          status_ext = 'void'::public.order_status
      WHERE id = v_source_order_id;

      -- Cerrar la sesión origen vacía y liberar la mesa origen.
      UPDATE public.table_sessions
      SET closed_at = now()
      WHERE id = p_source_session_id;

      UPDATE public.dining_tables
      SET state = 'available'::public.table_state
      WHERE id = v_source_table_id;

      -- Recalcular totales en la orden destino (que ahora tiene
      -- los items consolidados).
      PERFORM public.fn_recalc_order_totals(v_target_order_id);
    END IF;

    RETURN jsonb_build_object(
      'mode', v_mode,
      'source_session_id', p_source_session_id,
      'source_table_id', v_source_table_id,
      'target_table_id', p_target_table_id,
      'target_session_id', COALESCE(v_target_session_id, p_source_session_id),
      'target_order_id', COALESCE(v_target_order_id, v_source_order_id),
      'merged_with_existing', v_target_session_id IS NOT NULL,
      'items_consolidated', v_moved_items
    );
  END IF;

  -- =====================================================================
  -- MODO B: ITEMS ESPECÍFICOS  (sin cambios)
  -- =====================================================================
  v_mode := 'partial';

  IF EXISTS (
    SELECT 1 FROM public.order_items
    WHERE id = ANY(p_item_ids) AND order_id <> v_source_order_id
  ) THEN
    RAISE EXCEPTION 'ITEMS_NOT_IN_SOURCE_ORDER';
  END IF;

  IF v_target_session_id IS NULL THEN
    INSERT INTO public.table_sessions (
      business_id, table_id, opened_by, opened_at, origin
    ) VALUES (
      v_business_id, p_target_table_id, v_caller_id, now(), 'dine_in'
    )
    RETURNING id INTO v_target_session_id;

    UPDATE public.dining_tables
    SET state = 'occupied'::public.table_state
    WHERE id = p_target_table_id;
  END IF;

  IF v_target_order_id IS NULL THEN
    INSERT INTO public.orders (session_id, created_at)
    VALUES (v_target_session_id, now())
    RETURNING id INTO v_target_order_id;
  END IF;

  WITH moved AS (
    UPDATE public.order_items
    SET order_id = v_target_order_id,
        check_id = NULL
    WHERE id = ANY(p_item_ids) AND order_id = v_source_order_id
    RETURNING id
  )
  SELECT count(*)::int INTO v_moved_items FROM moved;

  PERFORM public.fn_recalc_order_totals(v_source_order_id);
  PERFORM public.fn_recalc_order_totals(v_target_order_id);

  SELECT count(*)::int INTO v_remaining_items
  FROM public.order_items
  WHERE order_id = v_source_order_id
    AND status <> 'void';

  IF v_remaining_items = 0 THEN
    UPDATE public.table_sessions
    SET closed_at = now()
    WHERE id = p_source_session_id;

    UPDATE public.dining_tables
    SET state = 'available'::public.table_state
    WHERE id = v_source_table_id;
  END IF;

  RETURN jsonb_build_object(
    'mode', v_mode,
    'source_session_id', p_source_session_id,
    'source_table_id', v_source_table_id,
    'target_table_id', p_target_table_id,
    'target_session_id', v_target_session_id,
    'target_order_id', v_target_order_id,
    'items_moved', v_moved_items,
    'source_emptied', v_remaining_items = 0
  );
END;
$function$;

commit;
