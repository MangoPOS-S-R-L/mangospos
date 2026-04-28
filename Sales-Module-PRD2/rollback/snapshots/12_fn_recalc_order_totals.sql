-- Captured from production on 2026-04-28 (PRD 2 F2.2 pre-step).
-- Source: SELECT pg_get_functiondef('public.fn_recalc_order_totals'::regproc);
--
-- Wrapper trivial sobre calculate_order_totals. Cuando convirtamos
-- calculate_order_totals en wrapper de fn_recalc_totals (PRD §6.3), esta
-- función automáticamente va a usar el motor nuevo sin tocarla.

CREATE OR REPLACE FUNCTION public.fn_recalc_order_totals(_order_id uuid)
 RETURNS void
 LANGUAGE plpgsql
AS $function$
BEGIN
  PERFORM public.calculate_order_totals(_order_id);
END;
$function$;
