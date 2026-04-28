-- =============================================================================
-- File:        04_f2.2_calculate_totals_wrappers.sql
-- PRD:         2 (Refactor del Motor de Impuestos)
-- Phase:       F2.2
-- Author:      Cristian
-- Date:        2026-04-28
-- Reversible:  yes (restaurar desde snapshots/03 y snapshots/04)
-- Rollback:    rollback/04_restore_calculate_functions.sql
--
-- Purpose:
--   Convierte `calculate_order_totals` y `calculate_check_totals` en
--   wrappers triviales que delegan a `fn_recalc_totals` (PRD §6.3).
--
--   Razón: hay código (frontend, RPCs como `fn_recalc_order_totals`) que
--   llama a estas funciones. En vez de buscar y reemplazar todos los
--   call-sites, dejamos las firmas viejas y redireccionamos. Esto reduce
--   el blast radius del PRD 2.
--
--   `calculate_check_totals(_check_id)` recibe un check_id pero el motor
--   nuevo trabaja a nivel orden. Resolvemos el order_id desde el check_id
--   y llamamos a `fn_recalc_totals(order_id)`, que recalcula la orden Y
--   todos sus checks (incluido el que se nos pasó).
--
-- Apply order:
--   1. Staging.
--   2. Después de SQL 03 (fn_recalc_totals debe existir).
--   3. Antes de SQL 05 (que va a llamar a estos wrappers desde el trigger).
-- =============================================================================

-- Wrapper de calculate_order_totals
CREATE OR REPLACE FUNCTION public.calculate_order_totals(_order_id uuid)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
BEGIN
  -- DEPRECATED: usar fn_recalc_totals directamente.
  -- Wrapper preservado para compatibilidad con call-sites que aún la usan.
  PERFORM public.fn_recalc_totals(_order_id);
END;
$function$;

-- Wrapper de calculate_check_totals
CREATE OR REPLACE FUNCTION public.calculate_check_totals(_check_id uuid)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  _order_id uuid;
BEGIN
  -- DEPRECATED: el cálculo se hace a nivel orden.
  -- Buscamos la orden a la que pertenece el check y delegamos.
  SELECT order_id INTO _order_id
  FROM public.order_checks
  WHERE id = _check_id;

  IF _order_id IS NOT NULL THEN
    PERFORM public.fn_recalc_totals(_order_id);
  END IF;
END;
$function$;
