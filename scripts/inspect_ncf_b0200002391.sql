-- ============================================================================
-- Inspección detallada de NCF B0200002391
-- ============================================================================
-- 6 items, 2 con ITBIS, 4 sin → ¿por qué quedó así?
-- ============================================================================

-- ─── 1. Snapshot del documento + orden ──────────────────────────────────
SELECT
  fd.ncf_number,
  fd.subtotal      AS doc_sub,
  fd.itbis_amount  AS doc_itbis,
  fd.service_fee   AS doc_sf,
  fd.total         AS doc_total,
  fd.issued_at,
  o.subtotal       AS ord_sub,
  o.tax            AS ord_tax,
  o.service_fee    AS ord_sf,
  o.discounts      AS ord_disc,
  o.total          AS ord_total,
  o.status_ext,
  o.created_at     AS ord_created,
  o.closed_at      AS ord_closed,
  ts.origin        AS session_origin
FROM public.fiscal_documents fd
JOIN public.orders o ON o.id = fd.order_id
JOIN public.table_sessions ts ON ts.id = o.session_id
WHERE fd.ncf_number = 'B0200002391';

-- ─── 2. Cada item con precio configurado y taxes asignados ─────────────
SELECT
  oi.id              AS item_id,
  oi.product_name,
  c.name             AS category,
  oi.qty,
  oi.unit_price      AS unit_price_paid,
  mi.price           AS product_price_now,
  oi.subtotal        AS item_sub,
  oi.tax             AS item_tax,
  oi.tax_rate        AS item_rate,
  oi.original_tax_rate AS item_orig_rate,
  oi.tax_mode        AS item_mode,
  oi.is_takeout,
  oi.discounts       AS item_disc,
  oi.total           AS item_total,
  oi.status,
  oi.created_at      AS item_created,
  -- Lo que debería pagar según config actual del producto
  (SELECT string_agg(
            t.name || ' (' || t.rate || '%' ||
            CASE WHEN t.is_service_fee THEN ', sf' ELSE '' END || ')',
            ', ' ORDER BY t.is_service_fee, t.rate DESC)
     FROM public.menu_item_taxes mit
     JOIN public.taxes t ON t.id = mit.tax_id
    WHERE mit.item_id = mi.id
      AND COALESCE(t.is_active, true)) AS taxes_configurados,
  -- ¿Es takeout? Si sí, por config el ITBIS y/o LEY pueden no aplicar
  (SELECT COALESCE(bool_or(
       (oi.is_takeout = true AND COALESCE(t.apply_on_takeout, true) = false)
     ), false)
     FROM public.menu_item_taxes mit
     JOIN public.taxes t ON t.id = mit.tax_id
    WHERE mit.item_id = mi.id
      AND COALESCE(t.is_active, true)) AS takeout_filter_applied,
  -- Diagnóstico
  CASE
    WHEN oi.tax_rate = 18 THEN 'OK: paga ITBIS 18%'
    WHEN oi.tax_rate = 0 AND mi.id IS NULL THEN 'producto borrado del menú'
    WHEN oi.tax_rate = 0 AND NOT EXISTS (
      SELECT 1 FROM public.menu_item_taxes mit
      JOIN public.taxes t ON t.id = mit.tax_id
      WHERE mit.item_id = mi.id
        AND COALESCE(t.is_active, true)
        AND COALESCE(t.is_service_fee, false) = false
    ) THEN 'producto SIN ITBIS asignado en config'
    WHEN oi.tax_rate = 0 THEN 'item SIN ITBIS pero producto SÍ tiene config — sospechoso'
    ELSE 'rate inesperado: ' || oi.tax_rate::text
  END AS diagnostico
FROM public.order_items oi
LEFT JOIN public.menu_items mi ON mi.id = oi.product_id
LEFT JOIN public.categories c ON c.id = mi.category_id
WHERE oi.order_id = (
  SELECT order_id FROM public.fiscal_documents WHERE ncf_number = 'B0200002391'
)
ORDER BY oi.created_at;

-- ─── 3. Reconciliación de la math actual ───────────────────────────────
SELECT
  SUM(oi.subtotal)                                                   AS sum_subtotal,
  SUM(oi.tax)                                                        AS sum_tax,
  SUM(oi.subtotal) FILTER (WHERE oi.tax_rate = 18)                   AS sub_taxable,
  SUM(oi.subtotal) FILTER (WHERE oi.tax_rate = 0)                    AS sub_exempt,
  COUNT(*)                                                           AS items_total,
  COUNT(*) FILTER (WHERE oi.tax_rate = 18)                           AS items_with_itbis,
  COUNT(*) FILTER (WHERE oi.tax_rate = 0)                            AS items_zero_tax,
  COUNT(*) FILTER (WHERE oi.is_takeout = true)                       AS items_takeout
FROM public.order_items oi
WHERE oi.order_id = (
  SELECT order_id FROM public.fiscal_documents WHERE ncf_number = 'B0200002391'
)
  AND oi.status IS DISTINCT FROM 'void'::public.item_status;
