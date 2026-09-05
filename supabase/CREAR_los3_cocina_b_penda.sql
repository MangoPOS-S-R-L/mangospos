-- =============================================================================
-- LA PENDA EXPRESS — crear los 3 de la cocina B y cargarles su conteo
-- business_id = 35c5076a-bd85-4a1b-8d1c-ce719c4f9ae6
--
--   MANGU DE PLATANO - GUARNICION   41  bolsas
--   PAPAS FRITAS                    16  unidad
--   VEGETALES SALTEADOS             11  bolsas
--
-- ── LA UNIDAD ES LA DECISIÓN, Y VA DESDE EL NACIMIENTO ────────────────────
-- Cada uno nace en la unidad con que la COCINA lo cuenta, no en «unidad» por
-- defecto. Es la lección de esta semana: 23 de los 35 renglones del conteo
-- tenían la unidad discordante y hubo que arreglarlos uno por uno.
--
-- ── OJO: PAPAS FRITAS TIENE SU MATERIA PRIMA APARTE ──────────────────────
-- El sistema ya lleva `MCCAIN FLAVORLAST PAPAS`: 300 lb a RD$88 la libra.
-- Eso es la papa CRUDA congelada. Las 16 «unidad» que contó la cocina B son
-- porciones YA FRITAS, listas para servir. Son dos cosas distintas y las dos
-- son inventario, igual que la pechuga cruda y el filete porcionado.
--
-- Crear PAPAS FRITAS como insumo aparte es correcto. Lo que NO hay que hacer
-- es cargarle las 16 a la McCain: serían 16 libras de papa congelada y no es
-- lo que nadie contó.
--
-- ── SOBRE EL COSTO ────────────────────────────────────────────────────────
-- Nacen en 0 porque el costo se va a sacar de las compras. PERO OJO: estos
-- tres se PREPARAN EN CASA. Ningún proveedor vende «vegetales salteados», así
-- que NO van a aparecer en las compras de agosto por más que se busque.
--
-- Su costo tiene que salir de otro lado, y el sistema ya lo tiene: el producto
-- del menú trae su `cost` calculado. El paso 4 lo copia — está separado y
-- comentado para que sea una decisión, no un efecto secundario.
--
-- ── DISEÑO DEFENSIVO (por lo que pasó con las croquetas) ──────────────────
-- · el insert de insumos es idempotente por nombre
-- · la carga del conteo NO SUMA: escribe solo sobre líneas en blanco
-- · el paso 5 cuenta cuántos aterrizaron y AVISA si falta alguno, en vez de
--   reportar éxito con renglones perdidos en silencio
--
-- CORRER UNA SENTENCIA A LA VEZ.
-- =============================================================================

-- ---------------------------------------------------------------------------
-- 1. CREAR LOS TRES.
--
--    VERIFICADO 2026-09-03: ninguno de los tres existe como insumo. La
--    búsqueda ancha (`papa`, `mang[uú]`, `vegetal`, `saltead`) solo trajo
--    BRUSCHETTE MEDITERRANEA VEGETALES, MCCAIN FLAVORLAST PAPAS y PAPAS —
--    ninguno es el preparado que contó la cocina B.
--
--    Los tres SÍ existen como PRODUCTO del menú, los tres con
--    `is_inventory_tracked = false`, sin insumo ligado y sin receta:
--      MANGU DE PLATANO - GUARNICION   sku 00000580   RD$150
--      PAPAS FRITAS                    sku 1073       RD$135
--      VEGETALES SALTEADOS             sku 00000951   RD$225
--
--    Igual queda idempotente por nombre, por si se corre dos veces.
-- ---------------------------------------------------------------------------
insert into public.inventory_items
  (business_id, name, unit, cost, min_stock, is_active)
select '35c5076a-bd85-4a1b-8d1c-ce719c4f9ae6', v.nom, v.uni, 0, 0, true
from (values
  ('MANGU DE PLATANO - GUARNICION', 'bolsa'),
  ('PAPAS FRITAS',                  'unidad'),
  ('VEGETALES SALTEADOS',           'bolsa')
) as v(nom, uni)
where not exists (
  select 1 from public.inventory_items x
   where x.business_id = '35c5076a-bd85-4a1b-8d1c-ce719c4f9ae6'
     and upper(btrim(x.name)) = upper(btrim(v.nom))
);
-- Debe decir INSERT 0 3. Si dice menos, alguno ya existía — mirá el paso 5.


-- ---------------------------------------------------------------------------
-- 2. DARLES FILA DE STOCK EN LA BODEGA DE COCINA — en cero.
--
--    Sin fila en `inventory_stock` no aparecen en la pantalla de esa bodega.
--    Nacen en 0 y el conteo les pone su cantidad, así el movimiento queda
--    registrado como lo que es: una entrada por conteo físico.
-- ---------------------------------------------------------------------------
insert into public.inventory_stock (warehouse_id, item_id, quantity)
select w.id, i.id, 0
from public.warehouses w
join public.inventory_items i
  on i.business_id = w.business_id
 and upper(btrim(i.name)) in
     ('MANGU DE PLATANO - GUARNICION', 'PAPAS FRITAS', 'VEGETALES SALTEADOS')
where w.business_id = '35c5076a-bd85-4a1b-8d1c-ce719c4f9ae6'
  and w.name ilike '%cocina%'
on conflict (warehouse_id, item_id) do nothing;


-- ---------------------------------------------------------------------------
-- 3. CARGAR EL CONTEO DE LA COCINA B.
--
--    NO SUMA. La cocina A no los contó — la hoja 1 no los trae — así que el
--    número de la hoja 2 es el total. Y el `where` del on-conflict protege
--    cualquier línea que ya tenga cantidad, que es exactamente lo que faltó
--    cuando las croquetas terminaron en 34.
-- ---------------------------------------------------------------------------
with cant(nom, q) as (values
  ('MANGU DE PLATANO - GUARNICION', 41.0),
  ('PAPAS FRITAS',                  16.0),
  ('VEGETALES SALTEADOS',           11.0)
)
insert into public.physical_count_lines
  (session_id, item_id, snapshot_quantity, counted_quantity, counter_notes)
select
  s.id,
  i.id,
  coalesce((select st.quantity from public.inventory_stock st
             where st.item_id = i.id
               and st.warehouse_id = s.warehouse_id), 0),
  c.q,
  'Cocina B (hoja 2 del Excel): ' || c.q::text || '. La cocina A no lo contó.'
from public.physical_count_sessions s
join cant c on true
join public.inventory_items i
  on i.business_id = s.business_id
 and upper(btrim(i.name)) = upper(btrim(c.nom))
 and coalesce(i.is_active, true)
where s.business_id = '35c5076a-bd85-4a1b-8d1c-ce719c4f9ae6'
  and s.code = 'PC-2026-000003'
on conflict (session_id, item_id) do update
  set counted_quantity = excluded.counted_quantity,
      counter_notes    = excluded.counter_notes,
      updated_at       = now()
  where physical_count_lines.counted_quantity is null;
-- Debe decir INSERT 0 3.


-- ---------------------------------------------------------------------------
-- 4. EL COSTO — copiarlo del producto del menú.  ⚠️ DECISIÓN APARTE.
--
--    Estos tres NO se compran, se preparan. No van a salir en las compras de
--    agosto. Pero el producto del menú ya trae su `cost` calculado, que para
--    un preparado ES el costo de sus ingredientes.
--
--    Primero MIRAR qué costo tiene cada producto:
-- ---------------------------------------------------------------------------
select
  mi.name                                    as producto_menu,
  round(coalesce(mi.price, 0), 2)            as precio_venta,
  round(coalesce(mi.cost, 0), 2)             as costo_producto,
  ii.name                                    as insumo,
  round(coalesce(ii.cost, 0), 2)             as costo_insumo_hoy,
  case when coalesce(mi.cost, 0) = 0
       then '⚠️ el producto tampoco tiene costo'
       else 'se puede copiar' end            as se_puede
from public.menu_items mi
left join public.inventory_items ii
  on ii.business_id = mi.business_id
 and upper(btrim(ii.name)) = upper(btrim(mi.name))
 and coalesce(ii.is_active, true)
where mi.business_id = '35c5076a-bd85-4a1b-8d1c-ce719c4f9ae6'
  and upper(btrim(mi.name)) in
      ('MANGU DE PLATANO - GUARNICION', 'PAPAS FRITAS', 'VEGETALES SALTEADOS')
order by mi.name;

-- Y si el costo del producto sirve, copiarlo (DESCOMENTAR a propósito):
--
-- update public.inventory_items ii
--    set cost = mi.cost
--   from public.menu_items mi
--  where mi.business_id = ii.business_id
--    and upper(btrim(mi.name)) = upper(btrim(ii.name))
--    and ii.business_id = '35c5076a-bd85-4a1b-8d1c-ce719c4f9ae6'
--    and upper(btrim(ii.name)) in
--        ('MANGU DE PLATANO - GUARNICION', 'PAPAS FRITAS', 'VEGETALES SALTEADOS')
--    and coalesce(ii.cost, 0) = 0
--    and coalesce(mi.cost, 0) > 0;


-- ---------------------------------------------------------------------------
-- 4b. LOS PRODUCTOS NO DESCUENTAN INVENTARIO — decisión aparte, NO urgente.
--
--     Los tres tienen `is_inventory_tracked = false`, así que vender un mangú
--     no baja nada. Crear el insumo NO los liga solo: son dos cosas distintas.
--
--     Ligarlos es lo correcto a futuro, pero NO se hace hoy: prender el
--     descuento en medio de un conteo abierto mete movimientos que nadie
--     esperaba. Después de cerrar, desde la app (Productos → Inventariable).
--
--     Esta consulta deja la lista para ese día.
-- ---------------------------------------------------------------------------
select mi.id, mi.name, mi.sku, round(coalesce(mi.price,0),2) as precio,
       round(coalesce(mi.cost,0),2) as costo_producto,
       coalesce(mi.is_inventory_tracked, false) as descuenta,
       ii.id as insumo_que_le_tocaria
from public.menu_items mi
left join public.inventory_items ii
  on ii.business_id = mi.business_id
 and upper(btrim(ii.name)) = upper(btrim(mi.name))
 and coalesce(ii.is_active, true)
where mi.business_id = '35c5076a-bd85-4a1b-8d1c-ce719c4f9ae6'
  and upper(btrim(mi.name)) in
      ('MANGU DE PLATANO - GUARNICION', 'PAPAS FRITAS', 'VEGETALES SALTEADOS')
order by mi.name;


-- ---------------------------------------------------------------------------
-- 4c. EL CASABE EN NEGATIVO — hallazgo aparte, hay que contarlo.
--
--     `CASABE RELLENO DE GUAYABA` está en **-9** y NADIE lo contó. Un negativo
--     quiere decir que se vendió más de lo que entró, y si la sesión se cierra
--     con esa línea en blanco, el -9 se queda ahí.
--
--     `CASABE TOSTADO PENDA` tiene 6 y tampoco se contó.
--
--     La hoja 2 dice «CASABE» a secas y alguien le puso los 43 al natural.
--     PREGUNTA A LA COCINA: ¿esos 43 eran todos naturales, o había de los
--     otros dos?
-- ---------------------------------------------------------------------------
select i.id, i.name, round(coalesce(i.cost,0),2) as costo,
       coalesce((select sum(st.quantity) from public.inventory_stock st
                  where st.item_id = i.id), 0) as existencia,
       (select l.counted_quantity
          from public.physical_count_lines l
          join public.physical_count_sessions s on s.id = l.session_id
         where l.item_id = i.id and s.code = 'PC-2026-000003') as en_el_conteo
from public.inventory_items i
where i.business_id = '35c5076a-bd85-4a1b-8d1c-ce719c4f9ae6'
  and coalesce(i.is_active, true)
  and i.name ~* 'casabe'
order by i.name;


-- ---------------------------------------------------------------------------
-- 5. VERIFICAR — y AVISAR si falta alguno.
--
--    `aterrizaron` tiene que decir 3. Si dice menos, algo no entró y hay que
--    mirar el detalle de abajo antes de seguir. Un renglón perdido en
--    silencio es peor que un error a la cara.
-- ---------------------------------------------------------------------------
with esperados(nom, q) as (values
  ('MANGU DE PLATANO - GUARNICION', 41.0),
  ('PAPAS FRITAS',                  16.0),
  ('VEGETALES SALTEADOS',           11.0)
)
select
  count(*) filter (where l.counted_quantity = e.q)   as aterrizaron,
  count(*) filter (where i.id is null)               as insumo_no_existe,
  count(*) filter (where i.id is not null
                     and l.counted_quantity is null) as sin_cargar,
  count(*) filter (where l.counted_quantity is not null
                     and l.counted_quantity <> e.q)  as con_otro_numero
from esperados e
left join public.inventory_items i
  on i.business_id = '35c5076a-bd85-4a1b-8d1c-ce719c4f9ae6'
 and upper(btrim(i.name)) = upper(btrim(e.nom))
 and coalesce(i.is_active, true)
left join lateral (
  select l2.counted_quantity
    from public.physical_count_lines l2
    join public.physical_count_sessions s2 on s2.id = l2.session_id
   where l2.item_id = i.id and s2.code = 'PC-2026-000003'
   limit 1
) l on true;

-- (segunda sentencia: el detalle de los siete de la cocina B)
select
  i.name, i.unit, round(coalesce(i.cost,0),2) as costo,
  l.counted_quantity                          as contado,
  round(l.counted_quantity * coalesce(i.cost,0), 2) as valor,
  l.counter_notes
from public.physical_count_lines l
join public.physical_count_sessions s on s.id = l.session_id
join public.inventory_items i on i.id = l.item_id
where s.business_id = '35c5076a-bd85-4a1b-8d1c-ce719c4f9ae6'
  and s.code = 'PC-2026-000003'
  and upper(btrim(i.name)) in
      ('CASABE NATURAL', 'QUIPE DE POLLO', 'CROQUETAS DE POLLO',
       'COCOA AMARGA', 'MANGU DE PLATANO - GUARNICION', 'PAPAS FRITAS',
       'VEGETALES SALTEADOS')
order by i.name;
