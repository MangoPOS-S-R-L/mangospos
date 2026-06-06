-- =============================================================================
-- ROLLBACK de 20260605_0004 — quita las políticas RLS y revierte el check.
-- =============================================================================
-- OJO: al quitar las políticas, promotions/coupons/gift_cards vuelven a quedar
-- con RLS habilitado y SIN políticas → authenticated bloqueado de nuevo (vuelve
-- el bug "no guarda"). Solo revertir si se va a manejar RLS de otra forma.
-- =============================================================================

begin;

drop policy if exists "promotions_business_rw" on public.promotions;
drop policy if exists "coupons_business_rw" on public.coupons;
drop policy if exists "gift_cards_business_rw" on public.gift_cards;

-- Volver el check de discount_type a su estado previo (sin bundle_price).
alter table public.promotions
  drop constraint if exists promotions_discount_type_check;
alter table public.promotions
  add constraint promotions_discount_type_check
  check (discount_type in ('percentage', 'fixed', 'bogo'));

commit;
