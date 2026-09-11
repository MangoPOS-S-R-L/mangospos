-- =============================================================================
-- LA PENDA EXPRESS · PASO 7C — Triaje compacto de las 81 fichas sin mapear
-- SOLO LECTURA. Devuelve pocas filas a proposito.
-- =============================================================================

-- ═══ A · ¿De qué tamaño es cada grupo? ═══════════════════════════════════════
--   contiene   = el nombre del menu CONTIENE el de la ficha -> confiable
--   parecido   = solo se parece -> hay que mirarlo
--   sin_nada   = no hay candidato -> el producto no esta en el menu
with faltan as (
  select distinct p.codigo, p.producto
  from public._map_producto p
  where not exists (select 1 from public._map_producto_v2 v where v.codigo = p.codigo)
),
clas as (
  select f.codigo, f.producto,
    (select count(*) from public.menu_items m
      where m.business_id = '35c5076a-bd85-4a1b-8d1c-ce719c4f9ae6' and m.is_active
        and public._norm(m.name) like '%' || public._norm(f.producto) || '%') as n_contiene,
    (select count(*) from public.menu_items m
      where m.business_id = '35c5076a-bd85-4a1b-8d1c-ce719c4f9ae6' and m.is_active
        and similarity(public._norm(m.name), public._norm(f.producto)) > 0.45) as n_parecido
  from faltan f
)
select
  case when n_contiene > 0 then 'A · contiene (confiable)'
       when n_parecido > 0 then 'B · solo se parece'
       else                     'C · sin candidato' end     as grupo,
  count(*)                                                  as fichas,
  sum(n_contiene)                                           as productos_que_tocaria,
  round(avg(n_contiene), 1)                                 as promedio_por_ficha
from clas
group by 1 order by 1;


-- ═══ B · Las del grupo A, resumidas: ficha -> cuántos productos ══════════════
--   Si alguna toca 20 productos, ojo: el nombre es muy generico.
with faltan as (
  select distinct p.codigo, p.producto
  from public._map_producto p
  where not exists (select 1 from public._map_producto_v2 v where v.codigo = p.codigo)
)
select f.codigo, f.producto,
       count(m.id)                                      as productos,
       string_agg(m.name, ' | ' order by m.name)        as cuales
from faltan f
join public.menu_items m
  on m.business_id = '35c5076a-bd85-4a1b-8d1c-ce719c4f9ae6' and m.is_active
 and public._norm(m.name) like '%' || public._norm(f.producto) || '%'
group by f.codigo, f.producto
order by count(m.id) desc, f.codigo;


-- ═══ C · Las del grupo C: sin ningún candidato ══════════════════════════════
with faltan as (
  select distinct p.codigo, p.producto
  from public._map_producto p
  where not exists (select 1 from public._map_producto_v2 v where v.codigo = p.codigo)
)
select f.codigo, f.producto
from faltan f
where not exists (
  select 1 from public.menu_items m
   where m.business_id = '35c5076a-bd85-4a1b-8d1c-ce719c4f9ae6' and m.is_active
     and (public._norm(m.name) like '%' || public._norm(f.producto) || '%'
          or similarity(public._norm(m.name), public._norm(f.producto)) > 0.45))
order by f.codigo;


-- ═══ D · LOS INSUMOS: lo que falta mapear, por peso ═════════════════════════
--   Esto es la otra mitad del trabajo y no lo hemos visto todavia.
select m.ingrediente,
       count(distinct r.codigo)  as en_cuantas_fichas,
       min(r.unidad)             as unidad_receta
from public._map_ingrediente m
join public._recetario_penda r on r.ingrediente = m.ingrediente
where m.inventory_item_id is null and coalesce(m.como,'') <> 'descartar'
group by m.ingrediente
order by count(distinct r.codigo) desc, m.ingrediente;


-- ═══ E · Tablero de insumos ══════════════════════════════════════════════════
select
  count(*)                                                       as ingredientes,
  count(*) filter (where inventory_item_id is not null)           as emparejados,
  count(*) filter (where inventory_item_id is null
                     and coalesce(como,'') <> 'descartar')        as SIN_EMPAREJAR,
  count(*) filter (where como = 'auto-AMBIGUO')                   as ambiguos
from public._map_ingrediente;
