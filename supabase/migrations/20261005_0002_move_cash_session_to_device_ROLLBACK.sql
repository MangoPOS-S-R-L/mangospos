-- ROLLBACK de 20261005_0002 — quita el RPC para pasar una caja a otro equipo.
-- Las cajas ya movidas se quedan en el equipo nuevo (no hay forma segura de
-- saber a cuál devolverlas; el rastro está en audit_logs,
-- action = 'cash_session_moved_to_device'). La app muestra el error del RPC
-- inexistente al tocar "Pasar caja a este equipo".

begin;

drop function if exists public.fn_move_cash_session_to_device(uuid, text, text, text);

commit;
