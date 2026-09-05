-- =============================================================================
-- LA PENDA EXPRESS — ¿existen MANGÚ, PAPAS FRITAS y VEGETALES SALTEADOS?
-- business_id = 35c5076a-bd85-4a1b-8d1c-ce719c4f9ae6
--
-- ESTADO DE LA COCINA B (hoja 2 del Excel), 7 renglones:
--   ✅ CASABE               43   → «CASABE NATURAL», ya estaba cargado
--   ✅ QUIPE DE POLLO       52   → 10 cocina A + 42 cocina B
--   ✅ CROQUETAS DE POLLO   17   → corregido del doble conteo
--   ✅ COCOA AMARGA          2   → intacta
--   ❓ MANGU DE PLATANO     41
--   ❓ PAPAS FRITAS         16
--   ❓ VEGETALES SALTEADOS  11
--
-- La verificación anterior no los mostró, pero esa consulta parte de las
-- líneas del CONTEO — un insumo que no exista, o que se haya creado después
-- del congelado, no tiene línea y por eso no sale. Estas consultas miran el
-- CATÁLOGO COMPLETO, que es donde de verdad se sabe.
-- =============================================================================

-- ---------------------------------------------------------------------------
-- 1. EN EL CATÁLOGO DE INSUMOS — búsqueda ancha, incluidos los INACTIVOS.
--
--    Se incluyen los inactivos a propósito: si alguno fue desactivado por
--    error, aparece acá y se reactiva en vez de crear un duplicado.
-- ---------------------------------------------------------------------------
select
  i.id, i.name, i.unit, i.sku,
  round(coalesce(i.cost, 0), 2)              as costo,
  coalesce(i.is_active, true)                as activo,
  coalesce((select sum(st.quantity) from public.inventory_stock st
             where st.item_id = i.id), 0)    as existencia,
  i.created_at at time zone 'America/Santo_Domingo' as creado,
  (select l.counted_quantity
     from public.physical_count_lines l
     join public.physical_count_sessions s on s.id = l.session_id
    where l.item_id = i.id and s.code = 'PC-2026-000003') as en_el_conteo
from public.inventory_items i
where i.business_id = '35c5076a-bd85-4a1b-8d1c-ce719c4f9ae6'
  and (i.name ~* 'mang[uú]'          -- mangú, mangu, MANGU DE PLATANO
    or i.name ~* 'papa'              -- cualquier papa, no solo «papas fritas»
    or i.name ~* 'saltead'           -- salteado, salteados
    or i.name ~* 'vegetal')          -- vegetal, vegetales
order by i.name;


-- ---------------------------------------------------------------------------
-- 2. EN EL MENÚ — ¿existen como PRODUCTO y están ligados a algún insumo?
--
--    Si el producto existe y ya descuenta inventario, el conteo va contra el
--    insumo que tiene ligado (`insumo_ligado`), no contra uno nuevo.
-- ---------------------------------------------------------------------------
select
  mi.id, mi.name, mi.sku, mi.barcode,
  round(coalesce(mi.price, 0), 2)            as precio,
  coalesce(mi.is_inventory_tracked, false)   as descuenta_inventario,
  mi.inventory_item_id,
  (select ii.name from public.inventory_items ii
    where ii.id = mi.inventory_item_id)      as insumo_ligado,
  (select count(*) from public.recipes r where r.menu_item_id = mi.id) as tiene_receta
from public.menu_items mi
where mi.business_id = '35c5076a-bd85-4a1b-8d1c-ce719c4f9ae6'
  and (mi.name ~* 'mang[uú]' or mi.name ~* 'papa'
    or mi.name ~* 'saltead' or mi.name ~* 'vegetal')
order by mi.name;


-- ---------------------------------------------------------------------------
-- 3. SI DE VERDAD NO EXISTEN — crearlos con la unidad de la hoja 2.
--
--    ⚠️ NO CORRER hasta ver los pasos 1 y 2. Si el insumo existe con otro
--    nombre, crear uno nuevo parte el inventario en dos.
--
--    Las unidades salen del papel, que es como la cocina los cuenta:
--      MANGU DE PLATANO - GUARNICION  ·  bolsas
--      PAPAS FRITAS                   ·  unidad
--      VEGETALES SALTEADOS            ·  bolsas
--
--    Nacen con costo 0 y con el costo del PRODUCTO como referencia en la
--    descripción — la hoja 2 los trae: mangú 9.23, papas 40.17, vegetales 12.
--    Ese costo es del producto del menú, no del insumo, así que sirve de
--    punto de partida pero hay que confirmarlo con las compras de agosto.
-- ---------------------------------------------------------------------------
-- insert into public.inventory_items
--   (business_id, name, unit, cost, min_stock, is_active)
-- select '35c5076a-bd85-4a1b-8d1c-ce719c4f9ae6', v.nom, v.uni, 0, 0, true
-- from (values
--   ('MANGU DE PLATANO - GUARNICION', 'bolsa'),
--   ('PAPAS FRITAS',                  'unidad'),
--   ('VEGETALES SALTEADOS',           'bolsa')
-- ) as v(nom, uni)
-- where not exists (
--   select 1 from public.inventory_items x
--    where x.business_id = '35c5076a-bd85-4a1b-8d1c-ce719c4f9ae6'
--      and upper(btrim(x.name)) = upper(btrim(v.nom))
-- );


-- ---------------------------------------------------------------------------
-- 4. CARGARLOS AL CONTEO — con los ids que salgan del paso 1 (o del 3).
--
--    Sin sumar: la cocina A no los contó (la hoja 1 no los trae), así que el
--    número de la hoja 2 es el total. El `where` del on-conflict protege
--    cualquier línea que ya tenga cantidad — como pasó con las croquetas.
-- ---------------------------------------------------------------------------
-- with cant(item_id, q) as (values
--   ('<id MANGU>'::uuid,      41.0),
--   ('<id PAPAS FRITAS>'::uuid, 16.0),
--   ('<id VEGETALES>'::uuid,   11.0)
-- )
-- insert into public.physical_count_lines
--   (session_id, item_id, snapshot_quantity, counted_quantity, counter_notes)
-- select
--   s.id, c.item_id,
--   coalesce((select st.quantity from public.inventory_stock st
--              where st.item_id = c.item_id
--                and st.warehouse_id = s.warehouse_id), 0),
--   c.q,
--   'Cocina B (hoja 2 del Excel). La cocina A no lo contó.'
-- from public.physical_count_sessions s
-- cross join cant c
-- where s.business_id = '35c5076a-bd85-4a1b-8d1c-ce719c4f9ae6'
--   and s.code = 'PC-2026-000003'
-- on conflict (session_id, item_id) do update
--   set counted_quantity = excluded.counted_quantity,
--       counter_notes    = excluded.counter_notes,
--       updated_at       = now()
--   where physical_count_lines.counted_quantity is null;


-- ---------------------------------------------------------------------------
-- 5. LOS OTROS CASABES — quedaron sin contar y son plata.
--
--    La hoja 2 dice «CASABE» a secas y alguien lo asignó a CASABE NATURAL.
--    Pero el catálogo tiene tres casabes, y los otros dos están en blanco:
--      CASABE RELLENO DE GUAYABA  RD$85
--      CASABE TOSTADO PENDA       RD$100
--
--    PREGUNTA A LA COCINA: esos 43 paquetes ¿son todos del natural, o había
--    de los otros dos y se contaron juntos?
-- ---------------------------------------------------------------------------
select
  i.id, i.name, i.unit, round(coalesce(i.cost,0),2) as costo,
  coalesce((select sum(st.quantity) from public.inventory_stock st
             where st.item_id = i.id), 0)    as existencia,
  (select l.counted_quantity
     from public.physical_count_lines l
     join public.physical_count_sessions s on s.id = l.session_id
    where l.item_id = i.id and s.code = 'PC-2026-000003') as en_el_conteo
from public.inventory_items i
where i.business_id = '35c5076a-bd85-4a1b-8d1c-ce719c4f9ae6'
  and coalesce(i.is_active, true)
  and i.name ~* 'casabe'
order by i.name;
