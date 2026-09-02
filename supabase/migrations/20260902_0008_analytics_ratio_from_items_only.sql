-- 20260902_0008_analytics_ratio_from_items_only.sql
-- H-2 de la auditoria del 607 de La Penda Express (DH Asociados, 31-ago-2026):
-- 104 facturas donde el feed contable reporto Ley 10% sin que se vendiera un solo
-- producto sujeto a esa ley. Corrige 20260830_0009.
--
-- QUE ESTABA MAL
--   analytics.documentos PREFERIA order_item_tax_lines para sacar la proporcion
--   ITBIS/LEY. Esa tabla no es historia de lo cobrado: fn_populate_item_tax_lines
--   hace DELETE+INSERT desde menu_item_taxes y corre AL FACTURAR, mientras oi.tax
--   quedo congelado cuando se AGREGO el item. Si la configuracion del producto
--   cambia entre los dos momentos, las lineas describen una venta que no ocurrio.
--
--   Caso testigo NCF B0200157713 (2026-08-23), 11 items todos al 18%:
--       item agregado 12:45  ->  oi.tax_rate 18, oi.tax = 18% del subtotal
--       lineas escritas 13:29 (== issued_at al microsegundo) -> ITBIS 18% + LEY 10%
--   El feed anclaba el MONTO en el documento (778,53, correcto) pero sacaba la
--   PROPORCION de esas lineas (18/28) -> ITBIS 500,48 + LEY 278,05. Exactamente
--   los numeros del informe. El total nunca cambio, por eso era invisible.
--
--   Alcance medido en agosto: 451 de 19.494 items (2,3%) con la tasa de las lineas
--   distinta a la del item; RD$ 58.277,94 de impuesto que las lineas inventan.
--
-- COMO QUEDA
--   La proporcion sale UNICAMENTE de oi.tax repartido por oi.tax_rate contra las
--   tasas configuradas -- lo que realmente se cobro. Misma regla que la v6 de
--   fn_recompute_fd_for_scope (20260902_0007). El anclaje del monto en el documento
--   no cambia: sigue siendo total - subtotal + descuento, la leccion de 0008.
--
--   Con esto, una factura sin un solo producto al 28% reporta LEY = 0.
--
-- NO cambia columnas ni nombres: analytics.documentos sigue siendo
-- TIPO_DOC, NUMERO, FECHA, NOMBRE, BRUTO, ITBIS, LEY, TOTAL.
-- Idempotente.

begin;

drop view if exists analytics.documentos;
drop view if exists analytics.documentos_detalle;

create view analytics.documentos_detalle as
with fd as (
  select
    d.id, d.business_id, d.order_id, d.check_id,
    d.ncf_type::text  as ncf_type,
    d.ncf_number, d.customer_name, d.customer_rnc, d.status,
    d.issued_at, d.cancelled_at, d.cancellation_reason,
    coalesce(d.subtotal, 0)      as subtotal,
    coalesce(d.discount, 0)      as descuento,
    coalesce(d.tax_exempt, 0)    as exento,
    coalesce(d.taxable_amount,0) as gravado,
    coalesce(d.tip, 0)           as propina,
    coalesce(d.total, 0)         as total,
    exists (
      select 1 from public.customer_credits cc
      where cc.fiscal_document_id = d.id
         or (d.order_id is not null and cc.order_id = d.order_id)
    ) as es_credito
  from public.fiscal_documents d
  where d.business_id = analytics.allowed_business_id()
),
-- Tasas configuradas del negocio. Nada cableado.
tasas as (
  -- Manda el interruptor de Ajustes > Impuestos (include_in_ecf) SI el negocio
  -- ya lo configuro; si no, respaldo por el nombre. Igual que la v6 de
  -- fn_recompute_fd_for_scope: no exige tocar la config de un negocio vivo.
  select case when x.usa_flag then x.r_ecf else x.r_name_ecf end as r_itbis,
         case when x.usa_flag then x.r_non else x.r_name_non end as r_ley
  from (
    select
      coalesce(bool_or(coalesce(t.include_in_ecf, true) = false), false)          as usa_flag,
      coalesce(sum(t.rate) filter (where     coalesce(t.include_in_ecf, true)),0) as r_ecf,
      coalesce(sum(t.rate) filter (where not coalesce(t.include_in_ecf, true)),0) as r_non,
      coalesce(sum(t.rate) filter (where upper(t.name) like     '%ITBIS%'), 0)    as r_name_ecf,
      coalesce(sum(t.rate) filter (where upper(t.name) not like '%ITBIS%'), 0)    as r_name_non
    from public.taxes t
  where t.business_id = analytics.allowed_business_id()
    and coalesce(t.is_active, true)
  ) x
),
-- Impuesto POR ITEM, derivado UNICAMENTE de oi.tax repartido segun oi.tax_rate contra las
-- tasas configuradas. Es la misma regla de fn_recompute_fd_for_scope v6.
--
-- Ya NO se consultan order_item_tax_lines. Esa tabla se escribe con DELETE+INSERT desde
-- menu_item_taxes en el momento de FACTURAR, mientras oi.tax se congela cuando se AGREGA
-- el item: si la config cambia entremedio, las lineas describen algo que nunca se cobro.
-- Medido en La Penda, agosto 2026: 451 de 19.494 items (2,3%) con las lineas al 28% sobre
-- items cobrados al 18%, RD$ 58.277,94 de impuesto que las lineas inventan.
per_item as (
  select
    oi.order_id, oi.check_id,
    case
      when t.r_itbis > 0 and t.r_ley > 0
           and abs(coalesce(oi.tax_rate,0) - (t.r_itbis + t.r_ley)) < 0.5
        then round(coalesce(oi.tax,0) * t.r_itbis / (t.r_itbis + t.r_ley), 2)
      when t.r_itbis > 0 and abs(coalesce(oi.tax_rate,0) - t.r_itbis) < 0.5
        then coalesce(oi.tax,0)
      else 0
    end as itbis,
    case
      when t.r_itbis > 0 and t.r_ley > 0
           and abs(coalesce(oi.tax_rate,0) - (t.r_itbis + t.r_ley)) < 0.5
        then coalesce(oi.tax,0) - round(coalesce(oi.tax,0) * t.r_itbis / (t.r_itbis + t.r_ley), 2)
      when t.r_itbis > 0 and abs(coalesce(oi.tax_rate,0) - t.r_itbis) < 0.5
        then 0
      -- Lo que no encaje en ninguna tasa conocida va aqui: asi ningun impuesto se pierde
      -- y la identidad BRUTO + ITBIS + LEY = TOTAL sigue cerrando.
      else coalesce(oi.tax,0)
    end as ley,
    case when coalesce(oi.tax,0) = 0 then coalesce(oi.subtotal,0) else 0 end as exento_calc
  from public.order_items oi
  cross join tasas t
  where oi.status <> 'void'
    and oi.order_id in (select f.order_id from fd f where f.order_id is not null)
),
der_check as (
  select order_id, check_id,
         sum(itbis) as itbis, sum(ley) as ley, sum(exento_calc) as exento_calc
  from per_item group by order_id, check_id
),
der_order as (
  select order_id, sum(itbis) as itbis, sum(ley) as ley, sum(exento_calc) as exento_calc
  from per_item group by order_id
),
-- El MONTO del impuesto lo define el propio documento: total - subtotal + descuento es lo
-- que facturo. Los items solo definen la PROPORCION entre ITBIS y LEY.
--
-- Se resuelve con LEFT JOIN planos. La version 20260830_0008 usaba `cross join lateral` con
-- un `left join lateral` anidado, y eso se ejecutaba UNA VEZ POR DOCUMENTO: /documentos
-- empezo a devolver HTTP 500 por statement timeout en produccion. Con joins normales el
-- planificador hace un solo hash join y el resultado es identico.
--
-- Cuando check_id no es nulo casan las dos tablas derivadas y coalesce prefiere la del check;
-- cuando es nulo, der_check no casa (check_id = null nunca es cierto) y queda la de la orden.
base as (
  select
    f.*,
    greatest(f.total - f.subtotal + f.descuento, 0)      as tax_doc,
    coalesce(dc.itbis, do_.itbis, 0)                     as d_itbis,
    coalesce(dc.ley, do_.ley, 0)                         as d_ley,
    coalesce(dc.exento_calc, do_.exento_calc, 0)         as d_exento,
    t.r_itbis, t.r_ley
  from fd f
  cross join tasas t
  left join der_check dc on dc.order_id = f.order_id and dc.check_id = f.check_id
  left join der_order do_ on do_.order_id = f.order_id
),
fd2 as (
  select
    b.*,
    round(b.tax_doc * r.ratio, 2)                              as itbis,
    round(b.tax_doc - round(b.tax_doc * r.ratio, 2), 2)        as ley_10,
    round(b.d_exento, 2)                                       as exento_calc
  from base b
  cross join lateral (
    select case
             when b.d_itbis + b.d_ley > 0 then b.d_itbis / (b.d_itbis + b.d_ley)
             when b.r_itbis + b.r_ley > 0 then b.r_itbis / (b.r_itbis + b.r_ley)
             else 1
           end as ratio
  ) r
),
ventas as (
  select
    case when es_credito then 'Venta Crédito' else 'Venta Contado' end as tipo_doc,
    nullif(regexp_replace(ncf_number, '\D', '', 'g'), '')::bigint      as numero,
    (issued_at at time zone 'America/Santo_Domingo')::date as fecha,
    customer_name                     as nombre,
    round(total - itbis - ley_10, 2)  as bruto,
    itbis, ley_10,
    round(total, 2)                   as total,
    business_id, id as documento_id, order_id, ncf_type, ncf_number, customer_rnc,
    subtotal, descuento, exento_calc as exento, gravado, propina,
    status, issued_at as ocurrido_en, cancellation_reason
  from fd2
),
devoluciones as (
  select
    case when es_credito then 'Devolución Crédito' else 'Devolución Contado' end as tipo_doc,
    row_number() over (partition by business_id order by coalesce(cancelled_at, issued_at), id) as numero,
    (coalesce(cancelled_at, issued_at) at time zone 'America/Santo_Domingo')::date as fecha,
    customer_name                     as nombre,
    round(total - itbis - ley_10, 2)  as bruto,
    itbis, ley_10,
    round(total, 2)                   as total,
    business_id, id as documento_id, order_id, ncf_type, ncf_number, customer_rnc,
    subtotal, descuento, exento_calc as exento, gravado, propina,
    status, coalesce(cancelled_at, issued_at) as ocurrido_en, cancellation_reason
  from fd2
  -- TODA anulacion genera su devolucion. Antes se exigia cancelled_at y en prod habia 15
  -- ventas anuladas con solo 3 devoluciones: 12 anulaciones quedaban sin contrapartida y el
  -- feed las sumaba como venta.
  where status = 'cancelled'
),
recibos as (
  select
    'Recibo Pago'::text                                                           as tipo_doc,
    row_number() over (partition by cc.business_id order by cp.created_at, cp.id)  as numero,
    (cp.created_at at time zone 'America/Santo_Domingo')::date as fecha,
    coalesce(cu.name, cc.notes, 'Cliente')                                        as nombre,
    0::numeric as bruto, 0::numeric as itbis, 0::numeric as ley_10,
    round(cp.amount, 2) as total,
    cc.business_id, cp.id as documento_id, cc.order_id,
    null::text as ncf_type, cp.reference as ncf_number, cu.tax_id as customer_rnc,
    0::numeric as subtotal, 0::numeric as descuento, 0::numeric as exento,
    0::numeric as gravado, 0::numeric as propina,
    'active'::text as status, cp.created_at as ocurrido_en, null::text as cancellation_reason
  from public.credit_payments cp
  join public.customer_credits cc on cc.id = cp.credit_id
  left join public.customers cu   on cu.id = cc.customer_id
  where cc.business_id = analytics.allowed_business_id()
)
select * from ventas
union all select * from devoluciones
union all select * from recibos;

alter view analytics.documentos_detalle owner to mango_analytics_view_owner;
grant select on analytics.documentos_detalle to analytics_ro;

comment on view analytics.documentos_detalle is
  'Diario de documentos. El MONTO del impuesto sale del propio comprobante '
  '(total - subtotal + descuento) y la PROPORCION ITBIS/LEY de order_items.tax '
  'repartido por order_items.tax_rate. Nunca de fiscal_documents.itbis_amount, '
  'nunca de service_fee, y nunca de order_item_tax_lines.';

-- La proyeccion del cliente pasa de 7 a 8 columnas: se agrega LEY.
create view analytics.documentos as
select
  tipo_doc as "TIPO_DOC",
  numero   as "NUMERO",
  fecha    as "FECHA",
  nombre   as "NOMBRE",
  bruto    as "BRUTO",
  itbis    as "ITBIS",
  ley_10   as "LEY",
  total    as "TOTAL"
from analytics.documentos_detalle
order by fecha, tipo_doc, numero;

alter view analytics.documentos owner to mango_analytics_view_owner;
grant select on analytics.documentos to analytics_ro;

comment on view analytics.documentos is
  'Feed contable: TIPO_DOC, NUMERO, FECHA, NOMBRE, BRUTO, ITBIS, LEY, TOTAL. '
  'BRUTO es la base imponible: BRUTO + ITBIS + LEY = TOTAL, e ITBIS = 18% de BRUTO.';

commit;

notify pgrst, 'reload schema';
