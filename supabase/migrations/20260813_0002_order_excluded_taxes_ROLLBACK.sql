-- Rollback de 20260813_0002_order_excluded_taxes.sql
--
-- Devuelve las dos funciones fiscales a su cuerpo de 20260502_0001 (sin el
-- filtro de exclusión por orden) y elimina el RPC y la tabla.
--
-- ⚠️ ORDEN IMPORTANTE: primero se restauran las funciones y DESPUÉS se borra
-- la tabla. Al revés, cualquier item que se recalcule entre medio explota
-- porque la función todavía referencia `order_excluded_taxes`.
--
-- ⚠️ Las órdenes abiertas que tenían impuestos excluidos NO se recalculan
-- solas: quedan con la tasa reducida hasta que algo las toque. Si hace falta
-- devolverlas al impuesto completo, correr al final el bloque comentado.

-- 1. fn_resolve_order_item_tax_profile — cuerpo de 20260502_0001
CREATE OR REPLACE FUNCTION "public"."fn_resolve_order_item_tax_profile"(
  "p_product_id" "uuid",
  "p_order_id" "uuid",
  "p_is_takeout" boolean DEFAULT false
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
    AND (NOT coalesce(p_is_takeout, false) OR coalesce(t.apply_on_takeout, true) = true)
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

-- 2. fn_populate_item_tax_lines — cuerpo de 20260502_0001
CREATE OR REPLACE FUNCTION "public"."fn_populate_item_tax_lines"("p_item_id" "uuid")
RETURNS "void"
LANGUAGE "plpgsql"
SECURITY DEFINER
SET "search_path" TO 'public'
AS $$
DECLARE
  v_product_id uuid;
  v_subtotal numeric;
  v_origin text;
  v_biz_id uuid;
  v_status text;
  v_is_takeout boolean;
BEGIN
  SELECT oi.product_id, oi.subtotal, oi.status, coalesce(oi.is_takeout, false),
         trim(lower(ts.origin::text)), ts.business_id
    INTO v_product_id, v_subtotal, v_status, v_is_takeout, v_origin, v_biz_id
  FROM public.order_items oi
  JOIN public.orders o ON o.id = oi.order_id
  JOIN public.table_sessions ts ON ts.id = o.session_id
  WHERE oi.id = p_item_id;

  IF v_product_id IS NULL OR v_biz_id IS NULL THEN
    RETURN;
  END IF;

  DELETE FROM public.order_item_tax_lines WHERE order_item_id = p_item_id;

  IF v_status = 'void' THEN
    RETURN;
  END IF;

  INSERT INTO public.order_item_tax_lines
    (order_item_id, tax_id, tax_name, tax_rate, amount, created_at)
  SELECT
    p_item_id,
    t.id,
    t.name,
    t.rate,
    ROUND(v_subtotal * (t.rate / 100.0), 2),
    NOW()
  FROM public.menu_item_taxes mit
  JOIN public.taxes t ON t.id = mit.tax_id
  WHERE mit.item_id = v_product_id
    AND t.business_id = v_biz_id
    AND coalesce(t.is_active, true)
    AND (NOT v_is_takeout OR coalesce(t.apply_on_takeout, true) = true)
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
END;
$$;

-- 3. RPC y tabla
DROP FUNCTION IF EXISTS "public"."fn_set_order_excluded_taxes"("uuid", "uuid"[], "uuid");
DROP TABLE IF EXISTS "public"."order_excluded_taxes";

-- 4. OPCIONAL — devolver las órdenes abiertas afectadas al impuesto completo.
--    Descomentar solo si hay órdenes vivas que quedaron con tasa reducida.
--
--    NO usar fn_mark_order_takeout para esto: ese toggle PISA is_takeout en
--    todos los items y perderías qué era para llevar. Este bloque re-resuelve
--    la tasa item por item respetando el is_takeout que cada uno ya tiene.
--
-- DO $rollback$
-- DECLARE
--   r record;
--   v_tax_mode text;
--   v_tax_rate numeric;
-- BEGIN
--   FOR r IN
--     SELECT oi.id, oi.order_id, oi.product_id, coalesce(oi.is_takeout, false) AS is_takeout
--       FROM public.order_items oi
--       JOIN public.orders o ON o.id = oi.order_id
--      WHERE coalesce(o.status, '') NOT IN ('paid','void','cancelled')
--        AND coalesce(oi.status, '') <> 'void'
--        AND oi.product_id IS NOT NULL
--   LOOP
--     SELECT profile.tax_mode, profile.tax_rate
--       INTO v_tax_mode, v_tax_rate
--     FROM public.fn_resolve_order_item_tax_profile(
--       r.product_id, r.order_id, r.is_takeout
--     ) profile;
--
--     UPDATE public.order_items
--        SET tax_rate = coalesce(v_tax_rate, 0),
--            original_tax_rate = coalesce(v_tax_rate, 0),
--            tax_mode = coalesce(v_tax_mode, tax_mode)
--      WHERE id = r.id;
--
--     PERFORM public.fn_populate_item_tax_lines(r.id);
--   END LOOP;
--
--   PERFORM public.fn_recalc_order_totals(o.id)
--     FROM (SELECT DISTINCT id FROM public.orders
--            WHERE coalesce(status,'') NOT IN ('paid','void','cancelled')) o;
-- END
-- $rollback$;
