-- =============================================================================
-- Trigger: auto-recompute fd.total cuando un payment se asocia/cambia
-- de fiscal_document.
--
-- Sin este trigger, si llega un payment DESPUÉS del cierre del scope
-- y se linkea al fd existente (sync offline tardío, re-emisión, backfill),
-- el fd.total queda obsoleto — la diferencia se acumula como underreport
-- a DGII. Caso real observado: 13 NCFs subreportados por RD$ 17,560 en
-- mayo 2026 (sesión 2026-05-30).
--
-- El trigger cubre:
--   1. INSERT con fiscal_document_id ya seteado → recomputar ese fd
--   2. UPDATE que setea/cambia fiscal_document_id → recomputar el fd
--      nuevo (NEW) y el fd viejo (OLD) si era distinto y no nulo
--   3. UPDATE de amount, change_amount, status → recomputar fd actual
--      (cambios al monto del payment alteran fd.total)
--
-- Combinado con la migración 20260530_0001 (fn_recompute_fd_for_scope
-- ahora suma payments por fd_id directo), garantiza que cualquier
-- escritura sobre payments mantiene fd.total exacto.
-- =============================================================================

CREATE OR REPLACE FUNCTION public.trg_fn_recompute_fd_on_payment_change()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $function$
DECLARE
  v_order_id uuid;
  v_check_id uuid;
BEGIN
  -- Recomputar el fd NUEVO (si el payment quedó apuntando a alguno).
  IF NEW.fiscal_document_id IS NOT NULL THEN
    SELECT order_id, check_id
      INTO v_order_id, v_check_id
    FROM public.fiscal_documents
    WHERE id = NEW.fiscal_document_id;

    IF FOUND THEN
      PERFORM public.fn_recompute_fd_for_scope(
        NEW.fiscal_document_id, v_order_id, v_check_id);
    END IF;
  END IF;

  -- En UPDATE, si el payment se DES-asoció de un fd anterior o cambió
  -- de fd, también recomputar el fd viejo (para que no quede inflado
  -- con la contribución del payment que ya no le pertenece).
  IF TG_OP = 'UPDATE'
     AND OLD.fiscal_document_id IS NOT NULL
     AND OLD.fiscal_document_id IS DISTINCT FROM NEW.fiscal_document_id THEN
    SELECT order_id, check_id
      INTO v_order_id, v_check_id
    FROM public.fiscal_documents
    WHERE id = OLD.fiscal_document_id;

    IF FOUND THEN
      PERFORM public.fn_recompute_fd_for_scope(
        OLD.fiscal_document_id, v_order_id, v_check_id);
    END IF;
  END IF;

  RETURN NEW;
END;
$function$;

-- AFTER (no BEFORE) porque queremos que el cambio en NEW ya esté
-- persistido cuando fn_recompute_fd_for_scope sume los payments — ese
-- método lee del catálogo, no del NEW.
DROP TRIGGER IF EXISTS trg_recompute_fd_on_payment_change ON public.payments;

CREATE TRIGGER trg_recompute_fd_on_payment_change
AFTER INSERT OR UPDATE OF
  fiscal_document_id, amount, change_amount, status
ON public.payments
FOR EACH ROW
EXECUTE FUNCTION public.trg_fn_recompute_fd_on_payment_change();

COMMENT ON FUNCTION public.trg_fn_recompute_fd_on_payment_change() IS
  'Re-corre fn_recompute_fd_for_scope cuando un payment se inserta/actualiza, manteniendo fd.total sincronizado con la suma real de payments linkeados.';
