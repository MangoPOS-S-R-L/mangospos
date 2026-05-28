-- =============================================================================
-- Fix view `kds_active_items`: exponer el `area_code` real del order_item.
--
-- Antes el view tenía `NULL::text AS area_code` (placeholder hardcoded), lo
-- que rompía cualquier filtro por área en el KDS — todos los items quedaban
-- sin área asignada visible para el cliente.
--
-- Ahora pasamos directamente `oi.print_area_code` (que ya existe en
-- order_items, ver migration 20260508_0001_print_area_code_nullable.sql)
-- + traemos el `name` legible desde print_areas mediante LEFT JOIN.
--
-- Filtros client-side ("ver solo cocina", "ver solo bar") se hacen ahora
-- en Dart con el campo `area_code`/`area_name`.
--
-- ORDEN DE COLUMNAS — IMPORTANTE:
-- `CREATE OR REPLACE VIEW` en PostgreSQL solo permite APPEND de columnas
-- al final; no permite renombrar/reordenar existentes (error 42P16).
-- El view anterior (ver rollback file) tenía 15 columnas terminando en
-- `area_code` (NULL::text) en posición 14 y `modifiers` en 15.
-- Preservamos ese orden:
--   1..13   = mismas columnas (id … business_id)
--   14      = area_code  (ahora con valor real, mismo tipo `text`)
--   15      = modifiers
--   16..17  = is_takeout, area_name  ← columnas NUEVAS al final
-- =============================================================================

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
  -- Posición 14 (preserva ubicación del view anterior). Antes: NULL::text.
  -- Ahora: el código real del area asignada al item. Mismo tipo `text`,
  -- así que CREATE OR REPLACE acepta el cambio de expresión.
  oi.print_area_code AS area_code,
  -- Posición 15 (preservada).
  COALESCE(mods.modifiers, '[]'::json) AS modifiers,
  -- Columnas NUEVAS — agregadas al final para que CREATE OR REPLACE VIEW
  -- funcione sin tener que dropear el view existente.
  oi.is_takeout,
  -- Nombre legible del área para mostrarlo en el dropdown de filtro y en
  -- la card del KDS. NULL si el item no tiene área asignada todavía.
  pa.name AS area_name
FROM public.order_items oi
JOIN public.orders o          ON o.id = oi.order_id
JOIN public.table_sessions ts ON ts.id = o.session_id
LEFT JOIN public.dining_tables dt ON dt.id = ts.table_id
LEFT JOIN public.zones z          ON z.id = dt.zone_id
LEFT JOIN public.profiles p       ON p.id = ts.waiter_user_id
-- Join opcional al print_areas del business para obtener el nombre legible.
-- business_id viene de `z` (que sale del LEFT JOIN — puede ser NULL para
-- ventas manuales/quick sin mesa). En esos casos el area_name queda NULL
-- pero area_code igual viaja desde oi.
LEFT JOIN public.print_areas pa
       ON pa.code = oi.print_area_code
      AND pa.business_id = z.business_id
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
