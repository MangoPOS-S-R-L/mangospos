-- =============================================================================
-- Migration: fn_transfer_table_session (F2 del PRD-12 Mover/Unir Mesas)
-- Purpose : Transferir toda la cuenta de una mesa a otra, o solo items
--           específicos. Cubre el caso típico: el cliente se cambia de
--           mesa, o un mesero pasa parte del pedido a otra cuenta.
--
-- Modos:
--   1. TODA LA CUENTA (p_item_ids = NULL):
--      - Si la mesa destino NO tiene sesión: cambia
--        `table_sessions.table_id` del origen → destino. Mesa origen
--        queda available, mesa destino occupied con la misma sesión.
--      - Si la mesa destino TIENE sesión abierta: combina las órdenes.
--        UPDATE orders.session_id del origen → session destino, cierra
--        la sesión origen (vacía) y libera la mesa origen.
--   2. ITEMS ESPECÍFICOS (p_item_ids = uuid[]):
--      - Si destino TIENE sesión + orden abierta: UPDATE order_items
--        para reapuntar order_id al order destino.
--      - Si destino NO tiene sesión: abrir sesión nueva, crear orden
--        nueva en esa sesión, mover los items.
--      - La orden origen queda con los items NO movidos (si quedan
--        items, mesa origen sigue ocupada; si no quedan, se libera).
--
-- Recalcula totales (`fn_recalc_order_totals`) en cada orden tocada.
--
-- Seguridad:
--   - SECURITY DEFINER, RBAC manual via is_member_of_business (cualquier
--     miembro puede transferir; el PIN supervisor se valida client-side
--     ANTES de invocar este RPC).
--   - Bloquea cross-business: la mesa destino debe ser del mismo
--     business que la origen.
-- =============================================================================

CREATE OR REPLACE FUNCTION public.fn_transfer_table_session(
  p_source_session_id uuid,
  p_target_table_id   uuid,
  p_item_ids          uuid[] DEFAULT NULL
) RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $$
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

  -- 1. Origen: validar sesión existe y está abierta
  SELECT s.business_id, s.table_id, t.state
    INTO v_business_id, v_source_table_id, v_source_table_state
  FROM public.table_sessions s
  JOIN public.dining_tables t ON t.id = s.table_id
  WHERE s.id = p_source_session_id AND s.closed_at IS NULL;

  IF v_business_id IS NULL THEN
    RAISE EXCEPTION 'SOURCE_SESSION_NOT_FOUND_OR_CLOSED';
  END IF;

  -- 2. Destino: validar mesa existe y same business
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

  -- 3. RBAC: cualquier miembro del business puede transferir (el PIN
  -- supervisor se valida en cliente antes de llegar aquí).
  IF NOT public.is_member_of_business(v_business_id) THEN
    RAISE EXCEPTION 'NOT_AUTHORIZED';
  END IF;

  -- 4. Buscar la orden abierta del origen (la usamos en ambos modos)
  SELECT id INTO v_source_order_id
  FROM public.orders
  WHERE session_id = p_source_session_id
    AND closed_at IS NULL
    AND COALESCE(status_ext::text, '') NOT IN ('paid', 'void')
  ORDER BY created_at DESC
  LIMIT 1;

  IF v_source_order_id IS NULL THEN
    RAISE EXCEPTION 'SOURCE_ORDER_NOT_FOUND';
  END IF;

  -- 5. Buscar (o detectar ausencia de) sesión destino abierta
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
    ORDER BY created_at DESC
    LIMIT 1;
  END IF;

  -- =====================================================================
  -- MODO A: TODA LA CUENTA
  -- =====================================================================
  IF p_item_ids IS NULL OR array_length(p_item_ids, 1) IS NULL THEN
    v_mode := 'full';

    IF v_target_session_id IS NULL THEN
      -- Caso simple: destino vacío. Reapuntamos la sesión.
      UPDATE public.table_sessions
      SET table_id = p_target_table_id
      WHERE id = p_source_session_id;

      UPDATE public.dining_tables
      SET state = 'available'::public.table_state
      WHERE id = v_source_table_id;

      UPDATE public.dining_tables
      SET state = 'occupied'::public.table_state
      WHERE id = p_target_table_id;
    ELSE
      -- Combinar: mover todas las órdenes del origen al destino.
      UPDATE public.orders
      SET session_id = v_target_session_id
      WHERE session_id = p_source_session_id;

      -- Cerrar la sesión origen vacía y liberar la mesa origen.
      UPDATE public.table_sessions
      SET closed_at = now()
      WHERE id = p_source_session_id;

      UPDATE public.dining_tables
      SET state = 'available'::public.table_state
      WHERE id = v_source_table_id;
    END IF;

    -- Recalcular totales del order origen (que ahora puede o no estar
    -- bajo session destino) y del order destino si existía.
    PERFORM public.fn_recalc_order_totals(v_source_order_id);
    IF v_target_order_id IS NOT NULL AND v_target_order_id <> v_source_order_id THEN
      PERFORM public.fn_recalc_order_totals(v_target_order_id);
    END IF;

    RETURN jsonb_build_object(
      'mode', v_mode,
      'source_session_id', p_source_session_id,
      'source_table_id', v_source_table_id,
      'target_table_id', p_target_table_id,
      'target_session_id', COALESCE(v_target_session_id, p_source_session_id),
      'merged_with_existing', v_target_session_id IS NOT NULL
    );
  END IF;

  -- =====================================================================
  -- MODO B: ITEMS ESPECÍFICOS
  -- =====================================================================
  v_mode := 'partial';

  -- Validar que los items pertenecen a la orden origen.
  IF EXISTS (
    SELECT 1 FROM public.order_items
    WHERE id = ANY(p_item_ids) AND order_id <> v_source_order_id
  ) THEN
    RAISE EXCEPTION 'ITEMS_NOT_IN_SOURCE_ORDER';
  END IF;

  -- Asegurar sesión + orden destino. Si destino no tiene sesión,
  -- abrirla; misma cosa si no tiene orden abierta.
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

  -- Mover los items.
  WITH moved AS (
    UPDATE public.order_items
    SET order_id = v_target_order_id
    WHERE id = ANY(p_item_ids) AND order_id = v_source_order_id
    RETURNING id
  )
  SELECT count(*)::int INTO v_moved_items FROM moved;

  -- Recalcular totales en ambas órdenes.
  PERFORM public.fn_recalc_order_totals(v_source_order_id);
  PERFORM public.fn_recalc_order_totals(v_target_order_id);

  -- Si el origen quedó sin items abiertos, liberar la mesa origen.
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
$$;

GRANT EXECUTE ON FUNCTION public.fn_transfer_table_session(uuid, uuid, uuid[])
  TO authenticated, service_role;

COMMENT ON FUNCTION public.fn_transfer_table_session(uuid, uuid, uuid[]) IS
  'PRD-12 F2: transfiere una sesión completa o items específicos a otra '
  'mesa. Si destino tiene sesión abierta, combina automático. PIN '
  'supervisor se valida client-side antes del RPC.';
