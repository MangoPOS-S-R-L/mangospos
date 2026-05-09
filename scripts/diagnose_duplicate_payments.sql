-- =============================================================================
-- Diagnostico de payments duplicados
--
-- Sintoma: en "Historial de venta" aparecen 2 rows misma hora/monto/mesero,
-- una como "Boleta/Ticket/Publico General" y otra con NCF B02 + cliente real.
--
-- Hipotesis:
--   1) 2 payments insertados para la MISMA order_id  -> trigger ya tiene
--      idempotencia, no duplica fiscal_documents pero se muestran 2 rows.
--   2) 2 orders distintas creadas para la misma venta -> race en openTable.
--   3) Reimpresion crea payment fantasma.
--
-- Como correrlo: SQL editor de Supabase. Ajusta los timestamps en cada query
-- si la ventana cambia. Comparte el output de las 4 queries.
--
-- Nota: Supabase SQL editor NO soporta meta-comandos de psql (\set),
-- por eso las fechas estan inline en cada query.
-- =============================================================================

-- ── 1. Payments crudos en la ventana, con su fiscal_document si existe ─────
SELECT
  p.id                AS payment_id,
  p.order_id,
  p.check_id,
  p.amount,
  p.status,
  p.created_at,
  p.session_id,
  p.fiscal_document_id,           -- back-ref que el listado de UI no embebe
  fd.id                AS fd_id,
  fd.payment_id        AS fd_payment_id,
  fd.ncf_number,
  fd.ncf_type,
  fd.customer_name     AS fd_customer_name,
  fd.status            AS fd_status,
  fd.created_at        AS fd_created_at,
  o.session_id         AS order_session_id,
  ts.business_id
FROM public.payments p
LEFT JOIN public.fiscal_documents fd ON fd.payment_id = p.id
LEFT JOIN public.orders o ON o.id = p.order_id
LEFT JOIN public.table_sessions ts ON ts.id = o.session_id
WHERE p.created_at >= '2026-05-08 21:55:00-04'::timestamptz
  AND p.created_at <  '2026-05-08 22:10:00-04'::timestamptz
  AND p.status IN ('completed', 'void', 'cancelled')
ORDER BY p.created_at ASC;

-- ── 2. Detectar payments DUPLICADOS por order_id en la ventana ─────────────
-- Si una sola order_id tiene >1 payment activo en pocos segundos, es la causa.
SELECT
  p.order_id,
  count(*)                                       AS n_payments,
  array_agg(p.id          ORDER BY p.created_at) AS payment_ids,
  array_agg(p.amount      ORDER BY p.created_at) AS amounts,
  array_agg(p.created_at  ORDER BY p.created_at) AS created_ats,
  max(p.created_at) - min(p.created_at)          AS spread,
  array_agg(p.fiscal_document_id
              ORDER BY p.created_at)             AS fd_back_refs
FROM public.payments p
WHERE p.created_at >= '2026-05-08 21:55:00-04'::timestamptz
  AND p.created_at <  '2026-05-08 22:10:00-04'::timestamptz
  AND p.status = 'completed'
GROUP BY p.order_id
HAVING count(*) > 1
ORDER BY max(p.created_at) DESC;

-- ── 3. Detectar orders DUPLICADAS por session_id (mesa) ────────────────────
-- Si una mesa tiene >1 orden en la misma sesion con totales iguales y
-- creadas en pocos segundos, hay race en openTable.
SELECT
  o.session_id,
  count(*)                                            AS n_orders,
  array_agg(o.id              ORDER BY o.created_at)  AS order_ids,
  array_agg(o.total           ORDER BY o.created_at)  AS totals,
  array_agg(o.status_ext::text ORDER BY o.created_at) AS statuses,
  array_agg(o.created_at      ORDER BY o.created_at)  AS created_ats,
  max(o.created_at) - min(o.created_at)               AS spread
FROM public.orders o
WHERE o.created_at >= '2026-05-08 20:55:00-04'::timestamptz  -- 1 hora antes
  AND o.created_at <  '2026-05-08 22:10:00-04'::timestamptz
GROUP BY o.session_id
HAVING count(*) > 1
ORDER BY max(o.created_at) DESC
LIMIT 20;

-- ── 4. Trigger trg_issue_fiscal: confirma que esta instalado y unico ──────
SELECT
  tgname,
  tgrelid::regclass     AS on_table,
  tgenabled,
  pg_get_triggerdef(oid) AS definition
FROM pg_trigger
WHERE (tgname ILIKE '%fiscal%' OR tgname ILIKE '%payment%')
  AND NOT tgisinternal
ORDER BY tgname;
