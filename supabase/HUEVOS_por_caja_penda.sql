-- =============================================================================
-- LA PENDA EXPRESS — pasar HUEVOS FRECOS de unidad a CAJA
-- business_id = 35c5076a-bd85-4a1b-8d1c-ce719c4f9ae6
-- item_id     = 3306a200-6105-456d-b1b7-54ea5603e8e7
--
-- Decisión del dueño: los huevos se llevan por CAJA, que es como los cuenta la
-- cocina (la hoja 1 dice «29 cartones»).
--
-- ── EL CARTÓN ES DE 30, Y EL PROPIO SISTEMA LO CONFIRMA ──────────────────
-- Hoy hay 3,450 huevos declarados. 3,450 ÷ 30 = 115 exactas, sin decimal. Si
-- el cartón fuera de 36 daría 95.83, que nadie compra. El número redondo es la
-- prueba de que las entradas se hicieron en cartones de 30.
--
-- ── HAY QUE MOVER TRES COSAS A LA VEZ ────────────────────────────────────
-- Cambiar solo la unidad deja el inventario diciendo «3,450 cajas» y el costo
-- en RD$4.60 la caja. Las tres van juntas o el número miente:
--
--     unidad      unidad  →  caja
--     costo       4.60    →  138.00      (4.60 x 30)
--     existencia  3,450   →  115         (3,450 ÷ 30)
--
-- ── LA PRUEBA DE QUE LA CONVERSIÓN NO INVENTA NI PIERDE PLATA ────────────
--     antes:   3,450 huevos x RD$4.60  = RD$15,870
--     después:   115 cajas  x RD$138   = RD$15,870      ← idéntico
--
-- Y el ajuste del conteo también da igual en las dos formas:
--     en huevos:   (870 - 3,450) x 4.60 = -RD$11,868
--     en cajas:    ( 29 -   115) x 138  = -RD$11,868
--
-- CORRER UNA SENTENCIA A LA VEZ, EN ORDEN.
-- =============================================================================

-- ---------------------------------------------------------------------------
-- 1. ANTES — la foto para poder comparar después.
-- ---------------------------------------------------------------------------
select
  i.name, i.unit, round(coalesce(i.cost,0),2) as costo,
  coalesce((select sum(st.quantity) from public.inventory_stock st
             where st.item_id = i.id), 0)     as existencia,
  round(coalesce((select sum(st.quantity) from public.inventory_stock st
                   where st.item_id = i.id), 0) * coalesce(i.cost,0), 2) as valor,
  (select l.counted_quantity from public.physical_count_lines l
     join public.physical_count_sessions s on s.id = l.session_id
    where l.item_id = i.id and s.code = 'PC-2026-000003')  as contado,
  (select l.snapshot_quantity from public.physical_count_lines l
     join public.physical_count_sessions s on s.id = l.session_id
    where l.item_id = i.id and s.code = 'PC-2026-000003')  as snapshot
from public.inventory_items i
where i.id = '3306a200-6105-456d-b1b7-54ea5603e8e7';


-- ---------------------------------------------------------------------------
-- 2. LA FICHA — unidad, costo y empaque.
--
--    `purchase_unit` + `pack_size` dejan escrito que la caja trae 30. Con eso
--    una receta puede pedir «2 huevos» y el sistema sabe que son 2/30 de caja,
--    en vez de quedar atrapada en la caja entera.
-- ---------------------------------------------------------------------------
update public.inventory_items
   set unit          = 'caja',
       cost          = 138.00,        -- 4.60 x 30
       purchase_unit = 'Caja',
       pack_size     = 30
 where id = '3306a200-6105-456d-b1b7-54ea5603e8e7';


-- ---------------------------------------------------------------------------
-- 3. LA EXISTENCIA — 3,450 huevos son 115 cajas.
--
--    Esto NO es un ajuste de inventario: no entró ni salió un solo huevo, solo
--    se está diciendo la misma cantidad en otra unidad. Por eso va como update
--    directo y no por `fn_inventory_adjust`, que registraría un movimiento de
--    mercancía que nunca ocurrió.
--
--    Se divide sobre TODAS las bodegas donde el insumo tenga fila.
-- ---------------------------------------------------------------------------
update public.inventory_stock
   set quantity = round(quantity / 30.0, 4),
       last_updated = now()
 where item_id = '3306a200-6105-456d-b1b7-54ea5603e8e7';


-- ---------------------------------------------------------------------------
-- 4. EL SNAPSHOT DEL CONTEO — también en cajas.
--
--    El snapshot es «lo que el sistema creía tener» al congelar. Si queda en
--    3,450 mientras lo contado dice 29, el informe del auditor muestra una
--    diferencia de -3,421 CAJAS, que es un disparate y desacredita la hoja
--    entera. Se convierte igual: ÷ 30.
--
--    Aplica a TODAS las sesiones abiertas, no solo a la de cocina.
-- ---------------------------------------------------------------------------
update public.physical_count_lines l
   set snapshot_quantity = round(l.snapshot_quantity / 30.0, 4),
       updated_at = now()
  from public.physical_count_sessions s
 where l.session_id = s.id
   and s.business_id = '35c5076a-bd85-4a1b-8d1c-ce719c4f9ae6'
   and s.status in ('draft', 'in_progress')
   and l.item_id = '3306a200-6105-456d-b1b7-54ea5603e8e7';


-- ---------------------------------------------------------------------------
-- 5. CARGAR EL CONTEO — 29 cajas, tal como dice el papel.
--
--    Ya sin cuentas raras: el papel dice 29 cartones y el sistema lleva cajas.
--    El número entra tal cual, que era el punto.
-- ---------------------------------------------------------------------------
insert into public.physical_count_lines
  (session_id, item_id, snapshot_quantity, counted_quantity, counter_notes)
select
  s.id,
  '3306a200-6105-456d-b1b7-54ea5603e8e7',
  coalesce((select st.quantity from public.inventory_stock st
             where st.item_id = '3306a200-6105-456d-b1b7-54ea5603e8e7'
               and st.warehouse_id = s.warehouse_id), 0),
  29,
  'Hoja 1 cocina A: 29 cartones. El insumo se lleva por caja de 30.'
from public.physical_count_sessions s
where s.business_id = '35c5076a-bd85-4a1b-8d1c-ce719c4f9ae6'
  and s.code = 'PC-2026-000003'
on conflict (session_id, item_id) do update
  set counted_quantity = 29,
      counter_notes    = excluded.counter_notes,
      updated_at       = now();


-- ---------------------------------------------------------------------------
-- 6. VERIFICAR — el valor tiene que seguir siendo el mismo.
--
--    `valor` tiene que dar RD$15,870, igual que antes de la conversión. Si da
--    otra cosa, alguna de las tres partes quedó a medias.
-- ---------------------------------------------------------------------------
select
  i.name, i.unit, round(coalesce(i.cost,0),2) as costo,
  i.purchase_unit, i.pack_size,
  coalesce((select sum(st.quantity) from public.inventory_stock st
             where st.item_id = i.id), 0)     as existencia_cajas,
  round(coalesce((select sum(st.quantity) from public.inventory_stock st
                   where st.item_id = i.id), 0) * coalesce(i.cost,0), 2) as valor,
  l.snapshot_quantity                         as snapshot_cajas,
  l.counted_quantity                          as contado_cajas,
  round((l.counted_quantity - l.snapshot_quantity) * coalesce(i.cost,0), 2)
                                              as ajuste_rd,
  case when round(coalesce((select sum(st.quantity) from public.inventory_stock st
                             where st.item_id = i.id), 0)
                  * coalesce(i.cost,0), 2) = 15870.00
       then 'OK — el valor no cambió'
       else '⚠️ REVISAR — el valor debía quedar en 15,870' end as prueba
from public.inventory_items i
left join public.physical_count_lines l on l.item_id = i.id
left join public.physical_count_sessions s
       on s.id = l.session_id and s.code = 'PC-2026-000003'
where i.id = '3306a200-6105-456d-b1b7-54ea5603e8e7'
  and s.id is not null;
