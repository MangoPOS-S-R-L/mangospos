-- DIAGNOSTICO_itbis_causa.sql
-- LA PENDA EXPRESS: 3.672 de 10.851 facturas activas (33,8%) salen con ITBIS = 0, por
-- RD$ 6.089.497,56. NINGUNA se explica por exclusion del cajero ni por exencion.
--
-- Y la causa que sospechabamos queda DESCARTADA por los numeros: solo 77 de 2.648 productos
-- (2,9%) no tienen impuesto vinculado, y entre todos suman ~130 lineas vendidas. No pueden
-- explicar 3.672 facturas.
--
-- LA PREGUNTA QUE IMPORTA: ¿la venta COBRO el ITBIS y el documento fiscal lo declara en 0?
-- Si es asi, el cliente pago el impuesto y a la DGII se le declara cero. Es muy distinto de
-- "no se cobro", que solo seria una venta sin impuesto.
--
-- order_item_tax_lines guarda el impuesto calculado POR LINEA, asi que es la fuente fiable.
-- Se cuenta por ORDEN distinta para no multiplicar cuando una orden tiene varias subcuentas
-- y por tanto varios documentos fiscales.
-- Solo lee. Devuelve UNA sola tabla.

with b as (select '35c5076a-bd85-4a1b-8d1c-ce719c4f9ae6'::uuid as id),
-- ordenes cuyas facturas activas declaran ITBIS 0
ord_cero as (
  select distinct d.order_id
  from public.fiscal_documents d, b
  where d.business_id = b.id and d.status = 'active'
    and coalesce(d.itbis_amount,0) = 0
    and d.order_id is not null
),
-- ITBIS realmente calculado en las lineas de esas ordenes
calc as (
  select oc.order_id,
         coalesce(sum(tl.amount) filter (where upper(tl.tax_name) like '%ITBIS%'), 0) as itbis_lineas
  from ord_cero oc
  join public.order_items oi on oi.order_id = oc.order_id
  left join public.order_item_tax_lines tl on tl.order_item_id = oi.id
  group by oc.order_id
),
mes as (
  select date_trunc('month', d.issued_at at time zone 'America/Santo_Domingo')::date as m,
         count(*) as docs,
         count(*) filter (where coalesce(d.itbis_amount,0) = 0) as en_cero
  from public.fiscal_documents d, b
  where d.business_id = b.id and d.status = 'active'
  group by 1
)
select n, seccion, detalle from (

  select 1 as n, 'VEREDICTO' as seccion,
         'ordenes con factura en 0 que SI cobraron ITBIS: ' ||
         (select count(*) from calc where itbis_lineas > 0) ||
         '   |   que NO lo cobraron: ' ||
         (select count(*) from calc where itbis_lineas = 0) as detalle

  union all
  select 2, 'ITBIS COBRADO Y NO DECLARADO',
         'RD$ ' || round((select coalesce(sum(itbis_lineas),0) from calc), 2)

  union all
  select 3, 'POR MES  ' || to_char(m, 'YYYY-MM'),
         docs || ' facturas, ' || en_cero || ' en cero (' ||
         round(100.0 * en_cero / nullif(docs,0), 1) || '%)'
  from mes

  -- casos concretos para revisar a mano
  union all
  select 4, 'EJEMPLOS', d from (
    select 'NCF ' || fdx.ncf_number || '  total RD$ ' || fdx.total ||
           '  declara ITBIS ' || coalesce(fdx.itbis_amount,0) ||
           '  pero las lineas calcularon RD$ ' || round(c.itbis_lineas, 2) as d,
           c.itbis_lineas as k
    from calc c
    join public.fiscal_documents fdx on fdx.order_id = c.order_id
    join b on fdx.business_id = b.id
    where c.itbis_lineas > 0 and coalesce(fdx.itbis_amount,0) = 0 and fdx.status = 'active'
    order by k desc
    limit 10
  ) ej
) t
order by n, seccion, detalle;
