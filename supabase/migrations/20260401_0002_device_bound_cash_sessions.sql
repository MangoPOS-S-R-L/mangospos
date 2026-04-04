-- =============================================================================
-- Migration: Device-bound cash sessions with per-user isolation
-- =============================================================================
-- Goal:
--   - A cash session is tied to a device + the user who opened it.
--   - A device can only have ONE open cash session at a time.
--   - A user cannot open another cash session on a different device
--     if they already have one open.
--   - A user may still sell from another device if the app allows it,
--     but cannot open a second cash session.
--   - Only the owning user can close their cash session.
--
-- Notes:
--   - This supersedes the simpler per-user-per-register opening rule.
--   - Existing sessions are preserved.
--   - New openings must pass device_id.
-- =============================================================================

-- -----------------------------------------------------------------------------
-- 1) Remove old uniqueness rule and bind sessions to device metadata
-- -----------------------------------------------------------------------------
-- Old behavior allowed only one open session per cash_register_id.
-- Drop the legacy partial unique index/constraint if it still exists.
ALTER TABLE public.cash_register_sessions
  DROP CONSTRAINT IF EXISTS uq_cash_register_sessions_open_per_register;

DROP INDEX IF EXISTS public.uq_cash_register_sessions_open_per_register;

ALTER TABLE public.cash_register_sessions
  ADD COLUMN IF NOT EXISTS device_id text,
  ADD COLUMN IF NOT EXISTS device_name text;

COMMENT ON COLUMN public.cash_register_sessions.device_id IS
  'Unique device identifier from the client app / terminal used to open the cash session.';

COMMENT ON COLUMN public.cash_register_sessions.device_name IS
  'Optional human-readable device/terminal name used for audit and UI display.';

-- Optional helpful indexes for lookups (non-unique to avoid migration failure on dirty data)
CREATE INDEX IF NOT EXISTS idx_cash_register_sessions_open_device
  ON public.cash_register_sessions (device_id)
  WHERE status = 'open' AND closed_at IS NULL AND device_id IS NOT NULL;

CREATE INDEX IF NOT EXISTS idx_cash_register_sessions_open_user
  ON public.cash_register_sessions (user_id)
  WHERE status = 'open' AND closed_at IS NULL;

-- Enforce the new open-session rules at index level too.
CREATE UNIQUE INDEX IF NOT EXISTS uq_cash_register_sessions_open_per_device
  ON public.cash_register_sessions (device_id)
  WHERE status = 'open' AND closed_at IS NULL AND device_id IS NOT NULL;

CREATE UNIQUE INDEX IF NOT EXISTS uq_cash_register_sessions_open_per_user
  ON public.cash_register_sessions (user_id)
  WHERE status = 'open' AND closed_at IS NULL;

-- -----------------------------------------------------------------------------
-- 2) Opening rule: one open session per device and one open session per user
-- -----------------------------------------------------------------------------
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

    -- Rule A: the device itself can only have one open cash session
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

    -- Rule B: the user cannot open another cash session on another device
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

    RETURN jsonb_build_object(
        'success', true,
        'session_id', v_session_id
    );
END;
$$;

-- -----------------------------------------------------------------------------
-- 3) Closing rule: only owner can close their session (fail-closed)
-- -----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.fn_close_cash_session(
  p_session_id uuid,
  p_end_amount numeric,
  p_notes text DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
DECLARE
    v_session record;
    v_diff numeric;
    v_user_id uuid;
BEGIN
    v_user_id := auth.uid();

    IF v_user_id IS NULL THEN
        RETURN jsonb_build_object('error', 'Usuario no autenticado');
    END IF;

    SELECT *
      INTO v_session
      FROM public.cash_register_sessions
     WHERE id = p_session_id
     LIMIT 1;

    IF v_session IS NULL THEN
        RETURN jsonb_build_object('error', 'Sesion no encontrada');
    END IF;

    IF v_session.user_id IS DISTINCT FROM v_user_id THEN
        RETURN jsonb_build_object(
            'error', 'No puedes cerrar una caja que no te pertenece'
        );
    END IF;

    IF v_session.status IS DISTINCT FROM 'open' OR v_session.closed_at IS NOT NULL THEN
        RETURN jsonb_build_object(
            'error', 'La caja ya esta cerrada o no esta disponible'
        );
    END IF;

    v_diff := COALESCE(p_end_amount, 0) - COALESCE(v_session.start_amount, 0);

    UPDATE public.cash_register_sessions
       SET end_amount = p_end_amount,
           difference = v_diff,
           notes = p_notes,
           status = 'closed',
           closed_at = now()
     WHERE id = p_session_id;

    RETURN jsonb_build_object(
        'success', true,
        'session_id', p_session_id,
        'difference', v_diff
    );
END;
$$;
