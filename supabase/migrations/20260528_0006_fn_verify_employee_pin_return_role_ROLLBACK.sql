-- =============================================================================
-- ROLLBACK 20260528_0006
-- =============================================================================
-- Revierte fn_verify_employee_pin a la versión previa (sin campo `role`
-- en el jsonb de respuesta). Solo afecta a callers que dependan del
-- campo `role` (session_controller.verifyPin del fix correspondiente).
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
begin
  if p_business_id is null or p_pin is null or length(trim(p_pin)) = 0 then
    return null;
  end if;

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

  return jsonb_build_object(
    'employee_id', v_employee.id,
    'first_name', v_employee.first_name,
    'last_name', v_employee.last_name,
    'business_id', v_employee.business_id,
    'user_id', v_employee.user_id
  );
end;
$$;

commit;
