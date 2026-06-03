-- ROLLBACK de 20260602_0004_open_retail_cart.sql
-- Elimina el RPC de carritos retail. No toca fn_open_manual_or_quick ni datos.
-- Las mesas virtuales por carrito (zona "Ventas rapidas", code='quick-…') y sus
-- órdenes quedan tal cual — son datos válidos; se gestionan/cierran por el flujo
-- normal de órdenes.

begin;

drop function if exists public.fn_open_retail_cart(uuid, uuid, text, integer);

commit;
