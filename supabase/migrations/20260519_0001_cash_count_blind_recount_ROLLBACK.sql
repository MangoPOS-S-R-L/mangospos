-- Rollback de `20260519_0001_cash_count_blind_recount.sql`.
-- Antes de correr: si hay filas con attempt_number=2, hay que decidir
-- qué hacer (borrarlas o consolidarlas) porque el UNIQUE viejo
-- solo permite UNA fila por sesión.

begin;

-- Si hay reconteos guardados, borrarlos para que el UNIQUE viejo pase.
-- Esto pierde data — solo correr si es un rollback aceptable.
delete from public.cash_count_blind where attempt_number = 2;

alter table public.cash_count_blind
  drop constraint if exists cash_count_blind_session_attempt_unique;

alter table public.cash_count_blind
  drop constraint if exists cash_count_blind_attempt_check;

alter table public.cash_count_blind
  add constraint cash_count_blind_session_unique
  unique (cash_register_session_id);

alter table public.cash_count_blind
  drop column if exists attempt_number;

commit;
