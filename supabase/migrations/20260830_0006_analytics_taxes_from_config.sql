-- 20260830_0006_analytics_taxes_from_config.sql
-- El feed publicaba mal los dos impuestos. Ahora salen SOLO de la configuracion.
--
-- QUE ESTABA MAL
--   * ITBIS: se tomaba de fiscal_documents.itbis_amount. La propia app se niega a usar ese
--     campo; comentario textual en lib/data/repositories/reports_repository.dart:1807:
--       "El split sale de lo que REALMENTE se cobro por linea (order_items.tax) cruzado con
--        la config de taxes, NO de fiscal_documents.itbis_amount"
--   * LEY 10%: se tomaba de fiscal_documents.service_fee, que ademas de no ser fiable es un
--     parametro heredado que no debe usarse. Todos los impuestos salen de la configuracion.
--
-- MEDIDO EN LA PENDA EXPRESS (10.856 facturas activas, jul-ago 2026)
--     subtotal + itbis_amount + service_fee + tip = RD$  8.666.003,62
--     TOTAL                                         RD$ 10.052.230,05
--     diferencia sin representar                    RD$  1.386.226,43
--   service_fee esta en 0,00 en las 10.856. Los items al 28% (ITBIS+LEY juntos) cobraron
--   RD$ 1.391.070,80; repartido 18/28 y 10/28 da ITBIS 894.259 + LEY 496.811 = 1.391.070.
--   Es exactamente la diferencia: el documento fiscal no guardaba ninguno de los dos.
--
-- COMO QUEDA
--   Ambos impuestos se derivan de order_item_tax_lines, que es lo que realmente se cobro por
--   linea segun menu_item_taxes + taxes. Sin nombres cableados: ITBIS es la linea cuyo impuesto
--   se llama ITBIS y LEY es TODO lo demas que se haya configurado, de modo que ningun impuesto
--   se pierde y la identidad siempre cierra:
--       BRUTO + ITBIS + LEY = TOTAL          y   ITBIS = 18% de BRUTO
--
--   Cuentas divididas: se agrupa por check_id cuando el comprobante es de una subcuenta
--   (fiscal_documents.check_id), y por orden completa cuando no lo es. Antes esto dependia
--   del valor guardado en el documento; ahora tampoco.
--
--   analytics.documentos pasa de 7 a 8 columnas: se agrega LEY.
-- Idempotente.

begin;

-- El join nuevo necesita este indice para no degradar el feed.
create index if not exists idx_order_item_tax_lines_item
  on public.order_item_tax_lines (order_item_id);

-- Cambia el orden de columnas (entra ley_10 antes de total), y CREATE OR REPLACE exige
-- la misma lista en las mismas posiciones. Hay que recrear las dos vistas.
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
-- Impuesto realmente cobrado por linea, por subcuenta.
-- ITBIS = la linea del impuesto llamado ITBIS. LEY = todo el resto de impuestos
-- configurados, para que ninguno se pierda si manana se agrega otro.
der_check as (
  select oi.order_id, oi.check_id,
         sum(coalesce(tl.amount,0)) filter (where upper(tl.tax_name) like '%ITBIS%')     as itbis,
         sum(coalesce(tl.amount,0)) filter (where upper(tl.tax_name) not like '%ITBIS%') as ley
  from public.order_items oi
  join public.order_item_tax_lines tl on tl.order_item_id = oi.id
  where oi.status <> 'void'
    and oi.order_id in (select f.order_id from fd f where f.order_id is not null)
  group by oi.order_id, oi.check_id
),
der_order as (
  select order_id, sum(itbis) as itbis, sum(ley) as ley
  from der_check group by order_id
),
fd2 as (
  select f.*,
         round(case when f.check_id is not null
                    then coalesce(dc.itbis, 0) else coalesce(do_.itbis, 0) end, 2) as itbis,
         round(case when f.check_id is not null
                    then coalesce(dc.ley, 0)   else coalesce(do_.ley, 0)   end, 2) as ley_10
  from fd f
  left join der_check dc on dc.order_id = f.order_id and dc.check_id = f.check_id
  left join der_order do_ on do_.order_id = f.order_id
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
    subtotal, descuento, exento, gravado, propina,
    status, issued_at as ocurrido_en, cancellation_reason
  from fd2
),
devoluciones as (
  select
    case when es_credito then 'Devolución Crédito' else 'Devolución Contado' end as tipo_doc,
    row_number() over (partition by business_id order by cancelled_at, id)       as numero,
    (cancelled_at at time zone 'America/Santo_Domingo')::date as fecha,
    customer_name                     as nombre,
    round(total - itbis - ley_10, 2)  as bruto,
    itbis, ley_10,
    round(total, 2)                   as total,
    business_id, id as documento_id, order_id, ncf_type, ncf_number, customer_rnc,
    subtotal, descuento, exento, gravado, propina,
    status, cancelled_at as ocurrido_en, cancellation_reason
  from fd2
  where status = 'cancelled' and cancelled_at is not null
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
  'Diario de documentos. ITBIS y LEY derivados de order_item_tax_lines (configuracion), '
  'nunca de fiscal_documents.itbis_amount ni de service_fee.';

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
