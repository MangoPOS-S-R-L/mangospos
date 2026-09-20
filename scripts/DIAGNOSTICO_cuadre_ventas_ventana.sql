-- =============================================================================
-- CUADRE: vendido vs. cobrado vs. lo que sigue en cuentas.
--
-- Negocio 6d13ed3f, ventana 2026-09-19 09:00 (hora RD) -> ahora.
--
-- IDENTIDAD que debe cumplirse:
--     (1) VENDIDO  =  (2) COBRADO  +  (3) EN CUENTAS ABIERTAS
-- y por lo tanto la fila (4) DIFERENCIA tiene que dar 0. Si no da 0, hay
-- órdenes marcadas como PAGADAS a las que les falta dinero — el síntoma de
-- cobro a nivel de orden que deja ítems/checks sin cubrir.
--
-- CRITERIOS (los mismos que usa el sistema, para que los números peguen):
--   * "vendido" = ítems no anulados: subtotal + tax - discounts.
--   * "cobrado" = payments completados: amount - change_amount. Es la misma
--     fórmula de fn_dashboard_kpis, get_sales_summary_v2 y el cierre de caja.
--   * el conjunto son las órdenes que tuvieron consumo DENTRO de la ventana,
--     y de esas se toma la orden COMPLETA. Si se cortaran los ítems por hora,
--     una mesa abierta desde antes de las 9 AM nunca cuadraría contra su pago.
--
-- Las filas 5 en adelante son informativas: explican de dónde sale cualquier
-- diferencia entre "lo que entró por caja" y "lo que se vendió".
--
-- Devuelve UN solo resultado (el SQL Editor de Supabase solo muestra el
-- último), ordenado por la columna `#`.
-- =============================================================================

with params as (
  select
    '6d13ed3f-0fb9-40e3-a695-f4c09759fbfd'::uuid as bid,
    (timestamp '2026-09-19 09:00' at time zone 'America/Santo_Domingo') as desde,
    now() as hasta
),

-- Órdenes con consumo dentro de la ventana (excluye órdenes anuladas).
ordenes as (
  select distinct o.id, o.status_ext
  from public.orders o
  join public.table_sessions ts on ts.id = o.session_id
  join public.order_items oi on oi.order_id = o.id
  cross join params p
  where ts.business_id = p.bid
    and o.status_ext is distinct from 'void'
    and oi.status <> 'void'
    and oi.created_at >= p.desde
    and oi.created_at <  p.hasta
),

-- Consumo de la orden COMPLETA (ver criterios arriba).
consumo as (
  select
    oi.order_id,
    sum(oi.subtotal + oi.tax - coalesce(oi.discounts, 0)) as neto,
    count(*) as items,
    count(*) filter (where oi.status = 'draft') as items_draft
  from public.order_items oi
  join ordenes r on r.id = oi.order_id
  where oi.status <> 'void'
  group by oi.order_id
),

cobrado as (
  select
    pa.order_id,
    sum(pa.amount - coalesce(pa.change_amount, 0)) as monto
  from public.payments pa
  join ordenes r on r.id = pa.order_id
  where pa.status = 'completed' or pa.status is null
  group by pa.order_id
),

por_orden as (
  select
    r.id,
    r.status_ext,
    coalesce(c.neto, 0)                          as consumo,
    coalesce(c.items, 0)                         as items,
    coalesce(c.items_draft, 0)                   as items_draft,
    coalesce(pg.monto, 0)                        as cobrado,
    coalesce(c.neto, 0) - coalesce(pg.monto, 0)  as pendiente
  from ordenes r
  left join consumo c on c.order_id = r.id
  left join cobrado pg on pg.order_id = r.id
)

select * from (
  select 1 as "#",
         'VENDIDO en la ventana (órdenes completas)' as concepto,
         round(sum(consumo), 2) as monto,
         count(*) as ordenes,
         sum(items) as items,
         '(1) lo que el sistema registra como consumido' as nota
  from por_orden

  union all
  select 2, '  ├─ ya COBRADO de esas órdenes',
         round(sum(cobrado), 2),
         count(*) filter (where cobrado > 0),
         null,
         '(2) pagos completados de esas mismas órdenes'
  from por_orden

  union all
  select 3, '  ├─ aún EN CUENTAS (órdenes abiertas)',
         round(sum(pendiente) filter (where status_ext <> 'paid'), 2),
         count(*) filter (where status_ext <> 'paid'),
         sum(items) filter (where status_ext <> 'paid'),
         '(3) mesas vivas por cobrar'
  from por_orden

  union all
  select 4, '  └─ DIFERENCIA (1 - 2 - 3)  <<< debe ser 0',
         round(sum(pendiente) filter (where status_ext = 'paid'), 2),
         count(*) filter (where status_ext = 'paid' and pendiente <> 0),
         null,
         'órdenes PAGADAS a las que les falta dinero. Si no es 0, revisar esas órdenes'
  from por_orden

  union all
  select 5, 'ítems en borrador dentro de (1)',
         null,
         count(*) filter (where items_draft > 0),
         sum(items_draft),
         'aún no enviados a cocina; ya suman al consumo'
  from por_orden

  -- ---- informativas: el dinero visto desde la CAJA ----
  union all
  select 6, 'COBRADO por caja dentro de la ventana',
         round(sum(pa.amount - coalesce(pa.change_amount, 0)), 2),
         count(distinct pa.order_id),
         null,
         'todo lo que entró en el periodo, sin importar cuándo se consumió'
  from public.payments pa
  cross join params p
  where pa.business_id = p.bid
    and (pa.status = 'completed' or pa.status is null)
    and pa.created_at >= p.desde and pa.created_at < p.hasta

  union all
  select 7, '  └─ de órdenes FUERA de la ventana (arrastre)',
         round(sum(pa.amount - coalesce(pa.change_amount, 0)), 2),
         count(distinct pa.order_id),
         null,
         'mesas abiertas antes de las 9 AM que se cobraron dentro'
  from public.payments pa
  cross join params p
  where pa.business_id = p.bid
    and (pa.status = 'completed' or pa.status is null)
    and pa.created_at >= p.desde and pa.created_at < p.hasta
    and not exists (select 1 from ordenes r where r.id = pa.order_id)

  union all
  select 8, 'pagos ANULADOS/DEVUELTOS en la ventana',
         round(sum(pa.amount - coalesce(pa.change_amount, 0)), 2),
         count(*),
         null,
         'no entran en ningún total de arriba'
  from public.payments pa
  cross join params p
  where pa.business_id = p.bid
    and pa.status in ('cancelled', 'refunded')
    and pa.created_at >= p.desde and pa.created_at < p.hasta

  union all
  select 9, 'ANULADO en la ventana (ítems void)',
         round(sum(oi.subtotal + oi.tax - coalesce(oi.discounts, 0)), 2),
         count(distinct oi.order_id),
         count(*),
         'consumo que se borró; excluido de (1)'
  from public.order_items oi
  join public.orders o on o.id = oi.order_id
  join public.table_sessions ts on ts.id = o.session_id
  cross join params p
  where ts.business_id = p.bid
    and (oi.status = 'void' or o.status_ext = 'void')
    and oi.created_at >= p.desde and oi.created_at < p.hasta

  union all
  select 10, 'ABONOS de mesa recibidos en la ventana',
         round(sum(m.amount), 2),
         count(*),
         null,
         'plata que entró como saldo; se vuelve venta al consumirse'
  from public.table_deposit_movements m
  cross join params p
  where m.business_id = p.bid
    and m.type = 'deposit'
    and m.created_at >= p.desde and m.created_at < p.hasta
) cuadre
order by "#";


-- ############ CONSULTA 2 — detalle, solo si la fila 4 no dio 0 ##############
-- Una fila por orden descuadrada: qué mesa, cuándo, cuánto se consumió,
-- cuánto se cobró y cuánto falta. Córrela SOLA (el editor muestra solo el
-- último resultado).

with params as (
  select
    '6d13ed3f-0fb9-40e3-a695-f4c09759fbfd'::uuid as bid,
    (timestamp '2026-09-19 09:00' at time zone 'America/Santo_Domingo') as desde,
    now() as hasta
),
ordenes as (
  select distinct o.id, o.status_ext, o.session_id
  from public.orders o
  join public.table_sessions ts on ts.id = o.session_id
  join public.order_items oi on oi.order_id = o.id
  cross join params p
  where ts.business_id = p.bid
    and o.status_ext is distinct from 'void'
    and oi.status <> 'void'
    and oi.created_at >= p.desde
    and oi.created_at <  p.hasta
),
consumo as (
  select oi.order_id,
         sum(oi.subtotal + oi.tax - coalesce(oi.discounts, 0)) as neto,
         count(*) as items,
         max(oi.created_at) as ultimo_item
  from public.order_items oi
  join ordenes r on r.id = oi.order_id
  where oi.status <> 'void'
  group by oi.order_id
),
cobrado as (
  select pa.order_id,
         sum(pa.amount - coalesce(pa.change_amount, 0)) as monto,
         count(*) as pagos,
         max(pa.created_at) as ultimo_pago
  from public.payments pa
  join ordenes r on r.id = pa.order_id
  where pa.status = 'completed' or pa.status is null
  group by pa.order_id
)
select
  coalesce(dt.label, dt.code, '(sin mesa)') as mesa,
  r.status_ext                              as estado_orden,
  round(coalesce(c.neto, 0), 2)             as consumo,
  round(coalesce(pg.monto, 0), 2)           as cobrado,
  round(coalesce(c.neto, 0) - coalesce(pg.monto, 0), 2) as falta,
  coalesce(c.items, 0)                      as items,
  coalesce(pg.pagos, 0)                     as pagos,
  (c.ultimo_item  at time zone 'America/Santo_Domingo') as ultimo_item,
  (pg.ultimo_pago at time zone 'America/Santo_Domingo') as ultimo_pago,
  r.id                                      as order_id
from ordenes r
left join consumo c  on c.order_id = r.id
left join cobrado pg on pg.order_id = r.id
left join public.table_sessions ts on ts.id = r.session_id
left join public.dining_tables dt on dt.id = ts.table_id
where r.status_ext = 'paid'
  and round(coalesce(c.neto, 0) - coalesce(pg.monto, 0), 2) <> 0
order by falta desc;


-- ############ CONSULTA 3 — las cuentas ABIERTAS, una por una ###############
-- Responde si la fila (3) del cuadre es "la noche corriendo" o mesas que
-- quedaron abiertas. Mira `horas_sin_actividad`: si son pocas, la mesa está
-- viva; si son muchas, quedó olvidada. `sesion` dice si la mesa del salón
-- sigue ocupada o si la sesión ya se cerró dejando la orden colgando
-- (ese caso es orden huérfana, no mesa viva).

with params as (
  select
    '6d13ed3f-0fb9-40e3-a695-f4c09759fbfd'::uuid as bid,
    (timestamp '2026-09-19 09:00' at time zone 'America/Santo_Domingo') as desde,
    now() as hasta
),
ordenes as (
  select distinct o.id, o.status_ext, o.session_id
  from public.orders o
  join public.table_sessions ts on ts.id = o.session_id
  join public.order_items oi on oi.order_id = o.id
  cross join params p
  where ts.business_id = p.bid
    and o.status_ext is distinct from 'void'
    and oi.status <> 'void'
    and oi.created_at >= p.desde
    and oi.created_at <  p.hasta
),
consumo as (
  select oi.order_id,
         sum(oi.subtotal + oi.tax - coalesce(oi.discounts, 0)) as neto,
         count(*) as items,
         min(oi.created_at) as primer_item,
         max(oi.created_at) as ultimo_item
  from public.order_items oi
  join ordenes r on r.id = oi.order_id
  where oi.status <> 'void'
  group by oi.order_id
),
cobrado as (
  select pa.order_id, sum(pa.amount - coalesce(pa.change_amount, 0)) as monto
  from public.payments pa
  join ordenes r on r.id = pa.order_id
  where pa.status = 'completed' or pa.status is null
  group by pa.order_id
)
select
  coalesce(dt.label, dt.code, '(sin mesa)')                        as mesa,
  r.status_ext                                                     as estado_orden,
  case when ts.closed_at is null then 'mesa ocupada'
       else 'SESIÓN CERRADA (orden huérfana)' end                  as sesion,
  round(coalesce(c.neto, 0) - coalesce(pg.monto, 0), 2)            as pendiente,
  coalesce(c.items, 0)                                             as items,
  (c.primer_item at time zone 'America/Santo_Domingo')             as primer_item,
  (c.ultimo_item at time zone 'America/Santo_Domingo')             as ultimo_item,
  round(extract(epoch from (now() - c.ultimo_item)) / 3600.0, 1)   as horas_sin_actividad,
  round(coalesce(pg.monto, 0), 2)                                  as abonado,
  r.id                                                             as order_id
from ordenes r
left join consumo c  on c.order_id = r.id
left join cobrado pg on pg.order_id = r.id
left join public.table_sessions ts on ts.id = r.session_id
left join public.dining_tables dt on dt.id = ts.table_id
where r.status_ext <> 'paid'
order by pendiente desc;
