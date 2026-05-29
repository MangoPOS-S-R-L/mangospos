-- =============================================================================
-- fn_order_opener_employee_id: hermano de `fn_order_opener_name` pero
-- devuelve el employee_id (uuid) en vez del nombre. Sirve para escribir
-- `order_items.created_by_employee_id` con la identidad del mesero que
-- abrió la mesa en vez de la del cajero/admin que clickeó "agregar".
--
-- Por qué:
-- En un POS multimesero, el negocio quiere que toda la cadena de
-- documentos de una mesa apunte a la misma persona — el mesero
-- responsable. Ese es el OPENER de la mesa (`opened_by_employee_id`):
--
--   - Comanda enviada a cocina → muestra OPENER
--   - Precuenta → muestra OPENER
--   - Factura/NCF → muestra OPENER
--   - Tooltip de auditoría sobre cada item → ahora también OPENER
--
-- Sin esto, cuando un cajero/admin entraba a una mesa abierta por un
-- mesero y le agregaba productos (caso común: cajero ayuda con un
-- pedido tomado por un mesero), el item quedaba atribuido al cajero,
-- generando inconsistencia visual entre el ticket impreso ("MESERO: X")
-- y el tooltip ("Mozo: cajero").
--
-- Prioridad (igual que `fn_order_opener_name`):
--   1. `opened_by_employee_id` — PIN multimesero del opener
--   2. `opened_by` (auth user_id) → employee del mismo business
--   3. NULL — el caller (Flutter) seguirá con sus otros fallbacks
--
-- SECURITY DEFINER por la misma razón que las demás RPCs de este lote:
-- RLS sobre `employees` bloqueaba el SELECT directo desde Flutter para
-- cajeros sin permisos especiales.
-- =============================================================================

CREATE OR REPLACE FUNCTION public.fn_order_opener_employee_id(
  p_order_id uuid
)
RETURNS uuid
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path TO 'public'
AS $function$
DECLARE
  v_business_id uuid;
  v_opened_by_employee_id uuid;
  v_opened_by uuid;
  v_resolved uuid;
BEGIN
  SELECT ts.business_id, ts.opened_by_employee_id, ts.opened_by
    INTO v_business_id, v_opened_by_employee_id, v_opened_by
  FROM public.orders o
  JOIN public.table_sessions ts ON ts.id = o.session_id
  WHERE o.id = p_order_id;

  IF v_business_id IS NULL THEN
    RETURN NULL;
  END IF;

  IF auth.role() <> 'service_role' THEN
    IF NOT EXISTS (
      SELECT 1 FROM public.current_user_business_ids() c
      WHERE c.business_id = v_business_id
    ) THEN
      RAISE EXCEPTION 'access denied' USING ERRCODE = '42501';
    END IF;
  END IF;

  -- Prioridad 1: PIN multimesero del opener.
  IF v_opened_by_employee_id IS NOT NULL THEN
    RETURN v_opened_by_employee_id;
  END IF;

  -- Prioridad 2: auth user del opener → employee del mismo business.
  IF v_opened_by IS NOT NULL THEN
    SELECT id INTO v_resolved
    FROM public.employees
    WHERE user_id = v_opened_by
      AND business_id = v_business_id
    LIMIT 1;
    RETURN v_resolved;
  END IF;

  RETURN NULL;
END;
$function$;

REVOKE ALL ON FUNCTION public.fn_order_opener_employee_id(uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.fn_order_opener_employee_id(uuid) TO authenticated;

COMMENT ON FUNCTION public.fn_order_opener_employee_id(uuid) IS
  'Employee_id del mesero que abrió la mesa de la orden. Hermano de fn_order_opener_name. Usado por Flutter para poblar order_items.created_by_employee_id con el opener, garantizando que tooltip/comanda/precuenta/factura muestren todos al mismo responsable.';
