-- =============================================================================
-- LA PENDA EXPRESS — ¿qué hay hoy en el conteo PC-2026-000003?
-- business_id = 35c5076a-bd85-4a1b-8d1c-ce719c4f9ae6
--
-- Todo lo que se cargó en esta sesión de trabajo entró a 000003: los scripts
-- filtran `s.code = 'PC-2026-000003'` y las verificaciones leían de ahí. Esto
-- lo confirma con la base en vivo.
-- =============================================================================

-- ---------------------------------------------------------------------------
-- 1. EL CONTADOR — cuántos renglones tiene contados hoy.
--
--    Antes de esta sesión de trabajo tenía 41. Con lo que cargamos
--    (13 pendientes + 7 de cocina B + 11 de la hoja 1 + huevos) debería
--    haber subido bastante — parte de esos 41 ya eran de los mismos.
-- ---------------------------------------------------------------------------
select
  s.code,
  coalesce(nullif(btrim(s.notes),''), '(sin nombre)') as nombre,
  w.name                                              as bodega,
  s.status,
  count(l.*)                                          as lineas,
  count(l.*) filter (where l.counted_quantity is not null) as contadas,
  round(sum(l.counted_quantity * coalesce(i.cost,0))
        filter (where l.counted_quantity is not null), 2)  as valor_contado,
  round(sum((l.counted_quantity - l.snapshot_quantity) * coalesce(i.cost,0))
        filter (where l.counted_quantity is not null), 2)  as ajuste_al_cerrar
from public.physical_count_sessions s
join public.warehouses w on w.id = s.warehouse_id
left join public.physical_count_lines l on l.session_id = s.id
left join public.inventory_items i on i.id = l.item_id
where s.business_id = '35c5076a-bd85-4a1b-8d1c-ce719c4f9ae6'
  and s.code = 'PC-2026-000003'
group by s.code, s.notes, w.name, s.status;


-- ---------------------------------------------------------------------------
-- 2. TODO LO CONTADO EN 000003 — el listado completo, ordenado por lo que más
--    mueve el inventario al cerrar.
--
--    Acá tienen que estar los 12 de hoy (los 11 de la hoja 1 + los huevos),
--    los 13 pendientes, los 7 de la cocina B y los 22 que ya estaban.
-- ---------------------------------------------------------------------------
select
  i.name                                  as articulo,
  coalesce(i.unit,'unidad')               as unidad,
  l.snapshot_quantity                     as segun_sistema,
  l.counted_quantity                      as contado,
  round(coalesce(i.cost,0),2)             as costo,
  round((l.counted_quantity - l.snapshot_quantity) * coalesce(i.cost,0), 2)
                                          as ajuste_rd,
  to_char(l.updated_at at time zone 'America/Santo_Domingo',
          'DD/MM HH24:MI')                as tocada,
  coalesce(l.counter_notes,'')            as observacion
from public.physical_count_lines l
join public.physical_count_sessions s on s.id = l.session_id
join public.inventory_items i on i.id = l.item_id
where s.business_id = '35c5076a-bd85-4a1b-8d1c-ce719c4f9ae6'
  and s.code = 'PC-2026-000003'
  and l.counted_quantity is not null
order by abs((l.counted_quantity - l.snapshot_quantity) * coalesce(i.cost,0)) desc;


-- ---------------------------------------------------------------------------
-- 3. LO QUE SE CARGÓ HOY — las líneas tocadas en las últimas 24 horas.
--    Es la prueba directa de que los cambios entraron a esta sesión.
-- ---------------------------------------------------------------------------
select
  i.name, coalesce(i.unit,'unidad') as unidad,
  l.counted_quantity as contado,
  to_char(l.updated_at at time zone 'America/Santo_Domingo',
          'DD/MM HH24:MI')          as cargada,
  coalesce(l.counter_notes,'')      as observacion
from public.physical_count_lines l
join public.physical_count_sessions s on s.id = l.session_id
join public.inventory_items i on i.id = l.item_id
where s.business_id = '35c5076a-bd85-4a1b-8d1c-ce719c4f9ae6'
  and s.code = 'PC-2026-000003'
  and l.counted_quantity is not null
  and l.updated_at >= now() - interval '24 hours'
order by l.updated_at desc;


-- ---------------------------------------------------------------------------
-- 4. LOS TRES SIN FILA DE STOCK — detalle que quedó suelto.
--
--    `CREAR_los3_cocina_b_penda.sql` intentaba darles fila en una bodega con
--    «cocina» en el nombre, pero las CINCO sesiones están sobre «Almacen
--    Principal»: no existe una bodega de cocina. Así que el paso 2 de ese
--    archivo no creó nada.
--
--    NO es un problema para el conteo — el trigger del cierre hace
--    `insert ... on conflict do update`, así que la fila se crea sola al
--    aplicar el ajuste. Pero MIENTRAS TANTO no aparecen en la pantalla de
--    inventario de esa bodega, y eso confunde si alguien los busca.
-- ---------------------------------------------------------------------------
select
  i.name, i.unit, round(coalesce(i.cost,0),2) as costo,
  (select count(*) from public.inventory_stock st where st.item_id = i.id)
                                          as filas_de_stock,
  (select l.counted_quantity from public.physical_count_lines l
     join public.physical_count_sessions s on s.id = l.session_id
    where l.item_id = i.id and s.code = 'PC-2026-000003') as en_el_conteo
from public.inventory_items i
where i.business_id = '35c5076a-bd85-4a1b-8d1c-ce719c4f9ae6'
  and upper(btrim(i.name)) in
      ('MANGU DE PLATANO - GUARNICION','PAPAS FRITAS','VEGETALES SALTEADOS')
order by i.name;
