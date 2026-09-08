-- =============================================================================
-- Rollback de 20260907_0006_fn_ingest_external_order.sql
--
-- Quita la ingesta y el resolvedor de credenciales. NO toca las tablas del
-- canal (esas son de 20260907_0005) ni ninguna orden ya creada: un pedido que
-- ya entro es una venta del restaurante, con su comanda y posiblemente su
-- comprobante. Borrarlo no es "revertir", es perder una venta.
--
-- Despues de correr esto, el endpoint /pincer-orders empieza a responder 500 en
-- cada pedido. Si el canal esta activo, revoca primero la credencial para que
-- Pincer reciba un 401 limpio y mande los pedidos a su respaldo manual:
--
--   update public.external_api_keys
--      set is_active = false, revoked_at = now()
--    where channel = 'pincer';
--
-- Las columnas de estado de cobro quedan comentadas: tienen el rastro de que
-- cobros fallaron al registrarse, que es justo lo que hace falta para
-- reconciliar. Borrarlas pierde esa informacion.
-- =============================================================================

begin;

drop function if exists public.fn_ingest_external_order(uuid, text, jsonb, text);
drop function if exists public.fn_resolve_external_api_key(text);

-- Comentadas A PROPOSITO (ver cabecera):
--
-- alter table public.external_orders
--   drop column if exists payment_state,
--   drop column if exists payment_error,
--   drop column if exists needs_review,
--   drop column if exists environment;

commit;
