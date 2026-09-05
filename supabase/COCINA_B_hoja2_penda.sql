-- =============================================================================
-- LA PENDA EXPRESS — la hoja 2 es un SEGUNDO conteo: la cocina B
-- business_id = 35c5076a-bd85-4a1b-8d1c-ce719c4f9ae6
--
-- La hoja «cocina 2» del Excel parecía un volcado del menú, pero tiene una
-- columna de cantidad llena en SIETE renglones. Es el conteo de la otra área
-- de cocina, y hay que sumarlo al de la hoja 1 — así lo confirmó el dueño
-- para el quipe de pollo, y aplica igual a los demás.
--
--   CASABE                          43 paquetes
--   QUIPE DE POLLO                  42 unidad     ← + 10 de la hoja 1 = 52
--   MANGU DE PLATANO - GUARNICION   41 bolsas
--   CROQUETAS DE POLLO              17 servicio
--   PAPAS FRITAS                    16 unidad
--   VEGETALES SALTEADOS             11 bolsas
--   COCOA AMARGA                     2 unidad
--
-- Son platos preparados que la cocina guarda hechos, así que existen como
-- PRODUCTO del menú y a la vez como INSUMO. Los SKU de arriba son los del
-- producto; el insumo puede tener otro. Por eso el paso 1 los busca por
-- nombre Y por código antes de cargar nada.
--
-- CORRER UNA SENTENCIA A LA VEZ.
-- =============================================================================

-- ---------------------------------------------------------------------------
-- 1. ENCONTRARLOS PRIMERO — ¿existen como insumo? ¿con qué unidad?
--
--    No cargar nada hasta ver esta salida. Si alguno no aparece, hay que
--    decidir si se crea o si el conteo va contra otro insumo.
-- ---------------------------------------------------------------------------
with papel(nom, cant, uni, sku_menu) as (values
  ('CASABE',                        43.0, 'paquetes', '1074'),
  ('QUIPE DE POLLO',                42.0, 'unidad',   '00000740'),
  ('MANGU DE PLATANO - GUARNICION', 41.0, 'bolsas',   '00000580'),
  ('CROQUETAS DE POLLO',            17.0, 'servicio', '1050'),
  ('PAPAS FRITAS',                  16.0, 'unidad',   '1073'),
  ('VEGETALES SALTEADOS',           11.0, 'bolsas',   '00000951'),
  ('COCOA AMARGA',                   2.0, 'unidad',   '7460193553296')
)
select
  p.nom                                      as dice_la_hoja2,
  p.cant                                     as conto_cocina_b,
  p.uni                                      as unidad_papel,
  i.name                                     as insumo_en_sistema,
  i.unit                                     as unidad_sistema,
  round(coalesce(i.cost,0), 2)               as costo,
  coalesce((select sum(st.quantity) from public.inventory_stock st
             where st.item_id = i.id), 0)    as existencia,
  (select l.counted_quantity
     from public.physical_count_lines l
     join public.physical_count_sessions s on s.id = l.session_id
    where l.item_id = i.id and s.code = 'PC-2026-000003') as ya_cargado_cocina,
  i.sku,
  case
    when i.id is null                then '❌ no existe como insumo'
    when coalesce(i.cost,0) = 0      then '⚠️ existe, sin costo'
    else                                  '✅'
  end                                        as estado,
  i.id
from papel p
left join lateral (
  select * from public.inventory_items ii
   where ii.business_id = '35c5076a-bd85-4a1b-8d1c-ce719c4f9ae6'
     and coalesce(ii.is_active, true)
     and (upper(btrim(ii.name)) = upper(btrim(p.nom)) or ii.sku = p.sku_menu)
   order by (upper(btrim(ii.name)) = upper(btrim(p.nom))) desc
   limit 1
) i on true
order by (i.id is null) desc, p.nom;


-- ---------------------------------------------------------------------------
-- 2. EL QUIPE DE POLLO — 10 + 42 = 52.
--
--    Hoy tiene 51 cargado, que no es ni 10 ni 42 ni la suma: alguien lo sumó
--    a mano y se le fue uno. Se deja la nota con el desglose para que la
--    diferencia se pueda explicar sin adivinar.
-- ---------------------------------------------------------------------------
update public.physical_count_lines l
   set counted_quantity = 52,
       counter_notes = 'Cocina A (hoja 1) 10 + Cocina B (hoja 2) 42 = 52. '
                     || 'Antes tenía 51, sumado a mano.',
       updated_at = now()
  from public.physical_count_sessions s
 where l.session_id = s.id
   and s.business_id = '35c5076a-bd85-4a1b-8d1c-ce719c4f9ae6'
   and s.code = 'PC-2026-000003'
   and l.item_id = 'd5b7e98b-cbd9-4e1f-9648-e14be92f805f';
-- Debe decir UPDATE 1.


-- ---------------------------------------------------------------------------
-- 3. VISTA PREVIA — qué pasaría con cada uno ANTES de tocar nada.
--
--    ⚠️ EL RIESGO: la cantidad se SUMA a la que ya esté en la línea, porque
--    la hoja 2 es otra área. Pero COCOA AMARGA ya tiene un «2» cargado, y ese
--    2 es exactamente lo que dice la hoja 2 — o sea que probablemente YA
--    entró. Sumarle otro 2 lo dejaría en 4 y nadie contó 4.
--
--    Por eso este paso solo MUESTRA. Mirá la columna `sospecha` y sacá del
--    paso 3b cualquiera que ya venga cargado con el mismo número.
-- ---------------------------------------------------------------------------
with papel(nom, cant, sku_menu) as (values
  ('CASABE',                        43.0, '1074'),
  ('MANGU DE PLATANO - GUARNICION', 41.0, '00000580'),
  ('CROQUETAS DE POLLO',            17.0, '1050'),
  ('PAPAS FRITAS',                  16.0, '1073'),
  ('VEGETALES SALTEADOS',           11.0, '00000951'),
  ('COCOA AMARGA',                   2.0, '7460193553296')
)
select
  p.nom                                      as hoja2,
  p.cant                                     as cocina_b,
  i.name                                     as insumo,
  l.counted_quantity                         as ya_cargado,
  coalesce(l.counted_quantity, 0) + p.cant   as quedaria_en,
  l.counter_notes                            as nota_actual,
  case
    when i.id is null                          then '❌ no existe — sacar de 3b'
    when l.counted_quantity = p.cant           then '⚠️ YA TIENE ESTE MISMO NÚMERO — sacar de 3b'
    when l.counted_quantity is null            then 'ok, entra limpio'
    else                                            'suma sobre ' || l.counted_quantity::text
  end                                        as sospecha
from papel p
left join lateral (
  select * from public.inventory_items ii
   where ii.business_id = '35c5076a-bd85-4a1b-8d1c-ce719c4f9ae6'
     and coalesce(ii.is_active, true)
     and (upper(btrim(ii.name)) = upper(btrim(p.nom)) or ii.sku = p.sku_menu)
   order by (upper(btrim(ii.name)) = upper(btrim(p.nom))) desc limit 1
) i on true
left join lateral (
  select l2.counted_quantity, l2.counter_notes
    from public.physical_count_lines l2
    join public.physical_count_sessions s2 on s2.id = l2.session_id
   where l2.item_id = i.id and s2.code = 'PC-2026-000003' limit 1
) l on true
order by p.nom;


-- ---------------------------------------------------------------------------
-- 3b. CARGAR — con la lista ya depurada según el paso 3.
--
--    Quitá de los VALUES cualquiera que el paso 3 haya marcado. NO correr dos
--    veces: suma de nuevo.
-- ---------------------------------------------------------------------------
with papel(nom, cant, sku_menu) as (values
  ('CASABE',                        43.0, '1074'),
  ('MANGU DE PLATANO - GUARNICION', 41.0, '00000580'),
  ('CROQUETAS DE POLLO',            17.0, '1050'),
  ('PAPAS FRITAS',                  16.0, '1073'),
  ('VEGETALES SALTEADOS',           11.0, '00000951')
  -- COCOA AMARGA sale de acá: ya tiene un «2» cargado y es el mismo número
  -- de la hoja 2. Volver a sumarlo lo dejaría en 4. Si el paso 3 muestra que
  -- ese 2 vino de otra área, agregala de vuelta:
  --   , ('COCOA AMARGA', 2.0, '7460193553296')
),
resuelto as (
  select p.nom, p.cant, i.id as item_id
  from papel p
  join lateral (
    select * from public.inventory_items ii
     where ii.business_id = '35c5076a-bd85-4a1b-8d1c-ce719c4f9ae6'
       and coalesce(ii.is_active, true)
       and (upper(btrim(ii.name)) = upper(btrim(p.nom)) or ii.sku = p.sku_menu)
     order by (upper(btrim(ii.name)) = upper(btrim(p.nom))) desc
     limit 1
  ) i on true
)
insert into public.physical_count_lines
  (session_id, item_id, snapshot_quantity, counted_quantity, counter_notes)
select
  s.id, r.item_id,
  coalesce((select st.quantity from public.inventory_stock st
             where st.item_id = r.item_id
               and st.warehouse_id = s.warehouse_id), 0),
  r.cant,
  'Cocina B (hoja 2 del Excel): ' || r.cant::text
from public.physical_count_sessions s
join resuelto r on true
where s.business_id = '35c5076a-bd85-4a1b-8d1c-ce719c4f9ae6'
  and s.code = 'PC-2026-000003'
on conflict (session_id, item_id) do update
  set counted_quantity = coalesce(physical_count_lines.counted_quantity, 0)
                       + excluded.counted_quantity,
      counter_notes    = coalesce(physical_count_lines.counter_notes || ' + ', '')
                       || excluded.counter_notes,
      updated_at       = now();


-- ---------------------------------------------------------------------------
-- 4. VERIFICAR — los siete de la cocina B, como quedaron.
-- ---------------------------------------------------------------------------
select
  i.name, i.unit, round(coalesce(i.cost,0),2) as costo,
  l.counted_quantity                          as contado_total,
  round(l.counted_quantity * coalesce(i.cost,0), 2) as valor,
  l.counter_notes
from public.physical_count_lines l
join public.physical_count_sessions s on s.id = l.session_id
join public.inventory_items i on i.id = l.item_id
where s.business_id = '35c5076a-bd85-4a1b-8d1c-ce719c4f9ae6'
  and s.code = 'PC-2026-000003'
  and (upper(btrim(i.name)) in ('CASABE','QUIPE DE POLLO',
        'MANGU DE PLATANO - GUARNICION','CROQUETAS DE POLLO','PAPAS FRITAS',
        'VEGETALES SALTEADOS','COCOA AMARGA'))
order by i.name;
