-- Rollback de 20260529_0005. Si Flutter ya está deployado llamando esta
-- RPC, revertir vuelve a romper el "MESERO:" impreso para usuarios sin
-- privilegios de SELECT directo a `employees`.
DROP FUNCTION IF EXISTS public.fn_order_opener_name(uuid);
