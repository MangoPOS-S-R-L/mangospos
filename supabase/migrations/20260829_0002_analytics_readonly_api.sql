-- 20260829_0002_analytics_readonly_api.sql
-- API de LECTURA para clientes (primer consumidor: Penda Express).
--
-- Objetivo: entregar una API key permanente de SOLO LECTURA, restringida a UN negocio,
-- sin tocar el modelo de seguridad del POS.
--
-- Por que este diseno (verificado en Postgres, no es teoria):
--   * Un rol miembro de `authenticated` con NOINHERIT ve 0 filas: las policies `TO authenticated`
--     se evaluan con has_privs_of_role(), que respeta NOINHERIT.
--   * Un rol miembro de `authenticated` con INHERIT si ve filas, pero hereda tambien los grants
--     de INSERT/UPDATE/DELETE => deja de ser solo lectura.
--   * Solucion: vistas SIN security_invoker (definer) en un esquema aparte, cuyo OWNER si es
--     miembro de `authenticated`. La RLS de public.* se evalua con los privilegios del owner de
--     la vista, mientras que el rol de la API (`analytics_ro`) no tiene NINGUN grant sobre
--     public.* y solo tiene SELECT sobre las vistas. Resultado: lee filtrado, no escribe nada.
--
-- Doble candado de alcance:
--   1. RLS de public.* via auth.uid() (el usuario analitico pertenece a un solo negocio), y
--   2. analytics.api_clients: pin explicito de business_id por usuario. Toda relacion que tenga
--      business_id (directo o por join conocido) se filtra ADEMAS por ese pin.
--
-- Requiere despues de aplicar:
--   PGRST_DB_SCHEMAS=public,storage,graphql_public,analytics   + reiniciar el servicio rest.
-- OJO: prod hoy expone `public, storage, graphql_public` (verificado contra la API el
-- 2026-08-30). Hay que AGREGAR analytics a esa lista, no reescribirla: si se omite
-- `storage`, PostgREST deja de servir el esquema de archivos.
-- Idempotente.

begin;

-- ---------------------------------------------------------------------------
-- 1. Roles
-- ---------------------------------------------------------------------------

-- Owner de las vistas. NO hace login. Es miembro de `authenticated` (INHERIT) solo para que
-- las policies `TO authenticated` apliquen al leer public.*.
do $$
begin
  if not exists (select 1 from pg_roles where rolname = 'mango_analytics_view_owner') then
    create role mango_analytics_view_owner nologin inherit;
  end if;
end $$;

-- Rol que asume PostgREST cuando llega la API key. NOINHERIT y NO es miembro de `authenticated`:
-- no puede tocar public.* ni por herencia.
do $$
begin
  if not exists (select 1 from pg_roles where rolname = 'analytics_ro') then
    create role analytics_ro nologin noinherit;
  end if;
end $$;

-- Si alguno de estos GRANT falla por privilegios, ejecutar el archivo como `supabase_admin`
-- en lugar de `postgres`.
grant authenticated to mango_analytics_view_owner;
grant mango_analytics_view_owner to postgres;
grant analytics_ro to authenticator;
grant mango_analytics_view_owner to authenticator;

-- ---------------------------------------------------------------------------
-- 2. Esquema y pin de negocio
-- ---------------------------------------------------------------------------

create schema if not exists analytics;
alter schema analytics owner to mango_analytics_view_owner;

grant usage on schema analytics to analytics_ro;
grant usage on schema analytics to mango_analytics_view_owner;

-- Quien puede consumir la API y sobre que negocio. Es el candado duro de alcance.
create table if not exists analytics.api_clients (
  user_id     uuid primary key references auth.users(id) on delete cascade,
  business_id uuid not null references public.businesses(id) on delete cascade,
  label       text not null,
  is_active   boolean not null default true,
  created_at  timestamptz not null default now(),
  notes       text
);

alter table analytics.api_clients owner to postgres;

-- Un cliente = exactamente un negocio. Si manana hay que dar dos, se cambia la PK a propósito,
-- no por accidente.
comment on table analytics.api_clients is
  'Pin de alcance de la API de lectura. PK por user_id => un usuario analitico ve un solo negocio.';

-- Nadie mas que postgres la lee. analytics_ro NO recibe grant.
revoke all on analytics.api_clients from public;

create or replace function analytics.allowed_business_ids()
returns setof uuid
language sql
stable
security definer
set search_path to 'analytics', 'public', 'pg_temp'
as $$
  select c.business_id
  from analytics.api_clients c
  where c.user_id = auth.uid()
    and c.is_active
$$;

alter function analytics.allowed_business_ids() owner to postgres;
revoke all on function analytics.allowed_business_ids() from public;
grant execute on function analytics.allowed_business_ids() to mango_analytics_view_owner;
-- OJO: el EXECUTE de una funcion se valida contra el INVOCADOR, no contra el owner de la vista
-- (a diferencia del acceso a tablas). Sin este grant, todas las vistas fallan con
-- "permission denied for function allowed_business_ids". Es inocuo: la funcion solo devuelve
-- el business_id ya asignado a ese mismo JWT y no se puede alterar desde afuera.
grant execute on function analytics.allowed_business_ids() to analytics_ro;

comment on function analytics.allowed_business_ids() is
  'Business ids permitidos para el JWT actual. Usada dentro de las vistas de analytics.';

commit;


-- ---------------------------------------------------------------------------
-- 3. Vistas de lectura
-- ---------------------------------------------------------------------------
-- Una vista por relacion del allowlist. Regla de seguridad aplicada por relacion:
--   a) tiene columna business_id  -> se filtra por el pin de analytics.api_clients
--      (queda protegida aunque la tabla no tuviera RLS)
--   b) no tiene business_id pero SI tiene RLS -> la RLS de public.* hace el alcance
--   c) no tiene business_id y NO tiene RLS -> SE OMITE (expondria otros tenants)
-- El caso (c) se reporta como NOTICE al final; revisar siempre esa lista.

begin;

do $$
declare
  v_rel       text;
  v_pred      text;
  v_kind      "char";
  v_rls       boolean;
  v_has_biz   boolean;
  v_created   int  := 0;
  v_skipped   text[] := '{}';
  v_rls_only  text[] := '{}';

  -- Relaciones sin business_id propio donde igual queremos el pin duro.
  v_override  jsonb := jsonb_build_object(
    'businesses',
      'id in (select analytics.allowed_business_ids())',
    'orders',
      'exists (select 1 from public.table_sessions ts'
      ' left join public.dining_tables dt on dt.id = ts.table_id'
      ' left join public.zones z on z.id = dt.zone_id'
      ' where ts.id = src.session_id'
      '   and coalesce(ts.business_id, z.business_id) in (select analytics.allowed_business_ids()))',
    'order_items',
      'exists (select 1 from public.orders o'
      ' join public.table_sessions ts on ts.id = o.session_id'
      ' left join public.dining_tables dt on dt.id = ts.table_id'
      ' left join public.zones z on z.id = dt.zone_id'
      ' where o.id = src.order_id'
      '   and coalesce(ts.business_id, z.business_id) in (select analytics.allowed_business_ids()))',
    'order_checks',
      'exists (select 1 from public.orders o'
      ' join public.table_sessions ts on ts.id = o.session_id'
      ' left join public.dining_tables dt on dt.id = ts.table_id'
      ' left join public.zones z on z.id = dt.zone_id'
      ' where o.id = src.order_id'
      '   and coalesce(ts.business_id, z.business_id) in (select analytics.allowed_business_ids()))'
  );

  -- Superficie de reporteria acordada con el cliente.
  v_allow text[] := array[
    -- ventas / operacion
    'orders','order_items','order_item_modifiers','order_checks','order_excluded_taxes',
    'table_sessions','dining_tables','zones','payments','payment_methods',
    'direct_receipts','direct_receipt_items',
    -- menu / productos
    'menus','menu_items','menu_item_links','menu_item_groups','menu_item_taxes',
    'menu_item_print_areas','categories','modifiers','modifier_groups',
    'combo_groups','combo_group_items','recipes','recipe_ingredients',
    'promotions','coupons','coupon_usage','taxes',
    -- caja
    'cash_registers','cash_register_sessions','cash_transactions',
    'cash_transaction_reasons','cash_count_blind',
    -- fiscal DGII
    'fiscal_documents','fiscal_document_items','fiscal_document_status_events',
    'fiscal_settings','ncf_sequences','secuencias_ncf',
    'comprobantes','comprobante_items','dgii_receipt_types',
    -- inventario / compras
    'inventory_items','inventory_stock','inventory_movements','inventory_lots','warehouses',
    'physical_count_sessions','physical_count_lines',
    'production_orders','production_order_lines',
    'stock_transfers','stock_transfer_items',
    'suppliers','supplier_items','purchase_orders','purchase_order_items',
    'purchase_receptions','purchase_reception_lines',
    'supplier_credits','supplier_credit_payments',
    -- clientes / fidelidad
    'customers','customer_credits','credit_payments','customer_points','point_transactions',
    'loyalty_programs','gift_cards','gift_card_transactions',
    -- personas / auditoria
    'employees','employee_roles','roles','role_permissions','permissions',
    'user_roles','user_permission_overrides','shifts','attendance','audit_logs',
    -- negocio / catalogos
    'businesses','business_settings','business_modules','currencies','reservations',
    'print_areas','print_area_printers'
  ];
begin
  foreach v_rel in array v_allow loop
    select c.relkind, c.relrowsecurity
      into v_kind, v_rls
      from pg_class c
      join pg_namespace n on n.oid = c.relnamespace
     where n.nspname = 'public' and c.relname = v_rel;

    if not found then
      v_skipped := v_skipped || (v_rel || ' (no existe en esta BD)');
      continue;
    end if;

    select exists (
      select 1 from information_schema.columns
       where table_schema = 'public' and table_name = v_rel and column_name = 'business_id'
    ) into v_has_biz;

    if v_override ? v_rel then
      v_pred := v_override ->> v_rel;
    elsif v_has_biz then
      v_pred := 'business_id in (select analytics.allowed_business_ids())';
    elsif v_rls then
      v_pred := 'true';
      v_rls_only := v_rls_only || v_rel;
    else
      -- sin business_id y sin RLS: expondria todos los negocios. No se publica.
      v_skipped := v_skipped || (v_rel || ' (sin business_id y SIN RLS)');
      continue;
    end if;

    execute format('drop view if exists analytics.%I cascade', v_rel);
    execute format(
      'create view analytics.%I as select src.* from public.%I src where %s',
      v_rel, v_rel, v_pred
    );
    execute format('alter view analytics.%I owner to mango_analytics_view_owner', v_rel);
    execute format('grant select on analytics.%I to analytics_ro', v_rel);
    v_created := v_created + 1;
  end loop;

  raise notice '--- API de lectura: % vistas creadas en el esquema analytics ---', v_created;
  if array_length(v_rls_only, 1) is not null then
    raise notice 'Alcance por RLS unicamente (sin pin directo): %', array_to_string(v_rls_only, ', ');
  end if;
  if array_length(v_skipped, 1) is not null then
    raise notice 'OMITIDAS (revisar): %', array_to_string(v_skipped, ', ');
  else
    raise notice 'OMITIDAS: ninguna';
  end if;
end $$;

-- Candado final: analytics_ro no debe tener NADA fuera del esquema analytics.
revoke all on schema public from analytics_ro;
revoke all privileges on all tables in schema public from analytics_ro;
revoke all privileges on all functions in schema public from analytics_ro;
revoke all privileges on all sequences in schema public from analytics_ro;
grant usage on schema analytics to analytics_ro;

commit;

notify pgrst, 'reload schema';


-- ---------------------------------------------------------------------------
-- 4. Feed de documentos (formato acordado con el cliente)
-- ---------------------------------------------------------------------------
-- Columnas exactas: TIPO_DOC, NUMERO, FECHA, NOMBRE, BRUTO, ITBIS, TOTAL
--
-- Mapeo contra MangoPOS:
--   Venta Contado      -> fiscal_documents SIN customer_credits asociado
--   Venta Credito      -> fiscal_documents CON customer_credits asociado
--   Devolucion ...     -> fiscal_documents con status='cancelled' (fila ADICIONAL a la venta:
--                         la venta ocurrio, la devolucion la revierte; nunca se borra la venta)
--   Recibo Pago        -> credit_payments (abonos a CxC). BRUTO=0, ITBIS=0, TOTAL=abono
--
-- Criterios de importe (mantienen la identidad BRUTO + ITBIS = TOTAL):
--   BRUTO = total - itbis_amount   <- incluye Ley 10% y propina si el ticket las trae
--   ITBIS = itbis_amount
--   TOTAL = total
--   Las devoluciones se reportan en POSITIVO, igual que en la muestra del cliente.
--
-- FECHA: se calcula SIEMPRE en America/Santo_Domingo (UTC-4, sin horario de verano).
-- Es obligatorio: PostgREST abre sus conexiones en UTC, asi que un ::date pelado mandaria
-- toda venta despues de las 8:00 PM al dia siguiente y descuadraria el cierre diario.
--
-- NUMERO:
--   ventas       -> parte numerica del NCF (tipo + secuencia), unica por negocio
--   devoluciones -> contador propio por negocio, ordenado por fecha de anulacion
--   recibos      -> contador propio por negocio, ordenado por fecha del abono
--
-- El desglose completo (NCF, tipo de NCF, descuento, Ley 10%, propina, RNC) esta en
-- analytics.documentos_detalle.

-- ---------------------------------------------------------------------------
-- 4.a Indices que el feed necesita para no morir con volumen real
-- ---------------------------------------------------------------------------
-- ESTO SI TOCA public.*, es el unico punto de la migracion que lo hace.
-- Es aditivo (solo indices) y tambien beneficia al POS.
--
-- Sin ellos, el EXISTS que clasifica Contado vs Credito hace un Seq Scan de
-- customer_credits POR CADA documento fiscal: con decenas de miles de facturas el
-- endpoint /documentos se cae por timeout. Verificado con EXPLAIN: customer_credits
-- no traia indice ni por fiscal_document_id ni por order_id.
--
-- Son parciales para que ocupen poco. customer_credits es una tabla chica, asi que el
-- CREATE INDEX toma un lock breve; si se aplica en hora pico, usar CREATE INDEX
-- CONCURRENTLY a mano (no se puede dentro de una transaccion).

create index if not exists idx_customer_credits_fiscal_document
  on public.customer_credits (fiscal_document_id)
  where fiscal_document_id is not null;

create index if not exists idx_customer_credits_order
  on public.customer_credits (order_id)
  where order_id is not null;


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
  where d.business_id in (select analytics.allowed_business_ids())
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
  where cc.business_id in (select analytics.allowed_business_ids())
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
where p.business_id in (select analytics.allowed_business_ids())
  and p.fiscal_document_id is null
  and p.status = 'completed';

alter view analytics.ventas_sin_documento_fiscal owner to mango_analytics_view_owner;
grant select on analytics.ventas_sin_documento_fiscal to analytics_ro;

commit;

notify pgrst, 'reload schema';
