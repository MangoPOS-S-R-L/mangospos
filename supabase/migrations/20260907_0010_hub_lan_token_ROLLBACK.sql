-- Rollback de 20260907_0010. La app cae sola a la constante legacy cuando la
-- columna no existe (el getter degrada a default), así que soltar la columna no
-- rompe el Hub: vuelve al esquema de token compartido de antes.

begin;

alter table public.business_settings drop column if exists lan_token;

commit;
