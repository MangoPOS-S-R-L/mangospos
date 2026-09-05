-- =============================================================================
-- PASO 3 · LA PENDA EXPRESS — poner las unidades como la cocina las cuenta
-- business_id = 35c5076a-bd85-4a1b-8d1c-ce719c4f9ae6
--
-- De los 35 renglones del conteo, 23 tenían la unidad discordante. 17 de esos
-- decían «L» — la misma libra disfrazada de litro que ya arreglamos en el
-- selector de la app (`baseUnitOptions` no tenía libra, así que la gente
-- escogía la L).
--
-- ── TODO ESTO ES RE-ETIQUETADO ────────────────────────────────────────────
-- No se toca NINGUNA cantidad, ni de `inventory_stock` ni del conteo. El
-- número que hay es el correcto; la palabra que lo acompaña no lo era.
-- Impacto en el valor del inventario: CERO.
--
-- ── LO QUE NO ESTÁ ACÁ ────────────────────────────────────────────────────
-- · La pechuga va en `CORREGIR_pechuga_penda.sql` — es libras con recetas en
--   onzas, y además hay que bajar el conteo de 32 bolsas a 20 libras.
-- · Siete casos necesitan que la cocina conteste algo antes de tocarlos.
--   Están al final, comentados, con la pregunta exacta de cada uno.
--
-- CORRER UNA SENTENCIA A LA VEZ.
-- =============================================================================

-- ---------------------------------------------------------------------------
-- 1. LOS NUEVE DE «L» A LIBRA.
--
--    El papel los contó en libras y el costo lo confirma: RD$24 el apio,
--    RD$35 el tomate, RD$219 el queso de freír. Todos son precios por libra
--    de mercado dominicano; por litro no significarían nada.
-- ---------------------------------------------------------------------------
update public.inventory_items
   set unit = 'lb'
 where business_id = '35c5076a-bd85-4a1b-8d1c-ce719c4f9ae6'
   and lower(btrim(unit)) = 'l'
   and id in (
     'e7dc40a8-5100-4b38-8e40-88f053ac8a80',  -- Aji morron amarillo   RD$65
     'cdee569a-f603-4818-a0cf-5675ddb1d6bd',  -- Aji Cubanela          RD$45
     '6ba4e779-fceb-4143-b71b-e231bcbc334d',  -- TOMATE BARCELO        RD$35
     'cc01f726-1955-47e4-8060-fa5afa9a9e65',  -- Aji morron Rojo       RD$65
     '122a3d3f-2e0e-4adf-891b-44f7672abd7e',  -- PUERRO ANCHO          RD$40
     '56da1160-5ff8-4224-b05c-634f99329432',  -- Apio                  RD$24
     '8ec8627b-53fb-4a40-970e-6b081526469a',  -- ZANAHORIA             RD$26
     'e1890ea5-ef55-40da-9c5c-5cb00e281a1e',  -- JAMON DE PAVO (el nombre ya dice LBS)
     'e27e130e-9506-452e-b837-dd145981fda0'   -- QUESO DE FREIR BLANCO RD$219
   );
-- Debe decir UPDATE 9.


-- ---------------------------------------------------------------------------
-- 2. LOS DOS QUE SE CUENTAN POR PIEZA.
--
--    RD$35 un zucchini y RD$31 una berenjena son precios por pieza. El papel
--    también los contó por unidad; solo el sistema decía litros.
-- ---------------------------------------------------------------------------
update public.inventory_items
   set unit = 'unidad'
 where business_id = '35c5076a-bd85-4a1b-8d1c-ce719c4f9ae6'
   and lower(btrim(unit)) = 'l'
   and id in (
     '26697de2-775a-4e4f-9d28-2f76ca7190fa',  -- ZUCCHINI    RD$35
     '0cb23cb5-9d9f-4aa9-8796-d3d0d2b527a3'   -- Berengena   RD$31
   );
-- Debe decir UPDATE 2.


-- ---------------------------------------------------------------------------
-- 3. LOS TRES QUE SE CUENTAN POR BOLSA.
--
--    Acá la prueba es doble: el costo cuadra con la bolsa Y la existencia del
--    sistema queda cerca de lo contado, que es lo que uno espera cuando ambos
--    números hablan de lo mismo:
--
--       ALITAS FRESCAS    sistema 50    contó 46    RD$109 la bolsa
--       LONGANIZA         sistema 135   contó 110   RD$150 la bolsa
--       CEPA DE APIO      sistema 9     contó 8     RD$45  la bolsa
--
--    Si fueran libras contra bolsas, esos pares estarían separados por un
--    factor grande, no por un 8%.
-- ---------------------------------------------------------------------------
update public.inventory_items
   set unit = 'bolsa'
 where business_id = '35c5076a-bd85-4a1b-8d1c-ce719c4f9ae6'
   and id in (
     'ea915c9a-fd40-420b-bff9-31e338ae39a9',  -- ALITAS FRESCAS
     'f1aebda2-0464-46eb-b3f8-7fadce9f9c7c',  -- LONGANIZA CASERA ARTESANAL
     '68dff758-4461-49ec-b063-469cf3f8a1dd'   -- CEPA DE APIO
   );
-- Debe decir UPDATE 3.


-- ---------------------------------------------------------------------------
-- 4. LA MANTECA — se cuenta por caja.
--
--    RD$2,550 la «unidad» es imposible por libra y exacto por caja de 50
--    libras. El nombre ya lo dice: «MANTECA NUESTRA 50 libras».
--    Se le declara el empaque para que una receta pueda pedir libras.
-- ---------------------------------------------------------------------------
update public.inventory_items
   set unit = 'caja',
       purchase_unit = 'Caja',
       pack_size = 1
 where id = '777b31c5-301e-447b-ada1-de4013361f07';


-- ---------------------------------------------------------------------------
-- 5. VERIFICAR — ninguna cantidad se movió.
--
--    `valor_antes` y `valor_despues` tienen que dar IGUAL. Si difieren, algo
--    tocó una cantidad y hay que revisar.
-- ---------------------------------------------------------------------------
select
  i.name, i.unit, round(coalesce(i.cost,0),2) as costo,
  coalesce((select sum(s.quantity) from public.inventory_stock s
             where s.item_id = i.id), 0) as existencia,
  round(coalesce((select sum(s.quantity) from public.inventory_stock s
                   where s.item_id = i.id), 0) * coalesce(i.cost,0), 2) as valor
from public.inventory_items i
where i.id in (
  'e7dc40a8-5100-4b38-8e40-88f053ac8a80','cdee569a-f603-4818-a0cf-5675ddb1d6bd',
  '6ba4e779-fceb-4143-b71b-e231bcbc334d','cc01f726-1955-47e4-8060-fa5afa9a9e65',
  '122a3d3f-2e0e-4adf-891b-44f7672abd7e','56da1160-5ff8-4224-b05c-634f99329432',
  '8ec8627b-53fb-4a40-970e-6b081526469a','e1890ea5-ef55-40da-9c5c-5cb00e281a1e',
  'e27e130e-9506-452e-b837-dd145981fda0','26697de2-775a-4e4f-9d28-2f76ca7190fa',
  '0cb23cb5-9d9f-4aa9-8796-d3d0d2b527a3','ea915c9a-fd40-420b-bff9-31e338ae39a9',
  'f1aebda2-0464-46eb-b3f8-7fadce9f9c7c','68dff758-4461-49ec-b063-469cf3f8a1dd',
  '777b31c5-301e-447b-ada1-de4013361f07')
order by i.unit, i.name;


-- ---------------------------------------------------------------------------
-- 6. EL CENSO — cuánto bajó la «L».
--    Venía de 52 → 48 (tras el primer arreglo). Con estos 14 debe quedar ~34.
-- ---------------------------------------------------------------------------
select
  coalesce(nullif(btrim(i.unit), ''), '(vacía)')     as unidad,
  count(*)                                           as insumos,
  round(100.0 * count(*) / sum(count(*)) over (), 1) as porcentaje
from public.inventory_items i
where i.business_id = '35c5076a-bd85-4a1b-8d1c-ce719c4f9ae6'
  and coalesce(i.is_active, true)
group by 1
order by count(*) desc;


-- =============================================================================
-- ⛔ NO CORRER — LOS SIETE QUE NECESITAN RESPUESTA DE LA COCINA
--
-- Cada uno tiene la pregunta y el update listo para cuando la contesten.
-- =============================================================================

-- ▸ HUEVOS FRECOS — sistema 3,450 unidad a RD$4.60 · papel 29 CARTONES
--   RD$4.60 es el precio de UN huevo, así que la unidad está bien. Falta el
--   tamaño del cartón. PREGUNTA: ¿cuántos huevos trae el cartón?
--     30 → el conteo son 870    ·    36 → son 1,044
--   update public.physical_count_lines l set counted_quantity = 29 * <30 ó 36>
--     from public.physical_count_sessions s
--    where l.session_id = s.id and s.code = 'PC-2026-000003'
--      and l.item_id = '3306a200-6105-456d-b1b7-54ea5603e8e7';

-- ▸ LIMONES FRESCOS — sistema 2,390 unidad a RD$9.50 · papel 25 LIBRAS
--   PREGUNTA: ¿los RD$9.50 son por limón o por libra? Una libra son 6-8
--   limones, así que 25 libras ≈ 175 limones contra 2,390. El hueco es
--   enorme en cualquiera de las dos lecturas y hay que entenderlo antes.

-- ▸ CARNE SALADA — sistema 48 «L» a RD$140 · papel 1 BOLSA
--   El Excel del 1-sep decía 6.25 y hoy el sistema dice 48: alguien la movió
--   entre medio. 6.25 lb eran exactamente 10 bolsas de 10 oz; 48 no cuadra
--   con nada. PREGUNTA: ¿qué pasó con la carne salada entre el 1 y hoy?

-- ▸ PIMIENTA NEGRA MOLIDA — sistema 1 unidad a RD$1,832 · papel 5 LIBRAS
--   La libra de pimienta anda por RD$400-600, así que RD$1,832 es un pote
--   grande — probablemente de 5 libras, y el papel contó el CONTENIDO.
--   PREGUNTA: ¿cuántas libras trae el pote?  Si son 5:
--   update public.inventory_items
--      set unit='lb', cost=1832/5.0, purchase_unit='Pote', pack_size=5
--    where id='22c6c8f6-4237-407b-a954-0190d4596b43';
--   ⚠️ el stock también tendría que pasar de 1 a 5 — eso va por
--      fn_inventory_adjust, no por update directo.

-- ▸ PALITOS YUQUITAS BOLSA — sistema 141.9 lb a RD$105 · papel 39 UNIDAD
--   El nombre dice BOLSA y RD$105 la bolsa cuadra, pero el 141.9 con decimal
--   huele a libras. Se contradicen. PREGUNTA: ¿se cuenta por bolsa o se pesa?

-- ▸ MORTADELA ALEGRIA — sistema 20 unidad a RD$488 · papel 20 LIBRAS
--   Los dos números coinciden, así que la «unidad» ya es la libra y el
--   conteo no mueve nada. Pero RD$488 la libra de mortadela es carísimo.
--   PREGUNTA: ¿los RD$488 son por libra o por pieza entera?

-- ▸ FILETE DE SALMON — sistema 3.7 «L» a RD$489 · papel 1 unidad de 8 onzas
--   Y en el conteo hay cargado un 2, que no es ni 1 ni 3.7. Tres números
--   distintos. PREGUNTA: ¿el salmón se lleva por filete o por libra?
