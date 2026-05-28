-- =============================================================================
-- ROLLBACK — 20260528_0004 — fn_open_cash_session hardening
-- =============================================================================
--
-- Restaura la versión PREVIA del RPC (la de la migración 20260513_0014).
-- Aplicar este rollback REABRE el agujero de seguridad — solo úsalo si
-- el fix introduce regresiones operativas que bloquean cobros y necesitas
-- recuperar el servicio mientras debuggeas.
--
-- IMPORTANTE: con este rollback activo, cualquier cliente autenticado
-- puede asignar sesiones de caja a cualquier user_id. No es un estado
-- seguro para producción a largo plazo.
-- =============================================================================

begin;

CREATE OR REPLACE FUNCTION public.fn_open_cash_session(
  p_cash_register_id uuid,
  p_user_id uuid,
  p_start_amount numeric,
  p_device_id text,
  p_device_name text DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
DECLARE
    v_session_id uuid;
    v_existing_device_session uuid;
    v_existing_user_session uuid;
    v_existing_user_device_id text;
    v_register_business_id uuid;
    v_is_owner_of_target boolean := false;
BEGIN
    IF p_cash_register_id IS NULL THEN
        RETURN jsonb_build_object('error', 'cash_register_id es requerido');
    END IF;

    IF p_user_id IS NULL THEN
        RETURN jsonb_build_object('error', 'user_id es requerido');
    END IF;

    IF p_device_id IS NULL OR btrim(p_device_id) = '' THEN
        RETURN jsonb_build_object('error', 'device_id es requerido');
    END IF;

    SELECT id
      INTO v_existing_device_session
      FROM public.cash_register_sessions
     WHERE device_id = btrim(p_device_id)
       AND status = 'open'
       AND closed_at IS NULL
     LIMIT 1;

    IF v_existing_device_session IS NOT NULL THEN
        RETURN jsonb_build_object(
            'error', 'Este dispositivo ya tiene una caja abierta',
            'session_id', v_existing_device_session
        );
    END IF;

    SELECT cr.business_id
      INTO v_register_business_id
      FROM public.cash_registers cr
     WHERE cr.id = p_cash_register_id
     LIMIT 1;

    IF v_register_business_id IS NOT NULL THEN
        v_is_owner_of_target :=
          public.user_business_role(p_user_id, v_register_business_id) = 'owner';
    END IF;

    IF NOT v_is_owner_of_target THEN
        SELECT id, device_id
          INTO v_existing_user_session, v_existing_user_device_id
          FROM public.cash_register_sessions
         WHERE user_id = p_user_id
           AND status = 'open'
           AND closed_at IS NULL
         LIMIT 1;

        IF v_existing_user_session IS NOT NULL THEN
            RETURN jsonb_build_object(
                'error', 'Ya tienes una caja abierta en otro dispositivo',
                'session_id', v_existing_user_session,
                'device_id', v_existing_user_device_id
            );
        END IF;
    END IF;

    INSERT INTO public.cash_register_sessions (
        cash_register_id,
        user_id,
        start_amount,
        status,
        device_id,
        device_name
    )
    VALUES (
        p_cash_register_id,
        p_user_id,
        p_start_amount,
        'open',
        btrim(p_device_id),
        NULLIF(btrim(p_device_name), '')
    )
    RETURNING id INTO v_session_id;

    RETURN jsonb_build_object('success', true, 'session_id', v_session_id);
END;
$$;

commit;
