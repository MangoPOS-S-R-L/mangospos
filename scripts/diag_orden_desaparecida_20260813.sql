-- ============================================================================
-- DIAGNÓSTICO: órdenes que "desaparecieron" — 2026-08-13
-- Negocio: d1f0e5c5-f598-4bd6-a3d1-19543c133f99
-- Caso testigo: comanda ORDEN #F5AB74D7, MESA9, mesero rosario,
--               cliente NATHALIA, 11:43:17 (hora local)
-- Correr en Supabase Studio > SQL Editor. Solo lectura.
-- ============================================================================

-- ─── 1) ¿EXISTE TODAVÍA LA ORDEN F5AB74D7? ─────────────────────────────────
-- 0 filas = la orden YA NO ESTÁ EN LA BD (borrada, casi seguro por cascada
--           al borrarse la table_session). Eso descarta "se cerró sola".
-- 1 fila  = sigue ahí; mira status / status_ext / closed_at.
SELECT
  '1_ORDEN'                                         AS seccion,
  o.id,
  o.status,
  o.status_ext,
  o.created_at AT TIME ZONE 'America/Santo_Domingo' AS creada_local,
  o.closed_at  AT TIME ZONE 'America/Santo_Domingo' AS cerrada_local,
  o.subtotal, o.discounts, o.tax, o.total, o.total_amount,
  ts.id                                             AS session_id,
  ts.business_id,
  dt.code                                           AS mesa,
  ts.customer_name,
  ts.opened_at AT TIME ZONE 'America/Santo_Domingo' AS sesion_abierta_local,
  ts.closed_at AT TIME ZONE 'America/Santo_Domingo' AS sesion_cerrada_local,
  ts.origin,
  ts.opened_by,
  ts.waiter_user_id
FROM public.orders o
JOIN public.table_sessions ts ON ts.id = o.session_id
LEFT JOIN public.dining_tables dt ON dt.id = ts.table_id
WHERE o.id::text LIKE 'f5ab74d7%';


-- ─── 2) ÍTEMS DE ESA ORDEN ─────────────────────────────────────────────────
-- Debería salir "EMPLEADO PLATO DEL DIA" con nota "nathalia".
-- Si la orden existe pero esto da 0 filas → los ítems nunca se guardaron en
-- el servidor (la comanda se imprimió del estado local) o se borraron.
SELECT
  '2_ITEMS'                                          AS seccion,
  oi.id,
  oi.product_name,
  oi.quantity, oi.qty,
  oi.status,
  oi.unit_price, oi.subtotal, oi.tax, oi.tax_rate, oi.tax_mode,
  oi.notes,
  oi.check_id,
  oi.created_at AT TIME ZONE 'America/Santo_Domingo' AS creado_local
FROM public.order_items oi
JOIN public.orders o ON o.id = oi.order_id
WHERE o.id::text LIKE 'f5ab74d7%'
ORDER BY oi.created_at;


-- ─── 3) TODO LO QUE PASÓ EN MESA9 HOY ──────────────────────────────────────
-- Todas las sesiones de la mesa en el día, con sus órdenes y conteo de ítems.
-- Si la sesión de las 11:4x NO aparece → la sesión fue borrada (cascada).
SELECT
  '3_MESA9_HOY'                                      AS seccion,
  dt.code                                            AS mesa,
  ts.id                                              AS session_id,
  ts.customer_name,
  ts.opened_at AT TIME ZONE 'America/Santo_Domingo'  AS abierta_local,
  ts.closed_at AT TIME ZONE 'America/Santo_Domingo'  AS cerrada_local,
  o.id                                               AS order_id,
  upper(left(o.id::text, 8))                         AS orden_num,
  o.status, o.status_ext, o.total,
  o.created_at AT TIME ZONE 'America/Santo_Domingo'  AS orden_creada_local,
  o.closed_at  AT TIME ZONE 'America/Santo_Domingo'  AS orden_cerrada_local,
  (SELECT count(*) FROM public.order_items oi WHERE oi.order_id = o.id) AS n_items
FROM public.table_sessions ts
JOIN public.dining_tables dt ON dt.id = ts.table_id
LEFT JOIN public.orders o ON o.session_id = ts.id
WHERE ts.business_id = 'd1f0e5c5-f598-4bd6-a3d1-19543c133f99'
  AND dt.code = 'MESA9'
  AND ts.opened_at >= (DATE '2026-08-13')::timestamp AT TIME ZONE 'America/Santo_Domingo'
  AND ts.opened_at <  (DATE '2026-08-14')::timestamp AT TIME ZONE 'America/Santo_Domingo'
ORDER BY ts.opened_at;


-- ─── 4) TODAS LAS ÓRDENES DEL NEGOCIO HOY (10:00–15:00) ────────────────────
-- Para ubicar las DOS órdenes del reporte y ver si hay un hueco en la
-- secuencia de horas (órdenes que faltan entre dos que sí quedaron).
SELECT
  '4_ORDENES_HOY'                                    AS seccion,
  upper(left(o.id::text, 8))                         AS orden_num,
  o.created_at AT TIME ZONE 'America/Santo_Domingo'  AS creada_local,
  dt.code                                            AS mesa,
  ts.customer_name,
  ts.origin,
  o.status, o.status_ext,
  o.total,
  o.closed_at  AT TIME ZONE 'America/Santo_Domingo'  AS cerrada_local,
  ts.closed_at AT TIME ZONE 'America/Santo_Domingo'  AS sesion_cerrada_local,
  (SELECT count(*) FROM public.order_items oi WHERE oi.order_id = o.id)                        AS n_items,
  (SELECT count(*) FROM public.order_items oi WHERE oi.order_id = o.id AND oi.status = 'void') AS n_void,
  (SELECT count(*) FROM public.payments p WHERE p.order_id = o.id AND p.status = 'completed')  AS n_pagos
FROM public.orders o
JOIN public.table_sessions ts ON ts.id = o.session_id
LEFT JOIN public.dining_tables dt ON dt.id = ts.table_id
WHERE ts.business_id = 'd1f0e5c5-f598-4bd6-a3d1-19543c133f99'
  AND o.created_at >= (DATE '2026-08-13' + TIME '10:00')::timestamp AT TIME ZONE 'America/Santo_Domingo'
  AND o.created_at <  (DATE '2026-08-13' + TIME '15:00')::timestamp AT TIME ZONE 'America/Santo_Domingo'
ORDER BY o.created_at;


-- ─── 5) ÓRDENES DEL DÍA SIN ÍTEMS (candidatas a "se perdió el consumo") ────
SELECT
  '5_ORDENES_VACIAS'                                 AS seccion,
  upper(left(o.id::text, 8))                         AS orden_num,
  o.id,
  o.created_at AT TIME ZONE 'America/Santo_Domingo'  AS creada_local,
  dt.code                                            AS mesa,
  ts.customer_name,
  o.status, o.status_ext, o.total,
  o.closed_at  AT TIME ZONE 'America/Santo_Domingo'  AS cerrada_local
FROM public.orders o
JOIN public.table_sessions ts ON ts.id = o.session_id
LEFT JOIN public.dining_tables dt ON dt.id = ts.table_id
WHERE ts.business_id = 'd1f0e5c5-f598-4bd6-a3d1-19543c133f99'
  AND o.created_at >= (DATE '2026-08-13')::timestamp AT TIME ZONE 'America/Santo_Domingo'
  AND NOT EXISTS (SELECT 1 FROM public.order_items oi WHERE oi.order_id = o.id)
ORDER BY o.created_at;


-- ─── 6) SESIONES DEL DÍA SIN NINGUNA ORDEN ────────────────────────────────
-- Si la orden se borró pero la sesión no, aparece aquí.
SELECT
  '6_SESIONES_SIN_ORDEN'                             AS seccion,
  ts.id                                              AS session_id,
  dt.code                                            AS mesa,
  ts.customer_name,
  ts.opened_at AT TIME ZONE 'America/Santo_Domingo'  AS abierta_local,
  ts.closed_at AT TIME ZONE 'America/Santo_Domingo'  AS cerrada_local
FROM public.table_sessions ts
LEFT JOIN public.dining_tables dt ON dt.id = ts.table_id
WHERE ts.business_id = 'd1f0e5c5-f598-4bd6-a3d1-19543c133f99'
  AND ts.opened_at >= (DATE '2026-08-13')::timestamp AT TIME ZONE 'America/Santo_Domingo'
  AND NOT EXISTS (SELECT 1 FROM public.orders o WHERE o.session_id = ts.id)
ORDER BY ts.opened_at;


-- ─── 7) AUDITORÍA DEL DÍA (anulaciones, descuentos, acciones con PIN) ──────
SELECT
  '7_AUDIT'                                          AS seccion,
  a.created_at AT TIME ZONE 'America/Santo_Domingo'  AS cuando_local,
  a.action, a.reason, a.ref_table, a.ref_id, a.user_id
FROM public.audit_logs a
WHERE a.business_id = 'd1f0e5c5-f598-4bd6-a3d1-19543c133f99'
  AND a.created_at >= (DATE '2026-08-13')::timestamp AT TIME ZONE 'America/Santo_Domingo'
ORDER BY a.created_at;


-- ─── 8) ¿HAY UN BARRENDERO AUTOMÁTICO CORRIENDO? ──────────────────────────
-- fn_release_empty_tables cierra órdenes "vacías" pasado un umbral. Si está
-- instalada y con cron, es candidata a haberse llevado la orden.
SELECT '8A_FN_BARRENDERO' AS seccion, p.proname, pg_get_function_identity_arguments(p.oid) AS args
FROM pg_proc p
JOIN pg_namespace n ON n.oid = p.pronamespace
WHERE n.nspname = 'public'
  AND p.proname IN ('fn_release_empty_tables', 'fn_close_order_and_table');

SELECT '8B_CRON' AS seccion, jobid, schedule, command, active
FROM cron.job;   -- si da error "schema cron does not exist", no hay pg_cron: ignóralo

SELECT '8C_CRON_RUNS' AS seccion, jobid, status, return_message,
       start_time AT TIME ZONE 'America/Santo_Domingo' AS inicio_local
FROM cron.job_run_details
WHERE start_time >= (DATE '2026-08-13')::timestamp AT TIME ZONE 'America/Santo_Domingo'
ORDER BY start_time DESC
LIMIT 50;


-- ─── 9) NEGOCIO: ¿cuál es? (para confirmar que hablamos del mismo) ────────
SELECT '9_NEGOCIO' AS seccion, b.*
FROM public.businesses b
WHERE b.id = 'd1f0e5c5-f598-4bd6-a3d1-19543c133f99';
