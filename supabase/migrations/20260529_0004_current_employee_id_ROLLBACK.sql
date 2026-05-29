-- Rollback de 20260529_0004. Si Flutter ya está deployado con la versión
-- que llama esta RPC, revertir vuelve a romper el fallback de auditoría
-- (items agregados por cajero/admin vuelven a quedar como "Sin asignar").
DROP FUNCTION IF EXISTS public.fn_current_employee_id(uuid);
