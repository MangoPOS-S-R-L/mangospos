-- =============================================================================
-- LA PENDA EXPRESS · OPERACIÓN INVENTARIO — PASO 10: por qué solo 35 recetas
-- business_id = 35c5076a-bd85-4a1b-8d1c-ce719c4f9ae6
--
-- SOLO LECTURA. UNA sola consulta. REQUIERE PASO 6 + OP 9 corridos.
--
-- De 143 fichas salieron 35 recetas. Esto dice EXACTAMENTE dónde se cayeron las
-- otras 108, y cuáles se pueden rescatar.
--
--   K1  el embudo, filtro por filtro
--   K2  las que se cayeron porque un ingrediente NO CONVIERTE — con el nombre
--       del ingrediente culpable. Estas se rescatan llenando una equivalencia.
--   K3  las que NO tienen producto en el POS, separadas en dos grupos:
--         «se vendió con otro nombre»  → hay producto, solo no casó el nombre
--         «nunca se vendió»            → el plato no existe en el negocio
--       Es la diferencia entre renombrar y ampliar el menú.
--   K4  las 14 que el candado dejó afuera a propósito (vínculo directo)
--   K5  las que sí cargaron
-- =============================================================================

with
biz as (select '35c5076a-bd85-4a1b-8d1c-ce719c4f9ae6'::uuid as id),

fichas as (select distinct codigo, producto from public._recetario_penda),

-- el estado de cada ficha, con el motivo.
-- MATERIALIZED porque k1 la referencia 6 veces y k2..k5 otra vez cada una:
-- inlineada, los subselects correlacionados se recalculan en cada referencia.
estado as materialized (
  select f.codigo, f.producto,
         p.menu_item_id,
         mi.inventory_item_id is not null                       as vinculo_directo,
         exists (select 1 from public._recetario_penda z
                  where z.codigo = f.codigo and z.nota like 'PLANTILLA%') as plantilla,
         -- ingredientes que frenan la ficha
         (select string_agg(distinct z.ingrediente || ' (' || z.cantidad || ' ' ||
                            z.unidad || ' → ' || coalesce(ii.name,'sin insumo') ||
                            coalesce(' en ' || ii.unit, '') || ')', ' · ')
            from public._recetario_penda z
            left join public._map_ingrediente m  on m.ingrediente = z.ingrediente
            left join public.inventory_items ii  on ii.id = m.inventory_item_id
           where z.codigo = f.codigo
             and z.unidad <> 'c/n' and z.cantidad is not null
             and coalesce(m.como,'') <> 'descartar'
             and (m.inventory_item_id is null
                  or public._penda_a_base(z.cantidad, z.unidad, m.inventory_item_id) is null)
         )                                                      as frenan,
         exists (select 1 from public.recipes r
                  where r.menu_item_id = p.menu_item_id)        as tiene_receta,
         f.producto as _p
    from fichas f
    left join public._map_producto p on p.codigo = f.codigo
    left join public.menu_items mi   on mi.id = p.menu_item_id
),

-- ¿el plato se vendió alguna vez, aunque con otro nombre?
--   UN solo escaneo del historial, colapsado a nombres DISTINTOS, y el parecido
--   por TRIGRAMAS, no por palabra clave. Con palabra clave, «WRAP ITALIANO» y
--   «SANDWICH ITALIANO» casaban los dos con «CAPUCCINO ITALIANO» porque la
--   palabra mas larga era el adjetivo. El trigrama compara el nombre completo.
-- MATERIALIZED no es decorativo: sin el, Postgres inlinea esta CTE y la
-- re-evalua DENTRO del lateral de abajo, una vez por ficha. Medido en un local
-- del tamaño de prod: 23,260 ms sin materializar contra 854 ms con.
nombres as materialized (
  select public._norm(oi.product_name) as n,
         min(oi.product_name)           as nombre,
         count(*)                       as lineas
    from public.order_items oi
    join public.orders o          on o.id = oi.order_id
    join public.table_sessions ts on ts.id = o.session_id
   cross join biz
   where ts.business_id = biz.id and oi.status <> 'void'
     and oi.product_name is not null
   group by public._norm(oi.product_name)
),
vendido as (
  select e.codigo, x.nombre, x.lineas, x.sim
    from estado e
    left join lateral (
      select nb.nombre, nb.lineas,
             round(similarity(nb.n, public._norm(e.producto))::numeric, 2) as sim
        from nombres nb
       where similarity(nb.n, public._norm(e.producto)) > 0.45
       order by similarity(nb.n, public._norm(e.producto)) desc, nb.lineas desc
       limit 1
    ) x on true
   where e.menu_item_id is null
),

k1 as (
  select 1 as orden, 'K1 el embudo' as seccion, dato, valor from (
    select '1. fichas en el recetario' as dato,
           (select count(*)::text from fichas) as valor
    union all select '2. − sin producto en el POS',
           '−' || (select count(*)::text from estado where menu_item_id is null)
    union all select '3. = con producto',
           (select count(*)::text from estado where menu_item_id is not null)
    union all select '4. − con vínculo directo (el candado)',
           '−' || (select count(*)::text from estado
                    where menu_item_id is not null and vinculo_directo)
    union all select '5. − PLANTILLA (sin ingredientes reales)',
           '−' || (select count(*)::text from estado
                    where menu_item_id is not null and not vinculo_directo and plantilla)
    union all select '6. − algún ingrediente NO convierte',
           '−' || (select count(*)::text from estado
                    where menu_item_id is not null and not vinculo_directo
                      and not plantilla and frenan is not null)
    union all select '7. = RECETAS CARGADAS',
           (select count(*)::text from estado where tiene_receta and menu_item_id is not null)
  ) x
),

k2 as (
  select 2, 'K2 frenada · falta equivalencia', e.codigo || ' ' || e.producto, e.frenan
    from estado e
   where e.menu_item_id is not null and not e.vinculo_directo
     and not e.plantilla and e.frenan is not null
),

k3 as (
  select 3, 'K3 sin producto · ' ||
            case when v.nombre is not null then 'SE VENDE con otro nombre'
                 else 'NUNCA se vendió' end,
         e.codigo || ' ' || e.producto,
         case when v.nombre is not null
              then 'en el POS se llama «' || v.nombre || '» · ' || v.lineas ||
                   ' líneas · parecido ' || v.sim
              else 'ningún producto parecido se ha vendido nunca — habría que crearlo' end
    from estado e
    join vendido v on v.codigo = e.codigo
   where e.menu_item_id is null
),

k4 as (
  select 4, 'K4 candado · vínculo directo', e.codigo || ' ' || e.producto,
         'se descuenta a sí mismo; ponerle receta lo rompería'
    from estado e
   where e.menu_item_id is not null and e.vinculo_directo
),

k5 as (
  select 5, 'K5 cargadas', e.codigo || ' ' || e.producto,
         (select count(*)::text from public.recipe_ingredients ri
            join public.recipes r on r.id = ri.recipe_id
           where r.menu_item_id = e.menu_item_id) || ' ingredientes'
    from estado e
   where e.tiene_receta and e.menu_item_id is not null
)

select seccion, dato, valor from (
  select * from k1 union all select * from k2 union all select * from k3
  union all select * from k4 union all select * from k5
) todo
order by orden, dato;
