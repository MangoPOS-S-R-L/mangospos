-- =============================================================================
-- Fix: Tax resolution + order totals calculation
-- - fn_resolve_order_item_tax_profile: flexible origin matching, SECURITY DEFINER
-- - calculate_order_totals: filters paid/void items and closed checks,
--   propina only on dine-in (table/zone)
-- =============================================================================

-- 1. Tax resolution (flexible origin matching)
CREATE OR REPLACE FUNCTION "public"."fn_resolve_order_item_tax_profile"("p_product_id" "uuid", "p_order_id" "uuid")
RETURNS TABLE("tax_mode" "text", "tax_rate" numeric)
LANGUAGE "plpgsql" STABLE SECURITY DEFINER AS $$
DECLARE
  v_origin text;
  v_biz_id uuid;
  v_t_mode text;
BEGIN
  SELECT trim(lower(ts.origin::text)), ts.business_id INTO v_origin, v_biz_id
  FROM public.orders o
  JOIN public.table_sessions ts ON o.session_id = ts.id
  WHERE o.id = p_order_id;

  SELECT coalesce(mi.tax_mode, 'exclusive') INTO v_t_mode
  FROM public.menu_items mi WHERE mi.id = p_product_id;

  RETURN QUERY
  SELECT
    coalesce(v_t_mode, 'exclusive'),
    coalesce(sum(t.rate), 0)::numeric
  FROM public.taxes t
  WHERE t.business_id = v_biz_id
    AND coalesce(t.is_active, true)
    AND (
      ((v_origin = 'table' OR v_origin = 'dine_in' OR v_origin = 'zone') AND t.apply_on_zone = true) OR
      ((v_origin LIKE '%delivery%') AND t.apply_on_delivery = true) OR
      ((v_origin LIKE '%quick%') AND t.apply_on_quick = true) OR
      ((v_origin = 'manual') AND t.apply_on_manual = true) OR
      (v_origin NOT IN ('table','dine_in','zone','delivery','manual','quick','quick-sale','quick_sale')
       AND v_origin NOT LIKE '%delivery%' AND v_origin NOT LIKE '%quick%'
      )
    );
END;
$$;

-- 2. Order totals (filters paid/void + closed checks, propina only dine-in)
CREATE OR REPLACE FUNCTION "public"."calculate_order_totals"("_order_id" "uuid")
RETURNS "void" LANGUAGE "plpgsql" SECURITY DEFINER AS $$
DECLARE
  _subtotal numeric := 0;
  _tax numeric := 0;
  _discounts numeric := 0;
  _service_fee numeric := 0;
  _total numeric := 0;
  _origin text;
  _biz_id uuid;
  _sf_rate numeric := 10;
  _apply_sf boolean := false;
BEGIN
  SELECT trim(lower(ts.origin::text)), ts.business_id INTO _origin, _biz_id
  FROM public.orders o
  JOIN public.table_sessions ts ON o.session_id = ts.id
  WHERE o.id = _order_id;

  -- Sum only OPEN items (exclude paid/void and items in closed checks)
  SELECT
    COALESCE(SUM(oi.subtotal), 0),
    COALESCE(SUM(oi.tax), 0),
    COALESCE(SUM(oi.discounts), 0)
  INTO _subtotal, _tax, _discounts
  FROM public.order_items oi
  LEFT JOIN public.order_checks oc ON oi.check_id = oc.id
  WHERE oi.order_id = _order_id
    AND oi.status NOT IN ('paid', 'void')
    AND COALESCE(oc.is_closed, false) = false;

  -- Service fee rate from business settings
  SELECT COALESCE(service_fee_rate, 10) INTO _sf_rate
  FROM public.business_settings WHERE business_id = _biz_id;

  -- Propina only on dine-in (table/zone)
  IF _origin IN ('table', 'dine_in', 'zone') THEN
    _apply_sf := true;
  END IF;

  -- Service fee on open, non-takeout items only
  IF _apply_sf THEN
    SELECT COALESCE(SUM(oi.subtotal), 0) * (_sf_rate / 100.0)
    INTO _service_fee
    FROM public.order_items oi
    LEFT JOIN public.order_checks oc ON oi.check_id = oc.id
    WHERE oi.order_id = _order_id
      AND oi.is_takeout = false
      AND oi.status NOT IN ('paid', 'void')
      AND COALESCE(oc.is_closed, false) = false;
  END IF;

  _total := _subtotal + _tax + _service_fee - _discounts;

  UPDATE public.orders SET
    subtotal = ROUND(_subtotal, 2),
    tax = ROUND(_tax, 2),
    service_fee = ROUND(_service_fee, 2),
    discounts = ROUND(_discounts, 2),
    total = ROUND(_total, 2)
  WHERE id = _order_id;
END;
$$;

-- 3. Ensure alias works
CREATE OR REPLACE FUNCTION "public"."fn_recalc_order_totals"("_order_id" "uuid") RETURNS "void"
    LANGUAGE "plpgsql" AS $$
BEGIN
  PERFORM public.calculate_order_totals(_order_id);
END;
$$;
