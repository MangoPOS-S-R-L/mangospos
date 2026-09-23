-- =============================================================================
-- LA PENDA EXPRESS · OPERACIÓN INVENTARIO — PASO 13: buscar en el CATÁLOGO
-- business_id = 35c5076a-bd85-4a1b-8d1c-ce719c4f9ae6
--
-- SOLO LECTURA. UNA sola consulta. REQUIERE PASO 6 + OP 9 corridos.
--
-- POR QUÉ HACE FALTA: el reporte K3 del PASO 10 buscaba los platos que faltaban
-- en el HISTORIAL DE VENTAS. Eso deja ciegos dos casos:
--   * el producto EXISTE pero nunca se vendió → no aparece en el historial
--   * el producto está DESACTIVADO → tampoco
-- y además `_map_producto` solo mira productos activos, así que ni los mapea.
--
-- Aquí se busca contra los 2,576 productos del CATÁLOGO, activos e inactivos.
--
-- CÓMO LEER `que_hacer`:
--   MAPEAR             el producto existe y está activo → mapear a mano (OP 12)
--   ACTIVAR Y MAPEAR   existe pero está DESACTIVADO → reactivarlo primero
--   VÍNCULO DIRECTO    existe pero se descuenta a sí mismo → no lleva receta
--   YA TIENE RECETA    ese producto ya está tomado por otra ficha (choque)
--   CREAR EL PRODUCTO  no hay nada parecido en el catálogo → ampliar el menú
--
-- Las columnas `parecido` y `se_vendio` dicen cuánto confiar. Parecido 1.00 con
-- ventas es seguro; por debajo de 0.60 hay que mirarlo.
-- =============================================================================

with
biz as (select '35c5076a-bd85-4a1b-8d1c-ce719c4f9ae6'::uuid as id),

-- las fichas que TODAVÍA no tienen receta
pendientes as materialized (
  select f.codigo, f.producto
    from (select distinct codigo, producto from public._recetario_penda) f
    left join public._map_producto p on p.codigo = f.codigo
   where p.menu_item_id is null
      or not exists (select 1 from public.recipes r where r.menu_item_id = p.menu_item_id)
),

-- TODO el catálogo, activos e inactivos, con cuánto se vendió cada uno
catalogo as materialized (
  select m.id, m.name, public._norm(m.name) as n,
         coalesce(m.is_active,true)       as activo,
         m.inventory_item_id is not null  as vinculo_directo,
         exists (select 1 from public.recipes r where r.menu_item_id = m.id) as con_receta,
         (select count(*) from public.order_items oi where oi.product_id = m.id
            and oi.status <> 'void')      as lineas
    from public.menu_items m, biz
   where m.business_id = biz.id
),

mejor as (
  select p.codigo, p.producto, c.*,
         round(similarity(c.n, public._norm(p.producto))::numeric, 2) as sim
    from pendientes p
    left join lateral (
      select * from catalogo c2
       where similarity(c2.n, public._norm(p.producto)) > 0.42
       -- primero lo que SIRVE: activo, sin vínculo, sin receta. Después el
       -- parecido. Así un producto usable le gana a uno mejor parecido pero
       -- que no se puede usar.
       order by (c2.activo and not c2.vinculo_directo and not c2.con_receta) desc,
                similarity(c2.n, public._norm(p.producto)) desc,
                c2.lineas desc
       limit 1
    ) c on true
)

select case
         when id is null                then '5 · CREAR EL PRODUCTO'
         when con_receta                then '4 · YA TIENE RECETA (choque)'
         when vinculo_directo           then '3 · VÍNCULO DIRECTO'
         when not activo                then '2 · ACTIVAR Y MAPEAR'
         else                                '1 · MAPEAR'
       end                                                    as que_hacer,
       codigo,
       producto                                               as ficha,
       coalesce(name, '—')                                    as producto_en_el_catalogo,
       coalesce(sim::text, '—')                               as parecido,
       case when id is null then '—'
            when lineas > 0 then lineas || ' líneas vendidas'
            else 'nunca se vendió' end                        as se_vendio,
       coalesce(id::text, '')                                 as menu_item_id
from mejor
order by 1, producto;
