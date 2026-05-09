-- =============================================================================
-- Backfill: split combined-rate (28%) items into ITBIS 18% + Propina 10%
-- y propagar a orders + fiscal_documents.
--
-- Contexto
-- --------
-- Pre-abril 2026, varios paths del POS guardaban order_items con
-- tax_rate=28 (ITBIS+Ley combinados) y tax = 28% del subtotal,
-- considerándolo "un solo impuesto". La consolidación del 12-abril
-- (20260412_0003) dejó la tax engine consistente — guarda tax_rate=18
-- (solo ITBIS), original_tax_rate=28 (full, para extraer base en
-- inclusive), y trasladó la propina a orders.service_fee vía
-- calculate_order_totals — pero solo recalculó las órdenes ABIERTAS:
--
--     WHERE o.closed_at IS NULL AND o.status_ext NOT IN ('paid','void')
--
-- Las órdenes ya pagadas/cerradas conservaron sus valores viejos:
--   - order_items.tax_rate = 28
--   - order_items.tax      = subtotal * 0.28
--   - orders.tax           = combinado (incluye propina)
--   - orders.service_fee   = 0 (la propina nunca se separó)
--   - fiscal_documents.itbis_amount = combinado
--   - fiscal_documents.service_fee  = 0
--
-- El reporte fiscal lee directo de fiscal_documents → muestra ITBIS
-- inflado en órdenes que tienen el dato consistente, columnas vacías
-- en órdenes pre-consolidación, y propina perdida en todos los
-- comprobantes legacy.
--
-- Esta migración corrige toda la cadena para data histórica.
--
-- Lo que hace
-- -----------
--   1. order_items con tax_rate ≈ 28 y tax ≈ subtotal*0.28:
--      - tax_rate          = 18
--      - tax               = ROUND(subtotal * 0.18, 2)
--      - total             = ROUND(subtotal + tax - discounts, 2)
--      - original_tax_rate = COALESCE(original_tax_rate, 28)
--        (preserva el rate combinado para que la engine inclusive
--         lo siga usando para extraer base en updates futuros).
--
--   2. orders afectadas:
--      - tax         = SUM(items.tax)               (ahora solo ITBIS)
--      - service_fee = service_fee + Σ(subtotal*0.10) de items splitteados
--      - total       = NO se toca (el Δ de tax = Δ negativo de service_fee
--                      con signo opuesto, entonces total queda igual a
--                      lo que efectivamente se cobró al cliente).
--
--   3. fiscal_documents:
--      - itbis_amount = orders.tax  (recién recalculado)
--      - service_fee  = orders.service_fee
--      - total = NO se toca.
--
-- Idempotente
-- -----------
-- Tras la primera corrida, ningún item matchea `tax_rate BETWEEN 27.99
-- AND 28.01`, así que la corrida #2 no genera changes.
--
-- Solo afecta data histórica
-- --------------------------
-- Hardcodeamos 18/28 y 10/28 (las tasas estándar DR según Norma
-- General 01-2020). Esto es robusto incluso si el negocio actualmente
-- tiene la config de impuestos mal (ej. un solo tax llamado "ITBIS"
-- con rate=28) — la migración trabaja sobre la SHAPE del dato
-- legacy, no sobre la config actual.
--
-- Hipótesis de detección: subtotal en order_items es la BASE
-- (post-extracción para inclusive). Verificación: ABS(tax - subtotal *
-- 0.28) < 0.05 garantiza que solo splitteamos items donde la math
-- cuadra exactamente con 28%. Items con descuentos parciales o
-- redondeos raros que NO cuadren se dejan en paz.
-- =============================================================================

DO $$
DECLARE
  v_items_updated   integer := 0;
  v_orders_updated  integer := 0;
  v_docs_updated    integer := 0;
BEGIN
  -- ─── Step 1: split items y capturar order_ids afectadas ─────────────────
  CREATE TEMP TABLE _tmp_affected_orders (
    order_id uuid PRIMARY KEY
  ) ON COMMIT DROP;

  WITH split AS (
    UPDATE public.order_items oi
    SET
      tax_rate          = 18,
      tax               = ROUND(oi.subtotal * 0.18, 2),
      total             = ROUND(oi.subtotal + ROUND(oi.subtotal * 0.18, 2)
                                 - COALESCE(oi.discounts, 0), 2),
      original_tax_rate = COALESCE(oi.original_tax_rate, 28)
    WHERE
      oi.tax_rate BETWEEN 27.99 AND 28.01
      AND oi.status IS DISTINCT FROM 'void'::public.item_status
      AND oi.subtotal > 0
      AND ABS(oi.tax - oi.subtotal * 0.28) < 0.05
    RETURNING oi.id, oi.order_id
  )
  INSERT INTO _tmp_affected_orders (order_id)
  SELECT DISTINCT s.order_id FROM split s
  ON CONFLICT (order_id) DO NOTHING;

  GET DIAGNOSTICS v_items_updated = ROW_COUNT;

  RAISE NOTICE 'Step 1: split % items en % órdenes',
    v_items_updated,
    (SELECT count(*) FROM _tmp_affected_orders);

  -- ─── Step 2: recalcular tax + service_fee en orders afectadas ──────────
  UPDATE public.orders o
  SET
    tax = ROUND(
      (SELECT COALESCE(SUM(oi.tax), 0)
         FROM public.order_items oi
        WHERE oi.order_id = o.id
          AND oi.status IS DISTINCT FROM 'void'::public.item_status),
      2
    ),
    service_fee = ROUND(
      COALESCE(o.service_fee, 0) +
      (SELECT COALESCE(SUM(ROUND(oi.subtotal * 0.10, 2)), 0)
         FROM public.order_items oi
        WHERE oi.order_id = o.id
          AND oi.tax_rate = 18
          AND oi.original_tax_rate BETWEEN 27.99 AND 28.01
          AND oi.status IS DISTINCT FROM 'void'::public.item_status),
      2
    )
  WHERE o.id IN (SELECT order_id FROM _tmp_affected_orders);

  GET DIAGNOSTICS v_orders_updated = ROW_COUNT;
  RAISE NOTICE 'Step 2: recalculadas % órdenes', v_orders_updated;

  -- ─── Step 3: refrescar fiscal_documents desde orders ──────────────────
  UPDATE public.fiscal_documents fd
  SET
    itbis_amount = o.tax,
    service_fee  = o.service_fee
  FROM public.orders o
  WHERE fd.order_id = o.id
    AND o.id IN (SELECT order_id FROM _tmp_affected_orders);

  GET DIAGNOSTICS v_docs_updated = ROW_COUNT;
  RAISE NOTICE 'Step 3: refrescados % fiscal_documents', v_docs_updated;

  -- ─── Resumen ──────────────────────────────────────────────────────────
  RAISE NOTICE '═══════════════════════════════════════════════════════════════';
  RAISE NOTICE 'Backfill completo:';
  RAISE NOTICE '  items splitteados      : %', v_items_updated;
  RAISE NOTICE '  orders recalculadas    : %', v_orders_updated;
  RAISE NOTICE '  fiscal_documents fixed : %', v_docs_updated;
  RAISE NOTICE '═══════════════════════════════════════════════════════════════';
END $$;
