-- ===========================================================================
-- ROLLBACK de 20260917_0004_azul_charges_custom_order_id.sql
--
-- ANTES: volver a desplegar la versión anterior de azul-charge-subscription.
-- La función nueva escribe custom_order_id; sin la columna no puede cobrar.
--
-- Se pierden los CustomOrderId guardados: los cobros con resultado
-- desconocido ya no se podrán verificar con Azul.
-- ===========================================================================

begin;

drop index if exists public.azul_charges_custom_order_id_key;

alter table public.azul_charges
  drop column if exists custom_order_id;

commit;

notify pgrst, 'reload schema';
