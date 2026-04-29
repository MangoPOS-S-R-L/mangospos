-- Fix: fn_require_open_cash_session debe buscar caja abierta en TODOS los
-- businesses del user, no solo en uno arbitrario.
--
-- Bug original: la función hacía
--   SELECT bid INTO v_business_id FROM current_user_business_ids() LIMIT 1;
--   ... cash session check sobre v_business_id ...
--
-- Si el user pertenece a múltiples businesses (caso común para admins
-- multi-tenant), LIMIT 1 sin ORDER BY agarra cualquiera. Si ese business
-- no tiene caja abierta, raise CASH_SESSION_NOT_OPEN aunque OTRO business
-- del user sí tenga caja activa.
--
-- Fix: iterar todos los businesses del user, devolver la primera caja
-- abierta encontrada. Solo raise si NINGÚN business del user tiene caja.

CREATE OR REPLACE FUNCTION "public"."fn_require_open_cash_session"()
RETURNS "uuid"
LANGUAGE "plpgsql"
SECURITY DEFINER
SET "search_path" TO 'public'
AS $$
DECLARE
  v_session_id uuid;
  v_business_count int := 0;
BEGIN
  -- Verificar primero que el user tenga al menos 1 business asociado.
  SELECT count(*) INTO v_business_count
  FROM public.current_user_business_ids() AS bid;

  IF v_business_count = 0 THEN
    RAISE EXCEPTION 'BUSINESS_NOT_FOUND';
  END IF;

  -- Buscar caja abierta entre TODOS los businesses del user.
  SELECT s.id INTO v_session_id
  FROM public.cash_register_sessions s
  JOIN public.cash_registers cr ON cr.id = s.cash_register_id
  WHERE cr.business_id IN (
    SELECT bid FROM public.current_user_business_ids() AS bid
  )
    AND s.status = 'open'
    AND s.closed_at IS NULL
  ORDER BY s.opened_at DESC
  LIMIT 1;

  IF v_session_id IS NULL THEN
    RAISE EXCEPTION 'CASH_SESSION_NOT_OPEN';
  END IF;

  RETURN v_session_id;
END;
$$;

GRANT EXECUTE ON FUNCTION "public"."fn_require_open_cash_session"() TO "anon";
GRANT EXECUTE ON FUNCTION "public"."fn_require_open_cash_session"() TO "authenticated";
GRANT EXECUTE ON FUNCTION "public"."fn_require_open_cash_session"() TO "service_role";

-- También hay una variante que toma p_user_id (la que llama
-- fn_open_manual_or_quick). Refactorearla con la misma lógica.
CREATE OR REPLACE FUNCTION "public"."fn_require_open_cash_session"("p_user_id" "uuid")
RETURNS "uuid"
LANGUAGE "plpgsql"
SECURITY DEFINER
SET "search_path" TO 'public'
AS $$
DECLARE
  v_session_id uuid;
  v_user_id uuid := COALESCE(p_user_id, auth.uid());
BEGIN
  IF v_user_id IS NULL THEN
    RAISE EXCEPTION 'USER_REQUIRED';
  END IF;

  -- Buscar caja abierta entre TODOS los businesses asociados al user
  -- (memberships + user_businesses + employees).
  SELECT s.id INTO v_session_id
  FROM public.cash_register_sessions s
  JOIN public.cash_registers cr ON cr.id = s.cash_register_id
  WHERE cr.business_id IN (
    SELECT business_id FROM public.memberships WHERE user_id = v_user_id
    UNION
    SELECT business_id FROM public.user_businesses WHERE user_id = v_user_id
    UNION
    SELECT business_id FROM public.employees WHERE user_id = v_user_id
  )
    AND s.status = 'open'
    AND s.closed_at IS NULL
  ORDER BY s.opened_at DESC
  LIMIT 1;

  IF v_session_id IS NULL THEN
    RAISE EXCEPTION 'CASH_SESSION_NOT_OPEN';
  END IF;

  RETURN v_session_id;
END;
$$;

GRANT EXECUTE ON FUNCTION "public"."fn_require_open_cash_session"("uuid") TO "anon";
GRANT EXECUTE ON FUNCTION "public"."fn_require_open_cash_session"("uuid") TO "authenticated";
GRANT EXECUTE ON FUNCTION "public"."fn_require_open_cash_session"("uuid") TO "service_role";
