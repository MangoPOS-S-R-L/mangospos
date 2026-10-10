-- Rollback manual de 20261010_0001. Quita el trigger para negocios nuevos.
-- NO revoca los permisos ya agregados a los roles cajero: no se pueden
-- distinguir de los que un dueño dio a mano después. Si hace falta quitarlos,
-- se hace por negocio desde Roles y permisos.
begin;
drop trigger if exists trg_roles_cashier_defaults on public.roles;
drop function if exists public.fn_roles_cashier_defaults();
drop function if exists public.fn_cashier_default_permission_codes();
commit;
