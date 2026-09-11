-- =============================================================================
-- LA PENDA EXPRESS · PASO 7B — Mapear las fichas a los productos del menu
-- business_id = 35c5076a-bd85-4a1b-8d1c-ce719c4f9ae6
--
-- POR QUE HACE FALTA:
--   El emparejamiento exacto del 7.1 dejo 84 de 130 fichas sin producto.
--   La causa NO es de tildes: el recetario es GENERICO y el menu ESPECIFICO.
--
--       ficha "CAPUCCINO"        ->  menu: CAPUCCINO ITALIANO
--                                          CAPUCCINO AMERICANO
--                                          CARAMEL CAPUCCINO
--
--   O sea que una ficha mapea a VARIOS productos, no a uno. El _map_producto
--   del 7.1 tenia `codigo` como llave primaria: 1:1. Estaba mal modelado.
--   Esto lo rehace como 1:N y agrega un buscador por parecido.
--
-- REQUIERE: pg_trgm.   create extension if not exists pg_trgm;
-- SOLO LEE, salvo el bloque 7B.4 que esta marcado.
-- =============================================================================

create extension if not exists pg_trgm;


-- ═══ 7B.1 · Rehacer el mapa como 1:N ═════════════════════════════════════════
--   Conserva lo que ya estaba mapeado.
create table if not exists public._map_producto_v2 (
  codigo       text not null,
  menu_item_id uuid not null,
  como         text,
  primary key (codigo, menu_item_id)
);

insert into public._map_producto_v2 (codigo, menu_item_id, como)
select codigo, menu_item_id, coalesce(como,'auto')
from public._map_producto
where menu_item_id is not null
on conflict do nothing;


-- ═══ 7B.2 · SUGERENCIAS: qué producto del menú se parece a cada ficha ════════
--   Las 3 mejores por ficha. Reviselas y quedese con las correctas.
--   `contiene` = el nombre del menu CONTIENE el de la ficha (el caso
--   CAPUCCINO -> CAPUCCINO ITALIANO). Esas son las mas confiables.
with faltan as (
  select distinct p.codigo, p.producto
  from public._map_producto p
  where not exists (select 1 from public._map_producto_v2 v where v.codigo = p.codigo)
),
cand as (
  select f.codigo, f.producto, m.id as menu_item_id, m.name as producto_menu,
         m.is_active, m.price,
         public._norm(m.name) like '%' || public._norm(f.producto) || '%' as contiene,
         similarity(public._norm(m.name), public._norm(f.producto))       as parecido,
         row_number() over (
           partition by f.codigo
           order by (public._norm(m.name) like '%' || public._norm(f.producto) || '%') desc,
                    similarity(public._norm(m.name), public._norm(f.producto)) desc,
                    m.is_active desc) as rn
  from faltan f
  join public.menu_items m
    on m.business_id = '35c5076a-bd85-4a1b-8d1c-ce719c4f9ae6'
   and (public._norm(m.name) like '%' || public._norm(f.producto) || '%'
        or similarity(public._norm(m.name), public._norm(f.producto)) > 0.45)
)
select codigo, producto, producto_menu, is_active, price, contiene,
       round(parecido::numeric, 2) as parecido, menu_item_id
from cand
where rn <= 3
order by codigo, rn;


-- ═══ 7B.3 · Las fichas para las que NO hay ni un candidato ═══════════════════
--   Estas o no estan en el menu, o se llaman muy distinto. Hay que buscarlas
--   a mano o decidir que no aplican.
with faltan as (
  select distinct p.codigo, p.producto
  from public._map_producto p
  where not exists (select 1 from public._map_producto_v2 v where v.codigo = p.codigo)
)
select f.codigo, f.producto
from faltan f
where not exists (
  select 1 from public.menu_items m
   where m.business_id = '35c5076a-bd85-4a1b-8d1c-ce719c4f9ae6'
     and (public._norm(m.name) like '%' || public._norm(f.producto) || '%'
          or similarity(public._norm(m.name), public._norm(f.producto)) > 0.45))
order by f.codigo;


-- ═══ 7B.4 · ACEPTAR SUGERENCIAS EN BLOQUE (escribe en la tabla de trabajo) ═══
--   Toma SOLO las de `contiene = true` sobre productos activos, que son las
--   confiables. Las demas se revisan a mano con el 7B.5.
--
--   Descomentar para aplicar.
/*
insert into public._map_producto_v2 (codigo, menu_item_id, como)
select distinct p.codigo, m.id, 'auto-contiene'
from public._map_producto p
join public.menu_items m
  on m.business_id = '35c5076a-bd85-4a1b-8d1c-ce719c4f9ae6'
 and m.is_active
 and public._norm(m.name) like '%' || public._norm(p.producto) || '%'
where not exists (select 1 from public._map_producto_v2 v where v.codigo = p.codigo)
on conflict do nothing;

select codigo, count(*) as productos_asignados
from public._map_producto_v2 group by codigo order by count(*) desc limit 20;
*/


-- ═══ 7B.5 · A MANO ═══════════════════════════════════════════════════════════
--   Para agregar un producto a una ficha (se pueden varios por ficha):
--
--     insert into public._map_producto_v2 (codigo, menu_item_id, como)
--     values ('PE-CAF-111','PEGA-EL-UUID','mano') on conflict do nothing;
--
--   Para quitar uno mal asignado:
--
--     delete from public._map_producto_v2
--      where codigo = 'PE-CAF-111' and menu_item_id = 'EL-UUID';
--
--   Para buscar el producto:
--
--     select id, name, price, is_active from public.menu_items
--      where business_id = '35c5076a-bd85-4a1b-8d1c-ce719c4f9ae6'
--        and name ilike '%capuccino%' order by name;


-- ═══ 7B.6 · Tablero ══════════════════════════════════════════════════════════
select
  (select count(distinct codigo) from public._map_producto)                   as fichas,
  (select count(distinct codigo) from public._map_producto_v2)                as fichas_mapeadas,
  (select count(*)               from public._map_producto_v2)                as pares_ficha_producto,
  (select count(distinct codigo) from public._map_producto p
    where not exists (select 1 from public._map_producto_v2 v
                       where v.codigo = p.codigo))                            as fichas_SIN_MAPEAR;
