-- =====================================================================
-- DIAGNOSTICO orden AA2686EE  "se cobro y sigue abierta"
-- Negocio: f054fbc2-3fb7-4e34-a020-11341ff11d84
-- AA2686EE = primeros 8 chars del uuid de la orden (asi lo pinta la POS)
--
-- UNA SOLA EJECUCION -> UN SOLO RESULTADO.
-- Devuelve filas (n, seccion, detalle jsonb). Copia y pega TODO de vuelta.
-- =====================================================================

WITH ord AS (
  SELECT o.*
  FROM public.orders o
  WHERE o.id::text LIKE 'aa2686ee%'
  LIMIT 1
),
pago AS (
  SELECT
    max(p.created_at)              AS t_pago,
    coalesce(sum(p.amount), 0)     AS recibido,
    coalesce(sum(p.change_amount), 0) AS cambio
  FROM public.payments p
  JOIN ord ON p.order_id = ord.id
  WHERE p.status = 'completed'
),

-- 01 -------------------------------------------------------------
s01 AS (
  SELECT jsonb_build_object(
    'codigo',        upper(left(o.id::text, 8)),
    'veredicto',
      CASE
        WHEN o.status_ext NOT IN ('paid','void')
          THEN 'ORDEN NUNCA SE MARCO PAGADA (status_ext=' || o.status_ext::text || ')'
        WHEN o.closed_at IS NULL
          THEN 'status_ext=paid pero closed_at NULL'
        WHEN ts.closed_at IS NULL
          THEN 'ORDEN CERRADA pero SESION ABIERTA -> ver seccion 02 (orden hermana viva)'
        WHEN dt.state <> 'available'
          THEN 'orden y sesion cerradas pero dining_tables.state = ' || dt.state::text
        ELSE 'orden, sesion y mesa cerradas -> revisar secciones 04 y 09'
      END,
    'orden',    to_jsonb(o),
    'sesion',   to_jsonb(ts),
    'mesa',     jsonb_build_object(
                  'table_id', dt.id, 'code', dt.code,
                  'state', dt.state, 'zona', z.name),
    'negocio',  b.business_name
  ) AS d
  FROM ord o
  JOIN public.table_sessions ts ON ts.id = o.session_id
  LEFT JOIN public.dining_tables dt ON dt.id = ts.table_id
  LEFT JOIN public.zones z          ON z.id  = dt.zone_id
  LEFT JOIN public.businesses b     ON b.id  = z.business_id
),

-- 02 -------------------------------------------------------------
s02 AS (
  SELECT coalesce(jsonb_agg(x ORDER BY x->>'created_at'), '[]'::jsonb) AS d
  FROM (
    SELECT jsonb_build_object(
      'codigo',      upper(left(o2.id::text, 8)),
      'order_id',    o2.id,
      'status_ext',  o2.status_ext,
      'closed_at',   o2.closed_at,
      'created_at',  o2.created_at,
      'total',       o2.total,
      'items_vivos', (SELECT count(*) FROM public.order_items i
                        WHERE i.order_id = o2.id AND i.status::text <> 'void'),
      'es_esta',     (o2.id = (SELECT id FROM ord))
    ) AS x
    FROM public.orders o2
    WHERE o2.session_id = (SELECT session_id FROM ord)
  ) q
),

-- 03 -------------------------------------------------------------
s03 AS (
  SELECT coalesce(jsonb_agg(x ORDER BY x->>'pagado_en'), '[]'::jsonb) AS d
  FROM (
    SELECT jsonb_build_object(
      'payment_id',   p.id,
      'tipo_cobro',   CASE WHEN p.check_id IS NULL THEN 'FULL-ORDER' ELSE 'POR CUENTA' END,
      'check_id',     p.check_id,
      'metodo',       pm.name,
      'code',         pm.code,
      'amount',       p.amount,
      'change_amount',p.change_amount,
      'neto_a_caja',  (p.amount - coalesce(p.change_amount,0)),
      'status',       p.status,
      'reference',    p.reference,
      'pagado_en',    p.created_at,
      'caja_session', p.session_id,
      'processed_by', p.processed_by
    ) AS x
    FROM public.payments p
    LEFT JOIN public.payment_methods pm ON pm.id = p.payment_method_id
    WHERE p.order_id = (SELECT id FROM ord)
  ) q
),

-- 04 -------------------------------------------------------------
s04 AS (
  SELECT coalesce(jsonb_agg(x ORDER BY (x->>'position')::int), '[]'::jsonb) AS d
  FROM (
    SELECT jsonb_build_object(
      'check_id',     oc.id,
      'label',        oc.label,
      'position',     oc.position,
      'is_closed',    oc.is_closed,
      'subtotal',     oc.subtotal,
      'discounts',    oc.discounts,
      'tax',          oc.tax,
      'total',        oc.total,
      'items',        (SELECT count(*) FROM public.order_items i WHERE i.check_id = oc.id),
      'items_vivos',  (SELECT count(*) FROM public.order_items i
                         WHERE i.check_id = oc.id AND i.status::text <> 'void'),
      'valor_items_vivos', (SELECT coalesce(sum(i.subtotal + i.tax - i.discounts),0)
                              FROM public.order_items i
                              WHERE i.check_id = oc.id AND i.status::text <> 'void'),
      'pagado_a_esta_cuenta', (SELECT coalesce(sum(pp.amount),0) FROM public.payments pp
                                 WHERE pp.check_id = oc.id AND pp.status = 'completed')
    ) AS x
    FROM public.order_checks oc
    WHERE oc.order_id = (SELECT id FROM ord)
  ) q
),

-- 05 -------------------------------------------------------------
s05 AS (
  SELECT coalesce(jsonb_agg(x ORDER BY x->>'item_creado'), '[]'::jsonb) AS d
  FROM (
    SELECT jsonb_build_object(
      'producto',    oi.product_name,
      'qty',         oi.qty,
      'unit_price',  oi.unit_price,
      'subtotal',    oi.subtotal,
      'discounts',   oi.discounts,
      'tax',         oi.tax,
      'tax_mode',    oi.tax_mode,
      'tax_rate',    oi.tax_rate,
      'linea_total', (oi.subtotal + oi.tax - oi.discounts),
      'item_status', oi.status,
      'check_id',    oi.check_id,
      'check_label', oc.label,
      'check_cerrado', oc.is_closed,
      -- las 3 banderas que explican el descuadre del papel
      'INVISIBLE_AL_COBRO',
        (oi.status::text IN ('paid','void') OR coalesce(oc.is_closed,false) = true),
      'SIN_CUENTA',  (oi.check_id IS NULL),
      'AGREGADO_DESPUES_DEL_PAGO',
        (oi.created_at > (SELECT t_pago FROM pago)),
      'item_creado', oi.created_at,
      'item_id',     oi.id
    ) AS x
    FROM public.order_items oi
    LEFT JOIN public.order_checks oc ON oc.id = oi.check_id
    WHERE oi.order_id = (SELECT id FROM ord)
  ) q
),

-- 06 -------------------------------------------------------------
s06 AS (
  SELECT jsonb_build_object(
    'papel_efectivo',        pago.recibido,
    'papel_cambio',          pago.cambio,
    'total_que_vio_la_pos',  (pago.recibido - pago.cambio),
    'orders_total_hoy',      (SELECT total FROM ord),
    'total_TODOS_los_items', (SELECT coalesce(sum(i.subtotal + i.tax - i.discounts),0)
                                FROM public.order_items i
                                WHERE i.order_id = (SELECT id FROM ord)
                                  AND i.status::text <> 'void'),
    'total_items_al_cobrar', (SELECT coalesce(sum(i.subtotal + i.tax - i.discounts),0)
                                FROM public.order_items i
                                WHERE i.order_id = (SELECT id FROM ord)
                                  AND i.status::text <> 'void'
                                  AND i.created_at <= pago.t_pago),
    'total_items_VISIBLES_al_cobro',
                             (SELECT coalesce(sum(i.subtotal + i.tax - i.discounts),0)
                                FROM public.order_items i
                                LEFT JOIN public.order_checks c ON c.id = i.check_id
                                WHERE i.order_id = (SELECT id FROM ord)
                                  AND i.status::text NOT IN ('paid','void')
                                  AND coalesce(c.is_closed,false) = false),
    'items_agregados_despues', (SELECT count(*) FROM public.order_items i
                                  WHERE i.order_id = (SELECT id FROM ord)
                                    AND i.status::text <> 'void'
                                    AND i.created_at > pago.t_pago),
    'items_en_check_cerrado',  (SELECT count(*) FROM public.order_items i
                                  JOIN public.order_checks c ON c.id = i.check_id
                                  WHERE i.order_id = (SELECT id FROM ord)
                                    AND i.status::text <> 'void'
                                    AND c.is_closed = true),
    'faltante_cobrado',      ((SELECT coalesce(sum(i.subtotal + i.tax - i.discounts),0)
                                 FROM public.order_items i
                                 WHERE i.order_id = (SELECT id FROM ord)
                                   AND i.status::text <> 'void')
                              - (pago.recibido - pago.cambio))
  ) AS d
  FROM pago
),

-- 07 -------------------------------------------------------------
s07 AS (
  SELECT coalesce(jsonb_agg(x ORDER BY x->>'issued_at'), '[]'::jsonb) AS d
  FROM (
    SELECT jsonb_build_object(
      'ncf_number', fd.ncf_number, 'ncf_type', fd.ncf_type, 'status', fd.status,
      'customer_name', fd.customer_name, 'customer_rnc', fd.customer_rnc,
      'subtotal', fd.subtotal, 'discount', fd.discount,
      'tax_exempt', fd.tax_exempt, 'taxable_amount', fd.taxable_amount,
      'itbis_amount', fd.itbis_amount, 'service_fee', fd.service_fee,
      'tip', fd.tip, 'total', fd.total,
      'issued_at', fd.issued_at, 'payment_id', fd.payment_id,
      'is_electronic', fd.is_electronic, 'ecf_status', fd.ecf_status,
      'cancelled_at', fd.cancelled_at, 'cancellation_reason', fd.cancellation_reason,
      'DESCUADRE_VS_PAPEL', round((710.73 - fd.total)::numeric, 2)
    ) AS x
    FROM public.fiscal_documents fd
    WHERE fd.order_id = (SELECT id FROM ord)
  ) q
),

-- 08 -------------------------------------------------------------
s08 AS (
  SELECT coalesce(jsonb_agg(to_jsonb(v)), '[]'::jsonb) AS d
  FROM public.v_zone_table_status v
  WHERE v.table_id = (SELECT ts.table_id FROM public.table_sessions ts
                        WHERE ts.id = (SELECT session_id FROM ord))
),

-- 09 -------------------------------------------------------------
s09 AS (
  SELECT coalesce(jsonb_agg(to_jsonb(s) ORDER BY s.ncf_type), '[]'::jsonb) AS d
  FROM (
    SELECT ns.ncf_type, ns.prefix, ns.serie, ns.range_start, ns.range_end,
           ns.current_number, (ns.range_end - ns.current_number) AS restantes,
           ns.expiration_date, ns.is_active
    FROM public.ncf_sequences ns
    WHERE ns.business_id = 'f054fbc2-3fb7-4e34-a020-11341ff11d84'
  ) s
),

-- 10 -------------------------------------------------------------
s10 AS (
  SELECT jsonb_build_object(
    'checks_abiertos_en_orden_cerrada',
      (SELECT count(*)
         FROM public.order_checks oc
         JOIN public.orders o     ON o.id  = oc.order_id
         JOIN public.table_sessions ts ON ts.id = o.session_id
         JOIN public.dining_tables dt  ON dt.id = ts.table_id
         JOIN public.zones z           ON z.id  = dt.zone_id
        WHERE z.business_id = 'f054fbc2-3fb7-4e34-a020-11341ff11d84'
          AND oc.is_closed = false
          AND o.status_ext IN ('paid','void')),
    'ordenes_con_pago_pero_abiertas',
      (SELECT count(DISTINCT o.id)
         FROM public.orders o
         JOIN public.table_sessions ts ON ts.id = o.session_id
         JOIN public.dining_tables dt  ON dt.id = ts.table_id
         JOIN public.zones z           ON z.id  = dt.zone_id
        WHERE z.business_id = 'f054fbc2-3fb7-4e34-a020-11341ff11d84'
          AND o.status_ext NOT IN ('paid','void')
          AND EXISTS (SELECT 1 FROM public.payments p
                        WHERE p.order_id = o.id AND p.status = 'completed')),
    'ordenes_cobradas_de_menos_ult_30d',
      (SELECT count(*) FROM (
         SELECT o.id
           FROM public.orders o
           JOIN public.table_sessions ts ON ts.id = o.session_id
           JOIN public.dining_tables dt  ON dt.id = ts.table_id
           JOIN public.zones z           ON z.id  = dt.zone_id
          WHERE z.business_id = 'f054fbc2-3fb7-4e34-a020-11341ff11d84'
            AND o.status_ext = 'paid'
            AND o.closed_at > now() - interval '30 days'
          GROUP BY o.id
         HAVING (SELECT coalesce(sum(i.subtotal + i.tax - i.discounts),0)
                   FROM public.order_items i
                  WHERE i.order_id = o.id AND i.status::text <> 'void')
              - (SELECT coalesce(sum(p.amount - coalesce(p.change_amount,0)),0)
                   FROM public.payments p
                  WHERE p.order_id = o.id AND p.status = 'completed') > 1
       ) q)
  ) AS d
),

-- 11 -------------------------------------------------------------
s11 AS (
  SELECT jsonb_build_object(
    'close_order_cierra_checks',
      (SELECT pg_get_functiondef(p.oid) LIKE '%order_checks%is_closed = true%'
         FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
        WHERE n.nspname='public' AND p.proname='fn_close_order_and_table' LIMIT 1),
    'totals_excluye_items_paid',
      (SELECT pg_get_functiondef(p.oid) LIKE '%NOT IN (''paid'', ''void'')%'
         FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
        WHERE n.nspname='public' AND p.proname='calculate_order_totals' LIMIT 1),
    'totals_excluye_checks_cerrados',
      (SELECT pg_get_functiondef(p.oid) LIKE '%oc.is_closed%'
         FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
        WHERE n.nspname='public' AND p.proname='calculate_order_totals' LIMIT 1),
    'overloads_process_payment',
      (SELECT jsonb_agg(p.oid::regprocedure::text)
         FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
        WHERE n.nspname='public' AND p.proname LIKE 'fn_process_payment%')
  ) AS d
)

SELECT * FROM (
  SELECT  1 AS n, '01_ORDEN_SESION_MESA'      AS seccion, d AS detalle FROM s01
  UNION ALL SELECT  2, '02_ORDENES_HERMANAS',        d FROM s02
  UNION ALL SELECT  3, '03_PAGOS',                   d FROM s03
  UNION ALL SELECT  4, '04_CHECKS',                  d FROM s04
  UNION ALL SELECT  5, '05_ITEMS',                   d FROM s05
  UNION ALL SELECT  6, '06_CUADRE_PAPEL_VS_BD',      d FROM s06
  UNION ALL SELECT  7, '07_COMPROBANTE_FISCAL',      d FROM s07
  UNION ALL SELECT  8, '08_VISTA_DEL_SALON',         d FROM s08
  UNION ALL SELECT  9, '09_SECUENCIAS_NCF',          d FROM s09
  UNION ALL SELECT 10, '10_ALCANCE_EN_EL_NEGOCIO',   d FROM s10
  UNION ALL SELECT 11, '11_FUNCIONES_VIVAS',         d FROM s11
) t
ORDER BY n;
