-- =============================================================================
-- get_sales_summary_v2 → CONCILIA los desgloses por línea (categoría y área de
-- producción) al monto realmente cobrado por orden.
--
-- Problema (reportado en producción): la card "Ventas" de arriba mostraba
-- RD$139,745 (net_sales = SUM de pagos completados) pero el "Total mostrado"
-- del desglose por área/categoría daba RD$140,595 — RD$850 de más. Esa
-- diferencia es un descuento/ajuste a nivel de ORDEN que las líneas no
-- reflejan: los desgloses por línea sumaban el bruto del ítem (subtotal+tax),
-- no lo que de verdad entró en caja.
--
-- Los desgloses por empleado y por zona NO tenían el problema porque ya
-- sumaban `amount_by_order` (lo cobrado por orden). Este fix lleva esa misma
-- base a los desgloses por línea:
--
--   - Nuevo CTE `items_allocated`: reparte el monto cobrado de cada orden
--     (amount_by_order.amount) proporcionalmente entre sus líneas, según el
--     peso del bruto de cada línea (gross_amount / SUM(gross_amount) de la
--     orden). Si la orden no tiene bruto (todo cortesía) cae al bruto crudo.
--   - `by_category` y `by_production_area` ahora suman `alloc_amount`. Por
--     construcción, SUM sobre todas las líneas = SUM de lo cobrado por orden
--     = total_sales. El "Total mostrado" cuadra con la card de arriba.
--
-- NO se toca `items_adjusted` (sigue alimentando product_sales y top_products
-- con la lógica de delta de redondeo + el invariante documentado
-- Brutas - Descuentos - Cortesías = Netas del reporte "Ventas por producto").
-- El resto del cuerpo es idéntico a 20260531_0001.
-- =============================================================================

CREATE OR REPLACE FUNCTION public.get_sales_summary_v2(
  _business_id uuid,
  _from        timestamp with time zone,
  _to          timestamp with time zone
)
RETURNS jsonb
LANGUAGE plpgsql
STABLE SECURITY DEFINER
SET search_path TO 'public'
AS $function$
DECLARE result jsonb;
BEGIN
  -- Access check: service_role salta (admin/RPC), authenticated valida
  IF auth.role() != 'service_role' THEN
    IF NOT EXISTS (
      SELECT 1 FROM current_user_business_ids() c
      WHERE c.business_id = _business_id
    ) THEN
      RAISE EXCEPTION 'access denied' USING ERRCODE = '42501';
    END IF;
  END IF;

  WITH
  scoped_payments AS (
    SELECT
      p.id, p.amount, p.change_amount, p.order_id, p.check_id,
      p.fiscal_document_id, p.status, p.created_at,
      p.payment_method_id,
      pm.name AS method_name, pm.code AS method_code,
      (p.amount - COALESCE(p.change_amount, 0)) AS net_amount
    FROM payments p
    LEFT JOIN payment_methods pm ON pm.id = p.payment_method_id
    WHERE p.business_id = _business_id
      AND p.created_at >= _from
      AND p.created_at < _to
  ),
  completed_payments AS (
    SELECT * FROM scoped_payments WHERE status = 'completed' OR status IS NULL
  ),
  voided_payments AS (
    SELECT * FROM scoped_payments WHERE status IN ('void', 'cancelled')
  ),
  amount_by_order AS (
    SELECT order_id, SUM(net_amount) AS amount
    FROM completed_payments WHERE order_id IS NOT NULL GROUP BY order_id
  ),
  order_ctx AS (
    SELECT o.id AS order_id, o.total AS order_total,
      COALESCE(pr.full_name, 'Sin empleado') AS employee_name,
      COALESCE(z.name, 'Sin zona') AS zone_name
    FROM orders o
    LEFT JOIN table_sessions ts ON ts.id = o.session_id
    LEFT JOIN profiles pr ON pr.id = ts.waiter_user_id
    LEFT JOIN dining_tables dt ON dt.id = ts.table_id
    LEFT JOIN zones z ON z.id = dt.zone_id
    WHERE o.id IN (SELECT order_id FROM amount_by_order)
      AND o.business_id = _business_id
  ),
  scoped_items AS (
    SELECT oi.id, oi.order_id, oi.product_id, oi.product_name,
      COALESCE(NULLIF(oi.qty, 0), oi.quantity, 0) AS qty,
      oi.subtotal, oi.discounts, oi.tax, oi.status, oi.notes,
      (oi.subtotal + oi.tax) AS gross_amount,
      COALESCE(c.name, 'Sin categoría') AS category_name,
      COALESCE(pa.name, NULLIF(oi.print_area_code, ''), 'Sin área') AS area_name
    FROM order_items oi
    LEFT JOIN menu_items mi ON mi.id = oi.product_id
    LEFT JOIN categories c ON c.id = mi.category_id
    LEFT JOIN print_areas pa
      ON pa.business_id = _business_id AND pa.code = oi.print_area_code
    WHERE oi.business_id = _business_id
      AND oi.order_id IN (SELECT order_id FROM amount_by_order)
      AND oi.status != 'void'
  ),
  per_order_delta AS (
    SELECT i.order_id, o.order_total - SUM(i.gross_amount) AS delta
    FROM scoped_items i JOIN order_ctx o ON o.order_id = i.order_id
    GROUP BY i.order_id, o.order_total
  ),
  items_ranked AS (
    SELECT i.*,
      ROW_NUMBER() OVER (PARTITION BY i.order_id ORDER BY i.gross_amount DESC) AS rn
    FROM scoped_items i
  ),
  items_adjusted AS (
    SELECT ir.*,
      CASE WHEN ir.rn = 1 AND ABS(d.delta) < 1.0
           THEN ir.gross_amount + d.delta ELSE ir.gross_amount END AS adjusted_amount
    FROM items_ranked ir LEFT JOIN per_order_delta d ON d.order_id = ir.order_id
  ),
  -- Bruto total por orden, base para repartir lo cobrado entre líneas.
  order_gross AS (
    SELECT order_id, SUM(gross_amount) AS sum_gross
    FROM scoped_items GROUP BY order_id
  ),
  -- Reparte amount_by_order.amount (lo cobrado) proporcionalmente al peso del
  -- bruto de cada línea. SUM(alloc_amount) por orden = lo cobrado por orden,
  -- así los desgloses por línea concilian con net_sales.
  items_allocated AS (
    SELECT i.*,
      CASE WHEN og.sum_gross > 0
           THEN i.gross_amount * abo.amount / og.sum_gross
           ELSE i.gross_amount END AS alloc_amount
    FROM scoped_items i
    JOIN order_gross og ON og.order_id = i.order_id
    JOIN amount_by_order abo ON abo.order_id = i.order_id
  ),
  totals AS (
    SELECT COALESCE(SUM(net_amount), 0) AS total_sales, COUNT(*) AS payments_count
    FROM completed_payments
  ),
  voided_totals AS (
    SELECT COALESCE(SUM(net_amount), 0) AS voided_sales, COUNT(*) AS voided_count
    FROM voided_payments
  ),
  items_totals AS (
    SELECT
      COALESCE(SUM(qty), 0) AS items_sold,
      COALESCE(SUM(discounts), 0) AS discounts_total,
      COUNT(*) FILTER (WHERE discounts > 0) AS discounted_lines_count,
      COUNT(*) FILTER (
        WHERE notes LIKE '%[CORTESIA:%'
           OR (gross_amount > 0 AND discounts >= gross_amount - 0.01)
      ) AS courtesy_lines_count,
      COALESCE(SUM(discounts) FILTER (
        WHERE notes LIKE '%[CORTESIA:%'
           OR (gross_amount > 0 AND discounts >= gross_amount - 0.01)
      ), 0) AS courtesy_total
    FROM scoped_items
  ),
  by_method AS (
    SELECT COALESCE(method_name, 'Sin método') AS label,
      method_code AS code,
      COALESCE(SUM(net_amount), 0) AS amount, COUNT(*) AS count
    FROM completed_payments GROUP BY method_name, method_code
  ),
  by_hour AS (
    SELECT EXTRACT(HOUR FROM created_at AT TIME ZONE 'America/Santo_Domingo')::int AS hour,
      COALESCE(SUM(net_amount), 0) AS amount, COUNT(*) AS count
    FROM completed_payments GROUP BY 1
  ),
  by_employee AS (
    SELECT oc.employee_name AS label,
      COALESCE(SUM(abo.amount), 0) AS amount,
      COUNT(DISTINCT abo.order_id) AS count
    FROM amount_by_order abo JOIN order_ctx oc ON oc.order_id = abo.order_id
    GROUP BY oc.employee_name
  ),
  by_zone AS (
    SELECT oc.zone_name AS label,
      COALESCE(SUM(abo.amount), 0) AS amount,
      COUNT(DISTINCT abo.order_id) AS count
    FROM amount_by_order abo JOIN order_ctx oc ON oc.order_id = abo.order_id
    GROUP BY oc.zone_name
  ),
  by_category AS (
    SELECT category_name AS label,
      COALESCE(SUM(alloc_amount), 0) AS amount,
      COALESCE(SUM(qty), 0) AS quantity, COUNT(*) AS count
    FROM items_allocated GROUP BY category_name
  ),
  by_production_area AS (
    SELECT area_name AS label,
      COALESCE(SUM(alloc_amount), 0) AS amount,
      COALESCE(SUM(qty), 0) AS quantity,
      COUNT(DISTINCT order_id) AS count
    FROM items_allocated GROUP BY area_name
  ),
  top_products_agg AS (
    SELECT product_name AS label, product_id,
      COALESCE(SUM(adjusted_amount), 0) AS amount,
      COALESCE(SUM(qty), 0) AS quantity
    FROM items_adjusted GROUP BY product_name, product_id
  ),
  product_sales_agg AS (
    SELECT
      ia.product_id,
      MAX(ia.product_name)  AS product,
      MAX(ia.category_name) AS category,
      COALESCE(SUM(ia.qty), 0) AS quantity_sold,
      COALESCE(SUM(ia.adjusted_amount + ia.discounts), 0) AS gross_sales,
      COALESCE(SUM(ia.discounts) FILTER (
        WHERE NOT (
          ia.notes LIKE '%[CORTESIA:%'
          OR (ia.gross_amount > 0 AND ia.discounts >= ia.gross_amount - 0.01)
        )
      ), 0) AS discounts,
      COALESCE(SUM(ia.discounts) FILTER (
        WHERE
          ia.notes LIKE '%[CORTESIA:%'
          OR (ia.gross_amount > 0 AND ia.discounts >= ia.gross_amount - 0.01)
      ), 0) AS courtesies,
      COALESCE(SUM(ia.adjusted_amount), 0) AS net_sales,
      COUNT(DISTINCT ia.order_id) AS tickets
    FROM items_adjusted ia
    GROUP BY ia.product_id
  ),
  orders_total_sum AS (
    SELECT COALESCE(SUM(order_total), 0) AS sum_orders FROM order_ctx
  )
  SELECT jsonb_build_object(
    'from', _from, 'to', _to,
    'total_sales', (SELECT total_sales FROM totals),
    'voided_sales', (SELECT voided_sales FROM voided_totals),
    'net_sales', (SELECT total_sales FROM totals),
    'payments_count', (SELECT payments_count FROM totals),
    'voided_payments_count', (SELECT voided_count FROM voided_totals),
    'items_sold', (SELECT items_sold::int FROM items_totals),
    'discounts_total', (SELECT discounts_total FROM items_totals),
    'courtesy_total', (SELECT courtesy_total FROM items_totals),
    'discounted_lines_count', (SELECT discounted_lines_count FROM items_totals),
    'courtesy_lines_count', (SELECT courtesy_lines_count FROM items_totals),
    'avg_ticket', CASE WHEN (SELECT payments_count FROM totals) = 0 THEN 0
      ELSE (SELECT total_sales FROM totals) / (SELECT payments_count FROM totals) END,
    'sum_orders_total', (SELECT sum_orders FROM orders_total_sum),
    'voluntary_tip', GREATEST(0,
      (SELECT total_sales FROM totals) - (SELECT sum_orders FROM orders_total_sum)),
    'sales_by_method', COALESCE(
      (SELECT jsonb_agg(jsonb_build_object('label', label, 'code', code,
        'amount', amount, 'count', count) ORDER BY amount DESC) FROM by_method), '[]'::jsonb),
    'sales_by_hour', COALESCE(
      (SELECT jsonb_agg(jsonb_build_object('hour', hour,
        'amount', amount, 'count', count) ORDER BY hour) FROM by_hour), '[]'::jsonb),
    'sales_by_employee', COALESCE(
      (SELECT jsonb_agg(jsonb_build_object('label', label,
        'amount', amount, 'count', count) ORDER BY amount DESC) FROM by_employee), '[]'::jsonb),
    'sales_by_zone', COALESCE(
      (SELECT jsonb_agg(jsonb_build_object('label', label,
        'amount', amount, 'count', count) ORDER BY amount DESC) FROM by_zone), '[]'::jsonb),
    'sales_by_category', COALESCE(
      (SELECT jsonb_agg(jsonb_build_object('label', label, 'amount', amount,
        'quantity', quantity, 'count', count) ORDER BY amount DESC) FROM by_category), '[]'::jsonb),
    'sales_by_production_area', COALESCE(
      (SELECT jsonb_agg(jsonb_build_object('label', label, 'amount', amount,
        'quantity', quantity, 'count', count) ORDER BY amount DESC) FROM by_production_area), '[]'::jsonb),
    'top_products', COALESCE(
      (SELECT jsonb_agg(jsonb_build_object('label', label, 'product_id', product_id,
        'amount', amount, 'quantity', quantity) ORDER BY amount DESC)
       FROM (SELECT * FROM top_products_agg ORDER BY amount DESC LIMIT 20) t), '[]'::jsonb),
    'product_sales', COALESCE(
      (SELECT jsonb_agg(jsonb_build_object(
        'product_id',    product_id,
        'product',       product,
        'category',      category,
        'quantity_sold', quantity_sold,
        'gross_sales',   gross_sales,
        'discounts',     discounts,
        'courtesies',    courtesies,
        'net_sales',     net_sales,
        'cost',          0,
        'gross_profit',  0,
        'tickets',       tickets
      ) ORDER BY net_sales DESC)
      FROM product_sales_agg), '[]'::jsonb)
  ) INTO result;

  RETURN result;
END;
$function$;
