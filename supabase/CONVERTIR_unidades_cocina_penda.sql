-- =============================================================================
-- LA PENDA EXPRESS — poner las unidades en su lugar (Cocina)
-- business_id = 35c5076a-bd85-4a1b-8d1c-ce719c4f9ae6
--
-- CÓMO SE DEDUJO: por el COSTO UNITARIO. El costo dice qué unidad usa
-- realmente el sistema, aunque la etiqueta diga otra cosa:
--
--   MANTECA NUESTRA   costo 2,550 · unidad «L»
--     2,550 por LIBRA de manteca es imposible. Por CAJA de 50 lb da 51/lb,
--     que es un precio real. La «L» nunca fue libra: es la caja.
--
--   CEPA DE APIO      costo 45 · unidad «unidad»
--     45 por cepa es correcto. La «unidad» ya ES la bolsa que contaron.
--
--   CARNE SALADA      costo 140 · unidad «L» · existencia 6.25
--     140 por libra es correcto, y 6.25 lb son exactamente 10 bolsas de
--     10 onzas. De ahí sale el factor: 1 bolsa = 0.625 lb.
--
-- LO QUE HACE ESTE ARCHIVO:
--   1. Corrige DOS etiquetas. No toca ningún número: la existencia y el
--      costo quedan igual, sólo pasan a decir la verdad.
--   2. Declara el empaque de CARNE SALADA con los campos que ya existen
--      (purchase_unit + pack_size, de la migración de junio).
--   3. Carga los tres renglones que con eso quedan destrabados.
--
-- CORRER UNA SENTENCIA A LA VEZ.
-- =============================================================================

-- ── 1. REVISAR antes de tocar ──────────────────────────────────────────────
select name, unit, purchase_unit, pack_size, cost,
       (select sum(quantity) from public.inventory_stock s where s.item_id = i.id)
         as existencia
from public.inventory_items i
where i.business_id = '35c5076a-bd85-4a1b-8d1c-ce719c4f9ae6'
  and i.id in ('777b31c5-301e-447b-ada1-de4013361f07',
               '68dff758-4461-49ec-b063-469cf3f8a1dd',
               'e3147d55-5633-45ee-ba9a-29f9b330a760');


-- ── 2. LAS ETIQUETAS ───────────────────────────────────────────────────────
-- Sólo cambia el texto de la unidad. La existencia y el costo NO se tocan,
-- así que el valor del inventario queda idéntico — lo único que cambia es
-- que la etiqueta deja de mentir.
begin;

update public.inventory_items
   set unit = 'caja'
 where business_id = '35c5076a-bd85-4a1b-8d1c-ce719c4f9ae6'
   and id = '777b31c5-301e-447b-ada1-de4013361f07';   -- MANTECA, «L» → caja

update public.inventory_items
   set unit = 'bolsa'
 where business_id = '35c5076a-bd85-4a1b-8d1c-ce719c4f9ae6'
   and id = '68dff758-4461-49ec-b063-469cf3f8a1dd';   -- CEPA DE APIO

commit;


-- ── 3. EL EMPAQUE DE LA CARNE SALADA ───────────────────────────────────────
-- Se queda en libras como unidad base — el costo de 140 es por libra — y se
-- declara que se compra en bolsas de 0.625 lb. Es para lo que están esos dos
-- campos desde junio.
begin;

update public.inventory_items
   set purchase_unit = 'bolsa',
       pack_size     = 0.625      -- 10 onzas
 where business_id = '35c5076a-bd85-4a1b-8d1c-ce719c4f9ae6'
   and id = 'e3147d55-5633-45ee-ba9a-29f9b330a760';

commit;


-- ── 4. CARGAR LOS TRES QUE QUEDAN DESTRABADOS ──────────────────────────────
begin;

with hoja(item_id, contado, nota) as (values
  ('777b31c5-301e-447b-ada1-de4013361f07'::uuid, 10.0,
   'Cocina · 10 cajas de 50 lb'),
  ('68dff758-4461-49ec-b063-469cf3f8a1dd',        8.0,
   'Cocina · 8 bolsas'),
  ('e3147d55-5633-45ee-ba9a-29f9b330a760',        0.625,
   'Cocina · 1 bolsa de 10 oz = 0.625 lb')
)
update public.physical_count_lines l
   set counted_quantity = h.contado,
       counter_notes    = h.nota,
       updated_at       = now()
  from hoja h, public.physical_count_sessions s
 where s.business_id = '35c5076a-bd85-4a1b-8d1c-ce719c4f9ae6'
   and s.code = 'PC-2026-000003'
   and s.status = 'in_progress'
   and l.session_id = s.id
   and l.item_id = h.item_id
   and l.counted_quantity is null;

commit;
-- 3 filas.


-- ── LO QUE NO ARREGLA LA CONVERSIÓN ────────────────────────────────────────
--
-- FILETE DE PECHUGA DE POLLO FRESCO no es un problema de unidad.
--   El costo de 140 confirma que la unidad base es la LIBRA (por bolsa de
--   10 oz saldría a 224/lb, muy caro para pechuga). Entonces:
--
--       32 bolsas × 0.625 lb  =  20 libras
--       el sistema dice          1,575.99 libras
--
--   Faltan 1,556 libras, unos RD$218,000. Eso no lo explica ninguna
--   conversión: o el número del sistema viene mal de antes, o la cocina
--   contó una parte, o hay pechuga en otra área. Es la pregunta más cara
--   del conteo y hay que hacerla aparte.
--
--
-- FALTAN SIETE EQUIVALENCIAS, y ninguna se puede deducir del costo:
--
--   HUEVOS FRECOS         29 cartones   ¿cuántos huevos por cartón?
--   LIMONES FRESCOS       25 libras     ¿cuántos limones por libra?
--   PALITOS YUQUITAS      39 unidades   ¿cuánto pesa la bolsa?
--   LONGANIZA CASERA     110 bolsas     ¿cuánto pesa la bolsa?
--   ALITAS FRESCAS        46 bolsas     ¿cuánto pesa la bolsa?
--   ZUCCHINI               3 unidades   ¿cuánto pesa uno?
--   Berengena             30 unidades   ¿cuánto pesa una?
--
--   Con cada respuesta: se pone `purchase_unit` + `pack_size` en el insumo
--   y se carga la línea multiplicando. Igual que la carne salada.
--
--   Los dos últimos (zucchini, berenjena) tienen una salida más simple:
--   si la cocina siempre los cuenta por pieza, conviene cambiarles la unidad
--   base a «unidad» en vez de pelear con el peso. Se pesan al comprar, no al
--   contar.
