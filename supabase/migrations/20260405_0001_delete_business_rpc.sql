-- RPC para eliminar una sucursal y todos sus datos relacionados
-- Sólo el propietario legal (owner_id) puede realizar esta acción

CREATE OR REPLACE FUNCTION public.fn_delete_business(p_business_id uuid)
RETURNS json
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
DECLARE
    v_owner_id uuid;
    v_active_sessions int;
BEGIN
    -- 1. Obtener el propietario de la sucursal
    SELECT owner_id INTO v_owner_id 
    FROM public.businesses 
    WHERE id = p_business_id;

    -- 2. Validar que la sucursal existe
    IF v_owner_id IS NULL THEN
        RETURN json_build_object(
            'success', false, 
            'error', 'La sucursal no existe.'
        );
    END IF;

    -- 3. Validar que el usuario que llama es el propietario
    IF v_owner_id <> auth.uid() THEN
        -- Permitir si es un service_role pero restringir para usuarios normales
        IF current_setting('role') <> 'service_role' THEN
            RETURN json_build_object(
                'success', false, 
                'error', 'Sólo el propietario puede eliminar la sucursal.'
            );
        END IF;
    END IF;

    -- 4. Validar que no haya sesiones de caja abiertas
    SELECT count(*) INTO v_active_sessions
    FROM public.cash_register_sessions crs
    JOIN public.cash_registers cr ON cr.id = crs.cash_register_id
    WHERE cr.business_id = p_business_id
      AND crs.status = 'open';

    IF v_active_sessions > 0 THEN
        RETURN json_build_object(
            'success', false, 
            'error', 'No se puede eliminar la sucursal porque tiene sesiones de caja abiertas.'
        );
    END IF;

    -- 5. Eliminar la sucursal
    -- Las claves foráneas con ON DELETE CASCADE se encargarán del resto de las tablas
    -- (orders, products, users, inventory, etc.)
    DELETE FROM public.businesses WHERE id = p_business_id;

    RETURN json_build_object('success', true);

EXCEPTION WHEN OTHERS THEN
    RETURN json_build_object(
        'success', false, 
        'error', 'Error inesperado: ' || SQLERRM
    );
END;
$$;
