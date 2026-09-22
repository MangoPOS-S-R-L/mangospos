-- =============================================================================
-- DIAGNÓSTICO — ¿De qué mesa son los trabajos atascados en la cola?
-- =============================================================================
-- Solo lee. UNA sola consulta. Cambiar solo la línea marcada con <<<.
--
-- Lista TODO lo que quedó sin imprimir en la cola del servidor (pending o
-- failed) y lee el propio ticket para sacar la mesa y la orden: el trabajo
-- no guarda la mesa en una columna, pero el papel sí la lleva impresa.
-- Si varias filas son de la MISMA mesa, esa mesa tiene un problema propio.
-- =============================================================================
with params as (
  select '6d13ed3f-0fb9-40e3-a695-f4c09759fbfd'::uuid as bid   -- <<< negocio
)
select
  to_char(j.created_at at time zone 'America/Santo_Domingo', 'DD/MM HH24:MI')
                                                          as creado,
  coalesce(to_jsonb(j) ->> 'kind', '(sin tipo)')          as tipo,
  j.status                                                as estado,
  coalesce((to_jsonb(j) ->> 'attempts')::int, 0)          as intentos,
  j.ip,
  coalesce(nullif(j.error, ''), '—')                      as error,
  -- Las primeras líneas legibles del ticket: ahí está la mesa.
  left(
    trim(regexp_replace(regexp_replace(
      case
        when j.data_hex ~ '^([0-9a-fA-F]{2})+$'
          then encode(decode(left(j.data_hex, 1600), 'hex'), 'escape')
        else ''
      end,
      '\\[0-7]{3}|\\\\|[^[:print:]\n]', ' ', 'g'),
      '\s*\n\s*|\s{2,}', ' | ', 'g')),
    160
  )                                                       as ticket
from public.print_jobs j
cross join params p
where j.business_id = p.bid
  and j.status not in ('done', 'printed', 'completed', 'cancelled')
order by j.created_at desc
limit 50;
