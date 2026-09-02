-- =============================================================================
-- LA PENDA EXPRESS — un Excel por sesión de conteo, para el auditor
-- business_id = 35c5076a-bd85-4a1b-8d1c-ce719c4f9ae6
--
-- CONTEXTO: las 4 sesiones (una por área) están contadas pero SIN CERRAR. El
-- auditor quiere el detalle de cada una ANTES de combinarlas, que es lo
-- correcto: una vez combinadas y cerradas, lo que contó cada área solo se
-- puede reconstruir mirando las sesiones canceladas.
--
-- CÓMO SACAR EL ARCHIVO: correr la consulta y usar "Download CSV" del editor
-- de Supabase.
--   ⚠️ EN EXCEL NO LO ABRAS CON DOBLE CLIC: el CSV viene en UTF-8 y Excel lo
--   lee con la página de códigos del sistema, así que "PEQUEÑA" sale como
--   "PEQUEÃA". Abrilo con Datos › Obtener datos › Desde texto/CSV y elegí
--   UTF-8 en "Origen del archivo".
--
--   (La app ya exporta .xlsx nativo sin ese problema — botón de exportar del
--   conteo, opción "Detalle en Excel" — pero requiere el build nuevo.)
--
-- CORRER UNA SENTENCIA A LA VEZ.
-- =============================================================================

-- ---------------------------------------------------------------------------
-- 1. PORTADA — el estado de las 4 sesiones. Va como primera hoja del informe.
-- ---------------------------------------------------------------------------
select
  s.code                                                   as sesion,
  s.status                                                 as estado,
  w.name                                                   as bodega,
  coalesce(s.notes, '(sin nombre de área)')                as area,
  coalesce(e.first_name || ' ' || e.last_name, '')         as abrio_la_sesion,
  (s.frozen_at at time zone 'America/Santo_Domingo')::date as congelada,
  count(l.*)                                               as items_en_sesion,
  count(l.*) filter (where l.counted_quantity is not null)  as contados,
  count(l.*) filter (where l.counted_quantity is null)      as sin_contar,
  round(sum(coalesce(l.counted_quantity, 0)), 2)            as unidades_contadas,
  round(sum(coalesce(l.counted_quantity, 0)
            * coalesce(ii.cost, 0)), 2)                     as valor_contado,
  -- Artículos contados cuyo costo es 0: el conteo de unidades está bien pero
  -- no aportan nada al valor. Si el auditor firma la valuación, estos hay que
  -- costearlos antes.
  count(*) filter (where l.counted_quantity is not null
                     and coalesce(ii.cost, 0) = 0)          as contados_sin_costo
from public.physical_count_sessions s
join public.warehouses w on w.id = s.warehouse_id
left join public.physical_count_lines l on l.session_id = s.id
left join public.inventory_items ii on ii.id = l.item_id
left join public.employees e
       on e.user_id = s.started_by
      and e.business_id = s.business_id
where s.business_id = '35c5076a-bd85-4a1b-8d1c-ce719c4f9ae6'
  and s.status = 'in_progress'
group by s.code, s.status, w.name, s.notes, s.frozen_at,
         e.first_name, e.last_name
order by s.code;


-- ---------------------------------------------------------------------------
-- 2. DETALLE DE UNA SESIÓN — cambiar el `code` y repetir por cada área.
--
--    IDENTIFICADO EN CADA FILA: sesión, área y bodega van repetidas en las
--    tres primeras columnas a propósito. Un CSV no admite encabezado arriba
--    de la tabla, y cinco archivos sin identificar son cinco archivos que
--    nadie puede distinguir después. Además así se pueden apilar los cinco en
--    una sola hoja sin perder de dónde salió cada renglón.
--
--    Los totales del área también viajan repetidos (`total_area_*`): dejan
--    cuadrar el archivo contra la portada sin abrir otra consulta.
--
--    Sale SOLO lo que esa área contó. Si el auditor quiere también los
--    renglones en blanco, comentar la línea marcada.
--
--    `diferencia` se calcula contra el snapshot del congelado, que es la foto
--    del sistema cuando arrancó el conteo. El ajuste REAL del cierre se
--    calcula contra el stock vivo de ese momento (migración 20260801_0002),
--    así que este número es la diferencia del conteo, no el asiento final.
-- ---------------------------------------------------------------------------
select
  s.code                                         as sesion,
  coalesce(s.notes, '(sin nombre de área)')      as area,
  w.name                                         as bodega,
  coalesce(e.first_name || ' ' || e.last_name, '') as abrio_la_sesion,
  (s.frozen_at at time zone 'America/Santo_Domingo')::date as congelada,
  ii.name                                        as articulo,
  coalesce(nullif(btrim(ii.sku), ''), '')        as sku,
  coalesce(nullif(btrim(ii.barcode), ''), '')    as codigo_barras,
  ii.unit                                        as unidad,
  round(l.snapshot_quantity, 3)                  as sistema_al_congelar,
  round(l.counted_quantity, 3)                   as contado,
  round(l.counted_quantity - l.snapshot_quantity, 3) as diferencia,
  round(coalesce(ii.cost, 0), 2)                 as costo_unitario,
  round((l.counted_quantity - l.snapshot_quantity)
        * coalesce(ii.cost, 0), 2)               as valor_diferencia,
  round(l.counted_quantity * coalesce(ii.cost, 0), 2) as valor_contado,
  case when coalesce(ii.cost, 0) = 0 then 'SIN COSTO' else '' end as alerta,
  coalesce(l.counter_notes, '')                  as notas,
  (l.updated_at at time zone 'America/Santo_Domingo') as ultima_edicion,
  -- Totales del área, repetidos en cada fila para poder cuadrar el archivo.
  count(*)          over ()                      as total_area_articulos,
  round(sum(l.counted_quantity) over (), 3)      as total_area_unidades,
  round(sum(l.counted_quantity * coalesce(ii.cost, 0)) over (), 2)
                                                 as total_area_valor
from public.physical_count_lines l
join public.physical_count_sessions s on s.id = l.session_id
join public.warehouses w on w.id = s.warehouse_id
join public.inventory_items ii on ii.id = l.item_id
left join public.employees e
       on e.user_id = s.started_by
      and e.business_id = s.business_id
where s.business_id = '35c5076a-bd85-4a1b-8d1c-ce719c4f9ae6'
  and s.code = 'PC-2026-000002'          -- ⬅ CAMBIAR por cada sesión
  and l.counted_quantity is not null     -- ⬅ COMENTAR para incluir los blancos
order by ii.name;


-- ---------------------------------------------------------------------------
-- 3. HOJA DE COMBINACIÓN — todas las áreas lado a lado, con el total.
--
--    Esta es la que justifica el número final: muestra de qué área salió cada
--    unidad. Si un artículo aparece en dos columnas es porque está en dos
--    áreas y se SUMA — por eso la combinación no puede ser "cerrar las
--    sesiones una por una", que dejaría solo la última.
--
--    ⚠️ La columna `desglose` es la garantía: se arma sola con las sesiones
--    que existan. Las columnas fijas de abajo son para leer cómodo, pero si
--    alguien abre una sesión nueva (ya pasó: PC-2026-000006 apareció después)
--    esa columna no existiría y el total no cuadraría con la suma horizontal.
--    Ante una duda, manda `desglose`.
--
--    Guardala junto con las otras: es el papel de trabajo del auditor.
-- ---------------------------------------------------------------------------
select
  ii.name                                       as articulo,
  coalesce(nullif(btrim(ii.sku), ''), '')       as sku,
  ii.unit                                       as unidad,
  round(max(l.snapshot_quantity), 3)            as sistema_al_congelar,
  round(sum(l.counted_quantity)
        filter (where s.code = 'PC-2026-000002'), 3) as furgon_almacen_02,
  round(sum(l.counted_quantity)
        filter (where s.code = 'PC-2026-000003'), 3) as cocina_03,
  round(sum(l.counted_quantity)
        filter (where s.code = 'PC-2026-000004'), 3) as foodshop_winnifer_04,
  round(sum(l.counted_quantity)
        filter (where s.code = 'PC-2026-000005'), 3) as foodshop_rosayra_05,
  round(sum(l.counted_quantity)
        filter (where s.code = 'PC-2026-000006'), 3) as bar_06,
  round(sum(coalesce(l.counted_quantity, 0)), 3)     as total_contado,
  count(*) filter (where l.counted_quantity is not null) as en_cuantas_areas,
  string_agg(
    right(s.code, 3) || '=' || round(l.counted_quantity, 3)::text,
    ' + ' order by s.code
  ) filter (where l.counted_quantity is not null)      as desglose,
  round(coalesce(ii.cost, 0), 2)                       as costo_unitario,
  round(sum(coalesce(l.counted_quantity, 0))
        * coalesce(ii.cost, 0), 2)                     as valor_total,
  case when coalesce(ii.cost, 0) = 0 then 'SIN COSTO' else '' end as alerta
from public.physical_count_lines l
join public.physical_count_sessions s on s.id = l.session_id
join public.inventory_items ii on ii.id = l.item_id
where s.business_id = '35c5076a-bd85-4a1b-8d1c-ce719c4f9ae6'
  and s.status = 'in_progress'
group by ii.id, ii.name, ii.sku, ii.unit, ii.cost
having count(*) filter (where l.counted_quantity is not null) > 0
order by ii.name;


-- ---------------------------------------------------------------------------
-- 4. VALUACIÓN RESUMIDA — el número grande del informe.
-- ---------------------------------------------------------------------------
with contado as (
  select l.item_id, sum(coalesce(l.counted_quantity, 0)) as unidades
  from public.physical_count_lines l
  join public.physical_count_sessions s on s.id = l.session_id
  where s.business_id = '35c5076a-bd85-4a1b-8d1c-ce719c4f9ae6'
    and s.status = 'in_progress'
    and l.counted_quantity is not null
  group by l.item_id
)
select
  count(*)                                                   as articulos_contados,
  round(sum(c.unidades), 2)                                  as unidades_totales,
  round(sum(c.unidades * coalesce(ii.cost, 0)), 2)           as valor_inventario_contado,
  (select count(*) from public.inventory_items
    where business_id = '35c5076a-bd85-4a1b-8d1c-ce719c4f9ae6'
      and coalesce(is_active, true))                          as articulos_en_catalogo
from contado c
join public.inventory_items ii on ii.id = c.item_id;
