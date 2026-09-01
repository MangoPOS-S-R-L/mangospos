-- 20260830_0009_analytics_tax_anchor_perf.sql
-- URGENTE: 20260830_0008 dejo /documentos devolviendo HTTP 500 por statement timeout.
--
-- CAUSA: el calculo del impuesto usaba `cross join lateral` con un `left join lateral`
-- anidado sobre der_check/der_order. Eso se evalua UNA VEZ POR DOCUMENTO (11.000 veces), y
-- con el ORDER BY de analytics.documentos no hay forma de recortar filas antes. La consulta
-- superaba el statement_timeout del servidor.
--
-- ARREGLO: la misma logica con LEFT JOIN planos. El resultado es identico -- monto del
-- documento, proporcion de los items -- pero el planificador resuelve con un hash join
-- unico en vez de una subconsulta por fila.
--
-- El unico lateral que queda es un calculo escalar sin acceso a tablas, que no cuesta nada
-- y solo evita repetir tres veces la misma expresion.
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
  select
    coalesce(max(t.rate) filter (where upper(t.name) like '%ITBIS%'), 0)     as r_itbis,
    coalesce(max(t.rate) filter (where upper(t.name) not like '%ITBIS%'), 0) as r_ley
  from public.taxes t
  where t.business_id = analytics.allowed_business_id()
    and coalesce(t.is_active, true)
),
-- Lineas de impuesto, cuando existen.
tl as (
  select order_item_id,
         sum(coalesce(amount,0)) filter (where upper(tax_name) like '%ITBIS%')     as itbis,
         sum(coalesce(amount,0)) filter (where upper(tax_name) not like '%ITBIS%') as ley
  from public.order_item_tax_lines
  group by order_item_id
),
-- Impuesto POR ITEM. order_item_tax_lines NO esta poblada para todos los items: si se usa
-- como INNER JOIN, esos items desaparecen y su impuesto termina sumado al BRUTO. Por eso
-- va LEFT JOIN con respaldo: cuando no hay lineas se reparte oi.tax segun oi.tax_rate
-- contra las tasas configuradas, que es la regla de fn_recompute_fd_for_scope.
per_item as (
  select
    oi.order_id, oi.check_id,
    case
      when tl.order_item_id is not null then coalesce(tl.itbis, 0)
      when t.r_itbis > 0 and t.r_ley > 0
           and abs(coalesce(oi.tax_rate,0) - (t.r_itbis + t.r_ley)) < 0.5
        then round(coalesce(oi.tax,0) * t.r_itbis / (t.r_itbis + t.r_ley), 2)
      when t.r_itbis > 0 and abs(coalesce(oi.tax_rate,0) - t.r_itbis) < 0.5
        then coalesce(oi.tax,0)
      else 0
    end as itbis,
    case
      when tl.order_item_id is not null then coalesce(tl.ley, 0)
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
  left join tl on tl.order_item_id = oi.id
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
