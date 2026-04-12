-- =============================================================================
-- EMERGENCY RESTORE: Restores functions broken by manual "rescue" script.
-- The manual script dropped and recreated calculate_order_totals,
-- fn_recalc_order_totals, fn_resolve_order_item_tax_profile, and
-- fn_compute_item_totals with simplified versions that lost critical logic.
-- This migration restores the correct versions from 20260408_0001.
-- =============================================================================

-- 0. Ensure service_fee_on_delivery column exists
ALTER TABLE public.business_settings
  ADD COLUMN IF NOT EXISTS service_fee_on_delivery boolean DEFAULT false;

-- 1. Restore calculate_order_totals (excludes paid/void, closed checks, delivery toggle)
CREATE OR REPLACE FUNCTION "public"."calculate_order_totals"("_order_id" "uuid") RETURNS "void"
    LANGUAGE "plpgsql"
    AS $$
DECLARE
  _subtotal numeric;
  _tax numeric;
  _discounts numeric;
  _service_fee numeric := 0;
  _total numeric;
  _sf_enabled boolean;
  _sf_rate numeric;
  _origin text;
  _sf_on_zone boolean;
  _sf_on_manual boolean;
  _sf_on_quick boolean;
  _sf_on_delivery boolean;
  _apply_sf boolean := false;
BEGIN
  -- 1. Sum ONLY open items (exclude paid/void items and items in closed checks)
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

  -- 2. Get origin
  SELECT ts.origin::text
  INTO _origin
  FROM public.orders o
  JOIN public.table_sessions ts ON o.session_id = ts.id
  WHERE o.id = _order_id;

  -- 3. Business settings (separate query to survive missing row)
  SELECT
    COALESCE(bs.service_fee_enabled, true),
    COALESCE(bs.service_fee_rate, 10),
    COALESCE(bs.service_fee_on_zone, true),
    COALESCE(bs.service_fee_on_manual, true),
    COALESCE(bs.service_fee_on_quick, false),
    COALESCE(bs.service_fee_on_delivery, false)
  INTO _sf_enabled, _sf_rate, _sf_on_zone, _sf_on_manual, _sf_on_quick, _sf_on_delivery
  FROM public.orders o
  JOIN public.table_sessions ts ON o.session_id = ts.id
  JOIN public.business_settings bs ON ts.business_id = bs.business_id
  WHERE o.id = _order_id;

  -- If no business_settings row, use defaults
  IF _sf_enabled IS NULL THEN
    _sf_enabled := true;
    _sf_rate := 10;
    _sf_on_zone := true;
    _sf_on_manual := true;
    _sf_on_quick := false;
    _sf_on_delivery := false;
  END IF;

  -- 4. Determine if service fee applies for this origin
  IF _sf_enabled THEN
    IF _origin IN ('dine_in', 'table', 'zone', 'table_order') AND _sf_on_zone THEN _apply_sf := true;
    ELSIF _origin IN ('manual', 'manual_order') AND _sf_on_manual THEN _apply_sf := true;
    ELSIF _origin IN ('quick', 'quick_sale', 'quick-sale') AND _sf_on_quick THEN _apply_sf := true;
    ELSIF _origin IN ('delivery', 'delivery_order') AND _sf_on_delivery THEN _apply_sf := true;
    END IF;
  END IF;

  -- 5. Service fee only on open, non-takeout items
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

  UPDATE public.orders
  SET
    subtotal = _subtotal,
    tax = _tax,
    discounts = _discounts,
    service_fee = ROUND(_service_fee, 2),
    total = ROUND(_total, 2)
  WHERE id = _order_id;
END;
$$;

-- 2. Restore fn_recalc_order_totals as alias
CREATE OR REPLACE FUNCTION "public"."fn_recalc_order_totals"("_order_id" "uuid") RETURNS "void"
    LANGUAGE "plpgsql"
    AS $$
BEGIN
  PERFORM public.calculate_order_totals(_order_id);
END;
$$;

-- 3. Restore fn_resolve_order_item_tax_profile (with delivery support + area toggles)
CREATE OR REPLACE FUNCTION "public"."fn_resolve_order_item_tax_profile"("p_product_id" "uuid", "p_order_id" "uuid")
RETURNS TABLE("tax_mode" "text", "tax_rate" numeric)
LANGUAGE "plpgsql" STABLE
AS $$
DECLARE
  v_origin text;
  v_tax_mode text;
  v_tax_rate numeric;
BEGIN
  SELECT lower(ts.origin::text) INTO v_origin
  FROM public.orders o
  JOIN public.table_sessions ts ON o.session_id = ts.id
  WHERE o.id = p_order_id;

  SELECT coalesce(mi.tax_mode, 'exclusive') INTO v_tax_mode
  FROM public.menu_items mi
  WHERE mi.id = p_product_id;

  SELECT coalesce(sum(t.rate), 0)::numeric INTO v_tax_rate
  FROM public.taxes t
  WHERE t.business_id = (
    SELECT ts.business_id FROM public.orders o
    JOIN public.table_sessions ts ON ts.id = o.session_id
    WHERE o.id = p_order_id LIMIT 1
  )
    AND coalesce(t.is_active, true)
    AND (
      (v_origin IN ('dine_in', 'table', 'zone', 'table_order') AND t.apply_on_zone = true) OR
      (v_origin IN ('manual', 'manual_order') AND t.apply_on_manual = true) OR
      (v_origin IN ('quick', 'quick_sale', 'quick-sale') AND t.apply_on_quick = true) OR
      (v_origin IN ('delivery', 'delivery_order') AND t.apply_on_delivery = true) OR
      (v_origin IS NULL OR v_origin NOT IN ('dine_in','table','zone','table_order','manual','manual_order','quick','quick_sale','quick-sale','delivery','delivery_order'))
    );

  RETURN QUERY SELECT coalesce(v_tax_mode, 'exclusive'), coalesce(v_tax_rate, 0);
END;
$$;

-- 4. Restore fn_compute_item_totals trigger
CREATE OR REPLACE FUNCTION "public"."fn_compute_item_totals"() RETURNS "trigger"
    LANGUAGE "plpgsql"
    AS $$
declare
  mods_total numeric(12,2) := 0;
  v_line_amount numeric(12,2) := 0;
  v_tax_rate numeric := greatest(coalesce(new.tax_rate, 0), 0);
  v_tax_mode text := coalesce(new.tax_mode, 'exclusive');
  v_net_subtotal numeric(12,2) := 0;
  v_extract_rate numeric := 0;
begin
  select coalesce(sum(price*qty),0)
    into mods_total
  from public.order_item_modifiers
  where item_id = coalesce(new.id, old.id);

  v_line_amount := round(
    (coalesce(new.unit_price, 0) * coalesce(new.qty, new.quantity, 1)) +
    mods_total,
    2
  );

  if v_tax_mode = 'inclusive' then
    v_extract_rate := greatest(coalesce(new.original_tax_rate, v_tax_rate), 0);

    if v_extract_rate > 0 then
      v_net_subtotal := round(v_line_amount / (1 + (v_extract_rate / 100.0)), 2);
    else
      v_net_subtotal := v_line_amount;
    end if;

    new.subtotal := v_net_subtotal;

    if v_tax_rate > 0 then
      new.tax := round(v_net_subtotal * (v_tax_rate / 100.0), 2);
    else
      new.tax := 0;
    end if;

    new.total := round(new.subtotal + new.tax - coalesce(new.discounts, 0), 2);
  else
    new.subtotal := v_line_amount;
    new.tax := round(new.subtotal * (v_tax_rate / 100.0), 2);
    new.total := round(
      new.subtotal - coalesce(new.discounts,0) + coalesce(new.tax,0),
      2
    );
  end if;
  return new;
end $$;

-- 5. Ensure trigger exists
DROP TRIGGER IF EXISTS trg_compute_item_totals ON public.order_items;
CREATE TRIGGER trg_compute_item_totals
  BEFORE INSERT OR UPDATE ON public.order_items
  FOR EACH ROW EXECUTE FUNCTION public.fn_compute_item_totals();

-- 6. Restore fn_add_item_from_menu (with print_area_code support)
-- original_tax_rate = full rate (ITBIS + propina) used to extract base from inclusive price.
-- tax_rate = origin-filtered rate (just ITBIS for the tax line).
CREATE OR REPLACE FUNCTION "public"."fn_add_item_from_menu"(
  "p_order_id" "uuid",
  "p_menu_item_id" "uuid",
  "p_qty" numeric DEFAULT 1,
  "p_check_position" integer DEFAULT 1,
  "p_is_takeout" boolean DEFAULT false,
  "p_notes" "text" DEFAULT NULL::"text"
) RETURNS "uuid"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
declare
  v_name text;
  v_price numeric(12,2);
  v_tax_mode text;
  v_tax_rate numeric := 0;
  v_full_tax_rate numeric := 0;
  v_print_area_code text;
  v_check uuid;
  v_item_id uuid;
  v_qty numeric(10,3);
begin
  v_qty := greatest(coalesce(p_qty, 1), 1);

  select name, price, coalesce(print_area_code, 'kitchen_hot')
    into v_name, v_price, v_print_area_code
  from public.menu_items
  where id = p_menu_item_id
  limit 1;

  if v_name is null then
    raise exception 'MENU_ITEM_NOT_FOUND';
  end if;

  select profile.tax_mode, profile.tax_rate
    into v_tax_mode, v_tax_rate
  from public.fn_resolve_order_item_tax_profile(p_menu_item_id, p_order_id) profile;

  -- Full tax rate: ALL active taxes (ITBIS + propina) for inclusive price extraction
  select coalesce(sum(t.rate), 0)::numeric
    into v_full_tax_rate
  from public.taxes t
  where t.business_id = (
    select ts.business_id from public.orders o
    join public.table_sessions ts on ts.id = o.session_id
    where o.id = p_order_id limit 1
  )
    and coalesce(t.is_active, true);

  if v_full_tax_rate = 0 then
    v_full_tax_rate := v_tax_rate;
  end if;

  v_check := public.fn_get_or_create_check(p_order_id, p_check_position);

  insert into public.order_items(
    order_id, check_id, product_id, product_name,
    qty, quantity, unit_price, tax_mode, tax_rate, original_tax_rate,
    is_takeout, notes, status, print_area_code
  ) values (
    p_order_id, v_check, p_menu_item_id, v_name,
    v_qty, v_qty, v_price, coalesce(v_tax_mode, 'exclusive'),
    coalesce(v_tax_rate, 0), v_full_tax_rate,
    coalesce(p_is_takeout, false), p_notes, 'draft',
    v_print_area_code
  )
  returning id into v_item_id;

  perform public.fn_recalc_order_totals(p_order_id);
  return v_item_id;
end;
$$;
