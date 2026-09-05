-- =============================================================================
-- LA PENDA EXPRESS — el pollo: qué está crudo, qué está porcionado
-- business_id = 35c5076a-bd85-4a1b-8d1c-ce719c4f9ae6
--
-- Antes de decidir cómo se sube lo que falta hay que ver qué hay. La pregunta
-- concreta: ¿cuáles insumos de pollo son MATERIA PRIMA (se compran en libras)
-- y cuáles son PORCIONADOS (salen de la cocina en bolsas)?
--
-- Es la misma pregunta para la carne, el cerdo y el queso. Cambiá el filtro
-- del paso 1 para mirarlos.
-- =============================================================================

-- ---------------------------------------------------------------------------
-- 1. TODO LO QUE DICE POLLO / PECHUGA — con su unidad, costo y existencia.
--
--    Cómo leerlo: si la unidad es libra y el costo es de RD$60–120, es
--    materia prima. Si la unidad es bolsa/unidad y el nombre trae un peso
--    («4 oz», «10 oz»), es porcionado y salió de la cocina.
-- ---------------------------------------------------------------------------
select
  i.id,
  i.name                                          as articulo,
  i.unit                                          as unidad,
  i.purchase_unit,
  i.pack_size,
  round(coalesce(i.cost, 0), 2)                   as costo,
  coalesce((select sum(s.quantity) from public.inventory_stock s
             where s.item_id = i.id), 0)          as existencia,
  round(coalesce((select sum(s.quantity) from public.inventory_stock s
                   where s.item_id = i.id), 0)
        * coalesce(i.cost, 0), 2)                 as valor,
  (select count(*) from public.recipe_ingredients ri
    where ri.inventory_item_id = i.id)            as en_recetas,
  case
    when i.name ~* '\m([0-9]+\s*(oz|onz|onza|onzas|lb|libra|libras|g|gr))\M'
      then 'PORCIONADO — el nombre trae el peso de la porción'
    when i.unit ~* '^(lb|libra|libras)$'
      then 'materia prima (se compra por libra)'
    else 'revisar'
  end                                             as tipo
from public.inventory_items i
where i.business_id = '35c5076a-bd85-4a1b-8d1c-ce719c4f9ae6'
  and coalesce(i.is_active, true)
  and i.name ~* '\m(pollo|pechuga|pechurina|ala|alitas|muslo|contramuslo)\M'
order by
  coalesce((select sum(s.quantity) from public.inventory_stock s
             where s.item_id = i.id), 0) * coalesce(i.cost, 0) desc;


-- ---------------------------------------------------------------------------
-- 2. ¿SE HA USADO EL MÓDULO DE PRODUCCIÓN ALGUNA VEZ?
--
--    Si esto vuelve vacío, la respuesta es no — y entonces el hueco de la
--    pechuga tiene explicación: las libras crudas nunca se bajaron al
--    porcionar, así que quedaron acumuladas en el sistema mientras
--    físicamente ya eran bolsas.
-- ---------------------------------------------------------------------------
select
  po.code,
  po.status,
  fi.name                                         as producto_terminado,
  po.planned_yield,
  po.actual_yield,
  po.completed_at,
  (select count(*) from public.production_order_lines l
    where l.production_order_id = po.id)          as insumos_consumidos
from public.production_orders po
join public.inventory_items fi on fi.id = po.finished_item_id
where po.business_id = '35c5076a-bd85-4a1b-8d1c-ce719c4f9ae6'
order by po.created_at desc
limit 20;


-- ---------------------------------------------------------------------------
-- 3. EL MOVIMIENTO DE LA PECHUGA — de dónde salieron esas libras.
--
--    Cambiá el id por el de la pechuga que salga en el paso 1. Si solo hay
--    entradas de compra y ninguna salida, confirma que nunca se descontó al
--    porcionar, y el «hueco» no es un descuadre sino un descuento que nunca
--    ocurrió.
-- ---------------------------------------------------------------------------
-- select m.created_at at time zone 'America/Santo_Domingo' as fecha,
--        m.movement_type, m.quantity, m.notes, w.name as bodega
--   from public.inventory_movements m
--   left join public.warehouses w on w.id = m.warehouse_id
--  where m.item_id = '<id de la pechuga>'
--  order by m.created_at desc
--  limit 50;
