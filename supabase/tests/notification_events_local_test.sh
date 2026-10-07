#!/usr/bin/env bash
# =============================================================================
# Prueba LOCAL de los avisos del dashboard (20261007_0001).
# Postgres 15 DESECHABLE con el esquema mínimo; corre los archivos REALES del
# repo: 20260919_0002 (registro de retiros del POS, para probar que conviven
# y que el texto toma su motivo/aprobador) y 20261007_0001 (+ su ROLLBACK).
# pg_net es un stub que anota las llamadas. No toca ninguna base real.
#
# Regla que se prueba: si el producto salió a cocina, quitarlo o bajarle la
# cantidad AVISA sin importar quién ni por dónde; lo que no salió, no.
#
#   bash supabase/tests/notification_events_local_test.sh [carpeta_trabajo]
# Variables: PG_BIN (default homebrew postgresql@15), PG_PORT (default 55448).
# =============================================================================
set -u
REPO=$(cd "$(dirname "$0")/../.." && pwd)
M=$REPO/supabase/migrations
PG=${PG_BIN:-/opt/homebrew/opt/postgresql@15/bin}
PORT=${PG_PORT:-55448}
WORK=${1:-$(mktemp -d)}
D=$WORK/pg_notification_events
rm -rf "$D"; mkdir -p "$D"
"$PG/initdb" -D "$D/data" -U postgres --auth=trust >/dev/null || exit 1
"$PG/pg_ctl" -D "$D/data" -o "-p $PORT -c listen_addresses=127.0.0.1 -c unix_socket_directories=''" \
  -l "$D/log" start -w >/dev/null || { cat "$D/log"; exit 1; }
trap '"$PG/pg_ctl" -D "$D/data" stop -m fast >/dev/null 2>&1' EXIT
Q() { "$PG/psql" -h 127.0.0.1 -p "$PORT" -U postgres -X -q -v ON_ERROR_STOP=1 "$@"; }
FAIL=0
ok()  { echo "  ok     $1"; }
bad() { echo "  FALLA  $1"; FAIL=1; }
run() {
  local label=$1; shift
  if OUT=$(Q "$@" 2>&1); then ok "$label";
  else echo "$OUT" | grep -E "ERROR|FALLA" | sed 's/^psql:[^:]*:[0-9]*: //'; bad "$label"; fi
}
expect() { # label, obtenido, esperado
  if [[ "$2" == "$3" ]]; then ok "$1"; else bad "$1 — obtuve [$2], esperaba [$3]"; fi
}
contains() { # label, texto, fragmento
  if [[ "$2" == *"$3"* ]]; then ok "$1"; else bad "$1 — [$2] no contiene [$3]"; fi
}

BIZ=b0000000-0000-0000-0000-000000000001
BIZ2=b0000000-0000-0000-0000-000000000002
OWNER=a0000000-0000-0000-0000-000000000001
TABLET=a0000000-0000-0000-0000-000000000002
WAITER=a0000000-0000-0000-0000-000000000003
EMP_JUAN=e0000000-0000-0000-0000-000000000001
EMP_MARIA=e0000000-0000-0000-0000-000000000002
TBL=d0000000-0000-0000-0000-000000000001

# Contexto de la petición, como lo deja PostgREST. $1 = path ('' = Studio,
# sin JWT), $2 = cuenta (sub), $3 = rol.
ctx() {
  if [[ -z "$1" ]]; then
    echo "select set_config('request.jwt.claims', '', false), set_config('request.path', '', false);"
  else
    echo "select set_config('request.jwt.claims', '{\"role\":\"${3:-authenticated}\",\"sub\":\"${2:-$TABLET}\"}', false), set_config('request.path', '$1', false);"
  fi
}
REST=/rest/v1/order_items

echo "== Esquema mínimo"
Q <<SQL || { bad "esquema"; exit 1; }
create role authenticated; create role anon; create role service_role;
create schema auth;
create function auth.uid() returns uuid language sql stable as \$\$
  select nullif(nullif(current_setting('request.jwt.claims', true), '')::jsonb ->> 'sub', '')::uuid
\$\$;
grant usage on schema public, auth to anon, authenticated, service_role;
grant execute on function auth.uid() to anon, authenticated, service_role;
-- Como Supabase: todo objeto nuevo de public nace con permisos para
-- anon/authenticated; la migración tiene que revocarlos.
alter default privileges in schema public grant all on tables to anon, authenticated;
alter default privileges in schema public grant execute on functions to anon, authenticated;

create type public.order_status as enum ('open','sent_to_kitchen','partially_paid','paid','void');
create type public.item_status as enum ('pending','preparing','ready','served','void','draft','paid');
create type public.order_origin as enum ('dine_in','manual','quick','delivery','self_service');

create table public.businesses (id uuid primary key);
create table public.user_businesses (user_id uuid, business_id uuid);
create function public.current_user_business_ids() returns setof uuid
language sql stable security definer set search_path = public as \$\$
  select ub.business_id from public.user_businesses ub where ub.user_id = auth.uid()
\$\$;
create table public.employees (id uuid primary key, business_id uuid, user_id uuid,
  first_name text not null, last_name text not null);
create table public.profiles (id uuid primary key, full_name text);
create table public.dining_tables (id uuid primary key, code text not null, label text);
create table public.table_sessions (id uuid primary key, business_id uuid, table_id uuid,
  origin public.order_origin not null default 'dine_in', customer_name text, note text);
create table public.orders (id uuid primary key, session_id uuid not null, business_id uuid,
  status_ext public.order_status not null default 'open',
  total numeric(12,2) not null default 0, closed_at timestamptz);
create table public.order_items (
  id uuid primary key default gen_random_uuid(), order_id uuid not null, business_id uuid,
  check_id uuid, product_id uuid, product_name text, qty numeric(10,3) default 1,
  quantity integer not null default 1, unit_price numeric(10,2) default 0, notes text,
  status public.item_status not null default 'draft', is_takeout boolean default false,
  kitchen_sent_at timestamptz, print_area_code text, created_by_employee_id uuid,
  created_at timestamptz default now());
create table public.order_item_modifiers (item_id uuid, name text, qty numeric);
create table public.order_checks (id uuid primary key, order_id uuid, label text);
create table public.fiscal_documents (id uuid primary key, business_id uuid, order_id uuid,
  ncf_number text, cancellation_reason text, cancelled_by uuid, status text default 'active');
create table public.payments (id uuid primary key default gen_random_uuid(),
  business_id uuid not null, order_id uuid, check_id uuid, fiscal_document_id uuid,
  amount numeric not null, change_amount numeric default 0,
  status text default 'completed', created_at timestamptz default now());
create table public.sales_notes (order_id uuid, cancellation_reason text);

create schema private;
create table private.dashboard_cron_config (id boolean primary key default true,
  functions_base_url text, service_role_key text);
insert into private.dashboard_cron_config values (true, 'https://x.test/functions/v1/', 'SRK');

create schema net;
create table net.calls (id bigserial primary key, url text, body jsonb, headers jsonb, timeout int);
create function net.http_post(url text, body jsonb default '{}', params jsonb default '{}',
  headers jsonb default '{}', timeout_milliseconds int default 5000) returns bigint
language sql as \$\$
  insert into net.calls (url, body, headers, timeout)
  values (url, body, headers, timeout_milliseconds) returning id
\$\$;

-- El trigger viejo de producción (push por cada ítem en 'void').
create function public.fn_push_notify() returns trigger language plpgsql as \$\$
begin insert into net.calls (url) values ('VIEJO'); return null; end \$\$;
create trigger push_order_item_void after update on public.order_items
  for each row when (new.status = 'void') execute function public.fn_push_notify();

insert into public.businesses values ('$BIZ'), ('$BIZ2');
insert into public.user_businesses values ('$OWNER', '$BIZ');
insert into public.employees values
  ('$EMP_JUAN', '$BIZ', '$TABLET', 'Juan', 'Pérez'),
  ('$EMP_MARIA', '$BIZ', null, 'María', 'Gómez');
insert into public.profiles values ('$TABLET', 'Caja Principal'), ('$WAITER', 'Pedro Mesero');
insert into public.dining_tables values ('$TBL', 'M5', 'Mesa 5');
SQL
ok "esquema"

run "migración 20260919_0002 (registro de retiros del POS, real)" -f "$M/20260919_0002_order_item_removals.sql"
run "migración 20261007_0001" -f "$M/20261007_0001_notification_events.sql"
run "migración 20261007_0001 otra vez (idempotente)" -f "$M/20261007_0001_notification_events.sql"

# Orden nueva con su sesión; imprime el id. $1 = estado, $2 = business_id de la orden.
mk_order() {
  Q -At -c "with s as (
              insert into public.table_sessions (id, business_id, table_id)
              values (gen_random_uuid(), '$BIZ', '$TBL') returning id)
            insert into public.orders (id, session_id, business_id, status_ext, total)
            select gen_random_uuid(), s.id, ${2:-"'$BIZ'"}, '${1:-open}', 1250 from s
            returning id;" | head -1
}
# Ítem; imprime el id. $1 = orden, $2 = nombre, $3 = qty, $4 = estado, $5 = business_id.
mk_item() {
  Q -At -c "insert into public.order_items (order_id, business_id, product_name, qty, quantity, status)
            values ('$1', ${5:-"'$BIZ'"}, '$2', $3, ceil($3)::int, '$4') returning id;" | head -1
}
events() { Q -At -c "select count(*) from public.notification_events where order_id = '$1'"; }
field()  { Q -At -c "select $2 from public.notification_events where order_id = '$1' order by created_at limit 1"; }
refresh_body() { # como push-notify (service_role)
  Q -At -c "select set_config('request.jwt.claims', '{\"role\":\"service_role\"}', false);
            select title || ' | ' || body from public.fn_notification_event_refresh('$1');" | tail -1
}

echo "== Permisos y limpieza"
expect "trigger viejo push_order_item_void eliminado" \
  "$(Q -At -c "select count(*) from pg_trigger where tgname = 'push_order_item_void'")" "0"
expect "anon sin acceso a notification_events" \
  "$(Q -At -c "select has_table_privilege('anon', 'public.notification_events', 'select')")" "f"
expect "authenticated solo lectura" \
  "$(Q -At -c "select has_table_privilege('authenticated', 'public.notification_events', 'select')::text || has_table_privilege('authenticated', 'public.notification_events', 'insert')::text")" "truefalse"
expect "anon no ejecuta el refresh" \
  "$(Q -At -c "select has_function_privilege('anon', 'public.fn_notification_event_refresh(uuid)', 'execute')")" "f"
expect "notification_events en supabase_realtime" \
  "$(Q -At -c "select count(*) from pg_publication_tables where pubname = 'supabase_realtime' and tablename = 'notification_events'")" "1"

echo "== Lo que NO salió a cocina no avisa"
O=$(mk_order)
I=$(mk_item "$O" Pizza 2 draft)
Q -c "$(ctx $REST) delete from public.order_items where id = '$I';" >/dev/null
I=$(mk_item "$O" Pizza 3 draft)
Q -c "$(ctx /rpc/fn_update_item_qty) update public.order_items set qty = 1, quantity = 1 where id = '$I';" >/dev/null
expect "borrador borrado o reducido: 0 avisos" "$(events "$O")" "0"

echo "== Enviado a cocina: borrar avisa"
O=$(mk_order)
I=$(mk_item "$O" 'Pizza Margarita' 2 pending)
Q -c "$(ctx $REST) delete from public.order_items where id = '$I';" >/dev/null
expect "1 aviso" "$(events "$O")" "1"
expect "clave de preferencia item_voided" "$(field "$O" event_type)" "item_voided"
expect "texto" "$(field "$O" "title || ' | ' || body")" \
  "Producto eliminado | Mesa 5 · 2 x Pizza Margarita. Por: Juan Pérez."
expect "1 push encolado con service_role y timeout 60 s" \
  "$(Q -At -c "select count(*) || '|' || max(url) || '|' || max(headers ->> 'Authorization') || '|' || max(timeout) from net.calls where body ->> 'kind' = 'notification_event'")" \
  "1|https://x.test/functions/v1/push-notify|Bearer SRK|60000"

echo "== No importa quién ni por dónde"
for case in \
  "fn_delete_item (subcuenta)|$(ctx /rpc/fn_delete_item)" \
  "RPC desconocida|$(ctx /rpc/fn_algo_que_no_conocemos)" \
  "Studio / SQL sin JWT|$(ctx '')" \
  "service_role (Hub, Edge)|$(ctx $REST '' service_role)" \
  "otra cuenta (mesero)|$(ctx $REST "$WAITER")"; do
  label=${case%%|*}; sql=${case#*|}
  O=$(mk_order)
  I=$(mk_item "$O" Mofongo 1 served)
  Q -c "$sql delete from public.order_items where id = '$I';" >/dev/null
  expect "borrado por $label: 1 aviso" "$(events "$O")" "1"
done
contains "Studio: sin 'Por:' inventado" "$(Q -At -c "select body from public.notification_events where actor_user_id is null and kind = 'items_removed' limit 1")" "Mesa 5 · 1 x Mofongo."
contains "mesero: su nombre" "$(Q -At -c "select body from public.notification_events where actor_user_id = '$WAITER' limit 1")" "Por: Pedro Mesero."

echo "== Ítem y orden sin business_id (el registro del POS no lo anota; el aviso sí)"
O=$(mk_order open null)
I=$(mk_item "$O" Ron 1 served null)
Q -c "$(ctx $REST) delete from public.order_items where id = '$I';" >/dev/null
expect "registro del POS: 0 filas" "$(Q -At -c "select count(*) from public.order_item_removals where item_id = '$I'")" "0"
expect "aviso: 1 (negocio desde table_sessions)" "$(events "$O")" "1"

echo "== Bajar la cantidad de algo enviado avisa (con o sin etiqueta)"
O=$(mk_order)
I=$(mk_item "$O" Presidente 3 served)
Q -c "$(ctx /rpc/fn_update_item_qty) update public.order_items set qty = 1 where id = '$I';" >/dev/null
expect "sin etiqueta (Hub/cola offline, fn_update_item_qty): 1 aviso" "$(events "$O")" "1"
expect "sin etiqueta: texto" "$(field "$O" "title || ' | ' || body")" \
  "Cantidad reducida | Mesa 5 · Presidente (3 → 1). Por: Juan Pérez."
O=$(mk_order)
I=$(mk_item "$O" Mojito 4 served)
Q -c "$(ctx /rpc/fn_update_item_details) update public.order_items
      set qty = 2, quantity = 2, notes = '[REDUCCION:Cliente cambió]' where id = '$I';" >/dev/null
expect "con etiqueta: 1 aviso (no duplica con el registro del POS)" "$(events "$O")" "1"
expect "con etiqueta: el POS también lo registró" \
  "$(Q -At -c "select count(*) from public.order_item_removals where item_id = '$I'")" "1"
expect "con etiqueta: motivo" "$(field "$O" body)" \
  "Mesa 5 · Mojito (4 → 2). Motivo: Cliente cambió. Por: Juan Pérez."
O=$(mk_order)
I=$(mk_item "$O" Agua 4 served)
Q -c "update public.order_items set qty = 0 where id = '$I';
      update public.order_items set qty = 4 where id = '$I';" >/dev/null
Q -c "insert into public.order_items (order_id, business_id, product_name, qty, quantity, status)
      values ('$O', '$BIZ', 'Legado', 0, 4, 'served');
      update public.order_items set quantity = 2 where product_name = 'Legado';" >/dev/null
expect "reducir a 0 y columna heredada quantity: avisan; subir no" \
  "$(field "$O" "jsonb_array_length(items)")" "2"

echo "== Redistribuir (dividir / mover / transferir) NO avisa"
for rpc in fn_split_items_equally fn_explode_items_to_units fn_consolidate_order_to_integer \
           fn_consolidate_keeper_atomic fn_move_item_to_check fn_move_items_to_check_batch \
           fn_transfer_table_session; do
  O=$(mk_order)
  I=$(mk_item "$O" Pizza 3 served)
  J=$(mk_item "$O" Coca 1 served)
  Q -c "$(ctx /rpc/$rpc) update public.order_items set qty = 1 where id = '$I';
        delete from public.order_items where id = '$J';" >/dev/null
  expect "$rpc: 0 avisos" "$(events "$O")" "0"
done

echo "== Varios productos = UN aviso"
O=$(mk_order)
CHK=40000000-0000-0000-0000-000000000001
Q -c "insert into public.order_items (order_id, business_id, check_id, product_name, qty, status)
      values ('$O', '$BIZ', '$CHK', 'Coca-Cola', 1, 'served'), ('$O', '$BIZ', '$CHK', 'Pizza', 1, 'pending'),
             ('$O', '$BIZ', '$CHK', 'Agua', 3, 'ready'), ('$O', '$BIZ', '$CHK', 'Borrador', 1, 'draft');"
Q -c "$(ctx $REST) delete from public.order_items where check_id = '$CHK';" >/dev/null
expect "subcuenta (un DELETE): 1 aviso con 3 productos" \
  "$(events "$O")|$(field "$O" "jsonb_array_length(items)")|$(field "$O" title)" "1|3|Productos eliminados"
O=$(mk_order)
I=$(mk_item "$O" Pizza 1 served)
J=$(mk_item "$O" Cerveza 2 served)
Q -c "$(ctx $REST) delete from public.order_items where id = '$I';" >/dev/null
Q -c "$(ctx $REST) delete from public.order_items where id = '$J';" >/dev/null
expect "dos borrados seguidos (< 5 s): 1 aviso con 2 productos" \
  "$(events "$O")|$(field "$O" "jsonb_array_length(items)")" "1|2"
expect "ese aviso: 1 push" \
  "$(Q -At -c "select count(*) from net.calls where body ->> 'event_id' = (select id::text from public.notification_events where order_id = '$O')")" "1"
Q -c "update public.notification_events set pushed_at = now() where order_id = '$O';"
K=$(mk_item "$O" Postre 1 served)
Q -c "$(ctx $REST) delete from public.order_items where id = '$K';" >/dev/null
expect "después de enviado el push: aviso nuevo" "$(events "$O")" "2"
L=$(mk_item "$O" Flan 1 served)
Q -c "$(ctx $REST "$WAITER") delete from public.order_items where id = '$L';" >/dev/null
expect "otra cuenta: aviso aparte" "$(events "$O")" "3"

echo "== Motivo, operador y aprobador (registro del POS) → refresh"
Q -c "alter table public.order_item_removals
        add column reason_code text, add column is_waste boolean,
        add column approved_by_employee_id uuid;
      create table public.order_item_removal_reasons (business_id uuid, code text, label text);
      insert into public.order_item_removal_reasons values ('$BIZ', 'spilled', 'Se derramó');"
O=$(mk_order)
I=$(mk_item "$O" Mojito 1 served)
Q -c "$(ctx $REST) delete from public.order_items where id = '$I';" >/dev/null
Q -c "update public.order_item_removals set reason_code = 'spilled', is_waste = true,
        reason_employee_id = '$EMP_JUAN', approved_by_employee_id = '$EMP_MARIA'
      where item_id = '$I';"
EV=$(field "$O" id)
expect "refresh como service_role" "$(refresh_body "$EV")" \
  "Producto eliminado | Mesa 5 · 1 x Mojito. Motivo: Se derramó (merma). Por: Juan Pérez. Autorizó: María Gómez."
expect "refresh deja el texto guardado" "$(field "$O" body)" \
  "Mesa 5 · 1 x Mojito. Motivo: Se derramó (merma). Por: Juan Pérez. Autorizó: María Gómez."

echo "== Anular orden abierta"
O=$(mk_order)
Q -c "update public.orders set status_ext = 'void' where id = '$O';"
expect "mesa vacía anulada (cron): 0 avisos" "$(events "$O")" "0"
O=$(mk_order)
mk_item "$O" 'Solo borrador' 1 draft >/dev/null
Q -c "update public.orders set status_ext = 'void' where id = '$O';"
expect "orden con solo borradores anulada: 0 avisos" "$(events "$O")" "0"
O=$(mk_order)
mk_item "$O" Pizza 1 pending >/dev/null
mk_item "$O" Borrador 1 draft >/dev/null
Q -c "update public.table_sessions set note = '[ANULACION][2026-10-07T12:00:00] Juan Pérez: Cliente se fue'
       where id = (select session_id from public.orders where id = '$O');
      $(ctx /rpc/fn_close_order_and_table) update public.orders set status_ext = 'void' where id = '$O';" >/dev/null
expect "orden enviada anulada: 1 aviso order_voided" "$(events "$O")|$(field "$O" event_type)" "1|order_voided"
expect "orden anulada: texto" "$(field "$O" "title || ' | ' || body")" \
  "Orden anulada | Mesa 5 · Cuenta de RD\$ 1,250.00 sin cobrar. Motivo: Cliente se fue. Por: Juan Pérez."
Q -c "update public.orders set status_ext = 'open' where id = '$O';
      update public.orders set status_ext = 'void' where id = '$O';"
expect "re-anular la misma orden: sigue 1 aviso" "$(events "$O")" "1"

echo "== Anular venta cobrada (annulOrder): orden → void, ítems → void, pagos → cancelled"
O=$(mk_order paid)
mk_item "$O" Pizza 1 paid >/dev/null
mk_item "$O" Coca 1 paid >/dev/null
FD=50000000-0000-0000-0000-000000000001
Q -c "insert into public.fiscal_documents (id, business_id, order_id, ncf_number)
      values ('$FD', '$BIZ', '$O', 'E310000000123');
      insert into public.payments (business_id, order_id, fiscal_document_id, amount, change_amount)
      values ('$BIZ', '$O', '$FD', 1000, 50), ('$BIZ', '$O', '$FD', 300, 0);"
BEFORE=$(Q -At -c "select coalesce(max(id), 0) from net.calls")
Q -c "$(ctx /rpc/fn_close_order_and_table) update public.orders set status_ext = 'void' where id = '$O';" >/dev/null
Q -c "$(ctx $REST) update public.order_items set status = 'void' where order_id = '$O';" >/dev/null
Q -c "$(ctx /rest/v1/payments) update public.payments set status = 'cancelled' where order_id = '$O';" >/dev/null
Q -c "update public.fiscal_documents set status = 'cancelled', cancellation_reason = 'Error de cobro',
        cancelled_by = '$TABLET' where id = '$FD';"
expect "venta anulada: 1 aviso (no uno por ítem)" "$(events "$O")" "1"
expect "venta anulada: 1 push y ninguno del trigger viejo" \
  "$(Q -At -c "select count(*) || '|' || count(*) filter (where url = 'VIEJO') from net.calls where id > $BEFORE")" "1|0"
EV8=$(field "$O" id)
expect "venta anulada: texto tras refresh" "$(refresh_body "$EV8")" \
  "Venta anulada | Mesa 5 · RD\$ 1,250.00 cobrados · NCF E310000000123. Motivo: Error de cobro. Por: Juan Pérez."

echo "== Anulación parcial (pago mixto de una subcuenta) = UN aviso"
O=$(mk_order paid)
CK=60000000-0000-0000-0000-000000000001
FD2=50000000-0000-0000-0000-000000000002
Q -c "insert into public.order_checks values ('$CK', '$O', 'C2');
      insert into public.fiscal_documents (id, business_id, order_id, ncf_number, cancellation_reason)
      values ('$FD2', '$BIZ', '$O', 'B0200000045', 'Cliente pidió factura con RNC');
      insert into public.payments (business_id, order_id, check_id, fiscal_document_id, amount)
      values ('$BIZ', '$O', '$CK', '$FD2', 400), ('$BIZ', '$O', '$CK', '$FD2', 100),
             ('$BIZ', '$O', null, null, 750);"
Q -c "$(ctx /rest/v1/payments) update public.payments set status = 'cancelled' where fiscal_document_id = '$FD2';" >/dev/null
expect "parcial: 1 aviso" "$(events "$O")" "1"
expect "parcial: texto" "$(field "$O" "title || ' | ' || body")" \
  "Venta anulada | Mesa 5 · Subcuenta C2 · RD\$ 500.00 anulados · NCF B0200000045; la cuenta volvió a quedar abierta. Motivo: Cliente pidió factura con RNC. Por: Juan Pérez."

echo "== Venta rápida con cliente"
O=$(mk_order)
Q -c "update public.table_sessions set origin = 'quick', customer_name = 'Ana'
       where id = (select session_id from public.orders where id = '$O');
      update public.orders set total = 99.5 where id = '$O';"
mk_item "$O" Café 1 served >/dev/null
Q -c "update public.orders set status_ext = 'void' where id = '$O';"
contains "venta rápida: lugar" "$(field "$O" body)" "Venta rápida (Ana) · Cuenta de RD\$ 99.50 sin cobrar."

echo "== Un error del aviso NUNCA bloquea al POS"
O=$(mk_order)
I=$(mk_item "$O" Pizza 2 pending)
Q -c "alter table public.employees rename to employees_x;"
run "borrar con el texto roto: el producto se borra igual" \
  -c "$(ctx $REST) delete from public.order_items where id = '$I';"
expect "borrar con el texto roto: ya no está" \
  "$(Q -At -c "select count(*) from public.order_items where id = '$I'")" "0"
mk_item "$O" Pizza 1 pending >/dev/null
run "anular con el texto roto: la orden se anula igual" \
  -c "update public.orders set status_ext = 'void' where id = '$O';"
Q -c "alter table public.employees_x rename to employees;"

echo "== Reintento de pushes (cron)"
Q -c "update public.notification_events set pushed_at = now();"
BEFORE=$(Q -At -c "select coalesce(max(id), 0) from net.calls")
Q -c "select private.fn_run_notification_event_sweep();" >/dev/null
expect "sin pendientes: no llama" "$(Q -At -c "select count(*) from net.calls where id > $BEFORE")" "0"
Q -c "update public.notification_events set pushed_at = null, created_at = now() - interval '5 minutes'
       where id = (select id from public.notification_events order by created_at limit 1);"
Q -c "select private.fn_run_notification_event_sweep();" >/dev/null
expect "con un pendiente viejo: 1 llamada notification_event_sweep" \
  "$(Q -At -c "select count(*) || '|' || max(body ->> 'kind') from net.calls where id > $BEFORE")" "1|notification_event_sweep"

echo "== Sin config de push: el aviso existe igual (dentro de la app)"
Q -c "delete from private.dashboard_cron_config;"
O=$(mk_order)
BEFORE=$(Q -At -c "select coalesce(max(id), 0) from net.calls")
I=$(mk_item "$O" Pizza 1 pending)
Q -c "$(ctx $REST) delete from public.order_items where id = '$I';" >/dev/null 2>&1
expect "aviso creado" "$(events "$O")" "1"
expect "sin llamada" "$(Q -At -c "select count(*) from net.calls where id > $BEFORE")" "0"

echo "== RLS: cada quien ve solo sus negocios"
Q -c "insert into public.notification_events (business_id, event_type, kind, title, body)
      values ('$BIZ2', 'order_voided', 'order_voided', 'Otro', 'Otro negocio');" 2>/dev/null
OWNER_CLAIMS="select set_config('request.jwt.claims', '{\"role\":\"authenticated\",\"sub\":\"$OWNER\"}', false);"
expect "dueño ve solo su negocio" \
  "$(Q -At -c "$OWNER_CLAIMS set role authenticated; select count(*) filter (where business_id = '$BIZ2') from public.notification_events;" | tail -1)" "0"
OTHER=$(Q -At -c "select id from public.notification_events where business_id = '$BIZ2'")
expect "refresh de otro negocio: vacío" \
  "$(Q -At -c "$OWNER_CLAIMS set role authenticated; select count(*) from public.fn_notification_event_refresh('$OTHER');" | tail -1)" "0"
expect "refresh de su negocio: 1 fila" \
  "$(Q -At -c "$OWNER_CLAIMS set role authenticated; select count(*) from public.fn_notification_event_refresh('$EV8');" | tail -1)" "1"

echo "== ROLLBACK"
run "rollback" -f "$M/20261007_0001_notification_events_ROLLBACK.sql"
expect "rollback: sin tabla ni triggers" \
  "$(Q -At -c "select (to_regclass('public.notification_events') is null)::text || (select count(*) from pg_trigger where tgname like 'trg_zz_notif_%')")" "true0"
run "re-aplicar tras rollback" -f "$M/20261007_0001_notification_events.sql"

echo
if [[ $FAIL -eq 0 ]]; then echo "TODO OK"; else echo "HAY FALLAS"; fi
exit $FAIL
