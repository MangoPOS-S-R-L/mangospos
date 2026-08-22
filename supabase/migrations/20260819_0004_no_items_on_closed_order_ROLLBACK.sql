-- =============================================================================
-- ROLLBACK de 20260819_0004 — quitar el candado de ítems sobre orden cerrada
-- =============================================================================
-- Deja la base EXACTAMENTE como estaba antes de 0004: sin trigger, sin
-- reanimador. La bitácora `orphan_order_revivals` se CONSERVA a propósito —
-- son evidencias de mesas que se cerraron encima de un mesero y borrarlas
-- perdería el rastro. Si de verdad la quieres fuera, el DROP está comentado
-- abajo.
--
-- OJO: revertir esto devuelve el agujero. Cualquier ítem que caiga sobre una
-- orden cerrada vuelve a quedar huérfano y esa venta no se cobra.
-- =============================================================================

begin;

drop trigger if exists trg_block_items_on_closed_order on public.order_items;
drop function if exists public.fn_block_items_on_closed_order();
drop function if exists public.fn_reopen_orphan_order(uuid, text);

-- drop table if exists public.orphan_order_revivals;

commit;
