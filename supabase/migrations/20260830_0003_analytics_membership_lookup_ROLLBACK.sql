-- ROLLBACK de 20260830_0003_analytics_membership_lookup.sql
-- Vuelve a romper las 20 vistas cuyas policies consultan user_businesses/memberships inline.
begin;
revoke select on public.user_businesses from analytics_ro;
revoke select on public.memberships     from analytics_ro;
commit;
notify pgrst, 'reload schema';
