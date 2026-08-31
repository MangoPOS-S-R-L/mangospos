-- ROLLBACK de 20260829_0002_analytics_readonly_api.sql
-- Deja el sistema exactamente como estaba: elimina el esquema analytics y los dos roles.
-- Lo unico que la migracion creo en public.* fueron dos indices en customer_credits.
-- Se dejan por defecto: son aditivos, aceleran tambien al POS y quitarlos no aporta nada.
-- Si se quiere una reversion literal, descomentar los DROP INDEX del final.
-- Ninguna tabla, columna ni policy del POS fue modificada.
--
-- OJO: los roles son a nivel de CLUSTER. Si a analytics_ro se le llego a otorgar algun
-- privilegio en OTRA base del mismo servidor, el DROP ROLE falla con
-- "cannot be dropped because some objects depend on it" y el DETAIL dice en cual base.
-- DROP OWNED BY solo limpia la base actual: hay que conectarse a esa otra base y repetirlo.

begin;

drop schema if exists analytics cascade;

do $$
begin
  if exists (select 1 from pg_roles where rolname = 'analytics_ro') then
    revoke all privileges on all tables    in schema public from analytics_ro;
    revoke all privileges on all functions in schema public from analytics_ro;
    revoke all on schema public from analytics_ro;
    revoke analytics_ro from authenticator;
    -- limpia los privilegios residuales que impiden el DROP ROLE
    drop owned by analytics_ro;
    drop role analytics_ro;
  end if;

  if exists (select 1 from pg_roles where rolname = 'mango_analytics_view_owner') then
    revoke authenticated from mango_analytics_view_owner;
    revoke mango_analytics_view_owner from postgres;
    revoke mango_analytics_view_owner from authenticator;
    drop owned by mango_analytics_view_owner;
    revoke all privileges on all tables in schema public from mango_analytics_view_owner;
    drop role mango_analytics_view_owner;
  end if;
end $$;

commit;

-- Reversion literal de los indices (opcional, normalmente NO hace falta):
-- drop index if exists public.idx_customer_credits_fiscal_document;
-- drop index if exists public.idx_customer_credits_order;

notify pgrst, 'reload schema';
