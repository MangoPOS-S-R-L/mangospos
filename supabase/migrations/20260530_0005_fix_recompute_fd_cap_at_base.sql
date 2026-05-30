-- =============================================================================
-- Fix v2: fn_recompute_fd_for_scope no debe escalar ITBIS/service_fee
-- cuando `scope_total > base_total` (over-payment).
--
-- Bug residual observado tras backfill del 2026-05-30:
-- La versión 20260530_0001 corrigió el filtro de payments (usar
-- fiscal_document_id directo en vez de check_id), lo que hizo que el
-- backfill capturara los 17,560 de payments perdidos. Pero la lógica
-- de prorrateo sigue escalando subtotal, itbis_amount y service_fee
-- multiplicando por v_ratio = scope_total / base_total. Cuando el
-- cliente pagó MÁS que el total facturado (por vuelto sin registrar,
-- propina voluntaria, etc.), ratio > 1 y la LEY se infla.
--
-- Síntoma visible: tras backfill, "LEY 10%" pasó a mostrar 10.50% del
-- base — los componentes fiscales se llevaron parte del excedente que
-- no es base gravable real.
--
-- Lógica correcta para DGII:
-- El NCF reporta lo FACTURADO, no lo cobrado en exceso. Cuando el
-- cliente paga más, ese excedente es vuelto/propina/error de captura
-- y NO debe inflar los componentes del comprobante fiscal:
--
--   - scope_total <  base_total (pago parcial): escalar todos los
--     componentes proporcionalmente (comportamiento previo, correcto)
--   - scope_total >= base_total (full o over-payment): usar los
--     valores del base 1:1, sin escalar. fd.total queda capado al
--     base_total para reflejar el monto realmente facturado.
--
-- Trade-off explícito:
-- Con esta versión, sum(fd.total) puede ser MENOR que sum(payments_net)
-- — el delta es el excedente que el cliente pagó pero el negocio no
-- facturó (vuelto sin registrar, tip). Eso es lo correcto fiscalmente:
-- DGII no debe ver propina como ingreso, y vuelto sin registrar es un
-- problema operativo del cajero, no facturable.
--
-- Si el negocio quiere capturar esos excedentes para auditoría
-- operativa (cash overage / tip reconciliation), conviene una tabla
-- separada o un campo `tip_amount` en payments — NO el fd.total.
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
  -- Prioridad 1: sumar payments linkeados directo al fd (heredado de
  -- la migración 20260530_0001).
  SELECT COALESCE(SUM(p.amount - COALESCE(p.change_amount, 0)), 0)
    INTO v_scope_total
  FROM public.payments p
  WHERE p.fiscal_document_id = p_fd_id
    AND p.status = 'completed';

  -- Fallback al filtro viejo si no hay payments linkeados aún.
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

  -- Base para el cómputo: totales del check o de la orden.
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
    -- desglose (caso edge — no debería pasar para órdenes válidas).
    v_subtotal    := v_scope_total;
    v_itbis       := 0;
    v_service_fee := 0;
    v_final_total := v_scope_total;
  ELSIF v_scope_total < v_base_total THEN
    -- Pago parcial: prorratear componentes proporcionalmente para
    -- que la suma cuadre exactamente con lo cobrado. Caso típico:
    -- cliente paga la mitad ahora y la otra mitad luego.
    v_ratio       := v_scope_total / v_base_total;
    v_subtotal    := ROUND(v_base_subtotal * v_ratio, 2);
    v_itbis       := ROUND(v_base_tax * v_ratio, 2);
    v_service_fee := ROUND(v_base_service_fee * v_ratio, 2);
    v_final_total := v_scope_total;
  ELSE
    -- Pago full o over-payment: el NCF refleja lo FACTURADO (base),
    -- no lo cobrado en exceso. Componentes se toman 1:1 del base,
    -- fd.total se capa al base_total. El excedente (scope_total -
    -- base_total) queda fuera del comprobante fiscal.
    v_subtotal    := v_base_subtotal;
    v_itbis       := v_base_tax;
    v_service_fee := v_base_service_fee;
    v_final_total := v_base_total;
  END IF;

  -- Ajuste residual: si por redondeo la suma de componentes difiere
  -- del total final por menos de RD$1, ajustar subtotal para cuadrar.
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
  'Recalcula fd a partir de payments linkeados. Pago parcial → prorratea. Pago full/over → toma componentes del base 1:1 (fd.total capado). El NCF refleja lo facturado, no el excedente cobrado.';
