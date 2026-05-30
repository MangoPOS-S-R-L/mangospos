-- =============================================================================
-- fn_sales_audit: función de audit que devuelve ventas calculadas de 2
-- maneras independientes y el drift entre ellas. Si drift > 1 RD$,
-- algo cambió en la pipeline de cálculo del RPC `get_sales_summary_v2`
-- y hay que investigar antes de confiar en los reportes.
--
-- Uso:
--   SELECT * FROM fn_sales_audit(
--     '33207ebd-985d-455c-bdbb-1b38af8b36ea',
--     '2026-05-01',
--     '2026-06-01'
--   );
--
-- Resultado (1 fila):
--   v1_payments — ventas calculadas sumando payments netos de cambio.
--                 Fuente de verdad operacional.
--   v5_rpc      — ventas devueltas por get_sales_summary_v2 (lo que
--                 el reporte de la app muestra).
--   drift       — v1 - v5. Si ≠ 0, alguien cambió la lógica del RPC.
--
-- Pensado para correr como cron semanal/mensual o para verificación
-- manual desde Supabase Studio. Si en algún momento drift sube de 0,
-- es señal de alerta temprana antes de que el problema se propague
-- a reportes consumidos por el contable.
-- =============================================================================

CREATE OR REPLACE FUNCTION public.fn_sales_audit(
  p_business_id uuid,
  p_from        timestamptz,
  p_to          timestamptz
)
RETURNS TABLE (
  v1_payments numeric,
  v5_rpc      numeric,
  drift       numeric
)
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path TO 'public'
AS $function$
BEGIN
  IF auth.role() <> 'service_role' THEN
    IF NOT EXISTS (
      SELECT 1 FROM public.current_user_business_ids() c
      WHERE c.business_id = p_business_id
    ) THEN
      RAISE EXCEPTION 'access denied' USING ERRCODE = '42501';
    END IF;
  END IF;

  RETURN QUERY
  WITH payments_net AS (
    SELECT ROUND(COALESCE(SUM(p.amount - COALESCE(p.change_amount, 0)), 0)::numeric, 2) AS v1
    FROM public.payments p
    JOIN public.orders o ON o.id = p.order_id
    JOIN public.table_sessions ts ON ts.id = o.session_id
    WHERE ts.business_id = p_business_id
      AND p.created_at >= p_from
      AND p.created_at < p_to
      AND (p.status = 'completed' OR p.status IS NULL)
  ),
  rpc_result AS (
    SELECT ROUND(((public.get_sales_summary_v2(p_business_id, p_from, p_to)
                   ->>'total_sales')::numeric), 2) AS v5
  )
  SELECT
    pn.v1,
    rr.v5,
    ROUND((pn.v1 - rr.v5)::numeric, 2) AS drift
  FROM payments_net pn, rpc_result rr;
END;
$function$;

REVOKE ALL ON FUNCTION public.fn_sales_audit(uuid, timestamptz, timestamptz) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.fn_sales_audit(uuid, timestamptz, timestamptz) TO authenticated;

COMMENT ON FUNCTION public.fn_sales_audit(uuid, timestamptz, timestamptz) IS
  'Audit de ventas: compara payments directos vs get_sales_summary_v2. Si drift != 0, alguien cambió la pipeline del RPC.';
