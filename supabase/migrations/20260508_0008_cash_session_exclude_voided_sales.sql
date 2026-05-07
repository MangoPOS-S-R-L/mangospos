-- =============================================================================
-- Migration: excluir ventas anuladas en RPCs de cierre de caja
-- Purpose : fn_close_cash_session y fn_get_cash_session_summary sumaban
--           cash_transactions (type='sale') sin verificar el estado del
--           pago asociado. Cuando se anula una orden, payments.status
--           pasa a 'cancelled' pero la transacción de venta queda
--           intacta — el cierre la seguía contando, inflando el
--           efectivo esperado y dando "Faltante detectado" fantasma.
--
-- Fix : ambos RPCs ahora filtran las transacciones de venta cuyas
--       órdenes asociadas tengan al menos un pago en estado
--       'cancelled' o 'void'. NOT EXISTS es más eficiente que NOT IN
--       y maneja NULL correctamente: cuando related_order_id es NULL
--       (cierre manual sin orden), la transacción se incluye igual.
--
-- Compat : sin schema changes. Solo recreamos los RPC bodies. La
--          firma jsonb de retorno se mantiene idéntica + un campo
--          nuevo `voided_sales_total` para visibilidad opcional.
-- =============================================================================

-- 1. fn_close_cash_session
CREATE OR REPLACE FUNCTION public.fn_close_cash_session(
  p_session_id uuid,
  p_end_amount numeric,
  p_notes      text
) RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
DECLARE
    v_start_amount       numeric := 0;
    v_total_sales        numeric := 0;
    v_voided_sales       numeric := 0;
    v_total_deposits     numeric := 0;
    v_total_withdrawals  numeric := 0;
    v_total_expenses     numeric := 0;
    v_expected_amount    numeric := 0;
    v_difference         numeric := 0;
BEGIN
    SELECT start_amount INTO v_start_amount
    FROM public.cash_register_sessions
    WHERE id = p_session_id;

    IF v_start_amount IS NULL THEN
        RAISE EXCEPTION 'SESSION_NOT_FOUND';
    END IF;

    -- Ventas (excluye anuladas).
    SELECT COALESCE(SUM(amount), 0)
      INTO v_total_sales
      FROM public.cash_transactions ct
     WHERE ct.session_id = p_session_id
       AND ct.type = 'sale'
       AND NOT EXISTS (
         SELECT 1 FROM public.payments p
         WHERE p.order_id = ct.related_order_id
           AND p.status IN ('cancelled', 'void')
       );

    -- Ventas anuladas (informativo, no entra al esperado).
    SELECT COALESCE(SUM(amount), 0)
      INTO v_voided_sales
      FROM public.cash_transactions ct
     WHERE ct.session_id = p_session_id
       AND ct.type = 'sale'
       AND EXISTS (
         SELECT 1 FROM public.payments p
         WHERE p.order_id = ct.related_order_id
           AND p.status IN ('cancelled', 'void')
       );

    SELECT COALESCE(SUM(amount), 0)
      INTO v_total_deposits
      FROM public.cash_transactions
     WHERE session_id = p_session_id AND type = 'deposit';

    SELECT COALESCE(SUM(amount), 0)
      INTO v_total_withdrawals
      FROM public.cash_transactions
     WHERE session_id = p_session_id AND type = 'withdrawal';

    SELECT COALESCE(SUM(amount), 0)
      INTO v_total_expenses
      FROM public.cash_transactions
     WHERE session_id = p_session_id AND type = 'expense';

    v_expected_amount := (v_total_deposits + v_total_sales)
                       - (v_total_withdrawals + v_total_expenses);
    v_difference := p_end_amount - v_expected_amount;

    UPDATE public.cash_register_sessions
       SET closed_at = NOW(),
           end_amount = p_end_amount,
           difference = v_difference,
           status = 'closed',
           notes = p_notes
     WHERE id = p_session_id;

    RETURN jsonb_build_object(
      'success', true,
      'difference', v_difference,
      'expected', v_expected_amount,
      'expected_amount', v_expected_amount,
      'start_amount', v_start_amount,
      'total_sales', v_total_sales,
      'voided_sales_total', v_voided_sales,
      'total_deposits', v_total_deposits,
      'total_withdrawals', v_total_withdrawals,
      'total_expenses', v_total_expenses
    );
END;
$$;

ALTER FUNCTION public.fn_close_cash_session(uuid, numeric, text)
  OWNER TO postgres;


-- 2. fn_get_cash_session_summary
CREATE OR REPLACE FUNCTION public.fn_get_cash_session_summary(
  p_session_id uuid
) RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
DECLARE
    v_result jsonb;
BEGIN
    SELECT jsonb_build_object(
        'start_amount', s.start_amount,
        'opened_at', s.opened_at,
        -- total_sales: solo ventas NO anuladas
        'total_sales', (
          SELECT COALESCE(SUM(amount), 0)
          FROM public.cash_transactions ct
          WHERE ct.session_id = s.id
            AND ct.type = 'sale'
            AND NOT EXISTS (
              SELECT 1 FROM public.payments p
              WHERE p.order_id = ct.related_order_id
                AND p.status IN ('cancelled', 'void')
            )
        ),
        'voided_sales_total', (
          SELECT COALESCE(SUM(amount), 0)
          FROM public.cash_transactions ct
          WHERE ct.session_id = s.id
            AND ct.type = 'sale'
            AND EXISTS (
              SELECT 1 FROM public.payments p
              WHERE p.order_id = ct.related_order_id
                AND p.status IN ('cancelled', 'void')
            )
        ),
        'total_deposits', (
          SELECT COALESCE(SUM(amount), 0)
          FROM public.cash_transactions
          WHERE session_id = s.id AND type = 'deposit'
        ),
        'total_withdrawals', (
          SELECT COALESCE(SUM(amount), 0)
          FROM public.cash_transactions
          WHERE session_id = s.id AND type = 'withdrawal'
        ),
        'total_expenses', (
          SELECT COALESCE(SUM(amount), 0)
          FROM public.cash_transactions
          WHERE session_id = s.id AND type = 'expense'
        ),
        -- total_income: ventas (no anuladas) + depósitos
        'total_income', (
          SELECT COALESCE(SUM(amount), 0)
          FROM public.cash_transactions ct
          WHERE ct.session_id = s.id
            AND (
              ct.type = 'deposit'
              OR (
                ct.type = 'sale'
                AND NOT EXISTS (
                  SELECT 1 FROM public.payments p
                  WHERE p.order_id = ct.related_order_id
                    AND p.status IN ('cancelled', 'void')
                )
              )
            )
        ),
        'total_outflows', (
          SELECT COALESCE(SUM(amount), 0)
          FROM public.cash_transactions
          WHERE session_id = s.id
            AND type IN ('withdrawal', 'expense')
        ),
        -- expected_amount: lo mismo que total_income - total_outflows.
        'expected_amount',
          (
            SELECT COALESCE(SUM(amount), 0)
            FROM public.cash_transactions ct
            WHERE ct.session_id = s.id
              AND (
                ct.type = 'deposit'
                OR (
                  ct.type = 'sale'
                  AND NOT EXISTS (
                    SELECT 1 FROM public.payments p
                    WHERE p.order_id = ct.related_order_id
                      AND p.status IN ('cancelled', 'void')
                  )
                )
              )
          )
          -
          (
            SELECT COALESCE(SUM(amount), 0)
            FROM public.cash_transactions
            WHERE session_id = s.id
              AND type IN ('withdrawal', 'expense')
          )
    ) INTO v_result
    FROM public.cash_register_sessions s
    WHERE s.id = p_session_id;

    RETURN v_result;
END;
$$;

ALTER FUNCTION public.fn_get_cash_session_summary(uuid) OWNER TO postgres;
