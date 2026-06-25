-- ============================================================================
-- Inspección orden e354f25f-0cfb-4aaa-a0c9-7cbe4763a23d  (NCF B0200070797)
-- Negocio: 1/2 Tiempo SRL (33207ebd-985d-455c-bdbb-1b38af8b36ea)
-- Síntoma: papel imprime TOTAL 750 (3 coronas) pero el cambio (2000-1500=500)
--          y el fiscal_document dicen 500 (2 coronas). ¿Oferta 3x2 oculta o
--          sub-cobro real?
-- ============================================================================

\set oid 'e354f25f-0cfb-4aaa-a0c9-7cbe4763a23d'

-- ─── 1. fiscal_document vs orders (¿coinciden los totales?) ─────────────────
SELECT
  fd.ncf_number,
  fd.subtotal      AS fd_sub,
  fd.itbis_amount  AS fd_itbis,
  fd.service_fee   AS fd_sf,
  fd.total         AS fd_total,
  fd.issued_at,
  o.subtotal       AS ord_sub,
  o.tax            AS ord_tax,
  o.service_fee    AS ord_sf,
  o.discounts      AS ord_disc,
  o.total          AS ord_total,
  o.status_ext,
  o.created_at     AS ord_created,
  o.closed_at      AS ord_closed
FROM public.orders o
LEFT JOIN public.fiscal_documents fd ON fd.order_id = o.id
WHERE o.id = :'oid';

-- ─── 2. TODAS las líneas, incl. ocultas (PROMO_AUTO/CORTESIA/DEAL) ──────────
--      Si hay una oferta 3x2, aquí debe aparecer una línea extra con
--      discounts ≈ precio de 1 corona y/o total negativo, y un marcador en
--      notes. Ordenadas por creación para ver qué se agregó después.
SELECT
  oi.created_at,
  oi.status,
  oi.product_name,
  oi.qty,
  oi.unit_price,
  oi.subtotal,
  oi.discounts,
  oi.tax,
  oi.total,
  oi.tax_rate,
  oi.tax_mode,
  oi.promotion_id,
  oi.check_id,
  oi.notes
FROM public.order_items oi
WHERE oi.order_id = :'oid'
ORDER BY oi.created_at;

-- ─── 3. Suma de líneas activas (¿neto 500 o 750?) ──────────────────────────
SELECT
  COUNT(*)            AS n_lineas,
  SUM(oi.qty)         AS sum_qty,
  SUM(oi.subtotal)    AS sum_sub,
  SUM(oi.discounts)   AS sum_disc,
  SUM(oi.tax)         AS sum_tax,
  SUM(oi.total)       AS sum_total
FROM public.order_items oi
WHERE oi.order_id = :'oid'
  AND oi.status <> 'void';

-- ─── 4. Pagos (monto cobrado real + cambio) ────────────────────────────────
--      change_amount confirma qué total usó la caja: 2000-1500=500.
SELECT
  p.created_at,
  p.amount,
  p.change_amount,
  p.status,
  p.payment_method_id,
  p.fiscal_document_id,
  p.check_id
FROM public.payments p
WHERE p.order_id = :'oid'
ORDER BY p.created_at;

-- ─── 5. Ofertas activas del negocio que puedan tocar Corona ────────────────
--      ¿Existe un BOGO / 3x2 configurado para Cervezas o Corona Extra?
SELECT *
FROM public.promotions
WHERE business_id = '33207ebd-985d-455c-bdbb-1b38af8b36ea'
ORDER BY created_at DESC;
