-- Rollback de 20260529_0006. Si Flutter ya está deployado llamando esta
-- RPC para asignar items al opener, revertir hace que los items futuros
-- vuelvan a quedar atribuidos al cajero/admin que clickeó "agregar".
DROP FUNCTION IF EXISTS public.fn_order_opener_employee_id(uuid);
