-- Captured from production on 2026-04-28 (PRD 2 F2.2 pre-step).
-- Source: SELECT pg_get_functiondef('public.calculate_check_totals'::regproc);
-- Use: rollback target if PRD 2 modifications break this function.

CREATE OR REPLACE FUNCTION public.calculate_check_totals(_check_id uuid)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
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
$function$;
