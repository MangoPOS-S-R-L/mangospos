-- Mitigar timeouts en pagos: prioriza consultas rápidas y aumenta el timeout de la función RPC.
-- Fecha: 2026-02-07

-- 1) Índice parcial para filtrar items abiertos en recalculos/rpc
CREATE INDEX IF NOT EXISTS idx_order_items_order_status_open
  ON public.order_items(order_id, status)
  WHERE status NOT IN ('paid','void');

-- 2) Índice auxiliar para pagos por orden
CREATE INDEX IF NOT EXISTS idx_payments_order_created
  ON public.payments(order_id, created_at DESC);

-- 3) Aumentar statement_timeout solo para la función fn_process_payment_v2
ALTER FUNCTION public.fn_process_payment_v2(
  p_order_id uuid,
  p_check_id uuid,
  p_payment_method_id text,
  p_amount numeric,
  p_reference text,
  p_customer_id uuid,
  p_customer_rnc text,
  p_cashier_session_id uuid
) SET statement_timeout = '60s';

-- Nota: Si usas fn_process_payment (v1) aún en algún ambiente, replica:
ALTER FUNCTION public.fn_process_payment(
  p_order_id uuid,
  p_check_id uuid,
  p_payment_method_id text,
  p_amount numeric,
  p_reference text,
  p_customer_id uuid,
  p_customer_rnc text
) SET statement_timeout = '60s';
