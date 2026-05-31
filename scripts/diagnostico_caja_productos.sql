-- ============================================================================
-- DIAGNÓSTICO: "En la caja 11 aparecen productos que ayer no estaban"
--
-- Cómo usarlo:
--   1. Abre el SQL Editor de Supabase (proyecto sqdwjjewdqzxglvqerqt).
--   2. Pega TODO este archivo y ejecútalo.
--   3. Revisa los resultados bloque por bloque (cada SELECT da una tabla).
--
-- El UUID se pone UNA sola vez abajo (bloque 0). Puede ser el id de la SESIÓN
-- de caja o el id de la CAJA (cash_register) — el script resuelve ambos.
--
-- Relaciones reales del esquema (importante):
--   - La caja (cash_registers) tiene N sesiones (cash_register_sessions).
--   - Las VENTAS de una sesión se enlazan por payments.session_id -> order_id
--     y por cash_transactions.session_id -> related_order_id.
--   - OJO: orders.session_id NO es la caja; apunta a table_sessions (la mesa).
--     Por eso para "qué se vendió en la caja" se va por payments, no por
--     orders.session_id.
--
-- Hipótesis principal de "productos de ayer": la sesión de la caja 11 quedó
-- ABIERTA desde ayer (nunca se cerró), entonces acumula ventas de varios días.
-- Los bloques 2 y 4 confirman o descartan eso.
-- ============================================================================

-- 0) UUID a investigar (cámbialo aquí si revisas otra caja). Se guarda para
--    todo el script; no hay que repetirlo.
select set_config('mango.uuid', '33207ebd-985d-455c-bdbb-1b38af8b36ea', false);


-- ----------------------------------------------------------------------------
-- 1) ¿Qué es el UUID? ¿una SESIÓN de caja o una CAJA?
-- ----------------------------------------------------------------------------
select 'ES_SESION' as que_es,
       s.id            as session_id,
       cr.name         as caja,
       s.status,
       s.opened_at,
       s.closed_at,
       s.start_amount,
       s.end_amount
  from public.cash_register_sessions s
  join public.cash_registers cr on cr.id = s.cash_register_id
 where s.id = current_setting('mango.uuid')::uuid
union all
select 'ES_CAJA' as que_es,
       cr.id      as session_id,
       cr.name    as caja,
       case when cr.is_active then 'activa' else 'inactiva' end,
       null, null, null, null
  from public.cash_registers cr
 where cr.id = current_setting('mango.uuid')::uuid;


-- ----------------------------------------------------------------------------
-- 2) Sesiones recientes de ESA caja (sea el UUID la caja o una de sus sesiones).
--    >>> Mira la columna `sigue_abierta` y `dias_abierta`. <<<
--    Si hay una sesión abierta con dias_abierta >= 1, ahí está el problema:
--    está mezclando ventas de varios días.
--    `cruza_dias` = la sesión abrió un día y sigue (o cerró) en otro.
-- ----------------------------------------------------------------------------
with reg as (
  select coalesce(
    (select cash_register_id from public.cash_register_sessions
       where id = current_setting('mango.uuid')::uuid),
    (select id from public.cash_registers
       where id = current_setting('mango.uuid')::uuid)
  ) as cash_register_id
)
select s.id                                              as session_id,
       cr.name                                           as caja,
       s.status,
       s.opened_at,
       s.closed_at,
       (s.closed_at is null)                             as sigue_abierta,
       (s.opened_at::date
          <> coalesce(s.closed_at, now())::date)         as cruza_dias,
       round(extract(epoch from (now() - s.opened_at))
             / 86400.0, 1)                               as dias_abierta,
       (select count(*) from public.payments p
          where p.session_id = s.id
            and p.status = 'completed')                  as pagos_completados
  from public.cash_register_sessions s
  join reg on reg.cash_register_id = s.cash_register_id
  join public.cash_registers cr on cr.id = s.cash_register_id
 order by s.opened_at desc
 limit 15;


-- ----------------------------------------------------------------------------
-- 3) Desglose de PRODUCTOS de la sesión objetivo.
--    Sesión objetivo = el UUID si es sesión; si el UUID es la caja, se toma su
--    sesión más reciente. Para forzar otra sesión, reemplaza en el bloque 0 el
--    UUID por el session_id que viste en el bloque 2.
--    >>> Mira `primera` y `ultima`: si `primera` es de ayer (o antes), esos
--        productos vienen de una sesión que no se cerró a tiempo. <<<
-- ----------------------------------------------------------------------------
with sess as (
  select coalesce(
    (select id from public.cash_register_sessions
       where id = current_setting('mango.uuid')::uuid),
    (select id from public.cash_register_sessions
       where cash_register_id = current_setting('mango.uuid')::uuid
       order by opened_at desc limit 1)
  ) as session_id
),
ords as (
  -- órdenes pagadas en esa sesión (distinct: evita doble conteo por split)
  select distinct o.id, o.created_at
    from sess
    join public.payments p
      on p.session_id = sess.session_id
     and p.status = 'completed'
    join public.orders o on o.id = p.order_id
)
select oi.product_name,
       sum(oi.qty)                  as cantidad,
       count(distinct ords.id)      as ordenes,
       min(ords.created_at)         as primera,
       max(ords.created_at)         as ultima
  from ords
  join public.order_items oi on oi.order_id = ords.id
 group by oi.product_name
 order by ultima desc;


-- ----------------------------------------------------------------------------
-- 4) SMOKING GUN: órdenes de la sesión objetivo que son de un día anterior
--    o que se crearon ANTES de que la sesión abriera (fuga entre sesiones).
--    Si este bloque devuelve filas, esos son los "productos de ayer".
-- ----------------------------------------------------------------------------
with sess as (
  select coalesce(
    (select id from public.cash_register_sessions
       where id = current_setting('mango.uuid')::uuid),
    (select id from public.cash_register_sessions
       where cash_register_id = current_setting('mango.uuid')::uuid
       order by opened_at desc limit 1)
  ) as session_id
)
select o.id                              as order_id,
       o.created_at                      as orden_creada,
       s.opened_at                       as sesion_abierta,
       (o.created_at < s.opened_at)      as creada_antes_de_abrir,
       (o.created_at::date < now()::date) as de_dia_anterior,
       o.total,
       p.created_at                      as pago_creado
  from sess
  join public.cash_register_sessions s on s.id = sess.session_id
  join public.payments p
    on p.session_id = sess.session_id
   and p.status = 'completed'
  join public.orders o on o.id = p.order_id
 where o.created_at::date < now()::date
    or o.created_at < s.opened_at
 order by o.created_at;


-- ----------------------------------------------------------------------------
-- 5) CRUCE de consistencia: ¿payments y cash_transactions cuentan lo mismo para
--    la sesión? Un descuadre acá indica que el resumen de cierre y la lista de
--    productos miran fuentes distintas (otra causa posible del fantasma).
-- ----------------------------------------------------------------------------
with sess as (
  select coalesce(
    (select id from public.cash_register_sessions
       where id = current_setting('mango.uuid')::uuid),
    (select id from public.cash_register_sessions
       where cash_register_id = current_setting('mango.uuid')::uuid
       order by opened_at desc limit 1)
  ) as session_id
)
select
  (select count(distinct order_id)
     from public.payments
    where session_id = (select session_id from sess)
      and status = 'completed')                       as ordenes_por_payments,
  (select count(distinct related_order_id)
     from public.cash_transactions
    where session_id = (select session_id from sess)
      and type = 'sale')                              as ordenes_por_cash_tx;
