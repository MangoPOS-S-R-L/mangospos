-- =============================================================================
-- File:        99_f2.2_parity_test_PROD_SAFE_v2.sql
-- PRD:         2 (Refactor del Motor de Impuestos)
-- Phase:       F2.4 — QA en producción (ULTRA seguro: rollback total)
-- Author:      Cristian
-- Date:        2026-04-28
--
-- Purpose:
--   Versión 2 del parity test, ahora con dos mejoras críticas:
--
--   1. table_sessions.table_id es NOT NULL → cada test pickea una
--      dining_table existente del mismo business que el producto de
--      prueba.
--
--   2. Cada test envuelto en BEGIN; ... ROLLBACK; → cero persistencia.
--      Las sessions/orders/items/tax_lines que se crean para el test
--      desaparecen al final. Ni siquiera se necesita DELETE explícito.
--      ZERO impacto en datos reales.
--
--   Los RAISE NOTICE se emiten igual aunque haya ROLLBACK (los mensajes
--   no son parte de la transacción).
--
-- Cómo correrlo:
--   - Pegar TODO en el SQL editor de Supabase.
--   - Ejecutar.
--   - Mirar el panel de Notices/Messages.
--   - Esperás 5 líneas con PASS/FAIL/SKIP.
-- =============================================================================


-- -----------------------------------------------------------------------------
-- TEST 1: producto sin menu_item_taxes → todo en cero (cierra bug Agua Dasany).
-- -----------------------------------------------------------------------------
BEGIN;
DO $$
DECLARE
  v_test_business_id uuid;
  v_test_product_id  uuid;
  v_test_table_id    uuid;
  v_test_session_id  uuid;
  v_test_order_id    uuid;
  v_item_id          uuid;
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

  -- Pickeamos una dining_table del mismo business para satisfacer el FK
  SELECT dt.id INTO v_test_table_id
  FROM public.dining_tables dt
  JOIN public.zones z ON z.id = dt.zone_id
  WHERE z.business_id = v_test_business_id
    AND coalesce(dt.is_active, true)
    AND coalesce(z.is_active, true)
  LIMIT 1;

  IF v_test_table_id IS NULL THEN
    RAISE NOTICE 'TEST 1: SKIP — el business no tiene dining_tables';
    RETURN;
  END IF;

  INSERT INTO public.table_sessions(table_id, business_id, origin)
  VALUES (v_test_table_id, v_test_business_id, 'dine_in')
  RETURNING id INTO v_test_session_id;

  INSERT INTO public.orders(session_id, status)
  VALUES (v_test_session_id, 'open')
  RETURNING id INTO v_test_order_id;

  v_item_id := public.fn_add_item_from_menu(
    p_order_id => v_test_order_id,
    p_menu_item_id => v_test_product_id,
    p_qty => 1
  );

  SELECT tax INTO v_oi_tax FROM public.order_items WHERE id = v_item_id;

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
END $$;
ROLLBACK;


-- -----------------------------------------------------------------------------
-- TEST 2: orders.service_fee queda en 0 al crear order de prueba.
-- -----------------------------------------------------------------------------
BEGIN;
DO $$
DECLARE
  v_test_business_id uuid;
  v_test_product_id  uuid;
  v_test_table_id    uuid;
  v_test_session_id  uuid;
  v_test_order_id    uuid;
  v_item_id          uuid;
  v_order_service_fee numeric;
  v_status           text;
BEGIN
  SELECT mi.business_id, mi.id
    INTO v_test_business_id, v_test_product_id
  FROM public.menu_items mi
  JOIN public.menu_item_taxes mit ON mit.item_id = mi.id
  LIMIT 1;

  IF v_test_product_id IS NULL THEN
    RAISE NOTICE 'TEST 2: SKIP — no hay productos con taxes';
    RETURN;
  END IF;

  SELECT dt.id INTO v_test_table_id
  FROM public.dining_tables dt
  JOIN public.zones z ON z.id = dt.zone_id
  WHERE z.business_id = v_test_business_id
    AND coalesce(dt.is_active, true)
    AND coalesce(z.is_active, true)
  LIMIT 1;

  IF v_test_table_id IS NULL THEN
    RAISE NOTICE 'TEST 2: SKIP — el business no tiene dining_tables';
    RETURN;
  END IF;

  INSERT INTO public.table_sessions(table_id, business_id, origin)
  VALUES (v_test_table_id, v_test_business_id, 'dine_in')
  RETURNING id INTO v_test_session_id;

  INSERT INTO public.orders(session_id, status)
  VALUES (v_test_session_id, 'open')
  RETURNING id INTO v_test_order_id;

  v_item_id := public.fn_add_item_from_menu(
    p_order_id => v_test_order_id,
    p_menu_item_id => v_test_product_id,
    p_qty => 1
  );

  SELECT coalesce(service_fee, 0) INTO v_order_service_fee
  FROM public.orders WHERE id = v_test_order_id;

  IF v_order_service_fee = 0 THEN
    v_status := 'PASS';
  ELSE
    v_status := format('FAIL — orders.service_fee debería ser 0; obtuvo %s', v_order_service_fee);
  END IF;

  RAISE NOTICE 'TEST 2 (service_fee = 0 en order nueva): %', v_status;
END $$;
ROLLBACK;


-- -----------------------------------------------------------------------------
-- TEST 3: order_item_tax_lines.amount sumado == order_items.tax (drift < 0.02).
-- -----------------------------------------------------------------------------
BEGIN;
DO $$
DECLARE
  v_test_business_id uuid;
  v_test_product_id  uuid;
  v_test_table_id    uuid;
  v_test_session_id  uuid;
  v_test_order_id    uuid;
  v_item_id          uuid;
  v_oi_tax           numeric;
  v_lines_sum        numeric;
  v_drift            numeric;
  v_status           text;
BEGIN
  SELECT mi.business_id, mi.id
    INTO v_test_business_id, v_test_product_id
  FROM public.menu_items mi
  JOIN public.menu_item_taxes mit ON mit.item_id = mi.id
  LIMIT 1;

  IF v_test_product_id IS NULL THEN
    RAISE NOTICE 'TEST 3: SKIP — no hay productos con taxes';
    RETURN;
  END IF;

  SELECT dt.id INTO v_test_table_id
  FROM public.dining_tables dt
  JOIN public.zones z ON z.id = dt.zone_id
  WHERE z.business_id = v_test_business_id
    AND coalesce(dt.is_active, true)
    AND coalesce(z.is_active, true)
  LIMIT 1;

  IF v_test_table_id IS NULL THEN
    RAISE NOTICE 'TEST 3: SKIP — el business no tiene dining_tables';
    RETURN;
  END IF;

  INSERT INTO public.table_sessions(table_id, business_id, origin)
  VALUES (v_test_table_id, v_test_business_id, 'dine_in')
  RETURNING id INTO v_test_session_id;

  INSERT INTO public.orders(session_id, status)
  VALUES (v_test_session_id, 'open')
  RETURNING id INTO v_test_order_id;

  v_item_id := public.fn_add_item_from_menu(
    p_order_id => v_test_order_id,
    p_menu_item_id => v_test_product_id,
    p_qty => 1
  );

  SELECT tax INTO v_oi_tax FROM public.order_items WHERE id = v_item_id;

  SELECT coalesce(SUM(amount), 0) INTO v_lines_sum
  FROM public.order_item_tax_lines
  WHERE order_item_id = v_item_id;

  v_drift := abs(v_oi_tax - v_lines_sum);

  IF v_drift <= 0.02 THEN
    v_status := format('PASS — oi.tax=%s, sum(lines)=%s, drift=%s', v_oi_tax, v_lines_sum, v_drift);
  ELSE
    v_status := format('FAIL — drift=%s (oi.tax=%s, sum(lines)=%s)', v_drift, v_oi_tax, v_lines_sum);
  END IF;

  RAISE NOTICE 'TEST 3 (tax_lines == oi.tax): %', v_status;
END $$;
ROLLBACK;


-- -----------------------------------------------------------------------------
-- TEST 4: self_service en fn_add_item_from_menu lanza excepción (fail-loud).
-- -----------------------------------------------------------------------------
BEGIN;
DO $$
DECLARE
  v_test_business_id uuid;
  v_test_product_id  uuid;
  v_test_table_id    uuid;
  v_test_session_id  uuid;
  v_test_order_id    uuid;
  v_status           text := 'FAIL — no lanzó excepción';
BEGIN
  SELECT mi.business_id, mi.id
    INTO v_test_business_id, v_test_product_id
  FROM public.menu_items mi
  JOIN public.menu_item_taxes mit ON mit.item_id = mi.id
  LIMIT 1;

  IF v_test_product_id IS NULL THEN
    RAISE NOTICE 'TEST 4: SKIP — no hay productos con taxes';
    RETURN;
  END IF;

  SELECT dt.id INTO v_test_table_id
  FROM public.dining_tables dt
  JOIN public.zones z ON z.id = dt.zone_id
  WHERE z.business_id = v_test_business_id
    AND coalesce(dt.is_active, true)
    AND coalesce(z.is_active, true)
  LIMIT 1;

  IF v_test_table_id IS NULL THEN
    RAISE NOTICE 'TEST 4: SKIP — el business no tiene dining_tables';
    RETURN;
  END IF;

  INSERT INTO public.table_sessions(table_id, business_id, origin)
  VALUES (v_test_table_id, v_test_business_id, 'self_service')
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
END $$;
ROLLBACK;


-- -----------------------------------------------------------------------------
-- TEST 5: takeout no genera tax_lines de service_fee.
-- -----------------------------------------------------------------------------
BEGIN;
DO $$
DECLARE
  v_test_business_id uuid;
  v_test_product_id  uuid;
  v_test_table_id    uuid;
  v_test_session_id  uuid;
  v_test_order_id    uuid;
  v_item_id          uuid;
  v_sf_lines_count   integer;
  v_status           text;
BEGIN
  SELECT mi.business_id, mi.id
    INTO v_test_business_id, v_test_product_id
  FROM public.menu_items mi
  JOIN public.menu_item_taxes mit ON mit.item_id = mi.id
  JOIN public.taxes t ON t.id = mit.tax_id
  WHERE coalesce(t.is_service_fee, false) = true
  LIMIT 1;

  IF v_test_product_id IS NULL THEN
    RAISE NOTICE 'TEST 5: SKIP — no hay productos con propina linkeada';
    RETURN;
  END IF;

  SELECT dt.id INTO v_test_table_id
  FROM public.dining_tables dt
  JOIN public.zones z ON z.id = dt.zone_id
  WHERE z.business_id = v_test_business_id
    AND coalesce(dt.is_active, true)
    AND coalesce(z.is_active, true)
  LIMIT 1;

  IF v_test_table_id IS NULL THEN
    RAISE NOTICE 'TEST 5: SKIP — el business no tiene dining_tables';
    RETURN;
  END IF;

  INSERT INTO public.table_sessions(table_id, business_id, origin)
  VALUES (v_test_table_id, v_test_business_id, 'dine_in')
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
END $$;
ROLLBACK;


-- =============================================================================
-- Resumen: 5 líneas en panel Notices con PASS/FAIL/SKIP.
-- Cero persistencia: los 5 BEGIN/ROLLBACK garantizan que ninguna sesión,
-- order, item ni tax_line creada para los tests sobreviva.
-- =============================================================================
