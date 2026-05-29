-- =============================================================================
-- 20260528_0006 — fn_verify_employee_pin retorna el role del empleado
-- =============================================================================
--
-- PROBLEMA QUE RESUELVE
-- ─────────────────────
-- El flujo "PIN de supervisor" en Flutter (session_controller.verifyPin)
-- valida el PIN contra `employees` y después busca el rol del empleado
-- en `user_businesses` para decidir si alcanza para autorizar (supervisor/
-- admin/owner).
--
-- Pero el RLS de user_businesses tiene esta política:
--
--   CREATE POLICY "user_businesses_select_own"
--     ON public.user_businesses FOR SELECT TO authenticated
--     USING (user_id = auth.uid());
--
-- O sea: un cajero/mesero logueado SOLO puede ver SU propia fila. Cuando
-- intenta validar un PIN de supervisor (que pertenece a OTRO user_id),
-- la query a user_businesses devuelve null por RLS → el rol queda
-- desconocido → la validación falla con "PIN inválido" aunque el PIN
-- sea correcto y el supervisor tenga rol owner/admin/manager.
--
-- Síntoma reportado: "El PIN de supervisor no funciona al borrar mesa".
-- Pasa en TODOS los negocios, no es bug de configuración.
--
-- FIX
-- ───
-- Modificar fn_verify_employee_pin (que ya corre SECURITY DEFINER → bypassea
-- RLS) para que ADEMÁS de retornar el employee, retorne el `role` desde
-- user_businesses. Así el cliente Flutter recibe el rol directamente en la
-- respuesta del RPC sin necesidad de hacer una segunda query bloqueada por
-- RLS.
--
-- El RPC retorna `role = null` si el empleado no tiene `user_id` (caso
-- típico de personal sin cuenta de login). El cliente decide qué hacer
-- en ese caso — hoy esos empleados no pueden autorizar acciones de
-- supervisor, lo cual es consistente con el comportamiento actual.
--
-- BACKWARDS COMPAT
-- ────────────────
-- El cambio es ADITIVO al jsonb de respuesta. Callers que no leen el
-- campo `role` siguen funcionando sin cambios (multimesero_repository:63
-- por ejemplo solo usa employee_id, user_id, business_id).
--
-- IDEMPOTENTE
-- ───────────
-- create or replace + grant if not exists. Re-ejecutar es seguro.
-- =============================================================================

begin;

create or replace function public.fn_verify_employee_pin(
  p_business_id uuid,
  p_pin text
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_employee record;
  v_role text;
begin
  if p_business_id is null or p_pin is null or length(trim(p_pin)) = 0 then
    return null;
  end if;

  -- El caller debe pertenecer al business. Sin esto, cualquier autenticado
  -- podría sondear PINs de cualquier negocio.
  if not public.user_has_business_access(auth.uid(), p_business_id) then
    raise exception 'UNAUTHORIZED_BUSINESS';
  end if;

  select e.id, e.first_name, e.last_name, e.business_id, e.user_id
    into v_employee
  from public.employees e
  where e.business_id = p_business_id
    and e.pin = trim(p_pin)
    and e.status = 'active'
  limit 1;

  if v_employee.id is null then
    return null;
  end if;

  -- Rol del empleado en este business. Sin esta resolución del lado server
  -- el cliente no puede determinarlo: el RLS user_businesses_select_own
  -- bloquea la lectura de filas que no son del propio user. Como esta
  -- función corre SECURITY DEFINER, podemos hacer el join aquí sin
  -- preocuparnos por RLS — la autorización ya la dimos arriba al validar
  -- que el caller pertenece al business.
  if v_employee.user_id is not null then
    select ub.role into v_role
      from public.user_businesses ub
     where ub.user_id = v_employee.user_id
       and ub.business_id = p_business_id
     limit 1;
  end if;

  return jsonb_build_object(
    'employee_id', v_employee.id,
    'first_name', v_employee.first_name,
    'last_name', v_employee.last_name,
    'business_id', v_employee.business_id,
    'user_id', v_employee.user_id,
    'role', v_role
  );
end;
$$;

grant execute on function public.fn_verify_employee_pin(uuid, text)
  to authenticated;

comment on function public.fn_verify_employee_pin(uuid, text) is
  'Valida un PIN contra los empleados activos de un business. Retorna el '
  'employee + el rol en user_businesses (jsonb) si match, NULL si no. '
  'Requiere que el caller pertenezca al business. Usado por multimesero '
  'para identificar al mesero y por session_controller.verifyPin para '
  'autorizar acciones de supervisor (donde el role del response es '
  'necesario porque el RLS de user_businesses no deja al cajero leer '
  'filas de otros users).';

commit;
