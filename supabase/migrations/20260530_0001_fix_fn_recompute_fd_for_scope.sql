-- =============================================================================
-- Fix: fn_recompute_fd_for_scope subreportaba fd.total cuando payments
-- compartían fd pero estaban en checks distintos.
--
-- Bug observado (sesión 2026-05-30, business 38a0dfd6...):
-- Una orden con 3 subcuentas (A, B, C) más 1 pago a nivel orden tenía
-- todos sus 4 payments apuntando al mismo fiscal_document_id, pero
-- fd.total reportaba solo RD$ 250 cuando los payments sumaban RD$ 4,040
-- netos. Diferencia subreportada a DGII: RD$ 3,790 en ese NCF, RD$ 17,560
-- en total sobre 13 órdenes del mes.
--
-- Causa raíz:
-- La función filtraba payments por `p.check_id is not distinct from
-- p_check_id`. Si el fd se emitió a nivel orden (check_id=NULL), solo
-- contaba payments con check_id=NULL. Los payments de subchecks que
-- terminaban linkeados a ese mismo fd (por backfill, re-asignación, o
-- ghost trigger pre-cierre) quedaban fuera del cómputo.
--
-- Fix:
-- Prioridad 1 → sumar payments por `p.fiscal_document_id = p_fd_id`
-- directo. Esa es la fuente más confiable: cualquier payment linkeado
-- al fd se cuenta, sin importar de qué scope vino originalmente.
--
-- Fallback → si todavía no hay payments linkeados al fd (caso primera
-- invocación desde create_fiscal_document, ANTES del UPDATE que asocia
-- los payments), usamos el filtro viejo por order_id+check_id. Eso
-- mantiene la compatibilidad con el flujo actual sin invertir el orden
-- en create_fiscal_document.
--
-- Riesgo:
-- Cero — el filtro nuevo es estrictamente más completo que el viejo.
-- Cualquier payment que el filtro viejo capturaba, el nuevo también
-- lo captura (porque ya está linkeado al fd). Y captura adicionales
-- que el viejo perdía.
-- =============================================================================

CREATE OR REPLACE FUNCTION public.fn_recompute_fd_for_scope(
  p_fd_id    uuid,
  p_order_id uuid,
  p_check_id uuid
)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $function$
DECLARE
  v_scope_total      numeric(12,2);
  v_base_subtotal    numeric(12,2);
  v_base_tax         numeric(12,2);
  v_base_service_fee numeric(12,2);
  v_base_total       numeric(12,2);
  v_ratio            numeric(12,8);
  v_subtotal         numeric(12,2);
  v_itbis            numeric(12,2);
  v_service_fee      numeric(12,2);
  v_sum              numeric(12,2);
  v_residual         numeric(12,2);
BEGIN
  -- Prioridad 1: sumar payments linkeados directo al fd. Cubre el caso
  -- donde un payment de otro check_id terminó asociado a este fd
  -- (subcheck pagado por separado, backfill, re-asignación).
  SELECT COALESCE(SUM(p.amount - COALESCE(p.change_amount, 0)), 0)
    INTO v_scope_total
  FROM public.payments p
  WHERE p.fiscal_document_id = p_fd_id
    AND p.status = 'completed';

  -- Fallback: ningún payment linkeado todavía (primera invocación desde
  -- create_fiscal_document, antes del UPDATE que asocia payments al fd
  -- recién creado). Usar el filtro viejo para no romper ese flujo.
  IF v_scope_total = 0 THEN
    SELECT COALESCE(SUM(p.amount - COALESCE(p.change_amount, 0)), 0)
      INTO v_scope_total
    FROM public.payments p
    WHERE p.order_id = p_order_id
      AND p.status = 'completed'
      AND p.check_id IS NOT DISTINCT FROM p_check_id;
  END IF;

  IF v_scope_total <= 0 THEN
    RETURN;
  END IF;

  -- Base para prorrateo: totales del check o de la orden (sin cambios
  -- vs versión previa de la función).
  IF p_check_id IS NOT NULL THEN
    SELECT COALESCE(oc.subtotal, 0),
           COALESCE(oc.tax, 0),
           COALESCE(oc.service_fee, 0),
           COALESCE(oc.total, 0)
      INTO v_base_subtotal, v_base_tax, v_base_service_fee, v_base_total
    FROM public.order_checks oc
    WHERE oc.id = p_check_id;
  ELSE
    SELECT COALESCE(o.subtotal, 0),
           COALESCE(o.tax, 0),
           COALESCE(o.service_fee, 0),
           COALESCE(o.total, 0)
      INTO v_base_subtotal, v_base_tax, v_base_service_fee, v_base_total
    FROM public.orders o
    WHERE o.id = p_order_id;
  END IF;

  IF v_base_total > 0 THEN
    v_ratio       := v_scope_total / v_base_total;
    v_subtotal    := ROUND(v_base_subtotal * v_ratio, 2);
    v_itbis       := ROUND(v_base_tax * v_ratio, 2);
    v_service_fee := ROUND(v_base_service_fee * v_ratio, 2);
  ELSE
    v_subtotal    := v_scope_total;
    v_itbis       := 0;
    v_service_fee := 0;
  END IF;

  -- Ajuste residual: la suma debe cuadrar con v_scope_total.
  v_sum := v_subtotal + v_itbis + v_service_fee;
  v_residual := v_scope_total - v_sum;
  IF ABS(v_residual) > 0 AND ABS(v_residual) < 1 THEN
    v_subtotal := v_subtotal + v_residual;
  END IF;

  UPDATE public.fiscal_documents
  SET subtotal       = v_subtotal,
      taxable_amount = v_subtotal,
      itbis_amount   = v_itbis,
      service_fee    = v_service_fee,
      total          = v_scope_total
  WHERE id = p_fd_id;
END;
$function$;

COMMENT ON FUNCTION public.fn_recompute_fd_for_scope(uuid, uuid, uuid) IS
  'Recalcula fd.total y desglose para un fiscal_document. Suma payments por fiscal_document_id directo (fuente de verdad). Cae al filtro por order_id+check_id solo cuando no hay payments linkeados aún (primera invocación desde create_fiscal_document).';
