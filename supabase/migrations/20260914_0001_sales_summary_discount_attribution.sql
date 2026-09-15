-- =============================================================================
-- 20260914_0001 — get_sales_summary_v2: descuento ATRIBUIDO a lo cobrado
-- =============================================================================
--
-- Bug: `discounts_total` (y cortesías) sumaba el descuento COMPLETO de toda
-- orden con ALGÚN pago completado en el rango, sin importar qué se cobró. Una
-- cuenta abierta por semanas que recibe un abono arrastraba todo su descuento
-- a ese día.
--   Caso real (negocio d1f0e5c5, 11/09/2026): mesa CR08 abierta desde el 18/07,
--   32 consumos con 25% de descuento. Ese día solo se cobró una subcuenta de
--   360 (un taco con 120 de descuento) y el reporte mostró 2,281.05.
--
-- Fix: cada línea aporta `discounts × disc_factor` según lo cobrado en el
-- rango (CTE item_disc_factor). Pago con check_id liquida las líneas de ESA
-- subcuenta; pago full-order (check_id NULL) liquida el resto — igual que
-- fn_process_payment_v3.
--
-- Cambios (ningún campo se quita ni se renombra):
--   1. scoped_items: + oi.check_id.
--   2. CTEs nuevos de atribución (order_payments_all … items_disc).
--   3. items_totals: discounts_total, courtesy_total y conteos de líneas usan
--      el descuento atribuido.
--   4. product_sales: discounts, courtesies y gross_sales usan el descuento
--      atribuido (gross_sales - discounts - courtesies = net_sales se mantiene).
--   5. product_sales.discounts: fix de NULL. Con notes NULL el FILTER
--      NOT (notes LIKE …) daba NULL y descartaba la línea, así que la columna
--      "Descuentos" por producto salía en 0 para todo descuento sin marca.
--
-- Órdenes cobradas completas dentro del rango: resultado IDÉNTICO (factor 1),
-- salvo product_sales.discounts, que ahora sí refleja los descuentos (fix 5).
-- NO cambia: total_sales, net_sales, métodos, horas, empleados, zonas,
-- categorías, áreas, items_sold, top_products ni net_sales por producto.
--
-- Sin impacto fiscal: no toca emisión, NCF ni fiscal_documents.
--
-- BASE: la definición VIVA de producción (pg_get_functiondef, 2026-09-14). Difiere
-- de 20260601_0005 solo en el access check: current_user_business_ids() c(bid)
-- / c.bid (fix del alias 42703 aplicado directo en la BD y nunca guardado en el
-- repo). Esta migración lo deja versionado.
--
-- GUARD: antes de reemplazar se verifica que el cuerpo vigente sea EXACTAMENTE
-- esa definición viva (md5 de prosrc). Si no coincide, aborta sin tocar nada.
-- Aplicar desde Studio (una ejecución) o con psql -v ON_ERROR_STOP=1.
-- =============================================================================

BEGIN;

DO $guard$
DECLARE
  v_md5 text;
BEGIN
  SELECT md5(p.prosrc) INTO v_md5
  FROM pg_proc p
  JOIN pg_namespace n ON n.oid = p.pronamespace
  WHERE n.nspname = 'public'
    AND p.proname = 'get_sales_summary_v2'
    AND pg_get_function_identity_arguments(p.oid)
        = '_business_id uuid, _from timestamp with time zone, _to timestamp with time zone';

  IF v_md5 IS DISTINCT FROM 'df9fad09be655f4d8e28ae02f63bd959' THEN
    RAISE EXCEPTION
      'get_sales_summary_v2 en la BD (md5 %) no coincide con la versión viva esperada (0005 + alias c(bid)). No se aplicó nada: comparar con pg_get_functiondef antes de seguir.',
      v_md5;
  END IF;
END
$guard$;

CREATE OR REPLACE FUNCTION public.get_sales_summary_v2(_business_id uuid, _from timestamp with time zone, _to timestamp with time zone)
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
      SELECT 1 FROM current_user_business_ids() c(bid)
      WHERE c.bid = _business_id
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
      -- 20260914_0001: subcuenta de la línea, para atribuir el descuento.
      oi.check_id,
      (oi.subtotal + oi.tax) AS gross_amount,
      COALESCE(c.name, 'Sin categoría') AS category_name,
      COALESCE(pa.name, NULLIF(oi.print_area_code, ''), 'Sin área') AS area_name,
      -- RF-R1: costo unitario ACTUAL del producto (menu_items.cost).
      COALESCE(mi.cost, 0) AS unit_cost
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
  -- ── 20260914_0001: DESCUENTO ATRIBUIDO A LO COBRADO EN EL RANGO ──────────
  -- Cada línea aporta discounts × disc_factor. Misma semántica que
  -- fn_process_payment_v3: pago con check_id liquida las líneas de ESA
  -- subcuenta; pago full-order (check_id NULL) liquida el resto.
  --   1) Subcuenta cobrada EN el rango  → cobrado_sub / neto_sub (tope 1).
  --   2) Subcuenta cobrada en OTRA fecha → 0 (su descuento se cuenta allá).
  --   3) Resto con pago full-order EN el rango → cobrado / neto_resto (tope 1).
  --   4) Resto 100% cortesía (neto ≈ 0) sin pago full-order nunca → cuenta el
  --      día del ÚLTIMO pago de la orden (si no, se perdería).
  --   5) Lo demás (cuenta abierta sin cobrar) → 0.
  -- Orden cobrada completa dentro del rango ⇒ factor 1 ⇒ igual que antes.
  -- Neto de línea = subtotal + tax - discounts (misma fórmula que el guard de
  -- cobertura de fn_process_payment_v3).
  order_payments_all AS (
    SELECT p.order_id, p.check_id, p.created_at,
      (p.amount - COALESCE(p.change_amount, 0)) AS net_amount
    FROM payments p
    WHERE p.business_id = _business_id
      AND p.order_id IN (SELECT order_id FROM amount_by_order)
      AND (p.status = 'completed' OR p.status IS NULL)
  ),
  checks_paid_ever AS (
    SELECT DISTINCT check_id FROM order_payments_all WHERE check_id IS NOT NULL
  ),
  check_paid_in_range AS (
    SELECT check_id, SUM(net_amount) AS paid
    FROM completed_payments
    WHERE order_id IS NOT NULL AND check_id IS NOT NULL
    GROUP BY check_id
  ),
  order_level_paid_in_range AS (
    SELECT order_id, SUM(net_amount) AS paid
    FROM completed_payments
    WHERE order_id IS NOT NULL AND check_id IS NULL
    GROUP BY order_id
  ),
  order_payment_facts AS (
    SELECT order_id,
      MAX(created_at) AS last_paid_at,
      BOOL_OR(check_id IS NULL) AS has_order_level_payment
    FROM order_payments_all
    GROUP BY order_id
  ),
  items_disc_base AS (
    SELECT i.id, i.order_id, i.check_id,
      (i.subtotal + i.tax - COALESCE(i.discounts, 0)) AS line_net,
      (i.check_id IS NOT NULL
        AND i.check_id IN (SELECT check_id FROM checks_paid_ever)) AS in_paid_check
    FROM scoped_items i
  ),
  check_net AS (
    SELECT check_id, SUM(line_net) AS net
    FROM items_disc_base WHERE check_id IS NOT NULL
    GROUP BY check_id
  ),
  residual_net AS (
    SELECT order_id, SUM(line_net) AS net
    FROM items_disc_base WHERE NOT in_paid_check
    GROUP BY order_id
  ),
  item_disc_factor AS (
    SELECT b.id,
      CASE
        WHEN cp.check_id IS NOT NULL THEN
          CASE WHEN cn.net <= 0.01 OR cp.paid >= cn.net - 0.01 THEN 1.0
               ELSE GREATEST(0, cp.paid / cn.net) END
        WHEN b.in_paid_check THEN 0.0
        WHEN olp.order_id IS NOT NULL THEN
          CASE WHEN rn.net <= 0.01 OR olp.paid >= rn.net - 0.01 THEN 1.0
               ELSE GREATEST(0, olp.paid / rn.net) END
        WHEN rn.net <= 0.01
         AND NOT opf.has_order_level_payment
         AND opf.last_paid_at >= _from
         AND opf.last_paid_at <  _to THEN 1.0
        ELSE 0.0
      END AS disc_factor
    FROM items_disc_base b
    LEFT JOIN check_paid_in_range cp      ON cp.check_id  = b.check_id
    LEFT JOIN check_net cn                ON cn.check_id  = b.check_id
    LEFT JOIN order_level_paid_in_range olp ON olp.order_id = b.order_id
    LEFT JOIN residual_net rn             ON rn.order_id  = b.order_id
    LEFT JOIN order_payment_facts opf     ON opf.order_id = b.order_id
  ),
  items_disc AS (
    SELECT i.*,
      COALESCE(f.disc_factor, 0) AS disc_factor,
      i.discounts * COALESCE(f.disc_factor, 0) AS discounts_attr
    FROM scoped_items i
    LEFT JOIN item_disc_factor f ON f.id = i.id
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
      -- 20260914_0001: descuento ATRIBUIDO al rango (ver item_disc_factor).
      ROUND(COALESCE(SUM(discounts_attr), 0), 2) AS discounts_total,
      COUNT(*) FILTER (WHERE discounts > 0 AND disc_factor > 0) AS discounted_lines_count,
      COUNT(*) FILTER (
        WHERE disc_factor > 0
          AND (notes LIKE '%[CORTESIA:%'
            OR (gross_amount > 0 AND discounts >= gross_amount - 0.01))
      ) AS courtesy_lines_count,
      ROUND(COALESCE(SUM(discounts_attr) FILTER (
        WHERE notes LIKE '%[CORTESIA:%'
           OR (gross_amount > 0 AND discounts >= gross_amount - 0.01)
      ), 0), 2) AS courtesy_total
    FROM items_disc
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
      COALESCE(SUM(qty), 0) AS quantity, COUNT(*) AS count,
      -- RF-R1: costo de la categoría = Σ(cantidad × costo unitario).
      COALESCE(SUM(qty * unit_cost), 0) AS cost_total
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
      -- 20260914_0001: descuento ATRIBUIDO al rango (ver item_disc_factor);
      -- gross_sales - discounts - courtesies = net_sales sigue cuadrando.
      -- COALESCE(notes, ''): con notes NULL el NOT (NULL LIKE …) daba NULL y
      -- el FILTER descartaba la línea → discounts por producto salía en 0.
      ROUND(COALESCE(SUM(ia.adjusted_amount
        + ia.discounts * COALESCE(df.disc_factor, 0)), 0), 2) AS gross_sales,
      ROUND(COALESCE(SUM(ia.discounts * COALESCE(df.disc_factor, 0)) FILTER (
        WHERE NOT (
          COALESCE(ia.notes, '') LIKE '%[CORTESIA:%'
          OR (ia.gross_amount > 0 AND ia.discounts >= ia.gross_amount - 0.01)
        )
      ), 0), 2) AS discounts,
      ROUND(COALESCE(SUM(ia.discounts * COALESCE(df.disc_factor, 0)) FILTER (
        WHERE
          COALESCE(ia.notes, '') LIKE '%[CORTESIA:%'
          OR (ia.gross_amount > 0 AND ia.discounts >= ia.gross_amount - 0.01)
      ), 0), 2) AS courtesies,
      COALESCE(SUM(ia.adjusted_amount), 0) AS net_sales,
      -- RF-R1: costo del producto = Σ(cantidad × costo unitario).
      COALESCE(SUM(ia.qty * ia.unit_cost), 0) AS cost_total,
      COUNT(DISTINCT ia.order_id) AS tickets
    FROM items_adjusted ia
    LEFT JOIN item_disc_factor df ON df.id = ia.id
    GROUP BY ia.product_id
  ),
  orders_total_sum AS (
    SELECT COALESCE(SUM(order_total), 0) AS sum_orders FROM order_ctx
  ),
  -- RF-R1: costo total agregado, base para márgenes de cabecera.
  cost_totals AS (
    SELECT COALESCE(SUM(cost_total), 0) AS total_cost FROM product_sales_agg
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
    -- RF-R1: totales de rentabilidad para metric cards.
    'total_cost', (SELECT total_cost FROM cost_totals),
    'gross_profit_total',
      (SELECT total_sales FROM totals) - (SELECT total_cost FROM cost_totals),
    'margin_pct_total', CASE WHEN (SELECT total_sales FROM totals) <= 0 THEN NULL
      ELSE round((((SELECT total_sales FROM totals) - (SELECT total_cost FROM cost_totals))
        / (SELECT total_sales FROM totals)) * 100, 2) END,
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
        'quantity', quantity, 'count', count,
        'cost', cost_total,
        'gross_profit', amount - cost_total,
        'margin_pct', CASE WHEN amount <= 0 THEN NULL
          ELSE round(((amount - cost_total) / amount) * 100, 2) END)
        ORDER BY amount DESC) FROM by_category), '[]'::jsonb),
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
        'cost',          cost_total,
        'gross_profit',  net_sales - cost_total,
        'margin_pct',    CASE WHEN net_sales <= 0 THEN NULL
          ELSE round(((net_sales - cost_total) / net_sales) * 100, 2) END,
        'tickets',       tickets
      ) ORDER BY net_sales DESC)
      FROM product_sales_agg), '[]'::jsonb)
  ) INTO result;

  RETURN result;
END;
$function$;

COMMIT;
