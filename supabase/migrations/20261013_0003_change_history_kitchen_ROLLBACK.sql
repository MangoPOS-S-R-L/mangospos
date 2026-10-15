-- Reversa de 20261013_0003_change_history_kitchen.sql: deja de anotar los
-- envíos a cocina. Las líneas ya escritas en change_history se quedan.

begin;

set local lock_timeout = '5s';

drop trigger if exists trg_zz_change_history_kitchen on public.order_items;
drop function if exists public.fn_change_history_on_kitchen_send();

commit;
