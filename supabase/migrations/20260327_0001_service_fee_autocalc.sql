-- 1. Ensure order_checks has service_fee column
DO $$ 
BEGIN 
    IF NOT EXISTS (SELECT 1 FROM information_schema.columns WHERE table_name='order_checks' AND column_name='service_fee') THEN
        ALTER TABLE public.order_checks ADD COLUMN service_fee numeric(12,2) DEFAULT 0 NOT NULL;
    END IF;
END $$;

-- 2. Update calculate_order_totals with automatic Service Fee (10%)
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
BEGIN
  -- 1. Sum up item totals
  SELECT 
    COALESCE(SUM(subtotal), 0),
    COALESCE(SUM(tax), 0),
    COALESCE(SUM(discounts), 0)
  INTO _subtotal, _tax, _discounts
  FROM public.order_items
  WHERE order_id = _order_id;
  
  -- 2. Fetch business settings for service fee
  SELECT COALESCE(bs.service_fee_enabled, false), COALESCE(bs.service_fee_rate, 10)
  INTO _sf_enabled, _sf_rate
  FROM public.orders o
  JOIN public.table_sessions ts ON o.session_id = ts.id
  JOIN public.business_settings bs ON ts.business_id = bs.business_id
  WHERE o.id = _order_id;

  -- 3. Calculate service fee (10% on dine-in items)
  IF _sf_enabled THEN
    SELECT COALESCE(SUM(subtotal), 0) * (_sf_rate / 100.0)
    INTO _service_fee
    FROM public.order_items
    WHERE order_id = _order_id AND is_takeout = false;
  END IF;
  
  _total := _subtotal + _tax + _service_fee - _discounts;
  
  -- 4. Update the order
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

-- 3. Update calculate_check_totals with automatic Service Fee (10%)
CREATE OR REPLACE FUNCTION "public"."calculate_check_totals"("_check_id" "uuid") RETURNS "void"
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
BEGIN
  -- 1. Sum up item totals for the check
  SELECT 
    COALESCE(SUM(subtotal), 0),
    COALESCE(SUM(tax), 0),
    COALESCE(SUM(discounts), 0)
  INTO _subtotal, _tax, _discounts
  FROM public.order_items
  WHERE check_id = _check_id;

  -- 2. Fetch business settings
  SELECT COALESCE(bs.service_fee_enabled, false), COALESCE(bs.service_fee_rate, 10)
  INTO _sf_enabled, _sf_rate
  FROM public.order_checks ch
  JOIN public.orders o ON ch.order_id = o.id
  JOIN public.table_sessions ts ON o.session_id = ts.id
  JOIN public.business_settings bs ON ts.business_id = bs.business_id
  WHERE ch.id = _check_id;

  -- 3. Calculate service fee for the check
  IF _sf_enabled THEN
    SELECT COALESCE(SUM(subtotal), 0) * (_sf_rate / 100.0)
    INTO _service_fee
    FROM public.order_items
    WHERE check_id = _check_id AND is_takeout = false;
  END IF;

  _total := _subtotal + _tax + _service_fee - _discounts;

  -- 4. Update the check
  UPDATE public.order_checks
  SET 
    subtotal = _subtotal,
    tax = _tax,
    discounts = _discounts,
    service_fee = ROUND(_service_fee, 2),
    total = ROUND(_total, 2)
  WHERE id = _check_id;
END;
$$;
