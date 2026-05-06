-- PRD 6 — Toggle "Aplicar para llevar" por impuesto.
--
-- Hasta ahora, el motor de impuestos hardcodeaba que el service fee se
-- saltea para items takeout. Eso ya no escala: hay restaurantes que
-- también quieren no cobrar ITBIS o algún otro tax cuando el pedido es
-- para llevar. La solución es per-tax: cada fila en `taxes` declara si
-- aplica para items con `is_takeout = true`.
--
-- Cambios:
--   1. Columna `taxes.apply_on_takeout boolean DEFAULT true`.
--   2. Backfill: service fees existentes → false (mantiene comportamiento).
--   3. fn_resolve_order_item_tax_profile acepta p_is_takeout.
--   4. fn_populate_item_tax_lines lee oi.is_takeout y filtra.
--   5. fn_add_item_from_menu pasa p_is_takeout al resolver.

-- ═══════════════════════════════════════════════════════════════════════════════
-- 1. Columna nueva
-- ═══════════════════════════════════════════════════════════════════════════════
ALTER TABLE public.taxes
  ADD COLUMN IF NOT EXISTS apply_on_takeout boolean NOT NULL DEFAULT true;

COMMENT ON COLUMN public.taxes.apply_on_takeout IS
  'Si TRUE, el impuesto aplica también a items con is_takeout=true. Default true para no romper taxes regulares; backfill setea FALSE para is_service_fee=true (preserva el skip hardcodeado pre-migración).';

-- ═══════════════════════════════════════════════════════════════════════════════
-- 2. Backfill: service fees mantienen comportamiento legacy (no aplicar para llevar)
-- ═══════════════════════════════════════════════════════════════════════════════
UPDATE public.taxes
   SET apply_on_takeout = false
 WHERE coalesce(is_service_fee, false) = true;

-- ═══════════════════════════════════════════════════════════════════════════════
-- 3. fn_resolve_order_item_tax_profile — ahora con p_is_takeout
-- ═══════════════════════════════════════════════════════════════════════════════
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
    -- Filtro takeout: si el item es para llevar, excluir taxes con apply_on_takeout=false.
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

GRANT EXECUTE ON FUNCTION "public"."fn_resolve_order_item_tax_profile"("uuid", "uuid", boolean) TO "anon";
GRANT EXECUTE ON FUNCTION "public"."fn_resolve_order_item_tax_profile"("uuid", "uuid", boolean) TO "authenticated";
GRANT EXECUTE ON FUNCTION "public"."fn_resolve_order_item_tax_profile"("uuid", "uuid", boolean) TO "service_role";

-- ═══════════════════════════════════════════════════════════════════════════════
-- 4. fn_populate_item_tax_lines — lee oi.is_takeout y filtra
-- ═══════════════════════════════════════════════════════════════════════════════
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
    -- Filtro takeout: skip taxes con apply_on_takeout=false cuando el item es para llevar.
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

GRANT EXECUTE ON FUNCTION "public"."fn_populate_item_tax_lines"("uuid") TO "anon";
GRANT EXECUTE ON FUNCTION "public"."fn_populate_item_tax_lines"("uuid") TO "authenticated";
GRANT EXECUTE ON FUNCTION "public"."fn_populate_item_tax_lines"("uuid") TO "service_role";

-- ═══════════════════════════════════════════════════════════════════════════════
-- 5. fn_add_item_from_menu — pasa p_is_takeout al resolver
-- ═══════════════════════════════════════════════════════════════════════════════
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
  v_print_area_code text;
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

  -- Resolución unificada: incluye service fees + regulares, ahora también
  -- filtrada por takeout per-tax.
  SELECT profile.tax_mode, profile.tax_rate
    INTO v_tax_mode, v_tax_rate
  FROM public.fn_resolve_order_item_tax_profile(
    p_menu_item_id, p_order_id, coalesce(p_is_takeout, false)
  ) profile;

  v_check := public.fn_get_or_create_check(p_order_id, p_check_position);

  INSERT INTO public.order_items(
    order_id, check_id, product_id, product_name,
    qty, quantity, unit_price, tax_mode, tax_rate, original_tax_rate,
    is_takeout, notes, status, print_area_code
  ) VALUES (
    p_order_id, v_check, p_menu_item_id, v_name,
    v_qty, v_qty, v_price, coalesce(v_tax_mode, 'exclusive'),
    coalesce(v_tax_rate, 0), coalesce(v_tax_rate, 0),
    coalesce(p_is_takeout, false), p_notes, 'draft',
    v_print_area_code
  )
  RETURNING id INTO v_item_id;

  PERFORM public.fn_populate_item_tax_lines(v_item_id);
  PERFORM public.fn_recalc_order_totals(p_order_id);
  RETURN v_item_id;
END;
$$;

GRANT EXECUTE ON FUNCTION "public"."fn_add_item_from_menu"("uuid", "uuid", numeric, integer, boolean, "text") TO "anon";
GRANT EXECUTE ON FUNCTION "public"."fn_add_item_from_menu"("uuid", "uuid", numeric, integer, boolean, "text") TO "authenticated";
GRANT EXECUTE ON FUNCTION "public"."fn_add_item_from_menu"("uuid", "uuid", numeric, integer, boolean, "text") TO "service_role";

-- ═══════════════════════════════════════════════════════════════════════════════
-- Smoke checks (manuales — se corren post-deploy en SQL editor)
-- ═══════════════════════════════════════════════════════════════════════════════
-- 1) Verificar columna creada y backfill:
--    SELECT id, name, is_service_fee, apply_on_takeout
--      FROM public.taxes
--     ORDER BY is_service_fee DESC, name;
--
-- 2) Verificar que un item takeout con tax apply_on_takeout=false NO incluye ese tax:
--    -- Crear una orden, agregar item con p_is_takeout=true y observar tax_rate.
--    -- Contrastar contra el mismo producto sin takeout.
--
-- 3) Verificar que tax_lines del item respetan el flag:
--    SELECT * FROM public.order_item_tax_lines
--     WHERE order_item_id = '<id-takeout-item>';
