-- ROLLBACK de 20260625_0001_delivery_fee.sql
-- Restaura calculate_order_totals SIN el fee, elimina fn_set_delivery_fee y
-- las columnas. OJO: dropear orders.delivery_fee / business_settings.* pierde
-- los montos ya capturados. Si hay datos en producción, evalúa conservarlos.

DROP FUNCTION IF EXISTS public.fn_set_delivery_fee(uuid, numeric);

CREATE OR REPLACE FUNCTION public.calculate_order_totals(_order_id uuid)
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
  _sf_rate_total numeric := 0;
  _sf_taxable_subtotal numeric := 0;
  _has_per_tax_sf boolean := false;
  _legacy_sf_rate numeric := 10;
  _legacy_apply boolean := false;
  _legacy_on_zone boolean := true;
  _legacy_on_manual boolean := true;
  _legacy_on_quick boolean := false;
  _legacy_on_delivery boolean := false;
BEGIN
  SELECT trim(lower(ts.origin::text)), ts.business_id
    INTO _origin, _biz_id
  FROM public.orders o
  JOIN public.table_sessions ts ON o.session_id = ts.id
  WHERE o.id = _order_id;

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

  SELECT COALESCE(bs.service_fee_enabled, false),
         COALESCE(bs.service_fee_rate, 10),
         COALESCE(bs.service_fee_on_zone, true),
         COALESCE(bs.service_fee_on_manual, true),
         COALESCE(bs.service_fee_on_quick, false),
         COALESCE(bs.service_fee_on_delivery, false)
    INTO _sf_enabled, _legacy_sf_rate,
         _legacy_on_zone, _legacy_on_manual, _legacy_on_quick, _legacy_on_delivery
  FROM public.business_settings bs
  WHERE bs.business_id = _biz_id;

  IF _sf_enabled THEN
    SELECT EXISTS (
      SELECT 1 FROM public.taxes t
      WHERE t.business_id = _biz_id
        AND COALESCE(t.is_service_fee, false) = true
    ) INTO _has_per_tax_sf;

    SELECT COALESCE(SUM(t.rate), 0)
      INTO _sf_rate_total
    FROM public.taxes t
    WHERE t.business_id = _biz_id
      AND COALESCE(t.is_active, true)
      AND COALESCE(t.is_service_fee, false) = true
      AND (
        (_origin IN ('dine_in','table','zone','table_order') AND t.apply_on_zone = true) OR
        (_origin IN ('manual','manual_order') AND t.apply_on_manual = true) OR
        (_origin IN ('quick','quick_sale','quick-sale') AND t.apply_on_quick = true) OR
        ((_origin = 'delivery' OR _origin LIKE '%delivery%') AND t.apply_on_delivery = true) OR
        (_origin IS NULL OR _origin NOT IN (
          'dine_in','table','zone','table_order',
          'manual','manual_order',
          'quick','quick_sale','quick-sale',
          'delivery'
        ))
      );

    IF NOT _has_per_tax_sf THEN
      CASE
        WHEN _origin IN ('table','dine_in','zone','table_order') THEN _legacy_apply := _legacy_on_zone;
        WHEN _origin IN ('manual','manual_order') THEN _legacy_apply := _legacy_on_manual;
        WHEN _origin IN ('quick','quick_sale','quick-sale') THEN _legacy_apply := _legacy_on_quick;
        WHEN _origin = 'delivery' OR _origin LIKE '%delivery%' THEN _legacy_apply := _legacy_on_delivery;
        ELSE _legacy_apply := true;
      END CASE;
      IF _legacy_apply THEN
        _sf_rate_total := _legacy_sf_rate;
      ELSE
        _sf_rate_total := 0;
      END IF;
    END IF;

    IF _sf_rate_total > 0 THEN
      SELECT COALESCE(SUM(oi.subtotal), 0)
        INTO _sf_taxable_subtotal
      FROM public.order_items oi
      LEFT JOIN public.order_checks oc ON oi.check_id = oc.id
      WHERE oi.order_id = _order_id
        AND oi.is_takeout = false
        AND oi.status NOT IN ('paid', 'void')
        AND COALESCE(oc.is_closed, false) = false;

      _service_fee := _sf_taxable_subtotal * (_sf_rate_total / 100.0);
    END IF;
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
$function$;

ALTER TABLE public.business_settings
  DROP COLUMN IF EXISTS delivery_fee_required,
  DROP COLUMN IF EXISTS delivery_fee_min,
  DROP COLUMN IF EXISTS delivery_fee_presets;

ALTER TABLE public.orders
  DROP COLUMN IF EXISTS delivery_fee;
