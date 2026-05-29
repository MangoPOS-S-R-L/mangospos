-- =============================================================================
-- fn_current_employee_id: resuelve el `employee_id` del usuario autenticado
-- en un business dado. Reemplaza el SELECT directo a `employees` que hace
-- Flutter para poblar `order_items.created_by_employee_id` como fallback
-- cuando el cajero/admin agrega items sin pasar por el PIN multimesero.
--
-- Por qué SECURITY DEFINER:
-- La tabla `employees` típicamente tiene RLS que solo permite SELECT a
-- admins / al mismo usuario o filtrado por business membership. Un cajero
-- sin permisos especiales no podía leer ni su propia fila de `employees`,
-- por lo que el fallback de Flutter caía a `null` silenciosamente y
-- todos los items que metía aparecían como "Sin asignar" en el tooltip
-- de auditoría.
--
-- Esta función bypassea RLS (SECURITY DEFINER) pero solo expone el
-- employee_id correspondiente a `auth.uid()` del caller — no permite
-- mirar empleados de otros usuarios. Filtra adicionalmente por
-- `business_id` porque un mismo `user_id` puede tener varias filas de
-- `employees` (multi-negocio).
--
-- Retorna NULL si:
--   - No hay usuario autenticado (auth.uid() es null)
--   - El usuario no tiene fila en `employees` para ese business
--   - El employee está soft-deleted (si la tabla tiene columna `deleted_at`)
-- =============================================================================

CREATE OR REPLACE FUNCTION public.fn_current_employee_id(
  p_business_id uuid
)
RETURNS uuid
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path TO 'public'
AS $function$
  SELECT e.id
  FROM public.employees e
  WHERE e.user_id = auth.uid()
    AND e.business_id = p_business_id
  LIMIT 1;
$function$;

REVOKE ALL ON FUNCTION public.fn_current_employee_id(uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.fn_current_employee_id(uuid) TO authenticated;

COMMENT ON FUNCTION public.fn_current_employee_id(uuid) IS
  'Resuelve el employee_id del auth user actual filtrado por business. SECURITY DEFINER para que cajeros/admins puedan obtener su propio id incluso si RLS bloquea SELECT directo a employees. Usado por Flutter para poblar order_items.created_by_employee_id como fallback al modo multimesero.';
