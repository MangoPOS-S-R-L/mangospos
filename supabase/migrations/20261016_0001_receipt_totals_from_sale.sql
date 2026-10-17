-- El importe de un NCF describe la venta, no el dinero entregado al cobrar.
-- Caso reproducido: productos por 6,800 y pago de 6,900 dejaban base 5,312.50,
-- ITBIS 956.25 y Ley 531.25, pero total 6,900. La primera impresión sumaba
-- productos y el historial imprimía ese total guardado: dos totales para el NCF.
--
-- No hay backfill de importes ni UPDATE de pagos. La marca inicial preserva
-- documentos cerrados; los preemitidos de scopes abiertos quedan pendientes.
-- El único UPDATE de documentos al instalar cambia esa marca de metadata,
-- sin alterar subtotal, impuestos, descuentos, total ni referencias de cobro.
-- El recálculo al cerrar fija y bloquea el snapshot de venta.
-- Un documento preemitido con abonos puede seguir creciendo hasta el cierre.
-- Los abonos, el vuelto y los excedentes siguen íntegros en payments.
BEGIN;
SET LOCAL lock_timeout = '5s';

-- Subtotal anterior al descuento en ambos modos, contrato de 20260630_0001.
-- Evitar desplegar esta suma sobre un servidor con el motor legacy que ya
-- había restado discounts dentro de subtotal.
DO $$
DECLARE v_body text;
BEGIN
  SELECT regexp_replace(lower(prosrc), '[[:space:]]+', ' ', 'g') INTO v_body
  FROM pg_proc WHERE oid = to_regprocedure('public.fn_compute_item_totals()');
  IF v_body IS NULL
     OR position('new.subtotal := v_net_subtotal;' in v_body) = 0
     OR position('new.subtotal := v_line_amount;' in v_body) = 0
     OR position('new.total := new.subtotal + new.tax - coalesce(new.discounts, 0);' in v_body) = 0 THEN
    RAISE EXCEPTION 'No se verificó el contrato de precios anterior al descuento. Revisar 20260630_0001 antes de aplicar los totales del comprobante.';
  END IF;
END;
$$;

ALTER TABLE public.fiscal_documents
  ADD COLUMN IF NOT EXISTS delivery_fee numeric(12,2) NOT NULL DEFAULT 0;
DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM pg_attribute
    WHERE attrelid = 'public.fiscal_documents'::regclass
      AND attname = 'sale_totals_locked' AND NOT attisdropped
  ) THEN
    ALTER TABLE public.fiscal_documents
      ADD COLUMN sale_totals_locked boolean NOT NULL DEFAULT true;
    -- Cambiar SOLO la marca, nunca importes. Un FD previo de un abono puede
    -- pertenecer a una cuenta aún abierta; debe incluir el consumo posterior
    -- al cerrarla. Esta inicialización corre solo al crear la columna: una
    -- reinstalación no desbloquea snapshots definitivos ya congelados.
    UPDATE public.fiscal_documents fd SET sale_totals_locked = false
    WHERE (fd.check_id IS NULL AND EXISTS (
      SELECT 1 FROM public.orders o WHERE o.id = fd.order_id AND o.closed_at IS NULL
    )) OR (fd.check_id IS NOT NULL AND EXISTS (
      SELECT 1 FROM public.order_checks c
      WHERE c.id = fd.check_id AND c.order_id = fd.order_id AND NOT COALESCE(c.is_closed, false)
    ));
  END IF;
END;
$$;
ALTER TABLE public.fiscal_documents
  ALTER COLUMN sale_totals_locked SET DEFAULT false;

COMMENT ON COLUMN public.fiscal_documents.delivery_fee IS
  'Cargo exento de delivery del documento; snapshot independiente del saldo actual de la orden.';
COMMENT ON COLUMN public.fiscal_documents.sale_totals_locked IS
  'Importes definitivos al cerrar orden/check, inmutables ante cambios en pagos. Preserva comprobantes previos cerrados; los preemitidos abiertos se fijan al cerrar.';

CREATE OR REPLACE FUNCTION public.fn_recompute_fd_for_scope(
  p_fd_id uuid,
  p_order_id uuid,
  p_check_id uuid
)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $function$
DECLARE
  v_doc public.fiscal_documents;
  v_rate_ecf numeric := 0;
  v_rate_non_ecf numeric := 0;
  v_rate_all numeric := 0;
  v_usa_flag boolean := false;
  v_item_count int := 0;
  v_subtotal numeric(12,2) := 0;
  v_itbis numeric(12,2) := 0;
  v_ley numeric(12,2) := 0;
  v_discount numeric(12,2) := 0;
  v_delivery numeric(12,2) := 0;
  v_total numeric(12,2) := 0;
  v_scope_closed boolean := false;
BEGIN
  SELECT * INTO v_doc
  FROM public.fiscal_documents WHERE id = p_fd_id FOR UPDATE;
  IF NOT FOUND OR v_doc.sale_totals_locked THEN
    RETURN;
  END IF;
  IF v_doc.order_id IS DISTINCT FROM p_order_id
     OR v_doc.check_id IS DISTINCT FROM p_check_id THEN
    RAISE EXCEPTION 'FISCAL_DOCUMENT_SCOPE_MISMATCH';
  END IF;
  -- Las notas de crédito/débito tienen su propio snapshot y no son ventas.
  IF v_doc.ncf_type::text IN ('B03', 'B04', 'E33', 'E34') THEN
    RETURN;
  END IF;
  -- Normalmente se emite al cierre, pero el RPC también permite preemitir
  -- sobre un abono. En esa cuenta aún se pueden agregar productos. Usar el
  -- mismo estado de cierre que fn_sales_note_policy_scope; nunca fijarlo por
  -- el primer enlace de un pago ni por la suma de sus importes.
  IF p_check_id IS NULL THEN
    SELECT closed_at IS NOT NULL INTO v_scope_closed
    FROM public.orders WHERE id = p_order_id;
  ELSE
    SELECT COALESCE(is_closed, false) INTO v_scope_closed
    FROM public.order_checks WHERE id = p_check_id AND order_id = p_order_id;
  END IF;

  -- Mismo reparto ITBIS/Ley que v6: configuración explícita si existe;
  -- en negocios que aún no la configuraron, respaldo por nombre del impuesto.
  SELECT EXISTS (
    SELECT 1 FROM public.taxes t
    WHERE t.business_id = v_doc.business_id
      AND COALESCE(t.is_active, true)
      AND NOT COALESCE(t.include_in_ecf, true)
  ) INTO v_usa_flag;
  IF v_usa_flag THEN
    SELECT
      COALESCE(SUM(t.rate) FILTER (WHERE COALESCE(t.include_in_ecf, true)), 0),
      COALESCE(SUM(t.rate) FILTER (WHERE NOT COALESCE(t.include_in_ecf, true)), 0)
      INTO v_rate_ecf, v_rate_non_ecf
    FROM public.taxes t
    WHERE t.business_id = v_doc.business_id AND COALESCE(t.is_active, true);
  ELSE
    SELECT
      COALESCE(SUM(t.rate) FILTER (WHERE upper(t.name) LIKE '%ITBIS%'), 0),
      COALESCE(SUM(t.rate) FILTER (WHERE upper(t.name) NOT LIKE '%ITBIS%'), 0)
      INTO v_rate_ecf, v_rate_non_ecf
    FROM public.taxes t
    WHERE t.business_id = v_doc.business_id AND COALESCE(t.is_active, true);
  END IF;
  v_rate_all := v_rate_ecf + v_rate_non_ecf;

  SELECT COUNT(*), COALESCE(SUM(oi.subtotal), 0),
         COALESCE(SUM(x.itbis_item), 0),
         COALESCE(SUM(COALESCE(oi.tax, 0) - x.itbis_item), 0),
         COALESCE(SUM(oi.discounts), 0)
    INTO v_item_count, v_subtotal, v_itbis, v_ley, v_discount
  FROM public.order_items oi
  CROSS JOIN LATERAL (
    SELECT CASE
      WHEN v_rate_all > 0 AND abs(oi.tax_rate - v_rate_all) < 0.5
        THEN ROUND(COALESCE(oi.tax, 0) * v_rate_ecf / v_rate_all, 2)
      WHEN v_rate_ecf > 0 AND abs(oi.tax_rate - v_rate_ecf) < 0.5
        THEN COALESCE(oi.tax, 0)
      WHEN v_rate_non_ecf > 0 AND abs(oi.tax_rate - v_rate_non_ecf) < 0.5
        THEN 0
      WHEN v_rate_all > 0
        THEN ROUND(COALESCE(oi.tax, 0) * v_rate_ecf / v_rate_all, 2)
      ELSE COALESCE(oi.tax, 0)
    END AS itbis_item
  ) x
  WHERE oi.order_id = p_order_id AND oi.status <> 'void'
    AND (
      (p_check_id IS NOT NULL AND oi.check_id = p_check_id)
      OR (p_check_id IS NULL AND (
        oi.check_id IS NULL OR (
          NOT EXISTS (
            SELECT 1 FROM public.fiscal_documents other
            WHERE other.order_id = p_order_id AND other.check_id = oi.check_id
              AND other.id <> p_fd_id AND other.status = 'active'
              AND other.ncf_type::text NOT IN ('B03', 'B04', 'E33', 'E34')
          )
          AND NOT EXISTS (
            SELECT 1 FROM public.sales_notes note
            WHERE note.order_id = p_order_id AND note.check_id = oi.check_id
              AND note.status = 'active'
          )
        )
      ))
    );
  IF v_item_count = 0 THEN
    -- No inventar un documento de mercancía a partir de un pago huérfano.
    RAISE EXCEPTION 'FISCAL_DOCUMENT_ITEMS_MISSING';
  END IF;

  -- El cargo pertenece al documento de la orden; una subcuenta no lo duplica.
  IF p_check_id IS NULL THEN
    SELECT COALESCE(delivery_fee, 0) INTO v_delivery
    FROM public.orders WHERE id = p_order_id;
  END IF;
  v_total := ROUND(v_subtotal + v_itbis + v_ley - v_discount + v_delivery, 2);
  IF v_total < 0 THEN
    RAISE EXCEPTION 'FISCAL_DOCUMENT_NEGATIVE_SALE_TOTAL';
  END IF;

  UPDATE public.fiscal_documents
  SET subtotal = v_subtotal, taxable_amount = v_subtotal,
      itbis_amount = v_itbis, service_fee = v_ley, delivery_fee = v_delivery,
      total = v_total, sale_totals_locked = COALESCE(v_scope_closed, false)
  WHERE id = p_fd_id;
END;
$function$;

COMMENT ON FUNCTION public.fn_recompute_fd_for_scope(uuid, uuid, uuid) IS
  'v7: importes de la venta del scope, incluidos descuentos y delivery; definitivos al cerrar. '
  'Pagos/abonos/excedentes no cambian el total emitido. Preserva documentos previos y '
  'excluye subcuentas con documento propio al facturar el remanente.';

COMMIT;
