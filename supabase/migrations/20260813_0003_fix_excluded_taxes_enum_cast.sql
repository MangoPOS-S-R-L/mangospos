-- =============================================================================
-- 20260813_0003 — Fix: fn_set_order_excluded_taxes reventaba con
--                 "invalid input value for enum item_status" (22P02)
-- =============================================================================
--
-- SÍNTOMA: al quitar un impuesto de una orden, el POS mostraba
--   `PostgrestException(message: invalid input value for enum item_status: "",
--    code: 22P02)` y no se cambiaba nada.
--
-- CAUSA: el bucle que recorre los items filtraba con
--
--     AND coalesce(status, '') <> 'void'
--
--   pero `order_items.status` es del enum `public.item_status`, no texto. El
--   `coalesce` obliga a Postgres a convertir el literal '' a `item_status`
--   para poder compararlo, y '' no es un valor del enum
--   ('pending','preparing','ready','served','void','draft'). Revienta SIEMPRE,
--   tenga o no la orden algún item con status NULL.
--
-- FIX: `status IS DISTINCT FROM 'void'`. Es equivalente al intento original
--   —NULL también entra, igual que con el coalesce— y compara enum contra
--   enum sin castear nada.
--
-- ALCANCE: solo esta función. Se reemplaza completa porque
--   `CREATE OR REPLACE` no admite parches parciales; el resto del cuerpo es
--   idéntico al de 20260813_0002 (que también quedó corregido en el repo para
--   que una instalación nueva no reintroduzca el bug).
--
-- ANTES DE APLICAR, confirmar que la definición viva coincide con la del repo
-- (esta base diverge de las migraciones más de una vez):
--
--   SELECT pg_get_functiondef('public.fn_set_order_excluded_taxes'::regproc);
--
-- IDEMPOTENTE: CREATE OR REPLACE.
-- =============================================================================

begin;

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

commit;

-- =============================================================================
-- VERIFICACIÓN
-- =============================================================================
-- 1) La definición viva ya no debe tener el coalesce sobre el enum.
--    Esperado: 0 filas.
-- SELECT 1
--   FROM pg_proc p
--  WHERE p.proname = 'fn_set_order_excluded_taxes'
--    AND pg_get_functiondef(p.oid) LIKE '%coalesce(status,%';
--
-- 2) Prueba en vivo sobre una orden ABIERTA (cambia el uuid). Debe devolver
--    sin error; para revertir, volver a llamarla con array vacío.
-- SELECT public.fn_set_order_excluded_taxes(
--          '00000000-0000-0000-0000-000000000000'::uuid,
--          ARRAY[]::uuid[],
--          NULL
--        );
-- =============================================================================
