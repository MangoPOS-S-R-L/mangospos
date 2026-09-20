-- =============================================================================
-- R6 · ¿Cómo pagaron esas mesas y cuadró la caja? · negocio 6d13ed3f
-- =============================================================================
-- Solo lee. UNA sola consulta. Cambiar solo las líneas marcadas con <<<.
--
-- POR QUÉ: si el trago se sirvió y el cliente lo pagó, el dinero entró. Si la
-- línea se borró de la cuenta, ese dinero no está declarado. Entonces:
--   * PAGO EN EFECTIVO → el efectivo físico sobraría contra lo declarado. Un
--     cierre con SOBRANTE parecido al monto borrado es la señal. Un cierre
--     cuadrado significa que el dinero no entró a la gaveta: o el trago no se
--     sirvió, o el efectivo no llegó a la caja.
--   * PAGO CON TARJETA → el cobro a la tarjeta salió más bajo. El dinero de
--     esa botella nunca existió: se regaló o no se sirvió.
--
-- SECCIONES:
--   1 CUENTA   una fila por borrado sin explicar: cómo se pagó esa cuenta,
--              cuánto y con qué comprobante.
--   2 CAJA     los cierres de caja del período: apertura, cierre, diferencia
--              y quién la tenía. Ahí se ve el sobrante o el faltante.
--
-- OJO: `difference` es lo que la app guardó al cerrar. Si el cierre se hizo
-- sin contar el efectivo de verdad, no prueba nada.
-- =============================================================================

with params as (
  select
    '6d13ed3f-0fb9-40e3-a695-f4c09759fbfd'::uuid as bid,        -- <<< negocio
    timestamptz '2026-09-19 09:00:00-04:00'      as desde,      -- <<< desde
    timestamptz '2026-09-20 12:00:00-04:00'      as hasta       -- <<< hasta
),
quitado as (
  select r.*, round(r.quantity * coalesce(r.unit_price, 0), 2) as valor
  from public.order_item_removals r
  cross join params p
  where r.business_id = p.bid
    and r.removed_at >= p.desde
    and r.is_user_action
    -- Solo lo que quedó sin explicar: no quedó otra línea igual en la orden.
    and not exists (
      select 1 from public.order_items oi
      where oi.order_id = r.order_id
        and oi.product_id is not distinct from r.product_id
        and oi.status::text not in ('draft', 'void')
    )
),
pagos as (
  select
    q.id,
    string_agg(
      coalesce(pm.name, '(sin método)') || ': ' ||
      to_char(p2.amount, 'FM999,999,990.00'),
      ' | ' order by p2.created_at
    )                                   as como_pago,
    sum(p2.amount)                      as total_pagado,
    bool_or(lower(coalesce(pm.code, pm.name, '')) like '%efec%'
            or lower(coalesce(pm.code, pm.name, '')) like '%cash%') as hubo_efectivo
  from quitado q
  join public.payments p2 on p2.order_id = q.order_id
                         and (p2.status = 'completed' or p2.status is null)
  left join public.payment_methods pm on pm.id = p2.payment_method_id
  group by q.id
)
select * from (
  select
    '1 CUENTA'                                                  as seccion,
    to_char(q.removed_at at time zone 'America/Santo_Domingo', 'DD/MM HH24:MI')
                                                                as cuando,
    q.table_name                                                as mesa,
    q.product_name || ' (' || trim_scale(q.quantity) || ')'     as detalle,
    q.valor                                                     as monto_borrado,
    coalesce(pg.total_pagado, 0)                                as cobrado,
    coalesce(pg.como_pago, '(sin pago registrado)')             as como_pago,
    case
      when pg.hubo_efectivo then 'efectivo: mirar el sobrante de caja'
      when pg.id is not null then 'sin efectivo: ese dinero nunca existió'
      else '—'
    end                                                         as que_revisar
  from quitado q
  left join pagos pg on pg.id = q.id

  union all

  select
    '2 CAJA',
    to_char(cs.opened_at at time zone 'America/Santo_Domingo', 'DD/MM HH24:MI')
      || ' → ' ||
      coalesce(to_char(cs.closed_at at time zone 'America/Santo_Domingo',
                       'DD/MM HH24:MI'), 'abierta'),
    coalesce(cr.name, 'Caja'),
    'Cajero: ' || coalesce(nullif(pf.full_name, ''), pf.email,
                           left(cs.user_id::text, 8), '—')
      || ' · ' || coalesce(cs.status, '—'),
    cs.start_amount,
    cs.end_amount,
    'Diferencia: ' || coalesce(to_char(cs.difference, 'FM999,999,990.00'), '—'),
    case
      when cs.difference > 0 then 'SOBRANTE: entró efectivo no declarado'
      when cs.difference < 0 then 'faltante'
      else 'cuadró'
    end
  from public.cash_register_sessions cs
  cross join params p
  join public.cash_registers cr on cr.id = cs.cash_register_id
                               and cr.business_id = p.bid
  left join public.profiles pf on pf.id = cs.user_id
  where cs.opened_at >= p.desde - interval '12 hours'
    and cs.opened_at <  p.hasta
) x
order by seccion, cuando;
