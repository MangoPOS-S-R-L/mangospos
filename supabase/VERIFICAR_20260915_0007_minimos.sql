-- =============================================================================
-- VERIFICAR 20260915_0007 (Compras F3, mínimos en lote) — SOLO LECTURA
-- UNA sola consulta. No guarda mínimos: la función se prueba desde la pantalla
-- «Mínimos en lote».
-- =============================================================================

with
fn as (
  select p.oid, p.prosecdef, p.proconfig
    from pg_proc p
    join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'public' and p.proname = 'fn_inventory_set_min_stock_bulk'
),
penda_wh as (
  select w.id
    from public.warehouses w
   where w.business_id = '35c5076a-bd85-4a1b-8d1c-ce719c4f9ae6'
),
-- Todo el negocio, colchón de 3 días: cómo están hoy los mínimos generales
-- frente a lo que sugiere el consumo.
proj as materialized (
  select *
    from public.fn_purchase_projection(
           '35c5076a-bd85-4a1b-8d1c-ce719c4f9ae6', null, 7, 30, 2, 3, null, false)
)
select n, chequeo, resultado, estado
  from (
    select 1 as n, 'fn_inventory_set_min_stock_bulk' as chequeo,
           case when count(*) = 1 then 'está' else 'no está' end as resultado,
           case when count(*) = 1 then 'OK' else 'FALTA' end as estado
      from fn
    union all
    select 2, 'SECURITY DEFINER con lock_timeout propio',
           coalesce(max(array_to_string(proconfig, ', ')), ''),
           case when bool_and(prosecdef) and bool_and(proconfig @> array['lock_timeout=5s']) then 'OK' else 'REVISAR' end
      from fn
    union all
    select 3, 'EXECUTE: authenticated sí · anon no',
           coalesce(max('authenticated=' || has_function_privilege('authenticated', oid, 'execute')
             || ' · anon=' || has_function_privilege('anon', oid, 'execute')), ''),
           case when bool_and(has_function_privilege('authenticated', oid, 'execute'))
                 and not bool_or(has_function_privilege('anon', oid, 'execute')) then 'OK' else 'REVISAR' end
      from fn
    union all
    select 4, 'Funciones de permiso que usa (user_business_role, user_has_business_permission)',
           (to_regprocedure('public.user_business_role(uuid,uuid)') is not null)::text || ' · '
             || (to_regprocedure('public.user_has_business_permission(uuid,text)') is not null)::text,
           case when to_regprocedure('public.user_business_role(uuid,uuid)') is not null
                 and to_regprocedure('public.user_has_business_permission(uuid,text)') is not null
                then 'OK' else 'FALTA' end
    union all
    select 5, 'Penda · insumos activos con mínimo general (> 0)', count(*)::text, 'INFO'
      from public.inventory_items ii
     where ii.business_id = '35c5076a-bd85-4a1b-8d1c-ce719c4f9ae6'
       and coalesce(ii.is_active, true)
       and coalesce(ii.min_stock, 0) > 0
    union all
    select 6, 'Penda · mínimos propios por almacén', count(*)::text, 'INFO'
      from public.inventory_stock s
      join penda_wh on penda_wh.id = s.warehouse_id
     where s.min_stock is not null
    union all
    select 7, 'Penda · con consumo y mínimo general POR DEBAJO del sugerido', count(*)::text, 'INFO'
      from proj
     where consumption > 0 and min_stock < suggested_min_stock
    union all
    select 8, 'Penda · dormidos (sin consumo en 30 días) que todavía tienen mínimo', count(*)::text, 'INFO'
      from proj
     where consumption <= 0 and min_stock > 0
  ) v
 order by n;
