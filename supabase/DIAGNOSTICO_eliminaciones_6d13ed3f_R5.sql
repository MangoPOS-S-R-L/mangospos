-- =============================================================================
-- R5 · ¿QUIÉN? — todas las personas alrededor de cada borrado · negocio 6d13ed3f
-- =============================================================================
-- Solo lee. UNA sola consulta. Cambiar solo las líneas marcadas con <<<.
--
-- LO PRIMERO, PARA NO ACUSAR A NADIE POR ERROR:
--   `cuenta_tablet` NO es quien borró. Es la cuenta de Supabase con la que
--   está logueada la tablet (`removed_by` → profiles). Si el negocio usa una
--   sola cuenta en todas las tablets, ese nombre sale en TODO y no señala a
--   nadie. El nombre real (el del PIN que autoriza el borrado) se guarda en
--   `reason_employee_id`, y hoy viene vacío porque falta desplegar el arreglo
--   de la app (`noteItemRemoval`).
--
-- LO QUE SÍ SE SABE HOY — quién estaba en esa mesa:
--   digito_el_producto  el mesero que metió la línea que después se borró
--                       (`author_employee_id`, el mismo "MESERO:" que sale
--                       impreso en la comanda).
--   abrio_la_mesa       quién abrió la cuenta.
--   otros_meseros       todos los que digitaron algo más en esa misma orden.
--   cobro               quién procesó el pago.
--
-- CÓMO USARLO: no prueba quién borró. Acota a quién preguntarle, con mesa,
-- hora y producto en la mano.
-- =============================================================================

with params as (
  select
    '6d13ed3f-0fb9-40e3-a695-f4c09759fbfd'::uuid as bid,     -- <<< negocio
    timestamptz '2026-09-19 09:00:00-04:00'      as desde    -- <<< desde
),
quitado as (
  select
    r.*,
    round(r.quantity * coalesce(r.unit_price, 0), 2) as valor,
    coalesce(r.session_id, o.session_id)             as sesion
  from public.order_item_removals r
  cross join params p
  left join public.orders o on o.id = r.order_id
  where r.business_id = p.bid
    and r.removed_at >= p.desde
    and r.is_user_action
),
otros as (
  -- Quién más digitó en esa orden (sin repetir el autor de la línea borrada).
  select
    q.id,
    string_agg(distinct nullif(trim(concat_ws(' ', e.first_name, e.last_name)), ''), ', ')
      as meseros
  from quitado q
  join public.order_items oi on oi.order_id = q.order_id
  join public.employees e    on e.id = oi.created_by_employee_id
  where e.id is distinct from q.author_employee_id
  group by q.id
),
cobro as (
  select
    q.id,
    string_agg(
      distinct coalesce(nullif(pf.full_name, ''), pf.email, left(p2.processed_by::text, 8)),
      ', '
    ) as quien_cobro
  from quitado q
  join public.payments p2      on p2.order_id = q.order_id
                              and (p2.status = 'completed' or p2.status is null)
  left join public.profiles pf on pf.id = p2.processed_by
  group by q.id
)
select
  to_char(q.removed_at at time zone 'America/Santo_Domingo', 'DD/MM HH24:MI')
                                                              as cuando,
  q.table_name                                                as mesa,
  q.product_name                                              as producto,
  trim_scale(q.quantity)                                      as cant,
  q.valor,
  coalesce(
    nullif(trim(concat_ws(' ', ea.first_name, ea.last_name)), ''),
    '(la línea no tenía autor)'
  )                                                           as digito_el_producto,
  coalesce(
    nullif(trim(concat_ws(' ', eo.first_name, eo.last_name)), ''),
    nullif(trim(pw.full_name), ''),
    '—'
  )                                                           as abrio_la_mesa,
  coalesce(o.meseros, '—')                                    as otros_meseros,
  coalesce(c.quien_cobro, '—')                                as cobro,
  coalesce(
    nullif(pr.full_name, ''), pr.email,
    left(q.removed_by::text, 8), '(sin cuenta)'
  )                                                           as cuenta_tablet,
  coalesce(
    nullif(trim(concat_ws(' ', er.first_name, er.last_name)), ''),
    '(falta desplegar el motivo/PIN)'
  )                                                           as quien_borro_con_pin,
  coalesce(q.reason, '(sin motivo)')                          as motivo
from quitado q
left join public.employees ea      on ea.id = q.author_employee_id
left join public.employees er      on er.id = q.reason_employee_id
left join public.profiles  pr      on pr.id = q.removed_by
left join public.table_sessions ts on ts.id = q.sesion
left join public.employees eo      on eo.id = ts.opened_by_employee_id
left join public.profiles  pw      on pw.id = ts.waiter_user_id
left join otros o                  on o.id = q.id
left join cobro c                  on c.id = q.id
order by q.valor desc, q.removed_at;
