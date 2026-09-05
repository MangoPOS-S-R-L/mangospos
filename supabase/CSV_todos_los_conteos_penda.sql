-- =============================================================================
-- LA PENDA EXPRESS — UN SOLO CSV con TODOS los conteos, separados por nombre
-- business_id = 35c5076a-bd85-4a1b-8d1c-ce719c4f9ae6
--
-- El nombre del conteo va PRIMERO, en las dos columnas iniciales, para que al
-- abrir el archivo en Excel se pueda agrupar o filtrar por área sin buscar.
-- El orden también agrupa: todos los renglones de un área quedan juntos.
--
-- EL NOMBRE VIVE EN `physical_count_sessions.notes`. Si alguna sesión sale
-- como «(SIN NOMBRE)», correr primero `NOMBRAR_conteos_penda.sql` — un archivo
-- de auditoría con cinco hojas indistinguibles no sirve de nada.
--
-- CÓMO EXPORTAR: correr la consulta en el SQL Editor de Supabase y usar
-- «Download CSV». Sale un solo archivo con las cinco áreas adentro.
-- =============================================================================

-- ---------------------------------------------------------------------------
-- 1. EL ARCHIVO — solo lo CONTADO, que es lo que firma el auditor.
-- ---------------------------------------------------------------------------
select
  s.code                                             as conteo,
  coalesce(nullif(btrim(s.notes), ''), '(SIN NOMBRE)') as nombre_del_conteo,
  w.name                                             as bodega,
  s.status                                           as estado_conteo,
  to_char(s.frozen_at at time zone 'America/Santo_Domingo',
          'DD/MM/YYYY HH24:MI')                      as congelado,
  coalesce(i.sku, '')                                as codigo,
  i.name                                             as articulo,
  coalesce(i.unit, 'unidad')                         as unidad,
  l.snapshot_quantity                                as segun_sistema,
  l.counted_quantity                                 as contado,
  round(l.counted_quantity - l.snapshot_quantity, 4) as diferencia,
  round(coalesce(i.cost, 0), 2)                      as costo_unitario,
  round(l.snapshot_quantity  * coalesce(i.cost, 0), 2) as valor_sistema,
  round(l.counted_quantity   * coalesce(i.cost, 0), 2) as valor_contado,
  round((l.counted_quantity - l.snapshot_quantity)
        * coalesce(i.cost, 0), 2)                    as valor_diferencia,
  case when coalesce(i.cost, 0) = 0 then 'SIN COSTO' else '' end as aviso,
  coalesce(l.counter_notes, '')                      as observacion
from public.physical_count_lines l
join public.physical_count_sessions s on s.id = l.session_id
join public.warehouses w            on w.id = s.warehouse_id
join public.inventory_items i       on i.id = l.item_id
where s.business_id = '35c5076a-bd85-4a1b-8d1c-ce719c4f9ae6'
  and s.status in ('draft', 'in_progress', 'completed')
  and l.counted_quantity is not null
order by
  s.code,                                   -- agrupa por conteo
  abs((l.counted_quantity - l.snapshot_quantity)
      * coalesce(i.cost, 0)) desc,          -- lo que más mueve, arriba
  i.name;


-- ---------------------------------------------------------------------------
-- 2. LA VERSIÓN COMPLETA — contados Y no contados, en el mismo archivo.
--
--    Un renglón sin contar conserva su stock viejo al cerrar, así que para el
--    auditor no es lo mismo «contado en cero» que «nadie lo miró». La columna
--    `estado_linea` los separa; el resto de las columnas es idéntico al de
--    arriba para que los dos archivos se puedan comparar.
-- ---------------------------------------------------------------------------
select
  s.code                                             as conteo,
  coalesce(nullif(btrim(s.notes), ''), '(SIN NOMBRE)') as nombre_del_conteo,
  w.name                                             as bodega,
  case when l.counted_quantity is null then 'SIN CONTAR' else 'contado' end
                                                     as estado_linea,
  coalesce(i.sku, '')                                as codigo,
  i.name                                             as articulo,
  coalesce(i.unit, 'unidad')                         as unidad,
  l.snapshot_quantity                                as segun_sistema,
  l.counted_quantity                                 as contado,
  case when l.counted_quantity is null then null
       else round(l.counted_quantity - l.snapshot_quantity, 4) end as diferencia,
  round(coalesce(i.cost, 0), 2)                      as costo_unitario,
  round(l.snapshot_quantity * coalesce(i.cost, 0), 2) as valor_sistema,
  case when l.counted_quantity is null then null
       else round(l.counted_quantity * coalesce(i.cost, 0), 2) end as valor_contado,
  coalesce(l.counter_notes, '')                      as observacion
from public.physical_count_lines l
join public.physical_count_sessions s on s.id = l.session_id
join public.warehouses w            on w.id = s.warehouse_id
join public.inventory_items i       on i.id = l.item_id
where s.business_id = '35c5076a-bd85-4a1b-8d1c-ce719c4f9ae6'
  and s.status in ('draft', 'in_progress', 'completed')
order by
  s.code,
  (l.counted_quantity is null),             -- primero lo contado
  i.name;


-- ---------------------------------------------------------------------------
-- 3. LA PORTADA — un renglón por conteo, para encabezar el informe.
-- ---------------------------------------------------------------------------
select
  s.code                                             as conteo,
  coalesce(nullif(btrim(s.notes), ''), '(SIN NOMBRE)') as nombre_del_conteo,
  w.name                                             as bodega,
  s.status                                           as estado,
  to_char(s.started_at at time zone 'America/Santo_Domingo',
          'DD/MM/YYYY HH24:MI')                      as iniciado,
  to_char(s.frozen_at at time zone 'America/Santo_Domingo',
          'DD/MM/YYYY HH24:MI')                      as congelado,
  count(l.*)                                                as renglones,
  count(l.*) filter (where l.counted_quantity is not null)   as contados,
  count(l.*) filter (where l.counted_quantity is null)       as sin_contar,
  count(l.*) filter (where l.counted_quantity is not null
                       and coalesce(i.cost,0) = 0)           as contados_sin_costo,
  round(sum(l.counted_quantity * coalesce(i.cost, 0))
        filter (where l.counted_quantity is not null), 2)    as valor_contado,
  round(sum(l.snapshot_quantity * coalesce(i.cost, 0))
        filter (where l.counted_quantity is not null), 2)    as valor_sistema,
  round(sum((l.counted_quantity - l.snapshot_quantity) * coalesce(i.cost, 0))
        filter (where l.counted_quantity is not null), 2)    as diferencia_rd
from public.physical_count_sessions s
join public.warehouses w on w.id = s.warehouse_id
left join public.physical_count_lines l on l.session_id = s.id
left join public.inventory_items i on i.id = l.item_id
where s.business_id = '35c5076a-bd85-4a1b-8d1c-ce719c4f9ae6'
  and s.status in ('draft', 'in_progress', 'completed')
group by s.code, s.notes, w.name, s.status, s.started_at, s.frozen_at
order by s.code;


-- ---------------------------------------------------------------------------
-- 4. EL MISMO ARTÍCULO EN VARIAS ÁREAS — la hoja que evita el doble conteo.
--
--    Contar lo mismo en dos áreas es legítimo (la misma bebida está en el bar
--    y en la tienda) y por eso se suma. Pero el auditor va a querer ver el
--    desglose, no un total que salió de la nada.
-- ---------------------------------------------------------------------------
select
  i.name                                             as articulo,
  coalesce(i.unit, 'unidad')                         as unidad,
  count(*)                                           as en_cuantas_areas,
  string_agg(coalesce(nullif(btrim(s.notes),''), s.code)
             || ': ' || l.counted_quantity::text,
             '  |  ' order by s.code)                as desglose_por_area,
  sum(l.counted_quantity)                            as total,
  round(coalesce(i.cost, 0), 2)                      as costo_unitario,
  round(sum(l.counted_quantity) * coalesce(i.cost, 0), 2) as valor_total
from public.physical_count_lines l
join public.physical_count_sessions s on s.id = l.session_id
join public.inventory_items i on i.id = l.item_id
where s.business_id = '35c5076a-bd85-4a1b-8d1c-ce719c4f9ae6'
  and s.status in ('draft', 'in_progress', 'completed')
  and l.counted_quantity is not null
group by i.id, i.name, i.unit, i.cost
having count(*) > 1
order by sum(l.counted_quantity) * coalesce(i.cost, 0) desc;
