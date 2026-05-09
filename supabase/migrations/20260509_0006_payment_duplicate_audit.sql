-- =============================================================================
-- Audit logging temporal para detectar payments duplicados que bypaseen el
-- guard de fn_process_payment_v3.
--
-- Contexto:
--   Migration 20260509_0001 agrego guard atomico (SELECT FOR UPDATE +
--   verificacion de orden cerrada). Verificamos que el cuerpo deployed lo
--   tiene. Pero el 2026-05-09 detectamos 4 nuevas duplicaciones que el guard
--   no bloqueo. El UNIQUE INDEX no es viable porque rompe split full-order
--   legitimo.
--
--   Antes de cambiar el guard, queremos evidencia exacta de cuando el
--   bypass ocurre. Este audit log registra cada vez que se inserta un
--   payment a una orden cuyo status_ext ya esta 'paid'/'void' o que ya
--   tiene closed_at (= duplicado por definicion del guard).
--
-- Diseno:
--   - Tabla `payment_duplicate_audit` con metadata del evento.
--   - Trigger AFTER INSERT en payments que llena la tabla cuando se
--     detecta el patron sospechoso.
--   - No bloquea el INSERT (es solo logging). El payment se inserta igual.
--   - `txid_current()` permite correlacionar payments del mismo
--     transaction (race-condition vs retry separado).
--
-- Como usar:
--   1. Aplicar esta migration.
--   2. Operar normalmente unas horas.
--   3. Query: SELECT * FROM payment_duplicate_audit ORDER BY detected_at;
--   4. Analizar patrones (mismo txid? distintos? gap entre payments?).
--   5. Una vez identificado el path, aplicar fix definitivo y eliminar
--      este audit log.
--
-- Esta migration es NO-DESTRUCTIVA y se puede revertir con:
--   DROP TRIGGER audit_duplicate_payment ON public.payments;
--   DROP FUNCTION public.trg_audit_duplicate_payment;
--   DROP TABLE public.payment_duplicate_audit;
-- =============================================================================

CREATE TABLE IF NOT EXISTS public.payment_duplicate_audit (
  id                       uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  payment_id               uuid NOT NULL,
  order_id                 uuid NOT NULL,
  payment_amount           numeric,
  payment_method_id        uuid,
  payment_check_id         uuid,
  payment_session_id       uuid,
  order_status_at_insert   text,
  order_closed_at_existing timestamptz,
  detected_at              timestamptz NOT NULL DEFAULT now(),
  txid                     bigint NOT NULL DEFAULT txid_current(),
  pid                      integer DEFAULT pg_backend_pid(),
  app_name                 text DEFAULT current_setting('application_name', true),
  user_id                  uuid DEFAULT auth.uid()
);

COMMENT ON TABLE public.payment_duplicate_audit IS
  'Audit log de payments insertados en orders ya cerradas. Indica que el '
  'guard de fn_process_payment_v3 fue bypaseado. Temporal — eliminar tras '
  'identificar y corregir el path bug.';

CREATE INDEX IF NOT EXISTS idx_pda_order_id ON public.payment_duplicate_audit (order_id);
CREATE INDEX IF NOT EXISTS idx_pda_detected_at ON public.payment_duplicate_audit (detected_at DESC);

CREATE OR REPLACE FUNCTION public.trg_audit_duplicate_payment()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_status text;
  v_closed_at timestamptz;
  v_existing_count int;
BEGIN
  -- Solo loguear payments completed.
  IF NEW.status IS DISTINCT FROM 'completed' THEN
    RETURN NEW;
  END IF;

  -- Solo loguear si la orden ya estaba cerrada antes de este INSERT
  -- (= caso anomalo que el guard de v3 deberia haber bloqueado).
  SELECT o.status_ext::text, o.closed_at
    INTO v_status, v_closed_at
  FROM public.orders o
  WHERE o.id = NEW.order_id;

  -- Caso anomalo: orden cerrada O status terminal.
  IF v_closed_at IS NOT NULL
     OR v_status IN ('paid', 'void')
  THEN
    -- Tambien contamos cuantos payments completed habia ANTES de este INSERT.
    SELECT count(*)
      INTO v_existing_count
    FROM public.payments
    WHERE order_id = NEW.order_id
      AND status = 'completed'
      AND id <> NEW.id;

    INSERT INTO public.payment_duplicate_audit (
      payment_id,
      order_id,
      payment_amount,
      payment_method_id,
      payment_check_id,
      payment_session_id,
      order_status_at_insert,
      order_closed_at_existing
    ) VALUES (
      NEW.id,
      NEW.order_id,
      NEW.amount,
      NEW.payment_method_id,
      NEW.check_id,
      NEW.session_id,
      v_status || ' (n_existing=' || v_existing_count || ')',
      v_closed_at
    );
  END IF;

  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS audit_duplicate_payment ON public.payments;

CREATE TRIGGER audit_duplicate_payment
AFTER INSERT ON public.payments
FOR EACH ROW
EXECUTE FUNCTION public.trg_audit_duplicate_payment();

GRANT SELECT ON public.payment_duplicate_audit TO authenticated;
