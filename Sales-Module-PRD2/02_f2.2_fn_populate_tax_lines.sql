-- =============================================================================
-- File:        02_f2.2_fn_populate_tax_lines.sql
-- PRD:         2 (Refactor del Motor de Impuestos)
-- Phase:       F2.2
-- Author:      Cristian
-- Date:        2026-04-28
-- Reversible:  yes
-- Rollback:    rollback/02_drop_populate_tax_lines.sql
--
-- Purpose:
--   Función + trigger AFTER que popla `order_item_tax_lines` con un
--   snapshot por cada impuesto que aplica al item.
--
--   Diseño:
--   - AFTER INSERT/UPDATE en order_items garantiza que NEW.id ya está
--     persistido y que NEW.subtotal ya fue calculado por el trigger BEFORE
--     `fn_compute_item_totals`.
--   - En UPDATE: borra las tax_lines previas y reescribe (idempotente).
--   - Lee `menu_item_taxes` filtrado por origin del order. La columna
--     `is_service_fee` ya NO se filtra (OQ2-5 = A: la propina pasa por
--     menu_item_taxes como cualquier otro impuesto).
--   - amount = round(NEW.subtotal * tax.rate / 100, 2). Si la suma de
--     amounts difiere de NEW.tax por redondeo, NO se ajusta acá: el
--     desfase quedará registrado en la tabla y los reportes del PRD 3
--     pueden reconciliar al centavo más cercano.
--   - Self_service y origins desconocidos → no se insertan tax_lines y
--     se RAISE EXCEPTION (fail-loud, OQ2-1 = B).
--
-- Apply order:
--   1. Staging primero.
--   2. Después del SQL 01 (la tabla destino debe existir).
--   3. Antes del SQL 06 (que reescribe fn_add_item_from_menu y depende
--      de que las tax_lines se generen automáticamente).
-- =============================================================================

CREATE OR REPLACE FUNCTION public.fn_populate_tax_lines()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  v_origin text;
  v_biz_id uuid;
  v_tax record;
BEGIN
  -- Idempotencia: en UPDATE borramos las líneas previas para reescribir.
  -- En INSERT no hay nada que borrar pero el DELETE no falla.
  DELETE FROM public.order_item_tax_lines
  WHERE order_item_id = NEW.id;

  -- Si el item está void, no escribimos tax_lines (no se cobra nada).
  IF NEW.status = 'void' THEN
    RETURN NEW;
  END IF;

  -- Obtener origin y business_id del order al que pertenece el item.
  SELECT trim(lower(ts.origin::text)), ts.business_id
    INTO v_origin, v_biz_id
  FROM public.orders o
  JOIN public.table_sessions ts ON ts.id = o.session_id
  WHERE o.id = NEW.order_id;

  -- Fail-loud para origins no soportados (PRD 2 OQ2-1).
  IF v_origin = 'self_service' THEN
    RAISE EXCEPTION 'self_service origin not supported (PRD 2 fail-loud): self-checkout aún no implementado';
  END IF;

  IF v_origin IS NULL OR v_origin NOT IN ('dine_in', 'manual', 'quick', 'delivery') THEN
    RAISE EXCEPTION 'unknown order_origin: %', v_origin;
  END IF;

  -- Insertar una fila por cada impuesto del producto que aplica al origin.
  -- Snapshot: tax_name y tax_rate al momento de la venta.
  FOR v_tax IN
    SELECT t.id AS tax_id, t.name AS tax_name, t.rate AS tax_rate
    FROM public.menu_item_taxes mit
    JOIN public.taxes t ON t.id = mit.tax_id
    WHERE mit.item_id = NEW.product_id
      AND t.business_id = v_biz_id
      AND coalesce(t.is_active, true)
      AND (
        (v_origin = 'dine_in'  AND t.apply_on_zone)     OR
        (v_origin = 'manual'   AND t.apply_on_manual)   OR
        (v_origin = 'quick'    AND t.apply_on_quick)    OR
        (v_origin = 'delivery' AND t.apply_on_delivery)
      )
      -- Takeout no paga service fee aunque esté linkeado y aplique al origin:
      AND NOT (NEW.is_takeout AND coalesce(t.is_service_fee, false))
  LOOP
    INSERT INTO public.order_item_tax_lines (
      order_item_id, tax_id, tax_name, tax_rate, amount
    ) VALUES (
      NEW.id,
      v_tax.tax_id,
      v_tax.tax_name,
      v_tax.tax_rate,
      ROUND(coalesce(NEW.subtotal, 0) * (v_tax.tax_rate / 100.0), 2)
    );
  END LOOP;

  RETURN NEW;
END;
$function$;

-- Trigger AFTER que dispara después de que `fn_compute_item_totals` (BEFORE)
-- ya seteó subtotal/tax/total y de que el row está persistido (NEW.id existe).
DROP TRIGGER IF EXISTS trg_populate_tax_lines ON public.order_items;
CREATE TRIGGER trg_populate_tax_lines
  AFTER INSERT OR UPDATE OF subtotal, status, product_id, order_id, is_takeout
  ON public.order_items
  FOR EACH ROW
  EXECUTE FUNCTION public.fn_populate_tax_lines();
