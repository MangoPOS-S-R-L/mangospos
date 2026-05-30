-- =============================================================================
-- Limpieza puntual: items 'paid' fantasmas en la mesa 6bcdfc65
-- (MEDIO TIEMPO BAR), sesión diagnóstica 2026-05-30.
--
-- Síntoma:
-- Mesa abierta desde 2026-05-26 23:48 con UN único payment registrado
-- (2026-05-27 01:11:19, RD$ 800 neto). Sin embargo decenas de items
-- creados DESPUÉS de ese payment quedaron con status='paid' — eso es
-- imposible, no hay payment que los cubra.
--
-- Causa probable:
-- Bug en algún flujo (cierre de check, dispatch a cocina, recálculo
-- manual) que marcó items como 'paid' sin generar el payment
-- correspondiente. Investigación del flujo queda pendiente — este
-- script solo limpia el síntoma para que cuando la mesa cierre
-- legítimamente, el flujo de cobro arranque desde un estado consistente.
--
-- Lo que hace:
-- Revierte a 'pending' los items de esa mesa con status='paid'
-- creados DESPUÉS del único payment registrado. Items creados ANTES
-- del payment quedan intactos (asumimos que esos sí estuvieron
-- legítimamente cubiertos por los 800).
--
-- Guard rail:
-- Cuenta items afectados y aborta si el número está fuera del rango
-- esperado (entre 5 y 50 — observamos ~30 items en el diagnóstico).
-- Si la cantidad cambió drásticamente, alguien más actuó sobre esta
-- mesa entre el diagnóstico y este script.
--
-- Posterior:
-- Después de aplicar 20260530_0007 (trigger order_items), orders.total
-- de esta mesa se va a recomputar automáticamente al primer cambio
-- de item subsiguiente. Si querés forzarlo manual antes:
--   SELECT calculate_order_totals('6bcdfc65-d8a6-47ab-9496-f7a2f7d299e7');
-- =============================================================================

DO $$
DECLARE
  v_payment_at timestamptz;
  v_count_before int;
  v_count_after int;
  v_affected int;
BEGIN
  -- Localizar el momento del único payment legítimo de la mesa.
  SELECT MAX(p.created_at) INTO v_payment_at
  FROM public.payments p
  WHERE p.order_id = '6bcdfc65-d8a6-47ab-9496-f7a2f7d299e7'
    AND p.status = 'completed';

  IF v_payment_at IS NULL THEN
    RAISE EXCEPTION 'No hay payment completed en la mesa — abortando, '
      'todo está marcado paid sin sustento de cobro.';
  END IF;

  RAISE NOTICE 'Único payment de la mesa: %', v_payment_at::text;

  -- Contar items afectados antes de actuar.
  SELECT COUNT(*) INTO v_count_before
  FROM public.order_items oi
  WHERE oi.order_id = '6bcdfc65-d8a6-47ab-9496-f7a2f7d299e7'
    AND oi.status = 'paid'
    AND oi.created_at > v_payment_at;

  RAISE NOTICE 'Items "paid" fantasmas detectados: %', v_count_before;

  -- Guard rail: entre 5 y 50. Diagnóstico mostró ~30.
  IF v_count_before < 5 OR v_count_before > 50 THEN
    RAISE EXCEPTION
      'Cantidad fuera de rango: % items. Esperaba entre 5 y 50. ABORTANDO.',
      v_count_before;
  END IF;

  -- Revertir a 'pending'. El trigger fn_compute_item_totals recalcula
  -- subtotal/tax/total del item, pero no cambia su contenido — solo
  -- la transición de status.
  UPDATE public.order_items
  SET status = 'pending'
  WHERE order_id = '6bcdfc65-d8a6-47ab-9496-f7a2f7d299e7'
    AND status = 'paid'
    AND created_at > v_payment_at;

  GET DIAGNOSTICS v_affected = ROW_COUNT;

  -- Verificar post-condición.
  SELECT COUNT(*) INTO v_count_after
  FROM public.order_items oi
  WHERE oi.order_id = '6bcdfc65-d8a6-47ab-9496-f7a2f7d299e7'
    AND oi.status = 'paid'
    AND oi.created_at > v_payment_at;

  IF v_count_after <> 0 THEN
    RAISE EXCEPTION
      'Aún quedan % items paid fantasmas tras el UPDATE. ABORTANDO.',
      v_count_after;
  END IF;

  RAISE NOTICE '✓ Limpieza completa: % items revertidos a pending', v_affected;

  -- Forzar recomputo de orders.total con la nueva mezcla de status.
  PERFORM public.calculate_order_totals('6bcdfc65-d8a6-47ab-9496-f7a2f7d299e7');

  RAISE NOTICE '✓ orders.total recalculado para la mesa.';
END$$;
