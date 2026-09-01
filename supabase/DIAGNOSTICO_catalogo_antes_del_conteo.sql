-- =============================================================================
-- DIAGNÓSTICO DEL CATÁLOGO ANTES DEL PRIMER CONTEO — Penda
-- business_id: 35c5076a-bd85-4a1b-8d1c-ce719c4f9ae6
--
-- Contexto: 1,088 insumos activos. El congelado del conteo incluye TODOS los
-- activos, así que la hoja va a salir con 1,088 renglones. Cada renglón basura
-- es tiempo perdido del que cuenta y una diferencia falsa al cerrar.
--
-- Correr UNA sentencia a la vez (el SQL Editor solo muestra la última).
-- =============================================================================

-- 1) PLATOS DEL MENÚ QUE SE VOLVIERON INSUMO.
--    El switch "Inventariable" del producto crea un inventory_item 1:1. Un
--    mofongo se hace al momento: no tiene existencia que contar y va a salir
--    con diferencia negativa siempre.
select mi.id            as menu_item_id,
       mi.name          as producto,
       ii.id            as insumo_id,
       ii.name          as insumo,
       ii.cost,
       coalesce(s.quantity, 0) as stock_actual
  from public.menu_items mi
  join public.inventory_items ii on ii.id = mi.inventory_item_id
  left join public.inventory_stock s on s.item_id = ii.id
 where mi.business_id = '35c5076a-bd85-4a1b-8d1c-ce719c4f9ae6'
   and mi.inventory_item_id is not null
   and coalesce(ii.is_active, true)
 order by mi.name;

-- 2) INSUMOS CUYO NOMBRE ES UN CÓDIGO DE BARRAS.
--    Nacieron de escanear sin ponerles nombre. Nadie puede contar
--    "009800007219" en una hoja de papel.
select id, sku, name, unit, cost,
       (select coalesce(sum(quantity), 0) from public.inventory_stock st
         where st.item_id = ii.id) as stock_actual
  from public.inventory_items ii
 where business_id = '35c5076a-bd85-4a1b-8d1c-ce719c4f9ae6'
   and coalesce(is_active, true)
   and name ~ '^[0-9]{8,14}$'
 order by name;

-- 3) BASURA DE PRUEBA.
--    Nombres sin vocal reconocible, muy cortos o claramente tecleados al azar.
select id, sku, name, unit, cost, created_at
  from public.inventory_items
 where business_id = '35c5076a-bd85-4a1b-8d1c-ce719c4f9ae6'
   and coalesce(is_active, true)
   and (
        length(trim(name)) <= 3
     or name ~* '^(test|prueba|aaa|xxx|asd|qwe)'
     or name ~ '^[a-z]{5,}$'          -- todo minúscula pegado: chemi, yhuyhgiuy
   )
 order by name;

-- 4) INSUMOS QUE NUNCA SE MOVIERON NI TIENEN EXISTENCIA.
--    Candidatos a desactivar: ocupan renglón en la hoja y nunca van a tener
--    nada que contar.
select ii.id, ii.sku, ii.name, ii.cost
  from public.inventory_items ii
  left join public.inventory_movements m on m.item_id = ii.id
  left join public.inventory_stock  s on s.item_id = ii.id
 where ii.business_id = '35c5076a-bd85-4a1b-8d1c-ce719c4f9ae6'
   and coalesce(ii.is_active, true)
 group by ii.id, ii.sku, ii.name, ii.cost
having count(m.id) = 0
   and coalesce(sum(s.quantity), 0) = 0
 order by ii.name;

-- 5) RESUMEN: cuánto se reduce la hoja si se limpia.
select count(*) as activos_hoy,
       count(*) filter (where name ~ '^[0-9]{8,14}$')            as nombre_es_barcode,
       count(*) filter (where length(trim(name)) <= 3
                           or name ~ '^[a-z]{5,}$')              as basura,
       count(*) filter (where exists (select 1 from public.menu_items mi
                                       where mi.inventory_item_id = ii.id)) as son_platos
  from public.inventory_items ii
 where business_id = '35c5076a-bd85-4a1b-8d1c-ce719c4f9ae6'
   and coalesce(is_active, true);

-- =============================================================================
-- BLOQUE 2 — lo que de verdad importa en Penda (catálogo retail 1:1)
-- =============================================================================

-- 6) EXISTENCIAS EN NEGATIVO. Esto es lo que el conteo viene a arreglar.
--    Cada negativo es mercancía que se vendió sin haber entrado al sistema.
select count(*)                                   as items_en_negativo,
       sum(s.quantity)                            as unidades_negativas,
       sum(s.quantity * coalesce(ii.cost, 0))     as valor_negativo
  from public.inventory_stock s
  join public.inventory_items ii on ii.id = s.item_id
 where ii.business_id = '35c5076a-bd85-4a1b-8d1c-ce719c4f9ae6'
   and coalesce(ii.is_active, true)
   and s.quantity < 0;

-- 7) El detalle de los negativos, del peor al menos malo.
select ii.name, ii.sku, s.quantity, ii.cost,
       s.quantity * coalesce(ii.cost, 0) as valor
  from public.inventory_stock s
  join public.inventory_items ii on ii.id = s.item_id
 where ii.business_id = '35c5076a-bd85-4a1b-8d1c-ce719c4f9ae6'
   and coalesce(ii.is_active, true)
   and s.quantity < 0
 order by s.quantity asc;

-- 8) NOMBRES QUE NO COINCIDEN entre el producto del menú y su insumo.
--    La hoja de conteo imprime el nombre del INSUMO, pero quien cuenta conoce
--    el anaquel por el nombre del PRODUCTO. Si dicen cosas distintas, se cuenta
--    en el renglón equivocado.
select mi.name as producto_en_menu,
       ii.name as insumo_en_hoja_de_conteo,
       coalesce(s.quantity, 0) as stock
  from public.menu_items mi
  join public.inventory_items ii on ii.id = mi.inventory_item_id
  left join public.inventory_stock s on s.item_id = ii.id
 where mi.business_id = '35c5076a-bd85-4a1b-8d1c-ce719c4f9ae6'
   and coalesce(ii.is_active, true)
   and upper(trim(mi.name)) <> upper(trim(ii.name))
 order by mi.name;

-- 9) RESTOS DE LA FUSIÓN DE DUPLICADOS del 30 de agosto.
select id, name, is_active
  from public.menu_items
 where business_id = '35c5076a-bd85-4a1b-8d1c-ce719c4f9ae6'
   and name ilike '%[DUPLICADO]%'
 order by name;
