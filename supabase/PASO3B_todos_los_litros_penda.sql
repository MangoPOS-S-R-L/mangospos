-- =============================================================================
-- PASO 3B · LA PENDA EXPRESS — sacar TODOS los sólidos de «litros»
-- business_id = 35c5076a-bd85-4a1b-8d1c-ce719c4f9ae6
--
-- Quedan 48 insumos en «L» que no son líquidos. Es la libra disfrazada de
-- litro: el selector de la app no tenía libra (`baseUnitOptions` = unidad · ml
-- · L · oz · g · kg), así que quien la necesitaba escogía la «L». Ya está
-- arreglado en el código; esto arregla los datos.
--
-- ── TODO ES RE-ETIQUETADO ────────────────────────────────────────────────
-- No se toca NINGUNA cantidad. Impacto en el valor del inventario: CERO.
-- La consulta final lo comprueba comparando el total antes y después.
--
-- ── IDEMPOTENTE ──────────────────────────────────────────────────────────
-- Cada update lleva `and lower(btrim(unit)) = 'l'`, así que lo ya corregido
-- (pechuga, manteca, longaniza, alitas, zucchini, berenjena, carne salada,
-- cepa de apio) no se vuelve a tocar y correrlo dos veces no hace daño.
--
-- ── EL MÉTODO: EL COSTO DELATA LA UNIDAD ─────────────────────────────────
-- RD$24 el apio y RD$35 el tomate son precios por LIBRA de mercado. RD$4,500
-- la «unidad» de azúcar no es una libra ni de casualidad: es un saco. Es el
-- mismo razonamiento que destapó la manteca y la cepa de apio.
--
-- CORRER UNA SENTENCIA A LA VEZ.
-- =============================================================================

-- ---------------------------------------------------------------------------
-- 0. LA FOTO DE ANTES — para comprobar al final que nada cambió de valor.
-- ---------------------------------------------------------------------------
select
  count(*)                                          as insumos_en_litros,
  round(sum(coalesce((select sum(st.quantity) from public.inventory_stock st
                       where st.item_id = i.id), 0)
            * coalesce(i.cost, 0)), 2)              as valor_total
from public.inventory_items i
where i.business_id = '35c5076a-bd85-4a1b-8d1c-ce719c4f9ae6'
  and coalesce(i.is_active, true)
  and lower(btrim(i.unit)) = 'l';


-- ---------------------------------------------------------------------------
-- 1. LOS QUE SE PESAN — 24 insumos a LIBRA.
--
--    Carnes, quesos, vegetales y víveres. El costo cuadra con la libra en
--    todos: RD$24 el apio, RD$26 la zanahoria, RD$35 el tomate y la yuca,
--    RD$180 la panceta, RD$247 el jamón de pavo (el nombre ya dice LBS),
--    RD$489 el salmón, RD$495 el grana padano.
-- ---------------------------------------------------------------------------
update public.inventory_items set unit = 'lb'
 where business_id = '35c5076a-bd85-4a1b-8d1c-ce719c4f9ae6'
   and lower(btrim(unit)) = 'l'
   and id in (
     'dbce710c-b13c-474c-a7d9-9ebc967c30a7',  -- PANCETA DE CERDO        180
     'c2031eb4-b8eb-4903-87e9-ce6c947c8a52',  -- ALAS DE POLLO AL GRANEL  92.37
     '394aabb4-88ac-4bea-9c1a-17824c6566c7',  -- QUESO FRESCO DE FREIR   219
     'e27e130e-9506-452e-b837-dd145981fda0',  -- QUESO DE FREIR BLANCO   219
     'da88845e-d27c-479a-aa3f-1a301bb78ee8',  -- Aji morron Verde         72
     'e1890ea5-ef55-40da-9c5c-5cb00e281a1e',  -- JAMON DE PAVO CASERIO   247
     '3aa5b603-8322-4f59-b166-9e5655ca27ab',  -- AJO                     130
     '2c0fb650-444d-4e7c-9ba6-87a7cdec74aa',  -- YUCA                     38
     '5634deb7-9ba9-447a-a1c2-bcf864b4f1d7',  -- GRANA PADANO            495
     'cc01f726-1955-47e4-8060-fa5afa9a9e65',  -- Aji morron Rojo          65
     '6ba4e779-fceb-4143-b71b-e231bcbc334d',  -- TOMATE BARCELO           35
     '5ecae117-de3f-4921-a3de-8e5055997b49',  -- TOMATE DE ENSALADA       40
     'cdee569a-f603-4818-a0cf-5675ddb1d6bd',  -- Aji Cubanela             45
     '10fcc7b3-921f-4da5-9720-fcd0f2e11a9b',  -- YAUTIA BLANCA            85
     'a97d0e8a-5cbf-4d23-87b4-b4207f1f8eac',  -- YAUTIA AMARILLA          85
     '2e21de50-092c-40dc-ab08-ec8e8c3da512',  -- PITAHAYA CONGELADA       85
     'df112b8a-7458-416a-a666-db3036d994e1',  -- FILETE DE SALMON        489
     'e7dc40a8-5100-4b38-8e40-88f053ac8a80',  -- Aji morron amarillo      65
     'e10a12b1-e916-4b8e-9f0e-40c4ed6d8bc4',  -- yautia morada            70
     '8ec8627b-53fb-4a40-970e-6b081526469a',  -- ZANAHORIA                26
     '122a3d3f-2e0e-4adf-891b-44f7672abd7e',  -- PUERRO ANCHO             40
     '56da1160-5ff8-4224-b05c-634f99329432',  -- Apio                     24
     '1e9998a7-ccf8-41f6-ab2a-1ee64f737cb3',  -- YUCA DEL MERCADO         35
     '9ac87904-f7cb-4f9c-9483-419d98209c8f'   -- Aullama                  35
   );
-- Debe decir UPDATE 24 (menos los que ya estuvieran en lb).


-- ---------------------------------------------------------------------------
-- 2. LOS QUE SE CUENTAN POR PIEZA — 5 insumos a UNIDAD.
--
--    Una lechuga, un repollo, una coliflor y una gallinita se cuentan enteros.
--    RD$35 una lechuga y RD$75 una gallinita pequeña son precios por pieza.
-- ---------------------------------------------------------------------------
update public.inventory_items set unit = 'unidad'
 where business_id = '35c5076a-bd85-4a1b-8d1c-ce719c4f9ae6'
   and lower(btrim(unit)) = 'l'
   and id in (
     '69b10487-57c6-4587-89b1-b05de317e442',  -- Lechuga risada           35
     '01f020d2-72a1-4623-8772-34e03521ba55',  -- Lechuga ROMANA           35
     '3056a611-8260-42c9-b851-6876f8ab7a7b',  -- coliflor                 60
     '44af8607-83fd-473b-a968-31f4a4c73328',  -- REPOLLO MORADO           40
     'd8184e1b-225b-4fae-bbd4-53e9212f5e89'   -- GALLINITAS PEQ CONGELADAS 75
   );
-- Debe decir UPDATE 5.


-- ---------------------------------------------------------------------------
-- 3. LAS HIERBAS FRESCAS — 7 insumos a MANOJO.
--
--    El cilantro, el perejil, la albahaca, la hierbabuena y el romero se
--    compran y se cuentan por MANOJO, no por libra. La prueba está en las
--    existencias: 15, 11, 9, 4, 2, 1 — números enteros y chicos. Un insumo
--    que se pesa muestra decimales (la panceta tiene 963.16, el puerro 11).
--
--    «PAQUET DE MENTA» ya lo dice en el nombre y va a `paquete`.
--
--    ⚠️ ES UN JUICIO, NO UNA CERTEZA. Si la cocina las pesa, el update de
--    abajo las pasa a libra en un segundo — pero entonces «1 romero» serían
--    RD$235 la libra, que para romero fresco es caro.
-- ---------------------------------------------------------------------------
update public.inventory_items set unit = 'manojo'
 where business_id = '35c5076a-bd85-4a1b-8d1c-ce719c4f9ae6'
   and lower(btrim(unit)) = 'l'
   and id in (
     'f13b80f1-7d73-4ca5-a940-45c8f461d656',  -- Albahaca                100 · 15
     '3206254e-9696-48eb-9e43-c14caa652515',  -- PEREJIL RISADO          100 · 11
     'ac8d700d-097b-48b9-afe0-d81dbc57d371',  -- cilantro fino            95 ·  9
     '5d6738b5-3d3c-48e1-b376-2bac3b4ab1b6',  -- cilantro ancho           70 ·  2
     '3d6d2e8d-0ad1-4c19-9e41-d606f1cd3fc5',  -- Hierba buena            100 ·  4
     'f33669eb-70b6-47cb-97c5-0e3a75168d21'   -- ROMERO                  235 ·  1
   );

update public.inventory_items set unit = 'paquete'
 where id = 'e12b90be-2c4e-47c3-a87e-abf4e4e60093'   -- PAQUET DE MENTA  150 · 2
   and lower(btrim(unit)) = 'l';
-- Debe decir UPDATE 6 y UPDATE 1.

-- Si la cocina dice que las pesa, revertir a libra:
-- update public.inventory_items set unit = 'lb'
--  where id in ('f13b80f1-7d73-4ca5-a940-45c8f461d656',
--               '3206254e-9696-48eb-9e43-c14caa652515',
--               'ac8d700d-097b-48b9-afe0-d81dbc57d371',
--               '5d6738b5-3d3c-48e1-b376-2bac3b4ab1b6',
--               '3d6d2e8d-0ad1-4c19-9e41-d606f1cd3fc5',
--               'f33669eb-70b6-47cb-97c5-0e3a75168d21');


-- =============================================================================
-- 4. ⛔ LOS CINCO CAROS — NO CORRER SIN CONFIRMAR
--
-- Estos NO son libras ni piezas: el costo dice que la «unidad» es un BULTO.
-- Y acá el re-etiquetado NO alcanza, porque hay que saber cuánto trae el
-- bulto para poder declarar el empaque. Sin ese dato, cambiar la unidad deja
-- el insumo igual de inservible, solo que con otra palabra.
--
--   AZUCAR BLANCA          RD$4,500 x 251 = RD$1,129,500   ← el renglón más
--                          grande de TODO el inventario. RD$4,500 es un saco
--                          de 100 lb. PREGUNTA: ¿de cuántas libras es el saco?
--
--   CHEF TOCINETA RED 5/3 LB  RD$4,100 x 4 = RD$16,400
--                          El nombre lo dice: 5 paquetes de 3 lb = 15 lb.
--                          Casi seguro es CAJA, pero confirmar.
--
--   QUESO BLANCO DE FREIR SIGMA  RD$7,869.17 x 1
--   QUESO MOZARELLA SIGMA        RD$6,156.00 x 1
--   QUESO GEO                    RD$3,094.58 x 1
--                          Tres quesos industriales a precio de CAJA.
--                          PREGUNTA: ¿cuántas libras trae cada caja?
--
-- ⚠️ Y OJO CON LA EXISTENCIA: si el azúcar pasa a `saco` con pack_size 100,
--    las 251 de hoy siguen siendo 251 SACOS — está bien. Pero si alguien
--    decidiera llevarla en libras, habría que multiplicar por 100, y eso ya
--    es un ajuste de cantidad, no un re-etiquetado.
--
-- Cuando tengas los datos:
-- update public.inventory_items
--    set unit = 'saco', purchase_unit = 'Saco', pack_size = <libras por saco>
--  where id = 'f732eb4c-bb92-4a0b-9582-974ef7ce5775';   -- AZUCAR BLANCA
--
-- update public.inventory_items
--    set unit = 'caja', purchase_unit = 'Caja', pack_size = 15
--  where id = 'c8c45267-3ca5-4eff-b5ee-4cfbe5d637aa';   -- CHEF TOCINETA
--
-- update public.inventory_items
--    set unit = 'caja', purchase_unit = 'Caja', pack_size = <libras por caja>
--  where id in ('a2c6f18b-908f-40e6-81da-8647a2baaf05',  -- SIGMA blanco
--               '2f9016fa-7ffe-4367-b563-d8bb4d61e7e1',  -- SIGMA mozzarella
--               '50ca7ec4-48b8-4421-a10f-80af73ed7cfa'); -- QUESO GEO
-- =============================================================================

-- La lista de los cinco, para llevársela a la cocina:
select i.id, i.name, i.unit, round(coalesce(i.cost,0),2) as costo,
       coalesce((select sum(st.quantity) from public.inventory_stock st
                  where st.item_id = i.id), 0)           as existencia,
       round(coalesce((select sum(st.quantity) from public.inventory_stock st
                        where st.item_id = i.id), 0) * coalesce(i.cost,0), 2)
                                                         as valor
from public.inventory_items i
where i.id in ('f732eb4c-bb92-4a0b-9582-974ef7ce5775',
               'c8c45267-3ca5-4eff-b5ee-4cfbe5d637aa',
               'a2c6f18b-908f-40e6-81da-8647a2baaf05',
               '2f9016fa-7ffe-4367-b563-d8bb4d61e7e1',
               '50ca7ec4-48b8-4421-a10f-80af73ed7cfa')
order by 6 desc;


-- ---------------------------------------------------------------------------
-- 5. VERIFICAR — el censo, y que el valor no se movió.
-- ---------------------------------------------------------------------------
select
  coalesce(nullif(btrim(i.unit), ''), '(vacía)')     as unidad,
  count(*)                                           as insumos,
  round(100.0 * count(*) / sum(count(*)) over (), 1) as pct,
  round(sum(coalesce((select sum(st.quantity) from public.inventory_stock st
                       where st.item_id = i.id), 0)
            * coalesce(i.cost, 0)), 2)               as valor
from public.inventory_items i
where i.business_id = '35c5076a-bd85-4a1b-8d1c-ce719c4f9ae6'
  and coalesce(i.is_active, true)
group by 1
order by count(*) desc;

-- (segunda sentencia) — los que TODAVÍA quedan en litros.
--   Deben quedar solo los 5 caros del punto 4 y los líquidos de verdad.
select i.id, i.name, round(coalesce(i.cost,0),2) as costo,
       coalesce((select sum(st.quantity) from public.inventory_stock st
                  where st.item_id = i.id), 0) as existencia
from public.inventory_items i
where i.business_id = '35c5076a-bd85-4a1b-8d1c-ce719c4f9ae6'
  and coalesce(i.is_active, true)
  and lower(btrim(i.unit)) in ('l','lt','litro','litros')
order by i.name;
