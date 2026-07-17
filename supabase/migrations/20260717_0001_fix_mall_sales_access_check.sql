-- Fix 42703 en fn_mall_sales_by_hour: current_user_business_ids() devuelve
-- SETOF uuid (columna escalar), no una tabla con columna business_id.
-- El check de acceso usaba "c.business_id" y rompía el RPC para todo usuario
-- no service_role. Se reescribe con el patrón del resto del esquema
-- (FROM current_user_business_ids() AS bid WHERE bid = ...).

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
      SELECT 1 FROM current_user_business_ids() AS bid
      WHERE bid = _business_id
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
