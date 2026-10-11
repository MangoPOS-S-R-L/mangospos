#!/usr/bin/env bash
# Postgres local desechable; no toca ninguna base remota.
# Prueba 20261010_0027 con las funciones reales: fn_apply_order_edit (0006),
# fn_delete_item (0011 + 0026) y el trigger de auditoría (20260919_0002).
# Borrar por fn_apply_order_edit → del usuario; unir líneas (consolidate_check)
# → interno; las demás rutas igual; corrección de lo ya registrado; reversa.
set -euo pipefail
REPO=$(cd "$(dirname "$0")/../.." && pwd)
M=$REPO/supabase/migrations
PG=${PG_BIN:-/opt/homebrew/opt/postgresql@15/bin}
PORT=${PG_PORT:-55486}
WORK=${1:-$(mktemp -d)}
D=$WORK/pg_removal_audit
rm -rf "$D"; mkdir -p "$D"
"$PG/initdb" -D "$D/data" -U postgres --auth=trust >/dev/null
"$PG/pg_ctl" -D "$D/data" -o "-p $PORT -c listen_addresses=127.0.0.1 -c unix_socket_directories=''" -l "$D/log" start -w >/dev/null
trap '"$PG/pg_ctl" -D "$D/data" stop -m fast >/dev/null 2>&1' EXIT
export PGOPTIONS='-c check_function_bodies=off -c client_min_messages=warning'
Q() { "$PG/psql" -h 127.0.0.1 -p "$PORT" -U postgres -X -q -v ON_ERROR_STOP=1 "$@"; }

Q <<'SQL'
create role anon; create role authenticated; create role service_role;
create schema auth;
create function auth.uid() returns uuid language sql stable
  as $$ select nullif(current_setting('test.uid', true), '')::uuid $$;
create function auth.role() returns text language sql stable
  as $$ select nullif(current_setting('test.role', true), '') $$;

create type public.item_status as enum ('pending','preparing','ready','served','void','draft');
create table public.businesses (id uuid primary key);
create table public.zones (id uuid primary key, business_id uuid);
create table public.dining_tables (id uuid primary key, zone_id uuid, label text, code text);
create table public.table_sessions (id uuid primary key, table_id uuid, business_id uuid,
  origin text default 'dine_in', note text);
create table public.orders (id uuid primary key, session_id uuid, business_id uuid,
  closed_at timestamptz, status_ext text default 'open',
  delivery_fee numeric, is_sales_note boolean, tip numeric);
create table public.order_checks (id uuid primary key, order_id uuid,
  customer_id uuid, customer_name text, customer_rnc text);
create table public.order_items (
  id uuid primary key, order_id uuid, business_id uuid, check_id uuid,
  status public.item_status default 'draft', kitchen_sent_at timestamptz,
  print_area_code text, created_by_employee_id uuid, product_id uuid,
  product_name text, sku text, qty numeric default 1, quantity numeric default 1,
  unit_price numeric default 100, notes text, is_takeout boolean default false,
  discounts numeric, created_at timestamptz default '2026-10-10 12:00');
create table public.order_item_modifiers (id uuid primary key default gen_random_uuid(),
  item_id uuid, name text, qty numeric);
create table public.fiscal_documents (id uuid primary key default gen_random_uuid(),
  order_id uuid, check_id uuid, status text, ncf_number text);
create table public.members (user_id uuid, business_id uuid);
create table public.perms (user_id uuid, business_id uuid, code text);

create function public.current_user_business_ids() returns setof uuid language sql stable
  as $$ select m.business_id from public.members m where m.user_id = auth.uid() $$;
create function public.is_member_of_business(p_business uuid) returns boolean
  language sql stable as $$
  select exists (select 1 from public.members m
                  where m.business_id = p_business and m.user_id = auth.uid()) $$;
create function public.fn_user_effective_permissions(p_user uuid, p_business uuid)
  returns table (code text, allowed boolean) language sql stable as $$
  select p.code, true from public.perms p
   where p.user_id = p_user and p.business_id = p_business $$;
create function public.fn_recalc_order_totals(p_order uuid) returns void
  language sql as $$ select null::void $$;

-- La unión real (viva, no está en el repo): borra las líneas sobrantes.
-- Variante 'direct' (DELETE) o 'via_fn' (fn_delete_item), según test.keeper.
create function public.fn_consolidate_keeper_atomic(
  p_keeper uuid, p_others uuid[], p_qty numeric, p_discounts numeric)
returns void language plpgsql security definer set search_path = public as $$
declare v uuid;
begin
  if current_setting('test.keeper', true) = 'via_fn' then
    foreach v in array p_others loop perform public.fn_delete_item(v); end loop;
  else
    delete from public.order_items where id = any(p_others);
  end if;
  update public.order_items set qty = p_qty, quantity = p_qty where id = p_keeper;
end $$;

insert into public.businesses values ('00000000-0000-0000-0000-0000000000b1');
insert into public.zones values ('00000000-0000-0000-0000-0000000000a1', '00000000-0000-0000-0000-0000000000b1');
insert into public.dining_tables values ('00000000-0000-0000-0000-0000000000d1', '00000000-0000-0000-0000-0000000000a1', 'MESA 1', 'M1');
insert into public.table_sessions (id, table_id, business_id) values
  ('00000000-0000-0000-0000-0000000000e1', '00000000-0000-0000-0000-0000000000d1', '00000000-0000-0000-0000-0000000000b1');
insert into public.orders (id, session_id, business_id) values
  ('00000000-0000-0000-0000-0000000000f1', '00000000-0000-0000-0000-0000000000e1', '00000000-0000-0000-0000-0000000000b1');
insert into public.order_checks (id, order_id) values
  ('00000000-0000-0000-0000-0000000000c1', '00000000-0000-0000-0000-0000000000f1');
insert into public.members values ('00000000-0000-0000-0000-000000000a01', '00000000-0000-0000-0000-0000000000b1');
insert into public.perms values ('00000000-0000-0000-0000-000000000a01', '00000000-0000-0000-0000-0000000000b1', 'ventas.orden.eliminar_item');

-- Guarda: una fn_log_order_item_removal desconocida no se pisa (se prueba abajo).
create function public.fn_log_order_item_removal() returns trigger language plpgsql
  as $$ begin return old; end $$;
SQL

if Q -f "$M/20261010_0027_removal_audit_apply_order_edit.sql" >/dev/null 2>&1; then
  echo 'FAIL: aplicó sobre una fn_log_order_item_removal desconocida'; exit 1
fi
echo 'ok: se niega a pisar una fn_log_order_item_removal desconocida'
Q -c "drop function public.fn_log_order_item_removal();"

# Lo vivo: la auditoría (20260919_0002, tabla + trigger), 0011, 0026 y 0006.
sed -n '/^create table if not exists public.order_item_removals/,/^-- 3. Motivo/p' \
  "$M/20260919_0002_order_item_removals.sql" | Q >/dev/null
Q -f "$M/20260902_0011_fn_delete_item_fiscal_guard.sql" >/dev/null
Q -f "$M/20261010_0026_delete_unsent_item_any_member.sql" >/dev/null
Q -f "$M/20261010_0006_versioned_order_edits.sql" >/dev/null

USER=00000000-0000-0000-0000-000000000a01
O1=00000000-0000-0000-0000-0000000000f1
C1=00000000-0000-0000-0000-0000000000c1
PRODUCT=00000000-0000-0000-0000-00000000aaaa

sent() { # id [check] [status]
  Q -c "insert into public.order_items (id, order_id, business_id, check_id, status, kitchen_sent_at, product_id, product_name)
        values ('$1', '$O1', '00000000-0000-0000-0000-0000000000b1', ${2:-null}, '${3:-pending}',
                case when '${3:-pending}' = 'draft' then null else now() end, '$PRODUCT', 'Daiquiri');"
}
# Una llamada como PostgREST: ruta, JWT del usuario y la sentencia.
api() { # path sql [jwt=yes]
  local claims="{\"sub\":\"$USER\",\"role\":\"authenticated\"}"
  [ "${3:-yes}" = "yes" ] || claims=""
  Q -c "begin;
        select set_config('request.path', '$1', true),
               set_config('request.jwt.claims', '$claims', true),
               set_config('test.uid', '$USER', true);
        $2;
        commit;" >/dev/null
}
edit_delete() { api /rpc/fn_apply_order_edit "select public.fn_apply_order_edit(gen_random_uuid(), '$O1', 'delete', '$1', null, null, '{}'::jsonb, true)" "${2:-yes}"; }
consolidate() { # keeper-variant
  api /rpc/fn_apply_order_edit "select set_config('test.keeper', '$1', true); select public.fn_apply_order_edit(gen_random_uuid(), '$O1', 'consolidate_check', '$C1', null, null, '{}'::jsonb, true)"
}
logged() { # item → is_user_action ('' si no hay registro)
  Q -At -c "select string_agg(is_user_action::text, ',') from public.order_item_removals where item_id = '$1'"
}
expect() { # item expected label
  local got; got=$(logged "$1")
  [ "$got" = "$2" ] || { echo "FAIL: $3 (esperaba '$2', quedó '$got')"; exit 1; }
  echo "ok: $3"
}

# --- Antes de 0027: lo que se vio en prod ----------------------------------
sent 20000000-0000-0000-0000-000000000001
edit_delete 20000000-0000-0000-0000-000000000001
expect 20000000-0000-0000-0000-000000000001 false 'antes (prod): borrar por fn_apply_order_edit queda interno'
sent 20000000-0000-0000-0000-000000000002 "'$C1'"; sent 20000000-0000-0000-0000-000000000003 "'$C1'"
consolidate direct
expect 20000000-0000-0000-0000-000000000003 false 'antes: unir líneas queda interno'

# --- 0027, dos veces (la segunda no corrige nada nuevo) ---------------------
Q -f "$M/20261010_0027_removal_audit_apply_order_edit.sql" >/dev/null
Q -f "$M/20261010_0027_removal_audit_apply_order_edit.sql" >/dev/null
echo 'ok: 0027 aplica dos veces'
expect 20000000-0000-0000-0000-000000000001 true 'corrige el borrado ya registrado (operación delete)'
expect 20000000-0000-0000-0000-000000000003 false 'la unión ya registrada sigue interna'

# --- Después de 0027 ---------------------------------------------------------
sent 20000000-0000-0000-0000-000000000010
edit_delete 20000000-0000-0000-0000-000000000010
expect 20000000-0000-0000-0000-000000000010 true 'la X por fn_apply_order_edit → del usuario (sale en el reporte)'

Q -c "delete from public.order_items where check_id = '$C1';" >/dev/null
sent 20000000-0000-0000-0000-000000000011 "'$C1'"; sent 20000000-0000-0000-0000-000000000012 "'$C1'"
consolidate direct
expect 20000000-0000-0000-0000-000000000012 false 'unir líneas (DELETE) por fn_apply_order_edit → interno'
Q -c "delete from public.order_items where check_id = '$C1';" >/dev/null
sent 20000000-0000-0000-0000-000000000013 "'$C1'"; sent 20000000-0000-0000-0000-000000000014 "'$C1'"
consolidate via_fn
expect 20000000-0000-0000-0000-000000000014 false 'unir líneas aunque use fn_delete_item → interno'
Q -c "delete from public.order_items where check_id = '$C1';" >/dev/null

sent 20000000-0000-0000-0000-000000000015
api /rpc/fn_consolidate_keeper_atomic "select public.fn_consolidate_keeper_atomic('20000000-0000-0000-0000-0000000000ff', array['20000000-0000-0000-0000-000000000015']::uuid[], 1, 0)"
expect 20000000-0000-0000-0000-000000000015 false '/rpc/fn_consolidate_keeper_atomic sigue interno'

sent 20000000-0000-0000-0000-000000000016
api /order_items "delete from public.order_items where id = '20000000-0000-0000-0000-000000000016'"
expect 20000000-0000-0000-0000-000000000016 true 'DELETE directo (app ≤ 2.0.20) sigue del usuario'

sent 20000000-0000-0000-0000-000000000017
api /rpc/fn_delete_item "select public.fn_delete_item('20000000-0000-0000-0000-000000000017')"
expect 20000000-0000-0000-0000-000000000017 true '/rpc/fn_delete_item sigue del usuario'

sent 20000000-0000-0000-0000-000000000018
edit_delete 20000000-0000-0000-0000-000000000018 no
expect 20000000-0000-0000-0000-000000000018 false 'sin JWT (interno) sigue interno'

sent 20000000-0000-0000-0000-000000000019 null draft
edit_delete 20000000-0000-0000-0000-000000000019
expect 20000000-0000-0000-0000-000000000019 '' 'lo no enviado no se registra (igual que antes)'

# --- Reversa -----------------------------------------------------------------
Q -f "$M/20261010_0027_removal_audit_apply_order_edit_ROLLBACK.sql" >/dev/null
Q -f "$M/20261010_0027_removal_audit_apply_order_edit_ROLLBACK.sql" >/dev/null
[ "$(Q -At -c "select md5(prosrc) from pg_proc where oid = 'public.fn_log_order_item_removal()'::regprocedure")" = "90d9616ae8c2101123985410c5d27511" ] \
  || { echo 'FAIL: la reversa no dejó la de 20260919_0002'; exit 1; }
echo 'ok: reversa (dos veces) deja el trigger idéntico a 20260919_0002'
sent 20000000-0000-0000-0000-000000000020
edit_delete 20000000-0000-0000-0000-000000000020
expect 20000000-0000-0000-0000-000000000020 false 'tras la reversa vuelve el comportamiento anterior'
expect 20000000-0000-0000-0000-000000000010 true 'la reversa no deshace lo ya registrado como del usuario'
echo 'TODO OK'
