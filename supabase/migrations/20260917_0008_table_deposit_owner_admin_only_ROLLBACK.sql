-- =============================================================================
-- ROLLBACK 20260917_0008 — Abonar es SOLO de dueño/administrador
-- =============================================================================
--
-- Devuelve el permiso a gerente/cajero y quita el candado del servidor, o sea
-- que vuelve a dejar que un cajero cargue saldo a una mesa. Solo tiene sentido
-- si el negocio cambia de opinión.
--
-- NO revierte los cuerpos de fn_table_deposit_add / _refund / _transfer a la
-- versión de la 0007: los deja como están pero sin el chequeo de rol, que es
-- lo único que la 0008 les agregó. Para volver de verdad a la 0007, re-aplicar
-- esa migración después de esta.
-- =============================================================================

begin;

-- El chequeo vive dentro de los tres RPC, así que no se puede "quitar" sin
-- reescribirlos. Lo neutralizamos: la función pasa a decir que cualquiera con
-- acceso al negocio puede manejar el saldo, que es el comportamiento 0007.
create or replace function public.fn_table_deposit_can_manage(
  p_business_id uuid,
  p_user_id     uuid default null
) returns boolean
language sql
stable
security definer
set search_path to 'public'
as $$
  select public.user_has_business_access(
           coalesce(p_user_id, auth.uid()), p_business_id);
$$;

comment on function public.fn_table_deposit_can_manage(uuid, uuid) is
  'ROLLBACK 0008: vuelve al criterio de la 0007 (cualquiera con acceso al '
  'negocio puede cargar saldo).';

insert into public.role_permissions (role_id, permission_id, allow)
select r.id, p.id, true
from public.roles r
cross join public.permissions p
where r.is_system = true
  and lower(r.name) in ('manager', 'cashier')
  and p.code = 'ventas.abono_mesa.registrar'
on conflict (role_id, permission_id) do nothing;

insert into public.role_permissions (role_id, permission_id, allow)
select r.id, p.id, true
from public.roles r
cross join public.permissions p
where r.is_system = true
  and lower(r.name) = 'manager'
  and p.code = 'ventas.abono_mesa.devolver'
on conflict (role_id, permission_id) do nothing;

commit;
