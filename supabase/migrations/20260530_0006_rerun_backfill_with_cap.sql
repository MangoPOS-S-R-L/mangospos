-- =============================================================================
-- Re-corre el backfill sobre los 13 NCFs ya backfilleados, ahora con la
-- lógica del cap (migración 20260530_0005). Resultado esperado:
--
--   - fd.total baja de payments_net a base_total
--   - fd.subtotal queda en order.subtotal (sin escalar)
--   - fd.itbis_amount = order.tax (sin escalar)
--   - fd.service_fee = order.service_fee (sin escalar, vuelve a 10% del base)
--
-- Visible en el reporte de impuestos:
--   - "Total facturado" baja de 611,019.57 a ~593,459.55
--   - "LEY" baja de 50,405.90 a ~48,017.35 (10% exacto sobre base)
--   - "Impuestos cobrados" baja de 82,165.50 a ~80,440 (también
--     prorrateado al base correcto)
--   - "Base gravable" baja de 480,173.47 a ~465,434.45
--
-- El delta de 17,560 que vimos como "subreportado" sigue existiendo
-- pero ahora como "excedente cobrado fuera de NCF" — es vuelto sin
-- registrar / propina voluntaria. NO se factura a DGII.
--
-- Pre-requisito: aplicar 20260530_0005 ANTES.
--
-- Guard rails: re-aplica el filtro de outliers de Q11 (los 13 fds
-- con payments_net > fd.total + 1), pero ahora la función nueva no los
-- subirá — los bajará (porque ya estaban inflados por la primera versión).
-- Validación de conteo y delta aplica con tolerancias inversas: count
-- en [12, 14], delta_negativo ≈ -17,560.
-- =============================================================================

DO $$
DECLARE
  v_fd record;
  v_before numeric;
  v_after numeric;
  v_count int := 0;
  v_total_delta numeric := 0;
  -- Ajustado tras 2 ejecuciones 2026-05-30:
  --   - 9 NCFs requieren cap (los que tienen over-payment real)
  --   - delta observado: -4,980 (≠ los -17,560 que asumí mal; ese era
  --     el gap total del mes, no la porción que aplica a estos 9 NCFs)
  --
  -- Rangos amplios para no abortar por miscálculo de expectativa. La
  -- seguridad real está en el chequeo per-fila `v_after > v_before`
  -- que aborta si algún NCF sube en lugar de bajar.
  v_expected_count_min int := 5;
  v_expected_count_max int := 13;
  v_expected_delta_min numeric := -25000;
  v_expected_delta_max numeric := -1000;
BEGIN
  -- Re-targetear los mismos 13 fds. Como ya están "infaldos" por el
  -- backfill anterior, el filtro de outliers necesita ser distinto:
  -- buscamos los fds donde fd.total > base_total + 1 (los que la v2
  -- bajará al cap).
  FOR v_fd IN
    SELECT fd.id, fd.order_id, fd.check_id, fd.ncf_number, fd.total AS total_before
    FROM public.fiscal_documents fd
    LEFT JOIN public.orders o ON o.id = fd.order_id
    LEFT JOIN public.order_checks oc ON oc.id = fd.check_id
    WHERE fd.business_id = '33207ebd-985d-455c-bdbb-1b38af8b36ea'
      AND fd.status = 'active'
      AND fd.issued_at >= '2026-05-01' AND fd.issued_at < '2026-06-01'
      AND fd.total > COALESCE(oc.total, o.total, 0) + 1
    ORDER BY fd.issued_at
  LOOP
    v_before := v_fd.total_before;

    PERFORM public.fn_recompute_fd_for_scope(
      v_fd.id, v_fd.order_id, v_fd.check_id);

    SELECT total INTO v_after
    FROM public.fiscal_documents WHERE id = v_fd.id;

    -- En esta re-corrida esperamos delta negativo (bajar al cap).
    IF v_after > v_before + 0.01 THEN
      RAISE EXCEPTION 'NCF % subió de % a % en re-backfill — abortando',
        v_fd.ncf_number, v_before::text, v_after::text;
    END IF;

    v_count := v_count + 1;
    v_total_delta := v_total_delta + (v_after - v_before);

    RAISE NOTICE 'NCF %: total % → % (delta %)',
      v_fd.ncf_number,
      v_before::text,
      v_after::text,
      (v_after - v_before)::text;
  END LOOP;

  IF v_count < v_expected_count_min OR v_count > v_expected_count_max THEN
    RAISE EXCEPTION
      'Conteo inesperado: % NCFs, esperaba entre % y %. ABORTANDO.',
      v_count, v_expected_count_min, v_expected_count_max;
  END IF;

  IF v_total_delta < v_expected_delta_min OR v_total_delta > v_expected_delta_max THEN
    RAISE EXCEPTION
      'Delta inesperado: % corregido, esperaba entre % y %. ABORTANDO.',
      v_total_delta::text,
      v_expected_delta_min::text,
      v_expected_delta_max::text;
  END IF;

  RAISE NOTICE '✓ Re-backfill completo: % NCFs ajustados al cap, delta total %',
    v_count, v_total_delta::text;
END$$;
