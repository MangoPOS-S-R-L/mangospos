-- 20260830_0001_analytics_perf.sql
-- Arregla el rendimiento de la API de lectura. Complementa a 20260829_0002.
--
-- SINTOMA MEDIDO en prod (LA PENDA EXPRESS, 124.909 documentos fiscales de los cuales 10.851
-- son suyos): un mes de /documentos tardaba 1.531 ms y el plan mostraba
--     Seq Scan on fiscal_documents  ...  Rows Removed by Filter: 114909
-- es decir, recorria la tabla ENTERA evaluando la RLS fila por fila y recien despues se
-- quedaba con las de Penda.
--
-- CAUSA: el pin estaba escrito como `business_id in (select analytics.allowed_business_ids())`.
-- allowed_business_ids() devuelve un CONJUNTO, y el planificador no puede usar un conjunto como
-- llave de indice: lo resuelve como Hash Join, y para eso necesita materializar todas las filas.
--
-- ARREGLO: allowed_business_id() (singular) devuelve UN uuid. Siendo STABLE, Postgres la evalua
-- una sola vez y la usa como condicion de indice sobre business_id. La tabla api_clients ya
-- tenia PK por user_id, o sea que un cliente = un negocio: el escalar es el modelo correcto,
-- el conjunto nunca hizo falta.
--
-- Se conserva allowed_business_ids() por compatibilidad; las vistas pasan a usar la escalar.
-- Idempotente.

begin;

-- ---------------------------------------------------------------------------
-- 1. Indices que faltaban
-- ---------------------------------------------------------------------------
-- Estos venian en 20260829_0002 pero prod se aplico antes de que se agregaran (verificado:
-- pg_indexes no los tenia). Sin ellos el EXISTS que separa Contado de Credito hace un
-- Seq Scan de customer_credits por CADA documento fiscal.
create index if not exists idx_customer_credits_fiscal_document
  on public.customer_credits (fiscal_document_id)
  where fiscal_document_id is not null;

create index if not exists idx_customer_credits_order
  on public.customer_credits (order_id)
  where order_id is not null;

-- ---------------------------------------------------------------------------
-- 2. Pin escalar
-- ---------------------------------------------------------------------------
create or replace function analytics.allowed_business_id()
returns uuid
language sql
stable
security definer
set search_path to 'analytics', 'public', 'pg_temp'
as $$
  select c.business_id
  from analytics.api_clients c
  where c.user_id = auth.uid()
    and c.is_active
  limit 1
$$;

alter function analytics.allowed_business_id() owner to postgres;
revoke all on function analytics.allowed_business_id() from public;
grant execute on function analytics.allowed_business_id() to mango_analytics_view_owner;
grant execute on function analytics.allowed_business_id() to analytics_ro;

comment on function analytics.allowed_business_id() is
  'Business id del JWT actual, escalar para que sea usable como condicion de indice.';

commit;


-- ---------------------------------------------------------------------------
-- 3. Regenerar las vistas con el pin escalar
-- ---------------------------------------------------------------------------
begin;

do $$
declare
  v_rel      text;
  v_pred     text;
  v_rls      boolean;
  v_has_biz  boolean;
  v_created  int := 0;
  v_skipped  text[] := '{}';

  v_override jsonb := jsonb_build_object(
    'businesses',
      'id = analytics.allowed_business_id()',
    'orders',
      'exists (select 1 from public.table_sessions ts'
      ' left join public.dining_tables dt on dt.id = ts.table_id'
      ' left join public.zones z on z.id = dt.zone_id'
      ' where ts.id = src.session_id'
      '   and coalesce(ts.business_id, z.business_id) = analytics.allowed_business_id())',
    'order_items',
      'exists (select 1 from public.orders o'
      ' join public.table_sessions ts on ts.id = o.session_id'
      ' left join public.dining_tables dt on dt.id = ts.table_id'
      ' left join public.zones z on z.id = dt.zone_id'
      ' where o.id = src.order_id'
      '   and coalesce(ts.business_id, z.business_id) = analytics.allowed_business_id())',
    'order_checks',
      'exists (select 1 from public.orders o'
      ' join public.table_sessions ts on ts.id = o.session_id'
      ' left join public.dining_tables dt on dt.id = ts.table_id'
      ' left join public.zones z on z.id = dt.zone_id'
      ' where o.id = src.order_id'
      '   and coalesce(ts.business_id, z.business_id) = analytics.allowed_business_id())'
  );

  v_allow text[] := array[
    'orders','order_items','order_item_modifiers','order_checks','order_excluded_taxes',
    'table_sessions','dining_tables','zones','payments','payment_methods',
    'direct_receipts','direct_receipt_items',
    'menus','menu_items','menu_item_links','menu_item_groups','menu_item_taxes',
    'menu_item_print_areas','categories','modifiers','modifier_groups',
    'combo_groups','combo_group_items','recipes','recipe_ingredients',
    'promotions','coupons','coupon_usage','taxes',
    'cash_registers','cash_register_sessions','cash_transactions',
    'cash_transaction_reasons','cash_count_blind',
    'fiscal_documents','fiscal_document_items','fiscal_document_status_events',
    'fiscal_settings','ncf_sequences','secuencias_ncf',
    'comprobantes','comprobante_items','dgii_receipt_types',
    'inventory_items','inventory_stock','inventory_movements','inventory_lots','warehouses',
    'physical_count_sessions','physical_count_lines',
    'production_orders','production_order_lines',
    'stock_transfers','stock_transfer_items',
    'suppliers','supplier_items','purchase_orders','purchase_order_items',
    'purchase_receptions','purchase_reception_lines',
    'supplier_credits','supplier_credit_payments',
    'customers','customer_credits','credit_payments','customer_points','point_transactions',
    'loyalty_programs','gift_cards','gift_card_transactions',
    'employees','employee_roles','roles','role_permissions','permissions',
    'user_roles','user_permission_overrides','shifts','attendance','audit_logs',
    'businesses','business_settings','business_modules','currencies','reservations',
    'print_areas','print_area_printers'
  ];
begin
  foreach v_rel in array v_allow loop
    select c.relrowsecurity into v_rls
      from pg_class c join pg_namespace n on n.oid = c.relnamespace
     where n.nspname = 'public' and c.relname = v_rel;
    if not found then
      v_skipped := v_skipped || (v_rel || ' (no existe)'); continue;
    end if;

    select exists (select 1 from information_schema.columns
                    where table_schema='public' and table_name=v_rel and column_name='business_id')
      into v_has_biz;

    if v_override ? v_rel then
      v_pred := v_override ->> v_rel;
    elsif v_has_biz then
      v_pred := 'business_id = analytics.allowed_business_id()';
    elsif v_rls then
      v_pred := 'true';
    else
      v_skipped := v_skipped || (v_rel || ' (sin business_id y SIN RLS)'); continue;
    end if;

    execute format('drop view if exists analytics.%I cascade', v_rel);
    execute format('create view analytics.%I as select src.* from public.%I src where %s',
                   v_rel, v_rel, v_pred);
    execute format('alter view analytics.%I owner to mango_analytics_view_owner', v_rel);
    execute format('grant select on analytics.%I to analytics_ro', v_rel);
    v_created := v_created + 1;
  end loop;

  raise notice '--- Vistas regeneradas con pin escalar: % ---', v_created;
  if array_length(v_skipped,1) is not null then
    raise notice 'OMITIDAS: %', array_to_string(v_skipped, ', ');
  else
    raise notice 'OMITIDAS: ninguna';
  end if;
end $$;

commit;


-- ---------------------------------------------------------------------------
-- 4. Feed de documentos, regenerado con el pin escalar
-- ---------------------------------------------------------------------------
-- Definiciones identicas a 20260829_0002 salvo el predicado:
--   business_id in (select analytics.allowed_business_ids())   ->  = analytics.allowed_business_id()
-- Nada mas cambia: mismas columnas, mismos criterios de importe, misma zona horaria.

begin;

create or replace view analytics.documentos_detalle as
with fd as (
  select
    d.id,
    d.business_id,
    d.order_id,
    d.ncf_type::text            as ncf_type,
    d.ncf_number,
    d.customer_name,
    d.customer_rnc,
    d.status,
    d.issued_at,
    d.cancelled_at,
    d.cancellation_reason,
    coalesce(d.subtotal, 0)     as subtotal,
    coalesce(d.discount, 0)     as descuento,
    coalesce(d.tax_exempt, 0)   as exento,
    coalesce(d.taxable_amount,0) as gravado,
    coalesce(d.itbis_amount, 0) as itbis,
    coalesce(d.service_fee, 0)  as ley_10,
    coalesce(d.tip, 0)          as propina,
    coalesce(d.total, 0)        as total,
    exists (
      select 1
      from public.customer_credits cc
      where cc.fiscal_document_id = d.id
         or (d.order_id is not null and cc.order_id = d.order_id)
    ) as es_credito
  from public.fiscal_documents d
  where d.business_id = analytics.allowed_business_id()
),
ventas as (
  select
    case when es_credito then 'Venta Crédito' else 'Venta Contado' end as tipo_doc,
    nullif(regexp_replace(ncf_number, '\D', '', 'g'), '')::bigint      as numero,
    (issued_at    at time zone 'America/Santo_Domingo')::date as fecha,
    customer_name              as nombre,
    round(total - itbis, 2)    as bruto,
    round(itbis, 2)            as itbis,
    round(total, 2)            as total,
    business_id, id as documento_id, order_id, ncf_type, ncf_number, customer_rnc,
    subtotal, descuento, exento, gravado, ley_10, propina,
    status, issued_at as ocurrido_en, cancellation_reason
  from fd
),
devoluciones as (
  select
    case when es_credito then 'Devolución Crédito' else 'Devolución Contado' end as tipo_doc,
    row_number() over (partition by business_id order by cancelled_at, id)       as numero,
    (cancelled_at at time zone 'America/Santo_Domingo')::date as fecha,
    customer_name              as nombre,
    round(total - itbis, 2)    as bruto,
    round(itbis, 2)            as itbis,
    round(total, 2)            as total,
    business_id, id as documento_id, order_id, ncf_type, ncf_number, customer_rnc,
    subtotal, descuento, exento, gravado, ley_10, propina,
    status, cancelled_at as ocurrido_en, cancellation_reason
  from fd
  where status = 'cancelled' and cancelled_at is not null
),
recibos as (
  select
    'Recibo Pago'::text                                                          as tipo_doc,
    row_number() over (partition by cc.business_id order by cp.created_at, cp.id) as numero,
    (cp.created_at at time zone 'America/Santo_Domingo')::date as fecha,
    coalesce(cu.name, cc.notes, 'Cliente')                                        as nombre,
    0::numeric                 as bruto,
    0::numeric                 as itbis,
    round(cp.amount, 2)        as total,
    cc.business_id, cp.id as documento_id, cc.order_id,
    null::text as ncf_type, cp.reference as ncf_number, cu.tax_id as customer_rnc,
    0::numeric as subtotal, 0::numeric as descuento, 0::numeric as exento,
    0::numeric as gravado, 0::numeric as ley_10, 0::numeric as propina,
    'active'::text as status, cp.created_at as ocurrido_en, null::text as cancellation_reason
  from public.credit_payments cp
  join public.customer_credits cc on cc.id = cp.credit_id
  left join public.customers cu   on cu.id = cc.customer_id
  where cc.business_id = analytics.allowed_business_id()
)
select * from ventas
union all
select * from devoluciones
union all
select * from recibos;

alter view analytics.documentos_detalle owner to mango_analytics_view_owner;
grant select on analytics.documentos_detalle to analytics_ro;

comment on view analytics.documentos_detalle is
  'Diario de documentos con desglose completo. analytics.documentos es su proyeccion de 7 columnas.';


-- Proyeccion exacta que consume el cliente.
create or replace view analytics.documentos as
select
  tipo_doc as "TIPO_DOC",
  numero   as "NUMERO",
  fecha    as "FECHA",
  nombre   as "NOMBRE",
  bruto    as "BRUTO",
  itbis    as "ITBIS",
  total    as "TOTAL"
from analytics.documentos_detalle
order by fecha, tipo_doc, numero;

alter view analytics.documentos owner to mango_analytics_view_owner;
grant select on analytics.documentos to analytics_ro;

comment on view analytics.documentos is
  'Feed contable: TIPO_DOC, NUMERO, FECHA, NOMBRE, BRUTO, ITBIS, TOTAL. BRUTO+ITBIS=TOTAL.';


-- Conciliacion: ventas cobradas que NO generaron documento fiscal. Si esta vista trae filas,
-- analytics.documentos esta por debajo de la venta real y hay que revisar el flujo de NCF.
create or replace view analytics.ventas_sin_documento_fiscal as
select
  p.id          as payment_id,
  p.business_id,
  p.order_id,
  p.created_at,
  round(p.amount, 2) as monto,
  p.status
from public.payments p
where p.business_id = analytics.allowed_business_id()
  and p.fiscal_document_id is null
  and p.status = 'completed';

alter view analytics.ventas_sin_documento_fiscal owner to mango_analytics_view_owner;
grant select on analytics.ventas_sin_documento_fiscal to analytics_ro;

commit;

notify pgrst, 'reload schema';
