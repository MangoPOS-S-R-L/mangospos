-- =============================================================================
-- Fix v3: fn_recompute_fd_for_scope — fd.total matchea payments_net,
-- pero el excedente sobre base no infla los impuestos.
--
-- Historia de versiones:
--   v1 (0001): sumaba payments por fd_id, escalaba TODOS los componentes
--              por v_ratio. Bug: LEY > 10% del base cuando hay over-payment.
--   v2 (0005): capeaba al base_total cuando over-payment. Bug visible:
--              fd.total < payments_net, sales y facturado no matchean.
--   v3 (0010): ESTE script. fd.total = payments_net (matchea sales)
--              pero el excedente solo afecta subtotal (no impuestos).
--
-- Lógica final:
--   - scope_total < base_total (pago parcial):
--       escalar componentes proporcionalmente (comportamiento de v1)
--   - scope_total >= base_total (full o over-payment):
--       itbis_amount  = order.tax (sin inflar — solo impuesto sobre menú)
--       service_fee   = order.service_fee (sin inflar — solo LEY sobre menú)
--       subtotal      = order.subtotal + (scope_total - base_total)
--                       ← el excedente cae aquí como ingreso no gravable
--       total         = scope_total
--
-- Math en display:
--   Base + ITBIS + LEY = (subtotal_orig + excess) + tax + service_fee
--                      = order.total + excess
--                      = scope_total ✓ cuadra con Total facturado
--   LEY / Base = order.service_fee / (subtotal_orig + excess)
--              ≈ 10% (ligeramente menor si hay excess significativo,
--              pero el cálculo dice "10% sobre lo facturado del menú")
--
-- Trade-off explícito:
-- El NCF reporta a DGII el total transado (incluye propina) pero solo
-- factura impuestos sobre lo cobrado por items del menú. El excedente
-- queda como una porción del subtotal "no gravable" — interpretable
-- como propina/vuelto sin registrar.
--
-- Esto es lo que el negocio quería: ventas matchea facturado, sin
-- pagar ITBIS de más al fisco por propinas.
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
  v_sum              numeric(12,2);
  v_residual         numeric(12,2);
BEGIN
  -- Sumar payments linkeados directo al fd. Heredado de v1.
  SELECT COALESCE(SUM(p.amount - COALESCE(p.change_amount, 0)), 0)
    INTO v_scope_total
  FROM public.payments p
  WHERE p.fiscal_document_id = p_fd_id
    AND p.status = 'completed';

  -- Fallback al filtro por order/check si nadie linkeó payments todavía.
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

  -- Base de referencia: check o orden.
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

  IF v_base_total <= 0 THEN
    -- Sin base de referencia: confiamos en scope_total como subtotal sin
    -- desglose (edge case — no debería pasar para órdenes válidas).
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
    -- Pago full o over-payment:
    --   impuestos quedan sobre el MENÚ (base_tax/base_service_fee sin
    --   escalar), el excedente sobre base va al subtotal como ingreso
    --   no gravable. fd.total refleja lo realmente cobrado.
    v_subtotal    := v_base_subtotal + (v_scope_total - v_base_total);
    v_itbis       := v_base_tax;
    v_service_fee := v_base_service_fee;
    v_final_total := v_scope_total;
  END IF;

  -- Ajuste residual: si la suma de componentes difiere del total por
  -- menos de RD$1 (rounding), ajustar subtotal para cuadrar exacto.
  v_sum := v_subtotal + v_itbis + v_service_fee;
  v_residual := v_final_total - v_sum;
  IF ABS(v_residual) > 0 AND ABS(v_residual) < 1 THEN
    v_subtotal := v_subtotal + v_residual;
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
  'Recompute fd con 3 modos: parcial (prorrateo), full (base 1:1), over-payment (excedente al subtotal sin tax). fd.total siempre matchea payments_net. Impuestos solo sobre el menú real.';
