-- =============================================================================
-- ROLLBACK 20260616_0002 — KDS completar al pagar vs esperar al cocinero
-- =============================================================================
-- Quita la vista, el trigger/función, el flag de orden y el toggle. El backfill
-- de kitchen_done_at no se revierte (solo se elimina la columna). Sin impacto
-- en pagos: nada de esto tocó fn_process_payment_v3.
-- =============================================================================

begin;

drop view if exists public.kds_open_orders;

drop trigger if exists trg_orders_kitchen_done_on_payment on public.orders;
drop function if exists public.tg_orders_kitchen_done_on_payment();

drop index if exists public.idx_orders_kitchen_open;

alter table public.orders
  drop column if exists kitchen_done_at;

alter table public.business_settings
  drop column if exists kds_complete_on_payment;

commit;
