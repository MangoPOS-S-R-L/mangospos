-- =============================================================================
-- Owner: relajar Rule B (per-user) para permitir cajas simultaneas en
-- multiples sucursales del mismo owner.
--
-- Contexto: fn_open_cash_session (20260401_0002) tiene 2 reglas:
--   - Rule A (per-device): 1 caja abierta por device. Sigue aplicando.
--   - Rule B (per-user)  : 1 caja abierta por user en cualquier device.
--                          Bloqueaba al owner que tiene varias sucursales y
--                          quiere caja en cada una desde devices distintos.
--
-- Cambio: si el caller es 'owner' del business al que pertenece el
-- cash_register destino, Rule B se omite. Cualquier otro rol (admin,
-- cashier, waiter) sigue limitado a 1 caja por user.
--
-- Rule A intacta: un mismo device fisico nunca puede tener 2 cajas a la vez.
-- Tampoco es semanticamente correcto a nivel operativo.
--
-- Compat: signatura sin cambios. Mensajes de error sin cambios para casos
-- que ya bloqueaban. Solo desbloqueamos un path adicional para owners.
-- =============================================================================

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

    -- ---------------------------------------------------------------------
    -- Rule A: per-device.
    -- Sigue aplicando para todos los roles, incluido owner. Un device
    -- fisico no puede tener 2 cajas abiertas a la vez.
    -- ---------------------------------------------------------------------
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

    -- ---------------------------------------------------------------------
    -- Detectar si el caller es owner del business del register destino.
    -- user_business_role retorna 'owner' si user_businesses.role='owner'
    -- o si businesses.owner_id = user_id. Cualquier otro role no califica.
    -- ---------------------------------------------------------------------
    SELECT cr.business_id
      INTO v_register_business_id
      FROM public.cash_registers cr
     WHERE cr.id = p_cash_register_id
     LIMIT 1;

    IF v_register_business_id IS NOT NULL THEN
        v_is_owner_of_target :=
          public.user_business_role(p_user_id, v_register_business_id) = 'owner';
    END IF;

    -- ---------------------------------------------------------------------
    -- Rule B: per-user.
    -- Salteable solo para owners (multiples sucursales). Para todos los
    -- demas (admin, cashier, waiter) sigue bloqueando.
    -- ---------------------------------------------------------------------
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

    -- ---------------------------------------------------------------------
    -- Insercion (sin cambios respecto a 20260401_0002).
    -- ---------------------------------------------------------------------
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

    INSERT INTO public.cash_transactions (
        session_id,
        amount,
        type,
        description
    )
    VALUES (
        v_session_id,
        p_start_amount,
        'deposit',
        'Apertura de caja'
    );

    RETURN jsonb_build_object('success', true, 'session_id', v_session_id);
END;
$$;
