-- ============================================================
-- DELIVERY SYSTEM
-- ============================================================

-- 1. Agregar delivery_type a table_sessions
ALTER TABLE public.table_sessions
  ADD COLUMN IF NOT EXISTS delivery_type text;

ALTER TABLE public.table_sessions
  DROP CONSTRAINT IF EXISTS chk_delivery_type;
ALTER TABLE public.table_sessions
  ADD CONSTRAINT chk_delivery_type
  CHECK (delivery_type IS NULL OR delivery_type IN ('own', 'uber_eats', 'pedidos_ya'));

-- 2. Agregar apply_on_delivery a taxes
ALTER TABLE public.taxes
  ADD COLUMN IF NOT EXISTS apply_on_delivery boolean NOT NULL DEFAULT true;

-- 3. Agregar service_fee_on_delivery a business_settings
ALTER TABLE public.business_settings
  ADD COLUMN IF NOT EXISTS service_fee_on_delivery boolean DEFAULT false;

-- ============================================================
-- fn_open_delivery_order: crea mesa temporal + sesión + orden
-- ============================================================
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

-- ============================================================
-- fn_list_delivery_orders: lista órdenes activas de delivery
-- ============================================================
CREATE OR REPLACE FUNCTION public.fn_list_delivery_orders(
  p_business_id uuid
) RETURNS TABLE(
  session_id uuid, order_id uuid, table_id uuid,
  table_code text, delivery_type text, status_ext text,
  total numeric, items_count bigint, opened_at timestamptz,
  customer_name text
)
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public
AS $$
  SELECT
    ts.id AS session_id,
    o.id AS order_id,
    dt.id AS table_id,
    dt.code AS table_code,
    ts.delivery_type,
    o.status_ext::text,
    COALESCE(o.total, 0) AS total,
    COALESCE(item_counts.cnt, 0) AS items_count,
    ts.opened_at,
    ts.customer_name
  FROM public.table_sessions ts
  JOIN public.dining_tables dt ON ts.table_id = dt.id
  JOIN public.zones z ON dt.zone_id = z.id
  LEFT JOIN public.orders o ON ts.id = o.session_id
  LEFT JOIN LATERAL (
    SELECT COUNT(*) AS cnt FROM public.order_items oi WHERE oi.order_id = o.id
  ) item_counts ON true
  WHERE z.business_id = p_business_id
    AND ts.origin = 'delivery'
    AND ts.closed_at IS NULL
  ORDER BY ts.opened_at DESC;
$$;

GRANT EXECUTE ON FUNCTION public.fn_list_delivery_orders(uuid) TO authenticated;

-- ============================================================
-- fn_close_delivery_order: cierra orden y limpia mesa temporal
-- ============================================================
CREATE OR REPLACE FUNCTION public.fn_close_delivery_order(
  p_order_id uuid,
  p_status text DEFAULT 'paid'
) RETURNS void
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public
AS $$
DECLARE
  v_session_id uuid;
  v_table_id uuid;
  v_is_delivery boolean;
BEGIN
  -- Cerrar orden
  UPDATE public.orders
    SET status_ext = p_status, closed_at = now()
    WHERE id = p_order_id;

  -- Obtener session y table
  SELECT o.session_id, ts.table_id, (ts.origin = 'delivery')
    INTO v_session_id, v_table_id, v_is_delivery
    FROM public.orders o
    JOIN public.table_sessions ts ON o.session_id = ts.id
    WHERE o.id = p_order_id;

  IF NOT v_is_delivery THEN RETURN; END IF;

  -- Cerrar sesión
  UPDATE public.table_sessions
    SET closed_at = now()
    WHERE id = v_session_id AND closed_at IS NULL;

  -- Marcar mesa como available (la vista filtra por sesión abierta)
  IF v_table_id IS NOT NULL THEN
    UPDATE public.dining_tables
      SET state = 'available', is_active = false
      WHERE id = v_table_id;
  END IF;
END;
$$;

GRANT EXECUTE ON FUNCTION public.fn_close_delivery_order(uuid, text) TO authenticated;

-- ============================================================
-- Actualizar filtro de impuestos por origin para incluir delivery
-- ============================================================
-- Ya incluido en fn_resolve_order_item_tax_profile: fallback aplica a origins no listados

-- Actualizar calculate_order_totals para delivery service fee
-- (Ya maneja origins desconocidos con el fallback en _origin NOT IN ...)
-- Solo necesitamos actualizar _isServiceFeeActiveForOrigin en Flutter.
