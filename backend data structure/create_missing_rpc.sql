-- ================================================================
-- CREACIÓN DE FUNCIÓN RPC FALTANTE
-- Corrige el error "Could not find function public.fn_user_effective_permissions"
-- ================================================================

CREATE OR REPLACE FUNCTION public.fn_user_effective_permissions(p_business_id uuid, p_user_id uuid)
RETURNS json
LANGUAGE plpgsql
SECURITY DEFINER
AS $function$
DECLARE
  v_employee_id uuid;
  v_permissions text[];
BEGIN
  -- 1. Obtener el ID del empleado para este usuario y negocio
  SELECT id INTO v_employee_id
  FROM public.employees
  WHERE user_id = p_user_id AND business_id = p_business_id;

  -- Si no es empleado, retornar array vacío
  IF v_employee_id IS NULL THEN
    RETURN '[]'::json;
  END IF;

  -- 2. Obtener todos los permisos efectivos (suma de todos sus roles)
  SELECT array_agg(DISTINCT rp.permission_key)
  INTO v_permissions
  FROM public.employee_roles er
  JOIN public.role_permissions rp ON rp.role_id = er.role_id
  WHERE er.employee_id = v_employee_id;

  -- Retornar como JSON (si es null, devolver array vacío)
  RETURN to_json(COALESCE(v_permissions, '{}'::text[]));
END;
$function$;
