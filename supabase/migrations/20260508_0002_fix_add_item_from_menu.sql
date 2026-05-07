-- =============================================================================
-- HOTFIX: 20260508_0001 sobrescribió fn_add_item_from_menu con una versión
-- vieja (de 20260409_0002) y perdió 2 cambios críticos del migration
-- 20260502_0001_tax_apply_on_takeout:
--   1. Llamada a fn_resolve_order_item_tax_profile con 3 args (incluye
--      p_is_takeout). La versión 2-args ya no existe en prod.
--   2. PERFORM fn_populate_item_tax_lines(v_item_id) post-insert.
--
-- Resultado del bug: cualquier intento de agregar un item desde el menu
-- (cashier flow) fallaba silenciosamente porque el RPC explotaba al
-- llamar el resolver con la signature equivocada.
--
-- Esta migration restaura la versión 20260502_0001 *manteniendo* el
-- pass-through del print_area_code (sin coalesce a 'kitchen_hot') que
-- introdujo 20260508_0001.
-- =============================================================================

CREATE OR REPLACE FUNCTION "public"."fn_add_item_from_menu"(
  "p_order_id" "uuid",
  "p_menu_item_id" "uuid",
  "p_qty" numeric DEFAULT 1,
  "p_check_position" integer DEFAULT 1,
  "p_is_takeout" boolean DEFAULT false,
  "p_notes" "text" DEFAULT NULL::"text"
) RETURNS "uuid"
LANGUAGE "plpgsql"
SECURITY DEFINER
SET "search_path" TO 'public'
AS $$
DECLARE
  v_name text;
  v_price numeric(12,2);
  v_tax_mode text;
  v_tax_rate numeric := 0;
  v_print_area_code text;
  v_check uuid;
  v_item_id uuid;
  v_qty numeric(10,3);
BEGIN
  v_qty := greatest(coalesce(p_qty, 1), 1);

  -- Pass-through del print_area_code (NULL si admin no eligió area).
  -- El cliente Dart valida en send-to-kitchen y bloquea con error claro.
  SELECT name, price, print_area_code
    INTO v_name, v_price, v_print_area_code
  FROM public.menu_items
  WHERE id = p_menu_item_id
  LIMIT 1;

  IF v_name IS NULL THEN
    RAISE EXCEPTION 'MENU_ITEM_NOT_FOUND';
  END IF;

  -- Resolución unificada: incluye service fees + regulares, filtrada por
  -- takeout per-tax (p_is_takeout). Esta es la signature 3-args
  -- introducida por 20260502_0001.
  SELECT profile.tax_mode, profile.tax_rate
    INTO v_tax_mode, v_tax_rate
  FROM public.fn_resolve_order_item_tax_profile(
    p_menu_item_id, p_order_id, coalesce(p_is_takeout, false)
  ) profile;

  v_check := public.fn_get_or_create_check(p_order_id, p_check_position);

  INSERT INTO public.order_items(
    order_id, check_id, product_id, product_name,
    qty, quantity, unit_price, tax_mode, tax_rate, original_tax_rate,
    is_takeout, notes, status, print_area_code
  ) VALUES (
    p_order_id, v_check, p_menu_item_id, v_name,
    v_qty, v_qty, v_price, coalesce(v_tax_mode, 'exclusive'),
    coalesce(v_tax_rate, 0), coalesce(v_tax_rate, 0),
    coalesce(p_is_takeout, false), p_notes, 'draft',
    v_print_area_code  -- Puede ser NULL: el cliente Dart valida.
  )
  RETURNING id INTO v_item_id;

  PERFORM public.fn_populate_item_tax_lines(v_item_id);
  PERFORM public.fn_recalc_order_totals(p_order_id);
  RETURN v_item_id;
END;
$$;

GRANT EXECUTE ON FUNCTION "public"."fn_add_item_from_menu"("uuid", "uuid", numeric, integer, boolean, "text") TO "anon";
GRANT EXECUTE ON FUNCTION "public"."fn_add_item_from_menu"("uuid", "uuid", numeric, integer, boolean, "text") TO "authenticated";
GRANT EXECUTE ON FUNCTION "public"."fn_add_item_from_menu"("uuid", "uuid", numeric, integer, boolean, "text") TO "service_role";
