-- =============================================================================
-- VERIFICAR 20260915_0009 (Compras F5a, presentaciones) — SOLO LECTURA
-- UNA sola consulta. No guarda presentaciones.
-- =============================================================================

with
fn as (
  select p.oid, p.prosecdef
    from pg_proc p
    join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'public' and p.proname = 'fn_inventory_item_presentations_save'
),
pres as (
  select x.*
    from public.inventory_item_presentations x
   where x.business_id = '35c5076a-bd85-4a1b-8d1c-ce719c4f9ae6'
)
select n, chequeo, resultado, estado
  from (
    select 1 as n, 'Tabla inventory_item_presentations' as chequeo,
           case when to_regclass('public.inventory_item_presentations') is null then 'no está' else 'está' end as resultado,
           case when to_regclass('public.inventory_item_presentations') is null then 'FALTA' else 'OK' end as estado
    union all
    select 2, 'RLS encendido y sus 2 policies',
           (select relrowsecurity::text from pg_class where oid = 'public.inventory_item_presentations'::regclass)
             || ' · ' || (select count(*) from pg_policies where schemaname = 'public' and tablename = 'inventory_item_presentations'),
           case when (select relrowsecurity from pg_class where oid = 'public.inventory_item_presentations'::regclass)
                 and (select count(*) from pg_policies where schemaname = 'public' and tablename = 'inventory_item_presentations') = 2
                then 'OK' else 'REVISAR' end
    union all
    select 3, 'Guardia de negocio (trigger)',
           count(*)::text, case when count(*) = 1 then 'OK' else 'FALTA' end
      from pg_trigger
     where tgname = 'trg_inventory_item_presentations_guard' and not tgisinternal
    union all
    select 4, 'Índices únicos (nombre por insumo, una de compra)',
           count(*)::text, case when count(*) = 2 then 'OK' else 'FALTA' end
      from pg_indexes
     where schemaname = 'public'
       and indexname in ('uq_inventory_item_presentations_unit', 'uq_inventory_item_presentations_default')
    union all
    select 5, 'fn_inventory_item_presentations_save: INVOKER · authenticated sí · anon no',
           coalesce(max(case when prosecdef then 'DEFINER' else 'INVOKER' end
             || ' · ' || has_function_privilege('authenticated', oid, 'execute')
             || ' · ' || has_function_privilege('anon', oid, 'execute')), 'no está'),
           case when count(*) = 1
                 and not bool_or(prosecdef)
                 and bool_and(has_function_privilege('authenticated', oid, 'execute'))
                 and not bool_or(has_function_privilege('anon', oid, 'execute'))
                then 'OK' else 'REVISAR' end
      from fn
    union all
    select 6, 'Penda · presentaciones cargadas (insumos con presentaciones)',
           count(*) || ' (' || count(distinct item_id) || ')', 'INFO'
      from pres
    union all
    -- La de compra tiene que estar aplanada en la ficha: si no, alguien cambió
    -- la unidad de compra por fuera (una app vieja) y órdenes/recepción usan
    -- otro contenido.
    select 7, 'Penda · de compra que NO coincide con la ficha (esperado 0)',
           count(*)::text,
           case when count(*) = 0 then 'OK' else 'REVISAR' end
      from pres p
      join public.inventory_items ii on ii.id = p.item_id
     where p.is_purchase_default
       and (ii.purchase_unit is distinct from p.unit or ii.pack_size is distinct from p.base_qty)
  ) v
 order by n;
