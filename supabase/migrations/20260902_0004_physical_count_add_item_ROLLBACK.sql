-- ROLLBACK de 20260902_0004_physical_count_add_item.sql
--
-- Quita la función. Las líneas que se hayan agregado con ella se quedan: son
-- conteo real, no metadata. Si además hay que sacarlas, se borran a mano por
-- `session_id` mirando `created_at` contra `frozen_at` de la sesión.
--
-- La app degrada sola: sin la función, el botón "Agregar insumo" avisa que
-- falta aplicar la migración y el insumo se crea igual en el maestro (solo
-- que no entra en la sesión en curso).

begin;

drop function if exists public.fn_physical_count_add_item(uuid, uuid);

commit;
