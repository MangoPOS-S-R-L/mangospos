-- =============================================================================
-- Re-run del backfill con la lógica final de v3 (0010): excedente al
-- subtotal, fd.total = payments_net, impuestos sin inflar.
--
-- Target: los 9 NCFs que la versión v2 (0005+0006) había capado al
-- base_total. Ahora con v3 vuelven a subir a payments_net, pero los
-- componentes itbis_amount y service_fee NO se escalan — el delta
-- sube al subtotal como ingreso no gravable.
--
-- Pre-requisito: aplicar 20260530_0010 ANTES.
--
-- Delta esperado: +RD$ 4,980 (positivo, recupera lo que la v2 había
-- bajado). Coincide con el delta negativo del 0006 al revés.
-- =============================================================================

DO $$
DECLARE
  v_fd record;
  v_before numeric;
  v_after numeric;
  v_count int := 0;
  v_total_delta numeric := 0;
  -- Diagnóstico 2026-05-30 final: solo 3 NCFs quedaron con gap real
  -- payments_net > fd.total (gap acumulado: RD$ 4,980.02). Los otros 6
  -- originales tienen payments_net = base_total exacto y no necesitan
  -- volver a subir.
  v_expected_count_min int := 1;
  v_expected_count_max int := 13;
  v_expected_delta_min numeric := 100;
  v_expected_delta_max numeric := 25000;
BEGIN
  -- Filtro: fds donde fd.total < payments_net + 1 (los que están
  -- subreportando). Con la función v3, todos van a subir a payments_net.
  FOR v_fd IN
    SELECT fd.id, fd.order_id, fd.check_id, fd.ncf_number, fd.total AS total_before
    FROM public.fiscal_documents fd
    WHERE fd.business_id = '33207ebd-985d-455c-bdbb-1b38af8b36ea'
      AND fd.status = 'active'
      AND fd.issued_at >= '2026-05-01' AND fd.issued_at < '2026-06-01'
      AND (
        SELECT COALESCE(SUM(p.amount - COALESCE(p.change_amount, 0)), 0)
        FROM public.payments p
        WHERE p.fiscal_document_id = fd.id
          AND p.status = 'completed'
      ) > fd.total + 1
    ORDER BY fd.issued_at
  LOOP
    v_before := v_fd.total_before;

    PERFORM public.fn_recompute_fd_for_scope(
      v_fd.id, v_fd.order_id, v_fd.check_id);

    SELECT total INTO v_after
    FROM public.fiscal_documents WHERE id = v_fd.id;

    -- Sanity: el delta debe ser positivo (estamos subiendo al payments_net).
    IF v_after < v_before - 0.01 THEN
      RAISE EXCEPTION 'NCF % bajó de % a % — abortando',
        v_fd.ncf_number, v_before::text, v_after::text;
    END IF;

    v_count := v_count + 1;
    v_total_delta := v_total_delta + (v_after - v_before);

    RAISE NOTICE 'NCF %: total % → % (delta +%)',
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

  RAISE NOTICE '✓ Re-backfill v3 completo: % NCFs ajustados, delta total +%',
    v_count, v_total_delta::text;
END$$;
