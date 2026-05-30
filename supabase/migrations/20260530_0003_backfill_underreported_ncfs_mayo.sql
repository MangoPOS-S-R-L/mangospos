-- =============================================================================
-- Backfill: corregir los NCFs que subreportaron fd.total en mayo 2026
-- por el bug de fn_recompute_fd_for_scope filtrando por check_id en
-- vez de fiscal_document_id directo.
--
-- Scope: business 33207ebd-985d-455c-bdbb-1b38af8b36ea, mes de mayo
-- 2026 (issued_at en [2026-05-01, 2026-06-01)).
--
-- Pre-requisito: aplicar 20260530_0001_fix_fn_recompute_fd_for_scope.sql
-- ANTES de este backfill. Sin la función corregida, este DO block no
-- arregla nada (re-correr la función vieja produce el mismo resultado).
--
-- Pre-requisito fiscal: NO haber enviado el 606 a DGII para mayo 2026.
-- Confirmado con el usuario el 2026-05-30 — el contable filea el 606
-- después del cierre del mes (junio). Backfill aplicado el 30 de mayo
-- queda reflejado cuando el contable consulte los NCFs para armar el
-- 606.
--
-- Lo que hace:
-- Para cada fd active del mes con payments_net > fd.total + 1,
-- re-corre fn_recompute_fd_for_scope (que ahora usa la lógica correcta
-- de sumar por fiscal_document_id). Esto actualiza fd.total, subtotal,
-- itbis_amount y service_fee a los valores reales.
--
-- Resultado esperado (sesión 2026-05-30):
-- 13 NCFs corregidos, RD$ 17,560.02 de revenue que estaba sub-facturado
-- queda registrado en los NCFs correctos.
-- =============================================================================

-- Guard rails: el backfill debe afectar EXACTAMENTE el set de outliers
-- identificado en la sesión diagnóstica (13 NCFs, ~RD$ 17,560.02 de delta).
-- Si los conteos no matchean, abortamos con error — significa que cambió
-- algo en la DB entre el diagnóstico y este script (otra orden afectada,
-- alguien ya corrió la corrección, etc.).
--
-- Tolerancias:
--   - count: ±1 NCF (permitimos que una orden nueva del último día caiga
--     o desaparezca del conjunto sin abortar)
--   - delta total: ±RD$ 500 (margen para órdenes intermedias)
--
-- Si querés re-correr este script en otra fecha, ajustá los parámetros
-- v_expected_count y v_expected_delta_min/max según el diagnóstico del
-- momento.

DO $$
DECLARE
  v_fd record;
  v_before numeric;
  v_after numeric;
  v_count int := 0;
  v_total_delta numeric := 0;
  -- Parámetros validados en la sesión 2026-05-30 con Q10/Q11/Q14:
  v_expected_count_min int := 12;
  v_expected_count_max int := 14;
  v_expected_delta_min numeric := 17000;
  v_expected_delta_max numeric := 18100;
BEGIN
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

    -- Sanity check por fila: el delta debe ser positivo (estamos subiendo
    -- fd.total hacia el real). Negativo significa que algo está muy mal.
    IF v_after < v_before - 0.01 THEN
      RAISE EXCEPTION 'NCF % bajó de % a % — abortando, esto NO debe pasar',
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

  -- Validación global: tanto el conteo como el delta deben matchear lo
  -- esperado. Si no, abortamos toda la transacción (DO block es atómico).
  IF v_count < v_expected_count_min OR v_count > v_expected_count_max THEN
    RAISE EXCEPTION
      'Conteo inesperado: % NCFs corregidos, esperaba entre % y %. '
      'Re-correr Q10/Q11 para verificar el estado actual.',
      v_count, v_expected_count_min, v_expected_count_max;
  END IF;

  IF v_total_delta < v_expected_delta_min OR v_total_delta > v_expected_delta_max THEN
    RAISE EXCEPTION
      'Delta inesperado: RD$ % corregido, esperaba entre RD$ % y RD$ %. '
      'Algo cambió desde el diagnóstico. ABORTANDO.',
      v_total_delta::text,
      v_expected_delta_min::text,
      v_expected_delta_max::text;
  END IF;

  RAISE NOTICE '✓ Backfill completo: % NCFs corregidos, +RD$ % en total',
    v_count, v_total_delta::text;
  RAISE NOTICE '✓ Conteo y delta dentro del rango esperado.';
END$$;
