-- DIAGNOSTICO_itbis_cifra.sql
-- Cifra FIABLE del ITBIS cobrado y no declarado en LA PENDA EXPRESS.
--
-- Por que hace falta esta segunda vuelta: DIAGNOSTICO_itbis_causa.sql comparaba el ITBIS de
-- la ORDEN completa contra CADA una de sus facturas. Cuando una orden se divide en subcuentas
-- genera varios documentos fiscales, y el mismo importe se contaba una vez por documento.
-- Se veia claro en los ejemplos: seis NCF distintos mostraban los mismos RD$ 2.193,96.
--
-- Aqui se compara, POR ORDEN:
--     declarado  = suma de itbis_amount de TODAS sus facturas activas
--     calculado  = suma del ITBIS de order_item_tax_lines de sus lineas
-- La diferencia es la sub-declaracion real.
--
-- Incluye una VALIDACION DEL METODO: en las ordenes cuya factura si declara ITBIS, declarado
-- y calculado deberian coincidir. Si no coinciden, el metodo esta mal y la cifra no vale.
--
-- Solo lee. Devuelve UNA sola tabla.

with b as (select '35c5076a-bd85-4a1b-8d1c-ce719c4f9ae6'::uuid as id),
docs as (
  select d.order_id,
         sum(coalesce(d.itbis_amount,0)) as declarado,
         count(*)                        as facturas,
         min(d.issued_at)                as primera
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
  select d.order_id, d.declarado, d.facturas, d.primera,
         coalesce(l.calculado, 0) as calculado,
         coalesce(l.calculado, 0) - d.declarado as faltante
  from docs d left join lineas l on l.order_id = d.order_id
)
select n, seccion, detalle from (

  -- VALIDACION: donde si se declaro algo, ¿cuadra con lo calculado?
  select 0 as n, 'VALIDACION DEL METODO' as seccion,
         'ordenes que declararon ITBIS>0: ' || count(*) ||
         '  |  cuadran (dif < RD$1): ' || count(*) filter (where abs(faltante) < 1) ||
         '  |  no cuadran: ' || count(*) filter (where abs(faltante) >= 1) as detalle
  from cmp where declarado > 0

  union all
  select 1, 'SUB-DECLARACION REAL',
         count(*) || ' ordenes declaran menos ITBIS del que cobraron  |  faltan RD$ ' ||
         round(sum(faltante), 2)
  from cmp where faltante > 1

  union all
  select 2, 'DE ESAS, EN CERO ABSOLUTO',
         count(*) || ' ordenes declaran RD$0 habiendo cobrado RD$ ' || round(sum(calculado), 2)
  from cmp where declarado = 0 and calculado > 1

  union all
  select 3, 'SOBRE-DECLARACION (control)',
         count(*) || ' ordenes declaran MAS de lo calculado  |  RD$ ' ||
         round(sum(-faltante), 2)
  from cmp where faltante < -1

  union all
  select 4, 'ORDENES CON SUBCUENTAS',
         count(*) || ' de las afectadas tienen mas de una factura (era la fuente del doble conteo)'
  from cmp where faltante > 1 and facturas > 1

  union all
  select 5, 'POR MES  ' || to_char(date_trunc('month', primera at time zone 'America/Santo_Domingo'), 'YYYY-MM'),
         count(*) || ' ordenes afectadas, faltan RD$ ' || round(sum(faltante), 2)
  from cmp where faltante > 1
  group by 1, date_trunc('month', primera at time zone 'America/Santo_Domingo')

  union all
  select 6, 'TOTAL FACTURADO DEL PERIODO',
         'RD$ ' || round((select sum(coalesce(total,0)) from public.fiscal_documents d, b
                           where d.business_id = b.id and d.status = 'active'), 2) ||
         '  |  ITBIS declarado RD$ ' ||
         round((select sum(coalesce(itbis_amount,0)) from public.fiscal_documents d, b
                 where d.business_id = b.id and d.status = 'active'), 2)
) t
order by n, seccion;
