-- ============================================================================
-- DIAGNÓSTICO DEL MAESTRO DE ARTÍCULOS  (solo lectura salvo el BLOQUE F)
--
-- Salió de revisar la extracción del maestro el 2026-08-28: el archivo sale
-- bien armado pero con la columna "Código de barras" VACÍA, porque el código
-- de barras del negocio está guardado en `sku`, no en `barcode`.
--
-- Reemplazá <BUSINESS_ID> en cada bloque antes de correr.
-- ============================================================================

-- ── A. Cobertura de los campos que pide el contador ─────────────────────────
select
  count(*)                                                          as articulos,
  count(*) filter (where coalesce(sku, '') = '')                    as sin_codigo,
  count(*) filter (where coalesce(barcode, '') = '')                as sin_codigo_barras,
  count(*) filter (where sku ~ '^[0-9]{12,14}$')                    as sku_parece_ean,
  count(*) filter (where coalesce(cost, 0) = 0)                     as sin_costo,
  count(*) filter (where name ~ '^[0-9]{8,14}$')                    as nombre_es_un_ean,
  count(*) filter (where coalesce(description, '') = '')            as sin_descripcion
from public.inventory_items
where business_id = '<BUSINESS_ID>'
  and is_active;

-- ── B. Artículos duplicados (mismo nombre, fichas distintas) ────────────────
-- Inventario partido en dos: cada ficha tiene su propio costo y su propia
-- existencia, así que ni el conteo ni la valoración cuadran.
select
  lower(regexp_replace(trim(name), '\s+', ' ', 'g')) as nombre_normalizado,
  count(*)                                           as fichas,
  array_agg(i.id order by i.created_at)              as ids,
  array_agg(i.cost order by i.created_at)            as costos,
  array_agg(coalesce(st.qty, 0) order by i.created_at) as existencias
from public.inventory_items i
left join lateral (
  select sum(s.quantity) as qty
  from public.inventory_stock s
  where s.item_id = i.id
) st on true
where i.business_id = '<BUSINESS_ID>'
  and i.is_active
group by 1
having count(*) > 1
order by 2 desc, 1;

-- ── C. Fichas basura: el nombre ES un código de barras ──────────────────────
-- Nacen de escanear un producto desconocido y darle de alta al vuelo. Sin
-- costo y sin existencia, solo ensucian el maestro y el buscador.
select i.id, i.name, i.cost, coalesce(sum(s.quantity), 0) as existencia
from public.inventory_items i
left join public.inventory_stock s on s.item_id = i.id
where i.business_id = '<BUSINESS_ID>'
  and i.name ~ '^[0-9]{8,14}$'
group by i.id
order by existencia desc, i.name;

-- ── D. Lo que rompe la valoración ───────────────────────────────────────────
--   · existencia negativa  → salidas sin entrada
--   · existencia sin costo → valoriza en 0 y subestima el inventario
--   · costo desproporcionado → casi siempre es la UNIDAD, no el precio
select
  i.name,
  i.unit,
  i.cost,
  coalesce(sum(s.quantity), 0)          as existencia,
  coalesce(sum(s.quantity), 0) * i.cost as valor,
  case
    when coalesce(sum(s.quantity), 0) < 0                              then 'EXISTENCIA NEGATIVA'
    when coalesce(i.cost, 0) = 0 and coalesce(sum(s.quantity), 0) <> 0 then 'EXISTENCIA SIN COSTO'
    else 'COSTO ALTO — REVISAR UNIDAD'
  end as problema
from public.inventory_items i
left join public.inventory_stock s on s.item_id = i.id
where i.business_id = '<BUSINESS_ID>'
  and i.is_active
group by i.id
having coalesce(sum(s.quantity), 0) < 0
    or (coalesce(i.cost, 0) = 0 and coalesce(sum(s.quantity), 0) <> 0)
    or i.cost > 2000
order by abs(coalesce(sum(s.quantity), 0) * i.cost) desc;

-- ── E. Unidades en uso ──────────────────────────────────────────────────────
-- 'L' es LITRO en el sistema. Si aparece en ajo, alitas o ají, lo están
-- usando como libra y toda conversión/receta sale mal.
select coalesce(unit, '(sin unidad)') as unidad, count(*) as articulos
from public.inventory_items
where business_id = '<BUSINESS_ID>' and is_active
group by 1
order by 2 desc;

-- ============================================================================
-- BLOQUE F — ARREGLO PROPUESTO. NO correr sin revisar antes el SELECT previo.
-- ============================================================================

-- F.1 PREVIEW: qué SKUs se copiarían a `barcode`. Solo 12–14 dígitos
--     (UPC-A / EAN-13 / ITF-14). Los códigos internos cortos ('1', '1576',
--     '00002002') NO son códigos de barras y quedan fuera a propósito.
select id, name, sku as se_copiaria_a_barcode
from public.inventory_items
where business_id = '<BUSINESS_ID>'
  and coalesce(barcode, '') = ''
  and sku ~ '^[0-9]{12,14}$'
order by name;

-- F.2 UPDATE (descomentar después de revisar F.1).
-- update public.inventory_items
--    set barcode = sku
--  where business_id = '<BUSINESS_ID>'
--    and coalesce(barcode, '') = ''
--    and sku ~ '^[0-9]{12,14}$';

-- F.3 Fichas basura fuera de circulación. Se DESACTIVAN, no se borran:
--     pueden tener movimientos históricos colgando.
-- update public.inventory_items i
--    set is_active = false
--  where i.business_id = '<BUSINESS_ID>'
--    and i.name ~ '^[0-9]{8,14}$'
--    and coalesce(i.cost, 0) = 0
--    and not exists (
--      select 1 from public.inventory_stock s
--      where s.item_id = i.id and s.quantity <> 0
--    );
