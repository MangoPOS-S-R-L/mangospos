-- =============================================================================
-- LA PENDA EXPRESS — la pechuga: un solo insumo, recetas en onzas
-- business_id = 35c5076a-bd85-4a1b-8d1c-ce719c4f9ae6
-- item_id     = 5fd1d147-6508-449e-a9c9-83c79c6a98bb  (código 0401-00018)
--
-- ── EL MODELO CORRECTO ────────────────────────────────────────────────────
-- La pechuga se COMPRA por libras y se AGREGA A LA RECETA en onzas, y de ella
-- salen cuatro platos: A LA PLANCHA, A LA CREMA, RELLENA y A LA PARMESANA.
--
-- Entonces es UN solo insumo, en libras. Las bolsas de 10 onzas son una
-- comodidad de la cocina, no algo que el sistema tenga que llevar aparte:
-- cada receta pide sus onzas y el sistema las convierte a libras al guardar.
--
-- (Un insumo porcionado aparte solo haría falta si hubiera que saber cuántas
-- bolsas hay Y cuántas libras crudas al mismo tiempo. Con las recetas en
-- onzas eso no hace falta, y agregarlo sería un número más que mantener.)
--
-- ── LO QUE HUBO QUE ARREGLAR EN LA APP PRIMERO ────────────────────────────
-- La onza estaba fija como VOLUMEN (29.5735 ml). Con el insumo en libras,
-- `convertUnit(10, 'oz', 'lb')` daba null por ser familias distintas, y
-- `_toBaseQty` hace `converted ?? qty` — o sea guardaba **10** crudo.
-- Cada plato habría descontado 10 LIBRAS en vez de 0.625. Dieciséis veces
-- de más, en silencio, en los cuatro platos.
--
-- Ya está: la onza se resuelve por CONTEXTO. Contra un insumo de peso son
-- 28.3495 g; contra uno de volumen siguen siendo 29.5735 ml, así que los
-- cócteles del bar no se tocan. 18 tests cubren ambos lados.
--
-- CORRER UNA SENTENCIA A LA VEZ.
-- =============================================================================

-- ---------------------------------------------------------------------------
-- 1. LA MATERIA PRIMA A LIBRAS — hoy dice «L», que es litros.
--    Re-etiquetado puro: no se toca ninguna cantidad.
-- ---------------------------------------------------------------------------
update public.inventory_items
   set unit = 'lb'
 where id = '5fd1d147-6508-449e-a9c9-83c79c6a98bb'
   and lower(btrim(unit)) = 'l';


-- ---------------------------------------------------------------------------
-- 2. EL CONTEO: 32 bolsas de 10 onzas son 20 LIBRAS, no 32.
--
--    32 × 10 oz = 320 oz ÷ 16 = 20 lb exactas.
--
--    Esto es lo urgente. Si la sesión se cierra con el 32 puesto, el sistema
--    lo lee como 32 libras y la diferencia contra las 1,575.99 sale como
--    «diferencia de conteo». Con 20 la cifra al menos dice lo que la cocina
--    de verdad tenía enfrente.
--
--    ⚠️ Igual quedan 1,556 libras sin explicar (RD$217,839). Eso NO lo
--    resuelve este update — se resuelve con `DECIDIR_pechuga_penda.sql`, y
--    hasta entonces la sesión de cocina no se cierra.
-- ---------------------------------------------------------------------------
update public.physical_count_lines l
   set counted_quantity = 20,
       counter_notes = 'El papel decía 32 BOLSAS de 10 oz = 20 lb exactas '
                     || '(32 × 10 ÷ 16). El insumo se lleva en libras.',
       updated_at = now()
  from public.physical_count_sessions s
 where l.session_id = s.id
   and s.business_id = '35c5076a-bd85-4a1b-8d1c-ce719c4f9ae6'
   and s.code = 'PC-2026-000003'
   and l.item_id = '5fd1d147-6508-449e-a9c9-83c79c6a98bb';


-- ---------------------------------------------------------------------------
-- 3. LOS CUATRO PLATOS — ¿ya tienen receta con la pechuga?
--
--    Si esto vuelve vacío, se han vendido pechugas durante meses sin que
--    ninguna bajara del inventario. Y eso explicaría de dónde salieron las
--    1,576 libras: las compras sumaron y nada restó nunca.
-- ---------------------------------------------------------------------------
select
  mi.id                                       as menu_item_id,
  mi.name                                     as plato,
  round(mi.price, 2)                          as precio,
  r.id                                        as receta_id,
  ri.quantity                                 as lleva,
  ri.unit                                     as en_que_unidad,
  ii.name                                     as insumo
from public.menu_items mi
left join public.recipes r on r.menu_item_id = mi.id
left join public.recipe_ingredients ri on ri.recipe_id = r.id
left join public.inventory_items ii on ii.id = ri.inventory_item_id
where mi.business_id = '35c5076a-bd85-4a1b-8d1c-ce719c4f9ae6'
  and mi.name ~* '\mpechuga\M'
order by mi.name, ii.name;


-- ---------------------------------------------------------------------------
-- 4. LAS RECETAS — se hacen DESDE LA APP, no acá.
--
--    Ajustes → Menús → Recetas. Por cada plato, un ingrediente:
--
--       FILETE DE PECHUGA DE POLLO FRESCO   ·   10   ·   oz
--
--    La app convierte al guardar: 10 oz → 0.625 lb, que es lo que va a
--    `recipe_ingredients.quantity`. Verificalo con la consulta 5.
--
--    Las onzas de cada plato las pone la cocina — 10 oz para la plancha,
--    quizá más para la rellena. No las inventes acá.
--
--    ⚠️ HACELO CON UN BUILD NUEVO. La resolución de la onza por contexto
--    acaba de entrar al código; con un build viejo, `convertUnit(10,'oz','lb')`
--    devuelve null y la receta se guarda con **10** — que descontaría 10
--    libras por plato. Si ya hay recetas guardadas con un build viejo, la
--    consulta 5 las delata.
-- ---------------------------------------------------------------------------


-- ---------------------------------------------------------------------------
-- 5. VERIFICAR LAS RECETAS — que hayan quedado en libras, no en onzas crudas.
--
--    `quantity` se guarda ya convertida a la unidad base del insumo. Para un
--    filete de 10 oz tiene que decir **0.625**. Si dice 10, esa receta se
--    guardó sin convertir y hay que rehacerla.
-- ---------------------------------------------------------------------------
select
  mi.name                                     as plato,
  ri.quantity                                 as guardado,
  ri.unit                                     as etiqueta,
  case
    when ri.quantity between 0.2 and 3   then 'OK — está en libras'
    when ri.quantity >= 5                then 'MAL — parece onzas sin convertir'
    else 'revisar'
  end                                         as diagnostico,
  round(ri.quantity * 140, 2)                 as costo_por_plato,
  round(mi.price, 2)                          as precio_venta
from public.recipe_ingredients ri
join public.recipes r on r.id = ri.recipe_id
join public.menu_items mi on mi.id = r.menu_item_id
where ri.inventory_item_id = '5fd1d147-6508-449e-a9c9-83c79c6a98bb'
order by mi.name;
