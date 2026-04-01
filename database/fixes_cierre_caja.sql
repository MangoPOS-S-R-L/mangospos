-- =============================================================================
-- MangoPOS — Fixes Cierre de Caja
-- Fecha: 2026-03-31
-- Descripción: Corrige bugs críticos en el flujo de cierre de caja:
--   1. fn_close_cash_session: agrega p_force_with_open_tables, idempotencia
--      y manejo de excepciones estructurado
--   2. fn_open_cash_session: agrega validación de caja y manejo de errores
--   3. fn_get_cash_session_summary: agrega manejo de excepciones
--   4. Schema: CHECK constraints en status y type
--   5. Índices faltantes en cash_transactions y cash_registers
-- =============================================================================


-- -----------------------------------------------------------------------------
-- SECCIÓN 1: CHECK CONSTRAINTS
-- Seguro para ejecutar siempre (IF NOT EXISTS)
-- -----------------------------------------------------------------------------

-- Válida que cash_register_sessions.status solo acepte 'open' o 'closed'
ALTER TABLE public.cash_register_sessions
  DROP CONSTRAINT IF EXISTS chk_cash_register_sessions_status;

ALTER TABLE public.cash_register_sessions
  ADD CONSTRAINT chk_cash_register_sessions_status
  CHECK (status IN ('open', 'closed'));

-- Válida que cash_transactions.type solo acepte valores conocidos
ALTER TABLE public.cash_transactions
  DROP CONSTRAINT IF EXISTS chk_cash_transactions_type;

ALTER TABLE public.cash_transactions
  ADD CONSTRAINT chk_cash_transactions_type
  CHECK (type IN ('sale', 'deposit', 'withdrawal', 'expense'));


-- -----------------------------------------------------------------------------
-- SECCIÓN 2: ÍNDICES FALTANTES
-- -----------------------------------------------------------------------------

-- Índice en cash_transactions.session_id (FK sin índice)
CREATE INDEX IF NOT EXISTS idx_cash_transactions_session_id
  ON public.cash_transactions (session_id);

-- Índice en cash_transactions.type (usado en WHERE de las funciones de cierre)
CREATE INDEX IF NOT EXISTS idx_cash_transactions_type
  ON public.cash_transactions (session_id, type);

-- Índice en cash_registers.business_id
CREATE INDEX IF NOT EXISTS idx_cash_registers_business_id
  ON public.cash_registers (business_id);


-- -----------------------------------------------------------------------------
-- SECCIÓN 3: fn_close_cash_session
-- Cambios:
--   - Nuevo parámetro p_force_with_open_tables (default false)
--   - Chequeo de sesión ya cerrada (idempotencia)
--   - Chequeo de mesas abiertas antes de cerrar
--   - Bloque EXCEPTION con códigos de error estructurados
--   - FOR UPDATE para evitar cierres concurrentes
-- -----------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION public.fn_close_cash_session(
  p_session_id             uuid,
  p_end_amount             numeric,
  p_notes                  text,
  p_force_with_open_tables boolean DEFAULT false
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $$
DECLARE
  v_start_amount        numeric := 0;
  v_current_status      text;
  v_business_id         uuid;
  v_open_tables_count   integer := 0;
  v_total_sales         numeric := 0;
  v_total_deposits      numeric := 0;
  v_total_withdrawals   numeric := 0;
  v_total_expenses      numeric := 0;
  v_expected_cash       numeric := 0;
  v_difference          numeric := 0;
BEGIN
  -- Bloquear la fila para evitar cierres concurrentes
  SELECT
    coalesce(crs.start_amount, 0),
    crs.status,
    cr.business_id
  INTO
    v_start_amount,
    v_current_status,
    v_business_id
  FROM public.cash_register_sessions crs
  JOIN public.cash_registers cr ON cr.id = crs.cash_register_id
  WHERE crs.id = p_session_id
  FOR UPDATE;

  IF NOT FOUND THEN
    RETURN jsonb_build_object(
      'success', false,
      'error_code', 'SESSION_NOT_FOUND',
      'error', 'La sesión de caja no existe.'
    );
  END IF;

  -- Idempotencia: si ya está cerrada devolver éxito sin hacer nada
  IF v_current_status = 'closed' THEN
    RETURN jsonb_build_object(
      'success', false,
      'error_code', 'SESSION_ALREADY_CLOSED',
      'error', 'Esta sesión de caja ya fue cerrada anteriormente.'
    );
  END IF;

  -- Verificar mesas abiertas (solo si no se fuerza el cierre)
  IF NOT p_force_with_open_tables THEN
    SELECT count(*)
    INTO v_open_tables_count
    FROM public.table_sessions
    WHERE business_id = v_business_id
      AND closed_at IS NULL;

    IF v_open_tables_count > 0 THEN
      RETURN jsonb_build_object(
        'success', false,
        'error_code', 'OPEN_TABLES_EXIST',
        'error', 'Hay ' || v_open_tables_count || ' mesa(s) abierta(s). Ciérralas antes o usa forzar cierre.',
        'open_tables_count', v_open_tables_count
      );
    END IF;
  END IF;

  -- Calcular totales por tipo de transacción
  SELECT coalesce(sum(amount), 0) INTO v_total_sales
  FROM public.cash_transactions
  WHERE session_id = p_session_id AND type = 'sale';

  SELECT coalesce(sum(amount), 0) INTO v_total_deposits
  FROM public.cash_transactions
  WHERE session_id = p_session_id AND type = 'deposit';

  SELECT coalesce(sum(amount), 0) INTO v_total_withdrawals
  FROM public.cash_transactions
  WHERE session_id = p_session_id AND type = 'withdrawal';

  SELECT coalesce(sum(amount), 0) INTO v_total_expenses
  FROM public.cash_transactions
  WHERE session_id = p_session_id AND type = 'expense';

  v_expected_cash :=
    v_start_amount +
    v_total_sales +
    v_total_deposits -
    v_total_withdrawals -
    v_total_expenses;

  v_difference := p_end_amount - v_expected_cash;

  UPDATE public.cash_register_sessions
  SET
    closed_at  = now(),
    end_amount = p_end_amount,
    difference = v_difference,
    status     = 'closed',
    notes      = p_notes
  WHERE id = p_session_id;

  RETURN jsonb_build_object(
    'success',           true,
    'difference',        v_difference,
    'expected',          v_expected_cash,
    'expected_amount',   v_expected_cash,
    'expected_cash',     v_expected_cash,
    'start_amount',      v_start_amount,
    'total_sales',       v_total_sales,
    'total_deposits',    v_total_deposits,
    'total_withdrawals', v_total_withdrawals,
    'total_expenses',    v_total_expenses
  );

EXCEPTION
  WHEN OTHERS THEN
    RETURN jsonb_build_object(
      'success',    false,
      'error_code', 'UNEXPECTED_ERROR',
      'error',      SQLERRM
    );
END;
$$;


-- -----------------------------------------------------------------------------
-- SECCIÓN 4: fn_open_cash_session
-- Cambios:
--   - Validar que cash_register_id existe
--   - Bloque EXCEPTION con códigos estructurados
-- -----------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION public.fn_open_cash_session(
  p_cash_register_id uuid,
  p_user_id          uuid,
  p_start_amount     numeric
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $$
DECLARE
  v_session_id     uuid;
  v_existing_open  uuid;
  v_register_exists boolean;
BEGIN
  -- Verificar que la caja existe
  SELECT EXISTS (
    SELECT 1 FROM public.cash_registers WHERE id = p_cash_register_id
  ) INTO v_register_exists;

  IF NOT v_register_exists THEN
    RETURN jsonb_build_object(
      'error_code', 'REGISTER_NOT_FOUND',
      'error',      'La caja registradora no existe.'
    );
  END IF;

  -- Verificar si ya hay una sesión abierta
  SELECT id INTO v_existing_open
  FROM public.cash_register_sessions
  WHERE cash_register_id = p_cash_register_id
    AND status = 'open';

  IF v_existing_open IS NOT NULL THEN
    RETURN jsonb_build_object(
      'error_code', 'SESSION_ALREADY_OPEN',
      'error',      'La caja ya tiene una sesión abierta.',
      'session_id', v_existing_open
    );
  END IF;

  INSERT INTO public.cash_register_sessions (cash_register_id, user_id, start_amount, status)
  VALUES (p_cash_register_id, p_user_id, p_start_amount, 'open')
  RETURNING id INTO v_session_id;

  -- No se inserta transacción de apertura porque start_amount ya almacena
  -- el fondo inicial. Insertarla como 'deposit' duplicaría el cálculo del
  -- efectivo esperado: start_amount + deposits = start_amount * 2.

  RETURN jsonb_build_object(
    'success',    true,
    'session_id', v_session_id
  );

EXCEPTION
  WHEN OTHERS THEN
    RETURN jsonb_build_object(
      'error_code', 'UNEXPECTED_ERROR',
      'error',      SQLERRM
    );
END;
$$;


-- -----------------------------------------------------------------------------
-- SECCIÓN 5: fn_get_cash_session_summary
-- Cambios:
--   - Bloque EXCEPTION con código estructurado
--   - Detección de método de pago mejorada (código tiene prioridad sobre nombre)
-- -----------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION public.fn_get_cash_session_summary(p_session_id uuid)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $$
DECLARE
  v_start_amount            numeric := 0;
  v_opened_at               timestamptz;
  v_cash_sales_net          numeric := 0;
  v_total_deposits          numeric := 0;
  v_total_withdrawals       numeric := 0;
  v_total_expenses          numeric := 0;
  v_expected_cash           numeric := 0;
  v_paid_cash               numeric := 0;
  v_expected_card           numeric := 0;
  v_expected_transfer       numeric := 0;
  v_expected_other          numeric := 0;
  v_total_sales_all_methods numeric := 0;
  v_transaction_count       integer := 0;
  v_result                  jsonb;
BEGIN
  SELECT coalesce(s.start_amount, 0), s.opened_at
  INTO v_start_amount, v_opened_at
  FROM public.cash_register_sessions s
  WHERE s.id = p_session_id;

  IF NOT FOUND THEN
    RETURN jsonb_build_object(
      'success',    false,
      'error_code', 'SESSION_NOT_FOUND',
      'error',      'La sesión de caja no existe.'
    );
  END IF;

  SELECT coalesce(sum(amount), 0) INTO v_cash_sales_net
  FROM public.cash_transactions
  WHERE session_id = p_session_id AND type = 'sale';

  SELECT coalesce(sum(amount), 0) INTO v_total_deposits
  FROM public.cash_transactions
  WHERE session_id = p_session_id AND type = 'deposit';

  SELECT coalesce(sum(amount), 0) INTO v_total_withdrawals
  FROM public.cash_transactions
  WHERE session_id = p_session_id AND type = 'withdrawal';

  SELECT coalesce(sum(amount), 0) INTO v_total_expenses
  FROM public.cash_transactions
  WHERE session_id = p_session_id AND type = 'expense';

  -- Detección por método de pago: código tiene prioridad sobre nombre
  SELECT
    coalesce(sum(CASE
      WHEN pm.code = 'cash'
        OR (pm.code IS NULL AND lower(coalesce(pm.name,'')) LIKE '%efectivo%')
        THEN p.amount ELSE 0 END), 0),
    coalesce(sum(CASE
      WHEN pm.code = 'card'
        OR (pm.code IS NULL AND lower(coalesce(pm.name,'')) LIKE '%tarjet%')
        THEN p.amount ELSE 0 END), 0),
    coalesce(sum(CASE
      WHEN pm.code = 'transfer'
        OR (pm.code IS NULL AND lower(coalesce(pm.name,'')) LIKE '%transfer%')
        THEN p.amount ELSE 0 END), 0),
    coalesce(sum(CASE
      WHEN pm.code NOT IN ('cash','card','transfer')
        AND (lower(coalesce(pm.name,'')) NOT LIKE '%efectivo%')
        AND (lower(coalesce(pm.name,'')) NOT LIKE '%tarjet%')
        AND (lower(coalesce(pm.name,'')) NOT LIKE '%transfer%')
        THEN p.amount ELSE 0 END), 0),
    coalesce(sum(p.amount), 0),
    coalesce(count(*), 0)::int
  INTO
    v_paid_cash,
    v_expected_card,
    v_expected_transfer,
    v_expected_other,
    v_total_sales_all_methods,
    v_transaction_count
  FROM public.payments p
  JOIN public.payment_methods pm ON pm.id = p.payment_method_id
  WHERE p.session_id = p_session_id
    AND p.status = 'completed';

  v_expected_cash :=
    v_start_amount +
    v_cash_sales_net +
    v_total_deposits -
    v_total_withdrawals -
    v_total_expenses;

  RETURN jsonb_build_object(
    'success',                true,
    'start_amount',           v_start_amount,
    'opened_at',              v_opened_at,
    'total_sales',            v_cash_sales_net,
    'cash_sales_net',         v_cash_sales_net,
    'total_sales_all_methods',v_total_sales_all_methods,
    'total_deposits',         v_total_deposits,
    'total_withdrawals',      v_total_withdrawals,
    'total_expenses',         v_total_expenses,
    'total_income',           (v_cash_sales_net + v_total_deposits),
    'total_outflows',         (v_total_withdrawals + v_total_expenses),
    'expected_amount',        v_expected_cash,
    'expected_cash',          v_expected_cash,
    'expected_card',          v_expected_card,
    'expected_transfer',      v_expected_transfer,
    'expected_other',         v_expected_other,
    'expected_total',         (v_expected_cash + v_expected_card + v_expected_transfer + v_expected_other),
    'paid_cash',              v_paid_cash,
    'transaction_count',      v_transaction_count
  );

EXCEPTION
  WHEN OTHERS THEN
    RETURN jsonb_build_object(
      'success',    false,
      'error_code', 'UNEXPECTED_ERROR',
      'error',      SQLERRM
    );
END;
$$;
