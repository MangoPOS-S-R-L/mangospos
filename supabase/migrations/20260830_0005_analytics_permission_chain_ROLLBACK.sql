-- ROLLBACK de 20260830_0005_analytics_permission_chain.sql
begin;
revoke select on public.employee_roles            from analytics_ro;
revoke select on public.role_permissions          from analytics_ro;
revoke select on public.permissions               from analytics_ro;
revoke select on public.roles                     from analytics_ro;
revoke select on public.user_roles                from analytics_ro;
revoke select on public.user_permission_overrides from analytics_ro;
commit;
notify pgrst, 'reload schema';
