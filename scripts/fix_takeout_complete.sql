-- ═══════════════════════════════════════════════════════════════════════════
-- KILL ALL: TAKEOUT 10% LEY — fix completo, idempotente
-- ═══════════════════════════════════════════════════════════════════════════
--
-- Cubre TODO el chain de "para llevar no debe cobrar la Ley 10%":
--   1. Schema: columna taxes.apply_on_takeout
--   2. Datos:  backfill de taxes existentes (service_fee + nombres tipicos)
--   3. Funciones:
--      a) fn_resolve_order_item_tax_profile (3-arg con p_is_takeout)
--      b) fn_populate_item_tax_lines (lee oi.is_takeout y filtra)
--      c) fn_add_item_from_menu (pasa is_takeout al resolver)
--      d) fn_toggle_item_takeout (recompute completo)
--      e) fn_mark_order_takeout (iterator)
--   4. Backfill: recomputar tax_lines/totales de items takeout abiertos
--
-- USO:
--   1. Supabase Studio -> SQL Editor -> New query
--   2. Pegar SCRIPT COMPLETO
--   3. Run -> corre con BEGIN/ROLLBACK, ves diagnostico ANTES/DESPUES sin
--      aplicar nada
--   4. Si las verificaciones DESPUES son las esperadas, cambia "ROLLBACK;"
--      final a "COMMIT;" y corre otra vez
--
-- businessId: 038bf561-b346-43e8-8dee-25fc84c0fc29 (backfill y smoke test).
-- Las funciones son globales (afectan a todos los businesses).
-- ═══════════════════════════════════════════════════════════════════════════

BEGIN;

-- ───────────────────────────────────────────────────────────────────────────
-- 0a. ANTES: signature de fn_resolve_order_item_tax_profile
--     bug si dice solo: "p_product_id uuid, p_order_id uuid"
--     esperado: "p_product_id uuid, p_order_id uuid, p_is_takeout boolean"
-- ───────────────────────────────────────────────────────────────────────────
SELECT 'ANTES: resolve signature' AS check_name,
       pg_get_function_identity_arguments(oid) AS args
FROM pg_proc
WHERE proname = 'fn_resolve_order_item_tax_profile'
  AND pronamespace = 'public'::regnamespace;

-- ───────────────────────────────────────────────────────────────────────────
-- 0b. ANTES: cuerpo de fn_toggle_item_takeout (primeros 600 chars)
--     bug si NO contiene "fn_resolve_order_item_tax_profile"
-- ───────────────────────────────────────────────────────────────────────────
SELECT 'ANTES: toggle body' AS check_name,
       substring(pg_get_functiondef(oid), 1, 600) AS body
FROM pg_proc
WHERE proname = 'fn_toggle_item_takeout'
  AND pronamespace = 'public'::regnamespace;

-- ───────────────────────────────────────────────────────────────────────────
-- 0c. ANTES: taxes del business
-- ───────────────────────────────────────────────────────────────────────────
SELECT 'ANTES: taxes del business' AS check_name,
       id, name, rate, is_service_fee,
       CASE WHEN EXISTS (
         SELECT 1 FROM information_schema.columns
         WHERE table_schema='public' AND table_name='taxes'
           AND column_name='apply_on_takeout'
       ) THEN 'EXISTE COLUMNA'
         ELSE 'COLUMNA NO EXISTE — falta migracion 0001'
       END AS columna_status
FROM public.taxes
WHERE business_id = '038bf561-b346-43e8-8dee-25fc84c0fc29'
ORDER BY rate DESC;

-- ═══════════════════════════════════════════════════════════════════════════
-- 1. SCHEMA: columna apply_on_takeout
-- ═══════════════════════════════════════════════════════════════════════════

ALTER TABLE public.taxes
  ADD COLUMN IF NOT EXISTS apply_on_takeout boolean NOT NULL DEFAULT true;

COMMENT ON COLUMN public.taxes.apply_on_takeout IS
  'PRD 6: si false el tax NO aplica para items con is_takeout=true. Default true para no romper ITBIS; backfill setea false para is_service_fee=true.';

-- ═══════════════════════════════════════════════════════════════════════════
-- 2. BACKFILL DE DATOS: marcar Ley/Propina/Servicio como NO-takeout
-- ═══════════════════════════════════════════════════════════════════════════

-- 2a) Marcar todos los service fees (cobertura conservadora original)
UPDATE public.taxes
SET apply_on_takeout = false
WHERE coalesce(is_service_fee, false) = true
  AND apply_on_takeout = true;

-- 2b) Cobertura por nombre: cualquier tax llamado "Ley", "Propina" o
--     "Servicio" SOLO del business actual (no tocamos otros businesses).
--     Si tu Ley se llama distinto, agrega el patron aqui.
UPDATE public.taxes
SET apply_on_takeout = false
WHERE business_id = '038bf561-b346-43e8-8dee-25fc84c0fc29'
  AND apply_on_takeout = true
  AND (
    lower(name) LIKE '%ley%'
    OR lower(name) LIKE '%propina%'
    OR lower(name) LIKE '%servicio%'
    OR lower(name) LIKE '%service%'
    OR lower(name) LIKE '%gratuity%'
    OR lower(name) LIKE '%tip%'
  );

-- ═══════════════════════════════════════════════════════════════════════════
-- 3. FUNCIONES (DROP + CREATE para cambiar signatures)
-- ═══════════════════════════════════════════════════════════════════════════

-- 3a. fn_resolve_order_item_tax_profile — SIGNATURE CAMBIA (2 args -> 3 args)
DROP FUNCTION IF EXISTS public.fn_resolve_order_item_tax_profile(uuid, uuid);
DROP FUNCTION IF EXISTS public.fn_resolve_order_item_tax_profile(uuid, uuid, boolean);

CREATE FUNCTION public.fn_resolve_order_item_tax_profile(
  p_product_id uuid,
  p_order_id uuid,
  p_is_takeout boolean DEFAULT false
)
RETURNS TABLE("tax_mode" text, "tax_rate" numeric)
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path TO 'public'
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

GRANT EXECUTE ON FUNCTION public.fn_resolve_order_item_tax_profile(uuid, uuid, boolean) TO anon, authenticated, service_role;

-- 3b. fn_populate_item_tax_lines — lee oi.is_takeout y filtra
CREATE OR REPLACE FUNCTION public.fn_populate_item_tax_lines(p_item_id uuid)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
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

GRANT EXECUTE ON FUNCTION public.fn_populate_item_tax_lines(uuid) TO anon, authenticated, service_role;

-- 3c. fn_add_item_from_menu — pasa p_is_takeout al resolver
CREATE OR REPLACE FUNCTION public.fn_add_item_from_menu(
  p_order_id uuid,
  p_menu_item_id uuid,
  p_qty numeric DEFAULT 1,
  p_check_position integer DEFAULT 1,
  p_is_takeout boolean DEFAULT false,
  p_notes text DEFAULT NULL
) RETURNS uuid
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
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

  -- Pasa is_takeout para que el resolver filtre las leyes/propinas.
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

GRANT EXECUTE ON FUNCTION public.fn_add_item_from_menu(uuid, uuid, numeric, integer, boolean, text) TO anon, authenticated, service_role;

-- 3d. fn_toggle_item_takeout — RECOMPUTE (no solo UPDATE)
CREATE OR REPLACE FUNCTION public.fn_toggle_item_takeout(
  p_item_id uuid,
  p_takeout boolean
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

  -- Re-resolver rate con el nuevo flag de takeout. Esto consulta
  -- taxes.apply_on_takeout por tax.
  SELECT profile.tax_mode, profile.tax_rate
    INTO v_tax_mode, v_tax_rate
  FROM public.fn_resolve_order_item_tax_profile(
    v_product_id, v_order_id, coalesce(p_takeout, false)
  ) profile;

  UPDATE public.order_items
     SET is_takeout = p_takeout,
         tax_rate = coalesce(v_tax_rate, 0),
         original_tax_rate = coalesce(v_tax_rate, 0),
         tax_mode = coalesce(v_tax_mode, tax_mode)
   WHERE id = p_item_id;

  PERFORM public.fn_populate_item_tax_lines(p_item_id);
  PERFORM public.fn_recalc_order_totals(v_order_id);
END;
$$;

GRANT EXECUTE ON FUNCTION public.fn_toggle_item_takeout(uuid, boolean) TO anon, authenticated, service_role;

-- 3e. fn_mark_order_takeout — iterar y reusar el toggle individual
CREATE OR REPLACE FUNCTION public.fn_mark_order_takeout(
  p_order_id uuid,
  p_takeout boolean
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
      AND status NOT IN ('paid', 'void')
  LOOP
    PERFORM public.fn_toggle_item_takeout(r.id, p_takeout);
  END LOOP;
END;
$$;

GRANT EXECUTE ON FUNCTION public.fn_mark_order_takeout(uuid, boolean) TO anon, authenticated, service_role;

-- ═══════════════════════════════════════════════════════════════════════════
-- 4. BACKFILL: recomputar items takeout abiertos del business
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
    JOIN public.table_sessions ts ON ts.id = o.session_id
    WHERE oi.is_takeout = true
      AND oi.status NOT IN ('paid', 'void')
      AND o.status_ext = 'open'
      AND ts.business_id = '038bf561-b346-43e8-8dee-25fc84c0fc29'
  LOOP
    PERFORM public.fn_toggle_item_takeout(r.id, true);
    v_count := v_count + 1;
  END LOOP;
  RAISE NOTICE 'Backfill: % items takeout recomputados', v_count;
END $$;

-- ───────────────────────────────────────────────────────────────────────────
-- 5a. DESPUES: signature de fn_resolve_order_item_tax_profile
--     debe ser: "p_product_id uuid, p_order_id uuid, p_is_takeout boolean"
-- ───────────────────────────────────────────────────────────────────────────
SELECT 'DESPUES: resolve signature' AS check_name,
       pg_get_function_identity_arguments(oid) AS args
FROM pg_proc
WHERE proname = 'fn_resolve_order_item_tax_profile'
  AND pronamespace = 'public'::regnamespace;

-- ───────────────────────────────────────────────────────────────────────────
-- 5b. DESPUES: fn_toggle_item_takeout debe ser "version con recompute"
-- ───────────────────────────────────────────────────────────────────────────
SELECT 'DESPUES: toggle status' AS check_name,
       CASE
         WHEN pg_get_functiondef(oid) LIKE '%fn_resolve_order_item_tax_profile%'
              AND pg_get_functiondef(oid) LIKE '%fn_populate_item_tax_lines%'
              AND pg_get_functiondef(oid) LIKE '%fn_recalc_order_totals%'
           THEN 'OK — version con recompute'
         ELSE 'FAIL — sigue siendo la version vieja'
       END AS status
FROM pg_proc
WHERE proname = 'fn_toggle_item_takeout'
  AND pronamespace = 'public'::regnamespace;

-- ───────────────────────────────────────────────────────────────────────────
-- 5c. DESPUES: taxes del business (Ley/Propina debe tener apply_on_takeout=false)
-- ───────────────────────────────────────────────────────────────────────────
SELECT 'DESPUES: taxes' AS check_name,
       id, name, rate, is_service_fee, apply_on_takeout
FROM public.taxes
WHERE business_id = '038bf561-b346-43e8-8dee-25fc84c0fc29'
ORDER BY rate DESC;

-- ───────────────────────────────────────────────────────────────────────────
-- 5d. DESPUES: items takeout abiertos — tax_lines NO debe incluir Ley/Propina
-- ───────────────────────────────────────────────────────────────────────────
SELECT 'DESPUES: items takeout' AS check_name,
       oi.id AS item_id,
       oi.product_name,
       oi.is_takeout,
       oi.tax_rate,
       oi.subtotal,
       oi.tax,
       oi.subtotal + oi.tax AS gross_calc,
       (SELECT string_agg(t.name || '(' || t.rate || '%)=' || tl.amount, ', ')
          FROM public.order_item_tax_lines tl
          JOIN public.taxes t ON t.id = tl.tax_id
         WHERE tl.order_item_id = oi.id) AS tax_lines
FROM public.order_items oi
JOIN public.orders o ON o.id = oi.order_id
JOIN public.table_sessions ts ON ts.id = o.session_id
WHERE oi.is_takeout = true
  AND oi.status NOT IN ('paid', 'void')
  AND ts.business_id = '038bf561-b346-43e8-8dee-25fc84c0fc29'
LIMIT 20;

-- ═══════════════════════════════════════════════════════════════════════════
-- FINAL: ROLLBACK por defecto. Si las verificaciones DESPUES son las
-- esperadas (Ley con apply_on_takeout=false, tax_lines sin Ley en items
-- takeout, fn_toggle_item_takeout con "OK — version con recompute"),
-- cambia esta linea a "COMMIT;" y corre OTRA VEZ para aplicar real.
-- ═══════════════════════════════════════════════════════════════════════════

ROLLBACK;
-- COMMIT;
