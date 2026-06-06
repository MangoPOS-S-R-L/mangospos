-- =============================================================================
-- ROLLBACK de 20260605_0005 — elimina fn_add_offer_deal.
-- =============================================================================
-- El cliente cae automáticamente al camino de 2 viajes (addItemFromMenu +
-- updateItemDiscountAndNotes) si la RPC no existe, así que quitarla no rompe el
-- flujo, solo lo hace un poco más lento.
-- =============================================================================

begin;

drop function if exists
  public.fn_add_offer_deal(uuid, uuid, numeric, numeric, text, uuid, integer);

commit;
