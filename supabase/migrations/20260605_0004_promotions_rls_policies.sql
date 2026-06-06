-- =============================================================================
-- 20260605_0004 — RLS faltante en promotions/coupons/gift_cards (bug: no guarda)
-- =============================================================================
--
-- PROBLEMA QUE RESUELVE
-- ─────────────────────
-- Las tablas `promotions`, `coupons` y `gift_cards` tienen ROW LEVEL SECURITY
-- HABILITADO (schema.sql) y `GRANT ALL` a authenticated, pero NO existe NINGUNA
-- política (`CREATE POLICY`) para ellas en todo el repo. Con RLS activo y CERO
-- políticas, PostgreSQL DENIEGA TODO a `authenticated`:
--   - INSERT  → rechazado ("new row violates row-level security policy").
--   - SELECT  → devuelve 0 filas (silenciosamente).
--
-- Síntoma reportado: "las ofertas no guardan nada cuando las creo" — el insert
-- falla y, aunque guardara, la lista siempre se ve vacía. ADEMÁS, esto explica
-- por qué el motor de auto-ofertas nunca aplicaba: su SELECT de `promotions`
-- también devolvía vacío bajo RLS.
--
-- BUG SECUNDARIO (bundle_price)
-- ─────────────────────────────
-- El check viejo `promotions_discount_type_check` solo permite
-- ('percentage','fixed','bogo'). La app guarda `discount_type = promo_type`, así
-- que una oferta tipo "Precio promo" (bundle_price) viola ese check y falla aun
-- con RLS arreglado. La migración 20260327_0010 agregó el check de `promo_type`
-- con 'bundle_price' pero NO actualizó el de `discount_type`. Lo alineamos aquí.
--
-- FIX
-- ───
-- 1. Política RLS business-scoped (mismo patrón que `customers`, `zones`, etc.)
--    para promotions/coupons/gift_cards: authenticated solo ve/edita filas de un
--    negocio al que pertenece (via user_businesses).
-- 2. Relajar `promotions_discount_type_check` para incluir 'bundle_price' (y
--    permitir NULL, ya que la columna es nullable).
--
-- SEGURIDAD
--   - Las políticas son business-scoped: un usuario NO ve ofertas de otros
--     negocios. service_role (backend) ignora RLS como siempre.
--   - Idempotente: `drop policy if exists` antes de crear.
-- =============================================================================

begin;

-- 1) promotions ---------------------------------------------------------------
drop policy if exists "promotions_business_rw" on public.promotions;
create policy "promotions_business_rw" on public.promotions
  for all
  to authenticated
  using (
    auth.uid() in (
      select ub.user_id from public.user_businesses ub
      where ub.business_id = promotions.business_id
    )
  )
  with check (
    auth.uid() in (
      select ub.user_id from public.user_businesses ub
      where ub.business_id = promotions.business_id
    )
  );

-- 2) coupons ------------------------------------------------------------------
drop policy if exists "coupons_business_rw" on public.coupons;
create policy "coupons_business_rw" on public.coupons
  for all
  to authenticated
  using (
    auth.uid() in (
      select ub.user_id from public.user_businesses ub
      where ub.business_id = coupons.business_id
    )
  )
  with check (
    auth.uid() in (
      select ub.user_id from public.user_businesses ub
      where ub.business_id = coupons.business_id
    )
  );

-- 3) gift_cards ---------------------------------------------------------------
drop policy if exists "gift_cards_business_rw" on public.gift_cards;
create policy "gift_cards_business_rw" on public.gift_cards
  for all
  to authenticated
  using (
    auth.uid() in (
      select ub.user_id from public.user_businesses ub
      where ub.business_id = gift_cards.business_id
    )
  )
  with check (
    auth.uid() in (
      select ub.user_id from public.user_businesses ub
      where ub.business_id = gift_cards.business_id
    )
  );

-- 4) Alinear el check de discount_type con promo_type (incluye bundle_price) ---
alter table public.promotions
  drop constraint if exists promotions_discount_type_check;
alter table public.promotions
  add constraint promotions_discount_type_check
  check (
    discount_type is null
    or discount_type in ('percentage', 'fixed', 'bogo', 'bundle_price')
  );

commit;
