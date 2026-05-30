-- Rollback de 20260530_0001. Vuelve a la versión que filtraba por
-- check_id (introducida en 20260513_0002_fd_per_container.sql).
-- Si se revierte, vuelve a subreportarse fd.total para payments
-- cross-check linkeados al mismo fd.

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
  SELECT COALESCE(SUM(p.amount - COALESCE(p.change_amount, 0)), 0)
    INTO v_scope_total
  FROM public.payments p
  WHERE p.order_id = p_order_id
    AND p.status = 'completed'
    AND p.check_id IS NOT DISTINCT FROM p_check_id;

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
