-- 20260902_0007_fd_split_by_tax_name.sql
-- H-1 de la auditoria del 607 de La Penda Express (DH Asociados, 31-ago-2026):
-- 1.977 comprobantes de agosto con itbis_amount = 0 y RD$ 725.510,57 de impuesto
-- cobrado sin desglosar. Declarar el 607 desde el registro fiscal sub-declara
-- ITBIS por unos RD$ 474 mil.
--
-- CAUSA RAIZ (medida en produccion el 2026-09-01)
--   fn_recompute_fd_for_scope v5 decide que va en itbis_amount y que va en
--   service_fee leyendo `taxes.is_service_fee`. Esa bandera esta SIEMPRE en
--   false (activarla hace que el servidor incluya la Ley dentro de oi.tax y el
--   cliente la vuelva a sacar aparte al imprimir: factura duplicada), asi que
--   v_ley_rate queda en 0 y un item al 28% no encaja en NINGUNA rama del CASE:
--       rama 1 (combinado) exige v_ley_rate > 0   -> no entra
--       rama 2 (solo ITBIS) exige |28 - 18| < 0.5 -> no entra
--       ELSE                                      -> ITBIS 0 y LEY 0
--   Medido: ley_rate_que_calcula = 0.00. Falla SOLO en comprobantes con
--   productos de Ley 10%; los de 18% puro caen en la rama 2 y se guardan bien.
--
--   Caso testigo B0200154176 (2026-08-02, 40 lineas al 28%):
--       base 12.923,39 - impuesto cobrado 3.618,55
--       correcto: ITBIS 2.326,21 + LEY 1.292,34   |   guardado: 0,00 + 0,00
--
-- EL ARREGLO: USAR LA BANDERA QUE EL NEGOCIO YA CONFIGURA
--   `taxes.include_in_ecf` existe desde 20260506_0004, tiene interruptor en
--   Ajustes > Impuestos y significa exactamente esto: "este impuesto se declara
--   a la DGII". La APP YA LA USA -- reports_repository.dart lo dice textual:
--   "Ya NO se usa is_service_fee (config fantasma sin UI)". La unica pieza que
--   se quedo en la bandera vieja era esta funcion.
--
--       itbis_amount <- impuestos con include_in_ecf = true
--       service_fee  <- impuestos con include_in_ecf = false
--
--   Con eso el reparto deja de ser una convencion cableada y pasa a ser lo que
--   el negocio marca en su pantalla de Impuestos. No se toca is_service_fee.
--
--   NO EXIGE TOCAR NADA EN PRODUCCION. El backfill de 20260506_0004 dejo
--   include_in_ecf = NOT is_service_fee, asi que un negocio que nunca toco el
--   interruptor tiene TODO marcado como declarable; fiarse de eso a ciegas
--   declararia la Ley 10% como ITBIS. Por eso el interruptor manda SOLO SI EL
--   NEGOCIO YA LO CONFIGURO (tiene al menos un impuesto activo en false).
--   Mientras tanto, el respaldo es el nombre del impuesto: acierta hoy y no
--   requiere cambiar la configuracion de un negocio vivo. El dia que se apague
--   el interruptor de la Ley, la configuracion toma el control sola.
--
--   Aclaracion: include_in_ecf NO afecta el COBRO. Ninguna funcion de la ruta
--   de cobro la lee (fn_resolve_order_item_tax_profile y
--   fn_populate_item_tax_lines filtran por is_active, apply_on_* y exclusiones
--   por orden, nunca por esta bandera), y en la app su unico consumidor es un
--   aviso visual en el dialogo de quitar impuestos. Responde "se declara a la
--   DGII", no "se cobra".
--
-- ADEMAS: SE ELIMINA EL `ELSE 0` QUE COSTO LOS RD$ 474 MIL
--   Antes, un item cuya tasa no encajaba en ningun patron conocido perdia TODO
--   su impuesto en silencio. Ahora, si no encaja, se reparte en la proporcion
--   configurada en vez de tirarse a cero: ningun impuesto cobrado puede
--   desaparecer del comprobante, pase lo que pase con la config.
--
--   Tambien se suman las tasas por grupo en vez de tomar el MAX, para que
--   funcione con mas de dos impuestos configurados.
--
--   Y la LEY pasa a calcularse como (impuesto - ITBIS) en vez de redondearse
--   por separado, para que ITBIS + LEY cierre contra lo cobrado al centavo.
--
-- QUE NO HACE
--   * NO corre backfill. Los comprobantes YA emitidos quedan intactos: solo
--     afecta los recomputes nuevos. El backfill va aparte (BACKFILL_607_penda.sql).
--   * NO usa order_item_tax_lines. Esa tabla se escribe con DELETE+INSERT desde
--     menu_item_taxes AL FACTURAR, mientras oi.tax se congela al AGREGAR el item:
--     en prod hay items cobrados al 18% cuyas lineas dicen 28%.
--   * NO toca POS, ordenes, items, pagos, impresion ni la app.
--
-- ROLLBACK: 20260902_0007_fd_split_by_tax_name_ROLLBACK.sql (restaura la v5)
-- Idempotente.

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
