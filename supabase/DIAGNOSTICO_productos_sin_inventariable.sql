-- =============================================================================
-- LA PENDA EXPRESS — ¿qué productos NO están marcados como Inventariable?
-- business_id = 35c5076a-bd85-4a1b-8d1c-ce719c4f9ae6
--
-- CORRER UNA SENTENCIA A LA VEZ: el SQL Editor de Supabase solo muestra el
-- resultado de la ÚLTIMA sentencia del script.
--
-- Solo LECTURA. No cambia nada.
-- =============================================================================

-- ---------------------------------------------------------------------------
-- 1. RESUMEN — cuántos hay de cada tipo y qué pasaría al activarlos
-- ---------------------------------------------------------------------------
with prod as (
  select mi.id,
         mi.name,
         mi.price,
         mi.sku,
         mi.is_inventory_tracked,
         mi.inventory_item_id,
         lower(btrim(mi.name))  as nombre_norm,
         nullif(btrim(mi.sku), '') as sku_norm
  from public.menu_items mi
  where mi.business_id = '35c5076a-bd85-4a1b-8d1c-ce719c4f9ae6'
    and coalesce(mi.is_active, true)
),
ins as (
  select ii.id,
         lower(btrim(ii.name))  as nombre_norm,
         nullif(btrim(ii.sku), '') as sku_norm
  from public.inventory_items ii
  where ii.business_id = '35c5076a-bd85-4a1b-8d1c-ce719c4f9ae6'
    and coalesce(ii.is_active, true)
),
receta as (
  select distinct r.menu_item_id
  from public.recipes r
  join public.recipe_ingredients ri on ri.recipe_id = r.id
  where r.menu_item_id in (select id from prod)
),
clasificado as (
  select p.*,
         (p.id in (select menu_item_id from receta)) as tiene_receta,
         -- Si ya existe un insumo con ese SKU o nombre, la activación lo
         -- REUSA en vez de crear ficha nueva (así lo hace el RPC).
         coalesce(
           (select i.id from ins i
             where i.sku_norm is not null and i.sku_norm = p.sku_norm limit 1),
           (select i.id from ins i
             where i.nombre_norm = p.nombre_norm limit 1)
         ) as insumo_existente
  from prod p
)
select
  count(*)                                                  as productos_activos,
  count(*) filter (where is_inventory_tracked)              as ya_inventariables,
  count(*) filter (where not is_inventory_tracked
                     and tiene_receta)                      as con_receta_NO_TOCAR,
  count(*) filter (where not is_inventory_tracked
                     and not tiene_receta
                     and inventory_item_id is not null)     as enlace_ya_hecho_flag_apagado,
  count(*) filter (where not is_inventory_tracked
                     and not tiene_receta
                     and inventory_item_id is null
                     and coalesce(price, 0) = 0)            as precio_cero_revisar,
  count(*) filter (where not is_inventory_tracked
                     and not tiene_receta
                     and inventory_item_id is null
                     and coalesce(price, 0) > 0
                     and insumo_existente is not null)       as candidatos_REUSAN_insumo,
  count(*) filter (where not is_inventory_tracked
                     and not tiene_receta
                     and inventory_item_id is null
                     and coalesce(price, 0) > 0
                     and insumo_existente is null)           as candidatos_CREAN_insumo
from clasificado;


-- ---------------------------------------------------------------------------
-- 2. LISTADO de los candidatos, priorizado por ventas de 90 días
--
--    `accion` dice qué haría la activación con cada uno.
--    Las ventas se agregan UNA vez con GROUP BY: una subconsulta por fila
--    sobre order_items revienta el editor (devuelve un error de Zod raro,
--    que es un timeout disfrazado).
-- ---------------------------------------------------------------------------
with prod as (
  select mi.id, mi.name, mi.price, mi.cost, mi.sku, mi.barcode,
         mi.category_id, mi.is_inventory_tracked, mi.inventory_item_id,
         lower(btrim(mi.name))  as nombre_norm,
         nullif(btrim(mi.sku), '') as sku_norm
  from public.menu_items mi
  where mi.business_id = '35c5076a-bd85-4a1b-8d1c-ce719c4f9ae6'
    and coalesce(mi.is_active, true)
),
ins as (
  select ii.id, ii.name,
         lower(btrim(ii.name))  as nombre_norm,
         nullif(btrim(ii.sku), '') as sku_norm
  from public.inventory_items ii
  where ii.business_id = '35c5076a-bd85-4a1b-8d1c-ce719c4f9ae6'
    and coalesce(ii.is_active, true)
),
receta as (
  select distinct r.menu_item_id
  from public.recipes r
  join public.recipe_ingredients ri on ri.recipe_id = r.id
  where r.menu_item_id in (select id from prod)
),
ventas as (
  select oi.product_id, sum(coalesce(oi.qty, oi.quantity::numeric)) as unidades_90d
  from public.order_items oi
  where oi.created_at >= now() - interval '90 days'
    and oi.product_id in (select id from prod)
  group by oi.product_id
)
select
  p.name                                   as producto,
  c.name                                   as categoria,
  p.price                                  as precio,
  p.cost                                   as costo,
  coalesce(p.sku, '')                      as sku,
  coalesce(p.barcode, '')                  as codigo_barras,
  round(coalesce(v.unidades_90d, 0), 2)    as vendidas_90d,
  i.name                                   as insumo_que_reusaria,
  case
    when p.id in (select menu_item_id from receta) then 'TIENE RECETA — no activar'
    when p.inventory_item_id is not null          then 'ya enlazado, solo falta el flag'
    when coalesce(p.price, 0) = 0                 then 'precio 0 — revisar (servicio/cargo)'
    when i.id is not null                         then 'reusa insumo existente'
    else                                               'crea insumo nuevo'
  end                                      as accion
from prod p
left join public.categories c on c.id = p.category_id
left join ventas v on v.product_id = p.id
left join lateral (
  select x.id, x.name from ins x
   where (x.sku_norm is not null and x.sku_norm = p.sku_norm)
      or x.nombre_norm = p.nombre_norm
   order by (x.sku_norm is not null and x.sku_norm = p.sku_norm) desc
   limit 1
) i on true
where not p.is_inventory_tracked
order by coalesce(v.unidades_90d, 0) desc, p.name;


-- ---------------------------------------------------------------------------
-- 3. SEGMENTAR los que crearían ficha nueva: ¿reventa o preparado?
--
--    La diferencia no es de opinión: la REVENTA está físicamente en el
--    anaquel como esa misma unidad (una Pringles, una Presidente), así que
--    se compra, se cuenta y se vende 1:1. El PREPARADO se hace en el momento
--    con insumos que YA existen (café, leche, plátano): darle stock propio
--    crea una ficha que nadie compra nunca y que solo baja.
--
--    Señal usada: código de barras cargado, o un SKU con pinta de EAN/UPC.
--    Los SKU internos de Penda son cortos ("1028") o con ceros a la
--    izquierda ("00000514"), así que se descartan.
-- ---------------------------------------------------------------------------
with prod as (
  select mi.id, mi.name, mi.price, mi.cost, mi.sku, mi.barcode, mi.category_id
  from public.menu_items mi
  where mi.business_id = '35c5076a-bd85-4a1b-8d1c-ce719c4f9ae6'
    and coalesce(mi.is_active, true)
    and not mi.is_inventory_tracked
    and mi.inventory_item_id is null
),
clasif as (
  select p.*,
    case
      when coalesce(btrim(p.barcode), '') <> ''            then 'reventa (código de barras)'
      when coalesce(btrim(p.sku), '') ~ '^[0-9]{8,14}$'
       and coalesce(btrim(p.sku), '') !~ '^000'            then 'reventa probable (SKU tipo EAN)'
      else                                                      'preparado/servicio (SKU interno)'
    end as tipo
  from prod p
)
select tipo, count(*) as productos, round(avg(price), 2) as precio_promedio
from clasif
group by tipo
order by productos desc;


-- ---------------------------------------------------------------------------
-- 4. LOS NO-INVENTARIABLES, POR CATEGORÍA
--
--    Sirve para decidir por bloque en vez de producto por producto. Mira dos
--    columnas: `con_codigo` (cuántos traen código de barras o SKU tipo EAN =
--    reventa segura) y los ejemplos. Una categoría con casi todos "con
--    código" es tienda; una con casi ninguno es cocina.
--
--    OJO: las categorías de Penda están revueltas (hay un KINDER JOY en
--    CROISSANTS y bebidas en TEQUILA), así que el bloque orienta, no decide.
-- ---------------------------------------------------------------------------
with prod as (
  select mi.id, mi.name, mi.price, mi.sku, mi.barcode, mi.category_id,
         (coalesce(btrim(mi.barcode), '') <> ''
          or (coalesce(btrim(mi.sku), '') ~ '^[0-9]{8,14}$'
              and coalesce(btrim(mi.sku), '') !~ '^000')) as tiene_codigo
  from public.menu_items mi
  where mi.business_id = '35c5076a-bd85-4a1b-8d1c-ce719c4f9ae6'
    and coalesce(mi.is_active, true)
    and not mi.is_inventory_tracked
    and mi.inventory_item_id is null
)
select
  coalesce(c.name, '(sin categoría)')            as categoria,
  count(*)                                       as no_inventariables,
  count(*) filter (where p.tiene_codigo)         as con_codigo,
  count(*) filter (where not p.tiene_codigo)     as sin_codigo,
  round(avg(p.price), 2)                         as precio_promedio,
  string_agg(p.name, ' · ' order by p.name)
    filter (where p.tiene_codigo)                as ejemplos_con_codigo
from prod p
left join public.categories c on c.id = p.category_id
group by coalesce(c.name, '(sin categoría)')
order by no_inventariables desc;


-- ---------------------------------------------------------------------------
-- 5. ⚠️ LO MÁS IMPORTANTE ANTES DE CREAR NADA:
--    ¿cuántos de esos productos YA EXISTEN como insumo, emparejados por
--    CÓDIGO CRUZADO?
--
--    POR QUÉ CRUZADO: en este catálogo el mismo EAN vive en campos distintos
--    según la ficha — en el producto suele estar en `barcode` y en el insumo
--    en `sku` (o al revés). Comparar sku↔sku y nombre↔nombre, que es lo que
--    hace el RPC, deja pasar como "nuevo" un producto cuyo insumo ya existe.
--    Crear la ficha igual DUPLICA el maestro y mete dos renglones por
--    producto en el conteo.
--
--    Acá se juntan los códigos de los dos campos de cada lado y se compara
--    contra todos. Solo coincidencia EXACTA de código: nada de parecidos.
-- ---------------------------------------------------------------------------
with prod_cod as (
  select mi.id, mi.name, cod
  from public.menu_items mi
  cross join lateral (
    values (nullif(btrim(mi.barcode), '')), (nullif(btrim(mi.sku), ''))
  ) as c(cod)
  where mi.business_id = '35c5076a-bd85-4a1b-8d1c-ce719c4f9ae6'
    and coalesce(mi.is_active, true)
    and not mi.is_inventory_tracked
    and mi.inventory_item_id is null
    and c.cod is not null
    -- Un código de verdad: al menos 6 dígitos. Descarta los SKU internos
    -- cortos ("1028"), que son numeración de Penda y no identifican nada.
    and c.cod ~ '^[0-9]{6,14}$'
),
ins_cod as (
  select ii.id, ii.name, cod
  from public.inventory_items ii
  cross join lateral (
    values (nullif(btrim(ii.barcode), '')), (nullif(btrim(ii.sku), ''))
  ) as c(cod)
  where ii.business_id = '35c5076a-bd85-4a1b-8d1c-ce719c4f9ae6'
    and coalesce(ii.is_active, true)
    and c.cod is not null
    and c.cod ~ '^[0-9]{6,14}$'
),
emparejado as (
  select distinct p.id as menu_item_id, p.name as producto,
         i.id as insumo_id, i.name as insumo, p.cod as codigo
  from prod_cod p
  join ins_cod i on i.cod = p.cod
)
select
  count(distinct menu_item_id) as productos_que_YA_TIENEN_insumo_por_codigo,
  count(distinct insumo_id)    as insumos_involucrados,
  count(*)                     as pares_encontrados
from emparejado;


-- ---------------------------------------------------------------------------
-- 5b. El detalle de esos pares — para revisar a ojo antes de enlazar.
--     Si aparecen nombres que no tienen nada que ver, ese código está mal
--     cargado en una de las dos fichas y hay que arreglarlo, no enlazarlo.
-- ---------------------------------------------------------------------------
with prod_cod as (
  select mi.id, mi.name, cod
  from public.menu_items mi
  cross join lateral (
    values (nullif(btrim(mi.barcode), '')), (nullif(btrim(mi.sku), ''))
  ) as c(cod)
  where mi.business_id = '35c5076a-bd85-4a1b-8d1c-ce719c4f9ae6'
    and coalesce(mi.is_active, true)
    and not mi.is_inventory_tracked
    and mi.inventory_item_id is null
    and c.cod is not null
    and c.cod ~ '^[0-9]{6,14}$'
),
ins_cod as (
  select ii.id, ii.name, cod
  from public.inventory_items ii
  cross join lateral (
    values (nullif(btrim(ii.barcode), '')), (nullif(btrim(ii.sku), ''))
  ) as c(cod)
  where ii.business_id = '35c5076a-bd85-4a1b-8d1c-ce719c4f9ae6'
    and coalesce(ii.is_active, true)
    and c.cod is not null
    and c.cod ~ '^[0-9]{6,14}$'
)
select distinct
  p.cod                                              as codigo,
  p.name                                             as producto,
  i.name                                             as insumo_existente,
  case when lower(btrim(p.name)) = lower(btrim(i.name))
       then 'nombre idéntico'
       else '⚠ nombres distintos — revisar' end      as señal
from prod_cod p
join ins_cod i on i.cod = p.cod
order by señal desc, p.name;


-- ---------------------------------------------------------------------------
-- 6. ÚLTIMO CONTROL — ¿algún producto de reventa se PARECE a un insumo que ya
--    existe? (los códigos no coinciden, pero el nombre puede)
--
--    Misma receta de detección que se usó para fusionar duplicados el
--    2026-08-30: (1) nombre normalizado sin espacios ni signos, y (2)
--    similarity() de pg_trgm >= 0.72 acotada por inicial y largo, que es lo
--    que la hace rápida. pg_trgm SÍ está instalada en esta base.
--
--    Lo que salga acá NO se crea: se enlaza a mano al insumo que ya está, o
--    se corrige el nombre. Si la lista sale vacía, se puede crear tranquilo.
-- ---------------------------------------------------------------------------
with prod as (
  select mi.id, mi.name,
         lower(regexp_replace(mi.name, '[^a-zA-Z0-9]', '', 'g')) as limpio
  from public.menu_items mi
  where mi.business_id = '35c5076a-bd85-4a1b-8d1c-ce719c4f9ae6'
    and coalesce(mi.is_active, true)
    and not mi.is_inventory_tracked
    and mi.inventory_item_id is null
    and (
      coalesce(btrim(mi.barcode), '') <> ''
      or (coalesce(btrim(mi.sku), '') ~ '^[0-9]{8,14}$'
          and coalesce(btrim(mi.sku), '') !~ '^000')
    )
),
ins as (
  select ii.id, ii.name,
         lower(regexp_replace(ii.name, '[^a-zA-Z0-9]', '', 'g')) as limpio
  from public.inventory_items ii
  where ii.business_id = '35c5076a-bd85-4a1b-8d1c-ce719c4f9ae6'
    and coalesce(ii.is_active, true)
)
select
  p.name                                   as producto,
  i.name                                   as insumo_parecido,
  case
    when p.limpio = i.limpio then 'IDÉNTICO sin espacios'
    else 'parecido ' || round(similarity(p.limpio, i.limpio)::numeric, 2)::text
  end                                      as coincidencia
from prod p
join ins i
  on left(p.limpio, 1) = left(i.limpio, 1)
 and abs(length(p.limpio) - length(i.limpio)) <= 4
 and (p.limpio = i.limpio or similarity(p.limpio, i.limpio) >= 0.72)
order by (p.limpio = i.limpio) desc, p.name;
