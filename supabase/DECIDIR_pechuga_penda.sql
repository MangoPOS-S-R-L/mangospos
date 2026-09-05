-- =============================================================================
-- LA PENDA EXPRESS — la pechuga: probar de dónde salieron 1,576 libras
-- item_id = 5fd1d147-6508-449e-a9c9-83c79c6a98bb  (FILETE DE PECHUGA DE POLLO
-- FRESCO · código 0401-00018 · RD$140 · 1,575.99 en «L» · RD$220,639)
--
-- El conteo de cocina dice 32 bolsas de 10 onzas = 20 libras. La diferencia
-- son RD$216,159 y NO se puede dejar que salgan como «diferencia de conteo».
-- Estas cuatro consultas dicen si el número del sistema es mercancía real o
-- un fantasma que se fue acumulando.
--
-- CORRER UNA SENTENCIA A LA VEZ.
-- =============================================================================

-- ---------------------------------------------------------------------------
-- 1. ¿DÓNDE ESTÁN ESAS LIBRAS? — el reparto por bodega.
--
--    Si TODO está en cocina, la cocina contó lo que tenía enfrente y sobran
--    1,556 libras que no existen → opción A + ajuste documentado.
--    Si hay libras en el furgón o el almacén principal, esas SÍ son materia
--    prima real y la cocina solo contó su parte → opción B.
-- ---------------------------------------------------------------------------
select
  w.name                                     as bodega,
  s.quantity                                 as existencia,
  round(s.quantity * 140, 2)                 as valor,
  s.last_updated at time zone 'America/Santo_Domingo' as ultima_vez
from public.inventory_stock s
join public.warehouses w on w.id = s.warehouse_id
where s.item_id = '5fd1d147-6508-449e-a9c9-83c79c6a98bb'
order by s.quantity desc;


-- ---------------------------------------------------------------------------
-- 2. ¿ALGUNA VEZ SALIÓ ALGO? — entradas contra salidas.
--
--    Esta es LA consulta. Si `salidas` es 0 o casi 0 frente a las entradas,
--    queda probado: nunca se descontó al porcionar, y las 1,576 libras son
--    la suma de todas las compras desde que se creó el insumo.
-- ---------------------------------------------------------------------------
select
  m.movement_type,
  count(*)                                   as veces,
  sum(m.quantity)                            as total_libras,
  round(sum(m.quantity) * 140, 2)            as valor,
  min(m.created_at at time zone 'America/Santo_Domingo') as primera,
  max(m.created_at at time zone 'America/Santo_Domingo') as ultima
from public.inventory_movements m
where m.item_id = '5fd1d147-6508-449e-a9c9-83c79c6a98bb'
group by m.movement_type
order by 3 desc;


-- ---------------------------------------------------------------------------
-- 3. EL DETALLE — los últimos 40 movimientos, para ver el patrón con ojos.
-- ---------------------------------------------------------------------------
select
  m.created_at at time zone 'America/Santo_Domingo' as fecha,
  m.movement_type,
  m.quantity,
  m.cost_per_unit,
  m.reference_type,
  w.name                                     as bodega,
  left(coalesce(m.notes, ''), 60)            as nota
from public.inventory_movements m
left join public.warehouses w on w.id = m.warehouse_id
where m.item_id = '5fd1d147-6508-449e-a9c9-83c79c6a98bb'
order by m.created_at desc
limit 40;


-- ---------------------------------------------------------------------------
-- 4. ¿ALGÚN PLATO LA DESCUENTA? — recetas y productos ligados.
--
--    Con el menú vendiendo PECHUGA A LA PLANCHA, A LA CREMA, RELLENA y A LA
--    PARMESANA, si esto vuelve vacío está dicho todo: se vendieron cientos de
--    pechugas y ninguna bajó del inventario.
-- ---------------------------------------------------------------------------
select
  mi.name                                    as plato,
  ri.quantity                                as lleva,
  ri.unit,
  round(coalesce(mi.price, 0), 2)            as precio
from public.recipe_ingredients ri
join public.recipes r  on r.id = ri.recipe_id
join public.menu_items mi on mi.id = r.menu_item_id
where ri.inventory_item_id = '5fd1d147-6508-449e-a9c9-83c79c6a98bb'
union all
select mi.name, 1, 'directo', round(coalesce(mi.price, 0), 2)
from public.menu_items mi
where mi.inventory_item_id = '5fd1d147-6508-449e-a9c9-83c79c6a98bb';
