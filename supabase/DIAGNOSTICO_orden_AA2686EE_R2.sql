-- =====================================================================
-- R2 — orden AA2686EE. La orden estaba BIEN. El papel esta mal.
-- Confirma que los 3 productos del ticket son de la sesion NUEVA de MESA4
-- y mide los 2 problemas de fondo (NCF con ITBIS 0, ordenes con pago abiertas)
-- UNA sola ejecucion -> un solo resultado.
-- =====================================================================

WITH biz AS (SELECT 'f054fbc2-3fb7-4e34-a020-11341ff11d84'::uuid AS id),

-- A) La sesion VIVA de MESA4 y sus items (los del papel)
sA AS (
  SELECT jsonb_build_object(
    'session_id',   ts.id,
    'opened_at',    ts.opened_at,
    'closed_at',    ts.closed_at,
    'orden',        upper(left(o.id::text,8)),
    'order_id',     o.id,
    'status_ext',   o.status_ext,
    'orders_total', o.total,
    'items', (
      SELECT jsonb_agg(jsonb_build_object(
        'producto',   i.product_name,
        'qty',        i.qty,
        'unit_price', i.unit_price,
        'subtotal',   i.subtotal,
        'tax',        i.tax,
        'tax_rate',   i.tax_rate,
        'tax_mode',   i.tax_mode,
        'status',     i.status,
        'creado',     i.created_at
      ) ORDER BY i.created_at)
      FROM public.order_items i
      WHERE i.order_id = o.id AND i.status::text <> 'void'
    ),
    'suma_items', (
      SELECT coalesce(sum(i.subtotal + i.tax - i.discounts),0)
      FROM public.order_items i
      WHERE i.order_id = o.id AND i.status::text <> 'void'
    ),
    'COINCIDE_CON_EL_PAPEL_710_73', (
      SELECT abs((coalesce(sum(i.subtotal + i.tax - i.discounts),0)) - 710.73) < 1.0
      FROM public.order_items i
      WHERE i.order_id = o.id AND i.status::text <> 'void'
    )
  ) AS d
  FROM public.table_sessions ts
  JOIN public.orders o ON o.session_id = ts.id
  WHERE ts.id = '7cf75142-dd6d-464a-b9cc-916838cdbb27'
),

-- B) NCF con ITBIS 0: el fd de AA2686EE dice taxable_amount 420 e itbis 0.
--    ¿Cuantos comprobantes del negocio estan asi? (sub-declaracion DGII)
sB AS (
  SELECT jsonb_build_object(
    'fds_activos_ult_90d',        count(*),
    'con_itbis_CERO',             count(*) FILTER (WHERE coalesce(fd.itbis_amount,0) = 0),
    'con_itbis_cero_Y_base_gravada',
                                  count(*) FILTER (WHERE coalesce(fd.itbis_amount,0) = 0
                                                     AND coalesce(fd.taxable_amount,0) > 0),
    'monto_total_facturado',      round(coalesce(sum(fd.total),0)::numeric, 2),
    'itbis_declarado',            round(coalesce(sum(fd.itbis_amount),0)::numeric, 2),
    'itbis_que_DEBIO_declararse', round(coalesce(sum(
                                    (SELECT coalesce(sum(i.tax),0)
                                       FROM public.order_items i
                                      WHERE i.order_id = fd.order_id
                                        AND i.status::text <> 'void')
                                  ),0)::numeric, 2),
    'primer_fd', min(fd.issued_at),
    'ultimo_fd', max(fd.issued_at)
  ) AS d
  FROM public.fiscal_documents fd, biz
  WHERE fd.business_id = biz.id
    AND fd.status = 'active'
    AND fd.issued_at > now() - interval '90 days'
),

-- C) Las 6,009 "con pago pero abiertas": desglose real por status
sC AS (
  SELECT coalesce(jsonb_agg(x ORDER BY x->>'status_ext'), '[]'::jsonb) AS d
  FROM (
    SELECT jsonb_build_object(
      'status_ext',   o.status_ext,
      'ordenes',      count(*),
      'mesa_ocupada', count(*) FILTER (WHERE ts.closed_at IS NULL),
      'mas_viejo',    min(o.created_at),
      'mas_nuevo',    max(o.created_at),
      'valor_items_pendiente', round(coalesce(sum(
        (SELECT coalesce(sum(i.subtotal + i.tax - i.discounts),0)
           FROM public.order_items i
          WHERE i.order_id = o.id AND i.status::text NOT IN ('paid','void'))
      ),0)::numeric, 2)
    ) AS x
    FROM public.orders o
    JOIN public.table_sessions ts ON ts.id = o.session_id
    JOIN public.dining_tables dt  ON dt.id = ts.table_id
    JOIN public.zones z           ON z.id  = dt.zone_id, biz
    WHERE z.business_id = biz.id
      AND o.status_ext NOT IN ('paid','void')
      AND EXISTS (SELECT 1 FROM public.payments p
                    WHERE p.order_id = o.id AND p.status = 'completed')
    GROUP BY o.status_ext
  ) q
),

-- D) Mesas ocupadas AHORA con sesion vieja (candidatas a "sigue abierta")
sD AS (
  SELECT coalesce(jsonb_agg(x ORDER BY (x->>'horas_abierta')::numeric DESC), '[]'::jsonb) AS d
  FROM (
    SELECT jsonb_build_object(
      'mesa',          dt.code,
      'zona',          z.name,
      'session_id',    ts.id,
      'abierta_desde', ts.opened_at,
      'horas_abierta', round((extract(epoch from (now() - ts.opened_at))/3600)::numeric, 1),
      'ordenes',       (SELECT count(*) FROM public.orders o2
                          WHERE o2.session_id = ts.id AND o2.closed_at IS NULL),
      'tiene_pagos',   EXISTS (SELECT 1 FROM public.payments p
                                 JOIN public.orders o3 ON o3.id = p.order_id
                                WHERE o3.session_id = ts.id AND p.status = 'completed')
    ) AS x
    FROM public.table_sessions ts
    JOIN public.dining_tables dt ON dt.id = ts.table_id
    JOIN public.zones z          ON z.id  = dt.zone_id, biz
    WHERE z.business_id = biz.id
      AND ts.closed_at IS NULL
      AND ts.opened_at < now() - interval '12 hours'
  ) q
)

SELECT * FROM (
  SELECT 1 AS n, 'A_SESION_VIVA_MESA4_vs_PAPEL' AS seccion, d AS detalle FROM sA
  UNION ALL SELECT 2, 'B_NCF_CON_ITBIS_CERO',      d FROM sB
  UNION ALL SELECT 3, 'C_ORDENES_CON_PAGO_ABIERTAS', d FROM sC
  UNION ALL SELECT 4, 'D_MESAS_ABIERTAS_MAS_12H',  d FROM sD
) t ORDER BY n;
