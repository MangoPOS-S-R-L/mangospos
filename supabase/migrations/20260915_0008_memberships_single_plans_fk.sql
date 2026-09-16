-- =============================================================================
-- 20260915_0008_memberships_single_plans_fk.sql
--
-- HOTFIX de 20260915_0006.
--
-- QUÉ ROMPIÓ
--   0006 creó memberships.price_override_plan_id con FOREIGN KEY a plans, y
--   memberships ya tenía otra (plan_id → plans). Con DOS relaciones entre las
--   mismas tablas, PostgREST no puede resolver un embed sin nombre como
--
--       memberships?select=*,plan:plans(*)
--
--   y responde PGRST201 ("more than one relationship was found"). Esa consulta
--   la hacen al abrir la app del POS (Mi suscripción) y mango_dashboard
--   (billing): de ahí el "No se pudo completar la operación".
--
-- FIX
--   Quitar esa FK. La columna se queda (la usan las funciones de precio). La
--   escribe solo admin_set_price_override, que copia el plan_id vigente —ese
--   sí con FK—, y los planes nunca se borran, se desactivan. Se pierde una
--   garantía teórica; se gana que NINGÚN cliente tenga que cambiar sus
--   consultas, incluidas las versiones del POS que ya están instaladas.
--
-- Idempotente: borra la FK por columna, se llame como se llame. Al final pide
-- a PostgREST recargar el caché de esquema para que el cambio aplique ya.
-- =============================================================================

begin;

do $$
declare
  c record;
begin
  for c in
    select con.conname
      from pg_constraint con
      join pg_attribute a
        on a.attrelid = con.conrelid
       and a.attnum = any(con.conkey)
     where con.conrelid = 'public.memberships'::regclass
       and con.contype = 'f'
       and a.attname = 'price_override_plan_id'
  loop
    execute format('alter table public.memberships drop constraint %I', c.conname);
    raise notice 'FK eliminada: %', c.conname;
  end loop;
end $$;

commit;

notify pgrst, 'reload schema';
