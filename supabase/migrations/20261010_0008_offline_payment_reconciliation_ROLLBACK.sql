-- Reversa de 20261010_0008: la app vuelve a subir los cobros sin red con
-- fn_process_payment_v3 (PGRST202 → camino de siempre). Los recibos se pierden:
-- antes de correrla, exportar los pendientes con
--   select * from public.offline_payment_receipts where status = 'needs_resolution';
begin;
drop function if exists public.fn_offline_payment_issues(uuid, timestamptz);
drop function if exists public.fn_resolve_offline_payment(uuid, text, uuid, text);
drop function if exists public.fn_replay_offline_payment(uuid, uuid, uuid, text, numeric, text, uuid, text, uuid, numeric, text, boolean, smallint, boolean, timestamptz, text, text, text);
drop function if exists public.fn_offline_payment_matches(public.payments, jsonb, uuid);
drop function if exists public.fn_apply_offline_payment_locked(jsonb, uuid, boolean);
drop function if exists public.fn_order_money_state(uuid);
drop function if exists public.fn_order_money_state_internal(uuid);
drop table if exists public.offline_payment_receipts;
commit;
