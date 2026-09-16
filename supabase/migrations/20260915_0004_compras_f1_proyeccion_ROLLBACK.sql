-- =============================================================================
-- ROLLBACK de 20260915_0004_compras_f1_proyeccion
-- Solo quita la función (no escribe datos). La pantalla de pedido sugerido
-- degrada a la de Reorden cuando la función no existe.
-- =============================================================================

begin;

set local lock_timeout = '5s';

drop function if exists public.fn_purchase_projection(uuid, uuid, integer, integer, integer, integer, uuid, boolean);

commit;

notify pgrst, 'reload schema';
