-- ============================================================================
-- DAÑO REAL de las órdenes huérfanas: DOBLE DESCUENTO DE INVENTARIO
-- ============================================================================
-- El mesero reteclea la orden que "desapareció", así que la VENTA sí se cobra
-- (la caja cuadra y por eso nadie lo reportó en 4 meses). Lo que se duplica es
-- el consumo de insumos:
--
--   fn_confirm_order_to_kitchen → consume_inventory_from_order(order_id)
--   y esa función deduplica por `reference_id = _order_id`.
--   La orden reteclada tiene OTRO order_id → descuenta de nuevo.
--
-- Resultado: por cada orden huérfana cuya comanda salió, el almacén se comió
-- una ración extra de insumos. Invisible en ventas; aparece como merma en el
-- conteo físico.
--
-- Solo lectura. Correr bloque por bloque.
-- ============================================================================

-- Definición compartida (repetida en cada bloque para poder correrlos sueltos)
-- huérfana = sesión cerrada + orden viva + ítems sin cobrar

-- ─── 1) ¿CUÁNTAS HUÉRFANAS TIENEN UNA "GEMELA" RETECLEADA? ────────────────
-- Confirma con datos lo que dice el mesero. Gemela = otra orden del MISMO
-- negocio, creada DESPUÉS de la huérfana (hasta 3 h), que comparte al menos un
-- producto. `min_seg` cerca de cero = la retecleó en caliente.
WITH huerfanas AS (
  SELECT o.id AS order_id,
         coalesce(ts.business_id, z.business_id) AS business_id,
         o.created_at
    FROM public.orders o
    JOIN public.table_sessions ts ON ts.id = o.session_id
    LEFT JOIN public.dining_tables dt ON dt.id = ts.table_id
    LEFT JOIN public.zones z ON z.id = dt.zone_id
   WHERE ts.closed_at IS NOT NULL
     AND o.closed_at IS NULL
     AND o.status_ext NOT IN ('paid','void')
     AND EXISTS (SELECT 1 FROM public.order_items oi
                  WHERE oi.order_id = o.id AND oi.status NOT IN ('void','paid'))
)
SELECT
  '1_RETECLADO'                                        AS seccion,
  b.business_name,
  count(*)                                             AS huerfanas,
  count(*) FILTER (WHERE g.gemela_id IS NOT NULL)      AS con_gemela,
  count(*) FILTER (WHERE g.gemela_id IS NULL)          AS sin_gemela_posible_perdida_real,
  round(avg(g.seg_despues) FILTER (WHERE g.gemela_id IS NOT NULL)) AS seg_promedio_al_reteclear
FROM huerfanas h
LEFT JOIN public.businesses b ON b.id = h.business_id
LEFT JOIN LATERAL (
  SELECT o2.id AS gemela_id,
         EXTRACT(EPOCH FROM (o2.created_at - h.created_at)) AS seg_despues
    FROM public.orders o2
    JOIN public.table_sessions ts2 ON ts2.id = o2.session_id
    LEFT JOIN public.dining_tables dt2 ON dt2.id = ts2.table_id
    LEFT JOIN public.zones z2 ON z2.id = dt2.zone_id
   WHERE coalesce(ts2.business_id, z2.business_id) = h.business_id
     AND o2.id <> h.order_id
     AND o2.created_at >  h.created_at
     AND o2.created_at <= h.created_at + interval '3 hours'
     AND EXISTS (
           SELECT 1
             FROM public.order_items a
             JOIN public.order_items c ON c.product_id = a.product_id
            WHERE a.order_id = h.order_id
              AND c.order_id = o2.id
              AND a.product_id IS NOT NULL
         )
   ORDER BY o2.created_at
   LIMIT 1
) g ON true
GROUP BY b.business_name
ORDER BY huerfanas DESC;


-- ─── 2) LOS PARES, UNO POR UNO (para verlo con ojos) ──────────────────────
-- Si `productos_huerfana` y `productos_gemela` se parecen, fue reteclado.
WITH huerfanas AS (
  SELECT o.id AS order_id,
         coalesce(ts.business_id, z.business_id) AS business_id,
         o.created_at, dt.code AS mesa, ts.customer_name
    FROM public.orders o
    JOIN public.table_sessions ts ON ts.id = o.session_id
    LEFT JOIN public.dining_tables dt ON dt.id = ts.table_id
    LEFT JOIN public.zones z ON z.id = dt.zone_id
   WHERE ts.closed_at IS NOT NULL
     AND o.closed_at IS NULL
     AND o.status_ext NOT IN ('paid','void')
     AND EXISTS (SELECT 1 FROM public.order_items oi
                  WHERE oi.order_id = o.id AND oi.status NOT IN ('void','paid'))
)
SELECT
  '2_PARES'                                            AS seccion,
  b.business_name,
  h.mesa, h.customer_name,
  upper(left(h.order_id::text, 8))                     AS huerfana,
  h.created_at AT TIME ZONE 'America/Santo_Domingo'    AS huerfana_local,
  upper(left(g.gemela_id::text, 8))                    AS gemela,
  round(g.seg_despues)                                 AS seg_despues,
  (SELECT string_agg(oi.product_name, ' | ' ORDER BY oi.product_name)
     FROM public.order_items oi WHERE oi.order_id = h.order_id)  AS productos_huerfana,
  (SELECT string_agg(oi.product_name, ' | ' ORDER BY oi.product_name)
     FROM public.order_items oi WHERE oi.order_id = g.gemela_id) AS productos_gemela
FROM huerfanas h
LEFT JOIN public.businesses b ON b.id = h.business_id
LEFT JOIN LATERAL (
  SELECT o2.id AS gemela_id,
         EXTRACT(EPOCH FROM (o2.created_at - h.created_at)) AS seg_despues
    FROM public.orders o2
    JOIN public.table_sessions ts2 ON ts2.id = o2.session_id
    LEFT JOIN public.dining_tables dt2 ON dt2.id = ts2.table_id
    LEFT JOIN public.zones z2 ON z2.id = dt2.zone_id
   WHERE coalesce(ts2.business_id, z2.business_id) = h.business_id
     AND o2.id <> h.order_id
     AND o2.created_at >  h.created_at
     AND o2.created_at <= h.created_at + interval '3 hours'
     AND EXISTS (SELECT 1 FROM public.order_items a
                   JOIN public.order_items c ON c.product_id = a.product_id
                  WHERE a.order_id = h.order_id AND c.order_id = o2.id
                    AND a.product_id IS NOT NULL)
   ORDER BY o2.created_at
   LIMIT 1
) g ON true
ORDER BY h.created_at DESC;


-- ─── 3) EL DAÑO: insumos descontados de más, valorados ────────────────────
-- Movimientos 'sale' que apuntan a una orden huérfana. Como la venta se cobró
-- en la orden reteclada (que descontó por su cuenta), TODO esto es consumo
-- duplicado. Valorado a `inventory_items.cost` (que en esta base es el ÚLTIMO
-- precio de compra, no un promedio).
WITH huerfanas AS (
  SELECT o.id AS order_id
    FROM public.orders o
    JOIN public.table_sessions ts ON ts.id = o.session_id
   WHERE ts.closed_at IS NOT NULL
     AND o.closed_at IS NULL
     AND o.status_ext NOT IN ('paid','void')
     AND EXISTS (SELECT 1 FROM public.order_items oi
                  WHERE oi.order_id = o.id AND oi.status NOT IN ('void','paid'))
)
SELECT
  '3_DOBLE_INVENTARIO'                                 AS seccion,
  b.business_name,
  count(DISTINCT im.reference_id)                      AS ordenes_que_descontaron,
  count(*)                                             AS movimientos,
  count(DISTINCT im.item_id)                           AS insumos_distintos,
  round(sum(abs(im.quantity) * coalesce(ii.cost, 0)), 2) AS costo_duplicado
FROM public.inventory_movements im
JOIN public.inventory_items ii ON ii.id = im.item_id
LEFT JOIN public.businesses b ON b.id = im.business_id
WHERE im.movement_type = 'sale'
  AND im.reference_type = 'order'
  AND im.reference_id IN (SELECT order_id FROM huerfanas)
GROUP BY b.business_name
ORDER BY costo_duplicado DESC NULLS LAST;


-- ─── 4) TOP INSUMOS DESCONTADOS DE MÁS (munición para el conteo físico) ───
-- Estos son los insumos que el sistema cree que se gastaron y no se gastaron.
-- Si el cliente reclama merma en alguno de estos, aquí está la explicación.
WITH huerfanas AS (
  SELECT o.id AS order_id
    FROM public.orders o
    JOIN public.table_sessions ts ON ts.id = o.session_id
   WHERE ts.closed_at IS NOT NULL
     AND o.closed_at IS NULL
     AND o.status_ext NOT IN ('paid','void')
     AND EXISTS (SELECT 1 FROM public.order_items oi
                  WHERE oi.order_id = o.id AND oi.status NOT IN ('void','paid'))
)
SELECT
  '4_TOP_INSUMOS'                                      AS seccion,
  b.business_name,
  ii.name                                              AS insumo,
  ii.unit,
  round(sum(abs(im.quantity)), 3)                      AS cantidad_de_mas,
  round(sum(abs(im.quantity) * coalesce(ii.cost, 0)), 2) AS costo,
  count(*)                                             AS veces
FROM public.inventory_movements im
JOIN public.inventory_items ii ON ii.id = im.item_id
LEFT JOIN public.businesses b ON b.id = im.business_id
WHERE im.movement_type = 'sale'
  AND im.reference_type = 'order'
  AND im.reference_id IN (SELECT order_id FROM huerfanas)
GROUP BY b.business_name, ii.name, ii.unit
ORDER BY costo DESC NULLS LAST
LIMIT 60;


-- ─── 5) ¿HAY COMANDAS HUÉRFANAS PEGADAS EN EL KDS? ────────────────────────
-- `kds_open_orders` filtra kitchen_done_at IS NULL. La tarjeta de una huérfana
-- no la despacha nadie porque la mesa ya no existe: se queda en el tablero.
SELECT
  '5_KDS_PEGADAS'                                      AS seccion,
  b.business_name,
  dt.code                                              AS mesa,
  upper(left(o.id::text, 8))                           AS orden_num,
  o.created_at AT TIME ZONE 'America/Santo_Domingo'    AS creada_local,
  o.kitchen_done_at,
  count(oi.id) FILTER (WHERE oi.status IN ('pending','preparing')) AS items_en_cocina
FROM public.orders o
JOIN public.table_sessions ts ON ts.id = o.session_id
LEFT JOIN public.dining_tables dt ON dt.id = ts.table_id
LEFT JOIN public.zones z ON z.id = dt.zone_id
LEFT JOIN public.businesses b ON b.id = coalesce(ts.business_id, z.business_id)
JOIN public.order_items oi ON oi.order_id = o.id
WHERE ts.closed_at IS NOT NULL
  AND o.closed_at IS NULL
  AND o.status_ext NOT IN ('paid','void')
  AND o.kitchen_done_at IS NULL
GROUP BY b.business_name, dt.code, o.id, o.created_at, o.kitchen_done_at
HAVING count(oi.id) FILTER (WHERE oi.status IN ('pending','preparing')) > 0
ORDER BY o.created_at DESC;
