-- Revierte solo el comportamiento de la función a v6. No reescribe documentos
-- ni pagos; conserva delivery_fee y la marca de snapshots para no perder
-- información emitida durante el despliegue. Reinstalar la migración es seguro.
BEGIN;
SET LOCAL lock_timeout = '5s';
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
  v_rate_ecf      numeric := 0;   -- suma de tasas que SI se declaran
  v_rate_non_ecf  numeric := 0;   -- suma de tasas que NO se declaran
  v_rate_all      numeric := 0;
  v_usa_flag      boolean := false;
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

  SELECT fd.business_id INTO v_biz
  FROM public.fiscal_documents fd WHERE fd.id = p_fd_id;

  -- 2. Tasas del negocio, agrupadas en "se declara" vs "no se declara".
  --
  --    FUENTE PRIMARIA: taxes.include_in_ecf, el interruptor de
  --    Ajustes > Impuestos. Es lo que el negocio configura y es la fuente
  --    correcta.
  --
  --    PERO sólo se usa SI EL NEGOCIO YA LO CONFIGURÓ, o sea si tiene al menos
  --    un impuesto activo marcado como NO declarable. El backfill de
  --    20260506_0004 dejó include_in_ecf = NOT is_service_fee, así que un
  --    negocio que nunca tocó el interruptor tiene TODO en true; si nos
  --    fiáramos de eso a ciegas, declararíamos la Ley 10% como ITBIS.
  --
  --    RESPALDO mientras nadie lo haya configurado: el nombre del impuesto.
  --    Es una convención, sí, pero acierta hoy y NO EXIGE TOCAR NADA EN UN
  --    NEGOCIO EN PRODUCCIÓN. El día que alguien apague el interruptor de la
  --    Ley, la configuración toma el control sola y este respaldo deja de usarse.
  SELECT EXISTS (
    SELECT 1 FROM public.taxes t
    WHERE t.business_id = v_biz
      AND COALESCE(t.is_active, true)
      AND COALESCE(t.include_in_ecf, true) = false
  ) INTO v_usa_flag;

  IF v_usa_flag THEN
    SELECT
      COALESCE(SUM(t.rate) FILTER (WHERE     COALESCE(t.include_in_ecf, true)), 0),
      COALESCE(SUM(t.rate) FILTER (WHERE NOT COALESCE(t.include_in_ecf, true)), 0)
      INTO v_rate_ecf, v_rate_non_ecf
    FROM public.taxes t
    WHERE t.business_id = v_biz AND COALESCE(t.is_active, true);
  ELSE
    SELECT
      COALESCE(SUM(t.rate) FILTER (WHERE upper(t.name) LIKE     '%ITBIS%'), 0),
      COALESCE(SUM(t.rate) FILTER (WHERE upper(t.name) NOT LIKE '%ITBIS%'), 0)
      INTO v_rate_ecf, v_rate_non_ecf
    FROM public.taxes t
    WHERE t.business_id = v_biz AND COALESCE(t.is_active, true);
  END IF;

  -- Si el respaldo por nombre tampoco separa nada (negocio de un solo impuesto,
  -- o nomenclatura distinta), todo queda como declarable. Es el comportamiento
  -- correcto para un negocio con un único ITBIS.
  v_rate_all := v_rate_ecf + v_rate_non_ecf;

  -- 3. Base + split ITBIS/LEY desde los ÍTEMS del scope, partiendo oi.tax
  --    (lo REALMENTE cobrado) según la tasa de cada ítem.
  --    LEY = impuesto - ITBIS, para que la suma cierre al centavo.
  SELECT
    COUNT(*),
    COALESCE(SUM(oi.subtotal), 0),
    COALESCE(SUM(x.itbis_item), 0),
    COALESCE(SUM(COALESCE(oi.tax, 0) - x.itbis_item), 0),
    COALESCE(SUM(oi.total), 0)
    INTO v_item_count, v_base_subtotal, v_base_itbis, v_base_ley, v_base_total
  FROM public.order_items oi
  CROSS JOIN LATERAL (
    SELECT CASE
      -- el item lleva TODOS los impuestos configurados (ej. 28 = 18 + 10)
      WHEN v_rate_all > 0 AND abs(oi.tax_rate - v_rate_all) < 0.5
        THEN ROUND(COALESCE(oi.tax, 0) * v_rate_ecf / v_rate_all, 2)
      -- el item lleva solo los declarables (ej. 18)
      WHEN v_rate_ecf > 0 AND abs(oi.tax_rate - v_rate_ecf) < 0.5
        THEN COALESCE(oi.tax, 0)
      -- el item lleva solo los NO declarables (ej. 10 de propina sola)
      WHEN v_rate_non_ecf > 0 AND abs(oi.tax_rate - v_rate_non_ecf) < 0.5
        THEN 0
      -- No encaja en ningun patron. AQUI ANTES HABIA UN `ELSE 0` y es lo que
      -- costo los RD$ 474 mil: el impuesto cobrado desaparecia en silencio.
      -- Se reparte en la proporcion configurada; nunca se pierde.
      WHEN v_rate_all > 0
        THEN ROUND(COALESCE(oi.tax, 0) * v_rate_ecf / v_rate_all, 2)
      -- Sin impuestos configurados: se declara todo (errar hacia declarar de mas).
      ELSE COALESCE(oi.tax, 0)
    END AS itbis_item
  ) x
  WHERE oi.status <> 'void'
    AND (
      (p_check_id IS NOT NULL AND oi.check_id = p_check_id)
      OR (p_check_id IS NULL AND oi.order_id = p_order_id)
    );

  -- SAFEGUARD: comprobante sin ítems en su scope (manual/huérfano) → no tocar.
  IF v_item_count = 0 THEN
    RETURN;
  END IF;

  -- 4. Prorrateo (idéntico a v4/v5): partial vs full/over-payment.
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
  'v6: itbis_amount = impuestos declarables, service_fee = el resto. Manda '
  'taxes.include_in_ecf (Ajustes > Impuestos) SI el negocio ya lo configuro; si no, '
  'respaldo por nombre del impuesto. is_service_fee ya no se usa. '
  'Sin ELSE 0: un impuesto cobrado nunca desaparece del comprobante. '
  'LEY = impuesto - ITBIS para cerrar al centavo. No usa order_item_tax_lines.';

COMMIT;
