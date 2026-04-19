-- 1. Identify and fix service fee taxes that are not correctly marked
-- Many discrepancies (like 677 vs 628) happen when a tax row for 'Propina Ley'
-- is NOT marked as is_service_fee=true, causing it to be double-counted 
-- (once as an item tax and again as an order-level service_fee).
UPDATE public.taxes 
SET is_service_fee = true 
WHERE (name ILIKE '%propina%' OR name ILIKE '%ley%' OR name ILIKE '%service%')
  AND is_service_fee = false;

-- 2. Hardening: fn_resolve_order_item_tax_profile
-- This function MUST return the non-service-fee rate for item taxes.
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
  -- 1. Get order origin and business
  SELECT trim(lower(ts.origin::text)), ts.business_id
    INTO v_origin, v_biz_id
  FROM public.orders o
  JOIN public.table_sessions ts ON ts.id = o.session_id
  WHERE o.id = p_order_id;

  -- 2. Get product tax mode
  SELECT coalesce(mi.tax_mode, 'exclusive')
    INTO v_tax_mode
  FROM public.menu_items mi
  WHERE mi.id = p_product_id;

  -- 3. Sum active taxes for this origin, STRICTLY EXCLUDING service fee
  -- We exclude is_service_fee=true because service fee is calculated 
  -- at the order level by calculate_order_totals.
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

  -- 4. Fallback: If NO non-service-fee taxes are found at all, use business default
  -- (Assuming default_tax_rate is ITBIS 18%)
  IF v_tax_rate = 0 AND NOT EXISTS (
    SELECT 1 FROM public.taxes t2
    WHERE t2.business_id = v_biz_id 
      AND coalesce(t2.is_active, true)
      AND coalesce(t2.is_service_fee, false) = false
  ) THEN
    SELECT coalesce(bs.default_tax_rate, 0)::numeric
      INTO v_tax_rate
    FROM public.business_settings bs
    WHERE bs.business_id = v_biz_id;
  END IF;

  RETURN QUERY SELECT coalesce(v_tax_mode, 'exclusive'), coalesce(v_tax_rate, 0);
END;
$$;

-- 3. Hardening: calculate_order_totals
-- Ensure it strictly follows: total = subtotal + tax + service_fee.
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

  -- 2. Aggregate subtotals by tax rate to prevent rounding drift
  -- (Instead of rounding per item, we round the sum of taxes for each rate)
  SELECT
    COALESCE(SUM(oi.subtotal), 0),
    COALESCE(SUM(oi.discounts), 0)
  INTO _subtotal, _discounts
  FROM public.order_items oi
  LEFT JOIN public.order_checks oc ON oi.check_id = oc.id
  WHERE oi.order_id = _order_id
    AND oi.status NOT IN ('paid', 'void')
    AND COALESCE(oc.is_closed, false) = false;

  -- Calculate ITBIS by aggregating subtotals per rate
  SELECT COALESCE(SUM(ROUND(rate_sum * (tax_rate / 100.0), 2)), 0)
  INTO _tax
  FROM (
    SELECT tax_rate, SUM(oi.subtotal) as rate_sum
    FROM public.order_items oi
    LEFT JOIN public.order_checks oc ON oi.check_id = oc.id
    WHERE oi.order_id = _order_id
      AND oi.status NOT IN ('paid', 'void')
      AND COALESCE(oc.is_closed, false) = false
    GROUP BY tax_rate
  ) groups;

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

  -- 4. Determine if service fee applies
  IF _sf_enabled THEN
    CASE
      WHEN _origin IN ('table','dine_in','zone','table_order') THEN _apply_sf := _sf_on_zone;
      WHEN _origin IN ('manual','manual_order') THEN _apply_sf := _sf_on_manual;
      WHEN _origin IN ('quick','quick_sale','quick-sale') THEN _apply_sf := _sf_on_quick;
      WHEN _origin = 'delivery' OR _origin LIKE '%delivery%' THEN _apply_sf := _sf_on_delivery;
      ELSE _apply_sf := true;
    END CASE;
  END IF;

  -- 5. Calculate service fee
  IF _apply_sf THEN
    -- It must be calculated on the subtotal. 
    -- If it's inclusive, subtotal is already base. If exclusive, it's also base.
    SELECT COALESCE(SUM(oi.subtotal), 0) * (_sf_rate / 100.0)
    INTO _service_fee
    FROM public.order_items oi
    LEFT JOIN public.order_checks oc ON oi.check_id = oc.id
    WHERE oi.order_id = _order_id
      AND oi.is_takeout = false
      AND oi.status NOT IN ('paid', 'void')
      AND COALESCE(oc.is_closed, false) = false;
  END IF;

  -- 6. Final Total Calculation
  _total := _subtotal + _tax + _service_fee - _discounts;

  -- 7. Update order
  UPDATE public.orders SET
    subtotal    = ROUND(_subtotal, 2),
    tax         = ROUND(_tax, 2),
    service_fee = ROUND(_service_fee, 2),
    discounts   = ROUND(_discounts, 2),
    total       = ROUND(_total, 2)
  WHERE id = _order_id;
END;
$$;

-- 4. Aggregate-then-Tax logic for calculate_check_totals
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
  -- 1. Aggregated subtotal and discounts
  SELECT
    COALESCE(SUM(subtotal), 0),
    COALESCE(SUM(discounts), 0)
  INTO _subtotal, _discounts
  FROM public.order_items
  WHERE check_id = _check_id
    AND status NOT IN ('void');

  -- 2. Aggregated tax by rate
  SELECT COALESCE(SUM(ROUND(rate_sum * (tax_rate / 100.0), 2)), 0)
  INTO _tax
  FROM (
    SELECT tax_rate, SUM(oi.subtotal) as rate_sum
    FROM public.order_items oi
    WHERE oi.check_id = _check_id
      AND oi.status NOT IN ('void')
    GROUP BY tax_rate
  ) groups;

  -- 3. Get origin and service fee config
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

  -- 4. Determine if service fee applies
  IF _sf_enabled THEN
    CASE
      WHEN _origin IN ('table','dine_in','zone','table_order') THEN _apply_sf := _sf_on_zone;
      WHEN _origin IN ('manual','manual_order') THEN _apply_sf := _sf_on_manual;
      WHEN _origin IN ('quick','quick_sale','quick-sale') THEN _apply_sf := _sf_on_quick;
      WHEN _origin = 'delivery' OR _origin LIKE '%delivery%' THEN _apply_sf := _sf_on_delivery;
      ELSE _apply_sf := true;
    END CASE;
  END IF;

  -- 5. Calculate service fee
  IF _apply_sf THEN
    SELECT COALESCE(SUM(subtotal), 0) * (_sf_rate / 100.0)
    INTO _service_fee
    FROM public.order_items
    WHERE check_id = _check_id
      AND is_takeout = false
      AND status NOT IN ('void');
  END IF;

  _total := _subtotal + _tax + _service_fee - _discounts;

  -- 6. Update check
  UPDATE public.order_checks SET
    subtotal    = ROUND(_subtotal, 2),
    tax         = ROUND(_tax, 2),
    discounts   = ROUND(_discounts, 2),
    service_fee = ROUND(_service_fee, 2),
    total       = ROUND(_total, 2)
  WHERE id = _check_id;
END;
$$;

-- 5. Hardening: fn_compute_item_totals with high internal precision
CREATE OR REPLACE FUNCTION "public"."fn_compute_item_totals"()
RETURNS trigger AS $$
DECLARE
  v_line_amount numeric;
  v_mod_total numeric := 0;
  v_extract_rate numeric := 0;
  v_tax_rate numeric := 0;
  v_net_subtotal numeric;
BEGIN
  v_tax_rate := coalesce(new.tax_rate, 0);
  
  -- Modifiers
  SELECT coalesce(SUM(qty * price), 0) INTO v_mod_total
  FROM public.order_item_modifiers
  WHERE item_id = new.id;

  v_line_amount := (new.qty * new.unit_price) + v_mod_total;

  IF new.tax_mode = 'inclusive' THEN
    -- In inclusive mode, we extract the base using high precision
    v_extract_rate := v_tax_rate;
    v_net_subtotal := v_line_amount / (1 + (v_extract_rate / 100.0));
    new.subtotal := v_net_subtotal - new.discounts;
    new.tax := new.subtotal * (v_tax_rate / 100.0);
  ELSE
    new.subtotal := v_line_amount - new.discounts;
    new.tax := new.subtotal * (v_tax_rate / 100.0);
  END IF;

  new.total := new.subtotal + new.tax;
  
  RETURN new;
END;
$$ LANGUAGE plpgsql;

CREATE OR REPLACE TRIGGER tr_compute_item_totals
BEFORE INSERT OR UPDATE ON public.order_items
FOR EACH ROW EXECUTE FUNCTION public.fn_compute_item_totals();

-- 5. Increase precision of order_items.qty and update split logic
-- We must drop all dependent views first
DROP VIEW IF EXISTS public.kds_active_items CASCADE;
DROP VIEW IF EXISTS public.v_kitchen_items CASCADE;
DROP VIEW IF EXISTS public.v_order_detail CASCADE;

-- Drop the generated column total because it blocks altering quantity
ALTER TABLE public.order_items DROP COLUMN IF EXISTS total;

-- Now alter the types
ALTER TABLE public.order_items ALTER COLUMN qty TYPE numeric(12,5);
ALTER TABLE public.order_items ALTER COLUMN quantity TYPE numeric(12,5);
ALTER TABLE public.order_items ALTER COLUMN subtotal TYPE numeric(20,4);
ALTER TABLE public.order_items ALTER COLUMN tax TYPE numeric(20,4);
ALTER TABLE public.order_items ALTER COLUMN discounts TYPE numeric(20,4);

-- Re-add total as a regular column with high precision
ALTER TABLE public.order_items ADD COLUMN total numeric(20,4) DEFAULT 0;

-- Re-create kds_active_items
CREATE OR REPLACE VIEW public.kds_active_items AS
SELECT
  oi.id,
  oi.order_id,
  LEFT(oi.order_id::text, 8) AS order_number,
  oi.product_name,
  COALESCE(oi.quantity, oi.qty, 1) AS quantity,
  oi.notes,
  oi.status,
  oi.created_at,
  oi.started_at,
  oi.ready_at,
  CASE
    WHEN dt.id IS NOT NULL THEN COALESCE(dt.label, dt.code, 'Mesa')
    WHEN ts.origin = 'manual' THEN 'Venta manual'
    WHEN ts.origin = 'quick' THEN 'Venta rapida'
    ELSE 'Venta'
  END AS table_name,
  p.full_name AS waiter_name,
  ts.business_id,
  NULL::text AS area_code,
  COALESCE(mods.modifiers, '[]'::json) AS modifiers
FROM public.order_items oi
JOIN public.orders o ON o.id = oi.order_id
JOIN public.table_sessions ts ON ts.id = o.session_id
LEFT JOIN public.dining_tables dt ON dt.id = ts.table_id
LEFT JOIN public.zones z ON z.id = dt.zone_id
LEFT JOIN public.profiles p ON p.id = ts.waiter_user_id
LEFT JOIN LATERAL (
  SELECT JSON_AGG(
    JSON_BUILD_OBJECT(
      'id', m.id,
      'name', m.name,
      'quantity', m.qty
    )
  ) AS modifiers
  FROM public.order_item_modifiers m
  WHERE m.item_id = oi.id
) mods ON TRUE
WHERE oi.status IN ('pending', 'preparing', 'ready');

-- Re-create v_kitchen_items
CREATE OR REPLACE VIEW public.v_kitchen_items AS
 SELECT oi.id,
    oi.order_id,
    oi.product_id,
    mi.name AS product_name,
    oi.qty,
    oi.status,
    oi.notes,
    oi.created_at,
    COALESCE(z.business_id, mi.business_id) AS business_id,
    dt.label AS table_name,
    z.name AS zone_name
   FROM (((((public.order_items oi
     JOIN public.orders o ON ((oi.order_id = o.id)))
     LEFT JOIN public.menu_items mi ON ((oi.product_id = mi.id)))
     LEFT JOIN public.table_sessions ts ON ((o.session_id = ts.id)))
     LEFT JOIN public.dining_tables dt ON ((ts.table_id = dt.id)))
     LEFT JOIN public.zones z ON ((dt.zone_id = z.id)));

-- Re-create v_order_detail
CREATE OR REPLACE VIEW public.v_order_detail WITH (security_invoker='on') AS
 SELECT o.id AS order_id,
    oc.id AS check_id,
    oc."position" AS check_pos,
    oc.label AS check_label,
    oi.id AS item_id,
    oi.product_id,
    oi.product_name,
    oi.qty,
    oi.unit_price,
    oi.is_takeout,
    oi.status,
    oi.notes,
    oi.subtotal,
    oi.discounts,
    oi.tax,
    oi.total,
    o.subtotal AS order_subtotal,
    o.discounts AS order_discounts,
    o.tax AS order_tax,
    o.total AS order_total,
    o.status_ext
   FROM ((public.orders o
     LEFT JOIN public.order_checks oc ON ((oc.order_id = o.id)))
     LEFT JOIN public.order_items oi ON (((oi.order_id = o.id) AND (oi.check_id = oc.id))));

CREATE OR REPLACE FUNCTION public.fn_split_items_equally(
  p_order_id uuid,
  p_people integer
)
returns setof public.order_checks
language plpgsql
security definer
set search_path=public
as $$
declare
  v_people integer := coalesce(p_people, 0);
  v_idx integer;
  v_pos integer;
  v_item record;
  v_target_check_ids uuid[] := array[]::uuid[];
  v_item_qty numeric(12,5);
  v_item_discounts numeric(12,2);
  v_qty_base numeric(12,5);
  v_qty_share numeric(12,5);
  v_qty_accum numeric(12,5);
  v_discount_base numeric(12,2);
  v_discount_share numeric(12,2);
  v_discount_accum numeric(12,2);
  v_new_item_id uuid;
  v_modifiers jsonb;
  v_mod jsonb;
  v_mod_qty numeric(12,5);
  v_check_id uuid;
begin
  if p_order_id is null then raise exception 'ORDER_ID_REQUIRED'; end if;
  if v_people < 2 or v_people > 10 then raise exception 'PEOPLE_OUT_OF_RANGE'; end if;

  perform pg_advisory_xact_lock(hashtext(p_order_id::text));

  for v_idx in 1..v_people loop
    v_pos := v_idx + 1;
    v_target_check_ids := array_append(v_target_check_ids, public.fn_get_or_create_check(p_order_id, v_pos));
  end loop;

  for v_item in
    select * from public.order_items
    where order_id = p_order_id and status not in ('paid', 'void')
    order by created_at, id
  loop
    v_item_qty := coalesce(v_item.qty, 1);
    v_item_discounts := coalesce(v_item.discounts, 0);
    v_qty_base := trunc(v_item_qty / v_people, 5); -- Higher precision
    v_discount_base := round(v_item_discounts / v_people, 2);
    v_qty_accum := 0;
    v_discount_accum := 0;

    -- Cache modifiers
    select coalesce(jsonb_agg(m), '[]'::jsonb) into v_modifiers from public.order_item_modifiers m where item_id = v_item.id;

    for v_idx in 1..v_people loop
      if v_idx < v_people then
        v_qty_share := v_qty_base;
        v_discount_share := v_discount_base;
      else
        v_qty_share := v_item_qty - v_qty_accum;
        v_discount_share := v_item_discounts - v_discount_accum;
      end if;

      if v_qty_share > 0 then
        if v_idx = 1 then
          update public.order_items set
            check_id = v_target_check_ids[v_idx],
            qty = v_qty_share,
            quantity = v_qty_share,
            discounts = v_discount_share
          where id = v_item.id;
        else
          insert into public.order_items (
            order_id, check_id, product_id, product_name, unit_price, tax_mode, tax_rate, 
            qty, quantity, discounts, status, is_takeout, notes, created_at
          ) values (
            v_item.order_id, v_target_check_ids[v_idx], v_item.product_id, v_item.product_name, v_item.unit_price, 
            v_item.tax_mode, v_item.tax_rate, v_qty_share, v_qty_share, v_discount_share, 
            v_item.status, v_item.is_takeout, v_item.notes, v_item.created_at
          ) returning id into v_new_item_id;

          -- Replicate modifiers with split qty
          insert into public.order_item_modifiers (item_id, name, qty, price)
          select v_new_item_id, name, (qty / v_item_qty) * v_qty_share, price
          from public.order_item_modifiers where item_id = v_item.id;
        end if;
      end if;
      v_qty_accum := v_qty_accum + v_qty_share;
      v_discount_accum := v_discount_accum + v_discount_share;
    end loop;
  end loop;

  -- Final recalc
  perform public.calculate_order_totals(p_order_id);
  foreach v_check_id in array v_target_check_ids loop
    perform public.calculate_check_totals(v_check_id);
  end loop;

  return query select * from public.order_checks where id = any(v_target_check_ids) order by position;
end;
$$;

-- 6. Recalculate all affected orders
DO $$
DECLARE
  r RECORD;
BEGIN
  FOR r IN SELECT o.id FROM public.orders o WHERE o.closed_at IS NULL LOOP
    PERFORM public.calculate_order_totals(r.id);
  END LOOP;
END;
$$;
