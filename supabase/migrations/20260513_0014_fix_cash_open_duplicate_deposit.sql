-- =============================================================================
-- Fix crítico: fn_open_cash_session duplicaba el monto de apertura
-- (2026-05-13).
--
-- BUG:
--   fn_open_cash_session (migración 20260509_0002) hacía DOS cosas con
--   el monto de apertura `p_start_amount`:
--     1. INSERT a `cash_register_sessions(start_amount = p_start_amount)`.
--     2. INSERT a `cash_transactions(type='deposit', amount=p_start_amount,
--        description='Apertura de caja')`.
--
--   El cálculo de cierre (fn_close_cash_session) hace:
--     expected_cash = start_amount + sales + deposits - withdrawals - expenses
--
--   Como la apertura aparece en `start_amount` Y en `deposits`, se suma
--   dos veces. Resultado: si abrís con 13,305 y no hay ventas, el
--   sistema esperaba 26,610 en caja al cerrar (el doble).
--
-- IMPACTO ACTUAL:
--   Sesiones afectadas son las abiertas DESPUÉS del deploy de
--   20260509_0002. Sesiones cerradas con el bug ya tienen `difference`
--   incorrecto y rompen reportes — pero NO las tocamos: forzar
--   recálculo retroactivo cambiaría arqueos firmados.
--
-- FIX:
--   1. Reescribir fn_open_cash_session sin el INSERT a cash_transactions.
--      La apertura vive SOLO en cash_register_sessions.start_amount,
--      que es donde el cierre la lee de raíz.
--   2. Cleanup defensivo: borrar las transacciones 'Apertura de caja'
--      que estén en sesiones AÚN ABIERTAS, para que cuando se cierren
--      el cálculo dé el número correcto.
--
-- BACKWARDS-COMPATIBLE:
--   - Signatura de la función no cambia.
--   - Sesiones cerradas no se tocan (lo que ya cerró, cerrado queda).
--   - Sesiones abiertas con el bug se "limpian" eliminando la
--     transacción duplicada. El monto inicial sigue vivo en
--     start_amount intacto.
-- =============================================================================

begin;

-- ---------------------------------------------------------------------------
-- 1. Re-crear fn_open_cash_session sin el INSERT duplicado.
-- ---------------------------------------------------------------------------

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

    -- Rule A: per-device. Un device físico no puede tener 2 cajas
    -- abiertas al mismo tiempo.
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

    -- Detectar si el caller es owner del business del register destino.
    SELECT cr.business_id
      INTO v_register_business_id
      FROM public.cash_registers cr
     WHERE cr.id = p_cash_register_id
     LIMIT 1;

    IF v_register_business_id IS NOT NULL THEN
        v_is_owner_of_target :=
          public.user_business_role(p_user_id, v_register_business_id) = 'owner';
    END IF;

    -- Rule B: per-user. Solo owners pueden saltarse esta regla.
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

    -- Inserción de la sesión. El `start_amount` queda como la fuente
    -- ÚNICA de verdad para el monto inicial. fn_close_cash_session lo
    -- suma de ahí — NO se crea una transacción 'deposit' adicional para
    -- evitar la duplicación que tenía el deploy del 2026-05-09.
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

comment on function public.fn_open_cash_session(uuid, uuid, numeric, text, text) is
  'Abre una sesión de caja. El monto inicial vive solo en '
  'cash_register_sessions.start_amount — NO se duplica en '
  'cash_transactions. Fix 2026-05-13: la versión anterior creaba un '
  'cash_transactions tipo deposit por p_start_amount, lo que hacía que '
  'fn_close_cash_session lo contara dos veces.';

-- ---------------------------------------------------------------------------
-- 2. Cleanup: borrar las transacciones 'Apertura de caja' duplicadas en
--    sesiones AÚN ABIERTAS.
--
--    Criterios estrictos para no borrar nada legítimo:
--      - type = 'deposit'
--      - description = 'Apertura de caja' (exacto, lo que ponía la RPC)
--      - amount = sesión.start_amount (cuadra con la apertura)
--      - sesión en status='open' (no tocamos lo cerrado)
-- ---------------------------------------------------------------------------

do $$
declare
  v_count integer;
begin
  with deleted as (
    delete from public.cash_transactions ct
    using public.cash_register_sessions s
    where ct.session_id = s.id
      and s.status = 'open'
      and ct.type = 'deposit'
      and ct.description = 'Apertura de caja'
      and ct.amount = s.start_amount
    returning ct.id
  )
  select count(*) into v_count from deleted;

  raise notice 'Cleanup: % transacción(es) duplicadas de apertura eliminadas en sesiones abiertas.', v_count;
end$$;

commit;
