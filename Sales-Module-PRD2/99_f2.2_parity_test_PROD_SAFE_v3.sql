-- =============================================================================
-- File:        99_f2.2_parity_test_PROD_SAFE_v3.sql
-- PRD:         2 (Refactor del Motor de Impuestos)
-- Phase:       F2.4 — QA en producción (resultados como filas, no NOTICEs)
-- Author:      Cristian
-- Date:        2026-04-28
--
-- Purpose:
--   Versión 3: el SQL editor de Supabase NO muestra RAISE NOTICE en la UI
--   web. Esta versión persiste los resultados en una TEMP table y al final
--   hace un SELECT que SÍ aparece en el panel "Results".
--
--   Estrategia:
--   - 1 TEMP table `_prd2_results` con (test_no, test_name, status, detail).
--   - 5 DO blocks que crean session+order+item de prueba, verifican,
--     INSERTan resultado y hacen DELETE explícito al final (cascada FK
--     limpia order_items y order_item_tax_lines).
--   - SELECT final que muestra los 5 PASS/FAIL/SKIP en el panel.
--
--   No usa BEGIN/ROLLBACK porque el INSERT a la TEMP table también se
--   revertiría. En su lugar, cada DO limpia explícitamente lo que creó.
--
-- Cómo correrlo:
--   1. Pegar TODO en el SQL editor de Supabase.
--   2. Ejecutar.
--   3. Mirar el panel "Results": deberías ver 5 filas con status.
-- =============================================================================

-- TEMP table que persiste los resultados durante la sesión
DROP TABLE IF EXISTS _prd2_results;
CREATE TEMP TABLE _prd2_results (
  test_no   int,
  test_name text,
  status    text,
  detail    text
);


-- -----------------------------------------------------------------------------
-- TEST 1: producto sin menu_item_taxes → todo en cero (cierra bug Agua Dasany).
-- -----------------------------------------------------------------------------
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
  v_detail           text;
BEGIN
  SELECT mi.business_id, mi.id
    INTO v_test_business_id, v_test_product_id
  FROM public.menu_items mi
  WHERE NOT EXISTS (SELECT 1 FROM public.menu_item_taxes mit WHERE mit.item_id = mi.id)
  LIMIT 1;

  IF v_test_product_id IS NULL THEN
    INSERT INTO _prd2_results VALUES (1, 'producto sin menu_item_taxes en dine_in', 'SKIP', 'no hay productos sin menu_item_taxes');
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
    INSERT INTO _prd2_results VALUES (1, 'producto sin menu_item_taxes en dine_in', 'SKIP', 'el business no tiene dining_tables');
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
    v_detail := format('tax=%s, tax_lines=%s', v_oi_tax, v_tax_lines_count);
  ELSE
    v_status := 'FAIL';
    v_detail := format('esperaba tax=0 y 0 tax_lines; obtuvo tax=%s, tax_lines=%s', v_oi_tax, v_tax_lines_count);
  END IF;

  INSERT INTO _prd2_results VALUES (1, 'producto sin menu_item_taxes en dine_in', v_status, v_detail);

  -- Cleanup (cascada FK borra order_items y order_item_tax_lines)
  DELETE FROM public.orders WHERE id = v_test_order_id;
  DELETE FROM public.table_sessions WHERE id = v_test_session_id;
END $$;


-- -----------------------------------------------------------------------------
-- TEST 2: orders.service_fee queda en 0 al crear order de prueba.
-- -----------------------------------------------------------------------------
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
  v_detail           text;
BEGIN
  -- Pickeamos producto + dining_table del MISMO business en una sola query
  -- para evitar SKIPs por businesses sin mesas.
  SELECT mi.business_id, mi.id, dt.id
    INTO v_test_business_id, v_test_product_id, v_test_table_id
  FROM public.menu_items mi
  JOIN public.menu_item_taxes mit ON mit.item_id = mi.id
  JOIN public.zones z          ON z.business_id = mi.business_id
                              AND coalesce(z.is_active, true)
  JOIN public.dining_tables dt ON dt.zone_id = z.id
                              AND coalesce(dt.is_active, true)
  LIMIT 1;

  IF v_test_product_id IS NULL OR v_test_table_id IS NULL THEN
    INSERT INTO _prd2_results VALUES (2, 'service_fee=0 en order nueva', 'SKIP', 'no hay producto con taxes en business con dining_tables activas');
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
    v_detail := format('service_fee=%s', v_order_service_fee);
  ELSE
    v_status := 'FAIL';
    v_detail := format('orders.service_fee debería ser 0; obtuvo %s', v_order_service_fee);
  END IF;

  INSERT INTO _prd2_results VALUES (2, 'service_fee=0 en order nueva', v_status, v_detail);

  DELETE FROM public.orders WHERE id = v_test_order_id;
  DELETE FROM public.table_sessions WHERE id = v_test_session_id;
END $$;


-- -----------------------------------------------------------------------------
-- TEST 3: order_item_tax_lines.amount sumado == order_items.tax (drift < 0.02).
-- -----------------------------------------------------------------------------
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
  v_detail           text;
BEGIN
  -- Pickeamos producto + dining_table del MISMO business en una sola query
  -- para evitar SKIPs por businesses sin mesas.
  SELECT mi.business_id, mi.id, dt.id
    INTO v_test_business_id, v_test_product_id, v_test_table_id
  FROM public.menu_items mi
  JOIN public.menu_item_taxes mit ON mit.item_id = mi.id
  JOIN public.zones z          ON z.business_id = mi.business_id
                              AND coalesce(z.is_active, true)
  JOIN public.dining_tables dt ON dt.zone_id = z.id
                              AND coalesce(dt.is_active, true)
  LIMIT 1;

  IF v_test_product_id IS NULL OR v_test_table_id IS NULL THEN
    INSERT INTO _prd2_results VALUES (3, 'tax_lines == oi.tax', 'SKIP', 'no hay producto con taxes en business con dining_tables activas');
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
    v_status := 'PASS';
  ELSE
    v_status := 'FAIL';
  END IF;
  v_detail := format('oi.tax=%s, sum(lines)=%s, drift=%s', v_oi_tax, v_lines_sum, v_drift);

  INSERT INTO _prd2_results VALUES (3, 'tax_lines == oi.tax', v_status, v_detail);

  DELETE FROM public.orders WHERE id = v_test_order_id;
  DELETE FROM public.table_sessions WHERE id = v_test_session_id;
END $$;


-- -----------------------------------------------------------------------------
-- TEST 4: self_service en fn_add_item_from_menu lanza excepción (fail-loud).
-- -----------------------------------------------------------------------------
DO $$
DECLARE
  v_test_business_id uuid;
  v_test_product_id  uuid;
  v_test_table_id    uuid;
  v_test_session_id  uuid;
  v_test_order_id    uuid;
  v_status           text := 'FAIL';
  v_detail           text := 'no lanzó excepción';
BEGIN
  -- Pickeamos producto + dining_table del MISMO business en una sola query
  -- para evitar SKIPs por businesses sin mesas.
  SELECT mi.business_id, mi.id, dt.id
    INTO v_test_business_id, v_test_product_id, v_test_table_id
  FROM public.menu_items mi
  JOIN public.menu_item_taxes mit ON mit.item_id = mi.id
  JOIN public.zones z          ON z.business_id = mi.business_id
                              AND coalesce(z.is_active, true)
  JOIN public.dining_tables dt ON dt.zone_id = z.id
                              AND coalesce(dt.is_active, true)
  LIMIT 1;

  IF v_test_product_id IS NULL OR v_test_table_id IS NULL THEN
    INSERT INTO _prd2_results VALUES (4, 'self_service fail-loud', 'SKIP', 'no hay producto con taxes en business con dining_tables activas');
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
        v_detail := 'excepción esperada lanzada correctamente';
      ELSE
        v_status := 'FAIL';
        v_detail := format('excepción inesperada: %s', SQLERRM);
      END IF;
  END;

  INSERT INTO _prd2_results VALUES (4, 'self_service fail-loud', v_status, v_detail);

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
  v_test_table_id    uuid;
  v_test_session_id  uuid;
  v_test_order_id    uuid;
  v_item_id          uuid;
  v_sf_lines_count   integer;
  v_status           text;
  v_detail           text;
BEGIN
  SELECT mi.business_id, mi.id
    INTO v_test_business_id, v_test_product_id
  FROM public.menu_items mi
  JOIN public.menu_item_taxes mit ON mit.item_id = mi.id
  JOIN public.taxes t ON t.id = mit.tax_id
  WHERE coalesce(t.is_service_fee, false) = true
  LIMIT 1;

  IF v_test_product_id IS NULL THEN
    INSERT INTO _prd2_results VALUES (5, 'takeout sin service_fee', 'SKIP', 'no hay productos con propina linkeada');
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
    INSERT INTO _prd2_results VALUES (5, 'takeout sin service_fee', 'SKIP', 'el business no tiene dining_tables');
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
    v_detail := 'takeout no generó tax_lines de service_fee';
  ELSE
    v_status := 'FAIL';
    v_detail := format('takeout generó %s tax_lines de service_fee', v_sf_lines_count);
  END IF;

  INSERT INTO _prd2_results VALUES (5, 'takeout sin service_fee', v_status, v_detail);

  DELETE FROM public.orders WHERE id = v_test_order_id;
  DELETE FROM public.table_sessions WHERE id = v_test_session_id;
END $$;


-- =============================================================================
-- Resumen final: 5 filas en panel "Results"
-- =============================================================================
SELECT * FROM _prd2_results ORDER BY test_no;
