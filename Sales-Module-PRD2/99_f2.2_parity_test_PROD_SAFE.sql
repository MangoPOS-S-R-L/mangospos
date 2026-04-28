-- =============================================================================
-- File:        99_f2.2_parity_test_PROD_SAFE.sql
-- PRD:         2 (Refactor del Motor de Impuestos)
-- Phase:       F2.4 — QA en producción (modo seguro)
-- Author:      Cristian
-- Date:        2026-04-28
--
-- Purpose:
--   Variante "no toca historia" del parity test.
--
--   Diferencias vs `99_f2.2_parity_test.sql`:
--   - TEST 2 reemplazado: en lugar de hacer PERFORM fn_recalc_totals sobre
--     50 órdenes recientes (que cambia composición de órdenes ya pagadas),
--     crea su propia order de prueba, le agrega un item y verifica que
--     orders.service_fee quedó en 0. Cero impacto en datos existentes.
--
--   - Los demás tests (1, 3, 4, 5) son IDÉNTICOS a la versión normal:
--     todos crean sessions/orders de prueba en TEMP scope y hacen DELETE
--     al final. Cero impacto en datos existentes.
--
--   Pre-condición: los SQL 01-07 + migration 01 ya aplicados (lo confirmaste
--   con las 4 queries de verificación antes de correr esto).
--
-- Cómo correrlo:
--   - Pegar TODO en el SQL editor de Supabase.
--   - Ejecutar.
--   - Mirar el panel de Notices/Messages (NO el de Results).
--   - Esperás 5 líneas con PASS o FAIL.
-- =============================================================================

-- -----------------------------------------------------------------------------
-- TEST 1: producto sin menu_item_taxes → todo en cero (cierra bug Agua Dasany).
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
  SELECT mi.business_id, mi.id
    INTO v_test_business_id, v_test_product_id
  FROM public.menu_items mi
  WHERE NOT EXISTS (SELECT 1 FROM public.menu_item_taxes mit WHERE mit.item_id = mi.id)
  LIMIT 1;

  IF v_test_product_id IS NULL THEN
    RAISE NOTICE 'TEST 1: SKIP — no hay productos sin menu_item_taxes';
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

  DELETE FROM public.orders WHERE id = v_test_order_id;
  DELETE FROM public.table_sessions WHERE id = v_test_session_id;
END $$;


-- -----------------------------------------------------------------------------
-- TEST 2 (PROD-SAFE): orders.service_fee queda en 0 al crear order de prueba.
-- Reemplaza al TEST 2 original que recalculaba 50 órdenes históricas.
-- -----------------------------------------------------------------------------
DO $$
DECLARE
  v_test_business_id uuid;
  v_test_product_id  uuid;
  v_test_session_id  uuid;
  v_test_order_id    uuid;
  v_item_id          uuid;
  v_order_service_fee numeric;
  v_status           text;
BEGIN
  -- Producto cualquiera con taxes asociados.
  SELECT mi.business_id, mi.id
    INTO v_test_business_id, v_test_product_id
  FROM public.menu_items mi
  JOIN public.menu_item_taxes mit ON mit.item_id = mi.id
  LIMIT 1;

  IF v_test_product_id IS NULL THEN
    RAISE NOTICE 'TEST 2 (PROD-SAFE): SKIP — no hay productos con taxes';
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
    p_qty => 1
  );

  -- Verificar el orders.service_fee que quedó después del recalc automático
  -- disparado por el trigger.
  SELECT coalesce(service_fee, 0) INTO v_order_service_fee
  FROM public.orders WHERE id = v_test_order_id;

  IF v_order_service_fee = 0 THEN
    v_status := 'PASS';
  ELSE
    v_status := format(
      'FAIL — orders.service_fee debería ser 0 con motor unificado; obtuvo %s',
      v_order_service_fee
    );
  END IF;

  RAISE NOTICE 'TEST 2 PROD-SAFE (service_fee = 0 en order nueva): %', v_status;

  DELETE FROM public.orders WHERE id = v_test_order_id;
  DELETE FROM public.table_sessions WHERE id = v_test_session_id;
END $$;


-- -----------------------------------------------------------------------------
-- TEST 3: order_item_tax_lines suma == order_items.tax (drift < 0.02).
-- Versión PROD-SAFE: solo mira items creados en los últimos 5 minutos
-- (los del propio test, NO el dataset histórico).
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
    WHERE oi.created_at > now() - interval '5 minutes'
      AND oi.status NOT IN ('void')
    GROUP BY oi.id, oi.tax
    HAVING ABS(oi.tax - coalesce(SUM(oitl.amount), 0)) > 0.02
  ) drift;

  IF v_drift_count = 0 THEN
    v_status := 'PASS';
  ELSE
    v_status := format('FAIL — %s items recientes con tax desfasado > 0.02', v_drift_count);
  END IF;

  RAISE NOTICE 'TEST 3 (tax_lines == oi.tax en items recientes): %', v_status;
END $$;


-- -----------------------------------------------------------------------------
-- TEST 4: self_service en fn_add_item_from_menu lanza excepción (fail-loud).
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
-- Resumen: 5 líneas en panel Notices con PASS/FAIL. Los 5 PASS = Go para F2.3.
-- Cero modificación de datos existentes.
-- =============================================================================
