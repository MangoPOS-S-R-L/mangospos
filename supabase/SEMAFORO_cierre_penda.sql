-- =============================================================================
-- LA PENDA EXPRESS — ¿está listo para cerrar? El semáforo, sin opiniones
-- business_id = 35c5076a-bd85-4a1b-8d1c-ce719c4f9ae6
--
-- Seis preguntas de sí o no. Todas tienen que salir en verde antes de cerrar
-- una sola sesión de conteo.
--
-- POR QUÉ IMPORTA EL ORDEN: `fn_physical_count_complete` deja el stock IGUAL a
-- lo contado. Lo que quede en blanco conserva su stock viejo (existencia
-- fantasma) y lo que quede con la unidad equivocada mete un ajuste falso. Una
-- vez cerrada, la sesión no se reabre.
-- =============================================================================

-- ---------------------------------------------------------------------------
-- 1. LAS SESIONES — cuántas líneas hay y cuántas siguen en blanco.
--
--    `pendientes` es el número que decide. Con las cinco sesiones abiertas
--    sobre la misma bodega, una línea en blanco en TODAS es un artículo que
--    ningún área contó.
-- ---------------------------------------------------------------------------
select
  s.code,
  s.status,
  w.name                                                    as bodega,
  count(l.*)                                                as lineas,
  count(l.*) filter (where l.counted_quantity is not null)  as contadas,
  count(l.*) filter (where l.counted_quantity is null)      as pendientes,
  round(100.0 * count(l.*) filter (where l.counted_quantity is not null)
        / nullif(count(l.*), 0), 1)                         as pct_avance
from public.physical_count_sessions s
join public.warehouses w on w.id = s.warehouse_id
left join public.physical_count_lines l on l.session_id = s.id
where s.business_id = '35c5076a-bd85-4a1b-8d1c-ce719c4f9ae6'
  and s.status in ('draft', 'in_progress')
group by s.code, s.status, w.name
order by s.code;


-- ---------------------------------------------------------------------------
-- 2. LO QUE NINGÚN ÁREA CONTÓ — mirando las cinco sesiones juntas.
--
--    Estos son los que van a conservar su stock viejo si se cierra así. El
--    `valor_fantasma` es lo que quedaría en el inventario sin que nadie lo
--    haya visto.
-- ---------------------------------------------------------------------------
with abiertas as (
  select id from public.physical_count_sessions
   where business_id = '35c5076a-bd85-4a1b-8d1c-ce719c4f9ae6'
     and status in ('draft', 'in_progress')
),
contado as (
  select distinct l.item_id
  from public.physical_count_lines l
  join abiertas a on a.id = l.session_id
  where l.counted_quantity is not null
)
select
  count(*)                                          as insumos_sin_contar,
  round(sum(coalesce(v.existencia, 0) * coalesce(i.cost, 0)), 2) as valor_fantasma
from public.inventory_items i
left join lateral (
  select sum(st.quantity) as existencia
  from public.inventory_stock st where st.item_id = i.id
) v on true
where i.business_id = '35c5076a-bd85-4a1b-8d1c-ce719c4f9ae6'
  and coalesce(i.is_active, true)
  and i.id not in (select item_id from contado);

-- (segunda sentencia: los 40 más caros de esa lista)
with abiertas as (
  select id from public.physical_count_sessions
   where business_id = '35c5076a-bd85-4a1b-8d1c-ce719c4f9ae6'
     and status in ('draft', 'in_progress')
),
contado as (
  select distinct l.item_id from public.physical_count_lines l
  join abiertas a on a.id = l.session_id
  where l.counted_quantity is not null
)
select
  i.name, i.unit, round(coalesce(i.cost,0),2) as costo,
  coalesce((select sum(st.quantity) from public.inventory_stock st
             where st.item_id = i.id), 0)     as existencia,
  round(coalesce((select sum(st.quantity) from public.inventory_stock st
                   where st.item_id = i.id), 0) * coalesce(i.cost,0), 2) as valor
from public.inventory_items i
where i.business_id = '35c5076a-bd85-4a1b-8d1c-ce719c4f9ae6'
  and coalesce(i.is_active, true)
  and i.id not in (select item_id from contado)
order by 5 desc
limit 40;


-- ---------------------------------------------------------------------------
-- 3. LAS UNIDADES — cuántos insumos siguen sin presentación real.
--
--    «unidad» es el valor POR DEFECTO de la columna, no una decisión. Un
--    insumo en «unidad» puede estar bien (una botella, un huevo) o puede ser
--    un saco de cebolla que nadie clasificó. La columna `sospechoso` separa
--    los que casi seguro están mal: los que dicen «L» (litro) siendo sólidos,
--    y los que valen tanto por «unidad» que la unidad tiene que ser un bulto.
-- ---------------------------------------------------------------------------
select
  coalesce(nullif(btrim(i.unit), ''), '(vacía)')     as unidad,
  count(*)                                           as insumos,
  round(100.0 * count(*) / sum(count(*)) over (), 1) as pct,
  count(*) filter (where coalesce(i.cost, 0) >= 800) as caros_sospechosos,
  round(sum(coalesce((select sum(st.quantity) from public.inventory_stock st
                       where st.item_id = i.id), 0)
            * coalesce(i.cost, 0)), 2)               as valor
from public.inventory_items i
where i.business_id = '35c5076a-bd85-4a1b-8d1c-ce719c4f9ae6'
  and coalesce(i.is_active, true)
group by 1
order by count(*) desc;


-- ---------------------------------------------------------------------------
-- 4. LOS QUE SE CONTARON PERO NO VALÚAN — costo en cero con cantidad puesta.
--
--    Cada uno de estos entra al inventario sumando unidades y RD$0. En el
--    informe del auditor aparecen como «contados sin costo» y la valuación
--    total queda corta por lo que valgan de verdad.
-- ---------------------------------------------------------------------------
select
  i.name, i.unit, l.counted_quantity as contado, s.code as sesion
from public.physical_count_lines l
join public.physical_count_sessions s on s.id = l.session_id
join public.inventory_items i on i.id = l.item_id
where s.business_id = '35c5076a-bd85-4a1b-8d1c-ce719c4f9ae6'
  and s.status in ('draft', 'in_progress')
  and l.counted_quantity is not null
  and l.counted_quantity > 0
  and coalesce(i.cost, 0) = 0
order by l.counted_quantity desc;


-- ---------------------------------------------------------------------------
-- 5. LOS SÓLIDOS QUE SIGUEN EN «LITROS» — el arreglo pendiente del PASO 3.
--
--    Si esto vuelve filas, el PASO 3 no se ha corrido completo. Cada una es
--    una libra escrita como litro.
-- ---------------------------------------------------------------------------
select
  i.id, i.name, i.unit, round(coalesce(i.cost,0),2) as costo,
  coalesce((select sum(st.quantity) from public.inventory_stock st
             where st.item_id = i.id), 0)     as existencia,
  (select l.counted_quantity
     from public.physical_count_lines l
     join public.physical_count_sessions s on s.id = l.session_id
    where l.item_id = i.id and s.status in ('draft','in_progress')
      and l.counted_quantity is not null limit 1) as contado
from public.inventory_items i
where i.business_id = '35c5076a-bd85-4a1b-8d1c-ce719c4f9ae6'
  and coalesce(i.is_active, true)
  and lower(btrim(i.unit)) in ('l','lt','litro','litros')
  and i.name !~* '\m(aceite|vinagre|jugo|leche|agua|salsa|sirope|jarabe|crema|refresco|vino|ron|whisky|cerveza|licor|almibar|caldo|soda|gaseosa)\M'
order by coalesce((select sum(st.quantity) from public.inventory_stock st
                    where st.item_id = i.id), 0) * coalesce(i.cost,0) desc;


-- ---------------------------------------------------------------------------
-- 6. EL RESUMEN — una sola fila con el veredicto.
-- ---------------------------------------------------------------------------
with abiertas as (
  select id from public.physical_count_sessions
   where business_id = '35c5076a-bd85-4a1b-8d1c-ce719c4f9ae6'
     and status in ('draft', 'in_progress')
),
contado as (
  select distinct l.item_id from public.physical_count_lines l
  join abiertas a on a.id = l.session_id where l.counted_quantity is not null
),
act as (
  select i.id, i.unit, coalesce(i.cost,0) as cost
  from public.inventory_items i
  where i.business_id = '35c5076a-bd85-4a1b-8d1c-ce719c4f9ae6'
    and coalesce(i.is_active, true)
)
select
  (select count(*) from act)                                   as insumos_activos,
  (select count(*) from contado)                               as ya_contados,
  (select count(*) from act where id not in (select item_id from contado))
                                                               as sin_contar,
  (select count(*) from act where lower(btrim(unit)) in ('l','lt','litro','litros'))
                                                               as siguen_en_litros,
  (select count(*) from act where cost = 0)                    as sin_costo,
  (select count(*) from public.physical_count_lines l
     join contado c on c.item_id = l.item_id
     join act a on a.id = l.item_id
    where l.counted_quantity > 0 and a.cost = 0)               as contados_sin_costo;
