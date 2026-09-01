-- =============================================================================
-- LA PENDA EXPRESS — los 5 insumos con nombre repetido, EN MEDIO DEL CONTEO
-- business_id = 35c5076a-bd85-4a1b-8d1c-ce719c4f9ae6
--
-- ORIGEN: solo KINDER JOY salió de la activación de hoy (dos productos
-- duplicados crearon una ficha cada uno). Los otros cuatro vienen de la
-- importación de julio y estaban pendientes de decisión desde agosto.
--
-- POR QUÉ NO SE FUSIONAN AHORA, COMO EN AGOSTO:
--   Con un conteo congelado encima, no hace falta mover stock entre fichas.
--   El conteo va a FIJAR la existencia real sobre la ficha que se queda, así
--   que el stock de la sobrante es irrelevante: alcanza con que nadie cuente
--   sobre ella y que el cierre la deje en cero.
--
--   Y desactivarla NO le quita el renglón al conteo: la línea ya está
--   congelada. Por eso lo que manda es RENOMBRARLA — el renglón la muestra
--   con el nombre nuevo y quien cuenta sabe cuál saltar.
--
-- PROCEDIMIENTO: marcar + desactivar la sobrante → contar todo sobre la que
-- se queda → el "poner en cero lo no contado" del cierre la deja en 0.
--
-- CORRER UNA SENTENCIA A LA VEZ.
-- =============================================================================

-- ---------------------------------------------------------------------------
-- 0. RESPALDO
-- ---------------------------------------------------------------------------
create table if not exists public.zz_backup_insumos_repetidos_20260901 (
  item_id       uuid primary key,
  nombre_previo text,
  was_active    boolean,
  registrado_en timestamptz default now()
);


-- ---------------------------------------------------------------------------
-- 1. MARCAR Y DESACTIVAR las 4 sobrantes decididas por los datos.
--
--    En cada par se queda la que tiene MÁS movimientos y más stock, que es la
--    que el negocio viene usando de verdad:
--      · Aullama        → se queda 28be1d62 (1 mov, stock 1)
--      · ENVIO          → se queda 96caa477 (4 mov, ligada al producto)
--      · yautia blanca  → se queda 10fcc7b3 (3 mov, stock 30)
--      · yautia morada  → se queda e10a12b1 (2 mov, stock 20)
--
--    KINDER JOY NO va acá: las dos fichas son de hoy y cada una cuelga de un
--    producto distinto. Eso se resuelve en el paso 3.
-- ---------------------------------------------------------------------------
with objetivo as (
  select id, name, is_active
  from public.inventory_items
  where id in (
    '9ac87904-f7cb-4f9c-9483-419d98209c8f',  -- Aullama vacía
    '2d7b1f03-9aa9-4fcf-b050-c1594d70d4af',  -- ENVIO duplicada
    'abe36ed5-482c-4306-ba71-84f42d7e4d60',  -- yautia blanca (stock 8)
    'cf575463-a925-4d7d-9080-02ce913674e1'   -- yautia morada (stock 8)
  )
),
respaldo as (
  insert into public.zz_backup_insumos_repetidos_20260901
    (item_id, nombre_previo, was_active)
  select id, name, is_active from objetivo
  on conflict (item_id) do nothing
  returning item_id
)
update public.inventory_items ii
   set name = ii.name || ' [DUPLICADO - NO CONTAR]',
       is_active = false
 where ii.id in (select id from objetivo);


-- ---------------------------------------------------------------------------
-- 2. ENVIO NO ES MERCANCÍA — quitarle el inventario al producto.
--
--    Es un cargo de servicio con "existencia" 8 y 2. Mientras siga
--    inventariable, cada envío cobrado descuenta una unidad de un insumo que
--    nadie compra nunca, y el conteo pide contar algo que no está en ningún
--    anaquel.
-- ---------------------------------------------------------------------------
update public.menu_items
   set is_inventory_tracked = false,
       inventory_item_id = null
 where business_id = '35c5076a-bd85-4a1b-8d1c-ce719c4f9ae6'
   and name = 'ENVIO';

-- (segunda sentencia) — y su ficha fuera del catálogo activo.
update public.inventory_items
   set is_active = false,
       name = name || ' [NO ES INSUMO]'
 where id = '96caa477-5dde-4744-af6c-f56ea74edd27';


-- ---------------------------------------------------------------------------
-- 3. KINDER JOY — requiere DECISIÓN, no datos.
--
--    Dos fichas creadas hoy, las dos vacías, cada una colgando de un producto
--    KINDER JOY distinto y con códigos DISTINTOS:
--        d8d24efe… → código 0009800570096
--        998bb238… → código 009800570034
--
--    Y en el menú hay un tercero, KINDER JOY HUEVITOS ($118.64, 27 vendidas),
--    contra los dos KINDER JOY de $150.72 (7 vendidas) y $158.72 (1 venta).
--
--    Primero mirá qué son de verdad: ¿dos presentaciones o el mismo producto
--    cargado dos veces con precios distintos?
-- ---------------------------------------------------------------------------
select mi.id, mi.name, mi.price, mi.sku, mi.barcode,
       mi.is_inventory_tracked, mi.inventory_item_id,
       (select sum(coalesce(oi.qty, oi.quantity::numeric))
          from public.order_items oi
         where oi.product_id = mi.id
           and oi.created_at >= now() - interval '90 days') as vendidas_90d
from public.menu_items mi
where mi.business_id = '35c5076a-bd85-4a1b-8d1c-ce719c4f9ae6'
  and coalesce(mi.is_active, true)
  and mi.name ilike '%KINDER JOY%'
order by mi.name, mi.price;

-- Cuando decidas cuál se descarta, con SU id:
-- update public.menu_items
--    set is_active = false,
--        name = name || ' [DUPLICADO]',
--        is_inventory_tracked = false
--  where id = '<producto que se descarta>';
--
-- update public.inventory_items
--    set is_active = false, name = name || ' [DUPLICADO - NO CONTAR]'
--  where id = '<su insumo>';


-- ---------------------------------------------------------------------------
-- 4. VERIFICAR — no debe quedar ningún nombre de insumo ACTIVO repetido.
-- ---------------------------------------------------------------------------
with ins as (
  select lower(regexp_replace(name, '[^a-zA-Z0-9]', '', 'g')) as limpio
  from public.inventory_items
  where business_id = '35c5076a-bd85-4a1b-8d1c-ce719c4f9ae6'
    and coalesce(is_active, true)
)
select limpio, count(*) as fichas
from ins group by limpio having count(*) > 1 order by limpio;


-- ---------------------------------------------------------------------------
-- 5. REVERTIR
-- ---------------------------------------------------------------------------
-- update public.inventory_items ii
--    set name = b.nombre_previo, is_active = b.was_active
--   from public.zz_backup_insumos_repetidos_20260901 b
--  where ii.id = b.item_id;
