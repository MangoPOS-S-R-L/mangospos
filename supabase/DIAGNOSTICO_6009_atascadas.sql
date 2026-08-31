-- =====================================================================
-- ¿POR QUE 6,009 ordenes cobradas quedaron en 'sent_to_kitchen'?
-- Negocio f054fbc2
--
-- HIPOTESIS: `fn_confirm_order_to_kitchen` pone status_ext='sent_to_kitchen'
-- y status='sent' SIN mirar si la orden ya esta pagada/cerrada. Si algo
-- manda a cocina DESPUES del cobro, pisa el 'paid' que dejo
-- fn_close_order_and_table. Los dos llamadores de sendToKitchen son:
--   (a) printing_service.sendOrderToKitchen  -> "Enviar a cocina" normal
--   (b) offline_pos_service, replay de 'confirm_local_order' -> LA COLA
-- La prueba es el ORDEN DE LOS RELOJES: si order_items.kitchen_sent_at
-- es POSTERIOR al pago, la cocina corrio despues del cobro.
--
-- UNA sola ejecucion -> un solo resultado.
-- =====================================================================

WITH biz AS (SELECT 'f054fbc2-3fb7-4e34-a020-11341ff11d84'::uuid AS id),

base AS (
  SELECT
    o.id,
    o.created_at,
    o.closed_at,
    o.status        AS status_legacy,
    o.status_ext,
    (SELECT min(p.created_at) FROM public.payments p
      WHERE p.order_id = o.id AND p.status = 'completed')      AS t_pago,
    (SELECT max(i.kitchen_sent_at) FROM public.order_items i
      WHERE i.order_id = o.id)                                 AS t_cocina,
    (SELECT count(*) FROM public.order_items i
      WHERE i.order_id = o.id AND i.status::text = 'paid')     AS items_paid,
    (SELECT count(*) FROM public.order_items i
      WHERE i.order_id = o.id
        AND i.status::text NOT IN ('paid','void'))             AS items_abiertos
  FROM public.orders o
  JOIN public.table_sessions ts ON ts.id = o.session_id
  JOIN public.dining_tables dt  ON dt.id = ts.table_id
  JOIN public.zones z           ON z.id  = dt.zone_id, biz
  WHERE z.business_id = biz.id
    AND o.status_ext = 'sent_to_kitchen'
    AND EXISTS (SELECT 1 FROM public.payments p
                  WHERE p.order_id = o.id AND p.status = 'completed')
),

-- 1) EL RELOJ: ¿la cocina corrio antes o despues del cobro?
reloj AS (
  SELECT
    CASE
      WHEN t_cocina IS NULL              THEN 'sin kitchen_sent_at'
      WHEN t_cocina > t_pago             THEN 'COCINA DESPUES DEL PAGO'
      WHEN t_cocina <= t_pago            THEN 'cocina antes del pago (normal)'
    END AS veredicto,
    count(*)::int AS ordenes,
    round(avg(extract(epoch FROM (t_cocina - t_pago))/60)::numeric, 1) AS min_promedio_despues,
    round(max(extract(epoch FROM (t_cocina - t_pago))/60)::numeric, 1) AS min_max_despues,
    min(created_at) AS mas_vieja,
    max(created_at) AS mas_nueva
  FROM base
  GROUP BY 1
),
s1 AS (
  SELECT coalesce(jsonb_agg(to_jsonb(r) ORDER BY r.ordenes DESC), '[]'::jsonb) AS d
  FROM reloj r
),

-- 2) LA FIRMA DEL PISOTON: fn_confirm_order_to_kitchen escribe
--    status='sent' + status_ext='sent_to_kitchen' y NO toca closed_at.
--    fn_close_order_and_table escribe status='paid' + closed_at.
--    Si vemos closed_at PUESTO con status='sent', la cocina llego despues.
firma AS (
  SELECT status_legacy,
         (closed_at IS NOT NULL) AS tiene_closed_at,
         (items_abiertos = 0)    AS todos_los_items_paid,
         count(*)::int           AS ordenes,
         min(created_at)         AS mas_vieja,
         max(created_at)         AS mas_nueva
  FROM base
  GROUP BY status_legacy, (closed_at IS NOT NULL), (items_abiertos = 0)
),
s2 AS (
  SELECT coalesce(jsonb_agg(to_jsonb(f) ORDER BY f.ordenes DESC), '[]'::jsonb) AS d
  FROM firma f
),

-- 3) ¿INVENTARIO DOBLE? consume_inventory_from_order es idempotente
--    (inserta expected - ya_consumido). Verificamos que de verdad no
--    haya movimientos 'sale' duplicados por orden+item.
dup AS (
  SELECT im.reference_id, im.item_id, count(*)::int AS movimientos
  FROM public.inventory_movements im, biz
  WHERE im.business_id = biz.id
    AND im.reference_type = 'order'
    AND im.movement_type = 'sale'
    AND im.reference_id IN (SELECT id FROM base)
  GROUP BY im.reference_id, im.item_id
  HAVING count(*) > 1
),
s3 AS (
  SELECT jsonb_build_object(
    'pares_orden_item_con_mas_de_1_movimiento', (SELECT count(*) FROM dup),
    'ordenes_afectadas', (SELECT count(DISTINCT reference_id) FROM dup),
    'nota', 'si es 0, el inventario NO se consumio doble'
  ) AS d
),

-- 4) por mes, para ver cuando arranco
mes AS (
  SELECT to_char(date_trunc('month', created_at), 'YYYY-MM') AS mes,
         count(*)::int AS ordenes,
         count(*) FILTER (WHERE t_cocina > t_pago)::int AS cocina_despues_del_pago
  FROM base
  GROUP BY date_trunc('month', created_at)
),
s4 AS (
  SELECT coalesce(jsonb_agg(to_jsonb(m) ORDER BY m.mes), '[]'::jsonb) AS d
  FROM mes m
)

SELECT * FROM (
  SELECT 1 AS n, '1_EL_RELOJ_cocina_vs_pago' AS seccion, d AS detalle FROM s1
  UNION ALL SELECT 2, '2_FIRMA_DEL_PISOTON',    d FROM s2
  UNION ALL SELECT 3, '3_INVENTARIO_DOBLE',     d FROM s3
  UNION ALL SELECT 4, '4_POR_MES',              d FROM s4
) t ORDER BY n;
