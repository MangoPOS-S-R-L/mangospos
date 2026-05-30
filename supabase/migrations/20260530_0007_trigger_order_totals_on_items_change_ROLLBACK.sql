-- Rollback de 20260530_0007. Elimina el trigger.
-- Si se revierte: orders.total puede volver a quedar stale cuando se
-- agreguen items después del cierre/recálculo (como pasó con la mesa
-- 6bcdfc65 en mayo 2026).

DROP TRIGGER IF EXISTS trg_recompute_order_on_items_change
  ON public.order_items;
DROP FUNCTION IF EXISTS public.trg_fn_recompute_order_on_items_change();
