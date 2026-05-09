-- ============================================================================
-- Auditoría de productos del business 38a0dfd6-f342-4e8c-b9d6-daf9e07d60da
-- ============================================================================
-- Bloque 0: descubrir qué columnas existen en menu_items.
-- Después corre el bloque 1 (productos) usando solo las columnas reales.
-- ============================================================================

-- ─── Bloque 0: columnas reales de menu_items ─────────────────────────────
SELECT column_name, data_type
FROM information_schema.columns
WHERE table_schema = 'public' AND table_name = 'menu_items'
ORDER BY ordinal_position;

-- ─── Bloque 1: Productos con tax_mode + impuestos asignados ─────────────
-- Solo usa columnas que existen seguro. Quitamos effective_tax_rate.
SELECT
  mi.id,
  mi.name                                                AS product_name,
  c.name                                                 AS category_name,
  mi.tax_mode,
  mi.is_active,
  mi.price,
  -- Lista compacta de impuestos asignados explícitamente al producto.
  -- NULL/vacío → el producto cae al fallback global (config del business).
  (SELECT string_agg(
            t.name || ' (' || t.rate || '%' ||
            CASE WHEN t.is_service_fee THEN ', sf' ELSE '' END ||
            CASE WHEN NOT COALESCE(t.is_active, true) THEN ', INACTIVO' ELSE '' END ||
            ')',
            ', ' ORDER BY t.is_service_fee, t.rate DESC)
     FROM public.menu_item_taxes mit
     JOIN public.taxes t ON t.id = mit.tax_id
    WHERE mit.item_id = mi.id) AS taxes_asignados,
  -- Diagnóstico rápido
  CASE
    WHEN NOT EXISTS (
      SELECT 1 FROM public.menu_item_taxes mit
      WHERE mit.item_id = mi.id
    ) THEN '(fallback global)'
    WHEN EXISTS (
      SELECT 1 FROM public.menu_item_taxes mit
      JOIN public.taxes t ON t.id = mit.tax_id
      WHERE mit.item_id = mi.id
        AND COALESCE(t.is_active, true)
        AND COALESCE(t.is_service_fee, false) = false
        AND t.rate >= 18
    ) THEN 'paga ITBIS'
    ELSE 'EXENTO de ITBIS'
  END AS diagnostico_itbis
FROM public.menu_items mi
LEFT JOIN public.categories c ON c.id = mi.category_id
WHERE mi.business_id = '38a0dfd6-f342-4e8c-b9d6-daf9e07d60da'
ORDER BY
  (CASE WHEN mi.tax_mode IS NULL THEN 0 ELSE 1 END),
  c.name NULLS LAST,
  mi.name;

-- ─── Bloque 2: Resumen agregado por categoría ───────────────────────────
SELECT
  COALESCE(c.name, '(sin categoría)') AS category,
  COUNT(*) AS total_products,
  COUNT(*) FILTER (WHERE mi.tax_mode = 'inclusive')  AS inclusive,
  COUNT(*) FILTER (WHERE mi.tax_mode = 'exclusive')  AS exclusive,
  COUNT(*) FILTER (WHERE mi.tax_mode IS NULL)        AS sin_modo,
  COUNT(*) FILTER (
    WHERE NOT EXISTS (
      SELECT 1 FROM public.menu_item_taxes mit
      WHERE mit.item_id = mi.id
    )
  ) AS sin_tax_asignado
FROM public.menu_items mi
LEFT JOIN public.categories c ON c.id = mi.category_id
WHERE mi.business_id = '38a0dfd6-f342-4e8c-b9d6-daf9e07d60da'
GROUP BY c.name
ORDER BY total_products DESC;

-- ─── Bloque 3: Producto del NCF B0200002389 ─────────────────────────────
-- Puntual: solo el item de esa orden.
SELECT
  oi.product_name,
  oi.subtotal,
  oi.tax,
  oi.tax_rate,
  oi.tax_mode      AS item_mode,
  oi.is_takeout,
  mi.id            AS menu_item_id,
  mi.tax_mode      AS menu_mode,
  c.name           AS category,
  (SELECT string_agg(
            t.name || ' (' || t.rate || '%' ||
            CASE WHEN t.is_service_fee THEN ', sf' ELSE '' END || ')',
            ', ')
     FROM public.menu_item_taxes mit
     JOIN public.taxes t ON t.id = mit.tax_id
    WHERE mit.item_id = mi.id
      AND COALESCE(t.is_active, true)) AS taxes_asignados
FROM public.order_items oi
LEFT JOIN public.menu_items mi ON mi.id = oi.product_id
LEFT JOIN public.categories c ON c.id = mi.category_id
WHERE oi.order_id = (
  SELECT order_id FROM public.fiscal_documents
  WHERE ncf_number = 'B0200002389'
);
