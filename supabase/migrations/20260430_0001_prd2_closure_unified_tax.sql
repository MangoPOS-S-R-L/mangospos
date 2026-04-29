-- PRD 2.5 — Closure: Unified Tax Engine (Fase 1)
--
-- Cierra PRD 2 (decisiones AD2-5, AD2-7) consolidando el modelo dual
-- tax / service_fee en uno solo: TODO impuesto va a oi.tax + oi.tax_lines.
-- orders.service_fee y order_checks.service_fee quedan en 0 siempre.
--
-- Cambios:
--   1. fn_resolve_order_item_tax_profile  — incluye service fees al sumar rate
--   2. fn_populate_item_tax_lines (nueva)  — helper que escribe una fila por
--      cada impuesto aplicable al item (regulares + service fees)
--   3. fn_add_item_from_menu               — simplificado, llama al helper
--   4. calculate_order_totals              — service_fee = 0
--   5. calculate_check_totals              — service_fee = 0
--   6. trg_oi_tax_lines_sync (nuevo)       — mantiene tax_lines sincronizadas
--      cuando un item cambia subtotal/tax_rate
--   7. Re-pobla tax_lines + recalcula totales para órdenes abiertas
--   8. orders.service_fee = 0 y order_checks.service_fee = 0 para órdenes
--      abiertas (las cerradas quedan con su snapshot histórico)
--
-- NO se backfilea órdenes cerradas: sus snapshots quedan inmutables (AD2.5-2).
-- NO se borran columnas DB: quedan inertes (AD2.5-1).

-- ═══════════════════════════════════════════════════════════════════════════════
-- 1. fn_resolve_order_item_tax_profile — INCLUDES service fees
--    Antes excluía is_service_fee=true. Ahora suma TODO lo que aplica al origin.
-- ═══════════════════════════════════════════════════════════════════════════════
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

  -- PRD 2.5: incluir TODOS los taxes (regulares + service fees) que apliquen
  -- al origin de la orden. is_service_fee deja de ser un discriminador.
  SELECT coalesce(sum(t.rate), 0)::numeric
    INTO v_tax_rate
  FROM public.menu_item_taxes mit
  JOIN public.taxes t ON t.id = mit.tax_id
  WHERE mit.item_id = p_product_id
    AND t.business_id = v_biz_id
    AND coalesce(t.is_active, true)
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

-- ═══════════════════════════════════════════════════════════════════════════════
-- 2. fn_populate_item_tax_lines — helper nuevo
--    Reescribe order_item_tax_lines para un item:
--      DELETE existentes + INSERT una fila por tax aplicable al origin.
--    Idempotente: se puede llamar múltiples veces, siempre deja el estado correcto.
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
BEGIN
  SELECT oi.product_id, oi.subtotal, oi.status,
         trim(lower(ts.origin::text)), ts.business_id
    INTO v_product_id, v_subtotal, v_status, v_origin, v_biz_id
  FROM public.order_items oi
  JOIN public.orders o ON o.id = oi.order_id
  JOIN public.table_sessions ts ON ts.id = o.session_id
  WHERE oi.id = p_item_id;

  IF v_product_id IS NULL OR v_biz_id IS NULL THEN
    RETURN;
  END IF;

  -- Borrar snapshots viejos del item.
  DELETE FROM public.order_item_tax_lines WHERE order_item_id = p_item_id;

  -- Insertar una fila por cada tax aplicable. Para items void no insertamos
  -- (su tax_lines queda en blanco, que es lo correcto).
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
-- 3. fn_add_item_from_menu — simplificado
--    Usa la rate consolidada (incluye service fees). Llama al helper
--    al final para poblar tax_lines.
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

  -- Resolución unificada: incluye service fees + regulares.
  SELECT profile.tax_mode, profile.tax_rate
    INTO v_tax_mode, v_tax_rate
  FROM public.fn_resolve_order_item_tax_profile(p_menu_item_id, p_order_id) profile;

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

  -- Poblar tax_lines del item recién insertado.
  PERFORM public.fn_populate_item_tax_lines(v_item_id);

  PERFORM public.fn_recalc_order_totals(p_order_id);
  RETURN v_item_id;
END;
$$;

-- ═══════════════════════════════════════════════════════════════════════════════
-- 4. calculate_order_totals — service_fee = 0 SIEMPRE (PRD 2.5 AD2.5-3)
-- ═══════════════════════════════════════════════════════════════════════════════
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
  _total numeric := 0;
BEGIN
  -- Sumar items abiertos (excluyendo paid/void y checks cerrados).
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

  _total := _subtotal + _tax - _discounts;

  -- service_fee = 0 siempre (modelo unificado: todo va a tax).
  UPDATE public.orders SET
    subtotal    = ROUND(_subtotal, 2),
    tax         = ROUND(_tax, 2),
    service_fee = 0,
    discounts   = ROUND(_discounts, 2),
    total       = ROUND(_total, 2)
  WHERE id = _order_id;
END;
$$;

-- ═══════════════════════════════════════════════════════════════════════════════
-- 5. calculate_check_totals — service_fee = 0 SIEMPRE
-- ═══════════════════════════════════════════════════════════════════════════════
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
  _total numeric := 0;
BEGIN
  SELECT
    COALESCE(SUM(subtotal), 0),
    COALESCE(SUM(tax), 0),
    COALESCE(SUM(discounts), 0)
  INTO _subtotal, _tax, _discounts
  FROM public.order_items
  WHERE check_id = _check_id
    AND status NOT IN ('void');

  _total := _subtotal + _tax - _discounts;

  UPDATE public.order_checks SET
    subtotal    = ROUND(_subtotal, 2),
    tax         = ROUND(_tax, 2),
    discounts   = ROUND(_discounts, 2),
    service_fee = 0,
    total       = ROUND(_total, 2)
  WHERE id = _check_id;
END;
$$;

-- ═══════════════════════════════════════════════════════════════════════════════
-- 6. Trigger: mantener tax_lines sincronizadas cuando items cambian
--    Se dispara AFTER INSERT/UPDATE en order_items. Solo re-pobla si el item
--    no es paid/void y subtotal o tax_rate cambiaron (o es INSERT).
-- ═══════════════════════════════════════════════════════════════════════════════
CREATE OR REPLACE FUNCTION "public"."trg_oi_tax_lines_sync"() RETURNS "trigger"
LANGUAGE "plpgsql"
AS $$
BEGIN
  IF NEW.status IN ('paid', 'void') THEN
    RETURN NEW;
  END IF;

  IF TG_OP = 'INSERT' THEN
    PERFORM public.fn_populate_item_tax_lines(NEW.id);
  ELSIF TG_OP = 'UPDATE' THEN
    -- Solo repoblar si subtotal o tax_rate cambiaron, para evitar trabajo
    -- innecesario en updates de status/notes/etc.
    IF NEW.subtotal IS DISTINCT FROM OLD.subtotal
       OR NEW.tax_rate IS DISTINCT FROM OLD.tax_rate
       OR NEW.tax_mode IS DISTINCT FROM OLD.tax_mode THEN
      PERFORM public.fn_populate_item_tax_lines(NEW.id);
    END IF;
  END IF;
  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS "trg_oi_tax_lines_sync" ON "public"."order_items";
CREATE TRIGGER "trg_oi_tax_lines_sync"
AFTER INSERT OR UPDATE ON "public"."order_items"
FOR EACH ROW EXECUTE FUNCTION "public"."trg_oi_tax_lines_sync"();

-- ═══════════════════════════════════════════════════════════════════════════════
-- 7. Re-poblar tax_lines + recalcular totales para órdenes abiertas
--    Las cerradas (paid/void) NO se tocan: sus snapshots quedan inmutables.
-- ═══════════════════════════════════════════════════════════════════════════════
DO $$
DECLARE
  _item_id uuid;
  _order_id uuid;
  _menu_item_id uuid;
  _origin_text text;
  _biz_id uuid;
  _new_tax_rate numeric;
BEGIN
  -- 7.1) Recompute oi.tax_rate para items abiertos según el modelo unificado.
  --      Esto es necesario porque items creados antes de esta migration
  --      tienen oi.tax_rate excluyendo service fees. Los re-resolvemos.
  FOR _item_id, _order_id, _menu_item_id IN
    SELECT oi.id, oi.order_id, oi.product_id
    FROM public.order_items oi
    JOIN public.orders o ON o.id = oi.order_id
    WHERE o.status_ext = 'open'
      AND oi.status NOT IN ('paid', 'void')
      AND oi.product_id IS NOT NULL
  LOOP
    SELECT profile.tax_rate INTO _new_tax_rate
    FROM public.fn_resolve_order_item_tax_profile(_menu_item_id, _order_id) profile;

    UPDATE public.order_items
    SET tax_rate = COALESCE(_new_tax_rate, 0),
        original_tax_rate = COALESCE(_new_tax_rate, 0)
    WHERE id = _item_id;
    -- El trigger trg_oi_tax_lines_sync se dispara en este UPDATE
    -- (porque tax_rate puede cambiar) y repuebla tax_lines.
    -- También fn_compute_item_totals BEFORE UPDATE recalcula oi.tax.
  END LOOP;

  -- 7.2) Recalcular totales de cada orden abierta (esto setea service_fee=0).
  FOR _order_id IN
    SELECT id FROM public.orders WHERE status_ext = 'open'
  LOOP
    PERFORM public.calculate_order_totals(_order_id);
  END LOOP;

  -- 7.3) Recalcular totales de checks abiertos.
  FOR _order_id IN
    SELECT DISTINCT oc.id
    FROM public.order_checks oc
    JOIN public.orders o ON o.id = oc.order_id
    WHERE o.status_ext = 'open'
      AND COALESCE(oc.is_closed, false) = false
  LOOP
    PERFORM public.calculate_check_totals(_order_id);
  END LOOP;
END $$;
