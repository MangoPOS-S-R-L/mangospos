-- ============================================================
-- FUNCIÓN DE PAGO - VERSIÓN SIMPLIFICADA Y ROBUSTA
-- ============================================================
-- Esta versión obtiene el business_id de forma más directa y robusta

CREATE OR REPLACE FUNCTION public.fn_process_payment_v2(
    p_order_id uuid,
    p_check_id uuid,
    p_payment_method_id text,
    p_amount numeric,
    p_reference text,
    p_customer_id uuid,
    p_customer_rnc text,
    p_cashier_session_id uuid DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
AS $function$
DECLARE
    v_payment_id uuid;
    v_business_id uuid;
    v_order_session_id uuid;
    v_table_id uuid;
    v_zone_id uuid;
    v_payment_record jsonb;
    v_pm_uuid uuid;
    v_pm_name text;
BEGIN
    -- PASO 1: Obtener session_id de la orden
    SELECT session_id INTO v_order_session_id
    FROM public.orders
    WHERE id = p_order_id;
    
    IF v_order_session_id IS NULL THEN
        RAISE EXCEPTION 'Orden % no encontrada', p_order_id;
    END IF;

    -- PASO 2: Obtener table_id desde la sesión
    SELECT table_id INTO v_table_id
    FROM public.table_sessions
    WHERE id = v_order_session_id;

    -- PASO 3: Obtener zone_id desde la mesa (si existe)
    IF v_table_id IS NOT NULL THEN
        SELECT zone_id INTO v_zone_id
        FROM public.dining_tables
        WHERE id = v_table_id;
    END IF;

    -- PASO 4: Obtener business_id desde la zona
    IF v_zone_id IS NOT NULL THEN
        SELECT business_id INTO v_business_id
        FROM public.zones
        WHERE id = v_zone_id;
    END IF;

    -- PASO 5: Si no obtuvimos business_id, intentar desde cash session
    IF v_business_id IS NULL AND p_cashier_session_id IS NOT NULL THEN
        SELECT business_id INTO v_business_id
        FROM public.cash_register_sessions
        WHERE id = p_cashier_session_id;
    END IF;

    -- PASO 6: Verificación final
    IF v_business_id IS NULL THEN
        RAISE EXCEPTION 'No se pudo determinar el ID del negocio para la orden %', p_order_id;
    END IF;

    -- Validar sesión de caja
    IF p_cashier_session_id IS NULL THEN
        RAISE EXCEPTION 'Se requiere una sesión de caja activa para procesar el pago';
    END IF;

    -- RESOLVER PAYMENT METHOD (convertir código texto a UUID)
    IF p_payment_method_id ~ '^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$' THEN
        -- Ya es un UUID válido
        v_pm_uuid := p_payment_method_id::uuid;
    ELSE
        -- Buscar por código
        SELECT id INTO v_pm_uuid
        FROM public.payment_methods
        WHERE business_id = v_business_id 
          AND code = p_payment_method_id
        LIMIT 1;

        -- Si no existe, crear automáticamente
        IF v_pm_uuid IS NULL THEN
            v_pm_name := CASE p_payment_method_id
                WHEN 'cash' THEN 'Efectivo'
                WHEN 'card' THEN 'Tarjeta'
                WHEN 'transfer' THEN 'Transferencia'
                ELSE p_payment_method_id
            END;

            INSERT INTO public.payment_methods (
                business_id, 
                name, 
                code, 
                is_active,
                position
            ) VALUES (
                v_business_id, 
                v_pm_name, 
                p_payment_method_id, 
                true,
                1
            ) RETURNING id INTO v_pm_uuid;
        END IF;
    END IF;

    -- INSERTAR EL PAGO
    INSERT INTO public.payments (
        order_id,
        check_id,
        business_id,
        session_id,
        payment_method_id,
        amount,
        reference,
        status,
        change_amount,
        created_at
    ) VALUES (
        p_order_id,
        p_check_id,
        v_business_id,
        p_cashier_session_id,
        v_pm_uuid,
        p_amount,
        p_reference,
        'completed',
        0,
        now()
    ) RETURNING id INTO v_payment_id;

    -- DEVOLVER EL REGISTRO
    SELECT to_jsonb(payment_row) INTO v_payment_record
    FROM (
        SELECT * FROM public.payments WHERE id = v_payment_id
    ) AS payment_row;

    RETURN v_payment_record;
END;
$function$;
