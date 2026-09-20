-- =============================================================================
-- DIAGNÓSTICO — Comandas vs. cobrado (una sola fila)
-- =============================================================================
-- Para cuadrar el comparador del reporte de Comandas contra el reporte de
-- Ventas de UN día. Cambiar solo las dos líneas marcadas con <<<.
-- Solo lee. El SQL Editor muestra solo el último resultado: es una sola
-- consulta.
--
-- Columnas:
--   ventas_productos        lo que el reporte de Ventas muestra como productos
--                           cobrados (órdenes con pago en el día, sin anulados)
--   enviados_con_marca      productos con marca de envío a cocina en el día
--   partidas_sin_marca      filas creadas al DIVIDIR la cuenta: no traen la
--                           marca (el reporte nuevo las hereda del original)
--   venta_rapida_sin_marca  venta rápida cobrada en el día: la comanda sale
--                           al cobrar y no se marca (el reporte nuevo la cuenta)
--   enviado_total           enviados_con_marca + partidas + venta rápida
--   cobrado                 de lo enviado, lo que quedó en factura (incluye
--                           cortesías y lo cobrado a 0)
--   cortesia                de lo cobrado, lo que fue cortesía (aunque la
--                           cuenta siga abierta)
--   cobrado_a_0             de lo cobrado, lo que no tenía nada que cobrar
--                           (precio 0 o gratis por promoción)
--   pendiente_mesa_abierta  enviado, sin cobrar, con la orden y la mesa abiertas
--   sin_cobrar              enviado, sin cobrar, con la orden cobrada sin ese
--                           producto o la mesa cerrada (huérfana)
--   anulado_despues         producto anulado u orden anulada (va aparte)
--   cobrado_sin_comanda     productos cobrados en el día (fecha del pago, como
--                           Ventas) que nunca pasaron por cocina
--
-- Lo anulado, la cortesía y lo cobrado a 0 NUNCA cuentan como pendiente ni
-- sin cobrar. Lo eliminado a propósito se borra y no aparece.
-- =============================================================================

with params as (
  select
    '00000000-0000-0000-0000-000000000000'::uuid as bid,   -- <<< id del negocio
    date '2026-09-19' as dia                               -- <<< día a revisar
),
rango as (
  select
    bid,
    (dia::timestamp at time zone 'America/Santo_Domingo') as t0,
    ((dia + 1)::timestamp at time zone 'America/Santo_Domingo') as t1
  from params
),
cocina as (
  select coalesce(
    (select bs.kitchen_enabled from public.business_settings bs, rango r
      where bs.business_id = r.bid limit 1),
    true) as activa
),
-- Igual que get_sales_summary_v2: órdenes con pago completado en el día.
ventas as (
  select coalesce(sum(coalesce(nullif(oi.qty, 0), oi.quantity, 0)), 0) as productos
  from public.order_items oi, rango r
  where oi.business_id = r.bid
    and oi.status::text <> 'void'
    and oi.order_id in (
      select p.order_id from public.payments p
      where p.business_id = r.bid
        and p.created_at >= r.t0 and p.created_at < r.t1
        and (p.status = 'completed' or p.status is null)
        and p.order_id is not null
    )
),
-- Cobrado sin comanda: pagado en el día y nunca enviado a cocina (sin
-- marca, sin heredarla de una cuenta dividida y sin ser venta rápida con la
-- cocina activada).
sin_comanda as (
  select coalesce(sum(coalesce(nullif(oi.qty, 0), oi.quantity)), 0) as productos
  from public.order_items oi
  join public.orders o          on o.id = oi.order_id
  join public.table_sessions ts on ts.id = o.session_id
  cross join rango r
  cross join cocina c
  where o.business_id = r.bid
    and oi.status::text = 'paid'
    and oi.kitchen_sent_at is null
    and not exists (
      select 1 from public.order_items s
      where s.order_id = oi.order_id
        and s.kitchen_sent_at is not null
        and s.product_id is not distinct from oi.product_id
        and s.created_at = oi.created_at
    )
    and not (c.activa and ts.origin::text in ('quick', 'quick_sale'))
    and oi.order_id in (
      select p.order_id from public.payments p
      where p.created_at >= r.t0 and p.created_at < r.t1
        and (p.status = 'completed' or p.status is null)
        and p.order_id is not null
    )
),
ordenes as (
  select distinct oi.order_id
  from public.order_items oi
  join public.orders o on o.id = oi.order_id
  cross join rango r
  where o.business_id = r.bid
    and o.created_at < r.t1
    and oi.kitchen_sent_at >= r.t0 and oi.kitchen_sent_at < r.t1
  union
  select o.id
  from public.orders o
  join public.table_sessions ts on ts.id = o.session_id
  cross join rango r
  cross join cocina c
  where c.activa
    and o.business_id = r.bid
    and ts.origin::text in ('quick', 'quick_sale')
    and o.closed_at >= r.t0 and o.closed_at < r.t1
),
items as (
  select
    oi.id,
    oi.status::text as status,
    coalesce(nullif(oi.qty, 0), oi.quantity::numeric, 1) as cant,
    oi.notes, oi.unit_price, oi.subtotal, oi.tax, oi.discounts, oi.total,
    exists (
      select 1 from public.order_item_modifiers m
      where m.item_id = oi.id and coalesce(m.price, 0) > 0
    ) as mods_con_precio,
    -- status_ext manda: anular a veces deja status = 'open' con ext 'void'.
    case
      when o.status_ext::text = 'void' then 'canceled'
      when o.status_ext::text = 'paid' then 'paid'
      else o.status::text
    end as o_status,
    o.closed_at as o_closed, ts.closed_at as ts_closed,
    case
      when oi.kitchen_sent_at is not null then 'marca'
      when exists (
        select 1 from public.order_items s
        where s.order_id = oi.order_id
          and s.kitchen_sent_at is not null
          and s.product_id is not distinct from oi.product_id
          and s.created_at = oi.created_at
      ) then 'partida'
      when ts.origin::text in ('quick', 'quick_sale') and oi.status::text = 'paid'
        then 'rapida'
    end as origen,
    coalesce(
      oi.kitchen_sent_at,
      (select min(s.kitchen_sent_at) from public.order_items s
        where s.order_id = oi.order_id
          and s.kitchen_sent_at is not null
          and s.product_id is not distinct from oi.product_id
          and s.created_at = oi.created_at),
      case when ts.origin::text in ('quick', 'quick_sale')
                and oi.status::text = 'paid' then o.closed_at end
    ) as enviado_en
  from ordenes x
  join public.order_items oi    on oi.order_id = x.order_id
  join public.orders o          on o.id = oi.order_id
  join public.table_sessions ts on ts.id = o.session_id
  where oi.status::text <> 'draft'
),
marcados as (
  select i.*,
    (
      coalesce(i.notes, '') like '%[CORTESIA:%'
      or (
        coalesce(i.notes, '') not like '%[PROMO_AUTO:%'
        and coalesce(i.notes, '') not like '%[DEAL:%'
        and coalesce(i.unit_price, 0) > 0
        and (
          (coalesce(i.subtotal, 0) + coalesce(i.tax, 0) > 0
           and coalesce(i.discounts, 0)
               >= coalesce(i.subtotal, 0) + coalesce(i.tax, 0) - 0.01)
          or coalesce(i.total, 1) <= 0.01
        )
      )
    ) as es_cortesia,
    (
      (coalesce(i.unit_price, 0) <= 0 and not i.mods_con_precio)
      or (
        coalesce(i.unit_price, 0) * i.cant > 0
        and coalesce(i.discounts, 0) >= coalesce(i.unit_price, 0) * i.cant - 0.01
      )
    ) as es_a_0
  from items i, rango r
  where i.enviado_en >= r.t0 and i.enviado_en < r.t1
),
enviados as (
  select m.*,
    case
      when m.status = 'void' or m.o_status = 'canceled' then 'anulado'
      when m.es_cortesia then 'cortesia'
      when m.es_a_0 then 'a_0'
      when m.status = 'paid' then 'cobrado'
      when m.o_closed is null and m.o_status not in ('paid', 'canceled')
           and m.ts_closed is null then 'pendiente'
      else 'sin_cobrar'
    end as estado
  from marcados m
)
select
  (select productos from ventas) as ventas_productos,
  coalesce(sum(cant) filter (where origen = 'marca'   and estado <> 'anulado'), 0) as enviados_con_marca,
  coalesce(sum(cant) filter (where origen = 'partida' and estado <> 'anulado'), 0) as partidas_sin_marca,
  coalesce(sum(cant) filter (where origen = 'rapida'  and estado <> 'anulado'), 0) as venta_rapida_sin_marca,
  coalesce(sum(cant) filter (where estado <> 'anulado'), 0)                         as enviado_total,
  coalesce(sum(cant) filter (where estado in ('cobrado', 'cortesia', 'a_0')), 0)   as cobrado,
  coalesce(sum(cant) filter (where estado = 'cortesia'), 0)                         as cortesia,
  coalesce(sum(cant) filter (where estado = 'a_0'), 0)                              as cobrado_a_0,
  coalesce(sum(cant) filter (where estado = 'pendiente'), 0)                        as pendiente_mesa_abierta,
  coalesce(sum(cant) filter (where estado = 'sin_cobrar'), 0)                       as sin_cobrar,
  coalesce(sum(cant) filter (where estado = 'anulado'), 0)                          as anulado_despues,
  (select productos from sin_comanda)                                               as cobrado_sin_comanda
from enviados;
