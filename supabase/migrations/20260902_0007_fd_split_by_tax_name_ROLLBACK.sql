-- ROLLBACK de 20260902_0007_fd_split_by_tax_name.sql
-- Restaura fn_recompute_fd_for_scope v5 (20260610_0001), la que clasificaba
-- ITBIS/LEY por taxes.is_service_fee.
--
-- OJO: volver a la v5 REINTRODUCE el bug H-1 del 607 — los comprobantes con
-- productos al 28% vuelven a guardarse con itbis_amount = 0. Solo usar si el
-- cambio de criterio rompió algo en otro negocio.
--
-- NO deshace ningún backfill: los comprobantes ya corregidos quedan corregidos.

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
  v_scope_total   numeric(12,2);
  v_biz           uuid;
  v_itbis_rate    numeric := 0;   -- tasa ITBIS del negocio (is_service_fee=false)
  v_ley_rate      numeric := 0;   -- tasa LEY  del negocio (is_service_fee=true)
  v_item_count    int := 0;
  v_base_subtotal numeric(12,2) := 0;
  v_base_itbis    numeric(12,2) := 0;
  v_base_ley      numeric(12,2) := 0;
  v_base_total    numeric(12,2) := 0;
  v_ratio         numeric(12,8);
  v_subtotal      numeric(12,2);
  v_itbis         numeric(12,2);
  v_ley           numeric(12,2);
  v_final_total   numeric(12,2);
BEGIN
  -- 1. Total cobrado del scope (pagos del FD, o del scope orden/check).
  SELECT COALESCE(SUM(p.amount - COALESCE(p.change_amount, 0)), 0)
    INTO v_scope_total
  FROM public.payments p
  WHERE p.fiscal_document_id = p_fd_id AND p.status = 'completed';

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

  -- 2. Tasas de impuesto del negocio (config-driven; no se asume 18/10).
  SELECT fd.business_id INTO v_biz
  FROM public.fiscal_documents fd WHERE fd.id = p_fd_id;

  SELECT
    COALESCE(MAX(t.rate) FILTER (WHERE NOT COALESCE(t.is_service_fee, false)), 0),
    COALESCE(MAX(t.rate) FILTER (WHERE COALESCE(t.is_service_fee, false)), 0)
    INTO v_itbis_rate, v_ley_rate
  FROM public.taxes t
  WHERE t.business_id = v_biz AND COALESCE(t.is_active, true);

  -- 3. Base + split ITBIS/LEY desde los ÍTEMS del scope (orden o check),
  --    partiendo oi.tax por la tasa de cada ítem.
  SELECT
    COUNT(*),
    COALESCE(SUM(oi.subtotal), 0),
    COALESCE(SUM(
      CASE
        -- ítem con ITBIS+LEY combinados (ej. 28 = 18+10)
        WHEN v_itbis_rate > 0 AND v_ley_rate > 0
             AND abs(oi.tax_rate - (v_itbis_rate + v_ley_rate)) < 0.5
          THEN ROUND(oi.tax * v_itbis_rate / (v_itbis_rate + v_ley_rate), 2)
        -- ítem solo ITBIS (ej. 18) — incluye agua 18%-solo
        WHEN v_itbis_rate > 0 AND abs(oi.tax_rate - v_itbis_rate) < 0.5
          THEN oi.tax
        -- ítem solo LEY (ej. 10) o exento (0) → 0 de ITBIS
        ELSE 0
      END), 0),
    COALESCE(SUM(
      CASE
        WHEN v_itbis_rate > 0 AND v_ley_rate > 0
             AND abs(oi.tax_rate - (v_itbis_rate + v_ley_rate)) < 0.5
          THEN ROUND(oi.tax * v_ley_rate / (v_itbis_rate + v_ley_rate), 2)
        WHEN v_ley_rate > 0 AND abs(oi.tax_rate - v_ley_rate) < 0.5
          THEN oi.tax
        ELSE 0
      END), 0),
    COALESCE(SUM(oi.total), 0)
    INTO v_item_count, v_base_subtotal, v_base_itbis, v_base_ley, v_base_total
  FROM public.order_items oi
  WHERE oi.status <> 'void'
    AND (
      (p_check_id IS NOT NULL AND oi.check_id = p_check_id)
      OR (p_check_id IS NULL AND oi.order_id = p_order_id)
    );

  -- SAFEGUARD: comprobante sin ítems en su scope (manual/huérfano) → no tocar.
  IF v_item_count = 0 THEN
    RETURN;
  END IF;

  -- 4. Prorrateo (idéntico a v4): partial vs full/over-payment.
  IF v_base_total <= 0 THEN
    v_subtotal    := v_scope_total;
    v_itbis       := 0;
    v_ley         := 0;
    v_final_total := v_scope_total;
  ELSIF v_scope_total < v_base_total THEN
    v_ratio       := v_scope_total / v_base_total;
    v_subtotal    := ROUND(v_base_subtotal * v_ratio, 2);
    v_itbis       := ROUND(v_base_itbis * v_ratio, 2);
    v_ley         := ROUND(v_base_ley * v_ratio, 2);
    v_final_total := v_scope_total;
  ELSE
    v_subtotal    := v_base_subtotal;
    v_itbis       := v_base_itbis;
    v_ley         := v_base_ley;
    v_final_total := v_scope_total;
  END IF;

  UPDATE public.fiscal_documents
  SET subtotal       = v_subtotal,
      taxable_amount = v_subtotal,
      itbis_amount   = v_itbis,
      service_fee    = v_ley,
      total          = v_final_total
  WHERE id = p_fd_id;
END;
$function$;

COMMENT ON FUNCTION public.fn_recompute_fd_for_scope(uuid, uuid, uuid) IS
  'v5: itbis_amount/service_fee derivados de los ítems del scope, split por las tasas de taxes (config-driven). No toca FDs sin ítems. Conserva prorrateo.';
