-- =============================================================================
-- DIAGNÓSTICO — ¿Una comanda se imprimió varias veces (en segundos)?
-- =============================================================================
-- Solo lee. Es UNA sola consulta (el SQL Editor muestra solo el último
-- resultado). Cambiar solo las líneas marcadas con <<<.
--
-- QUÉ MIRA: la cola de impresión del servidor (`print_jobs`). Dos trabajos
-- con EL MISMO contenido son el mismo papel impreso dos veces.
--
-- OJO, LO QUE NO CUBRE: la app imprime DIRECTO a la impresora (red, USB o
-- Bluetooth) y solo encola en el servidor cuando ese camino falla, o cuando
-- la comanda la genera el servidor al enviar a cocina. Si la sección 1 sale
-- vacía, este negocio imprime todo directo y aquí no hay nada que ver: para
-- contar TODAS las impresiones hay que registrar cada una (no existe hoy).
--
-- SECCIONES DEL RESULTADO:
--   1 RESUMEN        cuántos trabajos por tipo y estado en el rango.
--   2 REPETIDAS      mismo contenido enviado más de una vez: cuántas veces,
--                    primera y última, y los segundos entre ambas. Segundos
--                    en 0–60 con 2 o 3 veces = el mismo papel repetido.
--   3 REINTENTOS     trabajos que la cola reintentó (attempts > 1). Cada
--                    reintento puede haber sacado papel aunque el primero
--                    sí hubiera salido.
--
-- Las columnas nuevas de print_jobs (kind, attempts, idempotency_key) se
-- leen de forma tolerante: si el servidor no las tiene, salen vacías en vez
-- de romper la consulta.
-- =============================================================================

with params as (
  select
    '6d13ed3f-0fb9-40e3-a695-f4c09759fbfd'::uuid as bid,  -- <<< negocio
    date '2026-09-12' as desde,                           -- <<< primer día
    date '2026-09-19' as hasta                            -- <<< último día
),
rango as (
  select
    bid,
    (desde::timestamp at time zone 'America/Santo_Domingo')       as t0,
    ((hasta + 1)::timestamp at time zone 'America/Santo_Domingo') as t1
  from params
),
jobs as (
  select
    j.id,
    j.created_at,
    j.status,
    j.ip,
    coalesce(to_jsonb(j) ->> 'kind', '(sin tipo)')       as kind,
    to_jsonb(j) ->> 'area_code'                          as area,
    coalesce((to_jsonb(j) ->> 'attempts')::int, 0)       as attempts,
    to_jsonb(j) ->> 'idempotency_key'                    as idem,
    md5(coalesce(j.data_hex, ''))                        as huella,
    -- Las primeras líneas legibles del ticket (mesa, orden, productos).
    -- `encode(..., 'escape')` en vez de convert_from: el ticket trae bytes
    -- de control ESC/POS (0x00 entre ellos) que no son texto válido en
    -- ninguna codificación y reventaban la consulta (22021). Aquí salen
    -- como \ooo y se cambian por espacios.
    left(
      trim(
        regexp_replace(
          regexp_replace(
            case
              when j.data_hex ~ '^([0-9a-fA-F]{2})+$'
                then encode(decode(left(j.data_hex, 1200), 'hex'), 'escape')
              else ''
            end,
            '\\[0-7]{3}|\\\\|[^[:print:]\n]', ' ', 'g'),
          '\s*\n\s*|\s{2,}', ' | ', 'g')
      ),
      110
    )                                                    as ticket
  from public.print_jobs j
  cross join rango r
  where j.business_id = r.bid
    and j.created_at >= r.t0
    and j.created_at <  r.t1
)
select * from (
  -- 1. Qué hay en la cola.
  select
    '1 RESUMEN'                                          as seccion,
    kind || ' · ' || status                              as detalle,
    count(*)                                             as veces,
    to_char(min(created_at) at time zone 'America/Santo_Domingo',
            'DD/MM HH24:MI:SS')                          as primera,
    to_char(max(created_at) at time zone 'America/Santo_Domingo',
            'DD/MM HH24:MI:SS')                          as ultima,
    null::numeric                                        as segundos,
    null::text                                           as ip
  from jobs
  group by kind, status

  union all

  -- 2. Mismo contenido, más de un envío: el mismo papel repetido.
  select
    '2 REPETIDAS',
    coalesce(nullif(ticket, ''), '(sin contenido legible)'),
    count(*),
    to_char(min(created_at) at time zone 'America/Santo_Domingo',
            'DD/MM HH24:MI:SS'),
    to_char(max(created_at) at time zone 'America/Santo_Domingo',
            'DD/MM HH24:MI:SS'),
    round(extract(epoch from (max(created_at) - min(created_at)))::numeric, 1),
    string_agg(distinct ip, ', ')
  from jobs
  group by huella, ticket
  having count(*) > 1

  union all

  -- 3. Reintentos de la cola: cada uno pudo sacar papel.
  select
    '3 REINTENTOS',
    coalesce(nullif(ticket, ''), '(sin contenido legible)')
      || ' · intentos: ' || attempts || ' · ' || status,
    1,
    to_char(created_at at time zone 'America/Santo_Domingo',
            'DD/MM HH24:MI:SS'),
    null,
    null,
    ip
  from jobs
  where attempts > 1
) x
order by seccion, veces desc, primera;
