-- =============================================================================
-- DIAGNÓSTICO — Historial de impresión de UNA mesa vs. el resto de su zona
-- =============================================================================
-- Solo lee. UNA sola consulta. Cambiar solo las líneas marcadas con <<<.
--
-- POR QUÉ: si la mesa no tiene cuenta abierta, no hay nada vivo que mirar.
-- Pero cada cuenta cerrada deja su rastro:
--   * cada producto que salió a cocina tiene su marca `kitchen_sent_at`
--     (sin marca = la comanda nunca se mandó);
--   * la sesión guarda cuándo se imprimió la precuenta;
--   * la orden cobrada tiene su comprobante.
-- Si ESA mesa tiene productos sin enviar o precuentas sin imprimir y las
-- demás de la zona no, el problema es de esa mesa (o de quien la atiende).
--
-- Una fila por cuenta de la mesa en los últimos días, y al final una fila
-- de comparación con el resto de las mesas de la misma zona.
-- =============================================================================
with params as (
  select
    '6d13ed3f-0fb9-40e3-a695-f4c09759fbfd'::uuid as bid,     -- <<< negocio
    '2'                                          as numero,  -- <<< número de mesa
    7                                            as dias     -- <<< días hacia atrás
),
mesa as (
  select dt.id, dt.zone_id, coalesce(dt.label, dt.code) as nombre
  from public.dining_tables dt
  join public.zones z on z.id = dt.zone_id
  cross join params p
  where z.business_id = p.bid
    and (
      coalesce(dt.label, '') ~* ('(^|[^0-9])0*' || p.numero || '$')
      or coalesce(dt.code, '') ~* ('(^|[^0-9])0*' || p.numero || '$')
    )
  limit 1
),
cuentas as (
  select
    ts.id                                                      as sesion,
    ts.table_id,
    ts.opened_at,
    ts.closed_at,
    nullif(to_jsonb(ts) ->> 'precheck_printed_at', '')::timestamptz as precuenta_en,
    count(distinct o.id)                                       as ordenes,
    count(oi.id) filter (where oi.status::text <> 'void')      as productos,
    count(oi.id) filter (where oi.status::text not in ('void', 'draft')
                           and oi.kitchen_sent_at is not null) as enviados,
    count(oi.id) filter (where oi.status::text not in ('void', 'draft', 'paid')
                           and oi.kitchen_sent_at is null)     as sin_enviar,
    count(oi.id) filter (where oi.status::text = 'draft')      as en_borrador,
    bool_or(o.status_ext::text = 'paid' or o.status = 'paid')  as cobrada,
    count(distinct fd.id)                                      as comprobantes
  from public.table_sessions ts
  join public.dining_tables dt       on dt.id = ts.table_id
  cross join params p
  left join public.orders o          on o.session_id = ts.id
  left join public.order_items oi    on oi.order_id = o.id
  left join public.fiscal_documents fd on fd.order_id = o.id
  where dt.zone_id = (select zone_id from mesa)
    and ts.opened_at > now() - make_interval(days => p.dias)
  group by ts.id, ts.table_id, ts.opened_at, ts.closed_at, to_jsonb(ts)
)
select * from (
  -- Cada cuenta de la mesa elegida.
  select
    1                                                          as orden,
    (select nombre from mesa)                                  as mesa,
    to_char(c.opened_at at time zone 'America/Santo_Domingo', 'DD/MM HH24:MI')
      || ' → ' ||
      coalesce(to_char(c.closed_at at time zone 'America/Santo_Domingo', 'HH24:MI'), 'abierta')
                                                               as cuenta,
    c.productos,
    c.enviados                                                 as a_cocina,
    c.sin_enviar,
    c.en_borrador,
    case when c.precuenta_en is not null then 'sí' else 'no' end as precuenta,
    case when c.cobrada then 'sí' else 'no' end                as cobrada,
    c.comprobantes,
    case
      when c.sin_enviar > 0 then 'PRODUCTOS QUE NUNCA SALIERON A COCINA'
      when c.en_borrador > 0 and c.closed_at is not null then 'se cerró con productos sin enviar'
      when c.productos = 0 then 'cuenta vacía'
      else 'ok'
    end                                                        as alerta
  from cuentas c
  where c.table_id = (select id from mesa)

  union all

  -- Comparación: el resto de las mesas de la zona, sumadas.
  select
    2,
    'RESTO DE LA ZONA',
    count(*) || ' cuentas',
    sum(c.productos)::bigint,
    sum(c.enviados)::bigint,
    sum(c.sin_enviar)::bigint,
    sum(c.en_borrador)::bigint,
    round(100.0 * count(*) filter (where c.precuenta_en is not null)
          / nullif(count(*), 0)) || '% con precuenta',
    round(100.0 * count(*) filter (where c.cobrada)
          / nullif(count(*), 0)) || '% cobradas',
    sum(c.comprobantes)::bigint,
    'para comparar'
  from cuentas c
  where c.table_id <> (select id from mesa)
) x
order by orden, cuenta desc;
