-- =============================================================================
-- LA PENDA EXPRESS — cargar los 13 renglones del Excel que faltaban
-- business_id = 35c5076a-bd85-4a1b-8d1c-ce719c4f9ae6
--
-- Son los de la hoja 1 (cocina A) que nunca subieron. El conteo es el que los
-- auditores confirmaron; acá solo se representa fielmente en el sistema.
--
-- ── EL ORDEN IMPORTA: UNIDADES PRIMERO, CANTIDADES DESPUÉS ────────────────
-- Cargar «10» contra la manteca mientras el campo diga «L» guarda un 10 que
-- significa diez litros de manteca. El papel contó diez CAJAS. El número entra
-- igual y nadie se entera hasta que el valor no cuadra.
--
-- Por eso el paso 1 arregla las unidades y el paso 2 carga. Si ya corriste
-- `PASO3_unidades_cocina_penda.sql`, el paso 1 no hace nada y no molesta.
--
-- ── TRES LLEVAN UNA CUENTA, NO EL NÚMERO CRUDO ───────────────────────────
-- El papel cuenta en una unidad y el sistema lleva otra, y no hay forma de
-- relabelar sin romper el stock existente. En esos tres la cantidad se
-- CONVIERTE, y la cuenta queda escrita en la observación de la línea para que
-- el auditor la pueda rehacer:
--
--   PECHUGA        32 bolsas de 10 oz = 20 lb     (32 × 10 ÷ 16)
--   CARNE SALADA    1 bolsa de 10 oz  = 0.625 lb  (1 × 10 ÷ 16)
--   (el resto va con el número del papel tal cual)
--
-- ── LOS HUEVOS VAN APARTE ────────────────────────────────────────────────
-- Se decidió llevarlos por CAJA de 30, no por huevo. Eso no es cargar un
-- número: hay que mover la unidad, el costo (4.60 → 138) y la existencia
-- (3,450 → 115) juntos, o la valuación miente. Está en
-- `HUEVOS_por_caja_penda.sql`, que además comprueba que el valor total no
-- cambie: RD$15,870 antes y después.
--
-- ── UNO SIGUE SIN RESPUESTA ──────────────────────────────────────────────
-- LIMONES FRESCOS: el papel dice 25 libras y el sistema lleva 2,390 unidades a
-- RD$9.50. Si los 9.50 son POR LIMÓN, 25 libras son ~175 limones; si son por
-- libra, la unidad del sistema está mal. Sin ese dato cualquier número que
-- ponga es inventado. Va al final, comentado.
--
-- CORRER UNA SENTENCIA A LA VEZ.
-- =============================================================================

-- ---------------------------------------------------------------------------
-- 1. LAS UNIDADES DE ESTOS 13 — para que el número signifique lo que el papel
--    quiso decir. Idempotente: si ya se corrió el PASO 3, no cambia nada.
-- ---------------------------------------------------------------------------
update public.inventory_items set unit = 'bolsa'
 where business_id = '35c5076a-bd85-4a1b-8d1c-ce719c4f9ae6'
   and id in (
     'ea915c9a-fd40-420b-bff9-31e338ae39a9',  -- ALITAS FRESCAS      46 bolsas
     'f1aebda2-0464-46eb-b3f8-7fadce9f9c7c',  -- LONGANIZA           110 bolsas
     '68dff758-4461-49ec-b063-469cf3f8a1dd'   -- CEPA DE APIO        8 bolsas
   );

update public.inventory_items set unit = 'unidad'
 where business_id = '35c5076a-bd85-4a1b-8d1c-ce719c4f9ae6'
   and id in (
     '26697de2-775a-4e4f-9d28-2f76ca7190fa',  -- ZUCCHINI            3 unidad
     '0cb23cb5-9d9f-4aa9-8796-d3d0d2b527a3'   -- Berengena           30 unidad
   );

update public.inventory_items
   set unit = 'caja', purchase_unit = 'Caja', pack_size = 1
 where id = '777b31c5-301e-447b-ada1-de4013361f07';   -- MANTECA · 10 cajas

update public.inventory_items set unit = 'lb'
 where business_id = '35c5076a-bd85-4a1b-8d1c-ce719c4f9ae6'
   and id in (
     '5fd1d147-6508-449e-a9c9-83c79c6a98bb',  -- FILETE DE PECHUGA
     'e3147d55-5633-45ee-ba9a-29f9b330a760'   -- CARNE SALADA
   )
   and lower(btrim(unit)) = 'l';


-- ---------------------------------------------------------------------------
-- 2. CARGAR LAS 12 CANTIDADES.
--
--    NO SUMA: `where counted_quantity is null` — solo escribe sobre líneas en
--    blanco. Si alguna ya tenía número, se respeta y el paso 4 lo delata.
--
--    Cada línea lleva su observación con el origen y, donde aplica, la cuenta.
-- ---------------------------------------------------------------------------
with cant(item_id, q, nota) as (values
  ('26697de2-775a-4e4f-9d28-2f76ca7190fa'::uuid,   3.0,
   'Hoja 1 cocina A: 3 unidades.'),
  ('0cb23cb5-9d9f-4aa9-8796-d3d0d2b527a3'::uuid,  30.0,
   'Hoja 1 cocina A: 30 unidades.'),
  ('68dff758-4461-49ec-b063-469cf3f8a1dd'::uuid,   8.0,
   'Hoja 1 cocina A: 8 bolsas de 10 oz.'),
  ('ea915c9a-fd40-420b-bff9-31e338ae39a9'::uuid,  46.0,
   'Hoja 1 cocina A: 46 bolsas.'),
  ('f1aebda2-0464-46eb-b3f8-7fadce9f9c7c'::uuid, 110.0,
   'Hoja 1 cocina A: 110 bolsas.'),
  ('777b31c5-301e-447b-ada1-de4013361f07'::uuid,  10.0,
   'Hoja 1 cocina A: 10 cajas de 50 libras.'),
  ('e3147d55-5633-45ee-ba9a-29f9b330a760'::uuid,   0.625,
   'Hoja 1 cocina A: 1 bolsa de 10 oz = 0.625 lb (1 x 10 / 16).'),
  ('fde57faa-b1b2-4708-9eba-ab24acad3529'::uuid,  20.0,
   'Hoja 1 cocina A: 20 libras. La unidad del sistema ya equivale a la libra.'),
  ('22c6c8f6-4237-407b-a954-0190d4596b43'::uuid,   5.0,
   'Hoja 1 cocina A: 5 libras. PENDIENTE confirmar cuantas libras trae el pote '
   || 'de RD$1,832 — si el pote es de 5 lb, esto es 1 pote.'),
  ('6c892302-40bd-4543-a45d-4104cacfefa9'::uuid,  39.0,
   'Hoja 1 cocina A: 39 unidades. PENDIENTE confirmar si se cuenta por bolsa o '
   || 'se pesa: el sistema lleva 141.9 en libras.'),
  -- las dos que llevan cuenta
  ('5fd1d147-6508-449e-a9c9-83c79c6a98bb'::uuid,  20.0,
   'Hoja 1 cocina A: 32 bolsas de 10 oz = 20 lb exactas (32 x 10 / 16). '
   || 'El insumo se lleva en libras.')
  -- HUEVOS FRECOS salió de acá: el dueño decidió llevarlos por CAJA, no por
  -- huevo, así que la conversión toca la ficha, la existencia y el snapshot,
  -- no solo la cantidad. Va en `HUEVOS_por_caja_penda.sql` — CORRER ESE
  -- ARCHIVO ANTES O DESPUÉS DE ESTE, da igual, pero correrlo.
)
insert into public.physical_count_lines
  (session_id, item_id, snapshot_quantity, counted_quantity, counter_notes)
select
  s.id, c.item_id,
  coalesce((select st.quantity from public.inventory_stock st
             where st.item_id = c.item_id
               and st.warehouse_id = s.warehouse_id), 0),
  c.q, c.nota
from public.physical_count_sessions s
cross join cant c
where s.business_id = '35c5076a-bd85-4a1b-8d1c-ce719c4f9ae6'
  and s.code = 'PC-2026-000003'
on conflict (session_id, item_id) do update
  set counted_quantity = excluded.counted_quantity,
      counter_notes    = excluded.counter_notes,
      updated_at       = now()
  where physical_count_lines.counted_quantity is null;
-- Debe decir INSERT 0 11.


-- ---------------------------------------------------------------------------
-- 3. LIMONES FRESCOS — el único que no se puede cargar todavía.
--
--    El papel dice 25 LIBRAS. El sistema lleva 2,390 UNIDADES a RD$9.50.
--
--    Si los RD$9.50 son por limón (que es lo que parece), 25 libras son unos
--    175 limones — pero eso lo tiene que decir la cocina, porque depende del
--    tamaño. Poner 25 dejaría 25 limones y borraría RD$22,467.
--
--    PREGUNTA: ¿cuántos limones trae una libra?  Cuando lo sepas:
-- ---------------------------------------------------------------------------
-- insert into public.physical_count_lines
--   (session_id, item_id, snapshot_quantity, counted_quantity, counter_notes)
-- select s.id, '3f361492-a768-408f-bd72-0197010e7ee1',
--        coalesce((select st.quantity from public.inventory_stock st
--                   where st.item_id = '3f361492-a768-408f-bd72-0197010e7ee1'
--                     and st.warehouse_id = s.warehouse_id), 0),
--        25 * <limones por libra>,
--        'Hoja 1 cocina A: 25 libras x <N> limones por libra.'
--   from public.physical_count_sessions s
--  where s.business_id = '35c5076a-bd85-4a1b-8d1c-ce719c4f9ae6'
--    and s.code = 'PC-2026-000003'
-- on conflict (session_id, item_id) do update
--   set counted_quantity = excluded.counted_quantity,
--       counter_notes    = excluded.counter_notes, updated_at = now()
--   where physical_count_lines.counted_quantity is null;


-- ---------------------------------------------------------------------------
-- 4. VERIFICAR — los 13, con lo que quedó cargado.
--
--    Deben quedar 11 en OK (los 13 menos el limón y menos los huevos,
--    que van en su propio archivo). Si dice menos,
--    alguno ya tenía número y el guard lo respetó — mirá el detalle.
-- ---------------------------------------------------------------------------
with los13(id, nom, esperado) as (values
  ('26697de2-775a-4e4f-9d28-2f76ca7190fa'::uuid,'ZUCCHINI',3.0),
  ('0cb23cb5-9d9f-4aa9-8796-d3d0d2b527a3'::uuid,'Berengena',30.0),
  ('68dff758-4461-49ec-b063-469cf3f8a1dd'::uuid,'CEPA DE APIO',8.0),
  ('ea915c9a-fd40-420b-bff9-31e338ae39a9'::uuid,'ALITAS FRESCAS',46.0),
  ('f1aebda2-0464-46eb-b3f8-7fadce9f9c7c'::uuid,'LONGANIZA CASERA',110.0),
  ('777b31c5-301e-447b-ada1-de4013361f07'::uuid,'MANTECA NUESTRA',10.0),
  ('e3147d55-5633-45ee-ba9a-29f9b330a760'::uuid,'CARNE SALADA',0.625),
  ('fde57faa-b1b2-4708-9eba-ab24acad3529'::uuid,'MORTADELA ALEGRIA',20.0),
  ('22c6c8f6-4237-407b-a954-0190d4596b43'::uuid,'PIMIENTA NEGRA MOLIDA',5.0),
  ('6c892302-40bd-4543-a45d-4104cacfefa9'::uuid,'PALITOS YUQUITAS',39.0),
  ('5fd1d147-6508-449e-a9c9-83c79c6a98bb'::uuid,'FILETE DE PECHUGA',20.0),
  ('3306a200-6105-456d-b1b7-54ea5603e8e7'::uuid,'HUEVOS FRECOS (ver su archivo)',29.0),
  ('3f361492-a768-408f-bd72-0197010e7ee1'::uuid,'LIMONES FRESCOS',null)
)
select
  x.nom                                   as articulo,
  i.unit                                  as unidad,
  x.esperado,
  l.counted_quantity                      as cargado,
  round(coalesce(i.cost,0),2)             as costo,
  l.snapshot_quantity                     as tenia_el_sistema,
  round((coalesce(l.counted_quantity,0) - l.snapshot_quantity)
        * coalesce(i.cost,0), 2)          as ajuste_rd,
  case
    when x.esperado is null                        then '— pendiente (limón)'
    when l.counted_quantity is null                then '❌ NO CARGÓ'
    when abs(l.counted_quantity - x.esperado) <= 0.001 then 'OK'
    else                                                '⚠️ quedó en '
                                                        || l.counted_quantity::text
  end                                     as veredicto
from los13 x
join public.inventory_items i on i.id = x.id
left join lateral (
  select l2.counted_quantity, l2.snapshot_quantity
    from public.physical_count_lines l2
    join public.physical_count_sessions s2 on s2.id = l2.session_id
   where l2.item_id = x.id and s2.code = 'PC-2026-000003' limit 1
) l on true
order by x.nom;
