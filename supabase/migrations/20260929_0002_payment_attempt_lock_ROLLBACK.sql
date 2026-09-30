-- ROLLBACK de 20260929_0002_payment_attempt_lock.sql
-- La app nueva bloquea cobros online si se retiran estas funciones; coordinar
-- rollback del cliente para evitar detener ventas.
-- La columna payments.client_attempt_id se conserva a propósito (auditoría,
-- nullable, no la usa nadie más); borrarla es opcional:
--   alter table public.payments drop column if exists client_attempt_id;
begin;

drop trigger if exists trg_000_payments_attempt_guard on public.payments;
drop function if exists public.fn_payments_attempt_guard();
drop function if exists public.fn_process_payment_v3_attempt(
  uuid, uuid, uuid, text, numeric, text, uuid, text, uuid, numeric, text,
  boolean, smallint, boolean, timestamptz, integer, text
);
drop function if exists public.fn_payment_attempt_release(uuid, uuid);
drop function if exists public.fn_payment_attempt_acquire(uuid, uuid, uuid, text, text, integer);
drop table if exists public.order_payment_attempts;

commit;

notify pgrst, 'reload schema';
