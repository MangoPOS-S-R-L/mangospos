-- =============================================================================
-- Fix v4 (FINAL): fn_recompute_fd_for_scope.
--
-- Diferencia con v3 (0010):
-- v3 metía el excedente en fd.subtotal, lo cual inflaba la "Base gravable"
-- mostrada en el reporte y diluía el ratio ITBIS efectivo (de 17.11% a
-- 16.69% en el caso observado).
--
-- v4 mantiene fd.subtotal = order.subtotal (solo el menú real, gravable).
-- El excedente queda implícito en la diferencia fd.total - sum(componentes).
-- La UI debe mostrar ese gap explícitamente como "Excedente no gravable".
--
-- Resumen de las versiones:
--   v1 (0001): escalaba todo por v_ratio → LEY > 10% del base
--   v2 (0005): capeaba al base_total → Total ≠ Ventas
--   v3 (0010): excess al subtotal → Total = Ventas pero ratios diluidos
--   v4 (0012): FINAL → componentes limpios del menú + fd.total = payments
--
-- Lógica por modo:
--   - scope_total < base_total (parcial):
--       escalar proporcional (heredado de v1)
--   - scope_total >= base_total (full o over-payment):
--       subtotal = order.subtotal (sin tocar, gravable real del menú)
--       itbis_amount = order.tax (sin tocar)
--       service_fee = order.service_fee (sin tocar)
--       total = scope_total (lo cobrado realmente, incluye tip)
--       → diff implícita: tip = total - subtotal - itbis - service_fee
--
-- Math en display:
--   Base + ITBIS + LEY < Total (cuando hay tip)
--   La UI muestra el gap como "Excedente no gravable: X"
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
    -- Pago parcial: prorratear proporcionalmente.
    v_ratio       := v_scope_total / v_base_total;
    v_subtotal    := ROUND(v_base_subtotal * v_ratio, 2);
    v_itbis       := ROUND(v_base_tax * v_ratio, 2);
    v_service_fee := ROUND(v_base_service_fee * v_ratio, 2);
    v_final_total := v_scope_total;
  ELSE
    -- Pago full o over-payment: componentes limpios del menú, total
    -- refleja lo cobrado. La diferencia queda implícita.
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
