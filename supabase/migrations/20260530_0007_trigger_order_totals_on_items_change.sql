-- =============================================================================
-- Trigger: mantener order.total + subtotal + tax sincronizado con items
-- automáticamente. Cada vez que un item se inserta/actualiza/borra,
-- re-corremos calculate_order_totals para que orders.total nunca quede
-- stale.
--
-- Motivo (sesión 2026-05-30):
-- Mesa 6bcdfc65 (MEDIO TIEMPO BAR) tenía orders.total = 2,300 pero
-- SUM(items) = 15,085 — drift de 12,785 porque siguieron entrando
-- items desde el 27/05 sin que orders.total se actualizara. Sin
-- trigger, cualquier orden abierta que acumule items post-cierre o
-- post-recálculo queda con un total stale.
--
-- Esto NO afecta el reporte de ventas (que usa payments), pero sí
-- afecta:
--   - Reportes de productos vendidos (subreportan)
--   - Cierre de caja (arrastra diferencias)
--   - NCFs emitidos parcialmente (fd.total queda stale)
--   - Cálculo de propina/LEY a nivel orden
--
-- Performance:
-- 1 INSERT/UPDATE/DELETE en order_items ahora ejecuta calculate_order_totals.
-- Esa función agrega items del scope y hace 1 UPDATE a orders. Costo
-- ~1-2ms por cambio de item. Insignificante vs el costo de tener data
-- stale en reportes/cierres.
--
-- Recursión evitada:
-- calculate_order_totals NO modifica order_items, solo orders. Así que
-- el trigger no se vuelve a disparar a sí mismo.
-- =============================================================================

CREATE OR REPLACE FUNCTION public.trg_fn_recompute_order_on_items_change()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $function$
DECLARE
  v_order_id uuid;
BEGIN
  -- Para INSERT/UPDATE usamos NEW; para DELETE usamos OLD.
  IF TG_OP = 'DELETE' THEN
    v_order_id := OLD.order_id;
  ELSE
    v_order_id := NEW.order_id;
  END IF;

  -- Si el item cambió de order_id (raro pero posible), recomputar AMBAS.
  IF TG_OP = 'UPDATE' AND OLD.order_id IS DISTINCT FROM NEW.order_id THEN
    PERFORM public.calculate_order_totals(OLD.order_id);
    PERFORM public.calculate_order_totals(NEW.order_id);
    RETURN NEW;
  END IF;

  IF v_order_id IS NOT NULL THEN
    PERFORM public.calculate_order_totals(v_order_id);
  END IF;

  RETURN COALESCE(NEW, OLD);
END;
$function$;

-- AFTER (no BEFORE) porque queremos que el cambio del item ya esté
-- persistido cuando calculate_order_totals sume los items del scope.
DROP TRIGGER IF EXISTS trg_recompute_order_on_items_change
  ON public.order_items;

CREATE TRIGGER trg_recompute_order_on_items_change
AFTER INSERT OR UPDATE OR DELETE
ON public.order_items
FOR EACH ROW
EXECUTE FUNCTION public.trg_fn_recompute_order_on_items_change();

COMMENT ON FUNCTION public.trg_fn_recompute_order_on_items_change() IS
  'Mantiene orders.total/subtotal/tax sincronizado con items. Se dispara en cualquier INSERT/UPDATE/DELETE de order_items.';
