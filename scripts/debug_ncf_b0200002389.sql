-- ============================================================================
-- Diagnóstico de NCF B0200002389: por qué salió sin ITBIS
-- ============================================================================
-- Cuatro bloques: doc fiscal, orden, items con tax info, config de impuestos.
-- Cambia el NCF al final de la línea de WHERE en el primer SELECT si quieres
-- diagnosticar otro comprobante.
-- ============================================================================

-- ─── 1. Documento fiscal ─────────────────────────────────────────────────
SELECT
  fd.id            AS doc_id,
  fd.ncf_number,
  fd.ncf_type,
  fd.order_id,
  fd.payment_id,
  fd.subtotal,
  fd.itbis_amount,
  fd.service_fee,
  fd.total,
  fd.status,
  fd.issued_at
FROM public.fiscal_documents fd
WHERE fd.ncf_number = 'B0200002389';
-- ↑ Anota el order_id. Si no aparece, el NCF no existe.

-- ─── 2. Orden ────────────────────────────────────────────────────────────
SELECT
  o.id            AS order_id,
  o.subtotal,
  o.tax           AS order_tax,
  o.service_fee   AS order_service_fee,
  o.discounts,
  o.total         AS order_total,
  o.status_ext,
  o.closed_at,
  ts.origin       AS session_origin,
  ts.business_id
FROM public.orders o
JOIN public.table_sessions ts ON ts.id = o.session_id
WHERE o.id = (
  SELECT order_id FROM public.fiscal_documents
  WHERE ncf_number = 'B0200002389'
);

-- ─── 3. Items con su info de impuestos y producto ───────────────────────
-- Para cada item: subtotal, tax, tax_rate, tax_mode, is_takeout,
-- nombre del producto, su tax_mode configurado y la categoría.
SELECT
  oi.id              AS item_id,
  oi.product_name,
  oi.qty,
  oi.unit_price,
  oi.subtotal,
  oi.tax,
  oi.tax_rate,
  oi.original_tax_rate,
  oi.tax_mode,
  oi.is_takeout,
  oi.status          AS item_status,
  oi.discounts,
  oi.total,
  mi.id              AS menu_item_id,
  mi.tax_mode        AS menu_tax_mode,
  mi.effective_tax_rate AS menu_effective_rate,
  c.name             AS category_name
FROM public.order_items oi
LEFT JOIN public.menu_items mi ON mi.id = oi.product_id
LEFT JOIN public.menu_categories c ON c.id = mi.category_id
WHERE oi.order_id = (
  SELECT order_id FROM public.fiscal_documents
  WHERE ncf_number = 'B0200002389'
)
ORDER BY oi.created_at;

-- ─── 4. Config de impuestos activos en el negocio ───────────────────────
-- Para entender qué taxes deberían aplicar y por qué los items
-- pueden haber salido sin ITBIS.
SELECT
  t.id,
  t.name,
  t.rate,
  t.is_active,
  t.is_service_fee,
  t.apply_on_zone,
  t.apply_on_manual,
  t.apply_on_quick,
  t.apply_on_delivery,
  -- apply_on_takeout puede no existir si la migración 20260502 no se corrió
  (CASE
    WHEN EXISTS (
      SELECT 1 FROM information_schema.columns
      WHERE table_schema = 'public' AND table_name = 'taxes'
        AND column_name = 'apply_on_takeout'
    ) THEN to_jsonb(t)->>'apply_on_takeout'
    ELSE 'col_no_existe'
  END) AS apply_on_takeout
FROM public.taxes t
WHERE t.business_id = (
  SELECT ts.business_id
  FROM public.fiscal_documents fd
  JOIN public.orders o ON o.id = fd.order_id
  JOIN public.table_sessions ts ON ts.id = o.session_id
  WHERE fd.ncf_number = 'B0200002389'
)
ORDER BY t.is_active DESC, t.is_service_fee, t.rate DESC;

-- ─── 5. Diagnóstico rápido ───────────────────────────────────────────────
-- Resumen one-liner: cuánto debería haber pagado el comprobante
-- según los items, comparado con lo que tiene el doc.
WITH tgt AS (
  SELECT order_id, subtotal AS doc_sub, itbis_amount AS doc_itbis,
         service_fee AS doc_sf, total AS doc_total
  FROM public.fiscal_documents WHERE ncf_number = 'B0200002389'
)
SELECT
  tgt.doc_sub,
  tgt.doc_itbis,
  tgt.doc_sf,
  tgt.doc_total,
  COALESCE(SUM(oi.subtotal), 0)   AS items_sub,
  COALESCE(SUM(oi.tax), 0)        AS items_tax_sum,
  COALESCE(SUM(CASE WHEN oi.tax_rate > 0 THEN oi.subtotal ELSE 0 END), 0) AS taxable_sub,
  COALESCE(SUM(CASE WHEN oi.tax_rate = 0 THEN oi.subtotal ELSE 0 END), 0) AS exempt_sub,
  COUNT(oi.*)                     AS item_count,
  COUNT(oi.*) FILTER (WHERE oi.is_takeout = true) AS takeout_items,
  COUNT(oi.*) FILTER (WHERE oi.tax_rate = 0)      AS items_zero_tax
FROM tgt
LEFT JOIN public.order_items oi ON oi.order_id = tgt.order_id
  AND oi.status IS DISTINCT FROM 'void'::public.item_status
GROUP BY tgt.doc_sub, tgt.doc_itbis, tgt.doc_sf, tgt.doc_total;


UPDATE public.taxes
SET apply_on_takeout = false
WHERE id = '0f9b4a54-e4f6-45a0-b25b-99b405d83c65';  -- LEY
