-- =============================================================================
-- LA PENDA EXPRESS — control de duplicados DESPUÉS de activar Inventariable
-- business_id = 35c5076a-bd85-4a1b-8d1c-ce719c4f9ae6
--
-- POR QUÉ: se crearon 1,147 insumos (tandas C y D). La tanda C llevaba guard
-- anti-duplicado por nombre; **la D no**, y la B2 (enlace por código cruzado)
-- no figura en el resumen, así que los 4 pares conocidos —CARLES DE QUESO ↔
-- PAPITAS DE QUESO CARLES y los TAKIS— pudieron crearse por duplicado.
--
-- Además, el guard de la C tiene un límite conocido: exige que los nombres
-- tengan largo parecido (±4) y la misma inicial. "CARLES DE QUESO" vs
-- "PAPITAS DE QUESO CARLES" no lo pasa. Por eso acá manda el CÓDIGO, que es
-- identidad y no parecido.
--
-- Los insumos recién creados NO tienen movimientos, así que borrarlos es
-- seguro. CORRER UNA SENTENCIA A LA VEZ.
-- =============================================================================

-- ---------------------------------------------------------------------------
-- 1. DUPLICADOS POR CÓDIGO — el chequeo que importa.
--    Un insumo creado que comparte código (barcode o sku, cruzados) con un
--    insumo que YA existía = la misma mercancía en dos fichas.
-- ---------------------------------------------------------------------------
with creados as (
  select distinct created_inventory_item_id as id
  from public.zz_backup_inventariable_20260901
  where created_inventory_item_id is not null
),
cod as (
  select ii.id, ii.name, c.cod, (cr.id is not null) as es_nuevo
  from public.inventory_items ii
  left join creados cr on cr.id = ii.id
  cross join lateral (
    values (nullif(btrim(ii.barcode), '')), (nullif(btrim(ii.sku), ''))
  ) as c(cod)
  where ii.business_id = '35c5076a-bd85-4a1b-8d1c-ce719c4f9ae6'
    and coalesce(ii.is_active, true)
    and c.cod is not null
    and c.cod ~ '^[0-9]{6,14}$'
)
select
  n.cod                as codigo,
  n.id                 as insumo_creado_id,
  n.name               as insumo_creado,
  v.id                 as insumo_viejo_id,
  v.name               as insumo_viejo
from cod n
join cod v on v.cod = n.cod and v.id <> n.id and not v.es_nuevo
where n.es_nuevo
order by n.name;


-- ---------------------------------------------------------------------------
-- 2. DUPLICADOS POR NOMBRE IDÉNTICO (sin espacios ni signos).
--    Barato y exacto. Cubre los que no comparten código.
-- ---------------------------------------------------------------------------
with creados as (
  select distinct created_inventory_item_id as id
  from public.zz_backup_inventariable_20260901
  where created_inventory_item_id is not null
),
norm as (
  select ii.id, ii.name,
         lower(regexp_replace(ii.name, '[^a-zA-Z0-9]', '', 'g')) as limpio,
         (cr.id is not null) as es_nuevo
  from public.inventory_items ii
  left join creados cr on cr.id = ii.id
  where ii.business_id = '35c5076a-bd85-4a1b-8d1c-ce719c4f9ae6'
    and coalesce(ii.is_active, true)
)
select n.id as insumo_creado_id, n.name as insumo_creado,
       v.id as insumo_viejo_id,  v.name as insumo_viejo
from norm n
join norm v on v.limpio = n.limpio and v.id <> n.id and not v.es_nuevo
where n.es_nuevo
order by n.name;


-- ---------------------------------------------------------------------------
-- 3. ARREGLO — reapuntar el producto al insumo VIEJO y borrar el creado.
--
-- Solo toca los que salen por CÓDIGO (consulta 1): ahí la identidad es
-- exacta. Los de la consulta 2 conviene mirarlos antes; si están bien,
-- cambiá el `with dup as (...)` por el de la consulta 2.
--
-- El delete solo borra fichas SIN movimientos. Una recién creada no tiene,
-- pero el guard queda por si alguien ya movió algo.
-- ---------------------------------------------------------------------------
-- with creados as (
--   select distinct created_inventory_item_id as id
--   from public.zz_backup_inventariable_20260901
--   where created_inventory_item_id is not null
-- ),
-- cod as (
--   select ii.id, c.cod, (cr.id is not null) as es_nuevo
--   from public.inventory_items ii
--   left join creados cr on cr.id = ii.id
--   cross join lateral (
--     values (nullif(btrim(ii.barcode), '')), (nullif(btrim(ii.sku), ''))
--   ) as c(cod)
--   where ii.business_id = '35c5076a-bd85-4a1b-8d1c-ce719c4f9ae6'
--     and coalesce(ii.is_active, true)
--     and c.cod is not null
--     and c.cod ~ '^[0-9]{6,14}$'
-- ),
-- dup as (
--   select n.id as nuevo_id, min(v.id::text)::uuid as viejo_id
--   from cod n
--   join cod v on v.cod = n.cod and v.id <> n.id and not v.es_nuevo
--   where n.es_nuevo
--   group by n.id
--   having count(distinct v.id) = 1   -- ambiguo = a mano
-- )
-- update public.menu_items mi
--    set inventory_item_id = d.viejo_id
--   from dup d
--  where mi.inventory_item_id = d.nuevo_id;
--
-- -- y después, con los productos ya reapuntados:
-- delete from public.inventory_items ii
--  where ii.id in (
--    select created_inventory_item_id
--    from public.zz_backup_inventariable_20260901
--    where created_inventory_item_id is not null
--  )
--    and not exists (select 1 from public.menu_items mi
--                     where mi.inventory_item_id = ii.id)
--    and not exists (select 1 from public.inventory_movements m
--                     where m.item_id = ii.id);


-- ---------------------------------------------------------------------------
-- 4. FOTO FINAL — cuánto creció el maestro y cuántos renglones va a tener el
--    conteo cuando congeles.
-- ---------------------------------------------------------------------------
select
  (select count(*) from public.inventory_items
    where business_id = '35c5076a-bd85-4a1b-8d1c-ce719c4f9ae6'
      and coalesce(is_active, true))                              as insumos_activos_hoy,
  (select count(*) from public.zz_backup_inventariable_20260901
    where created_inventory_item_id is not null)                  as creados_por_la_activacion,
  (select count(*) from public.menu_items
    where business_id = '35c5076a-bd85-4a1b-8d1c-ce719c4f9ae6'
      and coalesce(is_active, true) and is_inventory_tracked)     as productos_inventariables,
  (select count(*) from public.menu_items
    where business_id = '35c5076a-bd85-4a1b-8d1c-ce719c4f9ae6'
      and coalesce(is_active, true) and not is_inventory_tracked) as productos_sin_inventario;


-- ---------------------------------------------------------------------------
-- 5. LOS 5 GRUPOS DE INSUMO CON NOMBRE REPETIDO — el detalle para decidir.
--
--    Sea cual sea el origen (dos productos duplicados que crearon ficha cada
--    uno, o una ficha nueva que chocó con una vieja), lo que decide es:
--      · `movimientos` — una ficha con movimientos NO se borra: falsearía el
--        kardex. Se desactiva.
--      · `productos_ligados` — si un producto le apunta, primero hay que
--        reapuntarlo a la ficha que se queda.
--      · `creado_hoy` — las recién creadas no tienen historia: son las que
--        se pueden borrar limpio.
-- ---------------------------------------------------------------------------
with creados as (
  select distinct created_inventory_item_id as id
  from public.zz_backup_inventariable_20260901
  where created_inventory_item_id is not null
),
ins as (
  select ii.id, ii.name, ii.sku, ii.barcode, ii.created_at,
         lower(regexp_replace(ii.name, '[^a-zA-Z0-9]', '', 'g')) as limpio,
         (cr.id is not null) as creado_hoy
  from public.inventory_items ii
  left join creados cr on cr.id = ii.id
  where ii.business_id = '35c5076a-bd85-4a1b-8d1c-ce719c4f9ae6'
    and coalesce(ii.is_active, true)
),
grupos as (
  select limpio from ins group by limpio having count(*) > 1
)
select
  i.limpio                                   as grupo,
  i.id                                       as insumo_id,
  i.name                                     as insumo,
  i.creado_hoy,
  i.created_at::date                         as creado,
  coalesce(nullif(btrim(i.barcode), ''),
           nullif(btrim(i.sku), ''))         as codigo,
  (select count(*) from public.inventory_movements m
    where m.item_id = i.id)                  as movimientos,
  (select coalesce(sum(st.quantity), 0) from public.inventory_stock st
    where st.item_id = i.id)                 as stock,
  (select string_agg(mi.name, ' · ') from public.menu_items mi
    where mi.inventory_item_id = i.id)       as productos_ligados
from ins i
join grupos g on g.limpio = i.limpio
order by i.limpio, i.creado_hoy, i.created_at;
