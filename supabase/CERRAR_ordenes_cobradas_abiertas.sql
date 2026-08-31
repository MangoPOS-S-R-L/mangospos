-- =====================================================================
-- CERRAR las ordenes YA COBRADAS que quedaron en 'sent_to_kitchen'
-- Negocio: f054fbc2-3fb7-4e34-a020-11341ff11d84
--
-- QUE NO HACE (a proposito):
--  * NO toca `order_items`. Las vistas del KDS filtran por el estado del
--    ITEM (kds_active_items: pending/preparing/ready) y por
--    orders.kitchen_done_at (kds_open_orders) — NO por status_ext ni
--    closed_at. Si tocaramos los items, la comanda desapareceria del
--    tablero. Asi, lo que este en cocina SIGUE en cocina.
--  * NO toca `dining_tables` ni `table_sessions`, y por eso NO usa
--    fn_close_order_and_table: esa funcion termina con
--    `update dining_tables set state='available'` mirando solo la sesion
--    VIEJA. Como estas ordenes ya tienen su sesion cerrada, el contador
--    da 0 y liberaria la mesa aunque hoy tenga una sesion NUEVA viva o
--    este Reservada. Aqui solo arreglamos las banderas de la ORDEN.
--  * NO cierra ordenes cobradas a medias: exige que el dinero cubra los
--    items.
--
-- >>> PASO 1 primero. Leer. Recien despues PASO 2. <<<
-- =====================================================================

-- ---------------------------------------------------------------------
-- PASO 1 — DRY RUN. No escribe nada.
-- ---------------------------------------------------------------------
WITH biz AS (SELECT 'f054fbc2-3fb7-4e34-a020-11341ff11d84'::uuid AS id),
cand AS (
  SELECT
    o.id,
    o.created_at,
    o.closed_at,
    (SELECT coalesce(sum(p.amount - coalesce(p.change_amount,0)),0)
       FROM public.payments p
      WHERE p.order_id = o.id AND p.status = 'completed')      AS cobrado,
    (SELECT coalesce(sum(i.subtotal + i.tax - i.discounts),0)
       FROM public.order_items i
      WHERE i.order_id = o.id AND i.status::text <> 'void')    AS valor_items,
    (SELECT count(*) FROM public.order_items i
      WHERE i.order_id = o.id
        AND i.status::text IN ('pending','preparing','ready')) AS items_en_tablero,
    (ts.closed_at IS NULL)                                     AS sesion_abierta,
    (o.kitchen_done_at IS NULL AND o.created_at >= now() - interval '2 days')
                                                               AS visible_en_kds_abiertas
  FROM public.orders o
  JOIN public.table_sessions ts ON ts.id = o.session_id
  JOIN public.dining_tables dt  ON dt.id = ts.table_id
  JOIN public.zones z           ON z.id  = dt.zone_id, biz
  WHERE z.business_id = biz.id
    AND o.status_ext NOT IN ('paid','void')
    AND EXISTS (SELECT 1 FROM public.payments p
                  WHERE p.order_id = o.id AND p.status = 'completed')
)
SELECT
  CASE WHEN cobrado + 1 >= valor_items
       THEN 'SE CIERRA'
       ELSE 'NO SE TOCA — el cobro no cubre los items' END  AS decision,
  count(*)                                                  AS ordenes,
  round(sum(cobrado)::numeric, 2)                           AS cobrado,
  round(sum(valor_items)::numeric, 2)                       AS valor_items,
  round(sum(greatest(valor_items - cobrado, 0))::numeric,2) AS faltante,
  -- estas dos NO bloquean: son informativas. Cerrar la orden no las mueve.
  count(*) FILTER (WHERE items_en_tablero > 0)              AS con_items_en_cocina,
  count(*) FILTER (WHERE visible_en_kds_abiertas)           AS visibles_en_kds_hoy,
  -- esta SI importa: si hubiera alguna con la sesion abierta, revisar antes
  count(*) FILTER (WHERE sesion_abierta)                    AS OJO_sesion_abierta,
  min(created_at) AS mas_vieja,
  max(created_at) AS mas_nueva
FROM cand
GROUP BY 1
ORDER BY 1;


-- ---------------------------------------------------------------------
-- PASO 2 — APLICAR. Descomentar y correr.
-- Idempotente y transaccional. Solo escribe en `orders` y `order_checks`.
-- ---------------------------------------------------------------------
/*
BEGIN;

CREATE TEMP TABLE _a_cerrar ON COMMIT DROP AS
SELECT o.id
FROM public.orders o
JOIN public.table_sessions ts ON ts.id = o.session_id
JOIN public.dining_tables dt  ON dt.id = ts.table_id
JOIN public.zones z           ON z.id  = dt.zone_id
WHERE z.business_id = 'f054fbc2-3fb7-4e34-a020-11341ff11d84'
  AND o.status_ext NOT IN ('paid','void')
  AND EXISTS (SELECT 1 FROM public.payments p
                WHERE p.order_id = o.id AND p.status = 'completed')
  -- el cobro cubre los items: nada a medio pagar se marca como pagado
  AND (SELECT coalesce(sum(p.amount - coalesce(p.change_amount,0)),0)
         FROM public.payments p
        WHERE p.order_id = o.id AND p.status = 'completed') + 1
      >= (SELECT coalesce(sum(i.subtotal + i.tax - i.discounts),0)
            FROM public.order_items i
           WHERE i.order_id = o.id AND i.status::text <> 'void')
  -- guarda extra: la sesion ya debe estar cerrada. Si alguna tiene la
  -- mesa viva, se queda fuera y se revisa a mano.
  AND ts.closed_at IS NOT NULL;

SELECT count(*) AS van_a_cerrarse FROM _a_cerrar;

-- BASELINE del KDS, ANTES de tocar nada y sobre el MISMO conjunto de
-- ordenes. Tiene que medirse asi: una consulta de "antes" que filtre por
-- status_ext no sirve, porque el UPDATE cambia justamente esa columna y el
-- numero bajaria por el filtro, no porque algo saliera del tablero.
SELECT count(*) AS items_en_kds_ANTES
FROM public.order_items i
WHERE i.order_id IN (SELECT id FROM _a_cerrar)
  AND i.status::text IN ('pending','preparing','ready');

-- la orden: banderas al dia. closed_at = el momento del ultimo cobro.
UPDATE public.orders o
SET status_ext = 'paid',
    status     = 'paid',
    closed_at  = COALESCE(o.closed_at,
                          (SELECT max(p.created_at) FROM public.payments p
                            WHERE p.order_id = o.id AND p.status = 'completed'),
                          now())
WHERE o.id IN (SELECT id FROM _a_cerrar);

-- los checks de esas ordenes, igual que hace fn_close_order_and_table
UPDATE public.order_checks c
SET is_closed = true,
    closed_at = now()
WHERE c.order_id IN (SELECT id FROM _a_cerrar)
  AND COALESCE(c.is_closed, false) = false;

-- VERIFICACION dentro de la transaccion:
--  a) no debe quedar ninguna cubierta sin cerrar
SELECT count(*) AS quedan_sin_cerrar
FROM public.orders o
JOIN public.table_sessions ts ON ts.id = o.session_id
JOIN public.dining_tables dt  ON dt.id = ts.table_id
JOIN public.zones z           ON z.id  = dt.zone_id
WHERE z.business_id = 'f054fbc2-3fb7-4e34-a020-11341ff11d84'
  AND o.status_ext NOT IN ('paid','void')
  AND ts.closed_at IS NOT NULL
  AND EXISTS (SELECT 1 FROM public.payments p
                WHERE p.order_id = o.id AND p.status = 'completed')
  AND (SELECT coalesce(sum(p.amount - coalesce(p.change_amount,0)),0)
         FROM public.payments p
        WHERE p.order_id = o.id AND p.status = 'completed') + 1
      >= (SELECT coalesce(sum(i.subtotal + i.tax - i.discounts),0)
            FROM public.order_items i
           WHERE i.order_id = o.id AND i.status::text <> 'void');

--  b) el KDS no se movio: este numero tiene que ser IDENTICO al de
--     `items_en_kds_ANTES` de arriba. Mismo conjunto de ordenes, misma
--     condicion, sin mirar status_ext.
SELECT count(*) AS items_en_kds_DESPUES
FROM public.order_items i
WHERE i.order_id IN (SELECT id FROM _a_cerrar)
  AND i.status::text IN ('pending','preparing','ready');

-- Si (a) = 0 y items_en_kds_DESPUES == items_en_kds_ANTES:  COMMIT;
-- Si algo no cuadra:                                 ROLLBACK;
COMMIT;
*/
