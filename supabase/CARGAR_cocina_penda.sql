-- ⚠️ CORRECCIÓN 2026-09-03: donde este archivo diga que el cierre «deja el
-- stock IGUAL a lo contado», está MAL. El cierre SUMA la diferencia:
--   stock final = stock actual + (contado - snapshot)
-- Ver la explicación completa en COMBINAR_conteos_por_area_penda.sql.

-- =============================================================================
-- LA PENDA EXPRESS — cargar el conteo de COCINA (papel) en PC-2026-000003
-- business_id = 35c5076a-bd85-4a1b-8d1c-ce719c4f9ae6
--
-- SE CARGAN 21 DE LOS 35 RENGLONES CONTADOS.
--
-- POR QUÉ NO LOS 35: catorce se contaron en una unidad DISTINTA a la que
-- lleva el sistema, y el cierre deja el stock IGUAL a lo contado. Cargar el
-- número del papel sin traducir dejaría un faltante falso de ~RD$292,800:
--
--   contaron 32 BOLSAS de pechuga (10 oz c/u) → el sistema lleva 1,575.99 L
--   contaron 10 CAJAS de manteca (50 lb c/u)  → el sistema lleva 20 "L"
--   contaron 25 LIBRAS de limones             → el sistema lleva 2,390 unidades
--   contaron 29 CARTONES de huevos            → el sistema lleva 3,450 unidades
--   contaron 39 UNIDADES de yuquitas          → el sistema lleva 141.9 lb
--
-- OJO con la manteca: el costo del sistema (2,550) es el de UNA CAJA de 50
-- libras, así que ahí la unidad "L" está mal puesta y el 10 del papel
-- probablemente sea el número bueno. Por eso no se traduce nada acá: cada
-- uno de los catorce hay que resolverlo con quien contó, no adivinando.
--
-- SE USA EL ID DEL INSUMO, no el nombre: los ids salen del propio Excel
-- exportado (columna «ID interno»), así que no hay emparejado difuso que
-- pueda fallar.
--
-- NO PISA lo ya contado (`counted_quantity is null` en el where).
-- =============================================================================

-- ── PARTE 1: PREVISUALIZAR (no escribe) ────────────────────────────────────

with hoja(item_id, contado) as (values
  ('e7dc40a8-5100-4b38-8e40-88f053ac8a80'::uuid, 0.5),    -- Aji morron amarillo
  ('1777df41-1169-4614-a6c7-470bc0d75af9',       1),      -- SALSA BBQ
  ('197d82fa-fe07-4552-93b4-849a8ce96eea',       2),      -- MANTEQUILLA DORINA 45OZ
  ('cdee569a-f603-4818-a0cf-5675ddb1d6bd',       2.5),    -- Aji Cubanela
  ('6ba4e779-fceb-4143-b71b-e231bcbc334d',       2.93),   -- TOMATE BARCELO
  ('cc01f726-1955-47e4-8060-fa5afa9a9e65',       3),      -- Aji morron Rojo
  ('122a3d3f-2e0e-4adf-891b-44f7672abd7e',       3.36),   -- PUERRO ANCHO
  ('56da1160-5ff8-4224-b05c-634f99329432',       5),      -- Apio
  ('8ec8627b-53fb-4a40-970e-6b081526469a',       5),      -- ZANAHORIA
  ('e1890ea5-ef55-40da-9c5c-5cb00e281a1e',       6.5),    -- JAMON DE PAVO CASERIO
  ('d5b7e98b-cbd9-4e1f-9648-e14be92f805f',       10),     -- QUIPE DE POLLO
  ('eb3e5f70-a3be-43d5-9b1e-f99462e3f77b',       12),     -- QUIPE DE QUESO DE CABRA
  ('d39590f7-c7d7-4fea-9e9e-b2e592fb940e',       13),     -- PEPINO FRESCO
  ('e0c7950e-f20e-44d6-8735-f4d02c0f36bd',       13),     -- CHIVO GUISADO
  ('b357c6d9-9735-4f0b-8f2a-d62abb25aa55',       20),     -- SALAMI SUPER ESPECIAL
  ('9e3008df-1f98-4b53-8729-03f58c7f2afb',       53),     -- SANCOCHO PENDA
  ('e27e130e-9506-452e-b837-dd145981fda0',       60),     -- QUESO DE FREIR BLANCO
  ('67f5a7bd-e091-4e12-8ebf-fd460ebd82a8',       95),     -- EMPANADA DE POLLO
  ('17f6b501-628d-4a5e-ab39-a3e05310221f',       100),    -- QUIPE DE RES
  ('fb176a38-0946-4043-9f5a-991a133a0dbd',       107),    -- EMPANADA QUESO BOTANA
  ('e0d2e3fc-bcf4-43b9-ba2c-356e5bfdf799',       137)     -- EMPANADA PIZZA BOTANA
)
select
  ii.name                                   as articulo,
  ii.unit                                   as unidad,
  h.contado,
  l.snapshot_quantity                       as sistema_al_congelar,
  round(h.contado - l.snapshot_quantity, 3) as diferencia,
  round((h.contado - l.snapshot_quantity) * coalesce(ii.cost, 0), 2) as valor,
  case
    when l.id is null                   then 'NO ESTÁ EN LA SESIÓN (recargar)'
    when l.counted_quantity is not null  then 'YA CONTADO con ' || l.counted_quantity::text
    else 'listo'
  end                                       as estado
from hoja h
join public.inventory_items ii on ii.id = h.item_id
left join public.physical_count_sessions s
       on s.business_id = '35c5076a-bd85-4a1b-8d1c-ce719c4f9ae6'
      and s.code = 'PC-2026-000003'
left join public.physical_count_lines l
       on l.session_id = s.id and l.item_id = h.item_id
order by estado, ii.name;


-- ── PARTE 2: CARGAR ────────────────────────────────────────────────────────
-- Descomentar cuando la parte 1 salga toda en «listo».
--
-- begin;
--
-- with hoja(item_id, contado) as (values
--   ('e7dc40a8-5100-4b38-8e40-88f053ac8a80'::uuid, 0.5),
--   ('1777df41-1169-4614-a6c7-470bc0d75af9',       1),
--   ('197d82fa-fe07-4552-93b4-849a8ce96eea',       2),
--   ('cdee569a-f603-4818-a0cf-5675ddb1d6bd',       2.5),
--   ('6ba4e779-fceb-4143-b71b-e231bcbc334d',       2.93),
--   ('cc01f726-1955-47e4-8060-fa5afa9a9e65',       3),
--   ('122a3d3f-2e0e-4adf-891b-44f7672abd7e',       3.36),
--   ('56da1160-5ff8-4224-b05c-634f99329432',       5),
--   ('8ec8627b-53fb-4a40-970e-6b081526469a',       5),
--   ('e1890ea5-ef55-40da-9c5c-5cb00e281a1e',       6.5),
--   ('d5b7e98b-cbd9-4e1f-9648-e14be92f805f',       10),
--   ('eb3e5f70-a3be-43d5-9b1e-f99462e3f77b',       12),
--   ('d39590f7-c7d7-4fea-9e9e-b2e592fb940e',       13),
--   ('e0c7950e-f20e-44d6-8735-f4d02c0f36bd',       13),
--   ('b357c6d9-9735-4f0b-8f2a-d62abb25aa55',       20),
--   ('9e3008df-1f98-4b53-8729-03f58c7f2afb',       53),
--   ('e27e130e-9506-452e-b837-dd145981fda0',       60),
--   ('67f5a7bd-e091-4e12-8ebf-fd460ebd82a8',       95),
--   ('17f6b501-628d-4a5e-ab39-a3e05310221f',       100),
--   ('fb176a38-0946-4043-9f5a-991a133a0dbd',       107),
--   ('e0d2e3fc-bcf4-43b9-ba2c-356e5bfdf799',       137)
-- )
-- update public.physical_count_lines l
--    set counted_quantity = h.contado,
--        counter_notes    = 'Cocina · conteo en papel 01-09-2026',
--        updated_at       = now()
--   from hoja h,
--        public.physical_count_sessions s
--  where s.business_id = '35c5076a-bd85-4a1b-8d1c-ce719c4f9ae6'
--    and s.code = 'PC-2026-000003'
--    and s.status = 'in_progress'
--    and l.session_id = s.id
--    and l.item_id = h.item_id
--    and l.counted_quantity is null;   -- ← no pisa lo ya contado
--
-- commit;
--
-- Tienen que salir 21 filas.


-- ── LOS 14 QUE FALTAN, para resolver con quien contó ───────────────────────
--   artículo                          contó            el sistema lleva
--   FILETE DE PECHUGA DE POLLO        32 bolsas 10oz   1,575.99 L
--   MANTECA NUESTRA 50 libras         10 cajas 50lb    20 "L"  (costo = 1 caja)
--   LIMONES FRESCOS                   25 libras        2,390 unidades
--   HUEVOS FRECOS                     29 cartones      3,450 unidades
--   PALITOS YUQUITAS BOLSA            39 unidades      141.9 lb
--   PIMIENTA NEGRA MOLIDA              5 libras        1 unidad
--   LONGANIZA CASERA ARTESANAL       110 bolsas        135 L
--   ZUCCHINI                           3 unidades      77 L
--   FILETE DE SALMON 8 onza            1 unidad        3.7 L
--   CARNE SALADA 10 onzas              1 bolsa         6.25 L
--   Berengena                         30 unidades      49 L
--   ALITAS FRESCAS                    46 bolsas        50 L
--   CEPA DE APIO 10 onzas              8 bolsas        9 unidades
--   MORTADELA ALEGRIA                 20 libras        20 unidades
--
-- Para cada uno hace falta UNA de dos cosas: la equivalencia (cuántas libras
-- trae la bolsa) para convertir el número, o corregir la unidad del insumo en
-- el sistema. La segunda es mejor cuando la unidad del sistema está mal —
-- como parece ser el caso de la manteca.
