-- ROLLBACK de 20260928_0001_inventory_outflow_reason.sql
--
-- Quita la función. Los movimientos ya registrados se quedan como están
-- (`waste` con su reason_code): son historia, no se tocan. La app vuelve sola
-- al `fn_inventory_record_movement` de siempre (motivo en la nota).

begin;

drop function if exists public.fn_inventory_record_outflow(
  uuid, uuid, uuid, numeric, text, text, numeric
);

notify pgrst, 'reload schema';

commit;
