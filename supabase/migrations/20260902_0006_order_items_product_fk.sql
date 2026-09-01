-- =============================================================================
-- Que borrar un producto con ventas FALLE, en vez de desconectar el histórico.
--
-- EL PROBLEMA (verificado 2026-09-01 contra la base VIVA):
--   La foreign key `order_items_product_id_fkey` YA EXISTE, pero se creó en
--   `20260407_0001` con `ON DELETE SET NULL`, y el comentario de esa
--   migración lo dice: se agregó para habilitar los joins de PostgREST, no
--   para proteger integridad.
--
--   Con esa regla, el botón de basura de Productos
--   (`products_repository.dart:527`) borra el producto SIN ERROR y deja en
--   NULL el `product_id` de todas sus ventas. El ticket viejo se salva
--   —`order_items` guarda `product_name` aparte— pero cualquier reporte que
--   agrupe por producto pierde esas ventas EN SILENCIO.
--
--   OJO CON EL REPO: `supabase/schema.sql` NO lista esta constraint; el dump
--   está viejo. La verdad estaba en las migraciones y en `pg_constraint`.
--
-- LA DECISIÓN: el histórico de ventas pesa más que la comodidad de borrar. Un
--   producto que ya se vendió no se borra: se DESACTIVA (`is_active = false`),
--   que es lo que la pantalla de Productos debería usar siempre.
--
-- POR QUÉ RESTRICT Y NO CASCADE: cascade borraría las líneas de venta, o sea
--   la facturación. Nunca.
--
-- NO HACE FALTA `NOT VALID`: la constraint vigente está validada, así que por
--   construcción no hay huérfanos y el escaneo no puede fallar. Con ~369 mil
--   filas y el índice ya creado, tarda segundos.
--
-- OJO: borrar un NEGOCIO entero ahora falla si tiene ventas
-- (`menu_items_business_id_fkey` es ON DELETE CASCADE y ya no podrá
-- cascadear). No es una operación normal en producción.
--
-- EJECUTAR LAS SENTENCIAS UNA POR UNA.
-- REVERSIBLE: sí (ver _ROLLBACK).
-- =============================================================================

-- ---------------------------------------------------------------------------
-- 1. LO QUE YA SE PERDIÓ — ventas sin producto asociado.
--
--    Con `SET NULL` no quedan huérfanos: quedan NULOS. Estas son las líneas
--    que ya no se pueden atribuir a ningún producto. OJO: no todas vienen de
--    un borrado — una venta rápida por monto libre también puede nacer sin
--    producto. Por eso se muestran con su `product_name`, que es el rastro
--    que quedó.
-- ---------------------------------------------------------------------------
select
  count(*)                                          as lineas_sin_producto,
  count(distinct oi.product_name)                   as nombres_distintos,
  min(oi.created_at)::date                          as desde,
  max(oi.created_at)::date                          as hasta,
  round(coalesce(sum(oi.total), 0), 2)              as monto_total
from public.order_items oi
where oi.product_id is null;

-- (segunda sentencia) — el detalle, para reconocer qué productos se borraron.
-- select oi.product_name,
--        count(*) as lineas,
--        round(sum(oi.total), 2) as monto,
--        min(oi.created_at)::date as desde,
--        max(oi.created_at)::date as hasta
-- from public.order_items oi
-- where oi.product_id is null
-- group by oi.product_name
-- order by count(*) desc
-- limit 50;


-- ---------------------------------------------------------------------------
-- 2. ÍNDICE sobre product_id — sin él, cada borrado escanea order_items
--    entera para comprobar la FK.
--
--    ⚠️ El editor SQL de Supabase envuelve las sentencias en una transacción,
--    así que `CREATE INDEX CONCURRENTLY` revienta ahí con 25001 (verificado).
--    Esta versión bloquea las escrituras unos segundos; con 369 mil filas es
--    despreciable, pero conviene un momento de calma en la caja.
-- ---------------------------------------------------------------------------
create index if not exists idx_order_items_product
  on public.order_items (product_id);

-- Desde psql (fuera de transacción) sí se puede sin bloquear escrituras:
--   create index concurrently if not exists idx_order_items_product
--     on public.order_items (product_id);


-- ---------------------------------------------------------------------------
-- 3. CAMBIAR LA REGLA: SET NULL → RESTRICT.
--
--    Va en UNA sola sentencia a propósito: entre el drop y el add, la tabla
--    queda sin protección. Un solo `alter table` con las dos acciones toma el
--    lock una vez y no deja esa ventana.
-- ---------------------------------------------------------------------------
alter table public.order_items
  drop constraint order_items_product_id_fkey,
  add  constraint order_items_product_id_fkey
       foreign key (product_id) references public.menu_items(id)
       on delete restrict;

comment on constraint order_items_product_id_fkey on public.order_items is
  'ON DELETE RESTRICT desde 20260902_0006: un producto con ventas no se borra, '
  'se desactiva. Antes era SET NULL (20260407_0001, puesta para los joins de '
  'PostgREST) y el borrado desconectaba el histórico sin avisar.';


-- ---------------------------------------------------------------------------
-- 4. VERIFICAR. Tiene que decir ON DELETE RESTRICT y convalidated = true.
-- ---------------------------------------------------------------------------
select conname, convalidated, pg_get_constraintdef(oid) as definicion
from pg_constraint
where conrelid = 'public.order_items'::regclass
  and conname = 'order_items_product_id_fkey';
