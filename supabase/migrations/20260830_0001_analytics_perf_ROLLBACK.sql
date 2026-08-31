-- ROLLBACK de 20260830_0001_analytics_perf.sql
--
-- Devuelve las vistas al pin de conjunto de 20260829_0002. OJO: eso reintroduce el Seq Scan
-- de fiscal_documents (medido: 356 ms -> 1.531 ms en el VPS con cache fria). Solo tiene sentido
-- si el pin escalar causara algun problema inesperado.
--
-- Los indices NO se tocan: son aditivos y tambien aceleran al POS.

begin;

-- 1. Volver a crear las vistas con el predicado original.
--    Se logra reaplicando la migracion anterior, que es idempotente:
--        \i supabase/migrations/20260829_0002_analytics_readonly_api.sql
--    Hay que correrla ANTES de borrar la funcion escalar, porque las vistas dependen de ella.

-- 2. Una vez reaplicada la anterior, quitar la funcion escalar:
drop function if exists analytics.allowed_business_id();

commit;

notify pgrst, 'reload schema';
