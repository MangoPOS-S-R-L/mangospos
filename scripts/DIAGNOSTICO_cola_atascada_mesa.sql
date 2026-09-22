-- =============================================================================
-- DIAGNÓSTICO — Trabajos atascados: ¿de qué MESA, a qué IMPRESORA, desde qué
-- TABLET?
-- =============================================================================
-- Solo lee. UNA sola consulta. Cambiar solo la línea marcada con <<<.
--
-- POR QUÉ: la precuenta se imprime como IMAGEN, así que el texto del ticket
-- no deja leer la mesa. Pero la clave de cada trabajo lleva el número de la
-- orden ('print-precheck-<orden>-<impresora>', y la comanda la suya): de ahí
-- sale la mesa. Y la impresora + la tablet de destino dicen si el problema es
-- de UNA mesa o de UN aparato: si todo lo atascado va a la misma impresora
-- Bluetooth/USB, lo que falla es ese aparato, no la mesa.
--
-- IP 0.0.0.0 = impresora sin dirección de red (USB o Bluetooth). La cola del
-- servidor solo imprime por red: esos trabajos NUNCA van a salir solos.
-- =============================================================================
with params as (
  select '6d13ed3f-0fb9-40e3-a695-f4c09759fbfd'::uuid as bid   -- <<< negocio
),
jobs as (
  select
    j.*,
    to_jsonb(j) ->> 'idempotency_key'                         as idem,
    -- La columna printer_id a veces viene vacía; la impresora también es
    -- la ÚLTIMA uuid de la clave ('...-<orden>-<impresora>').
    coalesce(
      nullif(to_jsonb(j) ->> 'printer_id', '')::uuid,
      (regexp_match(
         coalesce(to_jsonb(j) ->> 'idempotency_key', ''),
         '-([0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12})$'
       ))[1]::uuid
    )                                                         as printer_ref,
    to_jsonb(j) ->> 'target_device_id'                        as device,
    -- La PRIMERA uuid de la clave es la orden.
    (regexp_match(
       coalesce(to_jsonb(j) ->> 'idempotency_key', ''),
       '([0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12})'
     ))[1]::uuid                                              as orden_id
  from public.print_jobs j
  cross join params p
  where j.business_id = p.bid
    and j.status not in ('done', 'printed', 'completed', 'cancelled')
)
select
  to_char(j.created_at at time zone 'America/Santo_Domingo', 'DD/MM HH24:MI')
                                                         as creado,
  coalesce(to_jsonb(j) ->> 'kind', '(sin tipo)')         as tipo,
  j.status                                               as estado,
  coalesce(dt.label, dt.code,
           case when ts.origin::text in ('quick', 'quick_sale') then 'Venta rápida' end,
           '—')                                          as mesa,
  coalesce(upper(left(j.orden_id::text, 8)), '—')        as orden,
  coalesce(pr.name, '(impresora no encontrada)')         as impresora,
  coalesce(to_jsonb(pr) ->> 'type', '—')                 as tipo_impresora,
  coalesce(nullif(to_jsonb(pr) ->> 'ip_address', ''),
           nullif(to_jsonb(pr) ->> 'ip', ''), j.ip)      as ip,
  coalesce(j.device, '—')                                as tablet_destino,
  coalesce(j.idem, '—')                                  as clave
from jobs j
left join public.orders o          on o.id = j.orden_id
left join public.table_sessions ts on ts.id = o.session_id
left join public.dining_tables dt  on dt.id = ts.table_id
left join public.printers pr       on pr.id = j.printer_ref
order by j.created_at desc
limit 50;
