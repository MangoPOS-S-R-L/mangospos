-- ============================================================================
-- Corrector definitivo: reparar orders huérfanas + sync fiscal_documents
-- ============================================================================
-- Estado actual de las 3 órdenes problemáticas (de hoy):
--
-- B0200002389:
--   orders     = 0,0,0,0,0  (huérfana, vaciada por calculate_order_totals)
--   items      = subtotal 45.45, tax_rate 0, tax 0
--   fiscal_doc = subtotal 45.45, itbis 0, sf 0, total 50
--   → Cliente pagó 50. Re-interpretar como inclusive 28%:
--     base 39.06, ITBIS 7.03, propina 3.91.
--
-- B0200002391:
--   orders     = 0,0,0,0,0  (huérfana)
--   items      = 6 items, 2 con ITBIS (rate=18), 4 con rate=0
--   fiscal_doc = subtotal 318.54, itbis 24.61, sf 0, total 375
--   → Más complejo: ya tiene ITBIS parcial. NO re-bake completo
--     (perderíamos los items que sí pagaron ITBIS individualmente).
--     Solo restaurar orders desde items + asignar la propina faltante.
--     Gap = 375 - (318.54 + 24.61) = 31.85 = 10% del subtotal → propina.
--
-- B0200002395:
--   orders     = 468.75, 84.38, 0, 0, 553.13  (consistente: sub+itbis=total)
--   fiscal_doc = mismo subtotal/itbis/total, PERO service_fee=46.87 fantasma
--   → Limpiar fiscal_doc.service_fee a 0 (no se cobró).
--
-- Tres operaciones distintas en un solo script:
--   1. Restaurar orders huérfanas desde items + reasignar gap de propina
--   2. Re-bake las que necesitan ITBIS+propina como inclusive 28%
--   3. Limpiar propina fantasma en fiscal_documents que no aparece en orders
-- ============================================================================

DO $$
DECLARE
  v_business_id   uuid;
  v_orders_synced integer := 0;
  v_orphans_fixed integer := 0;
  v_ghosts_cleaned integer := 0;
  o_record        RECORD;
  v_items_sub     numeric;
  v_items_tax     numeric;
  v_target_sf     numeric;
BEGIN
  -- Resolver business_id
  SELECT ts.business_id
    INTO v_business_id
  FROM public.fiscal_documents fd
  JOIN public.orders o ON o.id = fd.order_id
  JOIN public.table_sessions ts ON ts.id = o.session_id
  WHERE fd.ncf_number = 'B0200002389'
  LIMIT 1;

  IF v_business_id IS NULL THEN
    RAISE EXCEPTION 'No se pudo resolver business_id';
  END IF;

  -- ============================================================
  -- BLOQUE 1: orders huérfanas (orders.total=0 pero fd.total>0)
  -- Restaurar desde items + asignar la propina faltante
  -- ============================================================
  FOR o_record IN
    SELECT
      o.id AS order_id,
      fd.id AS doc_id,
      fd.total AS doc_total,
      COALESCE(fd.itbis_amount, 0) AS doc_itbis
    FROM public.orders o
    JOIN public.table_sessions ts ON ts.id = o.session_id
    JOIN public.fiscal_documents fd ON fd.order_id = o.id
    WHERE ts.business_id = v_business_id
      AND fd.status = 'active'
      AND COALESCE(o.total, 0) = 0
      AND fd.total > 0
  LOOP
    -- Sumar items reales (que están intactos)
    SELECT
      COALESCE(SUM(oi.subtotal), 0),
      COALESCE(SUM(oi.tax), 0)
    INTO v_items_sub, v_items_tax
    FROM public.order_items oi
    WHERE oi.order_id = o_record.order_id
      AND oi.status IS DISTINCT FROM 'void'::public.item_status;

    -- Gap = doc_total - items_subtotal - items_tax → debería ser propina (10%)
    v_target_sf := ROUND(o_record.doc_total - v_items_sub - v_items_tax, 2);

    -- Sanity: el gap debe cuadrar con 10% del subtotal (margen 5%)
    IF v_target_sf > 0
       AND ABS(v_target_sf - v_items_sub * 0.10) / GREATEST(v_items_sub * 0.10, 0.01) < 0.05
    THEN
      -- Restaurar orders consistente con items + gap como service_fee
      UPDATE public.orders
      SET
        subtotal    = v_items_sub,
        tax         = v_items_tax,
        service_fee = v_target_sf,
        discounts   = 0,
        total       = v_items_sub + v_items_tax + v_target_sf
      WHERE id = o_record.order_id;

      -- Sync fiscal_documents
      UPDATE public.fiscal_documents
      SET
        subtotal     = v_items_sub,
        itbis_amount = v_items_tax,
        service_fee  = v_target_sf,
        total        = v_items_sub + v_items_tax + v_target_sf
      WHERE id = o_record.doc_id;

      v_orphans_fixed := v_orphans_fixed + 1;

      RAISE NOTICE 'Orphan fixed: order %, sub=%, itbis=%, sf=%, total=%',
        o_record.order_id, v_items_sub, v_items_tax, v_target_sf,
        v_items_sub + v_items_tax + v_target_sf;
    ELSE
      RAISE NOTICE 'Orphan SKIPPED (gap no cuadra con 10%%): order %, gap=%, expected=%',
        o_record.order_id, v_target_sf, ROUND(v_items_sub * 0.10, 2);
    END IF;
  END LOOP;

  -- ============================================================
  -- BLOQUE 2: Re-bake casos donde gap NO cuadra con propina simple
  -- (ej. items todos sin ITBIS pero el cliente pagó el 28%)
  -- ============================================================
  -- Estos son los casos como B0200002389 (items con tax=0 y total
  -- sugiere 28% inclusive). Reinterpretamos total como base × 1.28.
  FOR o_record IN
    SELECT
      o.id AS order_id,
      fd.id AS doc_id,
      fd.total AS doc_total
    FROM public.orders o
    JOIN public.table_sessions ts ON ts.id = o.session_id
    JOIN public.fiscal_documents fd ON fd.order_id = o.id
    WHERE ts.business_id = v_business_id
      AND fd.status = 'active'
      AND COALESCE(o.total, 0) = 0       -- todavía huérfana después del bloque 1
      AND fd.total > 0
  LOOP
    DECLARE
      v_new_sub   numeric := ROUND(o_record.doc_total / 1.28, 2);
      v_new_itbis numeric := ROUND(o_record.doc_total / 1.28 * 0.18, 2);
      v_new_sf    numeric;
      v_old_items_sub numeric;
      v_scale     numeric;
    BEGIN
      v_new_sf := ROUND(o_record.doc_total - v_new_sub - v_new_itbis, 2);

      -- Items actuales subtotal (para escalar)
      SELECT COALESCE(SUM(oi.subtotal), 0)
      INTO v_old_items_sub
      FROM public.order_items oi
      WHERE oi.order_id = o_record.order_id
        AND oi.status IS DISTINCT FROM 'void'::public.item_status;

      IF v_old_items_sub > 0 THEN
        v_scale := v_new_sub / v_old_items_sub;

        -- Re-escalar items
        UPDATE public.order_items oi
        SET
          subtotal          = ROUND(oi.subtotal * v_scale, 2),
          tax               = ROUND(oi.subtotal * v_scale * 0.18, 2),
          tax_rate          = 18,
          original_tax_rate = 28,
          tax_mode          = 'inclusive',
          total             = ROUND(oi.subtotal * v_scale * 1.18, 2)
        WHERE oi.order_id = o_record.order_id
          AND oi.status IS DISTINCT FROM 'void'::public.item_status
          AND oi.subtotal > 0;

        -- Update orders + fiscal_documents
        UPDATE public.orders SET
          subtotal    = v_new_sub,
          tax         = v_new_itbis,
          service_fee = v_new_sf,
          total       = o_record.doc_total
        WHERE id = o_record.order_id;

        UPDATE public.fiscal_documents SET
          subtotal     = v_new_sub,
          itbis_amount = v_new_itbis,
          service_fee  = v_new_sf,
          total        = o_record.doc_total
        WHERE id = o_record.doc_id;

        v_orphans_fixed := v_orphans_fixed + 1;
        RAISE NOTICE 'Re-baked inclusive 28%%: order %, sub=%, itbis=%, sf=%',
          o_record.order_id, v_new_sub, v_new_itbis, v_new_sf;
      END IF;
    END;
  END LOOP;

  -- ============================================================
  -- BLOQUE 3: Propina fantasma en fiscal_documents
  -- fiscal_doc.service_fee > 0 pero orders.service_fee = 0 Y la
  -- math de orders cuadra (orders.total = subtotal + tax sin sf).
  -- Limpiar fiscal_doc.service_fee = 0.
  -- ============================================================
  WITH ghosts AS (
    UPDATE public.fiscal_documents fd
    SET service_fee = 0
    FROM public.orders o
    JOIN public.table_sessions ts ON ts.id = o.session_id
    WHERE fd.order_id = o.id
      AND ts.business_id = v_business_id
      AND fd.status = 'active'
      AND COALESCE(fd.service_fee, 0) > 0
      AND COALESCE(o.service_fee, 0) = 0
      -- La orden cuadra sin el service_fee fantasma:
      AND ABS(o.total - o.subtotal - COALESCE(o.tax, 0)
              + COALESCE(o.discounts, 0)) < 0.05
    RETURNING fd.id
  )
  SELECT count(*) INTO v_ghosts_cleaned FROM ghosts;

  RAISE NOTICE '═══════════════════════════════════════════════════════════════';
  RAISE NOTICE 'Corrector definitivo:';
  RAISE NOTICE '  orders huérfanas reparadas    : %', v_orphans_fixed;
  RAISE NOTICE '  propinas fantasma limpiadas   : %', v_ghosts_cleaned;
  RAISE NOTICE '═══════════════════════════════════════════════════════════════';
END $$;

-- ─── Verificación de las 3 problemáticas ─────────────────────────────────
SELECT
  fd.ncf_number,
  fd.subtotal      AS doc_sub,
  fd.itbis_amount  AS doc_itbis,
  fd.service_fee   AS doc_sf,
  fd.total         AS doc_total,
  o.subtotal       AS ord_sub,
  o.tax            AS ord_tax,
  o.service_fee    AS ord_sf,
  o.total          AS ord_total,
  ROUND(fd.total - fd.subtotal - fd.itbis_amount - fd.service_fee, 2) AS doc_gap,
  ROUND(o.total - o.subtotal - COALESCE(o.tax,0)
        - COALESCE(o.service_fee,0) + COALESCE(o.discounts,0), 2) AS ord_gap
FROM public.fiscal_documents fd
JOIN public.orders o ON o.id = fd.order_id
WHERE fd.ncf_number IN ('B0200002389', 'B0200002391', 'B0200002395')
ORDER BY fd.ncf_number;
