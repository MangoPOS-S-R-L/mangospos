-- Ejecuta este script SQL en tu editor de Supabase (SQL Editor)

-- 1. Asegurarnos de que las mesas no cambien de dueño
-- Reemplazando `fn_open_table` para que NUNCA modifique el `waiter_user_id` de una sesión existente.
CREATE OR REPLACE FUNCTION public.fn_open_table(
  p_table_id uuid,
  p_user_id uuid,               -- Id del usuario que abrió originalmente
  p_people_count int default 1
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path=public
AS $$
DECLARE
  v_session_id uuid;
  v_order_id uuid;
BEGIN
  -- Si ya hay sesion abierta, reusarla sin actualizar waiter_user_id ni opened_by
  SELECT id INTO v_session_id
  FROM public.table_sessions
  WHERE table_id = p_table_id AND closed_at IS NULL
  ORDER BY opened_at DESC
  LIMIT 1;

  IF v_session_id IS NULL THEN
    INSERT INTO public.table_sessions(table_id, opened_by, origin, waiter_user_id, people_count)
    VALUES (p_table_id, p_user_id, 'dine_in', p_user_id, greatest(1, p_people_count))
    RETURNING id INTO v_session_id;
  END IF;

  -- Marcar la mesa como ocupada
  UPDATE public.dining_tables
  SET state = 'occupied'
  WHERE id = p_table_id;

  -- Orden activa (si no existe, crear una nueva)
  SELECT id INTO v_order_id
  FROM public.orders
  WHERE session_id = v_session_id
    AND closed_at IS NULL
    AND status_ext NOT IN ('paid', 'void')
  ORDER BY created_at DESC LIMIT 1;

  IF v_order_id IS NULL THEN
    INSERT INTO public.orders(session_id, status_ext, subtotal, discounts, tax, total, total_amount)
    VALUES (v_session_id, 'open', 0, 0, 0, 0, 0)
    RETURNING id INTO v_order_id;

    -- C1 por defecto
    INSERT INTO public.order_checks(order_id, label, position)
    VALUES (v_order_id, 'C1', 1);
  END IF;

  RETURN jsonb_build_object('session_id', v_session_id, 'order_id', v_order_id);
END $$;
GRANT EXECUTE ON FUNCTION public.fn_open_table(uuid, uuid, int) TO authenticated;

-- 2. Agregar columna invisible 'added_by' a order_items 
-- (para guardar quien agregó el producto si no fue el que abrió la mesa)
DO $$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM information_schema.columns WHERE table_schema='public' AND table_name='order_items' AND column_name='added_by') THEN
        ALTER TABLE public.order_items ADD COLUMN added_by uuid REFERENCES auth.users(id) ON DELETE SET NULL;
    END IF;
END $$;

-- 3. Actualizar fn_add_item_from_menu para que guarde `added_by` 
-- usando el usuario que hizo la acción (`auth.uid()`)
CREATE OR REPLACE FUNCTION public.fn_add_item_from_menu(
  p_order_id uuid,
  p_menu_item_id uuid,
  p_qty numeric default 1,
  p_check_position int default 1,
  p_is_takeout boolean default false,
  p_notes text default null
)
RETURNS uuid
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path=public
AS $$
DECLARE
  v_name text;
  v_price numeric(12,2);
  v_check uuid;
  v_item_id uuid;
  v_qty numeric(10,3);
BEGIN
  v_qty := greatest(coalesce(p_qty, 1), 1);

  SELECT name, price
    INTO v_name, v_price
  FROM public.menu_items
  WHERE id = p_menu_item_id
  LIMIT 1;

  IF v_name IS NULL THEN
    RAISE EXCEPTION 'MENU_ITEM_NOT_FOUND';
  END IF;

  v_check := public.fn_get_or_create_check(p_order_id, p_check_position);

  INSERT INTO public.order_items(
    order_id, check_id, product_id, product_name,
    qty, quantity, unit_price, is_takeout, notes, status, added_by
  ) VALUES (
    p_order_id, v_check, p_menu_item_id, v_name,
    v_qty, v_qty, v_price, coalesce(p_is_takeout, false), p_notes, 'draft', auth.uid()
  )
  RETURNING id INTO v_item_id;

  PERFORM public.fn_recalc_order_totals(p_order_id);
  RETURN v_item_id;
END;
$$;
GRANT EXECUTE ON FUNCTION public.fn_add_item_from_menu(uuid, uuid, numeric, int, boolean, text) TO authenticated;
