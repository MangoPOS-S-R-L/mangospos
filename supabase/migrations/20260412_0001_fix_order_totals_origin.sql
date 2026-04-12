-- =============================================================================
-- Fix: calculate_order_totals + calculate_check_totals
--
-- Bugs fixed:
-- 1. Origin matching: 'table' and 'zone' origins were NOT matching 'dine_in',
--    so they fell through to the catch-all ELSE clause which ALWAYS applied
--    service fee, ignoring the sf_on_zone flag.
-- 2. Missing status filter: paid/void items and closed checks were included
--    in the totals sum, inflating order amounts.
-- 3. Missing SECURITY DEFINER: could fail due to RLS policies.
-- =============================================================================

-- ── 1. Fix calculate_order_totals ──────────────────────────────────────────────
CREATE OR REPLACE FUNCTION "public"."calculate_order_totals"("_order_id" "uuid")
RETURNS "void"
LANGUAGE "plpgsql"
SECURITY DEFINER
SET "search_path" TO 'public'
AS $$
DECLARE
  _subtotal numeric := 0;
  _tax numeric := 0;
  _discounts numeric := 0;
  _service_fee numeric := 0;
  _total numeric := 0;
  _origin text;
  _biz_id uuid;
  _sf_enabled boolean := false;
  _sf_rate numeric := 10;
  _sf_on_zone boolean := true;
  _sf_on_manual boolean := true;
  _sf_on_quick boolean := false;
  _sf_on_delivery boolean := false;
  _apply_sf boolean := false;
BEGIN
  -- 1. Get origin and business
  SELECT trim(lower(ts.origin::text)), ts.business_id
    INTO _origin, _biz_id
  FROM public.orders o
  JOIN public.table_sessions ts ON o.session_id = ts.id
  WHERE o.id = _order_id;

  -- 2. Sum only OPEN items (exclude paid/void and items in closed checks)
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

  -- 3. Get service fee config
  SELECT
    COALESCE(bs.service_fee_enabled, false),
    COALESCE(bs.service_fee_rate, 10),
    COALESCE(bs.service_fee_on_zone, true),
    COALESCE(bs.service_fee_on_manual, true),
    COALESCE(bs.service_fee_on_quick, false),
    COALESCE(bs.service_fee_on_delivery, false)
  INTO _sf_enabled, _sf_rate, _sf_on_zone, _sf_on_manual, _sf_on_quick, _sf_on_delivery
  FROM public.business_settings bs
  WHERE bs.business_id = _biz_id;

  -- 4. Determine if service fee applies for this origin
  IF _sf_enabled THEN
    CASE
      WHEN _origin IN ('table', 'dine_in', 'zone', 'table_order') THEN
        _apply_sf := _sf_on_zone;
      WHEN _origin IN ('manual', 'manual_order') THEN
        _apply_sf := _sf_on_manual;
      WHEN _origin IN ('quick', 'quick_sale', 'quick-sale') THEN
        _apply_sf := _sf_on_quick;
      WHEN _origin = 'delivery' OR _origin LIKE '%delivery%' THEN
        _apply_sf := _sf_on_delivery;
      ELSE
        -- Unknown origin: apply by default
        _apply_sf := true;
    END CASE;
  END IF;

  -- 5. Calculate service fee on open, non-takeout items only
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

  -- 6. Update order
  UPDATE public.orders SET
    subtotal = ROUND(_subtotal, 2),
    tax      = ROUND(_tax, 2),
    service_fee = ROUND(_service_fee, 2),
    discounts = ROUND(_discounts, 2),
    total    = ROUND(_total, 2)
  WHERE id = _order_id;
END;
$$;

-- ── 2. Fix calculate_check_totals ──────────────────────────────────────────────
CREATE OR REPLACE FUNCTION "public"."calculate_check_totals"("_check_id" "uuid")
RETURNS "void"
LANGUAGE "plpgsql"
SECURITY DEFINER
SET "search_path" TO 'public'
AS $$
DECLARE
  _subtotal numeric := 0;
  _tax numeric := 0;
  _discounts numeric := 0;
  _service_fee numeric := 0;
  _total numeric := 0;
  _origin text;
  _biz_id uuid;
  _sf_enabled boolean := false;
  _sf_rate numeric := 10;
  _sf_on_zone boolean := true;
  _sf_on_manual boolean := true;
  _sf_on_quick boolean := false;
  _sf_on_delivery boolean := false;
  _apply_sf boolean := false;
BEGIN
  -- 1. Sum check items
  SELECT
    COALESCE(SUM(subtotal), 0),
    COALESCE(SUM(tax), 0),
    COALESCE(SUM(discounts), 0)
  INTO _subtotal, _tax, _discounts
  FROM public.order_items
  WHERE check_id = _check_id
    AND status NOT IN ('void');

  -- 2. Get origin and service fee config
  SELECT
    trim(lower(ts.origin::text)),
    ts.business_id,
    COALESCE(bs.service_fee_enabled, false),
    COALESCE(bs.service_fee_rate, 10),
    COALESCE(bs.service_fee_on_zone, true),
    COALESCE(bs.service_fee_on_manual, true),
    COALESCE(bs.service_fee_on_quick, false),
    COALESCE(bs.service_fee_on_delivery, false)
  INTO _origin, _biz_id, _sf_enabled, _sf_rate, _sf_on_zone, _sf_on_manual, _sf_on_quick, _sf_on_delivery
  FROM public.order_checks ch
  JOIN public.orders o ON ch.order_id = o.id
  JOIN public.table_sessions ts ON o.session_id = ts.id
  JOIN public.business_settings bs ON ts.business_id = bs.business_id
  WHERE ch.id = _check_id;

  -- 3. Determine if service fee applies
  IF _sf_enabled THEN
    CASE
      WHEN _origin IN ('table', 'dine_in', 'zone', 'table_order') THEN
        _apply_sf := _sf_on_zone;
      WHEN _origin IN ('manual', 'manual_order') THEN
        _apply_sf := _sf_on_manual;
      WHEN _origin IN ('quick', 'quick_sale', 'quick-sale') THEN
        _apply_sf := _sf_on_quick;
      WHEN _origin = 'delivery' OR _origin LIKE '%delivery%' THEN
        _apply_sf := _sf_on_delivery;
      ELSE
        _apply_sf := true;
    END CASE;
  END IF;

  -- 4. Calculate service fee
  IF _apply_sf THEN
    SELECT COALESCE(SUM(subtotal), 0) * (_sf_rate / 100.0)
    INTO _service_fee
    FROM public.order_items
    WHERE check_id = _check_id
      AND is_takeout = false
      AND status NOT IN ('void');
  END IF;

  _total := _subtotal + _tax + _service_fee - _discounts;

  -- 5. Update check
  UPDATE public.order_checks SET
    subtotal    = ROUND(_subtotal, 2),
    tax         = ROUND(_tax, 2),
    discounts   = ROUND(_discounts, 2),
    service_fee = ROUND(_service_fee, 2),
    total       = ROUND(_total, 2)
  WHERE id = _check_id;
END;
$$;

-- ── 3. Ensure fn_resolve_order_item_tax_profile has SECURITY DEFINER ───────────
CREATE OR REPLACE FUNCTION "public"."fn_resolve_order_item_tax_profile"(
  "p_product_id" "uuid",
  "p_order_id" "uuid"
)
RETURNS TABLE("tax_mode" "text", "tax_rate" numeric)
LANGUAGE "plpgsql"
STABLE
SECURITY DEFINER
SET "search_path" TO 'public'
AS $$
DECLARE
  v_origin text;
  v_tax_mode text;
  v_tax_rate numeric;
BEGIN
  -- 1. Get order origin
  SELECT trim(lower(ts.origin::text)) INTO v_origin
  FROM public.orders o
  JOIN public.table_sessions ts ON ts.id = o.session_id
  WHERE o.id = p_order_id;

  -- 2. Get product tax mode
  SELECT coalesce(mi.tax_mode, 'exclusive') INTO v_tax_mode
  FROM public.menu_items mi
  WHERE mi.id = p_product_id;

  -- 3. Sum all active business taxes that apply to this origin
  --    Exclude service fee taxes (is_service_fee = true) because service fee
  --    is calculated separately in calculate_order_totals.
  SELECT coalesce(sum(t.rate), 0)::numeric INTO v_tax_rate
  FROM public.taxes t
  WHERE t.business_id = (
    SELECT ts.business_id FROM public.orders o
    JOIN public.table_sessions ts ON ts.id = o.session_id
    WHERE o.id = p_order_id LIMIT 1
  )
    AND coalesce(t.is_active, true)
    AND coalesce(t.is_service_fee, false) = false
    AND (
      (v_origin IN ('dine_in', 'table', 'zone', 'table_order') AND t.apply_on_zone = true) OR
      (v_origin IN ('manual', 'manual_order') AND t.apply_on_manual = true) OR
      (v_origin IN ('quick', 'quick_sale', 'quick-sale') AND t.apply_on_quick = true) OR
      (v_origin = 'delivery' AND t.apply_on_delivery = true) OR
      (v_origin IS NULL OR v_origin NOT IN (
        'dine_in','table','zone','table_order',
        'manual','manual_order',
        'quick','quick_sale','quick-sale',
        'delivery'
      ))
    );

  -- 4. Fallback to business default if no taxes configured
  IF v_tax_rate = 0 AND NOT EXISTS (
    SELECT 1 FROM public.taxes t2
    WHERE t2.business_id = (
      SELECT ts2.business_id FROM public.orders o2
      JOIN public.table_sessions ts2 ON ts2.id = o2.session_id
      WHERE o2.id = p_order_id LIMIT 1
    ) AND coalesce(t2.is_active, true)
  ) THEN
    SELECT coalesce(bs.default_tax_rate, 0)::numeric INTO v_tax_rate
    FROM public.orders o
    JOIN public.table_sessions ts ON ts.id = o.session_id
    LEFT JOIN public.business_settings bs ON bs.business_id = ts.business_id
    WHERE o.id = p_order_id;
  END IF;

  RETURN QUERY SELECT coalesce(v_tax_mode, 'exclusive'), coalesce(v_tax_rate, 0);
END;
$$;
