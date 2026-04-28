-- =============================================================================
-- File:        05_f2.2_trigger_update_order_totals.sql
-- PRD:         2 (Refactor del Motor de Impuestos)
-- Phase:       F2.2
-- Author:      Cristian
-- Date:        2026-04-28
-- Reversible:  yes
-- Rollback:    rollback/05_restore_trigger_update_order_totals.sql
--
-- Purpose:
--   Simplifica el cuerpo de `trigger_update_order_totals` (la función
--   bound al trigger AFTER `order_items_totals_trigger` en order_items).
--
--   Cambio: una sola llamada a `fn_recalc_totals(order_id)` en cada caso,
--   en lugar de las dos llamadas actuales (`calculate_order_totals` +
--   `calculate_check_totals`). El motor nuevo recalcula la orden Y todos
--   sus checks en una pasada, así que no necesitamos llamarlas por
--   separado.
--
--   El TRIGGER en sí (`order_items_totals_trigger`) NO se toca: sigue
--   siendo AFTER INSERT OR DELETE OR UPDATE FOR EACH ROW.
--
-- Apply order:
--   1. Staging.
--   2. Después del SQL 03 (fn_recalc_totals debe existir) y SQL 04
--      (los wrappers, por si algún call-site externo los usa).
-- =============================================================================

CREATE OR REPLACE FUNCTION public.trigger_update_order_totals()
 RETURNS trigger
 LANGUAGE plpgsql
AS $function$
BEGIN
  IF TG_OP = 'DELETE' THEN
    PERFORM public.fn_recalc_totals(OLD.order_id);
    RETURN OLD;
  END IF;

  -- INSERT o UPDATE: recalcular para el order_id (nuevo o el viejo si UPDATE).
  PERFORM public.fn_recalc_totals(COALESCE(NEW.order_id, OLD.order_id));

  -- Si en UPDATE el item se movió a otro order (poco común pero posible),
  -- también recalcular el order viejo para no dejarlo desactualizado.
  IF TG_OP = 'UPDATE'
     AND OLD.order_id IS NOT NULL
     AND OLD.order_id IS DISTINCT FROM NEW.order_id THEN
    PERFORM public.fn_recalc_totals(OLD.order_id);
  END IF;

  RETURN NEW;
END;
$function$;
