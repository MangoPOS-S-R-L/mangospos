-- =============================================================================
-- LA PENDA EXPRESS — resolver el limón sin inventar el número
-- business_id = 35c5076a-bd85-4a1b-8d1c-ce719c4f9ae6
-- item_id     = 3f361492-a768-408f-bd72-0197010e7ee1
--
-- EL PROBLEMA: el papel contó 25 LIBRAS. El sistema lleva 2,390 UNIDADES a
-- RD$9.50 cada una (RD$22,705). Para cargar el conteo hay que saber si esos
-- RD$9.50 son por limón o por libra — y de eso dependen RD$21,000.
--
-- En vez de suponer, estas consultas buscan la respuesta en los datos que el
-- propio negocio ya generó: cómo se compró, cómo se movió, y qué recetas lo
-- usan. Si una compra dice «1,000 unidades a RD$9.50», está contestado.
--
-- CORRER UNA SENTENCIA A LA VEZ.
-- =============================================================================

-- ---------------------------------------------------------------------------
-- 1. LAS COMPRAS — la prueba más fuerte.
--
--    Si aparece una orden con cantidades en cientos o miles, la unidad es el
--    LIMÓN. Si aparecen cantidades de 20 o 50, es la LIBRA. Y `purchase_unit`
--    puede decirlo directo si quien la cargó lo llenó.
-- ---------------------------------------------------------------------------
select
  po.order_number,
  coalesce(po.received_date, po.created_at::date)  as fecha,
  po.status,
  s.name                                           as proveedor,
  poi.purchase_unit                                as se_compro_en,
  poi.pack_size                                    as contenido,
  poi.quantity_ordered                             as cantidad,
  round(poi.unit_cost, 2)                          as costo_unitario,
  round(poi.total, 2)                              as total_linea
from public.purchase_order_items poi
join public.purchase_orders po on po.id = poi.purchase_order_id
left join public.suppliers s on s.id = po.supplier_id
where po.business_id = '35c5076a-bd85-4a1b-8d1c-ce719c4f9ae6'
  and poi.inventory_item_id = '3f361492-a768-408f-bd72-0197010e7ee1'
order by coalesce(po.received_date, po.created_at::date) desc;


-- ---------------------------------------------------------------------------
-- 2. LOS MOVIMIENTOS — de dónde salieron las 2,390.
--
--    Una entrada de 1,000 de golpe es una compra de limones sueltos. Entradas
--    de 40 o 50 son sacos o libras. Y las salidas dicen a qué ritmo se
--    consume: un bar que hace mojitos gasta limones por unidad todos los días.
-- ---------------------------------------------------------------------------
select
  m.created_at at time zone 'America/Santo_Domingo'  as fecha,
  m.movement_type,
  m.quantity,
  round(m.cost_per_unit, 2)                          as costo,
  m.reference_type,
  w.name                                             as bodega,
  left(coalesce(m.notes, ''), 50)                    as nota
from public.inventory_movements m
left join public.warehouses w on w.id = m.warehouse_id
where m.item_id = '3f361492-a768-408f-bd72-0197010e7ee1'
order by m.created_at desc
limit 40;


-- ---------------------------------------------------------------------------
-- 3. LAS RECETAS — cómo lo pide la cocina.
--
--    Si un mojito lleva «2 limones», la unidad es la pieza. Si lleva «0.25»,
--    es una libra. Es la lectura más directa de todas.
-- ---------------------------------------------------------------------------
select
  mi.name                                    as plato,
  ri.quantity                                as lleva,
  ri.unit                                    as unidad_receta,
  round(coalesce(mi.price, 0), 2)            as precio
from public.recipe_ingredients ri
join public.recipes r     on r.id = ri.recipe_id
join public.menu_items mi on mi.id = r.menu_item_id
where ri.inventory_item_id = '3f361492-a768-408f-bd72-0197010e7ee1'
union all
select mi.name, 1, 'directo', round(coalesce(mi.price, 0), 2)
from public.menu_items mi
where mi.inventory_item_id = '3f361492-a768-408f-bd72-0197010e7ee1';


-- ---------------------------------------------------------------------------
-- 4. LOS OTROS LIMONES DEL CATÁLOGO — por si hay uno hermano ya resuelto.
-- ---------------------------------------------------------------------------
select i.id, i.name, i.unit, i.purchase_unit, i.pack_size,
       round(coalesce(i.cost,0),2)                as costo,
       coalesce((select sum(st.quantity) from public.inventory_stock st
                  where st.item_id = i.id), 0)    as existencia
from public.inventory_items i
where i.business_id = '35c5076a-bd85-4a1b-8d1c-ce719c4f9ae6'
  and coalesce(i.is_active, true)
  and i.name ~* 'lim[oó]n|lime|zumo'
order by i.name;


-- ---------------------------------------------------------------------------
-- 5. CARGAR EL CONTEO — cuando ya sepas el factor.
--
--    CASO A · los RD$9.50 son POR LIMÓN (lo más probable).
--       Hay que convertir: 25 libras x <limones por libra>.
--       En República Dominicana una libra de limón criollo son unos 8 a 12;
--       de limón persa, 4 a 6. Ese rango lo tiene que cerrar la cocina, pero
--       la diferencia entre 4 y 12 son solo RD$1,900 — nada al lado de los
--       RD$21,000 que separan las dos lecturas. Si hay que elegir, 6 es un
--       término medio defendible.
--
--       DESCOMENTAR y poner el número:
--
-- insert into public.physical_count_lines
--   (session_id, item_id, snapshot_quantity, counted_quantity, counter_notes)
-- select s.id, '3f361492-a768-408f-bd72-0197010e7ee1',
--        coalesce((select st.quantity from public.inventory_stock st
--                   where st.item_id = '3f361492-a768-408f-bd72-0197010e7ee1'
--                     and st.warehouse_id = s.warehouse_id), 0),
--        25 * 6,       -- <-- limones por libra
--        'Hoja 1 cocina A: 25 libras x 6 limones por libra = 150 limones. '
--        'Factor confirmado con la cocina el <fecha>.'
--   from public.physical_count_sessions s
--  where s.business_id = '35c5076a-bd85-4a1b-8d1c-ce719c4f9ae6'
--    and s.code = 'PC-2026-000003'
-- on conflict (session_id, item_id) do update
--   set counted_quantity = excluded.counted_quantity,
--       counter_notes    = excluded.counter_notes, updated_at = now()
--   where physical_count_lines.counted_quantity is null;
--
--
--    CASO B · los RD$9.50 son POR LIBRA y la unidad del sistema está mal.
--       Entonces hay 2,390 LIBRAS de limón declaradas — más de una tonelada,
--       que para un restaurante no tiene sentido. Si de verdad fuera así,
--       el problema no es el conteo sino que alguien cargó unidades como si
--       fueran libras, y eso es una corrección aparte:
--
-- update public.inventory_items set unit = 'lb'
--  where id = '3f361492-a768-408f-bd72-0197010e7ee1';
-- -- ...y el conteo entra con 25 tal cual.


-- ---------------------------------------------------------------------------
-- 6. VERIFICAR.
-- ---------------------------------------------------------------------------
select i.name, i.unit, round(coalesce(i.cost,0),2) as costo,
       l.snapshot_quantity as segun_sistema,
       l.counted_quantity  as contado,
       round((l.counted_quantity - l.snapshot_quantity) * coalesce(i.cost,0), 2)
                           as ajuste_rd,
       l.counter_notes
from public.inventory_items i
join public.physical_count_lines l on l.item_id = i.id
join public.physical_count_sessions s on s.id = l.session_id
where i.id = '3f361492-a768-408f-bd72-0197010e7ee1'
  and s.code = 'PC-2026-000003';
