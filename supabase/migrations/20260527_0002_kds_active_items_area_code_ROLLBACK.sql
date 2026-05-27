-- Rollback de 20260527_0002_kds_active_items_area_code.sql
-- Restaura el view con `area_code = NULL` y sin `area_name` ni `is_takeout`.

CREATE OR REPLACE VIEW public.kds_active_items WITH (security_invoker = on) AS
SELECT
  oi.id,
  oi.order_id,
  LEFT(oi.order_id::text, 8) AS order_number,
  oi.product_name,
  COALESCE(oi.quantity::numeric, oi.qty, 1::numeric) AS quantity,
  oi.notes,
  oi.status,
  oi.created_at,
  oi.started_at,
  oi.ready_at,
  CASE
    WHEN dt.id IS NOT NULL THEN COALESCE(dt.label, dt.code, 'Mesa')
    WHEN ts.origin = 'manual'::public.order_origin THEN 'Venta manual'
    WHEN ts.origin = 'quick'::public.order_origin  THEN 'Venta rapida'
    ELSE 'Venta'
  END AS table_name,
  p.full_name AS waiter_name,
  z.business_id,
  NULL::text AS area_code,
  COALESCE(mods.modifiers, '[]'::json) AS modifiers
FROM public.order_items oi
JOIN public.orders o          ON o.id = oi.order_id
JOIN public.table_sessions ts ON ts.id = o.session_id
LEFT JOIN public.dining_tables dt ON dt.id = ts.table_id
LEFT JOIN public.zones z          ON z.id = dt.zone_id
LEFT JOIN public.profiles p       ON p.id = ts.waiter_user_id
LEFT JOIN LATERAL (
  SELECT json_agg(json_build_object('id', m.id, 'name', m.name, 'quantity', m.qty)) AS modifiers
  FROM public.order_item_modifiers m
  WHERE m.item_id = oi.id
) mods ON true
WHERE oi.status = ANY (ARRAY[
  'pending'::public.item_status,
  'preparing'::public.item_status,
  'ready'::public.item_status
]);
