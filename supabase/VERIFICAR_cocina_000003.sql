-- =============================================================================
-- PC-2026-000003 · Almacén Cocina — confirmar cómo quedó
-- business_id = 35c5076a-bd85-4a1b-8d1c-ce719c4f9ae6
--
-- Correr DESPUÉS de la parte 2 de CARGAR_cocina_penda.sql.
-- Una sentencia a la vez.
-- =============================================================================

-- ── 1. El avance de la sesión ───────────────────────────────────────────────
select
  s.code,
  s.status,
  (s.frozen_at at time zone 'America/Santo_Domingo') as congelada,
  count(l.*)                                                as lineas,
  count(l.*) filter (where l.counted_quantity is not null)  as contadas,
  count(l.*) filter (where l.counted_quantity is null)      as en_blanco,
  round(sum(coalesce(l.counted_quantity,0) * coalesce(ii.cost,0)), 2)
                                                            as valor_contado
from public.physical_count_sessions s
join public.physical_count_lines l on l.session_id = s.id
join public.inventory_items ii on ii.id = l.item_id
where s.business_id = '35c5076a-bd85-4a1b-8d1c-ce719c4f9ae6'
  and s.code = 'PC-2026-000003'
group by s.code, s.status, s.frozen_at;
-- ESPERADO: contadas = 21 (las de la carga de hoy).


-- ── 2. Qué quedó cargado, renglón por renglón ───────────────────────────────
select
  ii.name                                             as articulo,
  ii.unit                                             as unidad,
  l.counted_quantity                                  as contado,
  l.snapshot_quantity                                 as sistema,
  round(l.counted_quantity - l.snapshot_quantity, 3)  as diferencia,
  round((l.counted_quantity - l.snapshot_quantity)
        * coalesce(ii.cost, 0), 2)                    as valor,
  coalesce(l.counter_notes, '')                       as nota
from public.physical_count_lines l
join public.physical_count_sessions s on s.id = l.session_id
join public.inventory_items ii on ii.id = l.item_id
where s.business_id = '35c5076a-bd85-4a1b-8d1c-ce719c4f9ae6'
  and s.code = 'PC-2026-000003'
  and l.counted_quantity is not null
order by abs((l.counted_quantity - l.snapshot_quantity)
             * coalesce(ii.cost, 0)) desc;


-- ── 3. LOS 14 QUE NO SE CARGARON — el pendiente real de Cocina ──────────────
--    Se contaron en otra unidad que la del sistema. Esta consulta los trae
--    con su unidad y su existencia, que es lo que hace falta para decidir la
--    equivalencia con quien contó.
select
  ii.name                     as articulo,
  ii.unit                     as unidad_del_sistema,
  l.snapshot_quantity         as sistema_al_congelar,
  round(coalesce(ii.cost,0),2) as costo_unitario,
  case l.item_id::text
    when 'df112b8a-7458-416a-a666-db3036d994e1' then '1 unidad (filete 8 oz)'
    when '26697de2-775a-4e4f-9d28-2f76ca7190fa' then '3 unidades'
    when '22c6c8f6-4237-407b-a954-0190d4596b43' then '5 libras'
    when '68dff758-4461-49ec-b063-469cf3f8a1dd' then '8 bolsas de 10 oz'
    when '777b31c5-301e-447b-ada1-de4013361f07' then '10 cajas de 50 lb'
    when 'fde57faa-b1b2-4708-9eba-ab24acad3529' then '20 libras'
    when '3306a200-6105-456d-b1b7-54ea5603e8e7' then '29 cartones'
    when '0cb23cb5-9d9f-4aa9-8796-d3d0d2b527a3' then '30 unidades'
    when '5fd1d147-6508-449e-a9c9-83c79c6a98bb' then '32 bolsas de 10 oz'
    when '6c892302-40bd-4543-a45d-4104cacfefa9' then '39 unidades'
    when 'ea915c9a-fd40-420b-bff9-31e338ae39a9' then '46 bolsas'
    when 'f1aebda2-0464-46eb-b3f8-7fadce9f9c7c' then '110 bolsas'
    when '3f361492-a768-408f-bd72-0197010e7ee1' then '25 libras'
    when 'e3147d55-5633-45ee-ba9a-29f9b330a760' then '1 bolsa de 10 oz'
  end                         as contaron_en_papel
from public.physical_count_lines l
join public.physical_count_sessions s on s.id = l.session_id
join public.inventory_items ii on ii.id = l.item_id
where s.business_id = '35c5076a-bd85-4a1b-8d1c-ce719c4f9ae6'
  and s.code = 'PC-2026-000003'
  and l.item_id in (
    'df112b8a-7458-416a-a666-db3036d994e1',  -- FILETE DE SALMON
    '26697de2-775a-4e4f-9d28-2f76ca7190fa',  -- ZUCCHINI
    '22c6c8f6-4237-407b-a954-0190d4596b43',  -- PIMIENTA NEGRA MOLIDA
    '68dff758-4461-49ec-b063-469cf3f8a1dd',  -- CEPA DE APIO
    '777b31c5-301e-447b-ada1-de4013361f07',  -- MANTECA NUESTRA
    'fde57faa-b1b2-4708-9eba-ab24acad3529',  -- MORTADELA ALEGRIA
    '3306a200-6105-456d-b1b7-54ea5603e8e7',  -- HUEVOS FRECOS
    '0cb23cb5-9d9f-4aa9-8796-d3d0d2b527a3',  -- Berengena
    '5fd1d147-6508-449e-a9c9-83c79c6a98bb',  -- FILETE DE PECHUGA
    '6c892302-40bd-4543-a45d-4104cacfefa9',  -- PALITOS YUQUITAS
    'ea915c9a-fd40-420b-bff9-31e338ae39a9',  -- ALITAS FRESCAS
    'f1aebda2-0464-46eb-b3f8-7fadce9f9c7c',  -- LONGANIZA CASERA
    '3f361492-a768-408f-bd72-0197010e7ee1',  -- LIMONES FRESCOS
    'e3147d55-5633-45ee-ba9a-29f9b330a760'   -- CARNE SALADA
  )
order by ii.name;
