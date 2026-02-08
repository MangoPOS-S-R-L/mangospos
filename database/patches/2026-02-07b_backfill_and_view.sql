-- Paso 2: backfill y vista filtrando líneas pagadas/void
-- Ejecutar SOLO después de aplicar 2026-02-07a_add_paid_enum_and_columns.sql
-- Fecha: 2026-02-07

-- Backfill: marcar líneas pagadas donde la orden o subcuenta ya estaba cerrada
UPDATE public.order_items oi
SET status = 'paid'
FROM public.orders o
WHERE oi.order_id = o.id
  AND o.status_ext = 'paid'
  AND oi.status <> 'void';

UPDATE public.order_items oi
SET status = 'paid'
FROM public.order_checks oc
WHERE oi.check_id = oc.id
  AND oc.is_closed = true
  AND oi.status <> 'void';

UPDATE public.order_checks
SET closed_at = COALESCE(closed_at, NOW())
WHERE is_closed = true;

-- Vista de estado de mesas filtrando líneas pagadas/void
CREATE OR REPLACE VIEW public.v_zone_table_status AS
SELECT
  t.id AS table_id,
  z.id AS zone_id,
  z.name AS zone_name,
  z.business_id,
  t.code,
  t.label,
  t.shape,
  t.capacity,
  t.state,
  s.id AS session_id,
  s.opened_by,
  s.opened_at,
  CASE
    WHEN (s.opened_at IS NOT NULL AND s.closed_at IS NULL)
      THEN (EXTRACT(EPOCH FROM (NOW() - s.opened_at))::INT / 60)
    ELSE NULL::INT
  END AS minutes_open,
  COALESCE((
    SELECT COUNT(*)
    FROM public.orders o
    WHERE o.session_id = s.id
      AND o.closed_at IS NULL
      AND o.status_ext NOT IN ('paid','void')
  ), 0)::BIGINT AS orders_count,
  s.people_count,
  COALESCE((
    SELECT SUM(oi.subtotal + oi.tax - oi.discounts)
    FROM public.orders o
    JOIN public.order_items oi ON oi.order_id = o.id
    WHERE o.session_id = s.id
      AND o.closed_at IS NULL
      AND o.status_ext NOT IN ('paid','void')
      AND oi.status <> ALL (ARRAY['paid'::item_status,'void'::item_status])
  ), 0)::NUMERIC AS total,
  COALESCE((
    SELECT COUNT(*)
    FROM public.order_items oi
    JOIN public.orders o2 ON oi.order_id = o2.id
    WHERE o2.session_id = s.id
      AND o2.closed_at IS NULL
      AND o2.status_ext NOT IN ('paid','void')
      AND oi.status <> ALL (ARRAY['paid'::item_status,'void'::item_status])
  ), 0)::BIGINT AS items_count
FROM public.dining_tables t
JOIN public.zones z ON z.id = t.zone_id
LEFT JOIN LATERAL (
  SELECT s2.id,
         s2.table_id,
         s2.opened_by,
         s2.opened_at,
         s2.closed_at,
         s2.customer_name,
         s2.note,
         s2.origin,
         s2.waiter_user_id,
         s2.people_count,
         s2.business_id
  FROM public.table_sessions s2
  WHERE s2.table_id = t.id
    AND s2.closed_at IS NULL
  ORDER BY s2.opened_at DESC
  LIMIT 1
) s ON TRUE;
