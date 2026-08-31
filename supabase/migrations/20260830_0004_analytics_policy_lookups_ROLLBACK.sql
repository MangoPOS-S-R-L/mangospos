-- ROLLBACK de 20260830_0004_analytics_policy_lookups.sql
-- Vuelve a romper print_areas, print_area_printers y secuencias_ncf.
begin;
revoke select on public.employees  from analytics_ro;
revoke select on public.businesses from analytics_ro;
commit;
notify pgrst, 'reload schema';
