-- =====================================================================
-- R3 — las 6,009 ordenes con pago completado atascadas en 'sent_to_kitchen'
-- (negocio f054fbc2). Objetivo: ver QUE quedo a medias al cerrar.
--
-- NOTA: aqui NO se mira `fiscal_documents.itbis_amount`. Los impuestos
-- se cargan desde configuracion (taxes x menu_item_taxes -> order_items),
-- esa columna no se usa.
--
-- UNA sola ejecucion -> un solo resultado.
-- =====================================================================

WITH biz AS (SELECT 'f054fbc2-3fb7-4e34-a020-11341ff11d84'::uuid AS id),

-- universo: ordenes del negocio con pago completado que NO quedaron en paid/void
atascadas AS (
  SELECT
    o.id,
    o.created_at,
    o.status                                            AS status_legacy,
    o.status_ext,
    (o.closed_at IS NOT NULL)                           AS orden_closed_at,
    (ts.closed_at IS NOT NULL)                          AS sesion_cerrada,
    (dt.state = 'occupied')                             AS mesa_ocupada,
    EXISTS (SELECT 1 FROM public.fiscal_documents f
              WHERE f.order_id = o.id AND f.status = 'active')      AS tiene_fd,
    NOT EXISTS (SELECT 1 FROM public.order_items i
                  WHERE i.order_id = o.id
                    AND i.status::text NOT IN ('paid','void'))      AS items_todos_paid,
    EXISTS (SELECT 1 FROM public.order_checks c
              WHERE c.order_id = o.id AND c.is_closed = false)      AS check_abierto,
    (SELECT coalesce(sum(p.amount - coalesce(p.change_amount,0)),0)
       FROM public.payments p
      WHERE p.order_id = o.id AND p.status = 'completed')           AS cobrado,
    (SELECT coalesce(sum(i.subtotal + i.tax - i.discounts),0)
       FROM public.order_items i
      WHERE i.order_id = o.id
        AND i.status::text NOT IN ('paid','void'))                  AS pendiente
  FROM public.orders o
  JOIN public.table_sessions ts ON ts.id = o.session_id
  JOIN public.dining_tables dt  ON dt.id = ts.table_id
  JOIN public.zones z           ON z.id  = dt.zone_id, biz
  WHERE z.business_id = biz.id
    AND o.status_ext NOT IN ('paid','void')
    AND EXISTS (SELECT 1 FROM public.payments p
                  WHERE p.order_id = o.id AND p.status = 'completed')
),

-- 1) el PATRON: que combinacion de banderas quedo
--    (agregacion en su propia capa; el jsonb se arma DESPUES)
patron AS (
  SELECT status_ext, status_legacy, orden_closed_at, sesion_cerrada,
         mesa_ocupada, tiene_fd, items_todos_paid, check_abierto,
         count(*)::int   AS ordenes,
         min(created_at) AS mas_viejo,
         max(created_at) AS mas_nuevo
  FROM atascadas
  GROUP BY status_ext, status_legacy, orden_closed_at, sesion_cerrada,
           mesa_ocupada, tiene_fd, items_todos_paid, check_abierto
),
s1 AS (
  SELECT coalesce(jsonb_agg(to_jsonb(p) ORDER BY p.ordenes DESC), '[]'::jsonb) AS d
  FROM patron p
),

-- 2) impacto en plata y en salon
s2 AS (
  SELECT jsonb_build_object(
    'ordenes',              count(*),
    'con_fd_emitido',       count(*) FILTER (WHERE tiene_fd),
    'sin_fd',               count(*) FILTER (WHERE NOT tiene_fd),
    'mesa_todavia_ocupada', count(*) FILTER (WHERE mesa_ocupada),
    'con_check_abierto',    count(*) FILTER (WHERE check_abierto),
    'items_todos_paid',     count(*) FILTER (WHERE items_todos_paid),
    'cobrado_total',        round(sum(cobrado)::numeric, 2),
    'valor_items_no_pagados', round(sum(pendiente)::numeric, 2),
    'mas_viejo',            min(created_at),
    'mas_nuevo',            max(created_at)
  ) AS d
  FROM atascadas
),

-- 3) por mes, para ver si se acelera o viene de siempre
mes AS (
  SELECT to_char(date_trunc('month', created_at), 'YYYY-MM') AS mes,
         count(*)::int AS ordenes,
         count(*) FILTER (WHERE items_todos_paid)::int AS todos_items_paid
  FROM atascadas
  GROUP BY date_trunc('month', created_at)
),
s3 AS (
  SELECT coalesce(jsonb_agg(to_jsonb(m) ORDER BY m.mes), '[]'::jsonb) AS d
  FROM mes m
),

-- 4) 5 ejemplos recientes para abrirlos a mano
muestra AS (
  SELECT upper(left(a.id::text,8)) AS codigo, a.id, a.created_at,
         a.cobrado, a.pendiente, a.tiene_fd, a.items_todos_paid,
         a.orden_closed_at, a.sesion_cerrada
  FROM atascadas a
  ORDER BY a.created_at DESC
  LIMIT 5
),
s4 AS (
  SELECT coalesce(jsonb_agg(to_jsonb(m) ORDER BY m.created_at DESC), '[]'::jsonb) AS d
  FROM muestra m
)

SELECT * FROM (
  SELECT 1 AS n, '1_PATRON_DE_BANDERAS' AS seccion, d AS detalle FROM s1
  UNION ALL SELECT 2, '2_IMPACTO',        d FROM s2
  UNION ALL SELECT 3, '3_POR_MES',        d FROM s3
  UNION ALL SELECT 4, '4_MUESTRA',        d FROM s4
) t ORDER BY n;
