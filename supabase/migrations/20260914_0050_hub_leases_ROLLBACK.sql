-- Rollback de 20260914_0050. La tabla y la RPC son nuevas y aditivas: nada más
-- en la BD depende de ellas. La app detecta que la RPC no existe y el uplink
-- vuelve al comportamiento de antes (sube sin confirmar lease). La PROMOCIÓN,
-- en cambio, queda bloqueada con aviso: promover sin lease es justo el riesgo de
-- venta doble que esta migración vino a cerrar.

begin;

drop function if exists public.fn_hub_lease_acquire(uuid, text, boolean);
drop table if exists public.hub_leases;

commit;
