-- =============================================================================
-- LA PENDA EXPRESS · PASO 7D — Clasificar los 182 ingredientes sin insumo
-- business_id = 35c5076a-bd85-4a1b-8d1c-ce719c4f9ae6
--
-- CONTEXTO: de 195 ingredientes del recetario, solo 13 emparejan por nombre
-- exacto con inventory_items. El catalogo de insumos se armo desde las
-- COMPRAS (botellas, empaquetados), no desde la cocina.
--
-- Pero los 182 no son todos iguales. Son TRES cosas distintas:
--
--   1. NO SE INVENTARIAN   sal, pimienta, agua, hielo, especias, sazonador.
--                          -> `descartar`. No bloquean la ficha.
--   2. PLACEHOLDER         "Salsa elegida", "Fruta o pulpa", "Guarnicion".
--                          -> NO se descartan: son el ingrediente principal.
--                             Necesitan decision de Eddy, no un UPDATE.
--   3. INSUMO DE VERDAD    "Chivo limpio", "Sofrito criollo", "Caldo".
--                          -> o existe con otro nombre, o hay que crearlo.
--
-- 7D.1 marca los del grupo 1.  7D.2 aisla el 2.  7D.3 busca parecidos del 3.
-- =============================================================================


-- ═══ 7D.1 · Marcar lo que NO se inventaria (escribe en la tabla de trabajo) ══
--   Reversible: update ... set como = null where como = 'descartar';
update public._map_ingrediente set como = 'descartar'
where inventory_item_id is null
  and ingrediente in (
    -- condimentos y agua: no se llevan por gramo
    'Sal y pimienta','Sal gruesa y pimienta','Ajo y oregano',
    'Hierbas y especias','Sazonador de la casa','Marinada seca',
    'Marinada de la casa','Agua','Agua de coccion','Agua de extraccion',
    'Hielo','Espuma'
  );

select ingrediente, como from public._map_ingrediente
where como = 'descartar' order by ingrediente;


-- ═══ 7D.2 · Los PLACEHOLDER: necesitan decisión, no mapeo ═══════════════════
--   Estos son el ingrediente PRINCIPAL de su ficha. Descartarlos cargaria la
--   receta sin su componente mas caro. Van a Eddy.
select m.ingrediente,
       count(distinct r.codigo)                                    as fichas,
       min(r.cantidad) || ' ' || min(r.unidad)                      as cantidad,
       string_agg(distinct r.producto, ' | ' order by r.producto)   as en_cuales
from public._map_ingrediente m
join public._recetario_penda r on r.ingrediente = m.ingrediente
where m.inventory_item_id is null
  and coalesce(m.como,'') <> 'descartar'
  and (m.ingrediente ilike '%segun receta%' or m.ingrediente ilike '%elegid%'
    or m.ingrediente ilike '%del dia%'      or m.ingrediente ilike 'Guarnicion%'
    or m.ingrediente ilike 'Fruta o pulpa%' or m.ingrediente ilike 'Producto principal%'
    or m.ingrediente ilike 'Proteina%'      or m.ingrediente ilike 'Relleno%')
group by m.ingrediente
order by count(distinct r.codigo) desc;


-- ═══ 7D.3 · LOS DE VERDAD: ¿existen con otro nombre? ════════════════════════
--   El mejor candidato del catalogo para cada uno. `parecido` alto = casi
--   seguro es el mismo con otra escritura.
with faltan as (
  select m.ingrediente, count(distinct r.codigo) as fichas, min(r.unidad) as u
  from public._map_ingrediente m
  join public._recetario_penda r on r.ingrediente = m.ingrediente
  where m.inventory_item_id is null
    and coalesce(m.como,'') <> 'descartar'
    and m.ingrediente not ilike '%segun receta%' and m.ingrediente not ilike '%elegid%'
    and m.ingrediente not ilike '%del dia%'      and m.ingrediente not ilike 'Guarnicion%'
    and m.ingrediente not ilike 'Fruta o pulpa%' and m.ingrediente not ilike 'Producto principal%'
    and m.ingrediente not ilike 'Proteina%'      and m.ingrediente not ilike 'Relleno%'
  group by m.ingrediente
),
mejor as (
  select f.ingrediente, f.fichas, f.u, i.id, i.name, i.unit, i.cost,
         similarity(public._norm(i.name), public._norm(f.ingrediente)) as p,
         row_number() over (partition by f.ingrediente
                            order by similarity(public._norm(i.name),
                                                public._norm(f.ingrediente)) desc) as rn
  from faltan f
  left join public.inventory_items i
    on i.business_id = '35c5076a-bd85-4a1b-8d1c-ce719c4f9ae6'
   and coalesce(i.is_active, true)
   and similarity(public._norm(i.name), public._norm(f.ingrediente)) > 0.30
)
select ingrediente, fichas, u as unidad_receta,
       name as mejor_candidato, unit as unidad_insumo, cost,
       round(p::numeric, 2) as parecido,
       case when p >= 0.65 then 'casi seguro'
            when p >= 0.45 then 'revisar'
            when p is null then 'HAY QUE CREARLO'
            else 'dudoso' end                as veredicto,
       id as inventory_item_id
from mejor
where rn = 1 or rn is null
order by (p is null) desc, fichas desc, ingrediente;


-- ═══ 7D.4 · Tablero después de clasificar ═══════════════════════════════════
select
  count(*)                                                   as ingredientes,
  count(*) filter (where inventory_item_id is not null)       as ya_mapeados,
  count(*) filter (where como = 'descartar')                  as no_se_inventarian,
  count(*) filter (where inventory_item_id is null
                     and coalesce(como,'') <> 'descartar')     as pendientes
from public._map_ingrediente;


-- ═══ 7D.5 · Aceptar los "casi seguro" en bloque ═════════════════════════════
--   Solo similitud >= 0.65. Descomentar despues de mirar el 7D.3.
/*
update public._map_ingrediente m
   set inventory_item_id = x.id, como = 'auto-parecido'
  from (
    select f.ingrediente, i.id,
           row_number() over (partition by f.ingrediente
                              order by similarity(public._norm(i.name),
                                                  public._norm(f.ingrediente)) desc) rn
    from public._map_ingrediente f
    join public.inventory_items i
      on i.business_id = '35c5076a-bd85-4a1b-8d1c-ce719c4f9ae6'
     and coalesce(i.is_active, true)
     and similarity(public._norm(i.name), public._norm(f.ingrediente)) >= 0.65
    where f.inventory_item_id is null and coalesce(f.como,'') <> 'descartar'
  ) x
 where m.ingrediente = x.ingrediente and x.rn = 1;
*/
