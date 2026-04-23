-- Product-scoped taxes.
--
-- Taxes remain global definitions in public.taxes, but a sale item should only
-- charge non-service taxes that are linked to that menu item through
-- public.menu_item_taxes. Service fee stays global by sale origin because the
-- pricing engine treats it as an order-level charge.

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
  v_product_biz_id uuid;
  v_tax_mode text;
  v_tax_rate numeric := 0;
BEGIN
  SELECT trim(lower(ts.origin::text)), ts.business_id
    INTO v_origin, v_biz_id
  FROM public.orders o
  JOIN public.table_sessions ts ON ts.id = o.session_id
  WHERE o.id = p_order_id;

  SELECT coalesce(mi.tax_mode, 'exclusive'), mi.business_id
    INTO v_tax_mode, v_product_biz_id
  FROM public.menu_items mi
  WHERE mi.id = p_product_id;

  IF v_biz_id IS NULL OR v_product_biz_id IS DISTINCT FROM v_biz_id THEN
    RETURN QUERY SELECT coalesce(v_tax_mode, 'exclusive'), 0::numeric;
    RETURN;
  END IF;

  SELECT coalesce(sum(t.rate), 0)::numeric
    INTO v_tax_rate
  FROM public.menu_item_taxes mit
  JOIN public.taxes t ON t.id = mit.tax_id
  WHERE mit.item_id = p_product_id
    AND t.business_id = v_biz_id
    AND coalesce(t.is_active, true)
    AND coalesce(t.is_service_fee, false) = false
    AND (
      (v_origin IN ('dine_in','table','zone','table_order') AND t.apply_on_zone = true) OR
      (v_origin IN ('manual','manual_order') AND t.apply_on_manual = true) OR
      (v_origin IN ('quick','quick_sale','quick-sale') AND t.apply_on_quick = true) OR
      ((v_origin = 'delivery' OR v_origin LIKE '%delivery%') AND t.apply_on_delivery = true) OR
      (v_origin IS NULL OR v_origin NOT IN (
        'dine_in','table','zone','table_order',
        'manual','manual_order',
        'quick','quick_sale','quick-sale',
        'delivery'
      ))
    );

  RETURN QUERY SELECT coalesce(v_tax_mode, 'exclusive'), coalesce(v_tax_rate, 0);
END;
$$;

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
  v_product_full_tax_rate numeric := 0;
  v_service_fee_rate numeric := 0;
  v_full_tax_rate numeric := 0;
  v_print_area_code text;
  v_origin text;
  v_biz_id uuid;
  v_check uuid;
  v_item_id uuid;
  v_qty numeric(10,3);
BEGIN
  v_qty := greatest(coalesce(p_qty, 1), 1);

  SELECT name, price, coalesce(print_area_code, 'kitchen_hot')
    INTO v_name, v_price, v_print_area_code
  FROM public.menu_items
  WHERE id = p_menu_item_id
  LIMIT 1;

  IF v_name IS NULL THEN
    RAISE EXCEPTION 'MENU_ITEM_NOT_FOUND';
  END IF;

  SELECT trim(lower(ts.origin::text)), ts.business_id
    INTO v_origin, v_biz_id
  FROM public.orders o
  JOIN public.table_sessions ts ON ts.id = o.session_id
  WHERE o.id = p_order_id;

  SELECT profile.tax_mode, profile.tax_rate
    INTO v_tax_mode, v_tax_rate
  FROM public.fn_resolve_order_item_tax_profile(p_menu_item_id, p_order_id) profile;

  -- Full non-service tax rate assigned to this product. This is intentionally
  -- not origin-filtered so inclusive prices keep a stable base when an origin
  -- disables one of the product's taxes.
  SELECT coalesce(sum(t.rate), 0)::numeric
    INTO v_product_full_tax_rate
  FROM public.menu_item_taxes mit
  JOIN public.taxes t ON t.id = mit.tax_id
  WHERE mit.item_id = p_menu_item_id
    AND t.business_id = v_biz_id
    AND coalesce(t.is_active, true)
    AND coalesce(t.is_service_fee, false) = false;

  IF coalesce(p_is_takeout, false) = false THEN
    -- Service fee remains global by origin and is not required to be linked to
    -- every product.
    SELECT coalesce(max(t.rate), 0)::numeric
      INTO v_service_fee_rate
    FROM public.taxes t
    WHERE t.business_id = v_biz_id
      AND coalesce(t.is_active, true)
      AND coalesce(t.is_service_fee, false)
      AND (
        (v_origin IN ('dine_in','table','zone','table_order') AND t.apply_on_zone = true) OR
        (v_origin IN ('manual','manual_order') AND t.apply_on_manual = true) OR
        (v_origin IN ('quick','quick_sale','quick-sale') AND t.apply_on_quick = true) OR
        ((v_origin = 'delivery' OR v_origin LIKE '%delivery%') AND t.apply_on_delivery = true) OR
        (v_origin IS NULL OR v_origin NOT IN (
          'dine_in','table','zone','table_order',
          'manual','manual_order',
          'quick','quick_sale','quick-sale',
          'delivery'
        ))
      );

    IF coalesce(v_service_fee_rate, 0) = 0 THEN
      SELECT
        CASE
          WHEN coalesce(bs.service_fee_enabled, false) = false THEN 0
          WHEN v_origin IN ('dine_in','table','zone','table_order')
            AND coalesce(bs.service_fee_on_zone, true) THEN coalesce(bs.service_fee_rate, 10)
          WHEN v_origin IN ('manual','manual_order')
            AND coalesce(bs.service_fee_on_manual, true) THEN coalesce(bs.service_fee_rate, 10)
          WHEN v_origin IN ('quick','quick_sale','quick-sale')
            AND coalesce(bs.service_fee_on_quick, false) THEN coalesce(bs.service_fee_rate, 10)
          WHEN (v_origin = 'delivery' OR v_origin LIKE '%delivery%')
            AND coalesce(bs.service_fee_on_delivery, false) THEN coalesce(bs.service_fee_rate, 10)
          WHEN v_origin IS NULL OR v_origin NOT IN (
            'dine_in','table','zone','table_order',
            'manual','manual_order',
            'quick','quick_sale','quick-sale',
            'delivery'
          ) THEN coalesce(bs.service_fee_rate, 10)
          ELSE 0
        END
        INTO v_service_fee_rate
      FROM public.business_settings bs
      WHERE bs.business_id = v_biz_id;
    END IF;
  END IF;

  v_full_tax_rate := coalesce(v_product_full_tax_rate, 0) + coalesce(v_service_fee_rate, 0);
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
