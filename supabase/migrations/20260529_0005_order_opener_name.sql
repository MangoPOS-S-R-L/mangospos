-- =============================================================================
-- fn_order_opener_name: devuelve el nombre del mesero que ABRIÓ la mesa
-- de la orden — la fuente de verdad para "MESERO:" en comanda, precuenta
-- y factura.
--
-- Por qué SECURITY DEFINER:
-- El helper Flutter `_loadWaiterName` hacía SELECTs directos a la tabla
-- `employees` para resolver el nombre del opener. RLS sobre `employees`
-- bloquea esos SELECTs para cajeros sin permisos especiales, así que el
-- helper caía silenciosamente al `fallback = sessionProvider.userName`
-- — es decir, el nombre del CAJERO logueado en el dispositivo, no del
-- mesero que efectivamente abrió la mesa. Resultado visible: en modo
-- multimesero, la factura impresa decía "MESERO: <nombre del cajero>"
-- aunque la mesa la hubiera abierto otro empleado vía PIN.
--
-- Esta función encapsula la lógica priorizada que ya tenía Flutter,
-- pero corre con privilegios elevados y solo expone el resultado para
-- una orden a la que el caller tiene acceso (verifica business_id).
--
-- Prioridad (igual que `_loadWaiterName`):
--   1. `table_sessions.opened_by_employee_id` — el employee_id que metió
--      PIN al abrir la mesa (modo multimesero, PRD 0001). Esta es la
--      fuente más confiable.
--   2. `table_sessions.opened_by` (auth.users.id) → match a `employees`
--      por `user_id` filtrado por business_id. Cubre cuando un cajero
--      abre la mesa sin pasar por PIN.
--   3. `profiles.full_name` por el `opened_by` user_id, como último
--      recurso si no hay fila en `employees`.
--
-- Retorna NULL si:
--   - La orden no existe
--   - El caller no tiene acceso al business de la orden
--   - Ningún paso de la cadena de prioridades resuelve un nombre
--
-- El caller (Flutter) sigue teniendo su propio fallback al usuario
-- logueado si esta función devuelve NULL.
-- =============================================================================

CREATE OR REPLACE FUNCTION public.fn_order_opener_name(
  p_order_id uuid
)
RETURNS text
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
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

COMMENT ON FUNCTION public.fn_order_opener_name(uuid) IS
  'Nombre del mesero que abrió la mesa de la orden. Prioridad: opened_by_employee_id (PIN multimesero) → opened_by user_id → profiles.full_name. SECURITY DEFINER para bypassar RLS de employees. Usado por Flutter para imprimir "MESERO:" en comanda/precuenta/factura.';
