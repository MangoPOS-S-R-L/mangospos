-- =============================================================================
-- Cargar en bloque las cantidades contadas en PAPEL / Excel a una sesión.
--
-- PARA QUÉ: `PC-2026-000003` (Almacén Cocina) se contó en papel y está en
-- cero en el sistema. Teclear 2,284 renglones a mano no es opción.
--
-- CÓMO USARLO:
--   1. Pegá los renglones del Excel en el bloque `hoja` de abajo, como
--      ('codigo o nombre', cantidad). El código es preferible: los nombres
--      del papel casi nunca coinciden letra por letra con el sistema.
--   2. Poné el código de la sesión en `SESION`.
--   3. Corré la PARTE 1. NO escribe nada: dice qué casa y qué NO.
--   4. Sólo si la PARTE 1 sale limpia, corré la PARTE 2.
--
-- ⚠️ SOLO afecta a la sesión que pongas. Las otras cuatro no se tocan.
-- ⚠️ NO pisa una cantidad ya contada: si la línea ya tiene número, se
--    reporta como conflicto y se deja. Sobrescribir en silencio lo que
--    alguien ya contó es la peor forma de perder trabajo.
-- =============================================================================

-- ── PARTE 1: DIAGNÓSTICO (no escribe) ──────────────────────────────────────

with
sesion as (select 'PC-2026-000003'::text as code),   -- ← LA SESIÓN
hoja(clave, cantidad) as (values
  -- ↓↓↓ PEGAR ACÁ. Ejemplos del formato: ↓↓↓
  ('7460123450718', 5),
  ('Leche condensada Nestlé', 5)
  -- ↑↑↑ una línea por renglón, con coma al final salvo la última ↑↑↑
),
s as (
  select ps.id, ps.code, ps.warehouse_id, ps.status
    from public.physical_count_sessions ps
    join sesion on ps.code = sesion.code
   where ps.business_id = '35c5076a-bd85-4a1b-8d1c-ce719c4f9ae6'
),
ii as (
  select i.id, i.name,
         coalesce(nullif(i.barcode,''), nullif(i.sku,''), '') as codigo,
         regexp_replace(translate(lower(i.name),'áéíóúüñ','aeiouun'),
                        '[^a-z0-9]','','g') as n,
         i.is_active
    from public.inventory_items i
   where i.business_id = '35c5076a-bd85-4a1b-8d1c-ce719c4f9ae6'
),
match as (
  select h.clave, h.cantidad,
         (select x.id from ii x
           where x.codigo = h.clave
              or x.n = regexp_replace(
                         translate(lower(h.clave),'áéíóúüñ','aeiouun'),
                         '[^a-z0-9]','','g')
           order by (x.codigo = h.clave) desc, x.is_active desc
           limit 1) as item_id
    from hoja h
)
select
  m.clave,
  m.cantidad,
  i.name                          as insumo,
  case
    when m.item_id is null                    then '1. NO EXISTE ese insumo'
    when l.id is null                         then '2. EXISTE pero NO está en la sesión (recargar primero)'
    when l.counted_quantity is not null       then '3. YA CONTADO con ' || l.counted_quantity::text || ' — NO se pisa'
    when m.cantidad < 0                       then '4. CANTIDAD NEGATIVA'
    else '5. listo para cargar'
  end                             as veredicto,
  l.snapshot_quantity             as sistema_creia
from match m
left join ii i on i.id = m.item_id
left join s on true
left join public.physical_count_lines l
       on l.session_id = s.id and l.item_id = m.item_id
order by veredicto, m.clave;


-- ── PARTE 2: LA CARGA ──────────────────────────────────────────────────────
-- Descomentar SOLO cuando todos salgan en «5. listo para cargar».
-- Repetir el mismo bloque `hoja` y la misma `sesion`.
--
-- begin;
--
-- with
-- sesion as (select 'PC-2026-000003'::text as code),
-- hoja(clave, cantidad) as (values
--   ('7460123450718', 5)
--   -- ← el mismo bloque de arriba
-- ),
-- s as (
--   select ps.id from public.physical_count_sessions ps
--     join sesion on ps.code = sesion.code
--    where ps.business_id = '35c5076a-bd85-4a1b-8d1c-ce719c4f9ae6'
--      and ps.status = 'in_progress'
-- ),
-- ii as (
--   select i.id,
--          coalesce(nullif(i.barcode,''), nullif(i.sku,''), '') as codigo,
--          regexp_replace(translate(lower(i.name),'áéíóúüñ','aeiouun'),
--                         '[^a-z0-9]','','g') as n, i.is_active
--     from public.inventory_items i
--    where i.business_id = '35c5076a-bd85-4a1b-8d1c-ce719c4f9ae6'
-- ),
-- match as (
--   select h.cantidad,
--          (select x.id from ii x
--            where x.codigo = h.clave
--               or x.n = regexp_replace(
--                          translate(lower(h.clave),'áéíóúüñ','aeiouun'),
--                          '[^a-z0-9]','','g')
--            order by (x.codigo = h.clave) desc, x.is_active desc
--            limit 1) as item_id
--     from hoja h
-- )
-- update public.physical_count_lines l
--    set counted_quantity = m.cantidad,
--        updated_at = now()
--   from match m, s
--  where l.session_id = s.id
--    and l.item_id = m.item_id
--    and l.counted_quantity is null      -- ← el candado: no pisa lo contado
--    and m.cantidad >= 0;
--
-- commit;
--
-- Después: la consulta 3 de RECARGAR_conteo_penda.sql muestra cómo quedó el
-- avance de cada sesión.
