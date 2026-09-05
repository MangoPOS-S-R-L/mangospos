-- =============================================================================
-- PASO 1c · LA PENDA EXPRESS — los 13 pendientes: NINGUNO falta
-- business_id = 35c5076a-bd85-4a1b-8d1c-ce719c4f9ae6
--
-- ── CONCLUSIÓN DE LA BÚSQUEDA ─────────────────────────────────────────────
-- Los 13 de la hoja «PENDIENTES EN SISTEMA» existen todos. Los que parecían
-- faltar eran fallas del comparador, no del catálogo:
--
--   chicharon 10 onza  → «Chicharrón 10 oz»   (onza ≠ oz, chicharon ≠ chicharrón)
--   pollo mechado 4 onza → «Pollo mechado 4 oz»            (onza ≠ oz)
--   pasta linguini     → «Pasta Linguine»                  (linguini ≠ linguine)
--   picantes red hot   → «Picante Red Hot»                 (plural ≠ singular)
--   pechurina 6 onza   → «PECHURINA»                       (sin la porción)
--
-- NO SE CREA NADA. Crear cualquiera de esos cinco sería duplicar — que es
-- justo lo que hubo que limpiar con los 15 que se fusionaron.
--
-- Lo que sí hay que arreglar: cuatro unidades y siete costos en cero.
--
-- CORRER UNA SENTENCIA A LA VEZ.
-- =============================================================================

-- ---------------------------------------------------------------------------
-- 1. LAS CUATRO UNIDADES.
--
--    Genjibre  : RD$145 la «unidad» es precio de libra de jengibre, y el papel
--                lo contó en libras. → lb
--    Las pastas: el papel las cuenta en bolsas y así es como se compran. Los
--                códigos 8076802085738 y 8076800195132 son de Barilla, que
--                viene en cajas/bolsas de una libra. → bolsa
--    PECHURINA : el papel dice «pechurina 6 onza · 10 bolsas». Es un
--                porcionado. → bolsa
-- ---------------------------------------------------------------------------
update public.inventory_items
   set unit = 'lb'
 where id = '1f814aac-9429-4616-b02f-028506747f7f';   -- Genjibre

update public.inventory_items
   set unit = 'bolsa'
 where id in (
   'cf27f185-e99d-4502-8578-906e453eb004',   -- Pasta Penne
   '44a5e30a-3df1-4596-8e5c-723f8d607fdc',   -- Pasta Linguine
   '97857b62-04cd-47c2-bdfb-5b87cf4b3530'    -- PECHURINA
 );
-- Debe decir UPDATE 3.


-- ---------------------------------------------------------------------------
-- 2. LOS SIETE SIN COSTO — la lista para llevarle a la cocina o a compras.
--
--    Mientras el costo sea 0 estos insumos SUMAN UNIDADES pero NO SUMAN VALOR.
--    En el informe del auditor van a caer en «contados sin costo», y la
--    valuación del inventario queda corta por lo que valgan de verdad.
--
--    El costo se pone al recibir la próxima compra (que es lo correcto: el
--    costo maestro se mueve AL RECIBIR) o a mano si hace falta para firmar.
-- ---------------------------------------------------------------------------
select
  i.id, i.name, i.unit, i.sku,
  (select l.counted_quantity
     from public.physical_count_lines l
     join public.physical_count_sessions s on s.id = l.session_id
    where l.item_id = i.id and s.code = 'PC-2026-000003') as contado_cocina
from public.inventory_items i
where i.id in (
  '0970382d-2832-499c-9368-c23a1ab3fa84',   -- Aceite especial lata 30 libras
  '4073534c-f9bf-4d86-ab65-8077b0e246bb',   -- Cativía de queso
  '4b5aaf6e-7efe-4b6f-bc7b-3ff06e4ae3ac',   -- Chicharrón 10 oz
  '6fcd25a7-f89d-4e32-b3c2-72139c65b15d',   -- Pepperoni Pedrollo
  '61b0c503-5ad6-428a-912e-f3e242d8c87a',   -- Pollo mechado 4 oz
  '485d54f4-8499-4de5-a683-0c7f9e1ff1bb',   -- Salami Genoa
  '914856c3-dfb0-42f2-a984-01a36498a1a3',   -- Salmón penca
  'cf27f185-e99d-4502-8578-906e453eb004',   -- Pasta Penne
  '44a5e30a-3df1-4596-8e5c-723f8d607fdc'    -- Pasta Linguine
)
order by i.name;


-- ---------------------------------------------------------------------------
-- 3. LAS PASTAS DUPLICADAS — antes de cargarles stock, decidir cuál se usa.
--
--    Hay tres pastas que podrían ser la misma cosa con nombres de proveedor
--    distintos. Si «Pasta Penne» y «Pasta Penne Bravo» son el mismo producto,
--    cargarles stock a las dos parte el inventario en dos y ninguna de las
--    dos cuadra después.
--
--    Los códigos lo dicen: 807680... es Barilla (italiano) y 205000... es un
--    código interno de Bravo (el supermercado). Son marcas distintas — pero
--    hay que confirmar si la cocina de verdad usa las dos.
-- ---------------------------------------------------------------------------
select i.id, i.name, i.unit, i.sku, round(coalesce(i.cost,0),2) as costo,
       coalesce((select sum(s.quantity) from public.inventory_stock s
                  where s.item_id = i.id), 0) as existencia,
       i.created_at at time zone 'America/Santo_Domingo' as creado
from public.inventory_items i
where i.business_id = '35c5076a-bd85-4a1b-8d1c-ce719c4f9ae6'
  and coalesce(i.is_active, true)
  and i.name ~* '\m(pasta|linguin|penne|codito|espagueti|spaghetti)'
order by i.name;


-- ---------------------------------------------------------------------------
-- 4. CARGAR LAS CANTIDADES DEL PAPEL EN EL CONTEO DE COCINA.
--
--    Ya con las unidades correctas, las 13 cantidades entran directo. Las
--    líneas que no existan en la sesión se crean; las que existan se
--    actualizan. Snapshot 0 porque todos están en cero.
--
--    ⚠️ CORRER DESPUÉS del paso 1, no antes: si se carga «17» mientras la
--    unidad todavía dice «unidad», el número queda bien pero significa otra
--    cosa, y al valorar sale mal.
-- ---------------------------------------------------------------------------
with cant(item_id, q) as (values
  ('d6c63496-fd67-42ce-9cd6-b4d99e1b2d92'::uuid,   6.0),   -- PASTRAMI            lb
  ('485d54f4-8499-4de5-a683-0c7f9e1ff1bb'::uuid,   9.0),   -- Salami Genoa        lb
  ('6fcd25a7-f89d-4e32-b3c2-72139c65b15d'::uuid,   3.3),   -- Pepperoni Pedrollo  lb
  ('4775fcb3-8759-47b0-81aa-9819351de75d'::uuid,   1.0),   -- Picante Red Hot     unidad
  ('1f814aac-9429-4616-b02f-028506747f7f'::uuid,   1.69),  -- Genjibre            lb
  ('0970382d-2832-499c-9368-c23a1ab3fa84'::uuid,   1.0),   -- Aceite especial     lata
  ('914856c3-dfb0-42f2-a984-01a36498a1a3'::uuid,   2.0),   -- Salmón penca        lb
  ('4b5aaf6e-7efe-4b6f-bc7b-3ff06e4ae3ac'::uuid,  66.0),   -- Chicharrón 10 oz    bolsa
  ('61b0c503-5ad6-428a-912e-f3e242d8c87a'::uuid, 126.0),   -- Pollo mechado 4 oz  bolsa
  ('97857b62-04cd-47c2-bdfb-5b87cf4b3530'::uuid,  10.0),   -- PECHURINA           bolsa
  ('4073534c-f9bf-4d86-ab65-8077b0e246bb'::uuid, 150.0),   -- Cativía de queso    unidad
  ('cf27f185-e99d-4502-8578-906e453eb004'::uuid,  17.0),   -- Pasta Penne         bolsa
  ('44a5e30a-3df1-4596-8e5c-723f8d607fdc'::uuid,  15.0)    -- Pasta Linguine      bolsa
)
insert into public.physical_count_lines
  (session_id, item_id, snapshot_quantity, counted_quantity, counter_notes)
select
  s.id, c.item_id,
  coalesce((select st.quantity from public.inventory_stock st
             where st.item_id = c.item_id
               and st.warehouse_id = s.warehouse_id), 0),
  c.q,
  'Hoja PENDIENTES EN SISTEMA, conteo de cocina 01-09-26.'
from public.physical_count_sessions s
cross join cant c
where s.business_id = '35c5076a-bd85-4a1b-8d1c-ce719c4f9ae6'
  and s.code = 'PC-2026-000003'
on conflict (session_id, item_id) do update
  set counted_quantity = excluded.counted_quantity,
      counter_notes    = excluded.counter_notes,
      updated_at       = now();
-- Debe decir INSERT 0 13.


-- ---------------------------------------------------------------------------
-- 5. VERIFICAR — los 13, con su unidad y su cantidad cargada.
-- ---------------------------------------------------------------------------
select
  i.name, i.unit, round(coalesce(i.cost,0),2) as costo,
  l.counted_quantity as contado,
  round(l.counted_quantity * coalesce(i.cost,0), 2) as valor,
  case when coalesce(i.cost,0) = 0 then '⚠️ sin costo' else 'ok' end as nota
from public.physical_count_lines l
join public.physical_count_sessions s on s.id = l.session_id
join public.inventory_items i on i.id = l.item_id
where s.business_id = '35c5076a-bd85-4a1b-8d1c-ce719c4f9ae6'
  and s.code = 'PC-2026-000003'
  and i.id in (
    'd6c63496-fd67-42ce-9cd6-b4d99e1b2d92','485d54f4-8499-4de5-a683-0c7f9e1ff1bb',
    '6fcd25a7-f89d-4e32-b3c2-72139c65b15d','4775fcb3-8759-47b0-81aa-9819351de75d',
    '1f814aac-9429-4616-b02f-028506747f7f','0970382d-2832-499c-9368-c23a1ab3fa84',
    '914856c3-dfb0-42f2-a984-01a36498a1a3','4b5aaf6e-7efe-4b6f-bc7b-3ff06e4ae3ac',
    '61b0c503-5ad6-428a-912e-f3e242d8c87a','97857b62-04cd-47c2-bdfb-5b87cf4b3530',
    '4073534c-f9bf-4d86-ab65-8077b0e246bb','cf27f185-e99d-4502-8578-906e453eb004',
    '44a5e30a-3df1-4596-8e5c-723f8d607fdc')
order by nota desc, i.name;
