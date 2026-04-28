-- Captured from production on 2026-04-28 (PRD 2 F2.2 pre-step).
-- Source: SELECT pg_get_functiondef('public.calculate_order_totals'::regproc);
-- Use: rollback target if PRD 2 modifications break this function.
--
-- NOTE: Esta función es la responsable directa del bug "propina fantasma a
-- nivel línea" que vimos con Agua Dasany. Nótese cómo el service_fee se
-- calcula a NIVEL ORDEN sumando subtotal de TODOS los items (excepto takeout),
-- sin consultar si cada producto tiene impuestos asociados o no.

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
  _sf_rate numeric := 10;
  _apply_sf boolean := false;
BEGIN
  -- 1. Obtener datos básicos
  SELECT trim(lower(ts.origin::text)), ts.business_id, COALESCE(bs.service_fee_rate, 10)
    INTO _origin, _biz_id, _sf_rate
  FROM public.orders o
  JOIN public.table_sessions ts ON o.session_id = ts.id
  JOIN public.business_settings bs ON ts.business_id = bs.business_id
  WHERE o.id = _order_id;

  -- 2. SUMAR usando la máxima precisión (sin redondear cada ítem)
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

  -- 3. Propina de Ley (calculada sobre el subtotal acumulado de precisión)
  -- Solo si no es takeout
  SELECT COALESCE(SUM(subtotal), 0) * (_sf_rate / 100.0)
  INTO _service_fee
  FROM public.order_items
  WHERE order_id = _order_id AND is_takeout = false AND status NOT IN ('paid', 'void');

  -- 4. TOTAL FINAL: Sumamos todo y RECIEN AHORA redondeamos a 2 decimales
  -- Esto evita que el 199.99 aparezca por culpa de redondeos intermedios
  _total := _subtotal + _tax + _service_fee - _discounts;

  -- 5. Guardar en la orden redondeando SOLO en este paso
  UPDATE public.orders SET
    subtotal    = ROUND(_subtotal, 4), -- Mantenemos 4 para consistencia interna
    tax         = ROUND(_tax, 4),
    service_fee = ROUND(_service_fee, 4),
    discounts   = ROUND(_discounts, 2),
    total       = ROUND(_total, 2)     -- El total sí debe ser de 2 decimales
  WHERE id = _order_id;
END;
$function$;
