-- DIAGNOSTICO_itbis_tax_rate.sql
-- Hipotesis a confirmar o descartar.
--
-- fn_recompute_fd_for_scope (mig 20260610_0001) reparte order_items.tax entre ITBIS y LEY
-- comparando oi.tax_rate contra las tasas del negocio, con tolerancia de 0.5:
--     tax_rate ~ 28 (18+10) -> reparte proporcional
--     tax_rate ~ 18         -> todo ITBIS
--     tax_rate ~ 10         -> todo LEY
--     cualquier otra cosa   -> ELSE 0   <-- el ITBIS se pierde aunque oi.tax traiga dinero
--
-- Si las ordenes sub-declaradas tienen tax_rate fuera de esos valores, esa es la causa.
-- Solo lee. Devuelve UNA sola tabla.

with b as (select '35c5076a-bd85-4a1b-8d1c-ce719c4f9ae6'::uuid as id),
tasas as (
  select
    max(rate) filter (where upper(name) like '%ITBIS%') as itbis,
    max(rate) filter (where upper(name) like '%LEY%')   as ley
  from public.taxes t, b
  where t.business_id = b.id and coalesce(t.is_active, true)
    and not coalesce(t.is_service_fee, false)
),
docs as (
  select d.order_id, sum(coalesce(d.itbis_amount,0)) as declarado
  from public.fiscal_documents d, b
  where d.business_id = b.id and d.status = 'active' and d.order_id is not null
  group by d.order_id
),
lineas as (
  select oi.order_id,
         sum(coalesce(tl.amount,0)) filter (where upper(tl.tax_name) like '%ITBIS%') as calculado
  from public.order_items oi
  join docs on docs.order_id = oi.order_id
  left join public.order_item_tax_lines tl on tl.order_item_id = oi.id
  group by oi.order_id
),
cmp as (
  select d.order_id, d.declarado, coalesce(l.calculado,0) as calculado,
         coalesce(l.calculado,0) - d.declarado as faltante
  from docs d left join lineas l on l.order_id = d.order_id
),
items as (
  select c.faltante > 1 as afectada,
         coalesce(oi.tax_rate, 0) as tax_rate,
         coalesce(oi.tax, 0)      as tax,
         oi.tax_mode
  from cmp c
  join public.order_items oi on oi.order_id = c.order_id
  where oi.status <> 'void'
)
select n, seccion, detalle from (

  select 0 as n, 'TASAS DEL NEGOCIO' as seccion,
         'ITBIS=' || coalesce(itbis::text,'?') || '  LEY=' || coalesce(ley::text,'?') ||
         '  =>  la funcion solo reconoce tax_rate ~' || coalesce((itbis+ley)::text,'?') ||
         ', ~' || coalesce(itbis::text,'?') || ' o ~' || coalesce(ley::text,'?') as detalle
  from tasas

  union all
  select 1, 'ORDENES SUB-DECLARADAS  tax_rate=' || i.tax_rate,
         count(*) || ' items, RD$ ' || round(sum(i.tax),2) || ' de impuesto cobrado  ->  ' ||
         case
           when t.itbis is null then 'sin tasa ITBIS configurada'
           when abs(i.tax_rate - coalesce(t.itbis+t.ley, -999)) < 0.5 then 'reparte ITBIS+LEY  OK'
           when abs(i.tax_rate - t.itbis) < 0.5                       then 'todo ITBIS  OK'
           when abs(i.tax_rate - coalesce(t.ley,-999)) < 0.5          then 'todo LEY (ITBIS 0 correcto)'
           else '*** CAE EN EL ELSE -> ITBIS 0 ***'
         end
  from items i, tasas t
  where i.afectada
  group by i.tax_rate, t.itbis, t.ley

  union all
  select 2, 'ORDENES QUE CUADRAN  tax_rate=' || i.tax_rate,
         count(*) || ' items, RD$ ' || round(sum(i.tax),2) || ' de impuesto cobrado'
  from items i
  where not i.afectada
  group by i.tax_rate

  union all
  select 3, 'MODO DE IMPUESTO  ' || coalesce(i.tax_mode,'(nulo)'),
         'afectadas: ' || count(*) filter (where i.afectada) ||
         '   cuadran: ' || count(*) filter (where not i.afectada)
  from items i
  group by i.tax_mode
) t
order by n, seccion;
