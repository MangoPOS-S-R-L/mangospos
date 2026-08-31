-- DIAGNOSTICO_cash_register_sessions.sql
-- Por que analytics.cash_register_sessions da "permission denied for schema auth" con el rol
-- analytics_ro. Solo lee.
--
-- Ya sabemos que la vista es `select src.* from cash_register_sessions src where true`, o sea
-- que su alcance depende por completo de la RLS. El error tiene que venir de la policy.
--
-- TODO en UNA sola consulta: el SQL Editor de Studio solo muestra el ultimo result set.

select 1 as n, 'USAGE sobre esquema auth' as tema,
       'analytics_ro=' || has_schema_privilege('analytics_ro','auth','USAGE') ||
       '  view_owner=' || has_schema_privilege('mango_analytics_view_owner','auth','USAGE') ||
       '  authenticated=' || has_schema_privilege('authenticated','auth','USAGE') ||
       '  anon=' || has_schema_privilege('anon','auth','USAGE') as detalle
union all
select 2, 'EXECUTE auth.uid()',
       'analytics_ro=' || has_function_privilege('analytics_ro','auth.uid()','EXECUTE') ||
       '  view_owner=' || has_function_privilege('mango_analytics_view_owner','auth.uid()','EXECUTE')
union all
select 3, 'POLICY ' || tablename || '.' || policyname || ' [' || cmd || '] roles=' || roles::text,
       coalesce(qual, '(sin using)')
  from pg_policies
 where schemaname = 'public'
   and tablename in ('cash_register_sessions', 'cash_registers')
union all
select 4, 'OTRAS POLICIES QUE USAN auth.', tablename || '.' || policyname || ' [' || cmd || ']'
  from pg_policies
 where schemaname = 'public'
   and (qual like '%auth.%' or with_check like '%auth.%')
union all
select 5, 'RESUMEN', 'policies del POS que mencionan auth.: ' ||
       (select count(*)::text from pg_policies
         where schemaname='public' and (qual like '%auth.%' or with_check like '%auth.%'))
order by n, tema;
