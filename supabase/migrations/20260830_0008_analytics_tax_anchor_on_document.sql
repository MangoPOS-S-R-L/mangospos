-- 20260830_0008_analytics_tax_anchor_on_document.sql
-- Tercer y ultimo ajuste del reparto de impuestos. Corrige 20260830_0007.
--
-- QUE SEGUIA MAL (medido en prod tras aplicar 0007): 352 de 11.002 ventas con
-- BRUTO != subtotal, en tres formas:
--   * 292 documentos con ITBIS en 0 y la diferencia igual al 28% del subtotal. Sus items
--     estan en `void`, mi calculo los excluye y el impuesto terminaba dentro del BRUTO.
--   * 18 documentos con BRUTO NEGATIVO: total ~0,02 mientras su orden tiene ~3.000 de
--     impuesto. Un BRUTO negativo no es salida valida en ningun caso.
--   * 49 en ordenes con varias subcuentas donde el reparto por check no coincidia con lo
--     que facturo cada documento.
--
-- LA CAUSA DE FONDO ERA EL ANCLAJE. Estaba sacando el MONTO del impuesto de los items,
-- cuando el documento fiscal ya lo sabe: total - subtotal + descuento es lo que facturo.
-- Los items no deben decir cuanto, solo COMO se reparte entre ITBIS y LEY.
--
-- ARREGLO: monto del documento, proporcion de los items (y de las tasas configuradas si el
-- documento no tiene lineas utiles). Con eso BRUTO = subtotal - descuento siempre, nunca es
-- negativo, y los items en void dejan de importar porque no se usan para el monto.
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
-- Antes el monto salia de los items y eso fallaba de tres formas distintas:
--   * items en void: se excluyen del calculo y su impuesto terminaba en el BRUTO (292 docs)
--   * documentos con total ~0 cuya orden si tiene items: BRUTO salia NEGATIVO (18 docs)
--   * subcuentas: el reparto por check no siempre coincide con lo que facturo el documento (49)
-- Anclando en el documento, BRUTO = subtotal - descuento SIEMPRE, y nunca sale negativo.
fd2 as (
  select f.*,
         round(v.tax_doc * v.ratio_itbis, 2)                        as itbis,
         round(v.tax_doc - round(v.tax_doc * v.ratio_itbis, 2), 2)  as ley_10,
         round(coalesce(v.exento_calc, 0), 2)                       as exento_calc
  from fd f
  cross join lateral (
    select
      greatest(f.total - f.subtotal + f.descuento, 0) as tax_doc,
      case
        -- proporcion segun lo que cobraron las lineas
        when coalesce(d.itbis,0) + coalesce(d.ley,0) > 0
          then coalesce(d.itbis,0) / (coalesce(d.itbis,0) + coalesce(d.ley,0))
        -- sin lineas utiles: se usa la proporcion de las tasas configuradas
        when t.r_itbis + t.r_ley > 0 then t.r_itbis / (t.r_itbis + t.r_ley)
        else 1
      end as ratio_itbis,
      d.exento_calc
    from tasas t
    left join lateral (
      select dc.itbis, dc.ley, dc.exento_calc
        from der_check dc
       where dc.order_id = f.order_id and dc.check_id = f.check_id
      union all
      select do_.itbis, do_.ley, do_.exento_calc
        from der_order do_
       where f.check_id is null and do_.order_id = f.order_id
      limit 1
    ) d on true
  ) v
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
