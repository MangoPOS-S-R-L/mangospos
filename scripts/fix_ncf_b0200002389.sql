-- ============================================================================
-- Corrector: NCF B0200002389 + raíz del problema (LEY mal configurada)
-- ============================================================================
-- Causa raíz: LEY tiene is_service_fee=false en la tabla `taxes`. El motor
-- la trata como impuesto regular y la suma a items.tax_rate, dejando los
-- comprobantes con la propina enmascarada como ITBIS o como tax combinado.
--
-- Estrategia:
--   1. Marcar LEY como is_service_fee=true → el motor la separa de aquí
--      en adelante.
--   2. Re-clasificar items que tenían tax_rate=10 (eran propina,
--      no ITBIS): tax_rate=0, tax=0. La propina la asume orders.service_fee.
--   3. Recomputar orders.tax y orders.service_fee usando
--      calculate_order_totals (single source of truth).
--   4. Refrescar fiscal_documents desde orders (itbis_amount, service_fee).
--
-- Idempotente: tras la primera corrida, no quedan items con tax_rate=10
-- ni LEY con is_service_fee=false → segunda corrida no produce changes.
--
-- Cobertura: aplica a TODOS los comprobantes activos del negocio que
-- tienen items rate=10 baked. Si solo quieres tocar B0200002389, edita
-- el WHERE indicado abajo.
-- ============================================================================

DO $$
DECLARE
  v_business_id   uuid;
  v_ley_id        uuid;
  v_items_fixed   integer := 0;
  v_orders_fixed  integer := 0;
  v_docs_fixed    integer := 0;
  o_id            uuid;
BEGIN
  -- ─── Resolver business_id desde el NCF B0200002389 ───────────────────
  SELECT ts.business_id, t.id
    INTO v_business_id, v_ley_id
  FROM public.fiscal_documents fd
  JOIN public.orders o ON o.id = fd.order_id
  JOIN public.table_sessions ts ON ts.id = o.session_id
  JOIN public.taxes t ON t.business_id = ts.business_id
  WHERE fd.ncf_number = 'B0200002389'
    AND lower(t.name) = 'ley'
    AND coalesce(t.is_active, true)
  LIMIT 1;

  IF v_business_id IS NULL THEN
    RAISE EXCEPTION 'No se encontró NCF B0200002389 o el tax LEY del negocio';
  END IF;

  RAISE NOTICE 'business_id: %, tax LEY id: %', v_business_id, v_ley_id;

  -- ─── Step 1: Marcar LEY como is_service_fee=true ─────────────────────
  -- Causa raíz: con esto el motor (fn_resolve_order_item_tax_profile)
  -- la excluye del tax_rate de items, y calculate_order_totals la
  -- aplica como service_fee separado.
  UPDATE public.taxes
  SET is_service_fee = true
  WHERE id = v_ley_id;

  RAISE NOTICE 'Step 1: LEY marcada como is_service_fee=true';

  -- ─── Step 2: Re-clasificar order_items afectados ─────────────────────
  -- Items con tax_rate ≈ 10 son propina baked. Los volvemos a 0 para
  -- que el motor recompute correctamente en step 3.
  --
  -- Si quieres limitar el fix SOLO al NCF B0200002389, descomenta el
  -- AND oi.order_id IN (...) y comenta el filtro por business_id.
  CREATE TEMP TABLE _affected_orders (
    order_id uuid PRIMARY KEY
  ) ON COMMIT DROP;

  WITH targeted AS (
    UPDATE public.order_items oi
    SET
      tax_rate = 0,
      tax      = 0,
      total    = ROUND(oi.subtotal - COALESCE(oi.discounts, 0), 2)
    FROM public.orders o
    JOIN public.table_sessions ts ON ts.id = o.session_id
    WHERE oi.order_id = o.id
      AND ts.business_id = v_business_id
      AND oi.tax_rate BETWEEN 9.99 AND 10.01
      AND oi.status IS DISTINCT FROM 'void'::public.item_status
      AND oi.subtotal > 0
      AND ABS(oi.tax - oi.subtotal * 0.10) < 0.05
      -- Para limitar a UNA SOLA orden, descomenta esta línea:
      -- AND oi.order_id = (SELECT order_id FROM public.fiscal_documents WHERE ncf_number = 'B0200002389')
    RETURNING oi.id, oi.order_id
  )
  INSERT INTO _affected_orders (order_id)
  SELECT DISTINCT order_id FROM targeted
  ON CONFLICT (order_id) DO NOTHING;

  GET DIAGNOSTICS v_items_fixed = ROW_COUNT;
  RAISE NOTICE 'Step 2: re-clasificados % items en % órdenes',
    v_items_fixed,
    (SELECT count(*) FROM _affected_orders);

  -- ─── Step 3: Recalcular orders con la engine oficial ─────────────────
  -- calculate_order_totals lee items, suma subtotal + tax,
  -- aplica service_fee desde las taxes con is_service_fee=true,
  -- y escribe orders.{subtotal, tax, service_fee, total}.
  FOR o_id IN SELECT order_id FROM _affected_orders LOOP
    PERFORM public.calculate_order_totals(o_id);
    v_orders_fixed := v_orders_fixed + 1;
  END LOOP;

  RAISE NOTICE 'Step 3: recalculadas % órdenes vía calculate_order_totals',
    v_orders_fixed;

  -- ─── Step 4: Refrescar fiscal_documents desde orders ────────────────
  -- Después de step 3, orders tiene los valores correctos. Los
  -- propagamos a fiscal_documents para que el reporte los lea.
  UPDATE public.fiscal_documents fd
  SET
    itbis_amount = o.tax,
    service_fee  = o.service_fee
  FROM public.orders o
  WHERE fd.order_id = o.id
    AND o.id IN (SELECT order_id FROM _affected_orders);

  GET DIAGNOSTICS v_docs_fixed = ROW_COUNT;
  RAISE NOTICE 'Step 4: refrescados % fiscal_documents', v_docs_fixed;

  -- ─── Resumen ──────────────────────────────────────────────────────────
  RAISE NOTICE '═══════════════════════════════════════════════════════════════';
  RAISE NOTICE 'Corrector completo:';
  RAISE NOTICE '  LEY → is_service_fee=true (fix de raíz)';
  RAISE NOTICE '  items re-clasificados   : %', v_items_fixed;
  RAISE NOTICE '  orders recalculadas     : %', v_orders_fixed;
  RAISE NOTICE '  fiscal_documents fixed  : %', v_docs_fixed;
  RAISE NOTICE '═══════════════════════════════════════════════════════════════';
END $$;

-- ─── Verificación post-fix ───────────────────────────────────────────────
-- Corre esto después para confirmar que B0200002389 quedó bien:
SELECT
  fd.ncf_number,
  fd.subtotal,
  fd.itbis_amount,
  fd.service_fee,
  fd.total,
  o.tax        AS order_tax,
  o.service_fee AS order_service_fee
FROM public.fiscal_documents fd
JOIN public.orders o ON o.id = fd.order_id
WHERE fd.ncf_number = 'B0200002389';
-- Esperado:
--   subtotal     = 45.45
--   itbis_amount = 0.00      (no se cobró ITBIS en esa orden)
--   service_fee  = 4.55      (la propina antes estaba en itbis_amount)
--   total        = 50.00     (intacto, no se cambia el cobro)
