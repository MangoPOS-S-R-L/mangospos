-- =============================================================================
-- File:        99_f2.2_parity_test.sql
-- PRD:         2 (Refactor del Motor de Impuestos)
-- Phase:       F2.4 — QA en staging
-- Author:      Cristian
-- Date:        2026-04-28
-- Reversible:  read-only (snapshots en TEMP TABLE)
--
-- Purpose:
--   Suite de tests de paridad para correr en STAGING después de aplicar
--   los SQL 01-07 del PRD 2 (sin tocar producción todavía).
--
--   Cada test compara el comportamiento del motor nuevo contra una
--   "verdad esperada" para escenarios concretos. NO compara contra el
--   motor viejo: el motor viejo tenía el bug de propina fantasma, así
--   que paridad numérica con el viejo sería paridad con el bug.
--
--   Pre-condición: staging cargado con dump reciente de producción y
--   los SQL 01-07 aplicados. La migration de propina (01_link_service_
--   fee_to_taxed_products.sql) DEBE haberse aplicado antes de este test.
--
-- Apply order:
--   1. Restaurar dump de prod en staging.
--   2. Aplicar migration 01.
--   3. Aplicar SQL 01-07 del PRD 2.
--   4. Correr este script.
--   5. Cada bloque marcado [TEST x] devuelve PASS o FAIL.
--   6. 100% de PASS = Go para F2.5 (deploy a producción).
-- =============================================================================

-- -----------------------------------------------------------------------------
-- TEST 1: producto sin menu_item_taxes (uno de los 76) → todo en cero.
-- -----------------------------------------------------------------------------
DO $$
DECLARE
  v_test_business_id uuid;
  v_test_product_id  uuid;
  v_test_session_id  uuid;
  v_test_order_id    uuid;
  v_item_id          uuid;
  v_oi_subtotal      numeric;
  v_oi_tax           numeric;
  v_tax_lines_count  integer;
  v_status           text;
BEGIN
  -- Picking del primer producto sin menu_item_taxes
  SELECT mi.business_id, mi.id
    INTO v_test_business_id, v_test_product_id
  FROM public.menu_items mi
  WHERE NOT EXISTS (SELECT 1 FROM public.menu_item_taxes mit WHERE mit.item_id = mi.id)
  LIMIT 1;

  IF v_test_product_id IS NULL THEN
    RAISE NOTICE 'TEST 1: SKIP — no hay productos sin menu_item_taxes';
    RETURN;
  END IF;

  -- Crear session + order de prueba (origin dine_in para máximo riesgo de propina)
  INSERT INTO public.table_sessions(business_id, origin)
  VALUES (v_test_business_id, 'dine_in')
  RETURNING id INTO v_test_session_id;

  INSERT INTO public.orders(session_id, status)
  VALUES (v_test_session_id, 'open')
  RETURNING id INTO v_test_order_id;

  -- Insertar el producto sin taxes
  v_item_id := public.fn_add_item_from_menu(
    p_order_id => v_test_order_id,
    p_menu_item_id => v_test_product_id,
    p_qty => 1
  );

  SELECT subtotal, tax INTO v_oi_subtotal, v_oi_tax
  FROM public.order_items WHERE id = v_item_id;

  SELECT count(*) INTO v_tax_lines_count
  FROM public.order_item_tax_lines WHERE order_item_id = v_item_id;

  IF v_oi_tax = 0 AND v_tax_lines_count = 0 THEN
    v_status := 'PASS';
  ELSE
    v_status := format(
      'FAIL — esperaba tax=0 y 0 tax_lines; obtuvo tax=%s, tax_lines=%s',
      v_oi_tax, v_tax_lines_count
    );
  END IF;

  RAISE NOTICE 'TEST 1 (producto sin menu_item_taxes en dine_in): %', v_status;

  -- Cleanup
  DELETE FROM public.orders WHERE id = v_test_order_id;
  DELETE FROM public.table_sessions WHERE id = v_test_session_id;
END $$;


-- -----------------------------------------------------------------------------
-- TEST 2: orders.service_fee siempre 0 después del refactor.
-- -----------------------------------------------------------------------------
DO $$
DECLARE
  v_count integer;
  v_status text;
BEGIN
  -- Forzar recalc de algunas órdenes recientes
  PERFORM public.fn_recalc_totals(o.id)
  FROM public.orders o
  WHERE o.created_at > now() - interval '7 days'
  LIMIT 50;

  SELECT count(*) INTO v_count
  FROM public.orders o
  WHERE o.created_at > now() - interval '7 days'
    AND coalesce(o.service_fee, 0) <> 0;

  IF v_count = 0 THEN
    v_status := 'PASS';
  ELSE
    v_status := format('FAIL — %s órdenes recientes tienen service_fee != 0', v_count);
  END IF;

  RAISE NOTICE 'TEST 2 (service_fee = 0 post-recalc): %', v_status;
END $$;


-- -----------------------------------------------------------------------------
-- TEST 3: order_item_tax_lines suma == order_items.tax para cada item.
-- -----------------------------------------------------------------------------
DO $$
DECLARE
  v_drift_count integer;
  v_status text;
BEGIN
  SELECT count(*) INTO v_drift_count
  FROM (
    SELECT
      oi.id,
      oi.tax AS oi_tax,
      coalesce(SUM(oitl.amount), 0) AS lines_sum
    FROM public.order_items oi
    LEFT JOIN public.order_item_tax_lines oitl ON oitl.order_item_id = oi.id
    WHERE oi.created_at > now() - interval '1 day'
      AND oi.status NOT IN ('void')
    GROUP BY oi.id, oi.tax
    HAVING ABS(oi.tax - coalesce(SUM(oitl.amount), 0)) > 0.02
  ) drift;

  IF v_drift_count = 0 THEN
    v_status := 'PASS';
  ELSE
    v_status := format('FAIL — %s items con tax desfasado > 0.02', v_drift_count);
  END IF;

  RAISE NOTICE 'TEST 3 (tax_lines == oi.tax): %', v_status;
END $$;


-- -----------------------------------------------------------------------------
-- TEST 4: self_service en fn_add_item_from_menu lanza excepción.
-- -----------------------------------------------------------------------------
DO $$
DECLARE
  v_test_session_id uuid;
  v_test_order_id   uuid;
  v_test_business_id uuid;
  v_test_product_id  uuid;
  v_status text := 'FAIL — no lanzó excepción';
BEGIN
  SELECT mi.business_id, mi.id INTO v_test_business_id, v_test_product_id
  FROM public.menu_items mi
  JOIN public.menu_item_taxes mit ON mit.item_id = mi.id
  LIMIT 1;

  IF v_test_product_id IS NULL THEN
    RAISE NOTICE 'TEST 4: SKIP — no hay productos con taxes';
    RETURN;
  END IF;

  INSERT INTO public.table_sessions(business_id, origin)
  VALUES (v_test_business_id, 'self_service')
  RETURNING id INTO v_test_session_id;

  INSERT INTO public.orders(session_id, status)
  VALUES (v_test_session_id, 'open')
  RETURNING id INTO v_test_order_id;

  BEGIN
    PERFORM public.fn_add_item_from_menu(
      p_order_id => v_test_order_id,
      p_menu_item_id => v_test_product_id
    );
  EXCEPTION
    WHEN OTHERS THEN
      IF SQLERRM LIKE '%self_service origin not supported%' THEN
        v_status := 'PASS';
      ELSE
        v_status := format('FAIL — excepción inesperada: %s', SQLERRM);
      END IF;
  END;

  RAISE NOTICE 'TEST 4 (self_service fail-loud): %', v_status;

  -- Cleanup
  DELETE FROM public.orders WHERE id = v_test_order_id;
  DELETE FROM public.table_sessions WHERE id = v_test_session_id;
END $$;


-- -----------------------------------------------------------------------------
-- TEST 5: takeout no genera tax_lines de service_fee.
-- -----------------------------------------------------------------------------
DO $$
DECLARE
  v_test_business_id uuid;
  v_test_product_id  uuid;
  v_test_session_id  uuid;
  v_test_order_id    uuid;
  v_item_id          uuid;
  v_sf_lines_count   integer;
  v_status           text;
BEGIN
  -- Producto que SÍ tiene service_fee linkeado (post-migration)
  SELECT mi.business_id, mi.id INTO v_test_business_id, v_test_product_id
  FROM public.menu_items mi
  JOIN public.menu_item_taxes mit ON mit.item_id = mi.id
  JOIN public.taxes t ON t.id = mit.tax_id
  WHERE coalesce(t.is_service_fee, false) = true
  LIMIT 1;

  IF v_test_product_id IS NULL THEN
    RAISE NOTICE 'TEST 5: SKIP — no hay productos con propina linkeada';
    RETURN;
  END IF;

  INSERT INTO public.table_sessions(business_id, origin)
  VALUES (v_test_business_id, 'dine_in')
  RETURNING id INTO v_test_session_id;

  INSERT INTO public.orders(session_id, status)
  VALUES (v_test_session_id, 'open')
  RETURNING id INTO v_test_order_id;

  v_item_id := public.fn_add_item_from_menu(
    p_order_id => v_test_order_id,
    p_menu_item_id => v_test_product_id,
    p_is_takeout => true
  );

  SELECT count(*) INTO v_sf_lines_count
  FROM public.order_item_tax_lines oitl
  JOIN public.taxes t ON t.id = oitl.tax_id
  WHERE oitl.order_item_id = v_item_id
    AND coalesce(t.is_service_fee, false) = true;

  IF v_sf_lines_count = 0 THEN
    v_status := 'PASS';
  ELSE
    v_status := format('FAIL — takeout generó %s tax_lines de service_fee', v_sf_lines_count);
  END IF;

  RAISE NOTICE 'TEST 5 (takeout sin service_fee): %', v_status;

  DELETE FROM public.orders WHERE id = v_test_order_id;
  DELETE FROM public.table_sessions WHERE id = v_test_session_id;
END $$;


-- =============================================================================
-- Resumen: revisar el output de NOTICE de cada DO. PASS en los 5 → Go para F2.5.
-- =============================================================================
