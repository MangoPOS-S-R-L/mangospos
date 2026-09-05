-- =============================================================================
-- LA PENDA EXPRESS — costear los 10 insumos que quedaron en cero
-- business_id = 35c5076a-bd85-4a1b-8d1c-ce719c4f9ae6
--
-- Los 13 pendientes ya están cargados con su unidad correcta, pero DIEZ tienen
-- costo 0: suman unidades y no suman valor. En el informe del auditor caen en
-- «contados sin costo» y la valuación queda corta.
--
-- El Excel no los costea — se revisaron las tres hojas y ninguna trae precio
-- para estos. Así que el costo tiene que salir de tres lugares, en este orden
-- de confianza:
--
--   1. una COMPRA real del sistema        ← lo mejor, es plata que se pagó
--   2. un insumo HERMANO ya costeado      ← estimación defendible
--   3. la cocina o compras                ← último recurso
--
-- CORRER UNA SENTENCIA A LA VEZ.
-- =============================================================================

-- ---------------------------------------------------------------------------
-- 1. ¿ALGUNA VEZ SE COMPRARON? — historial de compras de los diez.
--
--    Si alguno aparece acá, ese es su costo y no hay que estimar nada.
--    Nacieron el 2 de septiembre, así que lo más probable es que no — pero
--    puede que el insumo sea nuevo y el PRODUCTO ya se compraba con otro
--    nombre, y entonces la consulta 3 lo encuentra.
-- ---------------------------------------------------------------------------
select
  i.name                                     as insumo,
  po.received_date,
  po.status,
  poi.quantity_ordered,
  poi.quantity_received,
  round(poi.unit_cost, 2)                    as costo_unitario,
  s.name                                     as proveedor
from public.purchase_order_items poi
join public.purchase_orders po on po.id = poi.purchase_order_id
join public.inventory_items i  on i.id = poi.inventory_item_id
left join public.suppliers s on s.id = po.supplier_id
where po.business_id = '35c5076a-bd85-4a1b-8d1c-ce719c4f9ae6'
  and poi.inventory_item_id in (
    '0970382d-2832-499c-9368-c23a1ab3fa84',  -- Aceite especial lata 30 libras
    '4073534c-f9bf-4d86-ab65-8077b0e246bb',  -- Cativía de queso
    '4b5aaf6e-7efe-4b6f-bc7b-3ff06e4ae3ac',  -- Chicharrón 10 oz
    '44a5e30a-3df1-4596-8e5c-723f8d607fdc',  -- Pasta Linguine
    'cf27f185-e99d-4502-8578-906e453eb004',  -- Pasta Penne
    '6fcd25a7-f89d-4e32-b3c2-72139c65b15d',  -- Pepperoni Pedrollo
    '4775fcb3-8759-47b0-81aa-9819351de75d',  -- Picante Red Hot
    '61b0c503-5ad6-428a-912e-f3e242d8c87a',  -- Pollo mechado 4 oz
    '485d54f4-8499-4de5-a683-0c7f9e1ff1bb',  -- Salami Genoa
    '914856c3-dfb0-42f2-a984-01a36498a1a3'   -- Salmón penca
  )
order by i.name, po.received_date desc nulls last;


-- ---------------------------------------------------------------------------
-- 2. LOS HERMANOS COSTEADOS — insumos parecidos que SÍ tienen precio.
--
--    Para cada uno de los diez, qué más hay en el catálogo con un nombre
--    cercano y un costo real. De ahí sale una estimación defendible: no es
--    inventar un número, es usar lo que el mismo negocio ya paga por algo
--    equivalente.
--
--    Ejemplos que ya se ven a simple vista:
--      Salmón penca      ← FILETE DE SALMON        RD$489
--      Salami Genoa      ← SALAMI SUPER ESPECIAL   RD$432 la pieza de 3.47 lb
--                          = RD$124.50 la libra
--      Pollo mechado 4oz ← FILETE DE PECHUGA       RD$140/lb → 4 oz = RD$35
-- ---------------------------------------------------------------------------
with faltan(id, nom, raiz) as (values
  ('0970382d-2832-499c-9368-c23a1ab3fa84'::uuid, 'Aceite especial lata 30 libras', 'aceite'),
  ('4073534c-f9bf-4d86-ab65-8077b0e246bb'::uuid, 'Cativía de queso',               'cativ'),
  ('4b5aaf6e-7efe-4b6f-bc7b-3ff06e4ae3ac'::uuid, 'Chicharrón 10 oz',               'chicharr?[oó]n'),
  ('44a5e30a-3df1-4596-8e5c-723f8d607fdc'::uuid, 'Pasta Linguine',                 'linguin|pasta'),
  ('cf27f185-e99d-4502-8578-906e453eb004'::uuid, 'Pasta Penne',                    'penne'),
  ('6fcd25a7-f89d-4e32-b3c2-72139c65b15d'::uuid, 'Pepperoni Pedrollo',             'pep+eroni'),
  ('4775fcb3-8759-47b0-81aa-9819351de75d'::uuid, 'Picante Red Hot',                'red *hot|picante'),
  ('61b0c503-5ad6-428a-912e-f3e242d8c87a'::uuid, 'Pollo mechado 4 oz',             'pollo|pechuga'),
  ('485d54f4-8499-4de5-a683-0c7f9e1ff1bb'::uuid, 'Salami Genoa',                   'salami'),
  ('914856c3-dfb0-42f2-a984-01a36498a1a3'::uuid, 'Salmón penca',                   'salm[oó]n')
)
select
  f.nom                                      as sin_costo,
  i.name                                     as hermano_costeado,
  i.unit                                     as unidad_hermano,
  round(i.cost, 2)                           as costo_hermano,
  coalesce((select sum(st.quantity) from public.inventory_stock st
             where st.item_id = i.id), 0)    as existencia_hermano
from faltan f
join public.inventory_items i
  on i.business_id = '35c5076a-bd85-4a1b-8d1c-ce719c4f9ae6'
 and coalesce(i.is_active, true)
 and i.name ~* f.raiz
 and coalesce(i.cost, 0) > 0
 and i.id <> f.id
order by f.nom, i.cost desc;


-- ---------------------------------------------------------------------------
-- 3. ¿HAY UN MOVIMIENTO CON COSTO? — a veces el costo entró por un ajuste o
--    una recepción sin orden de compra formal.
-- ---------------------------------------------------------------------------
select i.name, m.movement_type, m.quantity,
       round(m.cost_per_unit, 2)             as costo_del_movimiento,
       m.created_at at time zone 'America/Santo_Domingo' as fecha,
       m.reference_type
from public.inventory_movements m
join public.inventory_items i on i.id = m.item_id
where m.item_id in (
    '0970382d-2832-499c-9368-c23a1ab3fa84','4073534c-f9bf-4d86-ab65-8077b0e246bb',
    '4b5aaf6e-7efe-4b6f-bc7b-3ff06e4ae3ac','44a5e30a-3df1-4596-8e5c-723f8d607fdc',
    'cf27f185-e99d-4502-8578-906e453eb004','6fcd25a7-f89d-4e32-b3c2-72139c65b15d',
    '4775fcb3-8759-47b0-81aa-9819351de75d','61b0c503-5ad6-428a-912e-f3e242d8c87a',
    '485d54f4-8499-4de5-a683-0c7f9e1ff1bb','914856c3-dfb0-42f2-a984-01a36498a1a3')
  and coalesce(m.cost_per_unit, 0) > 0
order by i.name, m.created_at desc;


-- ---------------------------------------------------------------------------
-- 4. PONER LOS COSTOS — plantilla, NO correr sin los números confirmados.
--
--    Reemplazá cada <…> con el costo real. Dejá en la nota de dónde salió:
--    si un auditor pregunta por qué el chicharrón vale lo que vale, la
--    respuesta tiene que estar escrita, no en la memoria de alguien.
--
--    ⚠️ El costo va en la UNIDAD BASE del insumo. Para «Pollo mechado 4 oz»
--    cuya unidad es `bolsa`, el costo es por BOLSA — no por libra. Si la
--    pechuga cuesta RD$140 la libra, la bolsa de 4 oz sale en RD$35
--    (140 × 4/16), sin contar la merma del porcionado.
--
--    ⚠️ Esto cambia el costo MAESTRO. Según la política del negocio el costo
--    se mueve AL RECIBIR una compra; ponerlo a mano acá es una excepción
--    justificada porque el insumo nunca se ha comprado por el sistema.
-- ---------------------------------------------------------------------------
-- update public.inventory_items set cost = <costo> where id = '<id>';
--
--   Aceite especial lata 30 libras  ·  lata     ·  contado 1     ·  cost = <?>
--   Cativía de queso                ·  unidad   ·  contado 150   ·  cost = <?>
--   Chicharrón 10 oz                ·  bolsa    ·  contado 66    ·  cost = <?>
--   Pasta Linguine                  ·  bolsa    ·  contado 15    ·  cost = <?>
--   Pasta Penne                     ·  bolsa    ·  contado 17    ·  cost = <?>
--   Pepperoni Pedrollo              ·  lb       ·  contado 3.3   ·  cost = <?>
--   Picante Red Hot                 ·  unidad   ·  contado 1     ·  cost = <?>
--   Pollo mechado 4 oz              ·  bolsa    ·  contado 126   ·  cost = <?>
--   Salami Genoa                    ·  lb       ·  contado 9     ·  cost = <?>
--   Salmón penca                    ·  lb       ·  contado 2     ·  cost = <?>


-- ---------------------------------------------------------------------------
-- 5. VERIFICAR — cuánto valor entra al conteo con los costos puestos.
-- ---------------------------------------------------------------------------
select
  i.name, i.unit, round(coalesce(i.cost,0),2) as costo,
  l.counted_quantity as contado,
  round(l.counted_quantity * coalesce(i.cost,0), 2) as valor,
  case when coalesce(i.cost,0) = 0 then '⚠️ sigue sin costo' else 'ok' end as nota
from public.physical_count_lines l
join public.physical_count_sessions s on s.id = l.session_id
join public.inventory_items i on i.id = l.item_id
where s.code = 'PC-2026-000003'
  and s.business_id = '35c5076a-bd85-4a1b-8d1c-ce719c4f9ae6'
  and i.id in (
    '0970382d-2832-499c-9368-c23a1ab3fa84','4073534c-f9bf-4d86-ab65-8077b0e246bb',
    '4b5aaf6e-7efe-4b6f-bc7b-3ff06e4ae3ac','44a5e30a-3df1-4596-8e5c-723f8d607fdc',
    'cf27f185-e99d-4502-8578-906e453eb004','6fcd25a7-f89d-4e32-b3c2-72139c65b15d',
    '4775fcb3-8759-47b0-81aa-9819351de75d','61b0c503-5ad6-428a-912e-f3e242d8c87a',
    '485d54f4-8499-4de5-a683-0c7f9e1ff1bb','914856c3-dfb0-42f2-a984-01a36498a1a3')
order by nota desc, i.name;
