-- =============================================================================
-- LA PENDA EXPRESS — desactivar productos duplicados (y limpiar su insumo)
-- business_id = 35c5076a-bd85-4a1b-8d1c-ce719c4f9ae6
--
-- POR QUÉ NO SE BORRAN:
--   `order_items.product_id` NO tiene foreign key hacia `menu_items`
--   (verificado en el esquema). Un DELETE por lo tanto NO falla: se ejecuta y
--   deja las ventas históricas apuntando a un producto inexistente. El ticket
--   viejo se salva porque `order_items` guarda `product_name` aparte, pero
--   cualquier reporte que agrupe por producto pierde esas ventas EN SILENCIO.
--
--   El botón de basura de la pantalla de Productos hace exactamente ese
--   DELETE (products_repository.dart:527). Úsalo SOLO en productos sin una
--   sola venta en toda su historia — la consulta 1 te lo dice.
--
-- QUÉ HACE ESTE SCRIPT: desactiva el sobrante, le pone sufijo, le quita el
-- inventario, y limpia la ficha de insumo que la activación le creó.
--
-- CORRER UNA SENTENCIA A LA VEZ.
-- =============================================================================

-- ---------------------------------------------------------------------------
-- 1. ¿BORRAR O DESACTIVAR? — ventas de TODA la historia, no de 90 días.
--    Poné acá los nombres que estés evaluando.
--    `ventas_totales = 0` → se puede borrar de verdad. Cualquier otro número
--    → se desactiva, nunca se borra.
-- ---------------------------------------------------------------------------
select
  mi.id,
  mi.name,
  mi.price,
  mi.is_inventory_tracked,
  mi.inventory_item_id,
  (select count(*) from public.order_items oi where oi.product_id = mi.id)
    as lineas_de_venta_historicas,
  (select coalesce(sum(coalesce(oi.qty, oi.quantity::numeric)), 0)
     from public.order_items oi where oi.product_id = mi.id)
    as ventas_totales,
  (select max(oi.created_at)::date from public.order_items oi
    where oi.product_id = mi.id)
    as ultima_venta
from public.menu_items mi
where mi.business_id = '35c5076a-bd85-4a1b-8d1c-ce719c4f9ae6'
  and mi.name in (
    -- ⬇ EDITAR: los sobrantes que decidiste descartar
    'SAN PELLEGRINO MELOGRANO E ARANCITA',
    'SANPELLEGRINO ARANCIA FICO INDIA',
    'PEPSI COLA 12 ONZ'
  )
order by mi.name;


-- ---------------------------------------------------------------------------
-- 2. RESPALDO
-- ---------------------------------------------------------------------------
create table if not exists public.zz_backup_prod_duplicados_20260901 (
  menu_item_id      uuid primary key,
  nombre_previo     text,
  was_active        boolean,
  was_tracked       boolean,
  inventory_item_id uuid,
  registrado_en     timestamptz default now()
);


-- ---------------------------------------------------------------------------
-- 3. DESACTIVAR el sobrante. Misma lista de la consulta 1.
--
--    El sufijo [DUPLICADO] es para que se distinga en la pantalla de
--    Productos cuando se filtre por inactivos, y para que nadie lo reactive
--    por error creyendo que es el bueno.
-- ---------------------------------------------------------------------------
with objetivo as (
  select id, name, is_active, is_inventory_tracked, inventory_item_id
  from public.menu_items
  where business_id = '35c5076a-bd85-4a1b-8d1c-ce719c4f9ae6'
    and coalesce(is_active, true)
    and name in (
      -- ⬇ EDITAR: la misma lista de arriba
      'SAN PELLEGRINO MELOGRANO E ARANCITA',
      'SANPELLEGRINO ARANCIA FICO INDIA',
      'PEPSI COLA 12 ONZ'
    )
),
respaldo as (
  insert into public.zz_backup_prod_duplicados_20260901
    (menu_item_id, nombre_previo, was_active, was_tracked, inventory_item_id)
  select id, name, is_active, is_inventory_tracked, inventory_item_id
  from objetivo
  on conflict (menu_item_id) do nothing
  returning menu_item_id
)
update public.menu_items mi
   set is_active = false,
       is_inventory_tracked = false,
       name = mi.name || ' [DUPLICADO]'
 where mi.id in (select id from objetivo);


-- ---------------------------------------------------------------------------
-- 4. SU FICHA DE INSUMO — borrar si nació hoy y está limpia.
--
--    Una ficha creada por la activación no tiene historia: sale sin dejar
--    rastro. Si tiene movimientos o le cuelga otro producto activo, NO se
--    borra (falsearía el kardex) y pasa al paso 5.
-- ---------------------------------------------------------------------------
delete from public.inventory_items ii
 using public.zz_backup_prod_duplicados_20260901 b
 where ii.id = b.inventory_item_id
   and ii.id in (select created_inventory_item_id
                 from public.zz_backup_inventariable_20260901
                 where created_inventory_item_id is not null)
   and not exists (select 1 from public.inventory_movements m
                    where m.item_id = ii.id)
   and not exists (select 1 from public.menu_items mi
                    where mi.inventory_item_id = ii.id
                      and coalesce(mi.is_active, true));


-- ---------------------------------------------------------------------------
-- 5. LAS QUE NO SE PUDIERON BORRAR — marcarlas para que nadie las cuente.
--
--    Desactivar NO le quita el renglón al conteo congelado: la línea ya
--    existe. Renombrarla sí se ve en la hoja, y al cierre el "poner en cero
--    lo no contado" la deja en 0.
-- ---------------------------------------------------------------------------
update public.inventory_items ii
   set is_active = false,
       name = ii.name || ' [DUPLICADO - NO CONTAR]'
  from public.zz_backup_prod_duplicados_20260901 b
 where ii.id = b.inventory_item_id
   and coalesce(ii.is_active, true)
   and not exists (select 1 from public.menu_items mi
                    where mi.inventory_item_id = ii.id
                      and coalesce(mi.is_active, true));


-- ---------------------------------------------------------------------------
-- 6. SI HAY QUE UNIFICAR EL PRECIO del que se queda.
--    Cuando los dos venden y tenían precios distintos, el dueño decide cuál
--    es el bueno y se pone acá.
-- ---------------------------------------------------------------------------
-- update public.menu_items
--    set price = 140.00
--  where business_id = '35c5076a-bd85-4a1b-8d1c-ce719c4f9ae6'
--    and name = 'SANPELLEGRINO MELOGRANO ARANCITA';


-- ---------------------------------------------------------------------------
-- 7. VERIFICAR
-- ---------------------------------------------------------------------------
select mi.name, mi.is_active, mi.is_inventory_tracked, ii.name as insumo,
       ii.is_active as insumo_activo
from public.menu_items mi
left join public.inventory_items ii on ii.id = mi.inventory_item_id
where mi.business_id = '35c5076a-bd85-4a1b-8d1c-ce719c4f9ae6'
  and mi.name like '%[DUPLICADO]%'
order by mi.name;


-- ---------------------------------------------------------------------------
-- 8. REVERTIR
-- ---------------------------------------------------------------------------
-- update public.menu_items mi
--    set is_active = b.was_active,
--        is_inventory_tracked = b.was_tracked,
--        name = b.nombre_previo,
--        inventory_item_id = b.inventory_item_id
--   from public.zz_backup_prod_duplicados_20260901 b
--  where mi.id = b.menu_item_id;
