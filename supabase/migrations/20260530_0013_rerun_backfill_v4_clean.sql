-- =============================================================================
-- Re-run de backfill con la lógica FINAL v4 (0012). Target: los 3 NCFs
-- de MEDIO TIEMPO BAR que tienen excedente no gravable.
--
-- Pre-requisito: aplicar 20260530_0012 antes.
--
-- Resultado esperado: los 3 NCFs van a:
--   - fd.total = payments_net (matchea sales)
--   - fd.subtotal = order.subtotal (menú real, sin inflar)
--   - fd.itbis_amount = order.tax (sin inflar)
--   - fd.service_fee = order.service_fee (sin inflar)
--
-- En el reporte de impuestos (post-aplicación):
--   Base gravable: 465,434 (RECUPERA, sin inflar)
--   Impuestos cobrados: 80,440 (17.28% sobre base real)
--   LEY: 48,017 (10% sobre base real)
--   Total facturado: 611,019 (matchea ventas)
--   La UI también va a mostrar (con cambio Flutter incluido):
--     Excedente no gravable: 17,560 (Total - Base - ITBIS - LEY)
-- =============================================================================

DO $$
DECLARE
  v_fd record;
  v_count int := 0;
BEGIN
  FOR v_fd IN
    SELECT fd.id, fd.order_id, fd.check_id, fd.ncf_number, fd.total AS total_before
    FROM public.fiscal_documents fd
    WHERE fd.business_id = '33207ebd-985d-455c-bdbb-1b38af8b36ea'
      AND fd.status = 'active'
      AND fd.issued_at >= '2026-05-01' AND fd.issued_at < '2026-06-01'
      -- Cubrir todos los fds que (a) tienen payments por encima de fd.total
      -- (no convergen) o (b) tienen subtotal inflado por 0010 (subtotal +
      -- itbis + service_fee > total esperado).
      AND (
        EXISTS (
          SELECT 1 FROM public.payments p
          WHERE p.fiscal_document_id = fd.id
            AND p.status = 'completed'
          GROUP BY p.fiscal_document_id
          HAVING SUM(p.amount - COALESCE(p.change_amount, 0)) > fd.total + 1
        )
        OR (fd.subtotal + fd.itbis_amount + fd.service_fee > fd.total + 1)
      )
    ORDER BY fd.issued_at
  LOOP
    PERFORM public.fn_recompute_fd_for_scope(
      v_fd.id, v_fd.order_id, v_fd.check_id);

    v_count := v_count + 1;

    RAISE NOTICE 'NCF % re-procesado con v4', v_fd.ncf_number;
  END LOOP;

  RAISE NOTICE '✓ Backfill v4 completo: % NCFs ajustados', v_count;
END$$;
