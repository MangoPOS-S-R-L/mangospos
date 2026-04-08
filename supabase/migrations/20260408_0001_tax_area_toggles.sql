-- Agrega columnas para controlar en qué secciones se aplica cada impuesto.
ALTER TABLE public.taxes ADD COLUMN IF NOT EXISTS apply_on_zone boolean NOT NULL DEFAULT true;
ALTER TABLE public.taxes ADD COLUMN IF NOT EXISTS apply_on_manual boolean NOT NULL DEFAULT true;
ALTER TABLE public.taxes ADD COLUMN IF NOT EXISTS apply_on_quick boolean NOT NULL DEFAULT true;

COMMENT ON COLUMN public.taxes.apply_on_zone IS 'Aplicar este impuesto en ventas por zona (mesas / dine-in)';
COMMENT ON COLUMN public.taxes.apply_on_manual IS 'Aplicar este impuesto en ventas manuales (mostrador / walk-in)';
COMMENT ON COLUMN public.taxes.apply_on_quick IS 'Aplicar este impuesto en venta rápida (quick sale)';

-- Actualizar la función para filtrar impuestos por origen al agregar items
CREATE OR REPLACE FUNCTION "public"."fn_resolve_order_item_tax_profile"("p_product_id" "uuid", "p_order_id" "uuid") 
RETURNS TABLE("tax_mode" "text", "tax_rate" numeric) 
LANGUAGE "plpgsql" STABLE 
AS $$
DECLARE
  v_origin text;
  v_tax_mode text;
  v_tax_rate numeric;
BEGIN
  -- 1. Obtener el origen del pedido
  SELECT ts.origin INTO v_origin
  FROM public.orders o
  JOIN public.table_sessions ts ON ts.id = o.session_id
  WHERE o.id = p_order_id;
  
  -- 2. Resolver tax_mode del producto
  SELECT coalesce(mi.tax_mode, 'exclusive') INTO v_tax_mode
  FROM public.menu_items mi
  WHERE mi.id = p_product_id;

  -- 3. Sumar tasas de impuestos vinculados que apliquen al origen
  SELECT coalesce(sum(t.rate), 0)::numeric INTO v_tax_rate
  FROM public.menu_item_taxes mit
  JOIN public.taxes t ON t.id = mit.tax_id
  WHERE mit.item_id = p_product_id
    AND coalesce(t.is_active, true)
    AND (
      (v_origin = 'dine_in' AND t.apply_on_zone = true) OR
      (v_origin = 'manual' AND t.apply_on_manual = true) OR
      (v_origin = 'quick' AND t.apply_on_quick = true) OR
      (v_origin NOT IN ('dine_in', 'manual', 'quick'))
    );

  -- 4. Si no hay impuestos específicos, usar el de por defecto del negocio
  IF v_tax_rate = 0 THEN
    SELECT coalesce(bs.default_tax_rate, 0)::numeric INTO v_tax_rate
    FROM public.orders o
    JOIN public.table_sessions ts ON ts.id = o.session_id
    LEFT JOIN public.business_settings bs ON bs.business_id = ts.business_id
    WHERE o.id = p_order_id;
  END IF;

  RETURN QUERY SELECT coalesce(v_tax_mode, 'exclusive'), coalesce(v_tax_rate, 0);
END;
$$;

-- Actualizar calculo de totales para respetar area-specific service fee
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
  _apply_sf boolean := false;
BEGIN
  -- 1. Sumar totales de items
  SELECT 
    COALESCE(SUM(subtotal), 0),
    COALESCE(SUM(tax), 0),
    COALESCE(SUM(discounts), 0)
  INTO _subtotal, _tax, _discounts
  FROM public.order_items
  WHERE order_id = _order_id;
  
  -- 2. Obtener configuracion y origen
  SELECT 
    COALESCE(bs.service_fee_enabled, false), 
    COALESCE(bs.service_fee_rate, 10),
    ts.origin::text,
    COALESCE(bs.service_fee_on_zone, true),
    COALESCE(bs.service_fee_on_manual, true),
    COALESCE(bs.service_fee_on_quick, false)
  INTO _sf_enabled, _sf_rate, _origin, _sf_on_zone, _sf_on_manual, _sf_on_quick
  FROM public.orders o
  JOIN public.table_sessions ts ON o.session_id = ts.id
  JOIN public.business_settings bs ON ts.business_id = bs.business_id
  WHERE o.id = _order_id;

  -- 3. Determinar si aplica SF para este origen
  IF _sf_enabled THEN
    IF _origin = 'dine_in' AND _sf_on_zone THEN _apply_sf := true;
    ELSIF _origin = 'manual' AND _sf_on_manual THEN _apply_sf := true;
    ELSIF _origin = 'quick' AND _sf_on_quick THEN _apply_sf := true;
    ELSIF _origin NOT IN ('dine_in', 'manual', 'quick') THEN _apply_sf := true;
    END IF;
  END IF;

  -- 4. Calcular service fee
  IF _apply_sf THEN
    SELECT COALESCE(SUM(subtotal), 0) * (_sf_rate / 100.0)
    INTO _service_fee
    FROM public.order_items
    WHERE order_id = _order_id AND is_takeout = false;
  END IF;
  
  _total := _subtotal + _tax + _service_fee - _discounts;
  
  -- 5. Actualizar la orden
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
  _origin text;
  _sf_on_zone boolean;
  _sf_on_manual boolean;
  _sf_on_quick boolean;
  _apply_sf boolean := false;
BEGIN
  -- 1. Sumar totales del check
  SELECT 
    COALESCE(SUM(subtotal), 0),
    COALESCE(SUM(tax), 0),
    COALESCE(SUM(discounts), 0)
  INTO _subtotal, _tax, _discounts
  FROM public.order_items
  WHERE check_id = _check_id;

  -- 2. Obtener configuracion y origen
  SELECT 
    COALESCE(bs.service_fee_enabled, false), 
    COALESCE(bs.service_fee_rate, 10),
    ts.origin::text,
    COALESCE(bs.service_fee_on_zone, true),
    COALESCE(bs.service_fee_on_manual, true),
    COALESCE(bs.service_fee_on_quick, false)
  INTO _sf_enabled, _sf_rate, _origin, _sf_on_zone, _sf_on_manual, _sf_on_quick
  FROM public.order_checks ch
  JOIN public.orders o ON ch.order_id = o.id
  JOIN public.table_sessions ts ON o.session_id = ts.id
  JOIN public.business_settings bs ON ts.business_id = bs.business_id
  WHERE ch.id = _check_id;

  -- 3. Determinar si aplica SF para este origen
  IF _sf_enabled THEN
    IF _origin = 'dine_in' AND _sf_on_zone THEN _apply_sf := true;
    ELSIF _origin = 'manual' AND _sf_on_manual THEN _apply_sf := true;
    ELSIF _origin = 'quick' AND _sf_on_quick THEN _apply_sf := true;
    ELSIF _origin NOT IN ('dine_in', 'manual', 'quick') THEN _apply_sf := true;
    END IF;
  END IF;

  -- 4. Calcular service fee para el check
  IF _apply_sf THEN
    SELECT COALESCE(SUM(subtotal), 0) * (_sf_rate / 100.0)
    INTO _service_fee
    FROM public.order_items
    WHERE check_id = _check_id AND is_takeout = false;
  END IF;

  _total := _subtotal + _tax + _service_fee - _discounts;

  -- 5. Actualizar el check
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

