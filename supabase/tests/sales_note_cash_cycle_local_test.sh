#!/usr/bin/env bash
# Postgres 15 desechable. Emisores y triggers REALES del repositorio; solamente
# generate_ncf usa una secuencia local (sin DGII, Alanube ni base remota).
# bash supabase/tests/sales_note_cash_cycle_local_test.sh [carpeta_trabajo]
set -euo pipefail
REPO=$(cd "$(dirname "$0")/../.." && pwd)
M=$REPO/supabase/migrations
PG=${PG_BIN:-/opt/homebrew/opt/postgresql@15/bin}
PORT=${PG_PORT:-55449}
WORK=${1:-$(mktemp -d)}
D=$WORK/pg_sales_note_cycle
mkdir -p "$D"
"$PG/initdb" -D "$D/data" -U postgres --auth=trust >/dev/null
"$PG/pg_ctl" -D "$D/data" -o "-p $PORT -c listen_addresses=127.0.0.1 -c unix_socket_directories=''" \
  -l "$D/log" start -w >/dev/null
trap '"$PG/pg_ctl" -D "$D/data" stop -m fast >/dev/null 2>&1' EXIT
Q() { "$PG/psql" -h 127.0.0.1 -p "$PORT" -U postgres -X -q -v ON_ERROR_STOP=1 "$@"; }

Q <<'SQL'
create role authenticated; create role anon; create role service_role;
create schema auth;
create function auth.role() returns text language sql stable as $$
  select case when current_setting('test.role', true) = 'sql-admin' then null
              else coalesce(nullif(current_setting('test.role', true), ''), 'authenticated') end
$$;
create function auth.uid() returns uuid language sql stable as $$
  select 'a0000000-0000-0000-0000-000000000001'::uuid
$$;
create function public.is_member_of_business(uuid) returns boolean language sql stable as $$
  select coalesce(nullif(current_setting('test.authorized', true), ''), 'on') = 'on'
$$;
create function public.user_has_business_access(uuid,uuid) returns boolean language sql as $$select true$$;
create function public.user_business_role(uuid,uuid) returns text language sql as $$select 'owner'$$;
alter default privileges in schema public grant all on tables to anon, authenticated;
alter default privileges in schema public grant execute on functions to anon, authenticated;
grant usage on schema public, auth to anon, authenticated, service_role;
create type public.ncf_type as enum ('B01','B02','B04','E31','E32');
create table public.businesses(id uuid primary key);
create table public.business_settings(id uuid default gen_random_uuid(), business_id uuid unique not null);
create table public.customers(id uuid primary key, tax_id text, name text);
create table public.zones(id uuid primary key default gen_random_uuid(), business_id uuid);
create table public.dining_tables(id uuid primary key default gen_random_uuid(), zone_id uuid);
create table public.table_sessions(id uuid primary key, business_id uuid, table_id uuid, customer_id uuid, customer_name text);
create table public.orders(id uuid primary key default gen_random_uuid(), session_id uuid,
  closed_at timestamptz, subtotal numeric default 100, tax numeric default 0,
  service_fee numeric default 0, discounts numeric default 0, total numeric default 100);
create table public.order_checks(id uuid primary key default gen_random_uuid(), order_id uuid,
  position integer default 1, is_closed boolean default false, closed_at timestamptz,
  requested_ncf_type public.ncf_type, subtotal numeric default 100, tax numeric default 0,
  service_fee numeric default 0, discounts numeric default 0, total numeric default 100);
create table public.payment_methods(id uuid primary key default gen_random_uuid(), business_id uuid, code text);
create table public.payments(id uuid primary key default gen_random_uuid(), business_id uuid,
  order_id uuid, check_id uuid, payment_method_id uuid, amount numeric default 100,
  change_amount numeric default 0, status text default 'completed',
  customer_id uuid, customer_rnc text, processed_by uuid, requested_ncf_type public.ncf_type,
  fiscal_document_id uuid, offline_ncf text, created_at timestamptz default clock_timestamp());
create table public.fiscal_settings(business_id uuid primary key, default_ncf_type public.ncf_type default 'B02',
  ecf_enabled boolean default false);
create table public.fiscal_documents(id uuid primary key default gen_random_uuid(), business_id uuid,
  order_id uuid, payment_id uuid, customer_id uuid, ncf_type public.ncf_type, ncf_number text,
  ncf_sequence_id uuid, customer_name text, customer_rnc text, subtotal numeric, taxable_amount numeric,
  itbis_amount numeric, service_fee numeric, total numeric, status text default 'active',
  ecf_status text, is_electronic boolean, offline_issued boolean default false,
  created_at timestamptz default clock_timestamp(),
  constraint fiscal_documents_business_id_ncf_number_key unique(business_id,ncf_number));
create table public.ncf_sequences(id uuid default gen_random_uuid(), business_id uuid,
  ncf_type public.ncf_type, prefix text, current_number bigint default 0, range_end bigint default 10000,
  is_active boolean default true, expiration_date date, created_at timestamptz default now());
create function public.generate_ncf(p_business_id uuid,p_type public.ncf_type) returns text
language plpgsql as $$
declare v_num bigint;
begin
  update public.ncf_sequences set current_number = current_number + 1
  where business_id = p_business_id and ncf_type = p_type returning current_number into v_num;
  return p_type::text || lpad(v_num::text,8,'0');
end $$;
insert into public.businesses values
  ('b0000000-0000-0000-0000-000000000001'), ('b0000000-0000-0000-0000-000000000002');
insert into public.business_settings(business_id) select id from public.businesses;
insert into public.table_sessions(id,business_id) select id,id from public.businesses;
insert into public.fiscal_settings(business_id) select id from public.businesses;
insert into public.payment_methods(business_id,code)
  select b.id,m.code from public.businesses b cross join (values ('cash'),('card'),('transfer')) m(code);
insert into public.ncf_sequences(business_id,ncf_type,prefix)
  select b.id,t.kind::public.ncf_type,t.kind from public.businesses b
  cross join (values ('B01'),('B02'),('E31'),('E32')) t(kind);
SQL

Q -f "$M/20260513_0002_fd_per_container.sql" >/dev/null
Q -f "$M/20260620_0003_fix_fiscal_document_per_check_reuse.sql" >/dev/null
Q -f "$M/20260910_0001_sales_notes.sql" >/dev/null
Q -f "$M/20261008_0002_sales_note_cash_cycle.sql" >/dev/null
Q -f "$M/20261008_0002_sales_note_cash_cycle.sql" >/dev/null

Q <<'SQL'
update public.business_settings set sales_note_enabled = true;
create function public.test_assert(p_ok boolean,p_message text) returns void language plpgsql as $$
begin
  if not coalesce(p_ok,false) then raise exception 'FAIL: %',p_message; end if;
  raise notice 'ok: %',p_message;
end $$;
create function public.test_open_sale(p_method text default 'cash',p_type public.ncf_type default 'B02',
  p_note boolean default true,p_business uuid default 'b0000000-0000-0000-0000-000000000001')
returns uuid language plpgsql as $$
declare v_order uuid;
begin
  insert into public.orders(session_id,is_sales_note) values (p_business,p_note) returning id into v_order;
  insert into public.order_checks(order_id,position) values (v_order,1);
  insert into public.payments(business_id,order_id,payment_method_id,requested_ncf_type)
    select p_business,v_order,pm.id,p_type from public.payment_methods pm
    where pm.business_id=p_business and pm.code=p_method;
  return v_order;
end $$;
create function public.test_sale(p_method text default 'cash',p_type public.ncf_type default 'B02',
  p_note boolean default true,p_business uuid default 'b0000000-0000-0000-0000-000000000001')
returns uuid language plpgsql as $$
declare v_order uuid;
begin
  v_order := public.test_open_sale(p_method,p_type,p_note,p_business);
  update public.orders set closed_at=clock_timestamp() where id=v_order;
  return v_order;
end $$;

do $$
declare o uuid; c uuid; p uuid; note_id uuid; n integer; b uuid := 'b0000000-0000-0000-0000-000000000001';
begin
  perform public.test_assert((select sales_note_limit=3 and sales_note_count=0 from business_settings where business_id=b),
    'default: tres notas y contador cero; migración reejecutable');
  for n in 1..3 loop
    o := public.test_sale();
    perform public.test_assert(exists(select 1 from sales_notes where order_id=o)
      and not exists(select 1 from fiscal_documents where order_id=o)
      and (select sales_note_count=n from business_settings where business_id=b),
      'efectivo consumo: nota '||n||' del ciclo');
  end loop;
  o := public.test_sale();
  perform public.test_assert(exists(select 1 from fiscal_documents where order_id=o and ncf_type='B02')
    and not exists(select 1 from sales_notes where order_id=o)
    and not (select is_sales_note from orders where id=o)
    and (select sales_note_count=0 from business_settings where business_id=b),
    'cuarto efectivo: factura automática, marca corregida y ciclo reiniciado');
  o := public.test_sale('cash','E32');
  select id into note_id from sales_notes where order_id=o;
  perform public.test_assert(note_id is not null,'consumo electrónico E32 permite nota');
  perform public.fn_issue_sales_note(o,null);
  perform public.test_assert((select sales_note_count=1 from business_settings where business_id=b)
    and (select count(*)=1 from sales_notes where order_id=o),'reintento no consume cuota ni duplica nota');
  select id into p from payments where order_id=o;
  select current_number into n from ncf_sequences where business_id=b and ncf_type='E32';
  begin
    perform public.issue_fiscal_document(o,p);
    raise exception 'FAIL: factura sobre nota activa';
  exception when others then
    if sqlerrm <> 'SALES_DOCUMENT_ALREADY_NOTED' then raise; end if;
  end;
  perform public.test_assert((select current_number=n from ncf_sequences where business_id=b and ncf_type='E32')
    and not exists(select 1 from fiscal_documents where order_id=o),
    'RPC fiscal sobre nota activa rechazado antes de generar NCF');
  perform set_config('test.authorized','off',true);
  perform set_config('test.role','service_role',true);
  perform public.fn_issue_sales_note(o,null);
  perform set_config('test.role','sql-admin',true);
  perform public.fn_issue_sales_note(o,null);
  perform set_config('test.role','authenticated',true);
  perform set_config('test.authorized','on',true);
  perform public.test_assert((select sales_note_count=1 from business_settings where business_id=b),
    'service_role y administrador SQL sin JWT conservan acceso confiable');
  update public.sales_notes set status='cancelled' where id=note_id;
  perform public.test_assert((select sales_note_count=1 from business_settings where business_id=b),
    'anulación conserva cantidad de notas utilizadas');

  foreach p in array array[(select id from payment_methods where business_id=b and code='card'),
                          (select id from payment_methods where business_id=b and code='transfer')] loop
    o := public.test_open_sale();
    update payments set payment_method_id=p where order_id=o;
    update orders set closed_at=clock_timestamp() where id=o;
    perform public.test_assert(exists(select 1 from fiscal_documents where order_id=o)
      and not exists(select 1 from sales_notes where order_id=o)
      and (select sales_note_count=1 from business_settings where business_id=b),
      'tarjeta/transferencia exige factura y conserva ciclo');
  end loop;
  o := public.test_sale('cash','B01');
  perform public.test_assert(exists(select 1 from fiscal_documents where order_id=o and ncf_type='B01')
    and (select sales_note_count=1 from business_settings where business_id=b),'crédito fiscal B01 efectivo exige factura');
  o := public.test_sale('card','E31');
  perform public.test_assert(exists(select 1 from fiscal_documents where order_id=o and ncf_type='E31')
    and (select sales_note_count=1 from business_settings where business_id=b),'crédito fiscal E31 tarjeta exige factura');
  o := public.test_sale('cash','B02',false);
  perform public.test_assert((select sales_note_count=0 from business_settings where business_id=b),
    'factura de consumo en efectivo elegida manualmente reinicia ciclo');

  o := public.test_open_sale();
  perform public.test_assert((select sales_note_count=0 from business_settings where business_id=b),
    'abono completado sin cerrar no consume cuota');
  insert into payments(business_id,order_id,payment_method_id,requested_ncf_type,amount)
    select b,o,id,'B02',50 from payment_methods where business_id=b and code='card';
  update orders set closed_at=clock_timestamp() where id=o;
  perform public.test_assert(exists(select 1 from fiscal_documents where order_id=o and total=150)
    and (select count(*)=2 from payments where order_id=o and fiscal_document_id is not null),
    'efectivo + tarjeta: una factura para TODOS los abonos');

  update business_settings set sales_note_limit=1 where business_id=b;
  o := public.test_sale();
  perform public.test_assert(exists(select 1 from sales_notes where order_id=o),'cuota configurable: primera nota');
  o := public.test_sale();
  perform public.test_assert(exists(select 1 from fiscal_documents where order_id=o)
    and (select sales_note_count=0 from business_settings where business_id=b),'cuota uno: segunda venta factura');

  -- Cuenta individual y remanente full-order con subcuentas existentes.
  o := public.test_open_sale();
  insert into order_checks(order_id,position,is_sales_note) values(o,2,true) returning id into c;
  update payments set check_id=c where order_id=o;
  update order_checks set is_closed=true where id=c;
  perform public.test_assert(exists(select 1 from sales_notes where order_id=o and check_id=c),
    'subcuenta individual cuenta una nota');
  insert into payments(business_id,order_id,payment_method_id,requested_ncf_type)
    select b,o,id,'B02' from payment_methods where business_id=b and code='cash';
  update orders set closed_at=clock_timestamp() where id=o;
  perform public.test_assert(exists(select 1 from fiscal_documents where order_id=o and check_id is null),
    'remanente full-order factura aunque existan subcuentas');

  o := public.test_sale('cash','B02',true,'b0000000-0000-0000-0000-000000000002');
  perform public.test_assert((select sales_note_count=1 from business_settings where business_id='b0000000-0000-0000-0000-000000000002')
    and (select sales_note_count=0 from business_settings where business_id=b),'contador aislado por negocio');

  update business_settings set sales_note_enabled=false where business_id=b;
  o := public.test_sale();
  perform public.test_assert(exists(select 1 from fiscal_documents where order_id=o),
    'notas deshabilitadas: siempre factura');
  update business_settings set sales_note_enabled=true,sales_note_limit=3 where business_id=b;
  o := public.test_sale();
  update business_settings set sales_note_limit=1,sales_note_prefix='TEST-' where business_id=b;
  perform public.test_assert((select sales_note_count=1 from business_settings where business_id=b),
    'guardar configuración no reinicia el contador');
  o := public.test_sale();
  perform public.test_assert(exists(select 1 from fiscal_documents where order_id=o),
    'bajar cuota por debajo del progreso exige factura');

  begin
    update business_settings set sales_note_count=99 where business_id=b;
    raise exception 'FAIL: contador editable';
  exception when others then
    if sqlerrm <> 'SALES_NOTE_COUNTER_READ_ONLY' then raise; end if;
  end;
  perform public.test_assert(true,'contador protegido contra edición directa');
  o := public.test_sale('card');
  begin
    perform public.fn_issue_sales_note(o,null);
    raise exception 'FAIL: RPC permite tarjeta';
  exception when others then
    if sqlerrm <> 'SALES_NOTE_REQUIRES_CASH_CONSUMER_FINAL' then raise; end if;
  end;
  perform public.test_assert(true,'RPC directo tampoco permite nota con tarjeta');
  perform set_config('test.authorized','off',true);
  begin
    perform public.fn_issue_sales_note(o,null);
    raise exception 'FAIL: acceso ajeno';
  exception when others then
    if sqlerrm <> 'UNAUTHORIZED_BUSINESS' then raise; end if;
  end;
  perform set_config('test.authorized','on',true);
  perform public.test_assert(true,'RPC valida pertenencia al negocio');
end $$;

do $$
declare
  b uuid := 'b0000000-0000-0000-0000-000000000001';
  b2 uuid := 'b0000000-0000-0000-0000-000000000002';
  o uuid; n uuid; p uuid; f uuid; z uuid; t uuid;
begin
  -- Una factura preemitida con abono conserva el ciclo hasta el cierre real.
  n := public.test_sale();
  o := public.test_open_sale('cash','B02',false);
  update public.payments set amount=40 where order_id=o;
  select (public.create_fiscal_document(o,null)).id into f;
  perform public.test_assert((select sales_note_count=1 from business_settings where business_id=b)
    and (select not sales_note_cycle_applied and total=40 from fiscal_documents where id=f),
    'factura preemitida con abono no reinicia ciclo antes del cierre');
  insert into payments(business_id,order_id,payment_method_id,requested_ncf_type,amount)
    select b,o,id,'B02',60 from payment_methods where business_id=b and code='cash';
  update orders set closed_at=clock_timestamp() where id=o;
  perform public.test_assert((select sales_note_count=0 from business_settings where business_id=b)
    and (select sales_note_cycle_applied and total=100 from fiscal_documents where id=f)
    and (select count(*)=2 from payments where order_id=o and fiscal_document_id=f),
    'cierre de factura preemitida aplica ciclo y repara todos los pagos/montos');
  n := public.test_sale();
  perform public.fn_apply_sales_note_invoice_cycle(f);
  perform public.fn_issue_sale_document(o,null,false);
  perform public.test_assert((select sales_note_count=1 from business_settings where business_id=b),
    'reintento de factura ya contabilizada no reinicia un ciclo posterior');
  perform public.test_sale('cash','B02',false);

  -- Una nota cancelada puede tener factura nueva. Reactivar ambos es inválido.
  o := public.test_sale();
  select id into n from sales_notes where order_id=o;
  update sales_notes set status='cancelled' where id=n;
  select id into p from payments where order_id=o;
  f := public.issue_fiscal_document(o,p);
  begin
    update sales_notes set status='active' where id=n;
    raise exception 'FAIL: nota e invoice activas';
  exception when others then
    if sqlerrm <> 'SALES_DOCUMENT_ALREADY_INVOICED' then raise; end if;
  end;
  update fiscal_documents set status='cancelled' where id=f;
  update sales_notes set status='active' where id=n;
  begin
    update fiscal_documents set status='active' where id=f;
    raise exception 'FAIL: invoice e nota activas';
  exception when others then
    if sqlerrm <> 'SALES_DOCUMENT_ALREADY_NOTED' then raise; end if;
  end;
  perform public.test_assert((select sales_note_count=0 from business_settings where business_id=b),
    'reactivación impide documento doble y no vuelve a contabilizar');
  insert into fiscal_documents(business_id,order_id,ncf_type,ncf_number,status)
    values(b,o,'B04','B04-CREDIT-NOTE','active');
  perform public.test_assert((select sales_note_count=0 from business_settings where business_id=b),
    'nota de crédito fiscal conserva ruta de anulación y no cambia el ciclo');

  -- Datos falsificados: el negocio del pago no puede reemplazar al de la orden.
  insert into orders(session_id,closed_at,is_sales_note) values(b2,now(),true) returning id into o;
  insert into payments(business_id,order_id,payment_method_id,requested_ncf_type)
    select b,o,id,'B02' from payment_methods where business_id=b and code='cash' returning id into p;
  begin
    perform public.fn_issue_sales_note(o,null);
    raise exception 'FAIL: nota con negocio falsificado';
  exception when others then
    if sqlerrm <> 'SALES_NOTE_SCOPE_NOT_FOUND' then raise; end if;
  end;
  begin
    perform public.issue_fiscal_document(o,p);
    raise exception 'FAIL: factura con negocio falsificado';
  exception when others then
    if sqlerrm <> 'NO_PAYMENTS_FOR_SCOPE' then raise; end if;
  end;
  begin
    insert into fiscal_documents(business_id,order_id,payment_id,ncf_type,ncf_number)
      values(b,o,p,'B02','B02-FORGED');
    raise exception 'FAIL: insert directo con negocio falsificado';
  exception when others then
    if sqlerrm <> 'SALES_DOCUMENT_BUSINESS_OUT_OF_SCOPE' then raise; end if;
  end;
  perform public.test_assert(not exists(select 1 from sales_notes where order_id=o)
    and not exists(select 1 from fiscal_documents where order_id=o),
    'negocio canónico de orden bloquea pagos e inserts falsificados');

  -- También se rechaza el scope completo si solo UN abono está falsificado.
  o := public.test_open_sale();
  select id into p from payments where order_id=o;
  insert into payments(business_id,order_id,payment_method_id,requested_ncf_type,amount)
    select b2,o,id,'B02',50 from payment_methods where business_id=b2 and code='cash';
  begin
    perform public.create_fiscal_document(o,null);
    raise exception 'FAIL: scope mixto de negocios';
  exception when others then
    if sqlerrm <> 'SALES_DOCUMENT_BUSINESS_OUT_OF_SCOPE' then raise; end if;
  end;
  begin
    perform public.issue_fiscal_document(o,p);
    raise exception 'FAIL: representativo válido permite abono ajeno';
  exception when others then
    if sqlerrm <> 'SALES_DOCUMENT_BUSINESS_OUT_OF_SCOPE' then raise; end if;
  end;
  perform public.test_assert(not exists(select 1 from public.fn_sales_note_policy_scope(o,null)),
    'cualquier abono de otro negocio invalida el scope completo');

  o := public.test_open_sale();
  update payments set payment_method_id=(select id from payment_methods where business_id=b2 and code='cash')
    where order_id=o;
  begin
    perform public.create_fiscal_document(o,null);
    raise exception 'FAIL: método de otro negocio';
  exception when others then
    if sqlerrm <> 'SALES_DOCUMENT_BUSINESS_OUT_OF_SCOPE' then raise; end if;
  end;
  perform public.test_assert(not exists(select 1 from public.fn_sales_note_policy_scope(o,null)),
    'método de pago de otro negocio invalida el scope');

  -- La rama de factura existente se protege ANTES de devolver/reparar links.
  o := public.test_open_sale('cash','B02',false);
  select (public.create_fiscal_document(o,null)).id into f;
  perform set_config('test.authorized','off',true);
  begin
    perform public.create_fiscal_document(o,null);
    raise exception 'FAIL: consulta de factura existente sin pertenencia';
  exception when others then
    if sqlerrm <> 'UNAUTHORIZED_BUSINESS' then raise; end if;
  end;
  perform set_config('test.role','service_role',true);
  perform public.create_fiscal_document(o,null);
  perform set_config('test.role','sql-admin',true);
  perform public.create_fiscal_document(o,null);
  perform set_config('test.role','authenticated',true);
  perform set_config('test.authorized','on',true);
  insert into payments(business_id,order_id,payment_method_id,requested_ncf_type,amount)
    select b2,o,id,'B02',50 from payment_methods where business_id=b2 and code='cash';
  begin
    perform public.create_fiscal_document(o,null);
    raise exception 'FAIL: abono ajeno enlazado a factura existente';
  exception when others then
    if sqlerrm <> 'SALES_DOCUMENT_BUSINESS_OUT_OF_SCOPE' then raise; end if;
  end;
  perform public.test_assert((select total=100 from fiscal_documents where id=f)
    and exists(select 1 from payments where order_id=o and business_id=b2 and fiscal_document_id is null),
    'factura existente conserva autorización y nunca enlaza un abono ajeno');

  -- Compatibilidad con sesiones antiguas cuyo business_id vive en la zona.
  insert into zones(business_id) values(b) returning id into z;
  insert into dining_tables(zone_id) values(z) returning id into t;
  update table_sessions set business_id=null,table_id=t where id=b;
  o := public.test_sale();
  perform public.test_assert(exists(select 1 from sales_notes where order_id=o),
    'sesión antigua resuelve negocio por mesa/zona');
  perform public.test_sale('cash','B02',false);
  update table_sessions set business_id=b,table_id=null where id=b;

  update business_settings set sales_note_limit=3 where business_id=b;
  o := public.test_open_sale('cash','B02',false);
  insert into order_checks(order_id,position,is_sales_note) values(o,2,true) returning id into n;
  update payments set check_id=n where order_id=o;
  update order_checks set is_closed=true where id=n;
  insert into payments(business_id,order_id,payment_method_id,requested_ncf_type)
    select b,o,id,'B02' from payment_methods where business_id=b and code='cash';
  update orders set closed_at=clock_timestamp() where id=o;
  perform public.test_assert(exists(select 1 from fiscal_documents where order_id=o and check_id is null)
    and (select sales_note_count=0 from business_settings where business_id=b),
    'nota de subcuenta cerrada no cambia factura manual del remanente');
end $$;
select public.test_assert(not has_function_privilege('authenticated',
  'public.fn_issue_sales_note_unchecked(uuid,uuid)','execute')
  and not has_function_privilege('authenticated','public.issue_fiscal_document_unchecked(uuid,uuid)','execute')
  and not has_function_privilege('authenticated','public.create_fiscal_document_unchecked(uuid,uuid)','execute')
  and not has_function_privilege('anon','public.fn_issue_sales_note(uuid,uuid)','execute'),
  'emisores sin guardia privados y anon sin acceso');
SQL

# Dos cajas que abrieron con cuota disponible compiten por el último lugar.
# La segunda debe esperar, emitir factura y reiniciar. No puede emitir otra nota.
Q -c "update public.business_settings set sales_note_limit=1 where business_id='b0000000-0000-0000-0000-000000000001'"
O1=$(Q -At -c 'select public.test_open_sale()')
O2=$(Q -At -c 'select public.test_open_sale()')
Q -c "begin; update public.orders set closed_at=clock_timestamp() where id='$O1'; select pg_sleep(1); commit;" >"$D/c1.out" 2>&1 &
P1=$!
sleep 0.2
Q -c "update public.orders set closed_at=clock_timestamp() where id='$O2'" >"$D/c2.out" 2>&1 &
P2=$!
wait "$P1" || { cat "$D/c1.out"; exit 1; }
wait "$P2" || { cat "$D/c2.out"; exit 1; }
Q -c "select public.test_assert((select count(*)=1 from public.sales_notes where order_id in ('$O1','$O2')) and (select count(*)=1 from public.fiscal_documents where order_id in ('$O1','$O2')) and (select sales_note_count=0 from public.business_settings where business_id='b0000000-0000-0000-0000-000000000001'), 'dos cajas simultáneas: exactamente una nota y una factura')"

# Llamada fiscal directa: el candado del ciclo precede al de ncf_sequences.
O3=$(Q -At -c 'select public.test_open_sale()')
O4=$(Q -At -c "select public.test_open_sale('cash','B02',false)")
P4=$(Q -At -c "select id from public.payments where order_id='$O4'")
Q -c "begin; select public.issue_fiscal_document('$O4','$P4'); select pg_sleep(1); commit;" >"$D/c3.out" 2>&1 &
P3=$!
sleep 0.2
Q -c "set statement_timeout='5s'; update public.orders set closed_at=clock_timestamp() where id='$O3'" >"$D/c4.out" 2>&1 &
P4=$!
wait "$P3" || { cat "$D/c3.out"; exit 1; }
wait "$P4" || { cat "$D/c4.out"; exit 1; }
Q -c "select public.test_assert(exists(select 1 from public.sales_notes where order_id='$O3') and exists(select 1 from public.fiscal_documents where order_id='$O4'), 'RPC fiscal directo y cierre simultáneo sin inversión de candados')"

Q -f "$M/20261008_0002_sales_note_cash_cycle_ROLLBACK.sql" >/dev/null
Q -f "$M/20261008_0002_sales_note_cash_cycle_ROLLBACK.sql" >/dev/null
Q -c "select public.test_assert(to_regprocedure('public.fn_issue_sales_note_unchecked(uuid,uuid)') is null and to_regprocedure('public.issue_fiscal_document_unchecked(uuid,uuid)') is null and to_regprocedure('public.create_fiscal_document_unchecked(uuid,uuid)') is null and (select sales_note_count=1 from public.business_settings where business_id='b0000000-0000-0000-0000-000000000001') and exists(select 1 from public.sales_notes where order_id='$O3'), 'rollback reejecutable restaura emisores y conserva documentos/contador')"
Q -f "$M/20261008_0002_sales_note_cash_cycle.sql" >/dev/null
Q -c "select public.test_assert((select sales_note_count=1 from public.business_settings where business_id='b0000000-0000-0000-0000-000000000001'), 'reaplicar migración preserva ciclo')"
echo "TODO OK: política de notas de venta y concurrencia"
