-- ============================================================================
-- ALCANCE GLOBAL: órdenes huérfanas (sesión cerrada + orden viva con consumo)
-- ============================================================================
-- Firma del bug (confirmado en Sophisticated Managment SRL, 2026-08-13):
--   `releaseEmptyTableIfNeeded` (app, 4 viajes sin transacción) cierra la
--   table_session justo cuando `fn_open_table` está creando otra orden en esa
--   misma sesión. La orden nace viva pero sin mesa: no sale en el salón, no
--   sale en cuentas abiertas, y nadie la cobra. La comanda SÍ salió por
--   impresora, así que la cocina despachó comida que nunca se facturó.
--
-- Delator secundario: la app guarda `closed_at` con `DateTime.now()` sin
-- `.toUtc()`, o sea hora local marcada como UTC → la sesión queda cerrada
-- 4 h ANTES de abrirse. `closed_at < opened_at` = la cerró la app.
-- Los cierres del servidor (`now()`) siempre dan `closed_at >= opened_at`.
--
-- Todo es SOLO LECTURA. Correr bloque por bloque.
-- ============================================================================

-- ─── 1) RESUMEN POR NEGOCIO — todo el histórico ───────────────────────────
-- La foto que decide si esto es un incidente o una hemorragia.
WITH huerfanas AS (
  SELECT
    coalesce(ts.business_id, z.business_id)                AS business_id,
    o.id                                                   AS order_id,
    o.created_at,
    (SELECT coalesce(sum(oi.subtotal + oi.tax - oi.discounts), 0)
       FROM public.order_items oi
      WHERE oi.order_id = o.id
        AND oi.status NOT IN ('void','paid'))              AS monto
  FROM public.orders o
  JOIN public.table_sessions ts ON ts.id = o.session_id
  LEFT JOIN public.dining_tables dt ON dt.id = ts.table_id
  LEFT JOIN public.zones z ON z.id = dt.zone_id
  WHERE ts.closed_at IS NOT NULL          -- la mesa ya no existe para la app
    AND o.closed_at IS NULL               -- pero la orden sigue viva
    AND o.status_ext NOT IN ('paid','void')
    AND EXISTS (SELECT 1 FROM public.order_items oi
                 WHERE oi.order_id = o.id
                   AND oi.status NOT IN ('void','paid'))
)
SELECT
  '1_POR_NEGOCIO'                                          AS seccion,
  b.business_name,
  h.business_id,
  count(*)                                                 AS n_ordenes,
  round(sum(h.monto), 2)                                   AS monto_nunca_cobrado,
  (min(h.created_at) AT TIME ZONE 'America/Santo_Domingo')::date AS desde,
  (max(h.created_at) AT TIME ZONE 'America/Santo_Domingo')::date AS hasta
FROM huerfanas h
LEFT JOIN public.businesses b ON b.id = h.business_id
GROUP BY b.business_name, h.business_id
ORDER BY monto_nunca_cobrado DESC NULLS LAST;


-- ─── 2) POR DÍA, ÚLTIMOS 45 DÍAS ──────────────────────────────────────────
-- ¿Arrancó con un build concreto o viene de siempre? Si hay un salto claro en
-- una fecha, esa fecha es la del release que lo introdujo.
SELECT
  '2_POR_DIA'                                              AS seccion,
  (o.created_at AT TIME ZONE 'America/Santo_Domingo')::date AS dia,
  count(*)                                                 AS n_ordenes,
  count(DISTINCT coalesce(ts.business_id, z.business_id))  AS n_negocios,
  round(sum((SELECT coalesce(sum(oi.subtotal + oi.tax - oi.discounts), 0)
               FROM public.order_items oi
              WHERE oi.order_id = o.id
                AND oi.status NOT IN ('void','paid'))), 2) AS monto
FROM public.orders o
JOIN public.table_sessions ts ON ts.id = o.session_id
LEFT JOIN public.dining_tables dt ON dt.id = ts.table_id
LEFT JOIN public.zones z ON z.id = dt.zone_id
WHERE ts.closed_at IS NOT NULL
  AND o.closed_at IS NULL
  AND o.status_ext NOT IN ('paid','void')
  AND o.created_at >= now() - interval '45 days'
  AND EXISTS (SELECT 1 FROM public.order_items oi
               WHERE oi.order_id = o.id
                 AND oi.status NOT IN ('void','paid'))
GROUP BY 1
ORDER BY 1 DESC;


-- ─── 3) DETALLE ACCIONABLE — últimos 7 días, todos los negocios ───────────
-- Esta lista es la que se puede recuperar: comida despachada y no cobrada.
-- `vida_sesion_seg` cerca de 0 (o negativo por el desfase) = carrera.
SELECT
  '3_DETALLE_7D'                                           AS seccion,
  b.business_name,
  dt.code                                                  AS mesa,
  ts.customer_name,
  upper(left(o.id::text, 8))                               AS orden_num,
  o.id                                                     AS order_id,
  o.session_id,
  o.status_ext,
  o.created_at AT TIME ZONE 'America/Santo_Domingo'        AS orden_creada_local,
  ts.opened_at AT TIME ZONE 'America/Santo_Domingo'        AS sesion_abierta_local,
  ts.closed_at AT TIME ZONE 'America/Santo_Domingo'        AS sesion_cerrada_local,
  round(EXTRACT(EPOCH FROM (ts.closed_at - ts.opened_at)))  AS vida_sesion_seg,
  CASE WHEN ts.closed_at < ts.opened_at THEN 'APP (desfase 4h)'
       ELSE 'servidor' END                                 AS quien_cerro,
  (SELECT count(*) FROM public.order_items oi
    WHERE oi.order_id = o.id AND oi.status NOT IN ('void','paid'))    AS items,
  round((SELECT coalesce(sum(oi.subtotal + oi.tax - oi.discounts), 0)
           FROM public.order_items oi
          WHERE oi.order_id = o.id
            AND oi.status NOT IN ('void','paid')), 2)      AS monto
FROM public.orders o
JOIN public.table_sessions ts ON ts.id = o.session_id
LEFT JOIN public.dining_tables dt ON dt.id = ts.table_id
LEFT JOIN public.zones z ON z.id = dt.zone_id
LEFT JOIN public.businesses b ON b.id = coalesce(ts.business_id, z.business_id)
WHERE ts.closed_at IS NOT NULL
  AND o.closed_at IS NULL
  AND o.status_ext NOT IN ('paid','void')
  AND o.created_at >= now() - interval '7 days'
  AND EXISTS (SELECT 1 FROM public.order_items oi
               WHERE oi.order_id = o.id
                 AND oi.status NOT IN ('void','paid'))
ORDER BY o.created_at DESC;


-- ─── 4) EXPOSICIÓN: ¿cuánto corre la ruta que provoca la carrera? ─────────
-- Cuenta las sesiones que cerró la APP (closed_at < opened_at, el desfase de
-- 4 h) contra las que cerró el servidor. Cada cierre de la app es una tirada
-- de dados; el número de la izquierda es cuántas veces al día se tira.
SELECT
  '4_EXPOSICION'                                           AS seccion,
  b.business_name,
  count(*) FILTER (WHERE ts.closed_at < ts.opened_at)      AS cerradas_por_app,
  count(*) FILTER (WHERE ts.closed_at >= ts.opened_at)     AS cerradas_por_servidor,
  count(*)                                                 AS total_cerradas,
  round(100.0 * count(*) FILTER (WHERE ts.closed_at < ts.opened_at)
        / nullif(count(*), 0), 1)                          AS pct_app
FROM public.table_sessions ts
LEFT JOIN public.dining_tables dt ON dt.id = ts.table_id
LEFT JOIN public.zones z ON z.id = dt.zone_id
LEFT JOIN public.businesses b ON b.id = coalesce(ts.business_id, z.business_id)
WHERE ts.closed_at IS NOT NULL
  AND ts.opened_at >= now() - interval '30 days'
GROUP BY b.business_name
ORDER BY cerradas_por_app DESC;


-- ─── 5) LA OTRA CARA: sesiones con DOS órdenes creadas con segundos de ────
--       diferencia (la doble entrada a la mesa que dispara todo)
-- No todas terminan en huérfana, pero cada una es la carrera ejecutándose.
SELECT
  '5_DOBLE_ORDEN'                                          AS seccion,
  b.business_name,
  dt.code                                                  AS mesa,
  ts.id                                                    AS session_id,
  ts.opened_at AT TIME ZONE 'America/Santo_Domingo'        AS abierta_local,
  count(o.id)                                              AS n_ordenes,
  round(EXTRACT(EPOCH FROM (max(o.created_at) - min(o.created_at))), 1) AS seg_entre_ordenes,
  count(*) FILTER (WHERE o.status_ext = 'void')            AS n_void
FROM public.table_sessions ts
JOIN public.orders o ON o.session_id = ts.id
LEFT JOIN public.dining_tables dt ON dt.id = ts.table_id
LEFT JOIN public.zones z ON z.id = dt.zone_id
LEFT JOIN public.businesses b ON b.id = coalesce(ts.business_id, z.business_id)
WHERE ts.opened_at >= now() - interval '7 days'
GROUP BY b.business_name, dt.code, ts.id, ts.opened_at
HAVING count(o.id) > 1
   AND EXTRACT(EPOCH FROM (max(o.created_at) - min(o.created_at))) < 60
ORDER BY ts.opened_at DESC
LIMIT 100;
