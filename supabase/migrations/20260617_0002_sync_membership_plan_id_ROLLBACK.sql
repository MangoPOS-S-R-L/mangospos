-- =============================================================================
-- ROLLBACK de 20260617_0002_sync_membership_plan_id.sql
--
-- Quita el trigger y la función de sincronización. NO revierte:
--   * Los plan_id re-derivados por el backfill (dejarlos seteados no es
--     destructivo: la POS sólo gana/corrige visibilidad del plan).
--   * Las filas trial/free/starter agregadas a `plans` (borrarlas violaría el
--     FK memberships.plan_id si quedaron referenciadas; déjalas o límpialas a
--     mano sólo si no hay membership apuntándolas).
-- =============================================================================

drop trigger if exists trg_sync_membership_plan_id on public.memberships;
drop function if exists public.fn_sync_membership_plan_id();
