-- =============================================================================
-- Sincroniza memberships.plan_id (uuid → plans) desde memberships.plan_type (texto),
-- tratando plan_type como la FUENTE DE VERDAD (es lo que escribe el dashboard admin).
--
-- CONTEXTO (divergencia dashboard ↔ POS, confirmada con datos vivos 2026-06-17):
--   * El dashboard admin (repo mangopos_administrador) asigna el plan escribiendo
--     SOLO `memberships.plan_type` (código texto) vía RPC `update_business_membership`.
--     NO toca `plan_id`. La POS lee `plan_id` (uuid → plans) → "Sin plan asignado".
--   * Además los catálogos divergieron en CÓDIGOS: el dashboard (`plan_catalog`) usa
--     trial/free/basic/pro/enterprise/starter; la POS (`plans`) solo tenía
--     basic/pro/enterprise. Faltan trial/free/starter → esos plan_type no resolvían.
--   * Y hay plan_id "stale": filas con plan_type='pro'/'starter' apuntando a
--     'enterprise'/'basic' (muestran el plan equivocado).
--
-- FIX (3 partes):
--   1. Alinear `plans` con `plan_catalog`: agregar trial/free/starter (inactivos;
--      la fila existe solo para resolver plan_id y mostrar el nombre correcto).
--   2. Trigger que mantiene plan_id en sync con plan_type (insert: rellena si falta;
--      update of plan_type: re-deriva — caso dashboard).
--   3. Backfill: re-derivar plan_id desde plan_type en TODAS las filas ancla
--      (corrige nulls Y stale).
--
-- Idempotente. Nombres/precios de basic/pro/enterprise NO se tocan.
-- =============================================================================

-- ---------------------------------------------------------------------------
-- 1. Agregar a `plans` los códigos del dashboard que faltaban.
--    price 0 y is_active=false (trial/free/starter no son planes vendibles;
--    la fila existe para que plan_type resuelva a un plan_id con nombre).
-- ---------------------------------------------------------------------------
insert into public.plans (code, name, description, price_cents_monthly, currency_code, is_active, display_order, features)
values
  ('trial',   'Trial',   'Período de prueba.',                0, 'DOP', false, 0,   '[]'::jsonb),
  ('free',    'Free',    'Plan gratuito (legacy).',           0, 'DOP', false, 1,   '[]'::jsonb),
  ('starter', 'Starter', 'Plan inicial (legacy, descontinuado).', 0, 'DOP', false, 100, '[]'::jsonb)
on conflict (code) do nothing;

-- ---------------------------------------------------------------------------
-- 2. Trigger de sincronización plan_type → plan_id.
-- ---------------------------------------------------------------------------
create or replace function public.fn_sync_membership_plan_id()
returns trigger
language plpgsql
security definer
set search_path = public, pg_temp
as $$
begin
  if tg_op = 'INSERT' then
    -- Respeta un plan_id provisto explícitamente (onboarding POS setea ambos);
    -- sólo rellena cuando falta.
    if new.plan_id is null then
      select p.id into new.plan_id from public.plans p where p.code = new.plan_type;
    end if;
  else
    -- UPDATE OF plan_type: el plan cambió (típicamente desde el dashboard) →
    -- re-derivar plan_id para que la POS refleje el plan actual.
    select p.id into new.plan_id from public.plans p where p.code = new.plan_type;
  end if;
  return new;
end;
$$;

comment on function public.fn_sync_membership_plan_id() is
  'Mantiene memberships.plan_id en sync con plan_type (plans.code = plan_type). '
  'Puente para que los planes asignados desde el dashboard (que sólo escribe '
  'plan_type) aparezcan correctamente en la POS (que lee plan_id).';

drop trigger if exists trg_sync_membership_plan_id on public.memberships;
create trigger trg_sync_membership_plan_id
  before insert or update of plan_type on public.memberships
  for each row
  execute function public.fn_sync_membership_plan_id();

-- ---------------------------------------------------------------------------
-- 3. Backfill: re-derivar plan_id desde plan_type en las filas ancla.
--    Corrige tanto los NULL como los stale (plan_id que no corresponde al
--    plan_type actual). Sólo filas is_billing_anchor (las que lee la POS).
-- ---------------------------------------------------------------------------
update public.memberships m
set plan_id = p.id
from public.plans p
where m.is_billing_anchor = true
  and p.code = m.plan_type
  and m.plan_id is distinct from p.id;
