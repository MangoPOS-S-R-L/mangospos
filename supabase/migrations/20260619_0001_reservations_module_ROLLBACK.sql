-- ROLLBACK de 20260619_0001_reservations_module.sql

drop function if exists public.fn_expire_overdue_reservations(int);
drop function if exists public.fn_cancel_reservation(uuid, text);
drop function if exists public.fn_seat_reservation(uuid);
drop function if exists public.fn_update_reservation(uuid, uuid, text, int, timestamptz, int, uuid, text, text);
drop function if exists public.fn_create_reservation(uuid, uuid, text, int, timestamptz, int, uuid, text, text);

drop table if exists public.reservations cascade;
drop function if exists public.fn_reservations_set_time_range();
drop type if exists public.reservation_status;

delete from public.permissions where code in ('reservas.acceso', 'reservas.gestionar');

drop function if exists public.fn_set_business_module(uuid, text, boolean, uuid, text);
drop function if exists public.fn_business_module_enabled(uuid, text);
drop table if exists public.business_modules cascade;

-- Nota: la extensión btree_gist se deja instalada (puede usarla otra cosa).
