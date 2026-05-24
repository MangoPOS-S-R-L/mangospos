-- ═══════════════════════════════════════════════════════════════════════════
-- FIX: Toggle "para llevar" no recomputa impuestos
-- ═══════════════════════════════════════════════════════════════════════════
--
-- BUG: fn_toggle_item_takeout y fn_mark_order_takeout solo hacen UPDATE de
--      is_takeout SIN recomputar tax_rate ni tax_lines. Resultado: el item
--      queda marcado para llevar pero el total sigue cobrando el 10% Ley.
--
-- CAUSA: la migracion 20260502_0002_toggle_takeout_recompute.sql NO se
--        aplico realmente en la BD (o fue revertida). schema.sql todavia
--        muestra las versiones simples (solo UPDATE).
--
-- FIX: re-aplicar la migracion + backfill opcional de items takeout
--      existentes para que reflejen el nuevo calculo.
--
-- USO:
--   1. Supabase Studio -> SQL Editor -> New query
--   2. Pegar ESTE SCRIPT COMPLETO
--   3. Run -> corre dentro de BEGIN/ROLLBACK al final, ves verificacion
--      pero no aplica nada
--   4. Si las verificaciones se ven bien, cambia "ROLLBACK;" final a "COMMIT;"
--      y corre otra vez
-- ═══════════════════════════════════════════════════════════════════════════

BEGIN;

-- ═══════════════════════════════════════════════════════════════════════════
-- 1. fn_toggle_item_takeout — version con recompute
-- ═══════════════════════════════════════════════════════════════════════════

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
  SELECT order_id, product_id
    INTO v_order_id, v_product_id
  FROM public.order_items
  WHERE id = p_item_id;

  IF v_order_id IS NULL THEN
    RETURN;
  END IF;

  -- Re-resolver rate considerando el nuevo flag de takeout. Esto consulta
  -- la columna taxes.apply_on_takeout per tax. Si la migracion 0001 no
  -- esta aplicada esta llamada falla con "column does not exist".
  SELECT profile.tax_mode, profile.tax_rate
    INTO v_tax_mode, v_tax_rate
  FROM public.fn_resolve_order_item_tax_profile(
    v_product_id, v_order_id, coalesce(p_takeout, false)
  ) profile;

  -- Update en un solo statement. fn_compute_item_totals trigger recalcula
  -- oi.subtotal y oi.tax usando la nueva tax_rate.
  UPDATE public.order_items
     SET is_takeout = p_takeout,
         tax_rate = coalesce(v_tax_rate, 0),
         original_tax_rate = coalesce(v_tax_rate, 0),
         tax_mode = coalesce(v_tax_mode, tax_mode)
   WHERE id = p_item_id;

  -- Repoblar tax_lines (ya filtra por is_takeout via migracion 0001).
  PERFORM public.fn_populate_item_tax_lines(p_item_id);

  -- Recalcular totales de la orden.
  PERFORM public.fn_recalc_order_totals(v_order_id);
END;
$$;

GRANT EXECUTE ON FUNCTION "public"."fn_toggle_item_takeout"("uuid", boolean) TO "anon";
GRANT EXECUTE ON FUNCTION "public"."fn_toggle_item_takeout"("uuid", boolean) TO "authenticated";
GRANT EXECUTE ON FUNCTION "public"."fn_toggle_item_takeout"("uuid", boolean) TO "service_role";

-- ═══════════════════════════════════════════════════════════════════════════
-- 2. fn_mark_order_takeout — iterar y reusar el toggle individual
-- ═══════════════════════════════════════════════════════════════════════════

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
  FOR r IN
    SELECT id FROM public.order_items
    WHERE order_id = p_order_id
      AND status NOT IN ('paid', 'void')  -- no tocar items ya cerrados
  LOOP
    PERFORM public.fn_toggle_item_takeout(r.id, p_takeout);
  END LOOP;
END;
$$;

GRANT EXECUTE ON FUNCTION "public"."fn_mark_order_takeout"("uuid", boolean) TO "anon";
GRANT EXECUTE ON FUNCTION "public"."fn_mark_order_takeout"("uuid", boolean) TO "authenticated";
GRANT EXECUTE ON FUNCTION "public"."fn_mark_order_takeout"("uuid", boolean) TO "service_role";

-- ═══════════════════════════════════════════════════════════════════════════
-- 3. VERIFICACION — confirmar que las funciones tienen el cuerpo nuevo
-- ═══════════════════════════════════════════════════════════════════════════

\echo '── fn_toggle_item_takeout (debe contener fn_resolve_order_item_tax_profile) ──'

SELECT CASE
  WHEN pg_get_functiondef(oid) LIKE '%fn_resolve_order_item_tax_profile%'
       AND pg_get_functiondef(oid) LIKE '%fn_populate_item_tax_lines%'
       AND pg_get_functiondef(oid) LIKE '%fn_recalc_order_totals%'
    THEN '✓ OK — version con recompute'
  ELSE '✗ FAIL — version vieja, no se aplico el CREATE OR REPLACE'
END AS status
FROM pg_proc
WHERE proname = 'fn_toggle_item_takeout'
  AND pronamespace = 'public'::regnamespace;

\echo '── columna taxes.apply_on_takeout (migracion 0001) ──'

SELECT CASE
  WHEN EXISTS (
    SELECT 1 FROM information_schema.columns
    WHERE table_schema='public' AND table_name='taxes'
      AND column_name='apply_on_takeout'
  )
    THEN '✓ OK — columna existe (migracion 0001 aplicada)'
  ELSE '✗ FAIL — falta migracion 0001, este fix no va a funcionar'
END AS status;

-- ═══════════════════════════════════════════════════════════════════════════
-- 4. BACKFILL OPCIONAL — recomputar items takeout ABIERTOS para que reflejen
--    el nuevo calculo. Solo toca items con is_takeout=true en ordenes abiertas
--    (status_ext='open') — no toca ordenes cerradas/pagadas (snapshot historico).
--
--    Si NO quieres tocar items existentes (preferis que solo aplique a items
--    nuevos a partir de ahora), comenta este DO block.
-- ═══════════════════════════════════════════════════════════════════════════

DO $$
DECLARE
  r record;
  v_count int := 0;
BEGIN
  FOR r IN
    SELECT oi.id
    FROM public.order_items oi
    JOIN public.orders o ON o.id = oi.order_id
    WHERE oi.is_takeout = true
      AND oi.status NOT IN ('paid', 'void')
      AND o.status_ext = 'open'
  LOOP
    -- Reusa toggle (true,true) que recalcula igual. Idempotente.
    PERFORM public.fn_toggle_item_takeout(r.id, true);
    v_count := v_count + 1;
  END LOOP;
  RAISE NOTICE 'Backfill: % items takeout recomputados', v_count;
END $$;

-- ═══════════════════════════════════════════════════════════════════════════
-- 5. SMOKE TEST — verificar con un item takeout real (si tienes alguno abierto)
-- ═══════════════════════════════════════════════════════════════════════════

\echo '── Items takeout abiertos: tax_lines deben NO incluir taxes con apply_on_takeout=false ──'

SELECT oi.id AS item_id,
       oi.product_name,
       oi.is_takeout,
       oi.tax_rate AS rate_actual,
       oi.subtotal,
       oi.tax,
       oi.subtotal + oi.tax AS gross_calc,
       (SELECT string_agg(t.name || '(' || t.rate || '%)', ', ')
          FROM public.order_item_tax_lines tl
          JOIN public.taxes t ON t.id = tl.tax_id
         WHERE tl.order_item_id = oi.id) AS tax_lines_actuales
FROM public.order_items oi
JOIN public.orders o ON o.id = oi.order_id
WHERE oi.is_takeout = true
  AND oi.status NOT IN ('paid', 'void')
  AND o.status_ext = 'open'
LIMIT 10;

-- ═══════════════════════════════════════════════════════════════════════════
-- Por defecto NO aplica. Si los \echo y verificaciones se ven bien,
-- cambia esta linea a "COMMIT;" y corre otra vez.
-- ═══════════════════════════════════════════════════════════════════════════

ROLLBACK;
-- COMMIT;
