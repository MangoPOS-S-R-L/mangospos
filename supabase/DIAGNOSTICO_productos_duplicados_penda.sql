-- =============================================================================
-- LA PENDA EXPRESS — duplicados en el MENÚ (menu_items), no en insumos
-- business_id = 35c5076a-bd85-4a1b-8d1c-ce719c4f9ae6
--
-- POR QUÉ AHORA: la activación de "Inventariable" (2026-09-01) creó 1,147
-- insumos, uno por producto. El guard anti-duplicado comparaba contra los
-- insumos que existían AL EMPEZAR el bucle, no contra los que iba creando —
-- así que dos productos duplicados generaron DOS insumos, y hoy son dos
-- renglones del mismo artículo en el conteo.
--
-- UN PRODUCTO NO SE FUSIONA COMO UN INSUMO: sus `order_items` históricos se
-- quedan donde están (reasignarlos falsearía reportes viejos). La regla es
-- desactivar el sobrante y unificar el precio del que queda.
--
-- Solo LECTURA. CORRER UNA SENTENCIA A LA VEZ.
-- =============================================================================

-- ---------------------------------------------------------------------------
-- 1. RESUMEN DEL DAÑO — cuántos insumos duplicados hay hoy por esta causa.
-- ---------------------------------------------------------------------------
with ins as (
  select ii.id, ii.name,
         lower(regexp_replace(ii.name, '[^a-zA-Z0-9]', '', 'g')) as limpio
  from public.inventory_items ii
  where ii.business_id = '35c5076a-bd85-4a1b-8d1c-ce719c4f9ae6'
    and coalesce(ii.is_active, true)
),
grupos as (
  select limpio, count(*) as cuantos
  from ins group by limpio having count(*) > 1
)
select
  count(*)                     as nombres_de_insumo_repetidos,
  coalesce(sum(cuantos), 0)    as fichas_involucradas,
  coalesce(sum(cuantos), 0) - count(*) as fichas_sobrantes
from grupos;


-- ---------------------------------------------------------------------------
-- 2. PRODUCTOS DUPLICADOS POR NOMBRE (normalizado, sin espacios ni signos).
--
--    Columnas que deciden:
--      · `precios_distintos` — se cobra distinto según qué botón toque el
--        cajero. Es lo más caro de un duplicado.
--      · `vendidas_90d` — el que no vende es el que se desactiva.
--      · `insumo_creado_hoy` — si es `true` en ambos, la activación duplicó
--        la ficha de inventario y hay que borrar la del que se desactive.
-- ---------------------------------------------------------------------------
with prod as (
  select mi.id, mi.name, mi.price, mi.sku, mi.barcode,
         mi.is_inventory_tracked, mi.inventory_item_id, mi.category_id,
         lower(regexp_replace(mi.name, '[^a-zA-Z0-9]', '', 'g')) as limpio
  from public.menu_items mi
  where mi.business_id = '35c5076a-bd85-4a1b-8d1c-ce719c4f9ae6'
    and coalesce(mi.is_active, true)
),
grupos as (
  select limpio
  from prod group by limpio having count(*) > 1
),
ventas as (
  select oi.product_id, sum(coalesce(oi.qty, oi.quantity::numeric)) as u90
  from public.order_items oi
  where oi.created_at >= now() - interval '90 days'
    and oi.product_id in (select id from prod)
  group by oi.product_id
),
creados as (
  select distinct created_inventory_item_id as id
  from public.zz_backup_inventariable_20260901
  where created_inventory_item_id is not null
)
select
  p.limpio                                as grupo,
  p.name                                  as producto,
  c.name                                  as categoria,
  p.price                                 as precio,
  round(coalesce(v.u90, 0), 2)            as vendidas_90d,
  coalesce(nullif(btrim(p.barcode), ''),
           nullif(btrim(p.sku), ''))      as codigo,
  ii.name                                 as insumo_ligado,
  (cr.id is not null)                     as insumo_creado_hoy,
  count(*) over (partition by p.limpio)   as en_el_grupo,
  (count(distinct p.price) over (partition by p.limpio) > 1) as precios_distintos
from prod p
join grupos g on g.limpio = p.limpio
left join public.categories c on c.id = p.category_id
left join ventas v on v.product_id = p.id
left join public.inventory_items ii on ii.id = p.inventory_item_id
left join creados cr on cr.id = p.inventory_item_id
order by precios_distintos desc, p.limpio, coalesce(v.u90, 0) desc;


-- ---------------------------------------------------------------------------
-- 3. PRODUCTOS QUE COMPARTEN CÓDIGO (barcode o sku, cruzados).
--
--    Son DOS cosas distintas y se arreglan distinto:
--      (a) el mismo producto cargado dos veces  → se desactiva uno;
--      (b) el código de OTRO producto copiado por error (ya pasó acá: MY
--          MOTTO TIRAMISU con el barcode del HAZELNUT) → se le VACÍA el
--          código al intruso, NO se desactiva.
--    Los nombres te dicen cuál es cuál.
-- ---------------------------------------------------------------------------
with prod_cod as (
  select mi.id, mi.name, mi.price, mi.inventory_item_id, c.cod
  from public.menu_items mi
  cross join lateral (
    values (nullif(btrim(mi.barcode), '')), (nullif(btrim(mi.sku), ''))
  ) as c(cod)
  where mi.business_id = '35c5076a-bd85-4a1b-8d1c-ce719c4f9ae6'
    and coalesce(mi.is_active, true)
    and c.cod is not null
    and c.cod ~ '^[0-9]{6,14}$'
),
repes as (
  select cod from prod_cod
  group by cod having count(distinct id) > 1
)
select
  p.cod                                    as codigo,
  p.name                                   as producto,
  p.price                                  as precio,
  ii.name                                  as insumo_ligado,
  case when lower(regexp_replace(p.name, '[^a-zA-Z0-9]', '', 'g')) =
            first_value(lower(regexp_replace(p.name, '[^a-zA-Z0-9]', '', 'g')))
              over (partition by p.cod order by p.name)
       then '' else '⚠ nombre distinto' end as señal
from prod_cod p
join repes r on r.cod = p.cod
left join public.inventory_items ii on ii.id = p.inventory_item_id
order by p.cod, p.name;


-- ---------------------------------------------------------------------------
-- 4. PARECIDOS POR TYPO — los que la comparación exacta no une.
--    (PARMALA/PARMALAT, BEKA/BEKE, RUFLES/RUFFLES…). similarity de pg_trgm
--    acotada por inicial y largo, igual que las fusiones del 2026-08-30.
-- ---------------------------------------------------------------------------
with prod as (
  select mi.id, mi.name, mi.price,
         lower(regexp_replace(mi.name, '[^a-zA-Z0-9]', '', 'g')) as limpio
  from public.menu_items mi
  where mi.business_id = '35c5076a-bd85-4a1b-8d1c-ce719c4f9ae6'
    and coalesce(mi.is_active, true)
),
ventas as (
  select oi.product_id, sum(coalesce(oi.qty, oi.quantity::numeric)) as u90
  from public.order_items oi
  where oi.created_at >= now() - interval '90 days'
    and oi.product_id in (select id from prod)
  group by oi.product_id
)
select
  a.name                                   as producto_a,
  a.price                                  as precio_a,
  round(coalesce(va.u90, 0), 2)            as vendidas_a,
  b.name                                   as producto_b,
  b.price                                  as precio_b,
  round(coalesce(vb.u90, 0), 2)            as vendidas_b,
  round(similarity(a.limpio, b.limpio)::numeric, 2) as parecido
from prod a
join prod b
  on b.id > a.id
 and left(a.limpio, 1) = left(b.limpio, 1)
 and abs(length(a.limpio) - length(b.limpio)) <= 4
 and a.limpio <> b.limpio
 and similarity(a.limpio, b.limpio) >= 0.80
left join ventas va on va.product_id = a.id
left join ventas vb on vb.product_id = b.id
order by parecido desc, a.name;


-- ---------------------------------------------------------------------------
-- 5. NOMBRE CONTENIDO EN OTRO — versión acotada.
--
--    La primera versión de esta consulta era inservible: con nombres
--    genéricos (CHINOLA, BROWNIES, MANTEQUILLA, DULCE DE LECHE) la contención
--    emparejaba media tienda. MOJITO DE CHINOLA no es un duplicado de
--    CHINOLA, es otro producto.
--
--    Tres filtros la vuelven revisable:
--      · el nombre corto tiene que ser PREFIJO del largo (no aparecer en
--        cualquier parte) — mata "…DE CHINOLA" y "PALETA DE …";
--      · lo que sobra al final no puede pasar de 8 caracteres — deja pasar
--        "12ONZ", "LATA", "UND", "ROSA", y descarta "CONHUEVOREVUELTO";
--      · el nombre corto, al menos 8 caracteres.
--
--    Y `veredicto` es lo que decide de verdad: si los DOS tienen código y son
--    distintos, son productos distintos, punto. La duda queda solo donde
--    falta un código.
-- ---------------------------------------------------------------------------
with prod as (
  select mi.id, mi.name, mi.price, mi.is_inventory_tracked,
         coalesce(nullif(btrim(mi.barcode), ''),
                  nullif(btrim(mi.sku), ''))                as codigo,
         lower(regexp_replace(mi.name, '[^a-zA-Z0-9]', '', 'g')) as limpio
  from public.menu_items mi
  where mi.business_id = '35c5076a-bd85-4a1b-8d1c-ce719c4f9ae6'
    and coalesce(mi.is_active, true)
),
ventas as (
  select oi.product_id, sum(coalesce(oi.qty, oi.quantity::numeric)) as u90
  from public.order_items oi
  where oi.created_at >= now() - interval '90 days'
    and oi.product_id in (select id from prod)
  group by oi.product_id
)
select
  corto.name                    as producto_corto,
  corto.price                   as precio_corto,
  round(coalesce(vc.u90, 0), 2) as vendidas_corto,
  corto.codigo                  as codigo_corto,
  largo.name                    as producto_largo,
  largo.price                   as precio_largo,
  round(coalesce(vl.u90, 0), 2) as vendidas_largo,
  largo.codigo                  as codigo_largo,
  substr(largo.limpio, length(corto.limpio) + 1) as lo_que_sobra,
  case
    when corto.codigo is not null and largo.codigo is not null
     and corto.codigo <> largo.codigo          then 'productos distintos (códigos distintos)'
    when corto.codigo = largo.codigo           then '⚠ MISMO CÓDIGO — duplicado'
    when corto.price = largo.price             then '⚠ revisar (mismo precio, falta un código)'
    else                                            'revisar (falta un código)'
  end                           as veredicto
from prod corto
join prod largo
  on largo.id <> corto.id
 and length(corto.limpio) >= 8
 and largo.limpio like corto.limpio || '%'
 and length(largo.limpio) - length(corto.limpio) between 1 and 8
left join ventas vc on vc.product_id = corto.id
left join ventas vl on vl.product_id = largo.id
order by veredicto, corto.name;


-- ---------------------------------------------------------------------------
-- 6. LO QUE SÍ IMPORTA PARA EL CONTEO: mercancía que VENDE y quedó fuera.
--
--    De los 731 que no entraron en la activación, algunos son reventa real
--    que la regla del código no vio — CANADA DRY AGUA TONICA vende 71 en 90
--    días y no descuenta nada. Cada uno de estos es una fuga: se vende y el
--    inventario ni se entera.
--
--    Lo que NO hay que activar sigue siendo lo mismo: cafés, jugos, platos,
--    cócteles y guarniciones, que necesitan receta. La categoría te orienta.
-- ---------------------------------------------------------------------------
with prod as (
  select mi.id, mi.name, mi.price, mi.category_id
  from public.menu_items mi
  where mi.business_id = '35c5076a-bd85-4a1b-8d1c-ce719c4f9ae6'
    and coalesce(mi.is_active, true)
    and not mi.is_inventory_tracked
),
ventas as (
  select oi.product_id, sum(coalesce(oi.qty, oi.quantity::numeric)) as u90
  from public.order_items oi
  where oi.created_at >= now() - interval '90 days'
    and oi.product_id in (select id from prod)
  group by oi.product_id
)
select
  p.name                        as producto,
  c.name                        as categoria,
  p.price                       as precio,
  round(coalesce(v.u90, 0), 2)  as vendidas_90d
from prod p
left join public.categories c on c.id = p.category_id
left join ventas v on v.product_id = p.id
where coalesce(v.u90, 0) > 0
order by coalesce(v.u90, 0) desc
limit 120;
