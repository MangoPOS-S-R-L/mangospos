-- 🥭 MangoPOS - Unified Sales Operations (Backend Speed & Precision)

-- 1. Actualizar calculate_order_totals para separar Propina de Ley de ITBIS
CREATE OR REPLACE FUNCTION "public"."calculate_order_totals"("_order_id" "uuid") RETURNS "void"
    LANGUAGE "plpgsql"
    AS $$
DECLARE
  _subtotal numeric;
  _total_tax numeric; -- Suma de todas las cargas (ITBIS + Propina)
  _discounts numeric;
  _service_fee numeric := 0;
  _final_tax numeric := 0;
  _total numeric;
  _service_rate numeric;
  _total_tax_rate numeric;
  _business_id uuid;
  _origin text;
BEGIN
    -- Obtener negocio y origen de la orden
    SELECT ts.business_id, ts.origin INTO _business_id, _origin
    FROM public.orders o
    JOIN public.table_sessions ts ON o.session_id = ts.id
    WHERE o.id = _order_id;

    -- Obtener tasas activas para este origen
    -- Usamos la misma lógica que fn_resolve_order_item_tax_profile para consistencia
    SELECT 
        COALESCE(SUM(CASE WHEN is_service_fee = true THEN rate ELSE 0 END), 0),
        COALESCE(SUM(rate), 0)
    INTO _service_rate, _total_tax_rate
    FROM public.taxes
    WHERE business_id = _business_id 
      AND is_active = true
      AND (
        (_origin = 'dine_in' AND apply_on_zone = true) OR
        (_origin = 'quick_sale' AND apply_on_quick = true) OR
        (_origin = 'delivery' AND apply_on_delivery = true) OR
        (_origin = 'manual' AND apply_on_manual = true)
      );

    -- Sumar totales de items
    SELECT 
        COALESCE(SUM(subtotal), 0),
        COALESCE(SUM(tax), 0),
        COALESCE(SUM(discounts), 0),
        COALESCE(SUM(total), 0)
    INTO _subtotal, _total_tax, _discounts, _total
    FROM public.order_items
    WHERE order_id = _order_id AND status <> 'void';

    -- Si hay tasa de servicio configurada, extraerla del total de tax
    IF _total_tax_rate > 0 AND _service_rate > 0 THEN
        _service_fee := round(_total_tax * (_service_rate / _total_tax_rate), 2);
        _final_tax := _total_tax - _service_fee;
    ELSE
        _final_tax := _total_tax;
        _service_fee := 0;
    END IF;

    UPDATE public.orders
    SET 
        subtotal = round(_subtotal, 2),
        tax = round(_final_tax, 2),
        service_fee = round(_service_fee, 2),
        discounts = round(_discounts, 2),
        total = round(_total, 2)
    WHERE id = _order_id;
END;
$$;

-- 2. Mejorar fn_get_order_bundle para incluir la nota de sesión
CREATE OR REPLACE FUNCTION "public"."fn_get_order_bundle"("p_order_id" "uuid") RETURNS "jsonb"
    LANGUAGE "plpgsql"
    AS $$
DECLARE
    v_order jsonb;
    v_items jsonb;
    v_checks jsonb;
    v_session_id uuid;
    v_customer_id uuid;
    v_customer_name text;
    v_note text;
BEGIN
    -- Obtener la orden básica
    SELECT to_jsonb(o.*) INTO v_order FROM public.orders o WHERE id = p_order_id;
    v_session_id := (v_order->>'session_id')::uuid;

    -- Obtener info de sesión
    SELECT customer_id, customer_name, note 
    INTO v_customer_id, v_customer_name, v_note
    FROM public.table_sessions 
    WHERE id = v_session_id;

    -- Obtener items y checks
    SELECT jsonb_agg(to_jsonb(oi.*)) INTO v_items FROM public.order_items oi WHERE order_id = p_order_id;
    SELECT jsonb_agg(to_jsonb(oc.*)) INTO v_checks FROM public.order_checks oc WHERE order_id = p_order_id;

    RETURN jsonb_build_object(
        'order', v_order,
        'items', COALESCE(v_items, '[]'::jsonb),
        'checks', COALESCE(v_checks, '[]'::jsonb),
        'customer_id', v_customer_id,
        'customer_name', v_customer_name,
        'note', v_note
    );
END;
$$;

-- 3. Crear RPC unificado para agregar item y obtener bundle (Ahorra 4 llamadas al servidor)
CREATE OR REPLACE FUNCTION "public"."fn_add_item_and_get_bundle"(
    "p_order_id" "uuid",
    "p_menu_item_id" "uuid",
    "p_qty" numeric DEFAULT 1,
    "p_check_position" integer DEFAULT 1,
    "p_is_takeout" boolean DEFAULT false,
    "p_notes" text DEFAULT NULL
) RETURNS "jsonb"
    LANGUAGE "plpgsql"
    AS $$
DECLARE
    v_item_id uuid;
    v_result jsonb;
BEGIN
    -- 1. Agregar el item
    SELECT public.fn_add_item_from_menu(
        p_order_id, 
        p_menu_item_id, 
        p_qty, 
        p_check_position, 
        p_is_takeout, 
        p_notes
    ) INTO v_item_id;

    -- 2. Recalcular totales
    PERFORM public.calculate_order_totals(p_order_id);

    -- 3. Generar el bundle completo
    SELECT public.fn_get_order_bundle(p_order_id) INTO v_result;

    RETURN v_result;
END;
$$;
