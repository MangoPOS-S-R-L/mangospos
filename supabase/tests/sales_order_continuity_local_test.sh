#!/usr/bin/env bash
# Base Postgres desechable que modela el punto de partida VIVO de las aperturas
# de venta (sin base remota):
#   · privilegios por defecto de Supabase (EXECUTE a anon/authenticated/service_role),
#   · cuerpos previos del repo cargados TAL CUAL desde sus archivos
#     (20260408_0002, 20260526_0003, 20260602_0004, schema.sql, 20260709_0001,
#     20260624_0001) más el overload legacy de 3 argumentos sobreviviente,
#   · uniq_open_session_per_table, dining_tables_zone_id_code_key y el trigger
#     que fija table_sessions.business_id,
#   · ventas vivas creadas con las funciones VIEJAS antes de migrar.
# Luego: deriva viva (aborta sin cambios) → forward x2 → casos → concurrencia →
# ROLLBACK → forward → humo.
set -euo pipefail
REPO=$(cd "$(dirname "$0")/../.." && pwd)
M=$REPO/supabase/migrations
FWD=$M/20261009_0004_sales_order_continuity.sql
RBK=$M/20261009_0004_sales_order_continuity_ROLLBACK.sql
PG=${PG_BIN:-/opt/homebrew/opt/postgresql@15/bin}
PORT=${PG_PORT:-55457}
WORK=${1:-$(mktemp -d)}
mkdir -p "$WORK"
D=$(mktemp -d "$WORK/pg_sales_continuity.XXXXXX")
"$PG/initdb" -D "$D/data" -U postgres --auth=trust >/dev/null
"$PG/pg_ctl" -D "$D/data" -o "-p $PORT -c listen_addresses=127.0.0.1 -c unix_socket_directories=''" -l "$D/log" start -w >/dev/null
trap '"$PG/pg_ctl" -D "$D/data" stop -m fast >/dev/null 2>&1' EXIT
Q() { "$PG/psql" -h 127.0.0.1 -p "$PORT" -U postgres -X -q -v ON_ERROR_STOP=1 "$@"; }
# Igual que Q, pero con la identidad JWT del usuario indicado (auth.uid()).
QU() { local uid=$1; shift; PGOPTIONS="-c request.jwt.claim.sub=$uid" Q "$@"; }
U1=a0000000-0000-0000-0000-000000000001
U2=a0000000-0000-0000-0000-000000000002
B2=b0000000-0000-0000-0000-000000000002
B4=b0000000-0000-0000-0000-000000000004
B9=b0000000-0000-0000-0000-000000000009

# ─── 1. Esquema base con los nombres/tipos/índices reales ───────────────────
Q <<'SQL'
create role anon; create role authenticated; create role service_role;
-- Supabase: toda función nueva de postgres en public nace con EXECUTE para
-- anon, authenticated y service_role (schema.sql: ALTER DEFAULT PRIVILEGES).
alter default privileges in schema public grant all on functions to anon, authenticated, service_role;
create schema auth;
grant usage on schema auth to anon, authenticated, service_role;
-- Como Supabase: auth.uid() sale del claim 'sub' del JWT; sin JWT es null.
create function auth.uid() returns uuid language sql stable as $$
  select nullif(coalesce(nullif(current_setting('request.jwt.claim.sub', true), ''),
    nullif(current_setting('request.jwt.claims', true), '')::jsonb ->> 'sub'), '')::uuid
$$;
create type public.order_origin as enum ('dine_in','manual','quick','delivery','self_service');
create type public.order_status as enum ('open','sent_to_kitchen','partially_paid','paid','void');
create type public.item_status as enum ('pending','preparing','ready','served','void','draft','paid');
create type public.table_shape as enum ('square','circle');
create type public.table_state as enum ('available','occupied','reserved','blocked');
create table public.businesses(id uuid primary key, owner_id uuid not null,
  business_name text not null, created_at timestamptz not null default now());
create table public.memberships(id uuid primary key default gen_random_uuid(),
  user_id uuid not null, business_id uuid not null);
create table public.user_businesses(id uuid primary key default gen_random_uuid(),
  user_id uuid not null, business_id uuid not null, role text not null default 'owner',
  created_at timestamptz not null default now(),
  shared_across_branches boolean not null default false);
create table public.zones(id uuid primary key default gen_random_uuid(), business_id uuid not null,
  branch_id uuid, name text not null, sort_index integer not null default 0,
  is_active boolean not null default true, created_at timestamptz default clock_timestamp());
create table public.dining_tables(id uuid primary key default gen_random_uuid(),
  zone_id uuid not null references public.zones(id), code text not null, label text,
  shape public.table_shape not null default 'square', capacity integer not null default 4,
  pos_x numeric not null default 0, pos_y numeric not null default 0,
  width numeric not null default 1, height numeric not null default 1,
  rotation numeric not null default 0,
  state public.table_state not null default 'available', is_active boolean not null default true,
  created_at timestamptz default clock_timestamp(),
  constraint dining_tables_zone_id_code_key unique (zone_id, code));
create table public.table_sessions(id uuid primary key default gen_random_uuid(),
  table_id uuid not null references public.dining_tables(id), opened_by uuid not null,
  opened_at timestamptz not null default clock_timestamp(), closed_at timestamptz,
  customer_name text, note text,
  origin public.order_origin not null default 'dine_in', waiter_user_id uuid,
  people_count integer not null default 1, business_id uuid, delivery_type text);
create unique index uniq_open_session_per_table on public.table_sessions using btree (table_id)
  where (closed_at is null);
create table public.orders(id uuid primary key default gen_random_uuid(),
  session_id uuid not null references public.table_sessions(id),
  status text not null default 'open'
    check (status = any (array['open','sent','served','canceled','paid'])),
  total_amount numeric(12,2) default 0, created_at timestamptz default clock_timestamp(),
  status_ext public.order_status not null default 'open',
  subtotal numeric(12,2) not null default 0, discounts numeric(12,2) not null default 0,
  service_fee numeric(12,2) not null default 0, tax numeric(12,2) not null default 0,
  total numeric(12,2) not null default 0, closed_at timestamptz);
create table public.order_checks(id uuid primary key default gen_random_uuid(),
  order_id uuid not null references public.orders(id), label text not null default 'C1',
  position integer not null default 1, is_closed boolean not null default false,
  closed_at timestamptz, total numeric(12,2) not null default 0);
create table public.order_items(id uuid primary key default gen_random_uuid(),
  order_id uuid references public.orders(id), quantity integer not null default 1,
  unit_price numeric(10,2) not null default 0, status public.item_status default 'draft',
  created_at timestamptz default clock_timestamp());
create table public.payments(id uuid primary key default gen_random_uuid(), business_id uuid not null,
  order_id uuid, amount numeric not null, status text default 'completed');

-- Ayudas de prueba.
create function public.tu(n int) returns uuid language sql immutable as $$
  select ('a0000000-0000-0000-0000-' || lpad(n::text, 12, '0'))::uuid $$;
create function public.tb(n int) returns uuid language sql immutable as $$
  select ('b0000000-0000-0000-0000-' || lpad(n::text, 12, '0'))::uuid $$;
create function public.test_as(p uuid) returns void language plpgsql as $$
begin perform set_config('request.jwt.claim.sub', coalesce(p::text, ''), false); end $$;
create function public.test_assert(ok boolean, message text) returns void language plpgsql as $$
begin
  if not coalesce(ok, false) then raise exception 'FAIL: %', message; end if;
  raise notice 'ok: %', message;
end $$;
create function public.test_expect_error(p_sql text, p_pattern text) returns void
language plpgsql as $$
begin
  begin
    execute p_sql;
  exception when others then
    if sqlerrm not like p_pattern then
      raise exception 'FAIL: % → esperaba [%], obtuvo [%]', p_sql, p_pattern, sqlerrm;
    end if;
    raise notice 'ok: rechazado [%]', sqlerrm;
    return;
  end;
  raise exception 'FAIL: sin error: %', p_sql;
end $$;
-- Mesa y estado de la venta que devolvió una apertura.
create function public.test_code(r jsonb) returns text language sql as $$
  select dt.code from public.table_sessions ts join public.dining_tables dt on dt.id = ts.table_id
  where ts.id = (r->>'session_id')::uuid $$;
create function public.test_label(r jsonb) returns text language sql as $$
  select dt.label from public.table_sessions ts join public.dining_tables dt on dt.id = ts.table_id
  where ts.id = (r->>'session_id')::uuid $$;
create function public.test_session_business(r jsonb) returns uuid language sql as $$
  select business_id from public.table_sessions where id = (r->>'session_id')::uuid $$;
create table public.test_expected_void(id uuid primary key);

-- Negocios: U1 directo en B1 (2020), B2 (2021), B4, B7, B8, B9; U2 directo en B1.
-- OWNER (tu 3) es owner_id de B3 (2019), B5 (2022) y B6 (2023) SIN filas directas.
-- SHARED (tu 5) tiene fila compartida en B6 → accede a B3/B5/B6. OUTSIDER (tu 4): nada.
insert into businesses(id, owner_id, business_name, created_at) values
  (tb(1), tu(1), 'B1', '2020-01-01'), (tb(2), tu(1), 'B2', '2021-01-01'),
  (tb(3), tu(3), 'B3', '2019-01-01'), (tb(4), tu(1), 'B4', '2021-06-01'),
  (tb(5), tu(3), 'B5', '2022-01-01'), (tb(6), tu(3), 'B6', '2023-01-01'),
  (tb(7), tu(1), 'B7', '2021-07-01'), (tb(8), tu(1), 'B8', '2021-08-01'),
  (tb(9), tu(1), 'B9', '2021-09-01');
insert into user_businesses(user_id, business_id, created_at, shared_across_branches) values
  (tu(1), tb(1), '2020-01-01', false), (tu(1), tb(2), '2021-01-01', false),
  (tu(1), tb(4), '2021-06-01', false), (tu(1), tb(7), '2021-07-01', false),
  (tu(1), tb(8), '2021-08-01', false), (tu(1), tb(9), '2021-09-01', false),
  (tu(2), tb(1), '2020-02-01', false), (tu(2), tb(4), '2021-06-02', false),
  (tu(5), tb(6), '2023-01-01', true);
SQL

# ─── 2. Cuerpos previos del repo, tal cual ──────────────────────────────────
python3 - "$REPO/supabase" "$D/prev" <<'PY'
from pathlib import Path
import sys
root, out = Path(sys.argv[1]), Path(sys.argv[2])
out.mkdir()
def cut(rel, start, end_marker='$$;', extra=''):
    s = (root / rel).read_text()
    a = s.index(start)
    b = s.index(end_marker, a) + len(end_marker)
    return s[a:b] + '\n' + extra
schema = 'schema.sql'
base = ''.join([
    cut('migrations/20260709_0001_shared_user_across_branches.sql',
        'create or replace function public.current_user_business_ids()'),
    cut(schema, 'CREATE OR REPLACE FUNCTION "public"."set_table_session_business_id"()',
        extra='CREATE OR REPLACE TRIGGER "set_business_id_on_table_session" BEFORE INSERT ON '
              '"public"."table_sessions" FOR EACH ROW EXECUTE FUNCTION '
              '"public"."set_table_session_business_id"();\n'),
    cut('migrations/20260624_0001_close_checks_on_order_close.sql',
        'CREATE OR REPLACE FUNCTION public.fn_close_order_and_table(', '$function$;'),
    cut(schema, 'CREATE OR REPLACE FUNCTION "public"."fn_get_or_create_virtual_table"(',
        extra=''.join(f'GRANT ALL ON FUNCTION "public"."fn_get_or_create_virtual_table"('
                      f'"p_business_id" "uuid", "p_origin" "public"."order_origin") TO "{r}";\n'
                      for r in ('anon', 'authenticated', 'service_role'))),
])
(out / '01_base.sql').write_text(base)
# Overload legacy de 3 argumentos (schema.sql: GRANT ALL TO anon).
legacy3 = cut('migrations/20260526_0003_fix_open_manual_or_quick_business_scope_ROLLBACK.sql',
              'create or replace function public.fn_open_manual_or_quick(',
              extra='grant all on function public.fn_open_manual_or_quick(public.order_origin, uuid, integer) '
                    'to anon, authenticated, service_role;\n')
(out / '02_legacy3.sql').write_text(legacy3)
(out / '05_delivery3.sql').write_text(
    cut('migrations/20260408_0002_delivery_system.sql',
        'CREATE OR REPLACE FUNCTION public.fn_open_delivery_order(',
        'GRANT EXECUTE ON FUNCTION public.fn_open_delivery_order(uuid, text, int) TO authenticated;'))
PY
Q -f "$D/prev/01_base.sql" >/dev/null
Q -f "$D/prev/02_legacy3.sql" >/dev/null
Q -f "$M/20260526_0003_fix_open_manual_or_quick_business_scope.sql" >/dev/null
Q -f "$M/20260602_0004_open_retail_cart.sql" >/dev/null
Q -f "$D/prev/05_delivery3.sql" >/dev/null
# Deriva viva posible: el overload de 3 argumentos sobrevivió a 20260526_0003.
Q -f "$D/prev/02_legacy3.sql" >/dev/null
Q <<'SQL'
select test_assert(has_function_privilege('anon',
  'public.fn_open_manual_or_quick(public.order_origin,uuid,integer,uuid)', 'execute'),
  'fixture: punto de partida con EXECUTE para anon (privilegios por defecto de Supabase)');
select test_assert((select count(*) = 2 from pg_proc where proname = 'fn_open_manual_or_quick'),
  'fixture: overloads legacy de 3 y 4 argumentos conviven antes de migrar');
SQL

# ─── 3. Datos vivos creados con las funciones VIEJAS ────────────────────────
Q <<'SQL'
select test_as(tu(1));
do $$
declare r jsonb; o uuid; z uuid; t uuid; s uuid;
begin
  -- B1: venta rápida VIVA con productos y abono en la mesa compartida 'quick'.
  r := fn_open_manual_or_quick('quick', tu(1), 1, tb(1));
  o := (r->>'order_id')::uuid;
  insert into order_items(order_id, quantity, unit_price, status) values (o, 2, 125, 'pending');
  insert into payments(business_id, order_id, amount) values (tb(1), o, 100);
  update orders set total = 250, status_ext = 'partially_paid' where id = o;
  -- B1: mesa 'manual' con sesión ABIERTA sin orden viva (cobrada, sesión quedó abierta).
  r := fn_open_manual_or_quick('manual', tu(1), 1, tb(1));
  update orders set status_ext = 'paid', status = 'paid', closed_at = now()
    where id = (r->>'order_id')::uuid;
  -- B1: zona acentuada creada por apps viejas, con su propia mesa 'quick' viva.
  insert into zones(business_id, name, sort_index) values (tb(1), 'Ventas rápidas', 901)
    returning id into z;
  insert into dining_tables(zone_id, code, label) values (z, 'quick', 'Venta rápida Auto')
    returning id into t;
  insert into table_sessions(table_id, opened_by, origin) values (t, tu(1), 'quick')
    returning id into s;
  insert into orders(session_id, total) values (s, 80) returning id into o;
  insert into order_items(order_id, quantity, unit_price, status) values (o, 1, 80, 'pending');
end $$;
create table test_snap_premig as
  select 'o' as k, id, md5(row(o.*)::text) as h from orders o
  union all select 's', id, md5(row(s.*)::text) from table_sessions s
  union all select 't', id, md5(row(t.*)::text) from dining_tables t
  union all select 'z', id, md5(row(z.*)::text) from zones z
  union all select 'i', id, md5(row(i.*)::text) from order_items i
  union all select 'p', id, md5(row(p.*)::text) from payments p;
SQL

# ─── 3b. Deriva viva de cuerpos: la migración aborta ANTES de tocar nada ────
# CREATE OR REPLACE reemplaza un cuerpo distinto sin error. La verificación
# previa de 0004 aborta si algún overload vivo trae guardas que el repo no tiene
# (fn_require_open_cash_session / ORIGIN_NOT_ALLOWED, sin distinguir mayúsculas).
# Cuerpo real del volcado vivo: el overload de 3 argumentos con ambas guardas.
python3 - "$REPO" "$D/prev/06_live3_backup.sql" <<'PY'
from pathlib import Path
import sys
s = (Path(sys.argv[1]) / 'database/supabase_backup.sql').read_text()
a = s.index('CREATE FUNCTION public.fn_open_manual_or_quick(p_origin public.order_origin, '
            'p_user_id uuid, p_people_count integer DEFAULT 1)')
b = s.index('$$;', a) + 3
Path(sys.argv[2]).write_text(s[a:b].replace('CREATE FUNCTION', 'CREATE OR REPLACE FUNCTION', 1) + '\n')
PY
Q <<'SQL'
create table test_fn_fixture as
  select p.oid::regprocedure::text as sig, pg_get_functiondef(p.oid) as def
  from pg_proc p where p.pronamespace = 'public'::regnamespace and p.prokind = 'f';
-- Huella del catálogo (cuerpo, ACL y dueño de cada función de public) y de los datos.
create view test_state as
  select 'f' as k, p.oid::regprocedure::text as id,
    md5(pg_get_functiondef(p.oid) || coalesce(p.proacl::text, '') || p.proowner::text) as h
  from pg_proc p where p.pronamespace = 'public'::regnamespace and p.prokind = 'f'
  union all select 'o', id::text, md5(row(o.*)::text) from orders o
  union all select 's', id::text, md5(row(s.*)::text) from table_sessions s
  union all select 't', id::text, md5(row(t.*)::text) from dining_tables t
  union all select 'z', id::text, md5(row(z.*)::text) from zones z
  union all select 'c', id::text, md5(row(c.*)::text) from order_checks c
  union all select 'i', id::text, md5(row(i.*)::text) from order_items i
  union all select 'p', id::text, md5(row(p.*)::text) from payments p;
-- Deriva simulada: una línea extra al inicio del cuerpo vivo (misma firma).
create function public.test_inject(p_sig text, p_line text) returns void language plpgsql as $$
begin
  execute regexp_replace(pg_get_functiondef(p_sig::regprocedure), '\mbegin\M',
    'begin' || chr(10) || '  ' || p_line, 'i');
end $$;
-- Devuelve cada función al cuerpo del fixture (CREATE OR REPLACE conserva el ACL).
create function public.test_restore_fixture() returns void language plpgsql as $$
declare r record;
begin
  for r in select f.def from test_fn_fixture f
           where pg_get_functiondef(f.sig::regprocedure) <> f.def loop
    execute r.def;
  end loop;
end $$;
SQL
# Uso: drift_case <descripción> <texto esperado en el aviso> <SQL que deja la deriva>
drift_case() {
  Q -c "$3" >/dev/null
  Q -c "create table test_state_pre as select * from test_state" >/dev/null
  if Q -f "$FWD" >"$D/drift.log" 2>&1; then
    cat "$D/drift.log"; echo "FAIL: deriva viva ($1): la migración se aplicó"; exit 1
  fi
  if ! grep -q '20261009_0004 abortada, no se cambió nada' "$D/drift.log" \
     || ! grep -qF -- "$2" "$D/drift.log"; then
    cat "$D/drift.log"; echo "FAIL: deriva viva ($1): aviso inesperado"; exit 1
  fi
  Q -v descr="$1" <<'SQL'
select test_assert((select count(*) = 0 from test_state a full join test_state_pre b using (k, id)
    where a.h is distinct from b.h),
  'deriva viva (' || :'descr' || '): la migración aborta sin cambiar nada');
drop table test_state_pre;
select test_restore_fixture();
SQL
}
drift_case 'overload de 3 argumentos del volcado vivo, antes del drop' \
  'fn_open_manual_or_quick(order_origin,uuid,integer) [fn_require_open_cash_session, ORIGIN_NOT_ALLOWED]' \
  "\\i $D/prev/06_live3_backup.sql"
drift_case 'misma firma de 4 argumentos con guarda de caja en mayúsculas' \
  'fn_open_manual_or_quick(order_origin,uuid,integer,uuid) [fn_require_open_cash_session]' \
  "select test_inject('public.fn_open_manual_or_quick(public.order_origin,uuid,integer,uuid)',
     'PERFORM PUBLIC.FN_REQUIRE_OPEN_CASH_SESSION(V_USER_ID);')"
drift_case 'carrito retail con ORIGIN_NOT_ALLOWED' \
  'fn_open_retail_cart(uuid,uuid,text,integer) [ORIGIN_NOT_ALLOWED]' \
  "select test_inject('public.fn_open_retail_cart(uuid,uuid,text,integer)',
     'if p_slot is null then raise exception ''Origin_Not_Allowed''; end if;')"
drift_case 'delivery de 3 argumentos con guarda de caja' \
  'fn_open_delivery_order(uuid,text,integer) [fn_require_open_cash_session]' \
  "select test_inject('public.fn_open_delivery_order(uuid,text,integer)',
     'perform public.fn_require_open_cash_session(p_user_id);')"
Q <<'SQL'
select test_assert((select count(*) = 0 from test_fn_fixture f
    where pg_get_functiondef(f.sig::regprocedure) <> f.def)
  and (select count(*) = 2 from pg_proc where proname = 'fn_open_manual_or_quick')
  and to_regprocedure('public.fn_sales_virtual_open(text,uuid,uuid,public.order_origin,integer,text)') is null,
  'deriva viva: el fixture vuelve a sus cuerpos previos y nada de 0004 quedó instalado');
SQL

# ─── 4. Forward dos veces ───────────────────────────────────────────────────
# Sin esas guardas en los cuerpos vivos, la migración aplica.
Q -f "$FWD" >/dev/null
Q -f "$FWD" >/dev/null

# Permisos y overloads: se reutiliza tras cada forward.
Q <<'SQL'
create function public.test_check_forward_shape() returns void language plpgsql as $$
declare f text;
begin
  foreach f in array array[
    'public.fn_open_manual_or_quick(public.order_origin,uuid,integer,uuid)',
    'public.fn_open_retail_cart(uuid,uuid,text,integer)',
    'public.fn_open_offline_sale(uuid,uuid,text,public.order_origin,integer)',
    'public.fn_open_delivery_order(uuid,text,integer,uuid)',
    'public.fn_open_delivery_order(uuid,text,integer)'] loop
    perform test_assert(not has_function_privilege('anon', f, 'execute')
      and not has_function_privilege('public', f, 'execute')
      and has_function_privilege('authenticated', f, 'execute')
      and has_function_privilege('service_role', f, 'execute'),
      'ACL ' || f || ': sin anon/PUBLIC; authenticated y service_role sí');
  end loop;
  foreach f in array array[
    'public.fn_sales_open_actor(uuid,text)',
    'public.fn_sales_user_can_open(uuid,uuid)',
    'public.fn_sales_default_business(uuid)',
    'public.fn_sales_virtual_open(text,uuid,uuid,public.order_origin,integer,text)',
    'public.fn_get_or_create_virtual_table(uuid,public.order_origin)'] loop
    perform test_assert(not has_function_privilege('anon', f, 'execute')
      and not has_function_privilege('authenticated', f, 'execute')
      and not has_function_privilege('public', f, 'execute'),
      'ACL ' || f || ': interna, sin EXECUTE para clientes');
  end loop;
  perform test_assert(
    to_regprocedure('public.fn_open_manual_or_quick(public.order_origin,uuid,integer)') is null
    and (select count(*) = 1 from pg_proc where proname = 'fn_open_manual_or_quick'),
    'un solo fn_open_manual_or_quick (el de 4 argumentos); el de 3 se eliminó');
  perform test_assert((select count(*) = 2 from pg_proc where proname = 'fn_open_delivery_order')
    and (select pronargdefaults = 0 from pg_proc
         where oid = 'public.fn_open_delivery_order(uuid,text,integer,uuid)'::regprocedure),
    'delivery: overloads 3/4 sin ambigüedad (el de 4 sin defaults)');
  perform test_assert((select count(*) = 1 from pg_proc where proname = 'fn_open_retail_cart')
    and (select count(*) = 1 from pg_proc where proname = 'fn_open_offline_sale'),
    'retail y offline con una sola firma');
end $$;
select test_check_forward_shape();
select test_assert((select count(*) = 0 from (
    select 'o' as k, id, md5(row(o.*)::text) as h from orders o
    union all select 's', id, md5(row(s.*)::text) from table_sessions s
    union all select 't', id, md5(row(t.*)::text) from dining_tables t
    union all select 'z', id, md5(row(z.*)::text) from zones z
    union all select 'i', id, md5(row(i.*)::text) from order_items i
    union all select 'p', id, md5(row(p.*)::text) from payments p
  ) now_ full join test_snap_premig b using (k, id)
  where now_.h is distinct from b.h),
  'aplicar la migración dos veces no modifica ni una fila');
SQL

# Roles reales: anon rechazado por permisos; authenticated abre.
Q <<'SQL'
select test_as(tu(1));
set role anon;
do $$
declare f text;
begin
  foreach f in array array[
    'select fn_open_manual_or_quick(''quick'', tu(1), 1, tb(1))',
    'select fn_open_retail_cart(tb(1), tu(1), ''quick-anon'', 1)',
    'select fn_open_offline_sale(tb(1), tu(1), ''manual-anon'', ''manual'', 1)',
    'select fn_open_delivery_order(tu(1), ''own'', 1, tb(1))',
    'select fn_open_delivery_order(tu(1))',
    'select fn_get_or_create_virtual_table(tb(1), ''quick'')'] loop
    begin
      execute f;
      raise exception 'FAIL: anon ejecutó %', f;
    exception when insufficient_privilege then
      raise notice 'ok: anon sin EXECUTE: %', f;
    end;
  end loop;
end $$;
reset role;
set role authenticated;
do $$
declare r jsonb;
begin
  r := fn_open_manual_or_quick('quick', tu(1), 1, tb(2));
  perform test_assert(r ? 'order_id' and r ? 'session_id', 'authenticated abre venta con su JWT');
  begin
    perform fn_sales_virtual_open('x', tb(2), tu(1), 'quick', 1, null);
    raise exception 'FAIL: authenticated ejecutó el helper interno';
  exception when insufficient_privilege then
    raise notice 'ok: authenticated no ejecuta helpers internos';
  end;
end $$;
reset role;
SQL

# ─── 5. Casos funcionales ───────────────────────────────────────────────────
Q <<'SQL'
select test_as(tu(1));
do $$
declare
  r jsonb; r2 jsonb; r3 jsonb; r4 jsonb; o uuid; s uuid; t uuid; prev uuid;
  legacy_quick uuid; legacy_manual_table uuid; kind public.order_origin;
begin
  select o2.id into legacy_quick from orders o2 join table_sessions ts on ts.id = o2.session_id
    join dining_tables dt on dt.id = ts.table_id join zones z on z.id = dt.zone_id
    where z.business_id = tb(1) and z.name = 'Ventas rapidas' and dt.code = 'quick';

  -- Carril ocupado por la venta viva previa → la siguiente toma 'quick#2'.
  r := fn_open_manual_or_quick('quick', tu(1), 1, tb(1));
  perform test_assert(test_code(r) = 'quick#2' and test_label(r) = 'Venta rapida 2'
    and r->>'table_code' = 'quick#2' and (r->>'resumed')::boolean = false,
    'mesa compartida ocupada: venta nueva en carril quick#2 "Venta rapida 2"');
  perform test_assert(test_session_business(r) = tb(1)
    and (select origin = 'quick' and opened_by = tu(1) from table_sessions
         where id = (r->>'session_id')::uuid),
    'sesión del carril en la sucursal pedida, origen quick, abierta por el cajero');
  perform test_assert(r->>'order_id' <> legacy_quick::text, 'nunca devuelve la venta viva de otra caja');

  -- Solo-nueva: el mismo usuario vuelve a abrir → otro carril, nunca retoma.
  r2 := fn_open_manual_or_quick('quick', tu(1), 1, tb(1));
  perform test_assert(test_code(r2) = 'quick#3' and r2->>'order_id' <> r->>'order_id',
    'reabrir es SIEMPRE venta nueva (quick#3)');
  -- Otro cajero → otro carril.
  perform test_as(tu(2));
  r3 := fn_open_manual_or_quick('quick', tu(2), 1, tb(1));
  perform test_assert(test_code(r3) = 'quick#4', 'otro cajero recibe su propio carril');
  perform test_as(tu(1));

  -- Nunca anula: la venta previa con productos y abono sigue intacta.
  perform test_assert((select status_ext = 'partially_paid' and closed_at is null and total = 250
      from orders where id = legacy_quick)
    and (select count(*) = 1 from order_items where order_id = legacy_quick)
    and (select count(*) = 1 from payments where order_id = legacy_quick),
    'la venta con productos y abono sigue intacta');

  -- Sesión abierta sin orden viva en 'manual' → se cierra y abre sin 23505.
  select dt.id into legacy_manual_table from dining_tables dt join zones z on z.id = dt.zone_id
    where z.business_id = tb(1) and z.name = 'Ventas manuales' and dt.code = 'manual';
  select id into prev from table_sessions where table_id = legacy_manual_table and closed_at is null;
  r := fn_open_manual_or_quick('manual', tu(1), 1, tb(1));
  perform test_assert(test_code(r) = 'manual' and test_label(r) = 'Venta manual auto',
    'sesión abierta sin orden viva: reutiliza la mesa manual (sin 23505)');
  perform test_assert((select closed_at is not null from table_sessions where id = prev)
    and (select count(*) = 1 from table_sessions where table_id = legacy_manual_table and closed_at is null)
    and (r->>'session_id')::uuid <> prev,
    'la sesión vacía se cierra y la venta nueva tiene sesión propia');

  -- Cobro libera el carril: se reutiliza con sesión nueva.
  r := fn_open_manual_or_quick('manual', tu(1), 1, tb(2));
  perform test_assert(test_code(r) = 'manual' and test_label(r) = 'Venta manual',
    'primer carril manual de B2: mesa "manual" con etiqueta "Venta manual"');
  perform fn_close_order_and_table((r->>'order_id')::uuid, 'paid');
  r2 := fn_open_manual_or_quick('manual', tu(1), 1, tb(2));
  perform test_assert(test_code(r2) = 'manual' and r2->>'session_id' <> r->>'session_id',
    'tras cobrar, el mismo carril se reutiliza con sesión nueva');

  -- Sesión abierta con CERO órdenes (barrido/traslado) → sin 23505.
  t := (select table_id from table_sessions where id = (r2->>'session_id')::uuid);
  perform fn_close_order_and_table((r2->>'order_id')::uuid, 'void');
  insert into test_expected_void values ((r2->>'order_id')::uuid);
  insert into table_sessions(table_id, opened_by, origin) values (t, tu(1), 'manual') returning id into s;
  r3 := fn_open_manual_or_quick('manual', tu(1), 1, tb(2));
  perform test_assert(test_code(r3) = 'manual'
    and (select closed_at is not null from table_sessions where id = s),
    'sesión abierta sin órdenes: se cierra y se abre venta nueva sin 23505');
  -- Sesión abierta con solo órdenes anuladas → sin 23505.
  perform fn_close_order_and_table((r3->>'order_id')::uuid, 'paid');
  insert into table_sessions(table_id, opened_by, origin) values (t, tu(1), 'manual') returning id into s;
  insert into orders(session_id, status_ext, status, closed_at) values (s, 'void', 'canceled', now())
    returning id into o;
  insert into test_expected_void values (o);
  r4 := fn_open_manual_or_quick('manual', tu(1), 1, tb(2));
  perform test_assert(test_code(r4) = 'manual'
    and (select count(*) = 1 from table_sessions where table_id = t and closed_at is null),
    'sesión abierta con solo anuladas: venta nueva, una sola sesión abierta');

  -- Validación y fallback determinista.
  perform test_expect_error('select fn_open_manual_or_quick(''delivery'', tu(1), 1, tb(1))',
    'fn_open_manual_or_quick: invalid origin delivery');
  r := fn_open_manual_or_quick('quick', tu(1));
  perform test_assert(r->>'business_id' = tb(1)::text and test_session_business(r) = tb(1),
    'sin sucursal: negocio de la fila directa más antigua (B1)');
  r := fn_open_manual_or_quick('quick', null, 1, tb(1));
  perform test_assert((select opened_by = tu(1) from table_sessions where id = (r->>'session_id')::uuid),
    'p_user_id null con JWT: el actor es auth.uid()');

  -- Cambio de sucursal: carriles y órdenes de cada negocio separados.
  perform test_assert((select bool_and(z.business_id = tb(2)) from table_sessions ts
      join dining_tables dt on dt.id = ts.table_id join zones z on z.id = dt.zone_id
      where ts.business_id = tb(2) and ts.origin in ('quick','manual')),
    'las ventas de B2 viven en zonas de B2');

  -- Zona acentuada vieja: ignorada y su venta viva intacta.
  perform test_assert((select count(*) = 1 from dining_tables dt join zones z on z.id = dt.zone_id
      where z.business_id = tb(1) and z.name = 'Ventas rápidas'),
    'no se crean mesas en la zona acentuada de apps viejas');
  perform test_assert((select count(*) = 1 from zones where business_id = tb(1) and name = 'Ventas rapidas' and sort_index = 901)
    and (select count(*) = 1 from zones where business_id = tb(1) and name = 'Ventas manuales' and sort_index = 900),
    'una zona canónica por origen (quick 901, manual 900)');
end $$;

-- Retail y offline: identidad por slot exacto, idempotentes.
do $$
declare b uuid := tb(1); r jsonb; r2 jsonb; o uuid; s uuid; prev uuid;
begin
  r := fn_open_retail_cart(b, tu(1), 'quick-test-1', 1);
  perform test_assert(test_session_business(r) = b and test_code(r) = 'quick-test-1'
    and (r->>'resumed')::boolean = false, 'retail abre en la mesa de su carrito');
  r2 := fn_open_retail_cart(b, tu(1), 'quick-test-2', 1);
  perform test_assert(r->>'order_id' <> r2->>'order_id', 'dos carritos conservan órdenes independientes');
  o := (r->>'order_id')::uuid;
  insert into order_items(order_id, quantity, unit_price, status) values (o, 1, 50, 'pending');
  update orders set status_ext = 'partially_paid' where id = o;
  r2 := fn_open_retail_cart(b, tu(1), 'quick-test-1', 1);
  perform test_assert(r->>'order_id' = r2->>'order_id' and (r2->>'resumed')::boolean,
    'abono retail retoma la misma venta del carrito');
  perform test_assert((select status_ext = 'partially_paid' and closed_at is null from orders where id = o)
    and (select count(*) = 1 from order_items where order_id = o),
    'retomar el carrito no cambia la orden');
  -- Carrito cobrado pero con sesión abierta → venta nueva, sin 23505.
  update orders set status_ext = 'paid', status = 'paid', closed_at = now() where id = o;
  prev := (r->>'session_id')::uuid;
  r2 := fn_open_retail_cart(b, tu(1), 'quick-test-1', 1);
  perform test_assert(r2->>'order_id' <> o::text
    and (select closed_at is not null from table_sessions where id = prev),
    'slot con sesión abierta sin orden viva: venta nueva, sesión vacía cerrada');

  r := fn_open_offline_sale(b, tu(1), 'manual-local-one', 'manual', 1);
  perform test_assert(test_session_business(r) = b
    and (select origin = 'manual' from table_sessions where id = (r->>'session_id')::uuid),
    'venta manual offline conserva origen para impuestos/reportes');
  r2 := fn_open_offline_sale(b, tu(1), 'manual-local-two', 'manual', 1);
  perform test_assert(r->>'order_id' <> r2->>'order_id', 'ventas manuales offline independientes');
  r2 := fn_open_offline_sale(b, tu(1), 'manual-local-one', 'manual', 1);
  perform test_assert(r->>'order_id' = r2->>'order_id', 'reintento offline retoma la misma identidad');
  r := fn_open_offline_sale(b, tu(1), 'quick-local-1', 'quick', 1);
  r2 := fn_open_retail_cart(b, tu(1), 'quick-local-1', 1);
  perform test_assert(r->>'order_id' = r2->>'order_id', 'retail y offline comparten la identidad del slot');

  perform test_expect_error('select fn_open_retail_cart(tb(1), tu(1), ''quick'', 1)', 'fn_open_retail_cart: invalid slot');
  perform test_expect_error('select fn_open_retail_cart(tb(1), tu(1), ''quick#2'', 1)', 'fn_open_retail_cart: invalid slot');
  perform test_expect_error('select fn_open_retail_cart(tb(1), tu(1), ''  '', 1)', 'fn_open_retail_cart: slot is required');
  perform test_expect_error('select fn_open_retail_cart(null, tu(1), ''quick-x'', 1)', 'fn_open_retail_cart: business id is required');
  perform test_expect_error('select fn_open_offline_sale(tb(1), tu(1), ''manual'', ''manual'', 1)', 'fn_open_offline_sale: invalid slot');
  perform test_expect_error('select fn_open_offline_sale(tb(1), tu(1), ''a#b'', ''manual'', 1)', 'fn_open_offline_sale: invalid slot');
  perform test_expect_error('select fn_open_offline_sale(tb(1), tu(1), ''manual-x'', ''delivery'', 1)', 'fn_open_offline_sale: invalid origin');
end $$;

-- Zonas homónimas (sin UNIQUE): resolución determinista.
do $$
declare b uuid := tb(7); za uuid; zb uuid; zc uuid; t uuid; s uuid; o uuid; r jsonb; n int;
begin
  insert into zones(business_id, name, sort_index, created_at) values (b, 'Ventas rapidas', 0, '2019-01-01') returning id into za;
  insert into zones(business_id, name, sort_index, created_at) values (b, 'Ventas rapidas', 901, '2020-01-01') returning id into zb;
  insert into zones(business_id, name, sort_index, created_at) values (b, 'Ventas rapidas', 901, '2021-01-01') returning id into zc;
  -- Carrito vivo en la zona MÁS NUEVA.
  insert into dining_tables(zone_id, code, label) values (zc, 'quick-dup', 'Venta rapida') returning id into t;
  insert into table_sessions(table_id, opened_by, origin) values (t, tu(1), 'quick') returning id into s;
  insert into orders(session_id) values (s) returning id into o;
  select count(*) into n from dining_tables;
  r := fn_open_retail_cart(b, tu(1), 'quick-dup', 1);
  perform test_assert(r->>'order_id' = o::text and (select count(*) = n from dining_tables),
    'zona homónima más nueva: el carrito retoma su venta sin crear otra mesa');
  -- Mismo slot en dos zonas sin venta viva: una sola mesa determinista.
  insert into dining_tables(zone_id, code) values (zb, 'quick-two'), (zc, 'quick-two');
  r := fn_open_retail_cart(b, tu(1), 'quick-two', 1);
  perform test_assert((select dt.zone_id = zb from dining_tables dt where dt.id = (r->>'table_id')::uuid),
    'slot duplicado: elige la mesa de la zona canónica');
  r := fn_open_retail_cart(b, tu(1), 'quick-two', 1);
  perform test_assert((select count(*) = 1 from table_sessions ts join dining_tables dt on dt.id = ts.table_id
      where dt.code = 'quick-two' and ts.closed_at is null), 'slot duplicado: una sola sesión abierta');
  -- Carril nuevo: en la zona con sort_index canónico (no en la de sort 0, más antigua).
  r := fn_open_manual_or_quick('quick', tu(1), 1, b);
  perform test_assert((select dt.zone_id = zb from dining_tables dt where dt.id = (r->>'table_id')::uuid),
    'carril nuevo en la zona canónica (sort 901), no en la homónima de sort 0');
end $$;

-- Dueño y usuario compartido SIN fila directa.
select test_as(tu(3));
do $$
declare r jsonb;
begin
  r := fn_open_manual_or_quick('quick', tu(3), 1, tb(3));
  perform test_assert(test_session_business(r) = tb(3), 'dueño sin fila directa abre venta rápida');
  r := fn_open_manual_or_quick('manual', null);
  perform test_assert(r->>'business_id' = tb(3)::text, 'dueño sin sucursal: negocio accesible más antiguo (B3)');
  r := fn_open_retail_cart(tb(3), tu(3), 'quick-owner-1', 1);
  perform test_assert(test_session_business(r) = tb(3), 'dueño abre carrito retail');
  r := fn_open_offline_sale(tb(3), tu(3), 'manual-owner-1', 'manual', 1);
  perform test_assert(test_session_business(r) = tb(3), 'dueño sincroniza venta offline');
  r := fn_open_delivery_order(tu(3), 'own', 1, tb(3));
  perform test_assert(test_session_business(r) = tb(3), 'dueño sin fila directa abre delivery');
  r := fn_open_delivery_order(tu(3));
  perform test_assert(test_session_business(r) = tb(3), 'delivery de 3 argumentos: fallback determinista (B3)');
  r := fn_open_delivery_order(null, 'uber_eats', 2);
  perform test_assert(test_session_business(r) = tb(3), 'delivery de 3 argumentos con p_user_id null');
end $$;
select test_as(tu(5));
do $$
declare r jsonb;
begin
  r := fn_open_manual_or_quick('quick', tu(5), 1, tb(3));
  perform test_assert(test_session_business(r) = tb(3), 'usuario compartido abre venta en sucursal hermana');
  r := fn_open_delivery_order(tu(5), 'own', 1, tb(5));
  perform test_assert(test_session_business(r) = tb(5), 'usuario compartido abre delivery en sucursal hermana');
  r := fn_open_delivery_order(tu(5));
  perform test_assert(test_session_business(r) = tb(6), 'usuario compartido sin sucursal: su fila directa (B6)');
end $$;

-- No miembro, suplantación y service_role.
select test_as(tu(4));
do $$
begin
  perform test_expect_error('select fn_open_manual_or_quick(''quick'', tu(4), 1, tb(1))',
    'fn_open_manual_or_quick: user a0000000-0000-0000-0000-000000000004 does not belong to business b0000000-0000-0000-0000-000000000001');
  perform test_expect_error('select fn_open_retail_cart(tb(1), tu(4), ''quick-x'', 1)',
    'fn_open_retail_cart: user % does not belong to business %');
  perform test_expect_error('select fn_open_offline_sale(tb(1), tu(4), ''manual-x'', ''manual'', 1)',
    'fn_open_offline_sale: user % does not belong to business %');
  perform test_expect_error('select fn_open_delivery_order(tu(4), ''own'', 1, tb(1))',
    'fn_open_delivery_order: user does not belong to business');
  perform test_expect_error('select fn_open_delivery_order(tu(4))', 'fn_open_delivery_order: no business found');
  perform test_expect_error('select fn_open_manual_or_quick(''quick'', tu(4))',
    'fn_open_manual_or_quick: no business found for user %');
end $$;
select test_as(tu(2));
select test_expect_error('select fn_open_manual_or_quick(''quick'', tu(2), 1, tb(2))',
  'fn_open_manual_or_quick: user % does not belong to business %');
select test_as(tu(1));
do $$
begin
  perform test_expect_error('select fn_open_manual_or_quick(''quick'', tu(2), 1, tb(1))',
    'fn_open_manual_or_quick: user id must match authenticated user');
  perform test_expect_error('select fn_open_retail_cart(tb(1), tu(2), ''quick-x'', 1)',
    'fn_open_retail_cart: user id must match authenticated user');
  perform test_expect_error('select fn_open_offline_sale(tb(1), tu(2), ''manual-x'', ''manual'', 1)',
    'fn_open_offline_sale: user id must match authenticated user');
  perform test_expect_error('select fn_open_delivery_order(tu(2), ''own'', 1, tb(1))',
    'fn_open_delivery_order: user id must match authenticated user');
  perform test_expect_error('select fn_open_delivery_order(tu(2))',
    'fn_open_delivery_order: user id must match authenticated user');
end $$;
select test_as(null);
do $$
declare r jsonb;
begin
  r := fn_open_manual_or_quick('quick', tu(1), 1, tb(2));
  perform test_assert(test_session_business(r) = tb(2), 'service_role (sin JWT) abre con fila directa');
  perform test_expect_error('select fn_open_manual_or_quick(''quick'', tu(3), 1, tb(3))',
    'fn_open_manual_or_quick: user % does not belong to business %');
  perform test_expect_error('select fn_open_manual_or_quick(''quick'', null, 1, tb(1))',
    'fn_open_manual_or_quick: user id is required');
  perform test_expect_error('select fn_open_delivery_order(null)', 'fn_open_delivery_order: user id is required');
end $$;

-- Límite de carriles: error claro con el nombre del RPC, sin filas a medias.
select test_as(tu(1));
do $$
declare i int; r jsonb; n_orders int; n_tables int;
begin
  for i in 1..50 loop
    r := fn_open_manual_or_quick('quick', tu(1), 1, tb(8));
  end loop;
  perform test_assert(r->>'table_code' = 'quick#50' and test_label(r) = 'Venta rapida 50',
    '50 ventas vivas ocupan quick..quick#50');
  select count(*) into n_orders from orders;
  select count(*) into n_tables from dining_tables;
  perform test_expect_error('select fn_open_manual_or_quick(''quick'', tu(1), 1, tb(8))',
    'fn_open_manual_or_quick: no hay carril libre%');
  perform test_assert((select count(*) = n_orders from orders) and (select count(*) = n_tables from dining_tables),
    'carriles agotados: no deja filas a medias');
end $$;
SQL

# Numeración delivery (DEL-1000 no trunca).
Q <<'SQL'
select test_as(tu(1));
do $$
declare z uuid; r jsonb;
begin
  perform fn_open_delivery_order(tu(1), 'own', 1, tb(2));
  select id into z from zones where business_id = tb(2) and name = 'Delivery';
  insert into dining_tables(zone_id, code) values (z, 'DEL-100'), (z, 'DEL-999');
  r := fn_open_delivery_order(tu(1), 'own', 1, tb(2));
  perform test_assert(r->>'table_code' = 'DEL-1000', 'delivery 1000 no trunca ni colisiona con DEL-100');
  r := fn_open_delivery_order(tu(1), 'own', 1, tb(2));
  perform test_assert(r->>'table_code' = 'DEL-1001', 'delivery continúa después de 999 pedidos');
end $$;
SQL

# ─── 6. Concurrencia con procesos psql paralelos ────────────────────────────
Q <<'SQL'
create table test_snap_preconc as select id, md5(row(o.*)::text) as h from orders o;
create table test_delivery_before as select count(*) as n from table_sessions where origin = 'delivery' and business_id = tb(2);
-- La pausa dentro de la apertura hace determinista la carrera.
create function public.slow_session_insert() returns trigger language plpgsql as $$
begin perform pg_sleep(0.15); return new; end $$;
create trigger slow_session_insert before insert on public.table_sessions
  for each row execute function public.slow_session_insert();
SQL
pids=()
for origin in quick manual; do
  for u in "$U1" "$U2" "$U1" "$U1"; do
    QU "$u" -c "select fn_open_manual_or_quick('$origin', null, 1, '$B4')" > "$D/legacy-$origin-$RANDOM.log" &
    pids+=("$!")
  done
done
for i in 1 2; do
  QU "$U1" -c "select fn_open_retail_cart('$B4', null, 'quick-concurrent', 1)" > "$D/retail-$i.log" &
  pids+=("$!")
  QU "$U1" -c "select fn_open_offline_sale('$B4', null, 'manual-concurrent', 'manual', 1)" > "$D/offline-$i.log" &
  pids+=("$!")
done
for i in 1 2 3 4; do
  QU "$U1" -c "select fn_open_delivery_order(null, 'own', 1, '$B2')" > "$D/delivery-$i.log" &
  pids+=("$!")
done
wait_all() { for pid in "${pids[@]}"; do wait "$pid" || { cat "$D"/*.log; echo 'FAIL: apertura concurrente con error'; exit 1; }; done; }
wait_all
Q <<'SQL'
select test_assert((select count(*) = 8 and count(distinct o.id) = 8 and count(distinct dt.id) = 8
      and array_agg(dt.code order by dt.code collate "C") = array['manual','manual#2','manual#3',
        'manual#4','quick','quick#2','quick#3','quick#4']
    from orders o join table_sessions ts on ts.id = o.session_id
    join dining_tables dt on dt.id = ts.table_id
    where ts.business_id = tb(4) and dt.code !~ '-concurrent$'),
  'aperturas simultáneas: cada una en su propio carril (quick..quick#4, manual..manual#4)');
select test_assert((select count(*) = 1 from orders o join table_sessions s on s.id = o.session_id
  join dining_tables t on t.id = s.table_id where t.code = 'quick-concurrent'),
  'aperturas simultáneas del mismo carrito crean una sola orden');
select test_assert((select count(*) = 1 from orders o join table_sessions s on s.id = o.session_id
  join dining_tables t on t.id = s.table_id where t.code = 'manual-concurrent'),
  'replays offline simultáneos del mismo slot crean una sola orden');
select test_assert((select count(*) = (select n from test_delivery_before) + 4 from table_sessions
  where origin = 'delivery' and business_id = tb(2)),
  'deliveries simultáneos conservan todas las órdenes');
select test_assert((select count(*) = 0 from test_snap_preconc b join orders o using (id)
  where md5(row(o.*)::text) <> b.h), 'la concurrencia no modifica ninguna orden existente');
drop trigger slow_session_insert on public.table_sessions;
-- Zonas: el esquema real no tiene UNIQUE(business_id,name).
create function public.slow_zone_insert() returns trigger language plpgsql as $$
begin perform pg_sleep(0.2); return new; end $$;
create trigger slow_zone_insert before insert on public.zones
  for each row execute function public.slow_zone_insert();
SQL
pids=()
for origin in quick manual; do
  for i in 1 2; do
    QU "$U1" -c "select fn_open_manual_or_quick('$origin', null, 1, '$B9')" > "$D/cross-legacy-$origin-$i.log" &
    pids+=("$!")
    QU "$U1" -c "select fn_open_offline_sale('$B9', null, '$origin-cross-entry', '$origin', 1)" > "$D/cross-offline-$origin-$i.log" &
    pids+=("$!")
  done
done
for i in 1 2; do
  QU "$U1" -c "select fn_open_retail_cart('$B9', null, 'quick-cross-entry', 1)" > "$D/cross-retail-$i.log" &
  pids+=("$!")
done
wait_all
Q <<'SQL'
select test_assert((select count(*) = 2 from zones where business_id = tb(9)
    and name in ('Ventas rapidas', 'Ventas manuales')),
  'legacy, retail y offline concurrentes conservan una zona por origen');
select test_assert((select count(*) = 6 from orders o join table_sessions s on s.id = o.session_id
    where s.business_id = tb(9)),
  'legacy abre 4 ventas nuevas; cada slot conserva una sola orden');
select test_assert((select count(*) = 1 from orders o join table_sessions s on s.id = o.session_id
    join dining_tables t on t.id = s.table_id where s.business_id = tb(9) and t.code = 'quick-cross-entry'),
  'retail y offline comparten identidad estable del mismo slot');
drop trigger slow_zone_insert on public.zones;

-- Invariantes globales tras todo lo anterior.
select test_assert((select count(*) = 0 from (
    select ts.table_id from table_sessions ts join orders o on o.session_id = ts.id
    where ts.closed_at is null and o.closed_at is null and o.status_ext::text not in ('paid','void')
      and ts.origin in ('quick','manual')
    group by ts.table_id having count(*) > 1) x),
  'ninguna mesa virtual tiene dos ventas vivas');
select test_assert((select count(*) = 0 from orders
    where status_ext = 'void' and id not in (select id from test_expected_void)),
  'ninguna apertura anuló una orden');
select test_assert((select count(*) = 0 from test_snap_premig b
    join orders o on b.k = 'o' and o.id = b.id where md5(row(o.*)::text) <> b.h),
  'las ventas vivas previas a la migración siguen byte a byte iguales');
select test_assert((select count(*) = 0 from zones z
    where z.business_id <> tb(7) and ((z.name = 'Ventas rapidas' and z.sort_index <> 901)
      or (z.name = 'Ventas manuales' and z.sort_index <> 900))),
  'sort_index canónico: quick 901, manual 900');
SQL

# ─── 7. ROLLBACK → forward ──────────────────────────────────────────────────
Q <<'SQL'
create table test_counts_pre_rbk as
  select (select count(*) from orders) as o, (select count(*) from dining_tables) as t;
SQL
Q -f "$RBK" >/dev/null
Q <<'SQL'
select test_assert(position('fn_close_order_and_table' in pg_get_functiondef(
    'public.fn_open_manual_or_quick(public.order_origin,uuid,integer,uuid)'::regprocedure)) > 0
  and position('fn_get_or_create_virtual_table' in pg_get_functiondef(
    'public.fn_open_manual_or_quick(public.order_origin,uuid,integer,uuid)'::regprocedure)) > 0,
  'rollback: fn_open_manual_or_quick vuelve al cuerpo de 20260526_0003');
select test_assert(position(':sales_virtual' in pg_get_functiondef(
    'public.fn_open_retail_cart(uuid,uuid,text,integer)'::regprocedure)) = 0,
  'rollback: fn_open_retail_cart vuelve al cuerpo de 20260602_0004');
select test_assert((select l.lanname = 'plpgsql' from pg_proc p join pg_language l on l.oid = p.prolang
    where p.oid = 'public.fn_open_delivery_order(uuid,text,integer)'::regprocedure),
  'rollback: delivery de 3 argumentos vuelve al plpgsql de 20260408_0002');
select test_assert(to_regprocedure('public.fn_open_offline_sale(uuid,uuid,text,public.order_origin,integer)') is not null
  and to_regprocedure('public.fn_open_delivery_order(uuid,text,integer,uuid)') is not null
  and to_regprocedure('public.fn_sales_virtual_open(text,uuid,uuid,public.order_origin,integer,text)') is not null,
  'rollback conserva offline, delivery de 4 y helpers (la app nueva los usa)');
select test_assert(to_regprocedure('public.fn_open_manual_or_quick(public.order_origin,uuid,integer)') is null,
  'rollback no recrea el overload de 3 argumentos');
select test_assert(not has_function_privilege('anon',
    'public.fn_open_manual_or_quick(public.order_origin,uuid,integer,uuid)', 'execute')
  and has_function_privilege('authenticated',
    'public.fn_open_manual_or_quick(public.order_origin,uuid,integer,uuid)', 'execute'),
  'rollback no devuelve EXECUTE a anon');
select test_assert((select o = (select count(*) from orders) and t = (select count(*) from dining_tables)
    from test_counts_pre_rbk), 'rollback no toca datos (carriles y órdenes quedan)');
select test_as(tu(1));
do $$
declare r jsonb;
begin
  r := fn_open_manual_or_quick('quick', tu(1), 1, tb(9));
  perform test_assert(r ? 'order_id', 'rollback: cuerpo restaurado abre venta');
  r := fn_open_retail_cart(tb(9), tu(1), 'quick-after-rollback', 1);
  perform test_assert(r ? 'order_id', 'rollback: retail restaurado abre carrito');
  r := fn_open_delivery_order(tu(1), 'own', 1, tb(9));
  perform test_assert(r ? 'order_id', 'rollback: delivery de 4 argumentos sigue funcionando');
end $$;
SQL
Q -f "$FWD" >/dev/null
Q <<'SQL'
select test_check_forward_shape();
select test_as(tu(1));
do $$
declare r jsonb; r2 jsonb;
begin
  r := fn_open_manual_or_quick('manual', tu(1), 1, tb(9));
  r2 := fn_open_manual_or_quick('manual', tu(1), 1, tb(9));
  perform test_assert(r->>'order_id' <> r2->>'order_id' and r2->>'table_code' <> r->>'table_code',
    'forward tras rollback: venta nueva por carril');
  r := fn_open_offline_sale(tb(9), tu(1), 'manual-cross-entry', 'manual', 1);
  r2 := fn_open_offline_sale(tb(9), tu(1), 'manual-cross-entry', 'manual', 1);
  perform test_assert(r->>'order_id' = r2->>'order_id', 'forward tras rollback: replay offline idempotente');
end $$;
SQL
printf 'Sales order continuity: OK\n'
