-- =============================================================================
-- ROLLBACK de 20261009_0005_order_opener_name_alias.
-- Restaura la definición VIVA previa (tomada de prod 2026-10-09), con el
-- access check `c.bid` que da 42703 para la app. Solo usar si el fix causa
-- algo inesperado: con esto la app vuelve a no recibir el nombre del mesero.
-- =============================================================================

begin;

set local lock_timeout = '5s';
set local statement_timeout = '30s';

CREATE OR REPLACE FUNCTION public.fn_order_opener_name(p_order_id uuid)
 RETURNS text
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  v_business_id uuid;
  v_opened_by_employee_id uuid;
  v_opened_by uuid;
  v_first_name text;
  v_last_name text;
  v_full_name text;
BEGIN
  SELECT ts.business_id, ts.opened_by_employee_id, ts.opened_by
    INTO v_business_id, v_opened_by_employee_id, v_opened_by
  FROM public.orders o
  JOIN public.table_sessions ts ON ts.id = o.session_id
  WHERE o.id = p_order_id;

  IF v_business_id IS NULL THEN
    RETURN NULL;
  END IF;

  -- Access check: service_role salta, authenticated valida pertenencia.
  IF auth.role() <> 'service_role' THEN
    IF NOT EXISTS (
      SELECT 1 FROM public.current_user_business_ids() c
      WHERE c.bid = v_business_id
    ) THEN
      RAISE EXCEPTION 'access denied' USING ERRCODE = '42501';
    END IF;
  END IF;

  -- Prioridad 1: empleado del PIN multimesero.
  IF v_opened_by_employee_id IS NOT NULL THEN
    SELECT first_name, last_name
      INTO v_first_name, v_last_name
    FROM public.employees
    WHERE id = v_opened_by_employee_id;
    IF v_first_name IS NOT NULL AND length(trim(v_first_name)) > 0 THEN
      RETURN trim(v_first_name || ' ' || COALESCE(v_last_name, ''));
    END IF;
  END IF;

  -- Prioridad 2: auth user → empleado en el mismo business.
  IF v_opened_by IS NOT NULL THEN
    SELECT first_name, last_name
      INTO v_first_name, v_last_name
    FROM public.employees
    WHERE user_id = v_opened_by
      AND business_id = v_business_id
    LIMIT 1;
    IF v_first_name IS NOT NULL AND length(trim(v_first_name)) > 0 THEN
      RETURN trim(v_first_name || ' ' || COALESCE(v_last_name, ''));
    END IF;
  END IF;

  -- Prioridad 3: full_name del profile como último recurso.
  IF v_opened_by IS NOT NULL THEN
    SELECT full_name INTO v_full_name
    FROM public.profiles
    WHERE id = v_opened_by;
    IF v_full_name IS NOT NULL AND length(trim(v_full_name)) > 0 THEN
      RETURN trim(v_full_name);
    END IF;
  END IF;

  RETURN NULL;
END;
$function$;

REVOKE ALL ON FUNCTION public.fn_order_opener_name(uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.fn_order_opener_name(uuid) TO authenticated;

commit;
