-- 20260522_0001_auth_offline_roster_ROLLBACK.sql
-- Revert de 20260522_0001_auth_offline_roster.sql
--
-- NO borra los pin_hash backfilled (solo dropea la columna). Si tienes
-- clientes que ya migraron a verificación offline contra pin_hash, este
-- rollback los rompe. Úsalo solo si la migración aún no se desplegó a
-- producción o si confirmaste que ningún cliente depende del hash.

begin;

drop function if exists public.fn_device_revoke(uuid);
drop function if exists public.fn_sync_roster(text);
drop function if exists public.fn_device_bind(uuid, text);

drop policy if exists dr_owner_write on public.device_registrations;
drop policy if exists dr_owner_read on public.device_registrations;

drop table if exists public.device_registrations;

drop trigger if exists tr_employees_hash_pin on public.employees;
drop function if exists public.fn_employees_hash_pin();

alter table public.employees
  drop column if exists pin_hash;

-- pgcrypto se queda — puede estar siendo usado por otras migraciones.

commit;
