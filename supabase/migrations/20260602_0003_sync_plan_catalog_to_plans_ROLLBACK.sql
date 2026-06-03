-- =============================================================================
-- ROLLBACK de 20260602_0003_sync_plan_catalog_to_plans.sql
--
-- 1. Detiene el espejo: elimina trigger y funciones de sincronización.
-- 2. Restaura los valores del seed PLACEHOLDER original de public.plans
--    (basic/pro/enterprise, precios en centavos, todos activos) tal como
--    estaban antes de la migración 0003. Esto deshace el efecto del backfill
--    (precios pisados desde el catálogo + 'enterprise' desactivado).
--
-- ADVERTENCIA: si el catálogo había agregado planes nuevos (trial/free u otros)
-- a public.plans vía el trigger, este rollback NO los borra (podrían estar
-- referenciados por memberships.plan_id). Solo los deja como quedaron.
-- =============================================================================

begin;

-- 1. Quitar trigger y funciones (defensivo: la tabla podría no existir).
do $$
begin
  if to_regclass('public.plan_catalog') is not null then
    execute 'drop trigger if exists trg_sync_plan_catalog_to_plans on public.plan_catalog';
  end if;
end $$;

drop function if exists public.trg_plan_catalog_sync();
drop function if exists public.fn_sync_plan_catalog_row(text);

-- 2. Restaurar el seed placeholder original (precios en centavos, activos).
update public.plans set
  name = 'Basic',
  description = 'Plan inicial: 1 caja, hasta 3 usuarios, reportes básicos.',
  price_cents_monthly = 150000,
  is_active = true,
  display_order = 1,
  features = '["1 caja registradora", "Hasta 3 usuarios", "Reportes diarios", "Soporte email"]'::jsonb,
  updated_at = now()
where code = 'basic';

update public.plans set
  name = 'Pro',
  description = 'Plan profesional: cajas ilimitadas, kitchen display, multi-mesero.',
  price_cents_monthly = 250000,
  is_active = true,
  display_order = 2,
  features = '["Cajas ilimitadas", "Usuarios ilimitados", "KDS", "Multi-mesero", "Reportes avanzados", "Soporte prioritario"]'::jsonb,
  updated_at = now()
where code = 'pro';

update public.plans set
  name = 'Enterprise',
  description = 'Plan empresarial: multi-sucursal, API, integraciones, SLA.',
  price_cents_monthly = 450000,
  is_active = true,
  display_order = 3,
  features = '["Todo de Pro", "Multi-sucursal consolidada", "API access", "Integraciones a medida", "SLA 99.9%", "Soporte 24/7"]'::jsonb,
  updated_at = now()
where code = 'enterprise';

commit;
