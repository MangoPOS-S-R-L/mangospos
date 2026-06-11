-- =============================================================================
-- ROLLBACK de 20260610_0001_fd_itbis_split_from_items.sql
-- Re-crea fn_recompute_fd_for_scope v4 (tal cual 20260530_0012_keep_base_only).
-- Volver a v4 reintroduce el bug (itbis = order.tax) — solo para revertir si el
-- DRY-RUN/QA del v5 no convence.
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
  v_final_total      numeric(12,2);
BEGIN
  SELECT COALESCE(SUM(p.amount - COALESCE(p.change_amount, 0)), 0)
    INTO v_scope_total
  FROM public.payments p
  WHERE p.fiscal_document_id = p_fd_id
    AND p.status = 'completed';

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

  IF p_check_id IS NOT NULL THEN
    SELECT COALESCE(oc.subtotal, 0), COALESCE(oc.tax, 0),
           COALESCE(oc.service_fee, 0), COALESCE(oc.total, 0)
      INTO v_base_subtotal, v_base_tax, v_base_service_fee, v_base_total
    FROM public.order_checks oc WHERE oc.id = p_check_id;
  ELSE
    SELECT COALESCE(o.subtotal, 0), COALESCE(o.tax, 0),
           COALESCE(o.service_fee, 0), COALESCE(o.total, 0)
      INTO v_base_subtotal, v_base_tax, v_base_service_fee, v_base_total
    FROM public.orders o WHERE o.id = p_order_id;
  END IF;

  IF v_base_total <= 0 THEN
    v_subtotal    := v_scope_total;
    v_itbis       := 0;
    v_service_fee := 0;
    v_final_total := v_scope_total;
  ELSIF v_scope_total < v_base_total THEN
    v_ratio       := v_scope_total / v_base_total;
    v_subtotal    := ROUND(v_base_subtotal * v_ratio, 2);
    v_itbis       := ROUND(v_base_tax * v_ratio, 2);
    v_service_fee := ROUND(v_base_service_fee * v_ratio, 2);
    v_final_total := v_scope_total;
  ELSE
    v_subtotal    := v_base_subtotal;
    v_itbis       := v_base_tax;
    v_service_fee := v_base_service_fee;
    v_final_total := v_scope_total;
  END IF;

  UPDATE public.fiscal_documents
  SET subtotal       = v_subtotal,
      taxable_amount = v_subtotal,
      itbis_amount   = v_itbis,
      service_fee    = v_service_fee,
      total          = v_final_total
  WHERE id = p_fd_id;
END;
$function$;

COMMENT ON FUNCTION public.fn_recompute_fd_for_scope(uuid, uuid, uuid) IS
  'v4 FINAL: componentes (subtotal/itbis/service_fee) reflejan el menú real, fd.total refleja payments_net. La diferencia es el excedente no gravable (propina/vuelto), implícito.';
