-- =============================================================================
-- Eliminaciones de cuenta · negocio 6d13ed3f (El Prodigio)
-- Rango: ayer 19-sep 9:00 AM (hora RD) → ahora
-- Fuente: order_item_removals (mig 20260919_0002)
-- El SQL Editor solo muestra el ÚLTIMO resultado → todo en UNA consulta.
-- =============================================================================
with r as (
  select
    r.*,
    round(r.quantity * coalesce(r.unit_price, 0), 2) as valor,
    coalesce(
      nullif(trim(concat_ws(' ', eo.first_name, eo.last_name)), ''),
      nullif(p.full_name, ''),
      p.email,
      left(r.removed_by::text, 8),
      '(no identificado)'
    ) as quien,
    coalesce(nullif(trim(concat_ws(' ', ea.first_name, ea.last_name)), ''), '(sin autor)') as mesero
  from public.order_item_removals r
  left join public.employees eo on eo.id = r.reason_employee_id
  left join public.employees ea on ea.id = r.author_employee_id
  left join public.profiles  p  on p.id  = r.removed_by
  where r.business_id = '6d13ed3f-0fb9-40e3-a695-f4c09759fbfd'
    and r.removed_at >= timestamptz '2026-09-19 09:00:00-04:00'
    and r.removed_at <  now()
)
-- 0 · desde cuándo hay registro (la tabla nació con la migración de ayer)
select
  '0 · COBERTURA'                                                              as bloque,
  'primer registro del negocio'                                                as cuando,
  to_char(min(removed_at) at time zone 'America/Santo_Domingo',
          'DD/MM HH24:MI')                                                     as producto,
  null::numeric                                                                as cant,
  null::numeric                                                                as valor,
  count(*)::text || ' filas en total (todo el histórico)'                      as motivo,
  null::text                                                                   as quien_lo_quito,
  null::text                                                                   as mesero_comanda,
  null::text                                                                   as mesa,
  null::text                                                                   as area,
  null::text                                                                   as tipo
from public.order_item_removals
where business_id = '6d13ed3f-0fb9-40e3-a695-f4c09759fbfd'

union all
-- 1 · resumen del rango
select
  '1 · RESUMEN',
  case
    when not is_user_action then 'reescritura interna (dividir cuenta / RPC)'
    when change_type = 'deleted' then 'BORRADOS de la cuenta'
    else 'REDUCIDOS (le bajaron la cantidad)'
  end,
  count(*)::text || ' línea(s)',
  sum(quantity),
  sum(valor),
  count(*) filter (where reason is not null)::text || ' con motivo',
  count(distinct quien)::text || ' persona(s)',
  null, null, null, null
from r
group by 1, 2

union all
-- 2 · detalle
select
  '2 · DETALLE',
  to_char(removed_at at time zone 'America/Santo_Domingo', 'DD/MM HH24:MI'),
  product_name,
  quantity,
  valor,
  coalesce(reason, '(sin motivo)'),
  quien,
  mesero,
  coalesce(table_name, '—'),
  coalesce(print_area_code, '(sin área)'),
  change_type
    || case when is_user_action then '' else ' · INTERNO' end
    || case when kitchen_sent_at is not null then ' · ya en cocina' else '' end
from r

order by 1, 2, 3;
