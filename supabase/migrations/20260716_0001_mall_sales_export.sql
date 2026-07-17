-- =============================================================================
-- 20260716_0001 — Exportación de ventas por hora a plaza comercial (SFTP)
-- =============================================================================
--
-- Caso: Ágora Santiago Center exige que cada local suba por SFTP un .txt con
-- el acumulado de ventas POR HORA de todas las cajas (formato de su manual,
-- sección 6.6 "Conexión al sistema de ventas").
--
-- Este migration crea:
--   1. business_sales_export_config — configuración por negocio (host SFTP,
--      credenciales, código de cliente NUMSERIE, etc). UNA fila por negocio.
--      RLS restringida a owner/admin porque guarda credenciales.
--   2. fn_mall_sales_by_hour(_business_id, _date) — agregado por hora local
--      del negocio: transacciones, artículos, bruto, impuestos y neto.
--      · Fuente = payments completados (todas las cajas del negocio).
--      · TOTALIMPUESTOS se deriva de order_items (subtotal/tax), NO de
--        fiscal_documents, por el historial de ITBIS=0 en NCFs (ver memoria
--        del bug del trigger 0007). El impuesto se prorratea por pago según
--        la fracción cobrada de la orden (soporta cuentas divididas).
--
-- Sin impacto fiscal: solo lectura para reporte externo.
-- =============================================================================

-- 1) Tabla de configuración -------------------------------------------------

CREATE TABLE IF NOT EXISTS public.business_sales_export_config (
  id            uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  business_id   uuid NOT NULL UNIQUE REFERENCES public.businesses(id) ON DELETE CASCADE,
  enabled       boolean NOT NULL DEFAULT false,
  -- Dispara el envío automáticamente al cerrar caja (además del botón manual).
  send_on_cash_close boolean NOT NULL DEFAULT true,
  host          text NOT NULL DEFAULT '',
  port          integer NOT NULL DEFAULT 22,
  username      text NOT NULL DEFAULT '',
  password      text NOT NULL DEFAULT '',
  remote_dir    text NOT NULL DEFAULT '/',
  -- Código de cliente asignado por la plaza (campo NUMSERIE del archivo).
  client_code   text NOT NULL DEFAULT '',
  -- Prefijo del nombre del archivo, ej. "Ventas_4_8" → Ventas_4_8_27032018.txt
  file_prefix   text NOT NULL DEFAULT 'Ventas',
  -- Campo TASA del archivo (tasa cambiaria); manual, default 1.
  exchange_rate numeric(10,6) NOT NULL DEFAULT 1.0,
  last_sent_at  timestamptz,
  last_error    text,
  created_at    timestamptz NOT NULL DEFAULT now(),
  updated_at    timestamptz NOT NULL DEFAULT now()
);

ALTER TABLE public.business_sales_export_config ENABLE ROW LEVEL SECURITY;

-- Solo owner/admin: la fila contiene credenciales SFTP.
DROP POLICY IF EXISTS bsec_admin ON public.business_sales_export_config;
CREATE POLICY bsec_admin ON public.business_sales_export_config
  TO authenticated
  USING (public.user_business_role(auth.uid(), business_id) = ANY (ARRAY['owner'::text, 'admin'::text]))
  WITH CHECK (public.user_business_role(auth.uid(), business_id) = ANY (ARRAY['owner'::text, 'admin'::text]));

DROP TRIGGER IF EXISTS set_business_sales_export_config_updated_at
  ON public.business_sales_export_config;
CREATE TRIGGER set_business_sales_export_config_updated_at
  BEFORE UPDATE ON public.business_sales_export_config
  FOR EACH ROW EXECUTE FUNCTION public.trigger_set_updated_at();

-- 2) RPC: ventas por hora ----------------------------------------------------

CREATE OR REPLACE FUNCTION public.fn_mall_sales_by_hour(
  _business_id uuid,
  _date        date
)
RETURNS TABLE(
  sale_hour   integer,
  tx_count    integer,
  total_items numeric,
  total_gross numeric,
  total_tax   numeric,
  total_net   numeric
)
LANGUAGE plpgsql
STABLE SECURITY DEFINER
SET search_path TO 'public'
AS $function$
DECLARE
  v_tz   text;
  v_from timestamptz;
  v_to   timestamptz;
BEGIN
  -- Access check (mismo patrón que get_sales_summary_v2).
  IF auth.role() != 'service_role' THEN
    IF NOT EXISTS (
      SELECT 1 FROM current_user_business_ids() c
      WHERE c.business_id = _business_id
    ) THEN
      RAISE EXCEPTION 'access denied' USING ERRCODE = '42501';
    END IF;
  END IF;

  SELECT COALESCE(bs.timezone, 'America/Santo_Domingo') INTO v_tz
  FROM business_settings bs
  WHERE bs.business_id = _business_id;
  v_tz := COALESCE(v_tz, 'America/Santo_Domingo');

  -- Día local del negocio → rango UTC.
  v_from := _date::timestamp AT TIME ZONE v_tz;
  v_to   := (_date + 1)::timestamp AT TIME ZONE v_tz;

  RETURN QUERY
  WITH completed_payments AS (
    SELECT
      p.id,
      p.order_id,
      (p.amount - COALESCE(p.change_amount, 0)) AS net_amount,
      EXTRACT(HOUR FROM p.created_at AT TIME ZONE v_tz)::int AS pay_hour
    FROM payments p
    WHERE p.business_id = _business_id
      AND p.created_at >= v_from
      AND p.created_at <  v_to
      AND (p.status = 'completed' OR p.status IS NULL)
  ),
  order_totals AS (
    SELECT
      oi.order_id,
      SUM(COALESCE(oi.tax, 0)) AS order_tax,
      SUM(COALESCE(oi.subtotal, 0) + COALESCE(oi.tax, 0)) AS order_gross,
      SUM(COALESCE(NULLIF(oi.qty, 0), oi.quantity, 0)) AS order_qty
    FROM order_items oi
    WHERE oi.business_id = _business_id
      AND oi.order_id IN (
        SELECT DISTINCT cp.order_id FROM completed_payments cp
        WHERE cp.order_id IS NOT NULL
      )
      AND oi.status != 'void'
    GROUP BY oi.order_id
  ),
  payment_rows AS (
    -- Prorrateo por pago: si el pago cubre una fracción de la orden
    -- (cuenta dividida / pago parcial), impuestos y artículos se
    -- reparten en la misma proporción de lo cobrado.
    SELECT
      cp.pay_hour,
      cp.net_amount,
      CASE WHEN COALESCE(ot.order_gross, 0) > 0
           THEN cp.net_amount * (ot.order_tax / ot.order_gross)
           ELSE 0 END AS tax_amount,
      CASE WHEN COALESCE(ot.order_gross, 0) > 0
           THEN ot.order_qty * (cp.net_amount / ot.order_gross)
           ELSE 0 END AS items_qty
    FROM completed_payments cp
    LEFT JOIN order_totals ot ON ot.order_id = cp.order_id
  )
  SELECT
    pr.pay_hour                                        AS sale_hour,
    COUNT(*)::int                                      AS tx_count,
    ROUND(SUM(pr.items_qty)::numeric, 2)               AS total_items,
    ROUND(SUM(pr.net_amount)::numeric, 2)              AS total_gross,
    ROUND(SUM(pr.tax_amount)::numeric, 2)              AS total_tax,
    ROUND(SUM(pr.net_amount - pr.tax_amount)::numeric, 2) AS total_net
  FROM payment_rows pr
  GROUP BY pr.pay_hour
  ORDER BY pr.pay_hour;
END;
$function$;

REVOKE ALL ON FUNCTION public.fn_mall_sales_by_hour(uuid, date) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.fn_mall_sales_by_hour(uuid, date)
  TO authenticated, service_role;
