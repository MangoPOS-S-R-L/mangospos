-- Captured from production on 2026-04-28 (PRD 2 F2.2 pre-step).
-- Source: SELECT pg_get_functiondef('public.fn_resolve_order_item_tax_profile'::regproc);
--
-- Resuelve (tax_mode, tax_rate) para un producto en el contexto de un order:
--   - tax_mode: viene del producto (menu_items.tax_mode), default 'exclusive'.
--   - tax_rate: SUMA de taxes del producto en menu_item_taxes, EXCLUYENDO
--     service fee, filtrados por origin del order.
--
-- Hallazgo clave: NO lee business_settings. Bien.
-- Hallazgo clave: el filtro origin tiene CASE statements con valores fantasma
--                 del enum (table, zone, table_order, manual_order, quick_sale,
--                 quick-sale). Esos branches son código muerto: el enum real
--                 sólo tiene dine_in/manual/quick/delivery/self_service.
--
-- En PRD 2 esta función se simplifica: dejar SOLO los 4 origins reales y
-- agregar fail-loud para self_service.

CREATE OR REPLACE FUNCTION public.fn_resolve_order_item_tax_profile(p_product_id uuid, p_order_id uuid)
 RETURNS TABLE(tax_mode text, tax_rate numeric)
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
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
$function$;
