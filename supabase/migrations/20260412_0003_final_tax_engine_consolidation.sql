-- =============================================================================
-- FINAL CONSOLIDATION: Tax engine, order totals, item insertion
--
-- This migration is the single source of truth for all tax-related DB functions.
-- It supersedes all previous definitions in:
--   20260408_0001, 20260409_0002, 20260410_0001, 20260412_0001
--
-- Functions updated:
--   1. fn_compute_item_totals          (trigger)
--   2. fn_resolve_order_item_tax_profile (RPC)
--   3. fn_add_item_from_menu           (RPC)
--   4. fn_update_item_tax_rate         (RPC)
--   5. calculate_order_totals          (RPC)
--   6. calculate_check_totals          (RPC)
--   7. fn_recalc_order_totals          (alias)
--
-- Also:
--   8. Recalculate all open orders with corrected totals
--   9. Ensure agent_url column exists
-- =============================================================================

-- ═══════════════════════════════════════════════════════════════════════════════
-- 1. fn_compute_item_totals — TRIGGER on order_items INSERT/UPDATE
--    For inclusive: extract base using original_tax_rate, apply tax using tax_rate
-- ═══════════════════════════════════════════════════════════════════════════════
CREATE OR REPLACE FUNCTION "public"."fn_compute_item_totals"() RETURNS "trigger"
LANGUAGE "plpgsql" AS $$
DECLARE
  mods_total numeric(12,2) := 0;
  v_line_amount numeric(12,2) := 0;
  v_tax_rate numeric := greatest(coalesce(new.tax_rate, 0), 0);
  v_tax_mode text := coalesce(new.tax_mode, 'exclusive');
  v_net_subtotal numeric(12,2) := 0;
  v_extract_rate numeric := 0;
BEGIN
  SELECT coalesce(sum(price * qty), 0)
    INTO mods_total
  FROM public.order_item_modifiers
  WHERE item_id = coalesce(new.id, old.id);

  v_line_amount := round(
    (coalesce(new.unit_price, 0) * coalesce(new.qty, new.quantity, 1)) + mods_total,
    2
  );

  IF v_tax_mode = 'inclusive' THEN
    -- Use original_tax_rate (full rate including service fee) to extract the base.
    -- If not set, fall back to tax_rate (backward compat with old items).
    v_extract_rate := greatest(coalesce(new.original_tax_rate, v_tax_rate), 0);

    IF v_extract_rate > 0 THEN
      v_net_subtotal := round(v_line_amount / (1 + (v_extract_rate / 100.0)), 2);
    ELSE
      v_net_subtotal := v_line_amount;
    END IF;

    new.subtotal := v_net_subtotal;

    IF v_tax_rate > 0 THEN
      new.tax := round(v_net_subtotal * (v_tax_rate / 100.0), 2);
    ELSE
      new.tax := 0;
    END IF;

    -- Total = base + applicable tax (NOT the menu price).
    -- When original_tax_rate = tax_rate, total ≈ line_amount.
    new.total := round(new.subtotal + new.tax - coalesce(new.discounts, 0), 2);
  ELSE
    -- Exclusive: taxes on top
    new.subtotal := v_line_amount;
    new.tax := round(new.subtotal * (v_tax_rate / 100.0), 2);
    new.total := round(new.subtotal - coalesce(new.discounts, 0) + coalesce(new.tax, 0), 2);
  END IF;

  RETURN new;
END;
$$;

-- ═══════════════════════════════════════════════════════════════════════════════
-- 2. fn_resolve_order_item_tax_profile
--    Returns tax_mode + tax_rate for a product in an order.
--    EXCLUDES service fee taxes (is_service_fee) — service fee is separate.
-- ═══════════════════════════════════════════════════════════════════════════════
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
  v_biz_id uuid;
  v_tax_mode text;
  v_tax_rate numeric;
BEGIN
  SELECT trim(lower(ts.origin::text)), ts.business_id
    INTO v_origin, v_biz_id
  FROM public.orders o
  JOIN public.table_sessions ts ON ts.id = o.session_id
  WHERE o.id = p_order_id;

  SELECT coalesce(mi.tax_mode, 'exclusive')
    INTO v_tax_mode
  FROM public.menu_items mi
  WHERE mi.id = p_product_id;

  -- Sum active taxes for this origin, EXCLUDING service fee
  SELECT coalesce(sum(t.rate), 0)::numeric
    INTO v_tax_rate
  FROM public.taxes t
  WHERE t.business_id = v_biz_id
    AND coalesce(t.is_active, true)
    AND coalesce(t.is_service_fee, false) = false
    AND (
      (v_origin IN ('dine_in','table','zone','table_order') AND t.apply_on_zone = true) OR
      (v_origin IN ('manual','manual_order') AND t.apply_on_manual = true) OR
      (v_origin IN ('quick','quick_sale','quick-sale') AND t.apply_on_quick = true) OR
      (v_origin = 'delivery' OR v_origin LIKE '%delivery%') AND t.apply_on_delivery = true OR
      (v_origin IS NULL OR v_origin NOT IN (
        'dine_in','table','zone','table_order',
        'manual','manual_order',
        'quick','quick_sale','quick-sale',
        'delivery'
      ))
    );

  -- Fallback to business default if no taxes configured at all
  IF v_tax_rate = 0 AND NOT EXISTS (
    SELECT 1 FROM public.taxes t2
    WHERE t2.business_id = v_biz_id AND coalesce(t2.is_active, true)
  ) THEN
    SELECT coalesce(bs.default_tax_rate, 0)::numeric
      INTO v_tax_rate
    FROM public.business_settings bs
    WHERE bs.business_id = v_biz_id;
  END IF;

  RETURN QUERY SELECT coalesce(v_tax_mode, 'exclusive'), coalesce(v_tax_rate, 0);
END;
$$;

-- ═══════════════════════════════════════════════════════════════════════════════
-- 3. fn_add_item_from_menu
--    Adds item to order with: tax_rate (filtered, no service fee),
--    original_tax_rate (ALL taxes including service fee), print_area_code.
-- ═══════════════════════════════════════════════════════════════════════════════
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
  v_full_tax_rate numeric := 0;
  v_print_area_code text;
  v_biz_id uuid;
  v_check uuid;
  v_item_id uuid;
  v_qty numeric(10,3);
BEGIN
  v_qty := greatest(coalesce(p_qty, 1), 1);

  -- Get product info including print area
  SELECT name, price, coalesce(print_area_code, 'kitchen_hot')
    INTO v_name, v_price, v_print_area_code
  FROM public.menu_items
  WHERE id = p_menu_item_id
  LIMIT 1;

  IF v_name IS NULL THEN
    RAISE EXCEPTION 'MENU_ITEM_NOT_FOUND';
  END IF;

  -- Resolve business ID
  SELECT ts.business_id INTO v_biz_id
  FROM public.orders o
  JOIN public.table_sessions ts ON ts.id = o.session_id
  WHERE o.id = p_order_id;

  -- Tax rate filtered by origin (EXCLUDES service fee)
  SELECT profile.tax_mode, profile.tax_rate
    INTO v_tax_mode, v_tax_rate
  FROM public.fn_resolve_order_item_tax_profile(p_menu_item_id, p_order_id) profile;

  -- Full tax rate: ALL active taxes INCLUDING service fee
  -- Used by fn_compute_item_totals to extract the base from inclusive prices
  SELECT coalesce(sum(t.rate), 0)::numeric
    INTO v_full_tax_rate
  FROM public.taxes t
  WHERE t.business_id = v_biz_id
    AND coalesce(t.is_active, true);

  IF v_full_tax_rate = 0 THEN
    v_full_tax_rate := v_tax_rate;
  END IF;

  v_check := public.fn_get_or_create_check(p_order_id, p_check_position);

  INSERT INTO public.order_items(
    order_id, check_id, product_id, product_name,
    qty, quantity, unit_price, tax_mode, tax_rate, original_tax_rate,
    is_takeout, notes, status, print_area_code
  ) VALUES (
    p_order_id, v_check, p_menu_item_id, v_name,
    v_qty, v_qty, v_price, coalesce(v_tax_mode, 'exclusive'),
    coalesce(v_tax_rate, 0), v_full_tax_rate,
    coalesce(p_is_takeout, false), p_notes, 'draft',
    v_print_area_code
  )
  RETURNING id INTO v_item_id;

  PERFORM public.fn_recalc_order_totals(p_order_id);
  RETURN v_item_id;
END;
$$;

-- ═══════════════════════════════════════════════════════════════════════════════
-- 4. fn_update_item_tax_rate — safe update bypassing RLS
-- ═══════════════════════════════════════════════════════════════════════════════
CREATE OR REPLACE FUNCTION "public"."fn_update_item_tax_rate"(
  "p_item_id" "uuid",
  "p_tax_rate" numeric,
  "p_original_tax_rate" numeric DEFAULT NULL
) RETURNS void
LANGUAGE "plpgsql"
SECURITY DEFINER
SET "search_path" TO 'public'
AS $$
BEGIN
  UPDATE public.order_items
  SET
    tax_rate = coalesce(p_tax_rate, tax_rate),
    original_tax_rate = coalesce(p_original_tax_rate, original_tax_rate)
  WHERE id = p_item_id;
END;
$$;

-- ═══════════════════════════════════════════════════════════════════════════════
-- 5. calculate_order_totals
--    Sums open items, applies service fee by origin, filters paid/void/closed
-- ═══════════════════════════════════════════════════════════════════════════════
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
  SELECT trim(lower(ts.origin::text)), ts.business_id
    INTO _origin, _biz_id
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

  -- Service fee config
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

  IF _sf_enabled THEN
    CASE
      WHEN _origin IN ('table','dine_in','zone','table_order') THEN _apply_sf := _sf_on_zone;
      WHEN _origin IN ('manual','manual_order') THEN _apply_sf := _sf_on_manual;
      WHEN _origin IN ('quick','quick_sale','quick-sale') THEN _apply_sf := _sf_on_quick;
      WHEN _origin = 'delivery' OR _origin LIKE '%delivery%' THEN _apply_sf := _sf_on_delivery;
      ELSE _apply_sf := true;
    END CASE;
  END IF;

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
    subtotal    = ROUND(_subtotal, 2),
    tax         = ROUND(_tax, 2),
    service_fee = ROUND(_service_fee, 2),
    discounts   = ROUND(_discounts, 2),
    total       = ROUND(_total, 2)
  WHERE id = _order_id;
END;
$$;

-- ═══════════════════════════════════════════════════════════════════════════════
-- 6. calculate_check_totals
-- ═══════════════════════════════════════════════════════════════════════════════
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
  SELECT
    COALESCE(SUM(subtotal), 0),
    COALESCE(SUM(tax), 0),
    COALESCE(SUM(discounts), 0)
  INTO _subtotal, _tax, _discounts
  FROM public.order_items
  WHERE check_id = _check_id
    AND status NOT IN ('void');

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

  IF _sf_enabled THEN
    CASE
      WHEN _origin IN ('table','dine_in','zone','table_order') THEN _apply_sf := _sf_on_zone;
      WHEN _origin IN ('manual','manual_order') THEN _apply_sf := _sf_on_manual;
      WHEN _origin IN ('quick','quick_sale','quick-sale') THEN _apply_sf := _sf_on_quick;
      WHEN _origin = 'delivery' OR _origin LIKE '%delivery%' THEN _apply_sf := _sf_on_delivery;
      ELSE _apply_sf := true;
    END CASE;
  END IF;

  IF _apply_sf THEN
    SELECT COALESCE(SUM(subtotal), 0) * (_sf_rate / 100.0)
    INTO _service_fee
    FROM public.order_items
    WHERE check_id = _check_id
      AND is_takeout = false
      AND status NOT IN ('void');
  END IF;

  _total := _subtotal + _tax + _service_fee - _discounts;

  UPDATE public.order_checks SET
    subtotal    = ROUND(_subtotal, 2),
    tax         = ROUND(_tax, 2),
    discounts   = ROUND(_discounts, 2),
    service_fee = ROUND(_service_fee, 2),
    total       = ROUND(_total, 2)
  WHERE id = _check_id;
END;
$$;

-- ═══════════════════════════════════════════════════════════════════════════════
-- 7. fn_recalc_order_totals — alias
-- ═══════════════════════════════════════════════════════════════════════════════
CREATE OR REPLACE FUNCTION "public"."fn_recalc_order_totals"("_order_id" "uuid")
RETURNS "void"
LANGUAGE "plpgsql" AS $$
BEGIN
  PERFORM public.calculate_order_totals(_order_id);
END;
$$;

-- ═══════════════════════════════════════════════════════════════════════════════
-- 8. Ensure columns exist
-- ═══════════════════════════════════════════════════════════════════════════════
ALTER TABLE public.order_items
  ADD COLUMN IF NOT EXISTS original_tax_rate numeric DEFAULT NULL;
ALTER TABLE public.order_items
  ADD COLUMN IF NOT EXISTS print_area_code text NOT NULL DEFAULT 'kitchen_hot';
ALTER TABLE public.menu_items
  ADD COLUMN IF NOT EXISTS print_area_code text NOT NULL DEFAULT 'kitchen_hot';
ALTER TABLE public.taxes
  ADD COLUMN IF NOT EXISTS is_service_fee boolean DEFAULT false;
ALTER TABLE public.taxes
  ADD COLUMN IF NOT EXISTS apply_on_zone boolean NOT NULL DEFAULT true;
ALTER TABLE public.taxes
  ADD COLUMN IF NOT EXISTS apply_on_manual boolean NOT NULL DEFAULT true;
ALTER TABLE public.taxes
  ADD COLUMN IF NOT EXISTS apply_on_quick boolean NOT NULL DEFAULT true;
ALTER TABLE public.taxes
  ADD COLUMN IF NOT EXISTS apply_on_delivery boolean NOT NULL DEFAULT true;
ALTER TABLE public.business_settings
  ADD COLUMN IF NOT EXISTS service_fee_on_zone boolean DEFAULT true;
ALTER TABLE public.business_settings
  ADD COLUMN IF NOT EXISTS service_fee_on_manual boolean DEFAULT true;
ALTER TABLE public.business_settings
  ADD COLUMN IF NOT EXISTS service_fee_on_quick boolean DEFAULT false;
ALTER TABLE public.business_settings
  ADD COLUMN IF NOT EXISTS service_fee_on_delivery boolean DEFAULT false;
ALTER TABLE public.business_settings
  ADD COLUMN IF NOT EXISTS agent_url text DEFAULT NULL;
ALTER TABLE public.cash_registers
  ADD COLUMN IF NOT EXISTS receipt_printer_id uuid REFERENCES public.printers(id) ON DELETE SET NULL;

-- ═══════════════════════════════════════════════════════════════════════════════
-- 9. Recalculate ALL open orders with corrected totals
--    This fixes any orders that were calculated with the buggy functions.
-- ═══════════════════════════════════════════════════════════════════════════════
DO $$
DECLARE
  r RECORD;
BEGIN
  -- Recalculate open orders
  FOR r IN
    SELECT o.id AS order_id
    FROM public.orders o
    JOIN public.table_sessions ts ON o.session_id = ts.id
    WHERE o.closed_at IS NULL
      AND o.status_ext NOT IN ('paid', 'void')
  LOOP
    PERFORM public.calculate_order_totals(r.order_id);
  END LOOP;

  -- Recalculate open checks
  FOR r IN
    SELECT ch.id AS check_id
    FROM public.order_checks ch
    JOIN public.orders o ON ch.order_id = o.id
    WHERE o.closed_at IS NULL
      AND ch.is_closed = false
  LOOP
    PERFORM public.calculate_check_totals(r.check_id);
  END LOOP;

  RAISE NOTICE 'All open orders and checks recalculated with corrected tax engine.';
END;
$$;
