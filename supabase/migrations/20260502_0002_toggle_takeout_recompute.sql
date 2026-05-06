-- PRD 6 — fix: cuando el usuario toggle "para llevar" en un item existente,
-- recomputar oi.tax_rate y repoblar tax_lines.
--
-- Bug observado: tras aplicar 20260502_0001, marcar un item como takeout
-- ocultaba la línea de Ley en el breakdown pero `oi.tax` y `oi.tax_rate`
-- quedaban con la rate consolidada original (28%). Resultado: subtotal +
-- ITBIS != total porque oi.tax aún incluía el 10% Ley.
--
-- Fix: extender `fn_toggle_item_takeout` para que tras flipear is_takeout:
--   1. Re-resuelva la rate via fn_resolve_order_item_tax_profile pasando
--      el nuevo valor de p_is_takeout.
--   2. Update oi.tax_rate (esto dispara fn_compute_item_totals que
--      recalcula oi.subtotal y oi.tax con la rate nueva).
--   3. Repuebla tax_lines via fn_populate_item_tax_lines (ya filtra por
--      takeout en 20260502_0001).
--   4. Recalcula totales de la orden.

CREATE OR REPLACE FUNCTION "public"."fn_toggle_item_takeout"(
  "p_item_id" "uuid",
  "p_takeout" boolean
) RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $$
DECLARE
  v_order_id uuid;
  v_product_id uuid;
  v_tax_mode text;
  v_tax_rate numeric := 0;
BEGIN
  -- Datos del item.
  SELECT order_id, product_id
    INTO v_order_id, v_product_id
  FROM public.order_items
  WHERE id = p_item_id;

  IF v_order_id IS NULL THEN
    RETURN;
  END IF;

  -- Re-resolver rate considerando el nuevo flag de takeout.
  SELECT profile.tax_mode, profile.tax_rate
    INTO v_tax_mode, v_tax_rate
  FROM public.fn_resolve_order_item_tax_profile(
    v_product_id, v_order_id, coalesce(p_takeout, false)
  ) profile;

  -- Update is_takeout + tax_rate en una misma sentencia. El trigger
  -- fn_compute_item_totals recalcula oi.subtotal y oi.tax usando
  -- la nueva tax_rate.
  UPDATE public.order_items
     SET is_takeout = p_takeout,
         tax_rate = coalesce(v_tax_rate, 0),
         original_tax_rate = coalesce(v_tax_rate, 0),
         tax_mode = coalesce(v_tax_mode, tax_mode)
   WHERE id = p_item_id;

  -- Repoblar tax_lines (ya filtra por is_takeout via 20260502_0001).
  PERFORM public.fn_populate_item_tax_lines(p_item_id);

  -- Recalcular totales de la orden.
  PERFORM public.fn_recalc_order_totals(v_order_id);
END;
$$;

GRANT EXECUTE ON FUNCTION "public"."fn_toggle_item_takeout"("uuid", boolean) TO "anon";
GRANT EXECUTE ON FUNCTION "public"."fn_toggle_item_takeout"("uuid", boolean) TO "authenticated";
GRANT EXECUTE ON FUNCTION "public"."fn_toggle_item_takeout"("uuid", boolean) TO "service_role";

-- ═══════════════════════════════════════════════════════════════════════════════
-- También: fn_mark_order_takeout (toggle a nivel orden) debe propagar el
-- mismo recompute a TODOS los items.
-- ═══════════════════════════════════════════════════════════════════════════════

CREATE OR REPLACE FUNCTION "public"."fn_mark_order_takeout"(
  "p_order_id" "uuid",
  "p_takeout" boolean
) RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $$
DECLARE
  r record;
BEGIN
  -- Iterar items de la orden y reusar el toggle individual (que ya hace
  -- recompute completo). Es O(n) pero correcto; típicamente n < 30.
  FOR r IN
    SELECT id FROM public.order_items WHERE order_id = p_order_id
  LOOP
    PERFORM public.fn_toggle_item_takeout(r.id, p_takeout);
  END LOOP;
END;
$$;

GRANT EXECUTE ON FUNCTION "public"."fn_mark_order_takeout"("uuid", boolean) TO "anon";
GRANT EXECUTE ON FUNCTION "public"."fn_mark_order_takeout"("uuid", boolean) TO "authenticated";
GRANT EXECUTE ON FUNCTION "public"."fn_mark_order_takeout"("uuid", boolean) TO "service_role";

-- ═══════════════════════════════════════════════════════════════════════════════
-- Smoke check
-- ═══════════════════════════════════════════════════════════════════════════════
-- SELECT id, product_name, is_takeout, tax_rate, subtotal, tax, total
--   FROM public.order_items
--  WHERE order_id = '<order-id>'
--  ORDER BY created_at;
--
-- Toggle takeout y volver a consultar — tax_rate debe reflejar el filtro
-- y subtotal+tax debe coincidir con total.
