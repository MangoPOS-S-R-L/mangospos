-- =============================================================================
-- 20260602_0003_sync_plan_catalog_to_plans.sql
--
-- PROBLEMA QUE RESUELVE
--   En el mismo Supabase conviven DOS catálogos de planes que no coinciden:
--     * public.plans         → lo que LEE el registro/onboarding de mangospos
--                              (precio en centavos; FK destino de memberships.plan_id;
--                               lo consume el cobro recurrente Azul).
--     * public.plan_catalog  → lo que ADMINISTRA en vivo el panel
--                              (mangopos_administrador); precio en RD$ con centavos
--                              (numeric); CRUD real desde la UI admin.
--   Resultado: lo que el admin configura en el panel nunca aparecía en el signup,
--   porque son tablas distintas con precios distintos.
--
-- DECISIÓN (acordada con el usuario el 2026-06-02)
--   plan_catalog es la fuente de verdad editable. Esta migración convierte a
--   public.plans en un ESPEJO de plan_catalog mediante un trigger + backfill,
--   sin tocar el código de registro ni la cadena de billing:
--     * plans.id (UUID) se conserva estable (match por `code`), así los FK de
--       memberships.plan_id y los joins `plan:plans(*)` siguen válidos.
--     * Mapeo: price_monthly (RD$) → price_cents_monthly = round(price_monthly*100).
--     * is_active efectivo = (plan_catalog.is_active AND archived_at IS NULL).
--     * trial_days NO existe en plan_catalog: en INSERT usa el default (14) y en
--       UPDATE se preserva el valor existente (no se pisa).
--     * Planes presentes en `plans` pero ausentes/archivados en el catálogo
--       (p.ej. el seed placeholder 'enterprise') se DESACTIVAN (is_active=false),
--       nunca se borran (FK safety).
--   El filtro "solo planes de pago en el signup" (excluir trial/free) vive en la
--   app (signupPlansProvider), no acá: la tabla mantiene el catálogo completo.
--
-- IDEMPOTENTE: create or replace + on conflict + guards con to_regclass.
-- DEFENSIVA: si plan_catalog aún no existe en este entorno, crea solo las
--   funciones y omite trigger/backfill (las apps comparten DB en prod, donde
--   plan_catalog sí existe vía migraciones de mangopos_administrador).
-- ROLLBACK: 20260602_0003_sync_plan_catalog_to_plans_ROLLBACK.sql
-- =============================================================================

begin;

-- ---------------------------------------------------------------------------
-- 1. Función que sincroniza UNA fila del catálogo hacia public.plans.
--    SECURITY DEFINER para poder escribir plans (RLS solo permite service_role
--    en escritura). search_path fijo para evitar hijacking.
-- ---------------------------------------------------------------------------
create or replace function public.fn_sync_plan_catalog_row(p_code text)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  c record;
begin
  select * into c from public.plan_catalog where code = p_code;

  if not found then
    -- El plan desapareció del catálogo: ocultarlo en plans (sin borrar: FK safety).
    update public.plans
       set is_active = false,
           updated_at = now()
     where code = p_code;
    return;
  end if;

  insert into public.plans (
    code, name, description, price_cents_monthly,
    currency_code, is_active, display_order, features, updated_at
  )
  values (
    c.code,
    c.name,
    c.description,
    round(c.price_monthly * 100)::int,
    coalesce(nullif(c.currency_code, ''), 'DOP'),
    (c.is_active and c.archived_at is null),
    c.display_order,
    c.features,
    now()
  )
  on conflict (code) do update set
    name                = excluded.name,
    description         = excluded.description,
    price_cents_monthly = excluded.price_cents_monthly,
    currency_code       = excluded.currency_code,
    is_active           = excluded.is_active,
    display_order       = excluded.display_order,
    features            = excluded.features,
    updated_at          = now();
    -- NOTA: trial_days se omite a propósito (plan_catalog no lo maneja).
    --       INSERT → default 14; UPDATE → conserva el valor existente.
end;
$$;

comment on function public.fn_sync_plan_catalog_row(text) is
  'Sincroniza una fila de plan_catalog hacia public.plans (espejo). '
  'price_monthly RD$ → price_cents_monthly centavos. trial_days no se pisa.';

-- ---------------------------------------------------------------------------
-- 2. Trigger function: enruta INSERT/UPDATE/DELETE del catálogo al espejo.
-- ---------------------------------------------------------------------------
create or replace function public.trg_plan_catalog_sync()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  if (tg_op = 'DELETE') then
    update public.plans
       set is_active = false,
           updated_at = now()
     where code = old.code;
    return old;
  end if;
  perform public.fn_sync_plan_catalog_row(new.code);
  return new;
end;
$$;

-- ---------------------------------------------------------------------------
-- 3. Crear el trigger y correr el backfill — solo si plan_catalog existe.
-- ---------------------------------------------------------------------------
do $$
begin
  if to_regclass('public.plan_catalog') is null then
    raise notice
      'plan_catalog no existe en este entorno; se omiten trigger y backfill. '
      'Las funciones quedan creadas y el sync arrancará al existir la tabla.';
    return;
  end if;

  -- Trigger (recrear idempotente).
  execute 'drop trigger if exists trg_sync_plan_catalog_to_plans on public.plan_catalog';
  execute $ddl$
    create trigger trg_sync_plan_catalog_to_plans
      after insert or update or delete on public.plan_catalog
      for each row execute function public.trg_plan_catalog_sync()
  $ddl$;

  -- Backfill: espejar cada fila del catálogo hacia plans.
  perform public.fn_sync_plan_catalog_row(code) from public.plan_catalog;

  -- Desactivar en plans cualquier código que NO esté activo en el catálogo
  -- (p.ej. el seed placeholder 'enterprise'). Nunca se borra: solo se oculta.
  update public.plans p
     set is_active = false,
         updated_at = now()
   where p.is_active = true
     and not exists (
       select 1 from public.plan_catalog c
        where c.code = p.code
          and c.is_active = true
          and c.archived_at is null
     );

  raise notice 'Sync inicial plan_catalog → plans completado.';
end $$;

commit;
