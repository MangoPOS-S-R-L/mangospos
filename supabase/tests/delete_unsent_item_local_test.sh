#!/usr/bin/env bash
# Postgres local desechable; no toca ninguna base remota.
# Prueba 20261010_0026: lo no enviado a cocina lo quita cualquiera del
# negocio; lo enviado sigue exigiendo ventas.orden.eliminar_item; candado
# fiscal intacto; guarda de huella; reversa.
set -euo pipefail
REPO=$(cd "$(dirname "$0")/../.." && pwd)
M=$REPO/supabase/migrations
PG=${PG_BIN:-/opt/homebrew/opt/postgresql@15/bin}
PORT=${PG_PORT:-55482}
WORK=${1:-$(mktemp -d)}
D=$WORK/pg_delete_unsent
rm -rf "$D"; mkdir -p "$D"
"$PG/initdb" -D "$D/data" -U postgres --auth=trust >/dev/null
"$PG/pg_ctl" -D "$D/data" -o "-p $PORT -c listen_addresses=127.0.0.1 -c unix_socket_directories=''" -l "$D/log" start -w >/dev/null
trap '"$PG/pg_ctl" -D "$D/data" stop -m fast >/dev/null 2>&1' EXIT
Q() { "$PG/psql" -h 127.0.0.1 -p "$PORT" -U postgres -X -q -v ON_ERROR_STOP=1 "$@"; }

Q <<'SQL'
create extension dblink;
create role anon; create role authenticated;
create schema auth;
create function auth.uid() returns uuid language sql stable
  as $$ select nullif(current_setting('test.uid', true), '')::uuid $$;

create type public.item_status as enum ('pending','preparing','ready','served','void','draft');
create table public.zones (id uuid primary key, business_id uuid);
create table public.dining_tables (id uuid primary key, zone_id uuid);
create table public.table_sessions (id uuid primary key, table_id uuid, business_id uuid);
create table public.orders (id uuid primary key, session_id uuid);
create table public.order_items (
  id uuid primary key, order_id uuid, check_id uuid,
  status public.item_status default 'draft', kitchen_sent_at timestamptz);
create table public.fiscal_documents (
  id uuid primary key default gen_random_uuid(), order_id uuid, check_id uuid,
  status text, ncf_number text);
create table public.members (user_id uuid, business_id uuid);
create table public.perms (user_id uuid, business_id uuid, code text);
create table public.recalcs (order_id uuid);

create function public.is_member_of_business(p_business uuid) returns boolean
  language sql stable as $$
  select exists (select 1 from public.members m
                  where m.business_id = p_business and m.user_id = auth.uid()) $$;
create function public.fn_user_effective_permissions(p_user uuid, p_business uuid)
  returns table (code text, allowed boolean) language sql stable as $$
  select p.code, true from public.perms p
   where p.user_id = p_user and p.business_id = p_business $$;
create function public.fn_recalc_order_totals(p_order uuid) returns void
  language sql as $$ insert into public.recalcs values (p_order) $$;

-- Negocio B1: cajero (miembro, sin permiso), mesero con permiso, extraño.
-- Mesa con zona (o1) y venta sin mesa con zona (o2, negocio en la sesión).
insert into public.zones values ('00000000-0000-0000-0000-0000000000a1', '00000000-0000-0000-0000-0000000000b1');
insert into public.dining_tables values ('00000000-0000-0000-0000-0000000000d1', '00000000-0000-0000-0000-0000000000a1');
insert into public.table_sessions values
  ('00000000-0000-0000-0000-0000000000e1', '00000000-0000-0000-0000-0000000000d1', null),
  ('00000000-0000-0000-0000-0000000000e2', '00000000-0000-0000-0000-0000000000d9', '00000000-0000-0000-0000-0000000000b1');
insert into public.orders values
  ('00000000-0000-0000-0000-0000000000f1', '00000000-0000-0000-0000-0000000000e1'),
  ('00000000-0000-0000-0000-0000000000f2', '00000000-0000-0000-0000-0000000000e2'),
  ('00000000-0000-0000-0000-0000000000f3', '00000000-0000-0000-0000-0000000000e1');
insert into public.members values
  ('00000000-0000-0000-0000-000000000c01', '00000000-0000-0000-0000-0000000000b1'),
  ('00000000-0000-0000-0000-000000000c02', '00000000-0000-0000-0000-0000000000b1');
insert into public.perms values
  ('00000000-0000-0000-0000-000000000c02', '00000000-0000-0000-0000-0000000000b1', 'ventas.orden.eliminar_item');
SQL

CAJERO=00000000-0000-0000-0000-000000000c01
MESERO_PERM=00000000-0000-0000-0000-000000000c02
EXTRANO=00000000-0000-0000-0000-000000000c09
O1=00000000-0000-0000-0000-0000000000f1
O2=00000000-0000-0000-0000-0000000000f2
O3=00000000-0000-0000-0000-0000000000f3

item() { # id order status [kitchen_sent_at]
  Q -c "insert into public.order_items (id, order_id, status, kitchen_sent_at) values ('$1', '$2', '$3', ${4:-null});"
}
del_ok() { # user item label
  Q -c "select set_config('test.uid', '$1', false); select public.fn_delete_item('$2');" >/dev/null
  [ "$(Q -At -c "select count(*) from public.order_items where id = '$2'")" = "0" ] || { echo "FAIL: $3"; exit 1; }
  echo "ok: $3"
}
del_fails() { # user item expected-sqlstate label
  local out
  if out=$(Q -v VERBOSITY=verbose -c "select set_config('test.uid', '$1', false); select public.fn_delete_item('$2');" 2>&1); then
    echo "FAIL: $4 (se borró)"; exit 1
  fi
  echo "$out" | grep -q "$3" || { echo "FAIL: $4 (esperaba $3): $out"; exit 1; }
  [ "$(Q -At -c "select count(*) from public.order_items where id = '$2'")" = "1" ] || { echo "FAIL: $4 (falta la línea)"; exit 1; }
  echo "ok: $4"
}

# --- Guarda de huella: no pisa una fn_delete_item distinta ------------------
Q -c "create function public.fn_delete_item(p_item_id uuid) returns void language plpgsql security definer as \$\$ begin null; end \$\$;"
if Q -f "$M/20261010_0026_delete_unsent_item_any_member.sql" >/dev/null 2>&1; then
  echo 'FAIL: aplicó sobre una fn_delete_item desconocida'; exit 1
fi
echo 'ok: se niega a pisar una fn_delete_item desconocida'
Q -c "drop function public.fn_delete_item(uuid);"

# --- Base viva (0011): el cajero NO puede quitar lo no enviado (el reporte) --
Q -f "$M/20260902_0011_fn_delete_item_fiscal_guard.sql" >/dev/null
item 10000000-0000-0000-0000-000000000001 $O1 draft
del_fails $CAJERO 10000000-0000-0000-0000-000000000001 42501 'antes (0011): cajero no quita lo no enviado — el reporte'

# --- 0026, dos veces ----------------------------------------------------------
Q -f "$M/20261010_0026_delete_unsent_item_any_member.sql" >/dev/null
Q -f "$M/20261010_0026_delete_unsent_item_any_member.sql" >/dev/null
echo 'ok: 0026 aplica dos veces'

del_ok $CAJERO 10000000-0000-0000-0000-000000000001 'cajero sin permiso quita lo «POR CONFIRMAR»'
[ "$(Q -At -c "select count(*) from public.recalcs where order_id = '$O1'")" = "1" ] || { echo 'FAIL: no recalculó'; exit 1; }
echo 'ok: recalcula los totales'

item 10000000-0000-0000-0000-000000000002 $O1 pending
del_fails $CAJERO 10000000-0000-0000-0000-000000000002 42501 'cajero sin permiso NO quita lo enviado a cocina'

item 10000000-0000-0000-0000-000000000003 $O1 draft "now()"
del_fails $CAJERO 10000000-0000-0000-0000-000000000003 42501 'draft con kitchen_sent_at cuenta como enviado'

item 10000000-0000-0000-0000-000000000004 $O1 draft
del_fails $EXTRANO 10000000-0000-0000-0000-000000000004 42501 'alguien de otro negocio no quita lo no enviado'
del_fails "" 10000000-0000-0000-0000-000000000004 42501 'sin usuario no quita lo no enviado'

del_ok $MESERO_PERM 10000000-0000-0000-0000-000000000002 'con ventas.orden.eliminar_item quita lo enviado'

item 10000000-0000-0000-0000-000000000005 $O2 draft
del_ok $CAJERO 10000000-0000-0000-0000-000000000005 'sin mesa con zona: el negocio sale de la sesión'

Q -c "insert into public.fiscal_documents (order_id, status, ncf_number) values ('$O3', 'active', 'B0200000001');"
item 10000000-0000-0000-0000-000000000006 $O3 draft
del_fails $MESERO_PERM 10000000-0000-0000-0000-000000000006 MP404 'candado fiscal: no se borra de una cuenta facturada'

if Q -c "select set_config('test.uid', '$CAJERO', false); select public.fn_delete_item('10000000-0000-0000-0000-0000000000ff');" >/dev/null 2>&1; then
  echo 'FAIL: borró una línea inexistente'; exit 1
fi
echo 'ok: línea inexistente → ITEM_NOT_FOUND'

# --- Carrera con el envío a cocina: la línea queda tomada --------------------
# c1 confirma a cocina sin cerrar la transacción; c2 (el cajero) pide borrar
# y espera. Cuando c1 confirma, c2 tiene que ver la línea YA enviada y negarse
# (sin el FOR UPDATE leía 'draft' y borraba lo enviado sin permiso).
item 10000000-0000-0000-0000-000000000007 $O1 draft
Q <<SQL
select dblink_connect('c1', 'host=127.0.0.1 port=$PORT user=postgres dbname=postgres');
select dblink_connect('c2', 'host=127.0.0.1 port=$PORT user=postgres dbname=postgres');
select dblink_exec('c1', 'begin');
select dblink_exec('c1', \$\$update public.order_items set status = 'pending' where id = '10000000-0000-0000-0000-000000000007'\$\$);
select dblink_send_query('c2', \$\$select set_config('test.uid', '$CAJERO', false), public.fn_delete_item('10000000-0000-0000-0000-000000000007')::text\$\$);
select pg_sleep(0.5);
select dblink_exec('c1', 'commit');
select * from dblink_get_result('c2', false) as t(a text, b text);
select dblink_disconnect('c1');
select dblink_disconnect('c2');
SQL
[ "$(Q -At -c "select status from public.order_items where id = '10000000-0000-0000-0000-000000000007'")" = "pending" ] \
  || { echo 'FAIL: se coló el borrado de lo que cocina confirmaba'; exit 1; }
echo 'ok: el borrado espera al envío a cocina y no se cuela'
del_fails $CAJERO 10000000-0000-0000-0000-000000000007 42501 'ya confirmado a cocina: el cajero no lo quita'

# --- Reversa -----------------------------------------------------------------
Q -f "$M/20261010_0026_delete_unsent_item_any_member_ROLLBACK.sql" >/dev/null
Q -f "$M/20261010_0026_delete_unsent_item_any_member_ROLLBACK.sql" >/dev/null
[ "$(Q -At -c "select md5(prosrc) from pg_proc where oid = 'public.fn_delete_item(uuid)'::regprocedure")" = "bfc0c1ad17a594865fbd4d90ba8dacbf" ] \
  || { echo 'FAIL: la reversa no dejó la de 0011'; exit 1; }
echo 'ok: reversa (dos veces) deja fn_delete_item idéntica a 0011'
item 10000000-0000-0000-0000-000000000008 $O1 draft
del_fails $CAJERO 10000000-0000-0000-0000-000000000008 42501 'tras la reversa vuelve el comportamiento anterior'
echo 'TODO OK'
