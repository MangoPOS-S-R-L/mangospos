-- =====================================================================
-- Insumos en negativo que en realidad son RECETAS
-- Negocio: f054fbc2-3fb7-4e34-a020-11341ff11d84
--
-- Sintoma: Moscow Mule -22, Caipiriña -22, Daiquiri Fresa -17...
-- Un coctel no se compra: se prepara. Pero al marcar el producto como
-- "Inventariable" el sistema le crea un insumo propio + una auto-receta
-- 1:1, y cada venta descuenta ese insumo fantasma que nadie recibe nunca.
--
-- La firma del insumo fantasma: tiene movimientos de VENTA pero cero de
-- COMPRA, y hay un menu_item del mismo nombre apuntandole.
--
-- SOLO LECTURA. Una sola ejecucion -> un solo resultado.
-- =====================================================================

WITH biz AS (SELECT 'f054fbc2-3fb7-4e34-a020-11341ff11d84'::uuid AS id),

item AS (
  SELECT
    ii.id,
    ii.name,
    ii.sku,
    ii.unit,
    ii.cost,
    ii.is_active,
    coalesce((SELECT sum(s.quantity) FROM public.inventory_stock s
               WHERE s.item_id = ii.id), 0)                       AS stock,
    coalesce((SELECT sum(m.quantity) FROM public.inventory_movements m
               WHERE m.item_id = ii.id AND m.movement_type = 'purchase'), 0)
                                                                  AS comprado,
    coalesce((SELECT abs(sum(m.quantity)) FROM public.inventory_movements m
               WHERE m.item_id = ii.id AND m.movement_type = 'sale'), 0)
                                                                  AS vendido,
    (SELECT count(*) FROM public.inventory_movements m
      WHERE m.item_id = ii.id AND m.movement_type = 'adjustment')  AS ajustes,
    -- el producto del menu que lo consume
    (SELECT jsonb_agg(jsonb_build_object(
        'menu_item_id', mi.id,
        'nombre',       mi.name,
        'precio',       mi.price,
        'inventariable', mi.is_inventory_tracked,
        'via',          CASE WHEN mi.inventory_item_id = ii.id
                             THEN 'link directo' ELSE 'receta' END,
        'mismo_nombre', (lower(trim(mi.name)) = lower(trim(ii.name)))
      ))
      FROM public.menu_items mi
      LEFT JOIN public.recipes r  ON r.menu_item_id = mi.id
      LEFT JOIN public.recipe_ingredients ri
             ON ri.recipe_id = r.id AND ri.inventory_item_id = ii.id
      WHERE mi.business_id = (SELECT id FROM biz)
        AND (mi.inventory_item_id = ii.id OR ri.id IS NOT NULL)
    )                                                             AS productos,
    -- ¿su receta tiene OTROS ingredientes ademas de si mismo? Si no, es 1:1
    (SELECT count(*)
       FROM public.menu_items mi
       JOIN public.recipes r ON r.menu_item_id = mi.id
       JOIN public.recipe_ingredients ri ON ri.recipe_id = r.id
      WHERE mi.business_id = (SELECT id FROM biz)
        AND mi.name = ii.name
        AND ri.inventory_item_id <> ii.id)                        AS otros_ingredientes
  FROM public.inventory_items ii, biz
  WHERE ii.business_id = biz.id
),

-- 1) los sospechosos: se consumen y NUNCA se compraron
s1 AS (
  SELECT coalesce(jsonb_agg(to_jsonb(x) ORDER BY x.stock ASC), '[]'::jsonb) AS d
  FROM (
    SELECT name, sku, unit, stock, comprado, vendido, ajustes,
           otros_ingredientes, productos, id
    FROM item
    WHERE stock < 0
      AND comprado = 0
    ORDER BY stock ASC
    LIMIT 60
  ) x
),

-- 2) el resumen
s2 AS (
  SELECT jsonb_build_object(
    'insumos_del_negocio',        count(*),
    'en_negativo',                count(*) FILTER (WHERE stock < 0),
    'NEGATIVO_Y_NUNCA_COMPRADO',  count(*) FILTER (WHERE stock < 0 AND comprado = 0),
    'negativo_pero_si_se_compra', count(*) FILTER (WHERE stock < 0 AND comprado > 0),
    'unidades_en_rojo',           round(sum(least(stock, 0))::numeric, 2),
    'nota', 'los "nunca comprado" son los que probablemente deban ser receta'
  ) AS d
  FROM item
),

-- 3) los que YA tienen receta real (mas de un ingrediente): esos estan bien
s3 AS (
  SELECT coalesce(jsonb_agg(to_jsonb(y) ORDER BY y.stock ASC), '[]'::jsonb) AS d
  FROM (
    SELECT name, stock, comprado, vendido, otros_ingredientes
    FROM item
    WHERE stock < 0 AND otros_ingredientes > 0
    LIMIT 30
  ) y
),

-- 4) productos del menu marcados Inventariable con link directo a un
--    insumo del MISMO nombre = la firma exacta del auto-insumo
s4 AS (
  SELECT jsonb_build_object(
    'productos_inventariables',   count(*),
    'con_link_directo',           count(*) FILTER (WHERE mi.inventory_item_id IS NOT NULL),
    'link_a_insumo_mismo_nombre', count(*) FILTER (
        WHERE mi.inventory_item_id IS NOT NULL
          AND lower(trim(ii2.name)) = lower(trim(mi.name)))
  ) AS d
  FROM public.menu_items mi
  LEFT JOIN public.inventory_items ii2 ON ii2.id = mi.inventory_item_id, biz
  WHERE mi.business_id = biz.id
    AND mi.is_inventory_tracked = true
)

SELECT * FROM (
  SELECT 1 AS n, '1_SOSPECHOSOS_negativo_sin_compras' AS seccion, d AS detalle FROM s1
  UNION ALL SELECT 2, '2_RESUMEN',                d FROM s2
  UNION ALL SELECT 3, '3_NEGATIVOS_CON_RECETA_REAL', d FROM s3
  UNION ALL SELECT 4, '4_FIRMA_AUTO_INSUMO',      d FROM s4
) t ORDER BY n;
