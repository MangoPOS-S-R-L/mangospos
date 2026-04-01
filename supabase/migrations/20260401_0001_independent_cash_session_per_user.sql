-- =============================================================================
-- Migration: Allow independent cash sessions per cashier (user) on same register
-- =============================================================================
-- BEFORE: Only ONE open session per cash_register_id (blocks all other users)
-- AFTER:  ONE open session per cash_register_id + user_id (each cashier independent)
--
-- Impact:
--   - fn_open_cash_session: relaxed constraint to per-user-per-register
--   - fn_close_cash_session: unchanged (operates on session_id)
--   - fn_get_cash_session_summary: unchanged (operates on session_id)
--   - fn_process_payment_v3: unchanged (operates on session_id)
--   - payments/cash_transactions: unchanged (linked to session_id)
--   - Reports: unchanged (aggregate by business_id across all sessions)
-- =============================================================================

CREATE OR REPLACE FUNCTION public.fn_open_cash_session(
  p_cash_register_id uuid,
  p_user_id uuid,
  p_start_amount numeric
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
DECLARE
    v_session_id UUID;
    v_existing_open UUID;
BEGIN
    -- Check if THIS USER already has an open session on THIS register
    -- (other users may have their own independent sessions)
    SELECT id INTO v_existing_open
    FROM cash_register_sessions
    WHERE cash_register_id = p_cash_register_id
      AND user_id = p_user_id
      AND status = 'open';

    IF v_existing_open IS NOT NULL THEN
        RETURN jsonb_build_object(
            'error', 'Ya tienes una caja abierta',
            'session_id', v_existing_open
        );
    END IF;

    INSERT INTO cash_register_sessions (cash_register_id, user_id, start_amount, status)
    VALUES (p_cash_register_id, p_user_id, p_start_amount, 'open')
    RETURNING id INTO v_session_id;

    INSERT INTO cash_transactions (session_id, amount, type, description)
    VALUES (v_session_id, p_start_amount, 'deposit', 'Apertura de caja');

    RETURN jsonb_build_object('success', true, 'session_id', v_session_id);
END;
$$;
