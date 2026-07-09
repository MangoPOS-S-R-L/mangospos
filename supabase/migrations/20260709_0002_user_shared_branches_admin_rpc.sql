-- Gestionar `user_businesses.shared_across_branches` desde la pantalla de
-- usuarios (un admin edita la fila de OTRO usuario).
--
-- Por que RPC: `user_businesses` tiene RLS `user_id = auth.uid()` (cada quien
-- solo ve/escribe SUS filas). Un owner/admin no puede leer ni actualizar la
-- fila de un empleado directamente. Estas dos funciones son SECURITY DEFINER
-- (bypass RLS) pero con guardas de autorizacion. Son NUEVAS y AISLADAS: no
-- tocan los RPC existentes (fn_get/save_user_access_profile), asi que no
-- pueden romper nada que ya funcione.
--
-- auth.uid() sigue devolviendo el usuario real dentro de SECURITY DEFINER (es
-- un claim del JWT, no depende del owner de la funcion), por eso
-- is_admin_of_business / is_member_of_business evaluan bien al llamador.

begin;

-- Setter: solo owner/admin del negocio puede marcar. Resuelve el user_id del
-- empleado y actualiza su fila de user_businesses de ESA sucursal. El flag en
-- una sucursal del grupo basta: el RLS abre todas las hermanas (mismo owner_id).
create or replace function public.fn_set_user_shared_across_branches(
  p_employee_id uuid,
  p_business_id uuid,
  p_shared boolean
) returns void
language plpgsql
security definer
set search_path to 'public'
as $$
declare
  v_user_id uuid;
begin
  if not public.is_admin_of_business(p_business_id) then
    raise exception 'access denied' using errcode = '42501';
  end if;

  select e.user_id into v_user_id
  from public.employees e
  where e.id = p_employee_id and e.business_id = p_business_id;

  -- Empleado sin login enlazado: no hay fila de user_businesses que marcar.
  if v_user_id is null then
    return;
  end if;

  update public.user_businesses
  set shared_across_branches = coalesce(p_shared, false)
  where user_id = v_user_id and business_id = p_business_id;
end;
$$;

-- Getter: devuelve el flag actual del empleado en la sucursal. Miembro del
-- negocio para poder leerlo; si no, false (nunca lanza, no rompe el load).
create or replace function public.fn_get_user_shared_across_branches(
  p_employee_id uuid,
  p_business_id uuid
) returns boolean
language sql
stable
security definer
set search_path to 'public'
as $$
  select case
    when not public.is_member_of_business(p_business_id) then false
    else coalesce((
      select ub.shared_across_branches
      from public.employees e
      join public.user_businesses ub
        on ub.user_id = e.user_id and ub.business_id = e.business_id
      where e.id = p_employee_id and e.business_id = p_business_id
      limit 1
    ), false)
  end;
$$;

commit;
