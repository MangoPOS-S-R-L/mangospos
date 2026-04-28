-- Captured from production on 2026-04-28 (PRD 2 F2.2 pre-step).
-- Source: SELECT pg_get_functiondef('public.trigger_update_order_totals'::regproc);
-- Use: rollback target if PRD 2 modifications break this function.
--
-- Bound to trigger:
--   CREATE TRIGGER order_items_totals_trigger
--   AFTER INSERT OR DELETE OR UPDATE ON public.order_items
--   FOR EACH ROW EXECUTE FUNCTION trigger_update_order_totals()

CREATE OR REPLACE FUNCTION public.trigger_update_order_totals()
 RETURNS trigger
 LANGUAGE plpgsql
AS $function$
begin
  if tg_op = 'DELETE' then
    perform public.calculate_order_totals(old.order_id);
    if old.check_id is not null then
      perform public.calculate_check_totals(old.check_id);
    end if;
    return old;
  end if;

  if tg_op = 'UPDATE' then
    perform public.calculate_order_totals(coalesce(new.order_id, old.order_id));

    if old.check_id is not null then
      perform public.calculate_check_totals(old.check_id);
    end if;

    if new.check_id is not null and new.check_id is distinct from old.check_id then
      perform public.calculate_check_totals(new.check_id);
    end if;

    return new;
  end if;

  perform public.calculate_order_totals(new.order_id);
  if new.check_id is not null then
    perform public.calculate_check_totals(new.check_id);
  end if;
  return new;
end;
$function$;
