-- =============================================================================
-- LA PENDA EXPRESS — deshacer el doble conteo de las croquetas y buscar los 4
-- que no cargaron
-- business_id = 35c5076a-bd85-4a1b-8d1c-ce719c4f9ae6
--
-- QUÉ PASÓ: el insert de la cocina B sumaba a lo que ya hubiera en la línea,
-- porque la hoja 2 es otra área. Pero CROQUETAS DE POLLO ya tenía sus 17
-- cargados, así que la suma lo dejó en 34. Nadie contó 34.
--
-- Y de los siete de la hoja 2 solo entraron tres: el `join lateral` que
-- resuelve el insumo es INTERNO, así que los que no encuentra desaparecen sin
-- avisar. CASABE, MANGU DE PLATANO, PAPAS FRITAS y VEGETALES SALTEADOS no
-- cargaron nada y el insert no dijo una palabra.
--
-- CORRER UNA SENTENCIA A LA VEZ, EN ORDEN.
-- =============================================================================

-- ---------------------------------------------------------------------------
-- 1. PRIMERO MIRAR — cómo quedaron las tres que sí se tocaron.
--
--    CROQUETAS tiene que decir 34 (el error). QUIPE tiene que decir 52 (bien).
--    COCOA tiene que decir 2 (intacta, se sacó del insert a propósito).
-- ---------------------------------------------------------------------------
select
  i.name, i.unit, l.counted_quantity as contado, l.counter_notes,
  l.updated_at at time zone 'America/Santo_Domingo' as tocada
from public.physical_count_lines l
join public.physical_count_sessions s on s.id = l.session_id
join public.inventory_items i on i.id = l.item_id
where s.business_id = '35c5076a-bd85-4a1b-8d1c-ce719c4f9ae6'
  and s.code = 'PC-2026-000003'
  and upper(btrim(i.name)) in
      ('CROQUETAS DE POLLO', 'QUIPE DE POLLO', 'COCOA AMARGA')
order by i.name;


-- ---------------------------------------------------------------------------
-- 2. DESHACER LAS CROQUETAS — de 34 a 17.
--
--    El 17 que ya estaba ES el de la hoja 2. La cocina A no contó croquetas:
--    la hoja 1 no las trae. Así que el total correcto es 17, no 34.
--
--    La nota deja escrito que hubo una corrección, porque un número que sube
--    y baja sin explicación es lo que hace que un auditor desconfíe de todo
--    el conteo.
-- ---------------------------------------------------------------------------
update public.physical_count_lines l
   set counted_quantity = 17,
       counter_notes = 'Cocina B (hoja 2): 17. La cocina A no contó croquetas. '
                     || 'Corregido: una carga automática las había duplicado a 34.',
       updated_at = now()
  from public.physical_count_sessions s
 where l.session_id = s.id
   and s.business_id = '35c5076a-bd85-4a1b-8d1c-ce719c4f9ae6'
   and s.code = 'PC-2026-000003'
   and l.item_id = (
     select id from public.inventory_items
      where business_id = '35c5076a-bd85-4a1b-8d1c-ce719c4f9ae6'
        and upper(btrim(name)) = 'CROQUETAS DE POLLO'
        and coalesce(is_active, true)
      limit 1
   );
-- Debe decir UPDATE 1.


-- ---------------------------------------------------------------------------
-- 3. ¿POR QUÉ NO CARGARON LOS OTROS CUATRO? — buscarlos de verdad.
--
--    Búsqueda amplia por raíz del nombre. Si aparecen con otro nombre, se
--    cargan contra ese id; si no aparecen, hay que crearlos.
-- ---------------------------------------------------------------------------
select i.id, i.name, i.unit, i.sku, round(coalesce(i.cost,0),2) as costo,
       coalesce((select sum(st.quantity) from public.inventory_stock st
                  where st.item_id = i.id), 0) as existencia,
       coalesce(i.is_active, true) as activo,
       (select l.counted_quantity
          from public.physical_count_lines l
          join public.physical_count_sessions s on s.id = l.session_id
         where l.item_id = i.id and s.code = 'PC-2026-000003') as ya_cargado
from public.inventory_items i
where i.business_id = '35c5076a-bd85-4a1b-8d1c-ce719c4f9ae6'
  and (i.name ~* '\mcasabe'
    or i.name ~* '\mmang[uú]'
    or i.name ~* '\mpapas?\M.*frit'
    or i.name ~* 'frit.*\mpapas?\M'
    or i.name ~* '\mvegetales?\M'
    or i.name ~* 'saltead')
order by i.name;


-- ---------------------------------------------------------------------------
-- 4. LOS PRODUCTOS DEL MENÚ CON ESOS NOMBRES — por si el insumo no existe
--    pero el producto sí, y hay que crear el insumo o ligarlo.
-- ---------------------------------------------------------------------------
select mi.id, mi.name, mi.sku, round(coalesce(mi.price,0),2) as precio,
       mi.inventory_item_id,
       (select ii.name from public.inventory_items ii
         where ii.id = mi.inventory_item_id)   as insumo_ligado,
       coalesce(mi.is_inventory_tracked, false) as descuenta_inventario
from public.menu_items mi
where mi.business_id = '35c5076a-bd85-4a1b-8d1c-ce719c4f9ae6'
  and (mi.name ~* '\mcasabe'
    or mi.name ~* '\mmang[uú]'
    or mi.name ~* '\mpapas?\M.*frit'
    or mi.name ~* '\mvegetales?\M'
    or mi.name ~* 'saltead')
order by mi.name;


-- ---------------------------------------------------------------------------
-- 5. CARGAR LOS CUATRO — con los ids reales del paso 3.
--
--    ⚠️ Reemplazá cada <id> con el que salga arriba. Esta versión NO SUMA:
--    pone el número tal cual, porque ya sabemos que la cocina A no los contó
--    (la hoja 1 no los trae). Si alguno ya tiene cantidad, el `where` lo
--    protege — solo escribe sobre líneas en blanco.
--
--    Y si algún id no existe, el insert falla en vez de ignorarlo en silencio.
--    Eso es a propósito: prefiero un error a un renglón perdido.
-- ---------------------------------------------------------------------------
-- with cant(item_id, q, nom) as (values
--   ('<id CASABE>'::uuid,               43.0, 'CASABE'),
--   ('<id MANGU DE PLATANO>'::uuid,     41.0, 'MANGU DE PLATANO - GUARNICION'),
--   ('<id PAPAS FRITAS>'::uuid,         16.0, 'PAPAS FRITAS'),
--   ('<id VEGETALES SALTEADOS>'::uuid,  11.0, 'VEGETALES SALTEADOS')
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
-- 6. VERIFICAR — los siete de la cocina B.
--
--    Tienen que quedar así:
--      CASABE                          43
--      COCOA AMARGA                     2
--      CROQUETAS DE POLLO              17
--      MANGU DE PLATANO - GUARNICION   41
--      PAPAS FRITAS                    16
--      QUIPE DE POLLO                  52   (10 cocina A + 42 cocina B)
--      VEGETALES SALTEADOS             11
-- ---------------------------------------------------------------------------
select
  i.name, i.unit, round(coalesce(i.cost,0),2) as costo,
  l.counted_quantity as contado,
  round(l.counted_quantity * coalesce(i.cost,0), 2) as valor,
  l.counter_notes
from public.physical_count_lines l
join public.physical_count_sessions s on s.id = l.session_id
join public.inventory_items i on i.id = l.item_id
where s.business_id = '35c5076a-bd85-4a1b-8d1c-ce719c4f9ae6'
  and s.code = 'PC-2026-000003'
  and (i.name ~* '\mcasabe' or i.name ~* '\mmang[uú]'
    or i.name ~* '\mpapas?\M.*frit' or i.name ~* '\mvegetales?\M'
    or i.name ~* 'saltead' or i.name ~* '\mcroquetas?\M'
    or i.name ~* '\mquipe\M.*pollo' or i.name ~* 'cocoa')
order by i.name;
