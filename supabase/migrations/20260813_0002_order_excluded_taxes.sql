-- ═══════════════════════════════════════════════════════════════════════════════
-- Quitar impuestos por orden desde la zona de ventas (estilo Square POS)
-- ═══════════════════════════════════════════════════════════════════════════════
--
-- QUÉ HABILITA
--   El cajero abre el bloque de impuestos del carrito y desmarca los que no
--   quiere cobrar en ESA orden. Ejemplo real: el negocio tiene ITBIS 18% +
--   Propina Ley 10%, el cliente pide que le quiten la propina, y hoy no hay
--   forma de hacerlo sin editar el catálogo del producto.
--
-- DÓNDE ENCAJA
--   Los impuestos se deciden en DOS funciones que comparten el mismo WHERE:
--
--     fn_resolve_order_item_tax_profile  → tasa consolidada → oi.tax_rate
--                                          → trigger fn_compute_item_totals
--                                          → oi.subtotal, oi.tax
--     fn_populate_item_tax_lines         → desglose por impuesto en
--                                          order_item_tax_lines
--
--   Ese WHERE ya filtra por is_active, apply_on_<origen> y apply_on_takeout.
--   Esta migración le agrega un cuarto filtro: la exclusión por orden. Las
--   dos funciones TIENEN que filtrar igual — si solo se toca una, la tasa
--   consolidada y el desglose divergen y el ticket deja de cuadrar
--   (exactamente el bug que arregló 20260502_0002 para "para llevar").
--
-- EL RECÁLCULO NO ES NUEVO
--   fn_set_order_excluded_taxes reusa el mismo flujo probado de
--   fn_mark_order_takeout: por cada item re-resolver la tasa, escribirla
--   (el trigger recalcula subtotal/tax), repoblar tax_lines, y al final
--   fn_recalc_order_totals. No se recalcula nada a mano.
--
-- ⚠️ ANTES DE APLICAR
--   La BD viva diverge de las migraciones del repo. Los cuerpos que este
--   archivo reescribe salen de 20260502_0001. Correr PRIMERO la query de
--   verificación en el comentario del final y confirmar que coinciden; si
--   no, hay que rebasar los CREATE OR REPLACE sobre la definición viva.
--
-- ALCANCE FISCAL (decisión del dueño, 2026-08-13)
--   Se permite excluir CUALQUIER impuesto, incluido el ITBIS — igual que
--   Square. Por eso la exclusión queda auditada (quién y cuándo) y solo se
--   admite con la orden abierta: un comprobante fiscal ya emitido no se
--   reescribe. El reporte de impuestos y la factura leen de
--   order_item_tax_lines, así que ambos siguen la exclusión sin cambios.
-- ═══════════════════════════════════════════════════════════════════════════════

-- ───────────────────────────────────────────────────────────────────────────────
-- 1. Tabla de exclusiones
-- ───────────────────────────────────────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS "public"."order_excluded_taxes" (
  "order_id"    uuid NOT NULL REFERENCES "public"."orders"("id") ON DELETE CASCADE,
  "tax_id"      uuid NOT NULL REFERENCES "public"."taxes"("id")  ON DELETE CASCADE,
  "excluded_by" uuid REFERENCES "public"."employees"("id"),
  "excluded_at" timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY ("order_id", "tax_id")
);

COMMENT ON TABLE "public"."order_excluded_taxes" IS
  'Impuestos que NO se cobran en una orden puntual, quitados por el cajero '
  'desde el carrito. La ausencia de fila = el impuesto aplica normalmente. '
  'excluded_by/excluded_at son el rastro de auditoría: al permitirse excluir '
  'el ITBIS, es lo que responde "quién quitó este impuesto" si la DGII pregunta.';

CREATE INDEX IF NOT EXISTS "order_excluded_taxes_order_idx"
  ON "public"."order_excluded_taxes" ("order_id");

ALTER TABLE "public"."order_excluded_taxes" ENABLE ROW LEVEL SECURITY;

-- Lectura/escritura acotada al negocio dueño de la orden. El POS escribe
-- vía RPC (SECURITY DEFINER), pero la app también lee la tabla directo para
-- pintar los checkboxes antes de llamar al RPC.
DROP POLICY IF EXISTS "order_excluded_taxes_select" ON "public"."order_excluded_taxes";
CREATE POLICY "order_excluded_taxes_select"
  ON "public"."order_excluded_taxes" FOR SELECT
  USING (
    EXISTS (
      SELECT 1
      FROM public.orders o
      JOIN public.table_sessions ts ON ts.id = o.session_id
      JOIN public.user_businesses ub ON ub.business_id = ts.business_id
      WHERE o.id = order_excluded_taxes.order_id
        AND ub.user_id = auth.uid()
    )
  );

-- ───────────────────────────────────────────────────────────────────────────────
-- 2. fn_resolve_order_item_tax_profile — respeta la exclusión por orden
--    (base: 20260502_0001; único cambio = el NOT EXISTS del final)
-- ───────────────────────────────────────────────────────────────────────────────
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
    )
    -- NUEVO: impuesto quitado a mano para esta orden.
    AND NOT EXISTS (
      SELECT 1 FROM public.order_excluded_taxes oet
      WHERE oet.order_id = p_order_id AND oet.tax_id = t.id
    );

  RETURN QUERY SELECT coalesce(v_tax_mode, 'exclusive'), coalesce(v_tax_rate, 0);
END;
$$;

GRANT EXECUTE ON FUNCTION "public"."fn_resolve_order_item_tax_profile"("uuid", "uuid", boolean) TO "anon";
GRANT EXECUTE ON FUNCTION "public"."fn_resolve_order_item_tax_profile"("uuid", "uuid", boolean) TO "authenticated";
GRANT EXECUTE ON FUNCTION "public"."fn_resolve_order_item_tax_profile"("uuid", "uuid", boolean) TO "service_role";

-- ───────────────────────────────────────────────────────────────────────────────
-- 3. fn_populate_item_tax_lines — mismo filtro, o el desglose diverge de la tasa
--    (base: 20260502_0001; cambios = v_order_id + el NOT EXISTS del final)
-- ───────────────────────────────────────────────────────────────────────────────
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
  v_order_id uuid;
BEGIN
  SELECT oi.product_id, oi.subtotal, oi.status, coalesce(oi.is_takeout, false),
         trim(lower(ts.origin::text)), ts.business_id, oi.order_id
    INTO v_product_id, v_subtotal, v_status, v_is_takeout, v_origin, v_biz_id, v_order_id
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
    )
    -- NUEVO: mismo filtro que fn_resolve_order_item_tax_profile.
    AND NOT EXISTS (
      SELECT 1 FROM public.order_excluded_taxes oet
      WHERE oet.order_id = v_order_id AND oet.tax_id = t.id
    );
END;
$$;

GRANT EXECUTE ON FUNCTION "public"."fn_populate_item_tax_lines"("uuid") TO "anon";
GRANT EXECUTE ON FUNCTION "public"."fn_populate_item_tax_lines"("uuid") TO "authenticated";
GRANT EXECUTE ON FUNCTION "public"."fn_populate_item_tax_lines"("uuid") TO "service_role";

-- ───────────────────────────────────────────────────────────────────────────────
-- 4. RPC que usa el POS
-- ───────────────────────────────────────────────────────────────────────────────
-- Recibe el conjunto COMPLETO de impuestos excluidos (no un toggle): la app
-- manda el estado final de los checkboxes y esto lo hace verdad. Así dos
-- devices que tocan la misma orden convergen al último estado enviado en vez
-- de acumular toggles cruzados.
CREATE OR REPLACE FUNCTION "public"."fn_set_order_excluded_taxes"(
  "p_order_id" "uuid",
  "p_tax_ids" "uuid"[],
  "p_employee_id" "uuid" DEFAULT NULL
) RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $$
DECLARE
  v_status text;
  v_biz_id uuid;
  v_has_fiscal boolean;
  r record;
  v_product_id uuid;
  v_is_takeout boolean;
  v_tax_mode text;
  v_tax_rate numeric := 0;
BEGIN
  SELECT o.status, ts.business_id
    INTO v_status, v_biz_id
  FROM public.orders o
  JOIN public.table_sessions ts ON ts.id = o.session_id
  WHERE o.id = p_order_id;

  IF v_biz_id IS NULL THEN
    RAISE EXCEPTION 'Orden no encontrada';
  END IF;

  -- Una orden cobrada o anulada no se toca: sus impuestos ya se declararon.
  IF v_status IN ('paid', 'void', 'cancelled') THEN
    RAISE EXCEPTION 'No se pueden cambiar los impuestos de una orden % ', v_status;
  END IF;

  -- Y si ya hay comprobante fiscal emitido, tampoco: reescribir el impuesto
  -- de un NCF vivo deja el papel entregado al cliente sin respaldo en BD.
  SELECT EXISTS (
    SELECT 1 FROM public.fiscal_documents fd
    WHERE fd.order_id = p_order_id
      AND coalesce(fd.status, '') NOT IN ('void', 'cancelled', 'annulled')
  ) INTO v_has_fiscal;

  IF v_has_fiscal THEN
    RAISE EXCEPTION 'La orden ya tiene un comprobante fiscal emitido';
  END IF;

  -- Estado final: borrar lo que ya no está excluido, insertar lo nuevo.
  DELETE FROM public.order_excluded_taxes
   WHERE order_id = p_order_id
     AND (p_tax_ids IS NULL OR NOT (tax_id = ANY(p_tax_ids)));

  IF p_tax_ids IS NOT NULL AND array_length(p_tax_ids, 1) > 0 THEN
    INSERT INTO public.order_excluded_taxes (order_id, tax_id, excluded_by)
    SELECT p_order_id, t.id, p_employee_id
      FROM public.taxes t
     WHERE t.id = ANY(p_tax_ids)
       AND t.business_id = v_biz_id
    ON CONFLICT (order_id, tax_id) DO NOTHING;
  END IF;

  -- Mismo recálculo que fn_mark_order_takeout: por item re-resolver la tasa,
  -- escribirla (el trigger recalcula subtotal/tax) y repoblar el desglose.
  FOR r IN
    SELECT id, product_id, coalesce(is_takeout, false) AS is_takeout
      FROM public.order_items
     WHERE order_id = p_order_id
       AND status IS DISTINCT FROM 'void'
  LOOP
    v_product_id := r.product_id;
    v_is_takeout := r.is_takeout;

    IF v_product_id IS NULL THEN
      CONTINUE;
    END IF;

    SELECT profile.tax_mode, profile.tax_rate
      INTO v_tax_mode, v_tax_rate
    FROM public.fn_resolve_order_item_tax_profile(
      v_product_id, p_order_id, v_is_takeout
    ) profile;

    UPDATE public.order_items
       SET tax_rate = coalesce(v_tax_rate, 0),
           original_tax_rate = coalesce(v_tax_rate, 0),
           tax_mode = coalesce(v_tax_mode, tax_mode)
     WHERE id = r.id;

    PERFORM public.fn_populate_item_tax_lines(r.id);
  END LOOP;

  PERFORM public.fn_recalc_order_totals(p_order_id);
END;
$$;

GRANT EXECUTE ON FUNCTION "public"."fn_set_order_excluded_taxes"("uuid", "uuid"[], "uuid") TO "anon";
GRANT EXECUTE ON FUNCTION "public"."fn_set_order_excluded_taxes"("uuid", "uuid"[], "uuid") TO "authenticated";
GRANT EXECUTE ON FUNCTION "public"."fn_set_order_excluded_taxes"("uuid", "uuid"[], "uuid") TO "service_role";

-- ═══════════════════════════════════════════════════════════════════════════════
-- VERIFICACIÓN PREVIA — correr ANTES de aplicar esta migración
-- ═══════════════════════════════════════════════════════════════════════════════
-- Confirma que los cuerpos vivos de las dos funciones que se reescriben son
-- los de 20260502_0001. Si difieren, NO aplicar: hay que rebasar los CREATE
-- OR REPLACE sobre lo que hay en producción.
--
--   SELECT p.proname,
--          pg_get_functiondef(p.oid) AS definicion_viva
--     FROM pg_proc p
--     JOIN pg_namespace n ON n.oid = p.pronamespace
--    WHERE n.nspname = 'public'
--      AND p.proname IN (
--            'fn_resolve_order_item_tax_profile',
--            'fn_populate_item_tax_lines',
--            'fn_recalc_order_totals',
--            'fn_mark_order_takeout'
--          )
--    ORDER BY p.proname;
--
-- Señales de que SÍ es la versión esperada:
--   · ambas mencionan `apply_on_takeout`
--   · ninguna menciona `order_excluded_taxes` (si ya la menciona, la
--     migración se aplicó antes)
--   · `fn_recalc_order_totals` existe (esta migración la invoca)
-- ═══════════════════════════════════════════════════════════════════════════════
