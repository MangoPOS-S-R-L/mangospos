-- ROLLBACK de 20260830_0002_analytics_auth_usage.sql
-- Deja de nuevo a analytics_ro sin USAGE sobre el esquema auth.
-- OJO: eso vuelve a romper las vistas cuyas policies llaman a auth.uid() en su expresion
-- (cash_register_sessions, cash_registers y las que compartan ese patron).

begin;
revoke usage on schema auth from analytics_ro;
commit;

notify pgrst, 'reload schema';
