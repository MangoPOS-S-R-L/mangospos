-- Incluye la lógica para cerrar checks individuales y la orden completa.

DROP FUNCTION IF EXISTS public.fn_process_payment_v2(uuid,uuid,text,numeric,text,uuid,text,uuid);

CREATE OR REPLACE FUNCTION public.fn_process_payment_v2(
  p_order_id uuid,
  p_check_id uuid,
  p_payment_method_id text,
  p_amount numeric,
  p_reference text,
  p_customer_id uuid,
  p_customer_rnc text,
  p_cashier_session_id uuid
)
RETURNS json
LANGUAGE plpgsql
SET statement_timeout = '60s' -- Timeout extendido para evitar cancelaciones
AS $function$
DECLARE
  v_payment_id uuid;
  v_business_id uuid;
  v_final_method_id uuid;
  v_payment_record json;
  v_open_items_count integer;
  v_is_uuid boolean;
BEGIN
  -- 1. Obtener business_id de la orden (via session)
  SELECT t.business_id INTO v_business_id
  FROM public.orders o
  JOIN public.table_sessions t ON o.session_id = t.id
  WHERE o.id = p_order_id;

  -- Fallback si no hay session (ej. venta rapida directa sin layout?)
  IF v_business_id IS NULL THEN
    -- Intentar buscar en user metadata o similar? 
    -- Por simplicidad, asumimos que orders SIEMPRE tiene session valida en este sistema.
    -- O buscamos en payment_methods si el ID paso directo?
    NULL; 
  END IF;

  -- 2. Resolver Payment Method ID
  -- Verificamos si es UUID
  v_is_uuid := (p_payment_method_id ~ '^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$');
  
  IF v_is_uuid THEN
    v_final_method_id := p_payment_method_id::uuid;
  ELSE
    -- Buscar por code (ej 'cash', 'card')
    SELECT id INTO v_final_method_id
    FROM public.payment_methods
    WHERE business_id = v_business_id 
      AND code = p_payment_method_id
      AND is_active = true
    LIMIT 1;
    
    IF v_final_method_id IS NULL THEN
        RAISE EXCEPTION 'Método de pago no válido: %', p_payment_method_id;
    END IF;
  END IF;

  -- 3. Insertar Pago
  INSERT INTO public.payments (
    business_id,
    order_id,
    check_id,
    payment_method_id,
    amount,
    reference,
    customer_id,
    customer_rnc,
    processed_by,
    session_id, -- cashier session
    status,
    created_at
  ) VALUES (
    v_business_id,
    p_order_id,
    p_check_id,
    v_final_method_id,
    p_amount,
    p_reference,
    p_customer_id,
    p_customer_rnc,
    auth.uid(),
    p_cashier_session_id,
    'completed',
    NOW()
  )
  RETURNING id INTO v_payment_id;

  -- 4. Retornar el registro insertado (como JSON)
  SELECT row_to_json(p.*) INTO v_payment_record
  FROM public.payments p
  WHERE p.id = v_payment_id;

  -- 5. Actualizar Estado de Items / Checks
  IF p_check_id IS NOT NULL THEN
    -- Caso 1: Pago de una cuenta separada (Check)
    
    -- Marcar items del check como pagados (ignorando voids)
    UPDATE public.order_items
    SET status = 'paid'
    WHERE check_id = p_check_id 
      AND status != 'void'
      AND status != 'paid'; -- Evitar re-update innecesario

    -- Marcar check como cerrado
    UPDATE public.order_checks
    SET is_closed = true,
        closed_at = NOW()
    WHERE id = p_check_id;
    
  ELSE
    -- Caso 2: Pago de la orden completa (o sin especificar check)
    -- Asumimos que si no hay check_id, estamos pagando/cerrando lo que quede.
    
    UPDATE public.order_items
    SET status = 'paid'
    WHERE order_id = p_order_id
      AND status != 'void'
      AND status != 'paid';
      
  END IF;

  -- 6. Recalcular y Verificar Cierre de Orden
  -- (Opcional: triggers en order_items deberían recalcular subtotales de orden)
  
  -- Verificar si quedan items abiertos en TODA la orden
  SELECT count(*) INTO v_open_items_count
  FROM public.order_items
  WHERE order_id = p_order_id
    AND status NOT IN ('paid', 'void');

  IF v_open_items_count = 0 THEN
    -- Cerrar orden y mesa
    -- Usamos la función existente para consistencia
    PERFORM public.fn_close_order_and_table(p_order_id, 'paid');
  END IF;

  RETURN v_payment_record;
END;
$function$;
