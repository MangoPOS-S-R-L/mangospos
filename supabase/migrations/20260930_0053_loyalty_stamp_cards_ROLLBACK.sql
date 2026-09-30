-- =============================================================================
-- ROLLBACK de 20260930_0053 — Tarjetas de sellos.
--
-- OJO: borra los programas, los ajustes manuales y el historial de canjes.
-- Las líneas que ya tenían un premio conservan su descuento y el marcador
-- `[LOYALTY:…]` en las notas (queda como texto; no afecta cobros).
-- =============================================================================

begin;

drop function if exists public.fn_loyalty_adjust_stamps(uuid, uuid, integer, text);
drop function if exists public.fn_loyalty_cancel_reward(uuid);
drop function if exists public.fn_loyalty_redeem_reward(uuid, uuid, uuid, integer);
drop function if exists public.fn_loyalty_customer_cards(uuid);
drop function if exists public.fn_loyalty_stamp_totals(uuid);
drop function if exists public.fn_loyalty_item_sold(text, uuid, boolean, uuid, timestamptz, text);
drop function if exists public.fn_loyalty_program_products(uuid);
drop function if exists public.fn_loyalty_marker_id(text);

drop table if exists public.loyalty_stamp_redemptions;
drop table if exists public.loyalty_stamp_adjustments;
drop table if exists public.loyalty_stamp_programs;

drop function if exists public.fn_loyalty_programs_validate_targets();
drop function if exists public.fn_loyalty_can_manage(uuid);

drop index if exists public.idx_order_checks_customer_id;

commit;

notify pgrst, 'reload schema';
