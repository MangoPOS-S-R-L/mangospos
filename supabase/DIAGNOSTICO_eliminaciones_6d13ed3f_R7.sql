-- =============================================================================
-- R7 · El efectivo de la caja, calculado a mano · negocio 6d13ed3f
-- =============================================================================
-- Solo lee. UNA sola consulta. Cambiar solo las líneas marcadas con <<<.
--
-- POR QUÉ: para rehacer a mano la cuenta del efectivo y no depender del
-- `difference` que guardó el cierre.
--
-- OJO, ERROR QUE COSTÓ UNA VUELTA (2026-09-20): `cash_transactions` YA trae
-- cada cobro como movimiento de tipo 'sale'. Sumar los pagos MÁS todas las
-- entradas duplica las ventas. Aquí los movimientos de tipo 'sale' se
-- excluyen: solo entran los manuales (deposit/income/withdrawal/expense).
-- Con eso la cuenta dio idéntica a la del cierre de la app — el cierre NO
-- está mal calculado.
--
--   fondo de apertura
--   + pagos EN EFECTIVO de esa sesión
--   + entradas de efectivo registradas
--   − salidas de efectivo registradas (gastos, retiros)
--   = lo que TENÍA que haber en la gaveta
--   vs. lo que el cajero declaró al cerrar (`end_amount`)
--
-- CÓMO LEERLO:
--   diferencia_real ≈ 0   la gaveta cuadró: el dinero de lo borrado NO entró.
--   diferencia_real > 0   SOBRÓ efectivo: entró plata que no está declarada
--                         en las cuentas (es lo que dejaría un producto
--                         servido, cobrado y borrado de la cuenta).
--   diferencia_real < 0   faltó efectivo.
--
-- Compara la diferencia contra el monto borrado esa noche antes de sacar
-- conclusiones: si sobran RD$300 no explica una botella de RD$24,000.
-- =============================================================================

with params as (
  select
    '6d13ed3f-0fb9-40e3-a695-f4c09759fbfd'::uuid as bid,        -- <<< negocio
    timestamptz '2026-09-19 06:00:00-04:00'      as desde,      -- <<< desde
    timestamptz '2026-09-20 12:00:00-04:00'      as hasta       -- <<< hasta
),
sesiones as (
  select
    cs.*,
    coalesce(nullif(pf.full_name, ''), pf.email, left(cs.user_id::text, 8), '—')
      as cajero,
    coalesce(cr.name, 'Caja') as caja
  from public.cash_register_sessions cs
  cross join params p
  join public.cash_registers cr on cr.id = cs.cash_register_id
                               and cr.business_id = p.bid
  left join public.profiles pf  on pf.id = cs.user_id
  where cs.opened_at >= p.desde
    and cs.opened_at <  p.hasta
),
-- Pagos en efectivo de cada sesión. Se toman por `session_id` del pago y, si
-- ese dato no está, por la ventana de la sesión: en una caja con turnos
-- seguidos las dos formas dan lo mismo.
efectivo as (
  select
    s.id,
    coalesce(sum(p2.amount) filter (where pm_efectivo), 0)              as cobrado_efectivo,
    coalesce(sum(coalesce(p2.change_amount, 0)) filter (where pm_efectivo), 0)
                                                                       as devuelto,
    coalesce(sum(p2.amount) filter (where not pm_efectivo), 0)         as cobrado_otros,
    count(p2.id) filter (where pm_efectivo)                            as pagos_efectivo
  from sesiones s
  cross join params par
  left join public.payments p2
         on (p2.status = 'completed' or p2.status is null)
        and p2.business_id = par.bid
        and (
          p2.session_id = s.id
          -- Pago sin sesión anotada: se le asigna por la ventana del turno.
          or (p2.session_id is null
              and p2.created_at >= s.opened_at
              and p2.created_at <  coalesce(s.closed_at, now()))
        )
  left join lateral (
    select (lower(coalesce(pm.code, pm.name, '')) like '%efec%'
            or lower(coalesce(pm.code, pm.name, '')) like '%cash%') as pm_efectivo
    from public.payment_methods pm
    where pm.id = p2.payment_method_id
  ) met on true
  group by s.id
),
movimientos as (
  select
    s.id,
    -- Movimientos MANUALES. Los de tipo 'sale' los escribe el cobro y ya
    -- están contados en `efectivo`: sumarlos otra vez duplica la noche.
    coalesce(sum(ct.amount) filter
             (where ct.type <> 'sale' and ct.amount > 0), 0)  as entradas,
    coalesce(sum(-ct.amount) filter
             (where ct.type <> 'sale' and ct.amount < 0), 0)  as salidas,
    coalesce(sum(ct.amount) filter (where ct.type = 'sale'), 0)
                                                              as ventas_en_caja,
    coalesce(string_agg(distinct ct.type, ', '), '—')         as tipos
  from sesiones s
  left join public.cash_transactions ct on ct.session_id = s.id
  group by s.id
)
select
  to_char(s.opened_at at time zone 'America/Santo_Domingo', 'DD/MM HH24:MI')
    || ' → ' ||
    coalesce(to_char(s.closed_at at time zone 'America/Santo_Domingo',
                     'DD/MM HH24:MI'), 'abierta')            as turno,
  s.caja,
  s.cajero,
  s.start_amount                                             as fondo,
  e.cobrado_efectivo,
  e.devuelto                                                 as cambio_devuelto,
  e.cobrado_otros                                            as cobrado_no_efectivo,
  m.entradas                                                 as entradas_manuales,
  m.salidas                                                  as salidas_manuales,
  m.tipos                                                    as tipos_de_movimiento,
  round(
    s.start_amount + e.cobrado_efectivo - e.devuelto + m.entradas - m.salidas,
    2
  )                                                          as deberia_haber,
  s.end_amount                                               as declaro_el_cajero,
  round(
    coalesce(s.end_amount, 0)
      - (s.start_amount + e.cobrado_efectivo - e.devuelto + m.entradas - m.salidas),
    2
  )                                                          as diferencia_real,
  s.difference                                               as diferencia_que_guardo_el_cierre,
  case
    when s.end_amount is null then 'sin cierre'
    when m.salidas = 0
         and coalesce(s.end_amount, 0)
             < (s.start_amount + e.cobrado_efectivo - e.devuelto) * 0.5
      then 'RETIROS SIN REGISTRAR: la gaveta no sirve de control'
    when abs(coalesce(s.end_amount, 0)
             - (s.start_amount + e.cobrado_efectivo - e.devuelto
                + m.entradas - m.salidas)) < 100 then 'cuadró'
    when coalesce(s.end_amount, 0)
         > (s.start_amount + e.cobrado_efectivo - e.devuelto
            + m.entradas - m.salidas) then 'SOBRÓ efectivo'
    else 'faltó efectivo'
  end                                                        as veredicto
from sesiones s
join efectivo e    on e.id = s.id
join movimientos m on m.id = s.id
order by s.opened_at;
