-- =============================================================================
-- fn_order_opener_name: arreglar el access check que tumbaba la función para
-- TODA llamada desde la app.
--
-- EL BUG (verificado en prod 2026-10-09 con pg_get_functiondef):
--   SELECT 1 FROM public.current_user_business_ids() c WHERE c.bid = ...
-- `current_user_business_ids()` devuelve SETOF uuid (desde 20260708_0001):
-- su única columna se llama `current_user_business_ids`, así que `c.bid` no
-- existe → 42703 para cualquier caller `authenticated`. Con service_role el
-- check se salta, por eso en el SQL Editor "funciona".
--
-- EFECTO EN EL POS: la app nunca recibió el nombre del mesero. Caía a su
-- respaldo, que era el usuario logueado → precuentas y facturas salían a
-- nombre de quien tenía la sesión iniciada, no del mesero que abrió la mesa.
-- (La app ya no cae al usuario logueado; con esto vuelve a recibir el nombre
-- correcto del servidor.)
--
-- EL FIX: alias EXPLÍCITO de columna `c(business_id)`. Funciona igual si la
-- función devuelve SETOF uuid o TABLE(business_id uuid).
--
-- El cuerpo es la definición VIVA (no la del repo, 20260529_0005, que decía
-- `c.business_id`); lo único que cambia es el alias. Prioridad intacta:
--   1. opened_by_employee_id (PIN multimesero)
--   2. empleado de la cuenta opened_by en el mismo negocio
--   3. profiles.full_name de opened_by
--
-- IDEMPOTENTE: sí. REVERSIBLE: sí (_ROLLBACK restaura la definición viva).
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
  -- Alias de columna explícito: current_user_business_ids() es SETOF uuid.
  IF auth.role() <> 'service_role' THEN
    IF NOT EXISTS (
      SELECT 1 FROM public.current_user_business_ids() AS c(business_id)
      WHERE c.business_id = v_business_id
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

-- -----------------------------------------------------------------------------
-- VERIFICACIÓN (correr aparte, después de aplicar): debe decir 'OK'.
-- -----------------------------------------------------------------------------
-- select case
--          when pg_get_functiondef(to_regprocedure('public.fn_order_opener_name(uuid)'))
--               ~* 'current_user_business_ids\(\)\s+as\s+c\s*\(\s*business_id\s*\)'
--          then 'OK' else 'NO APLICADA' end as estado;
