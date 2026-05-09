-- =============================================================================
-- Recalcular order_items.subtotal/tax/total cuando se inserta/modifica/elimina
-- un order_item_modifier.
--
-- Bug: products con price=0 (ej. "Jugo") y modifiers con precio (ej. "Sabor
-- fresa = $50") se cobran $0 a nivel DB. El flujo actual:
--   1. Cliente: addItemFromMenu -> RPC inserta order_item con unit_price=0.
--      El trigger fn_compute_item_totals corre en BEFORE INSERT, suma
--      modifiers (== 0 porque no existen aun) -> subtotal=0.
--   2. Cliente: addOrderItemModifiers -> INSERT en order_item_modifiers.
--      No hay trigger en esta tabla -> order_item.subtotal sigue 0.
--   3. orders.total se calcula sumando order_items.total (= 0).
--
-- Sintoma:
--   - UI compensaba con un heuristico frontend (`modifiersOutOfSync` en
--     order_pricing_utils.dart) -> el cliente ve el total correcto.
--   - DB queda inconsistente: orders.total=0, fiscal_documents.total=0,
--     reportes de ventas incorrectos.
--
-- Fix: trigger AFTER INSERT/UPDATE/DELETE en order_item_modifiers que hace
-- un UPDATE no-op sobre el order_item padre. Eso re-dispara la cadena
-- BEFORE UPDATE (fn_compute_item_totals con el nuevo SUM de modifiers) +
-- AFTER UPDATE (fn_after_item_change recalcula orders.total).
--
-- No hay recursion: el trigger lee modifiers, no escribe.
-- Idempotente: re-correr migration solo redefine la funcion + trigger.
-- =============================================================================

CREATE OR REPLACE FUNCTION public.fn_recalc_item_after_modifier_change()
RETURNS trigger
LANGUAGE plpgsql
AS $$
DECLARE
  v_item_id uuid;
BEGIN
  v_item_id := COALESCE(NEW.item_id, OLD.item_id);
  IF v_item_id IS NULL THEN
    RETURN NULL;
  END IF;

  -- UPDATE no-op para forzar el firing de los triggers de order_items.
  -- BEFORE UPDATE -> fn_compute_item_totals (suma modifiers actualizada).
  -- AFTER  UPDATE -> fn_after_item_change (recalc orders.total).
  -- Si el item ya fue borrado (cascade delete), el WHERE no matchea y no
  -- pasa nada, lo cual es correcto.
  UPDATE public.order_items
    SET unit_price = unit_price
  WHERE id = v_item_id;

  RETURN NULL;
END;
$$;

DROP TRIGGER IF EXISTS trg_recalc_item_after_modifier_change
  ON public.order_item_modifiers;

CREATE TRIGGER trg_recalc_item_after_modifier_change
AFTER INSERT OR UPDATE OR DELETE ON public.order_item_modifiers
FOR EACH ROW
EXECUTE FUNCTION public.fn_recalc_item_after_modifier_change();

-- ---------------------------------------------------------------------------
-- Backfill: forzar recompute de TODAS las orders abiertas con modifiers
-- existentes para corregir datos historicos (subtotals/totals quedados en 0).
-- Solo afecta abiertas; las pagadas/voided se respetan.
-- ---------------------------------------------------------------------------
DO $$
DECLARE
  v_affected int := 0;
BEGIN
  WITH items_to_touch AS (
    SELECT DISTINCT oi.id
    FROM public.order_items oi
    JOIN public.order_item_modifiers oim ON oim.item_id = oi.id
    JOIN public.orders o ON o.id = oi.order_id
    WHERE o.closed_at IS NULL
      AND COALESCE(o.status_ext::text, '') NOT IN ('paid', 'void')
      AND oi.status <> 'void'
  )
  UPDATE public.order_items oi
    SET unit_price = oi.unit_price
  FROM items_to_touch t
  WHERE oi.id = t.id;

  GET DIAGNOSTICS v_affected = ROW_COUNT;
  RAISE NOTICE 'Backfill: % order_items recalculados con sus modifiers.',
               v_affected;
END;
$$;
