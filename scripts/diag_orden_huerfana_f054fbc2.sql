-- ============================================================================
-- DIAGNÓSTICO 2: órdenes huérfanas (sesión cerrada, orden viva)
-- Negocio REAL: f054fbc2-3fb7-4e34-a020-11341ff11d84 (Sophisticated Managment SRL)
-- Caso testigo: orden f5ab74d7-006f-44ab-be61-b6d187c676f1, sesión
--               8a76adcc-2180-4970-9ce2-47bc7709d237 (MESA9)
-- Solo lectura. Correr bloque por bloque.
-- ============================================================================

-- ─── A) ¿CUÁNTAS ÓRDENES TIENE ESA SESIÓN? ─────────────────────────────────
-- LA PREGUNTA QUE DECIDE TODO.
--   2+ filas → confirmada la carrera: la limpieza de la 1ª orden (vacía, se
--              queda en status_ext='void') cerró la sesión sin ver la 2ª.
--   1 fila   → la limpieza corrió contra ESTA misma orden y el UPDATE de
--              `orders` no pegó (RLS) mientras el de `table_sessions` sí.
SELECT
  'A_ORDENES_DE_LA_SESION'                            AS seccion,
  upper(left(o.id::text, 8))                          AS orden_num,
  o.id,
  o.status, o.status_ext,
  o.created_at AT TIME ZONE 'America/Santo_Domingo'   AS creada_local,
  o.closed_at  AT TIME ZONE 'America/Santo_Domingo'   AS cerrada_local,
  o.closed_at                                         AS cerrada_raw_utc,
  o.total,
  (SELECT count(*) FROM public.order_items oi WHERE oi.order_id = o.id) AS n_items
FROM public.orders o
WHERE o.session_id = '8a76adcc-2180-4970-9ce2-47bc7709d237'
ORDER BY o.created_at;


-- ─── B) LAS HUÉRFANAS DE HOY: sesión cerrada + orden viva con ítems ────────
-- Aquí sale la SEGUNDA orden perdida del reporte, y cualquier otra.
-- `desfase_horas` ≈ -4 delata que la cerró la app (naive local como UTC);
-- ≈ 0 significa que la cerró el servidor (now()), o sea un cierre legítimo.
SELECT
  'B_HUERFANAS_HOY'                                   AS seccion,
  upper(left(o.id::text, 8))                          AS orden_num,
  o.id                                                AS order_id,
  dt.code                                             AS mesa,
  ts.customer_name,
  o.status, o.status_ext,
  o.total,
  o.created_at AT TIME ZONE 'America/Santo_Domingo'   AS orden_creada_local,
  ts.opened_at AT TIME ZONE 'America/Santo_Domingo'   AS sesion_abierta_local,
  ts.closed_at AT TIME ZONE 'America/Santo_Domingo'   AS sesion_cerrada_local,
  round(EXTRACT(EPOCH FROM (ts.closed_at - ts.opened_at)) / 3600.0, 2) AS desfase_horas,
  round(EXTRACT(EPOCH FROM (ts.closed_at - ts.opened_at)))            AS vida_sesion_seg,
  (SELECT count(*) FROM public.order_items oi
    WHERE oi.order_id = o.id AND oi.status NOT IN ('void','paid'))    AS items_sin_cobrar,
  (SELECT sum(oi.subtotal + oi.tax - oi.discounts) FROM public.order_items oi
    WHERE oi.order_id = o.id AND oi.status NOT IN ('void','paid'))    AS monto_sin_cobrar
FROM public.orders o
JOIN public.table_sessions ts ON ts.id = o.session_id
LEFT JOIN public.dining_tables dt ON dt.id = ts.table_id
WHERE ts.business_id = 'f054fbc2-3fb7-4e34-a020-11341ff11d84'
  AND ts.closed_at IS NOT NULL          -- la mesa ya no existe para la app
  AND o.closed_at IS NULL               -- pero la orden sigue viva
  AND o.status_ext NOT IN ('paid','void')
  AND EXISTS (SELECT 1 FROM public.order_items oi
               WHERE oi.order_id = o.id AND oi.status NOT IN ('void','paid'))
  AND o.created_at >= (DATE '2026-08-13')::timestamp AT TIME ZONE 'America/Santo_Domingo'
ORDER BY o.created_at;


-- ─── C) LA MISMA BÚSQUEDA, PERO DE TODA LA HISTORIA DEL NEGOCIO ────────────
-- Dice si esto es de hoy (→ sospechar el build/migración de hoy) o si viene
-- arrastrándose hace meses (→ carrera vieja que hoy se hizo visible).
SELECT
  'C_HUERFANAS_POR_DIA'                               AS seccion,
  (o.created_at AT TIME ZONE 'America/Santo_Domingo')::date AS dia,
  count(*)                                            AS n_ordenes,
  sum((SELECT coalesce(sum(oi.subtotal + oi.tax - oi.discounts), 0)
         FROM public.order_items oi
        WHERE oi.order_id = o.id AND oi.status NOT IN ('void','paid'))) AS monto_perdido
FROM public.orders o
JOIN public.table_sessions ts ON ts.id = o.session_id
WHERE ts.business_id = 'f054fbc2-3fb7-4e34-a020-11341ff11d84'
  AND ts.closed_at IS NOT NULL
  AND o.closed_at IS NULL
  AND o.status_ext NOT IN ('paid','void')
  AND EXISTS (SELECT 1 FROM public.order_items oi
               WHERE oi.order_id = o.id AND oi.status NOT IN ('void','paid'))
GROUP BY 1
ORDER BY 1 DESC
LIMIT 30;


-- ─── D) ¿CUÁNTO SE USA EL "LIBERAR MESA VACÍA" DE LA APP? ─────────────────
-- Sesiones cerradas con el timestamp 4 h atrás = cerradas por la app.
-- Muestra cuántas veces al día corre esa ruta (o sea, cuántas veces al día
-- se está jugando la carrera).
SELECT
  'D_CIERRES_POR_LA_APP'                              AS seccion,
  (ts.opened_at AT TIME ZONE 'America/Santo_Domingo')::date AS dia,
  count(*) FILTER (WHERE ts.closed_at < ts.opened_at) AS cerradas_por_app_4h_atras,
  count(*) FILTER (WHERE ts.closed_at >= ts.opened_at) AS cerradas_normales,
  count(*)                                            AS total_sesiones
FROM public.table_sessions ts
WHERE ts.business_id = 'f054fbc2-3fb7-4e34-a020-11341ff11d84'
  AND ts.closed_at IS NOT NULL
  AND ts.opened_at >= now() - interval '14 days'
GROUP BY 1
ORDER BY 1 DESC;


-- ─── E) SESIONES QUE VIVIERON MENOS DE 60 SEGUNDOS Y TIENEN CONSUMO ───────
-- Firma directa de la carrera: mesa abierta y cerrada en segundos, pero con
-- productos cargados después del cierre.
SELECT
  'E_SESIONES_RELAMPAGO'                              AS seccion,
  ts.id                                               AS session_id,
  dt.code                                             AS mesa,
  ts.customer_name,
  ts.opened_at AT TIME ZONE 'America/Santo_Domingo'   AS abierta_local,
  ts.closed_at AT TIME ZONE 'America/Santo_Domingo'   AS cerrada_local,
  (SELECT count(*) FROM public.orders o2 WHERE o2.session_id = ts.id) AS n_ordenes,
  (SELECT count(*) FROM public.order_items oi
     JOIN public.orders o3 ON o3.id = oi.order_id
    WHERE o3.session_id = ts.id)                      AS n_items,
  (SELECT max(oi.created_at) AT TIME ZONE 'America/Santo_Domingo'
     FROM public.order_items oi
     JOIN public.orders o4 ON o4.id = oi.order_id
    WHERE o4.session_id = ts.id)                      AS ultimo_item_local
FROM public.table_sessions ts
LEFT JOIN public.dining_tables dt ON dt.id = ts.table_id
WHERE ts.business_id = 'f054fbc2-3fb7-4e34-a020-11341ff11d84'
  AND ts.closed_at IS NOT NULL
  AND ts.opened_at >= now() - interval '14 days'
  -- vida real de la sesión, corrigiendo el desfase de 4 h de los cierres de la app
  AND abs(EXTRACT(EPOCH FROM (ts.closed_at - ts.opened_at))) % 3600 < 60
  AND EXISTS (SELECT 1 FROM public.orders o5
               JOIN public.order_items oi2 ON oi2.order_id = o5.id
              WHERE o5.session_id = ts.id)
ORDER BY ts.opened_at DESC
LIMIT 50;
