-- =============================================================================
-- ROLLBACK de 20260526_0002_azul_subscriptions_schema.sql
--
-- ATENCIÓN: este rollback DESTRUYE datos de:
--   - plans (catálogo de planes)
--   - azul_payment_sessions, azul_payment_methods, azul_charges,
--     azul_webhook_events (estado completo de billing Azul)
--   - Columnas de billing en memberships (plan_id, billing_status,
--     trial_ends_at, next_billing_date, anchor flag, etc.)
--
-- Antes de correrlo en cualquier ambiente con datos reales: tomar dump.
--
-- ORDEN: invertido respecto a la migración (drop hijos antes que padres).
-- =============================================================================

begin;

-- 0. Revocar GRANTs (revoke antes de drop view/tabla para evitar warnings).
revoke all on public.azul_payment_methods_public from authenticated;
revoke all on public.azul_charges_public from authenticated;
revoke all on public.azul_payment_methods from authenticated, service_role;
revoke all on public.azul_charges from authenticated, service_role;
revoke all on public.azul_payment_sessions from service_role;
revoke all on public.azul_webhook_events from service_role;
revoke all on public.plans from anon, authenticated, service_role;

-- 1. Vistas
drop view if exists public.azul_payment_methods_public;
drop view if exists public.azul_charges_public;

-- 2. Triggers
drop trigger if exists trg_plans_updated_at on public.plans;
drop trigger if exists trg_azul_payment_sessions_updated_at on public.azul_payment_sessions;
drop trigger if exists trg_azul_payment_methods_updated_at on public.azul_payment_methods;
drop trigger if exists trg_azul_charges_updated_at on public.azul_charges;

-- 3. Soltar FKs cruzados entre memberships ↔ azul_charges antes de drop azul_charges.
alter table public.memberships
  drop constraint if exists memberships_last_successful_charge_fkey;
alter table public.memberships
  drop constraint if exists memberships_last_failed_charge_fkey;

-- 4. Soltar FK circular sessions → payment_methods antes de drop ambas.
alter table public.azul_payment_sessions
  drop constraint if exists azul_payment_sessions_resulting_payment_method_fkey;

-- 5. Drop tablas azul_ en orden de dependencia.
drop table if exists public.azul_webhook_events cascade;
drop table if exists public.azul_charges cascade;
drop table if exists public.azul_payment_methods cascade;
drop table if exists public.azul_payment_sessions cascade;

-- 5b. Drop la policy plans_select_visible ANTES de tocar memberships.plan_id.
-- La policy referencia memberships.plan_id en su predicate, lo que crea una
-- dependencia que bloquea el DROP COLUMN si la policy sigue viva.
drop policy if exists "plans_select_visible" on public.plans;
drop policy if exists "plans_write_service" on public.plans;

-- 6. Quitar columnas/constraints/índices agregados a memberships.
drop index if exists public.memberships_one_billing_anchor_per_business;
drop index if exists public.idx_memberships_next_billing_date;
drop index if exists public.idx_memberships_billing_status;
drop index if exists public.idx_memberships_plan_id;

alter table public.memberships
  drop constraint if exists memberships_billing_status_check;
alter table public.memberships
  drop constraint if exists memberships_attempt_number_check;

alter table public.memberships
  drop column if exists last_successful_charge_id,
  drop column if exists last_failed_charge_id,
  drop column if exists plan_id,
  drop column if exists is_billing_anchor,
  drop column if exists billing_status,
  drop column if exists trial_ends_at,
  drop column if exists current_period_start,
  drop column if exists current_period_end,
  drop column if exists next_billing_date,
  drop column if exists consent_granted_at,
  drop column if exists current_attempt_number,
  drop column if exists suspended_at,
  drop column if exists cancelled_at,
  drop column if exists cancellation_reason;

-- 7. Drop plans (después de quitar el FK desde memberships.plan_id).
drop table if exists public.plans cascade;

-- 8. Drop función helper (si no la usa otra cosa — el _ROLLBACK la quita
--    porque la creó la migración).
drop function if exists public.fn_azul_touch_updated_at() cascade;

commit;
