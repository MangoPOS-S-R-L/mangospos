-- =============================================================================
-- LA PENDA EXPRESS — combinar los 4 conteos por área en UNO solo
-- business_id = 35c5076a-bd85-4a1b-8d1c-ce719c4f9ae6
--
-- CÓMO SE ESTÁ CONTANDO: varias sesiones abiertas a la vez sobre la MISMA
-- bodega, una por área, para repartir el recorrido. Al 2026-09-01 son CINCO:
--   PC-2026-000002  Diego · Furgón · Almacén principal
--   PC-2026-000003  Almacén Cocina  (se cuenta en PAPEL, hay que teclearla)
--   PC-2026-000004  Foodshop · Winnifer
--   PC-2026-000005  Foodshop · Rosayra   ← destino de la combinación
--   PC-2026-000006  Bar · DH             (abierta después que las otras)
--
-- OJO: el número de sesiones cambió sobre la marcha. Antes de combinar,
-- correr el paso 1 de este archivo para ver cuántas hay REALMENTE abiertas —
-- las sentencias de abajo trabajan sobre todas las `in_progress`, así que no
-- se les escapa ninguna, pero conviene saber qué se está sumando.
--
-- ⚠️ LO MÁS IMPORTANTE: NO CERRAR MÁS DE UNA SESIÓN.
--
--    CORREGIDO 2026-09-03 — antes este archivo decía que el cierre deja el
--    stock IGUAL a lo contado. NO ES ASÍ, y el error importa:
--
--      fn_physical_count_complete:  v_variance := contado - snapshot
--                                   y registra un movimiento de ajuste
--      fn_sync_inventory_stock_on_movement (trigger):
--                                   quantity = quantity + excluded.quantity
--
--      → stock final = stock ACTUAL + (contado - snapshot)
--
--    Con las cinco sesiones sobre la MISMA bodega, cerrar dos aplica DOS
--    ajustes, uno encima del otro. Un artículo con snapshot 100 contado 30 en
--    dos áreas: la primera lo deja en 30, la segunda le vuelve a restar 70 y
--    lo deja en -40. No es que se pierda un área — es que se resta dos veces.
--
--    Por eso la combinación va ANTES del cierre y solo se cierra UNA sesión.
--    Eso es lo que hace este archivo.
--
--    (Lo bueno de esta semántica: la mercancía que entró DESPUÉS de congelar
--    sobrevive al cierre, porque el ajuste es relativo al snapshot y no un
--    reemplazo. Ej.: carne salada con snapshot 6.25, contado 0.625 y stock
--    actual 48 termina en 42.375, no en 0.625.)
--
-- ⚠️ TAMPOCO tocar "Poner en cero lo no contado" en ninguna sesión: el botón
--    trabaja por sesión y las cuatro tienen las 2,236 líneas completas, así
--    que pondría en cero lo que contaron las otras tres. Para eso está el
--    paso 4 de acá, que mira las cuatro juntas.
--
-- ORDEN: 1 (revisar) → 2 (combinar) → 3 (cancelar las otras) → 4 (ceros, al
-- final del recorrido) → 5 (verificar) → cerrar la sesión destino DESDE LA APP.
-- CORRER UNA SENTENCIA A LA VEZ.
-- =============================================================================

-- ---------------------------------------------------------------------------
-- 1. REVISAR ANTES DE COMBINAR — qué artículos aparecen en más de un área.
--
--    Contar el mismo artículo en dos áreas es LEGÍTIMO acá (la misma bebida
--    está en el bar y en la tienda) y por eso se suma. Pero mirá la lista:
--    si aparece algo que NO puede estar en dos lados, es que dos personas
--    contaron el mismo anaquel y la suma lo duplicaría. Eso se corrige
--    borrando el conteo sobrante:
--        update public.physical_count_lines
--           set counted_quantity = null
--         where session_id = '<sesión que se descarta>'
--           and item_id = '<item>';
-- ---------------------------------------------------------------------------
select
  ii.name                       as articulo,
  count(*)                      as en_cuantas_areas,
  string_agg(s.code || ': ' || l.counted_quantity::text, ' | '
             order by s.code)   as detalle,
  sum(l.counted_quantity)       as total_si_se_suma
from public.physical_count_lines l
join public.physical_count_sessions s on s.id = l.session_id
join public.inventory_items ii on ii.id = l.item_id
where s.business_id = '35c5076a-bd85-4a1b-8d1c-ce719c4f9ae6'
  and s.status = 'in_progress'
  and l.counted_quantity is not null
group by ii.name
having count(*) > 1
order by count(*) desc, ii.name;


-- ---------------------------------------------------------------------------
-- 2. COMBINAR — sumar las cuatro áreas dentro de la sesión destino.
--
--    Cambiá 'PC-2026-000005' si querés otra como destino.
--    La suma INCLUYE lo que ya tenía el destino, así que la línea queda con
--    el total de las cuatro áreas, no con un acumulado a medias. Es
--    idempotente: correrlo dos veces da el mismo número.
--
--    La nota deja rastro de dónde salió cada cantidad, que es lo que después
--    permite explicar una diferencia sin adivinar.
-- ---------------------------------------------------------------------------
with destino as (
  select id from public.physical_count_sessions
   where business_id = '35c5076a-bd85-4a1b-8d1c-ce719c4f9ae6'
     and code = 'PC-2026-000005'
),
suma as (
  select
    l.item_id,
    sum(l.counted_quantity)                                as total,
    string_agg(s.code || '=' || l.counted_quantity::text,
               ' + ' order by s.code)                      as desglose,
    count(*)                                               as areas
  from public.physical_count_lines l
  join public.physical_count_sessions s on s.id = l.session_id
  where s.business_id = '35c5076a-bd85-4a1b-8d1c-ce719c4f9ae6'
    and s.status = 'in_progress'
    and l.counted_quantity is not null
  group by l.item_id
)
update public.physical_count_lines d
   set counted_quantity = s.total,
       counter_notes    = case when s.areas > 1
                               then 'Áreas: ' || s.desglose
                               else d.counter_notes end,
       updated_at       = now()
  from suma s
 where d.session_id = (select id from destino)
   and d.item_id = s.item_id
   and (d.counted_quantity is distinct from s.total);


-- ---------------------------------------------------------------------------
-- 3. CANCELAR las otras tres — para que nadie las cierre por error.
--
--    No se borran: quedan como `cancelled` con sus líneas intactas, que es el
--    respaldo de qué contó cada área. El total ya vive en la sesión destino.
-- ---------------------------------------------------------------------------
update public.physical_count_sessions
   set status = 'cancelled',
       cancelled_at = now(),
       cancellation_reason = 'Conteo por áreas: combinada en PC-2026-000005'
 where business_id = '35c5076a-bd85-4a1b-8d1c-ce719c4f9ae6'
   and status = 'in_progress'
   and code <> 'PC-2026-000005';


-- ---------------------------------------------------------------------------
-- 4. AL FINAL DEL RECORRIDO — poner en cero lo que ningún área contó.
--
--    Cada cero declara que ese artículo NO está en la bodega. Con 2,236
--    líneas, lo que quede en blanco conserva su stock viejo, que es
--    existencia fantasma. Correr SOLO cuando las cuatro áreas terminaron.
-- ---------------------------------------------------------------------------
-- update public.physical_count_lines d
--    set counted_quantity = 0,
--        counter_notes = coalesce(d.counter_notes, 'Ningún área lo contó'),
--        updated_at = now()
--  where d.session_id = (
--          select id from public.physical_count_sessions
--           where business_id = '35c5076a-bd85-4a1b-8d1c-ce719c4f9ae6'
--             and code = 'PC-2026-000005')
--    and d.counted_quantity is null;


-- ---------------------------------------------------------------------------
-- 5. VERIFICAR antes de cerrar.
--    Debe quedar UNA sola sesión in_progress, y el `statement_timeout` de
--    complete tiene que decir 300s: con 2,236 líneas, cada una contada genera
--    un movimiento y cada movimiento dispara dos triggers fila por fila,
--    todo en una sola transacción.
-- ---------------------------------------------------------------------------
select
  s.code,
  s.status,
  count(l.*)                                               as lineas,
  count(l.*) filter (where l.counted_quantity is not null) as contadas
from public.physical_count_sessions s
join public.physical_count_lines l on l.session_id = s.id
where s.business_id = '35c5076a-bd85-4a1b-8d1c-ce719c4f9ae6'
  and s.status in ('in_progress', 'draft')
group by s.code, s.status
order by s.code;

-- (segunda sentencia)
select proname, proconfig
from pg_proc
where proname in ('fn_physical_count_complete', 'fn_physical_count_freeze');
