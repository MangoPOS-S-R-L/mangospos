-- =============================================================================
-- ROLLBACK de 20260616_0006 — restaura el ITBIS de junio al estado PRE-backfill
-- =============================================================================
--
-- Restaura subtotal/taxable_amount/itbis_amount/service_fee/total de cada NCF
-- afectado desde el respaldo public._backup_fd_itbis_june_20260616.
--
-- Úsalo solo si necesitas revertir la corrección. Si el respaldo no existe,
-- el backfill nunca corrió (no hay nada que revertir).
-- =============================================================================

begin;

do $$
begin
  if not exists (
    select 1 from pg_class
    where relname = '_backup_fd_itbis_june_20260616' and relnamespace = 'public'::regnamespace
  ) then
    raise exception 'No existe public._backup_fd_itbis_june_20260616 — el backfill 0006 no se aplicó.';
  end if;
end$$;

update public.fiscal_documents fd
set subtotal       = b.subtotal,
    taxable_amount = b.taxable_amount,
    itbis_amount   = b.itbis_amount,
    service_fee    = b.service_fee,
    total          = b.total
from public._backup_fd_itbis_june_20260616 b
where b.id = fd.id;

-- Opcional: dejar el respaldo para auditoría. Descomenta para eliminarlo.
-- drop table public._backup_fd_itbis_june_20260616;

commit;
