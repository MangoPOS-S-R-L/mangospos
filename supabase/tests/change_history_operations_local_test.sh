#!/usr/bin/env bash
# =============================================================================
# Prueba LOCAL del historial de operaciones (20261013_0002) sobre 0001.
# Postgres 15 DESECHABLE con el esquema mínimo; corre los archivos REALES del
# repo: 20260709_0001, 20260919_0002, 20261013_0001 y 20261013_0002 (+ su
# ROLLBACK). fn_transfer_table_session y fn_update_item_discount son stubs con
# el mismo nombre: lo que se prueba es que el historial reconoce quién llamó.
#
#   bash supabase/tests/change_history_operations_local_test.sh [carpeta]
# Variables: PG_BIN (default homebrew postgresql@15), PG_PORT (default 55482).
# =============================================================================
set -u
REPO=$(cd "$(dirname "$0")/../.." && pwd)
M=$REPO/supabase/migrations
PG=${PG_BIN:-/opt/homebrew/opt/postgresql@15/bin}
PORT=${PG_PORT:-55482}
WORK=${1:-$(mktemp -d)}
D=$WORK/pg_change_history_ops
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

BIZ=b0000000-0000-0000-0000-000000000001
OWNER=a0000000-0000-0000-0000-000000000001
TABLET=a0000000-0000-0000-0000-000000000002
ADMIN=a0000000-0000-0000-0000-000000000003
EMP_JUAN=e0000000-0000-0000-0000-000000000002
EMP_MARIA=e0000000-0000-0000-0000-000000000003
ZONE=d1000000-0000-0000-0000-000000000001
T1=d0000000-0000-0000-0000-000000000001
T2=d0000000-0000-0000-0000-000000000002
T3=d0000000-0000-0000-0000-000000000003
REG=c1000000-0000-0000-0000-000000000001
PM_CASH=92000000-0000-0000-0000-000000000001
PM_CARD=92000000-0000-0000-0000-000000000002
WH=93000000-0000-0000-0000-000000000001
WH2=93000000-0000-0000-0000-000000000002
SUP=94000000-0000-0000-0000-000000000001
CUST=95000000-0000-0000-0000-000000000001

ctx() {
  if [[ -z "$1" ]]; then
    echo "select set_config('request.jwt.claims', '', false), set_config('request.path', '', false);"
  else
    echo "select set_config('request.jwt.claims', '{\"role\":\"authenticated\",\"sub\":\"${2:-$OWNER}\"}', false), set_config('request.path', '$1', false);"
  fi
}
H() { Q -At -c "select $1 from public.change_history where ${2:-true} order by id desc limit 1"; }
N() { Q -At -c "select count(*) from public.change_history where ${1:-true}"; }

echo "== Esquema mínimo"
Q <<SQL || { bad "esquema"; exit 1; }
create role authenticated; create role anon; create role service_role;
create schema auth;
create table auth.users (id uuid primary key, email text);
create function auth.uid() returns uuid language sql stable as \$\$
  select nullif(nullif(current_setting('request.jwt.claims', true), '')::jsonb ->> 'sub', '')::uuid
\$\$;
grant usage on schema public, auth to anon, authenticated, service_role;
grant execute on function auth.uid() to anon, authenticated, service_role;
alter default privileges in schema public grant all on tables to anon, authenticated;
alter default privileges in schema public grant all on sequences to anon, authenticated;
alter default privileges in schema public grant execute on functions to anon, authenticated;

create type public.order_status as enum ('open','sent_to_kitchen','partially_paid','paid','void');
create type public.item_status as enum ('pending','preparing','ready','served','void','draft','paid');
create type public.order_origin as enum ('dine_in','manual','quick','delivery','self_service');
create type public.movement_type as enum ('purchase','sale','adjustment','transfer_in','transfer_out',
  'waste','return','production_in','production_out');
create type public.purchase_status as enum ('draft','sent','partial','received','cancelled');

create table public.businesses (id uuid primary key, owner_id uuid, business_name text, branch_name text);
create table public.memberships (user_id uuid, business_id uuid, role text);
create table public.user_businesses (id uuid primary key default gen_random_uuid(),
  user_id uuid, business_id uuid, role text);
create table public.roles (id uuid primary key, business_id uuid, name text, level text);
create table public.employees (id uuid primary key, business_id uuid, user_id uuid,
  first_name text not null, last_name text not null, created_at timestamptz default now());
create table public.employee_roles (employee_id uuid, role_id uuid, primary key (employee_id, role_id));
create table public.profiles (id uuid primary key, full_name text);
create table public.permissions (id uuid primary key, code text, name text);
create table public.menus (id uuid primary key default gen_random_uuid(), business_id uuid, name text);
create table public.menu_items (id uuid primary key default gen_random_uuid(), business_id uuid not null,
  name text not null, price numeric default 0, is_active boolean default true, auto_disabled boolean default false);
create table public.menu_item_links (menu_id uuid, item_id uuid, position int default 0,
  primary key (menu_id, item_id));
create table public.zones (id uuid primary key, business_id uuid not null, name text);
create table public.dining_tables (id uuid primary key, zone_id uuid, code text not null, label text,
  state text default 'available');
create table public.payment_methods (id uuid primary key, business_id uuid, name text, code text);
create table public.customers (id uuid primary key, business_id uuid, name text);
create table public.suppliers (id uuid primary key, business_id uuid, name text);
create table public.warehouses (id uuid primary key, business_id uuid, name text);
create table public.inventory_items (id uuid primary key default gen_random_uuid(), business_id uuid, name text);

create table public.table_sessions (id uuid primary key, business_id uuid, table_id uuid,
  origin public.order_origin not null default 'dine_in', note text, closed_at timestamptz);
create table public.orders (id uuid primary key, session_id uuid not null, business_id uuid,
  status_ext public.order_status not null default 'open',
  total numeric(12,2) not null default 0, closed_at timestamptz);
create table public.order_items (
  id uuid primary key default gen_random_uuid(), order_id uuid not null, business_id uuid,
  check_id uuid, product_id uuid, product_name text, qty numeric(10,3) default 1,
  quantity integer not null default 1, unit_price numeric(10,2) default 0, notes text,
  discounts numeric(12,2) not null default 0,
  status public.item_status not null default 'draft', is_takeout boolean default false,
  kitchen_sent_at timestamptz, print_area_code text, created_by_employee_id uuid,
  created_at timestamptz default now());
create table public.order_item_modifiers (item_id uuid, name text, qty numeric);
create table public.order_checks (id uuid primary key, order_id uuid, label text);
create table public.fiscal_documents (id uuid primary key default gen_random_uuid(), business_id uuid,
  order_id uuid, ncf_number text, total numeric, status text default 'active',
  related_document_id uuid, modification_reason text, issued_by uuid, customer_name text);
create table public.payments (id uuid primary key default gen_random_uuid(),
  business_id uuid not null, order_id uuid, check_id uuid, fiscal_document_id uuid,
  payment_method_id uuid, amount numeric not null, change_amount numeric default 0,
  reference text, status text default 'completed', created_at timestamptz default now());

create table public.cash_registers (id uuid primary key, business_id uuid, name text);
create table public.cash_register_sessions (id uuid primary key default gen_random_uuid(),
  cash_register_id uuid, user_id uuid, opened_at timestamptz default now(), closed_at timestamptz,
  start_amount numeric, end_amount numeric, difference numeric, status text default 'open',
  notes text, device_id text, device_name text, variance_flagged boolean default false);
create table public.cash_transaction_reasons (id uuid primary key default gen_random_uuid(),
  business_id uuid, code text, label text);
create table public.cash_transactions (id uuid primary key default gen_random_uuid(),
  session_id uuid not null, amount numeric, type text, description text, related_order_id uuid,
  reason_code text, reason_id uuid, created_by uuid, approved_by uuid,
  approval_pin_used boolean default false, created_at timestamptz default now());
create table public.audit_logs (id uuid primary key default gen_random_uuid(), business_id uuid,
  user_id uuid, action text, reason text, ref_table text, ref_id uuid, created_at timestamptz default now());
create table public.table_session_waiter_changes (id uuid primary key default gen_random_uuid(),
  business_id uuid, session_id uuid, table_id uuid, from_employee_id uuid, to_employee_id uuid,
  changed_by uuid, reason text, items_frozen int, created_at timestamptz default now());
create table public.sales_notes (id uuid primary key default gen_random_uuid(), business_id uuid,
  note_number text, customer_name text, total numeric, status text default 'active',
  cancelled_at timestamptz, cancelled_by uuid, cancellation_reason text);
create table public.customer_credits (id uuid primary key default gen_random_uuid(), business_id uuid,
  customer_id uuid, original_amount numeric, balance numeric, status text default 'pending', notes text,
  cancelled_by uuid);
create table public.credit_payments (id uuid primary key default gen_random_uuid(), credit_id uuid,
  amount numeric, payment_method_id uuid, reference text, received_by uuid, code text, business_id uuid,
  created_at timestamptz default now());
create table public.supplier_credits (id uuid primary key default gen_random_uuid(), business_id uuid,
  supplier_id uuid, invoice_number text, original_amount numeric, balance numeric, due_date date,
  status text default 'pending', notes text, created_by uuid, ncf text);
create table public.supplier_credit_payments (id uuid primary key default gen_random_uuid(),
  supplier_credit_id uuid, amount numeric, payment_method_code text, reference text, paid_by uuid,
  created_at timestamptz default now());
create table public.table_deposit_movements (id uuid primary key default gen_random_uuid(),
  business_id uuid, table_id uuid, type text, amount numeric, balance_after numeric,
  payment_method_id uuid, related_table_id uuid, reference text, note text, created_by uuid,
  created_at timestamptz default now());
create table public.inventory_movements (id uuid primary key default gen_random_uuid(), business_id uuid,
  warehouse_id uuid, item_id uuid, movement_type public.movement_type, quantity numeric,
  cost_per_unit numeric, reference_id uuid, reference_type text, notes text, created_by uuid,
  reason_code text, destination text, created_at timestamptz default now());
create table public.purchase_orders (id uuid primary key default gen_random_uuid(), business_id uuid,
  supplier_id uuid, warehouse_id uuid, order_number text, status public.purchase_status default 'draft',
  subtotal numeric, tax numeric, total numeric, notes text, created_by uuid,
  created_at timestamptz default now(), idempotency_key text);
create table public.fixed_assets (id uuid primary key default gen_random_uuid(), business_id uuid,
  code text, name text);
create table public.fixed_asset_movements (id uuid primary key default gen_random_uuid(), asset_id uuid,
  business_id uuid, event_type text, from_warehouse_name text, to_warehouse_name text,
  from_location_note text, to_location_note text, from_employee_name text, to_employee_name text,
  from_status text, to_status text, changes jsonb, notes text, created_by uuid,
  created_at timestamptz default now());
create table public.device_sessions (id uuid primary key default gen_random_uuid(), business_id uuid,
  device_id text, label text, device_name text, hostname text, user_name text, user_email text,
  employee_name text, revoked_at timestamptz, revoked_by uuid, last_seen_at timestamptz default now());
create table public.loyalty_stamp_programs (id uuid primary key default gen_random_uuid(),
  business_id uuid, name text);
create table public.loyalty_stamp_adjustments (id uuid primary key default gen_random_uuid(),
  business_id uuid, program_id uuid, customer_id uuid, stamps int, reason text, created_by uuid,
  created_at timestamptz default now());

insert into public.businesses values ('$BIZ', '$OWNER', 'Prodigio', 'Piantini');
insert into public.user_businesses (user_id, business_id, role) values
  ('$TABLET', '$BIZ', 'cashier'), ('$ADMIN', '$BIZ', 'admin');
insert into public.employees (id, business_id, user_id, first_name, last_name) values
  ('e0000000-0000-0000-0000-000000000001', '$BIZ', '$OWNER', 'Ana', 'Dueña'),
  ('$EMP_JUAN', '$BIZ', '$TABLET', 'Juan', 'Pérez'),
  ('$EMP_MARIA', '$BIZ', null, 'María', 'Gómez');
insert into public.profiles values ('$ADMIN', 'Luis Admin');
insert into public.zones values ('$ZONE', '$BIZ', 'Terraza');
insert into public.dining_tables (id, zone_id, code, label) values
  ('$T1', '$ZONE', 'M1', 'Mesa 1'), ('$T2', '$ZONE', 'M2', 'Mesa 2'), ('$T3', '$ZONE', 'M3', 'Mesa 3');
insert into public.payment_methods values ('$PM_CASH', '$BIZ', 'Efectivo', 'cash'),
                                          ('$PM_CARD', '$BIZ', 'Tarjeta', 'card');
insert into public.cash_registers values ('$REG', '$BIZ', 'Caja 1');
insert into public.cash_transaction_reasons (business_id, code, label) values
  ('$BIZ', 'change_bank', 'Fondo para cambio'), ('$BIZ', 'petty_cash', 'Caja chica');
insert into public.customers values ('$CUST', '$BIZ', 'Pedro Cliente');
insert into public.suppliers values ('$SUP', '$BIZ', 'Distribuidora Vocatus');
insert into public.warehouses values ('$WH', '$BIZ', 'Bar'), ('$WH2', '$BIZ', 'Principal');

-- Stubs con el nombre real: lo que importa es la pila de llamadas.
create function public.fn_transfer_table_session(p_source_session_id uuid, p_target_table_id uuid,
  p_item_ids uuid[] default null) returns jsonb language plpgsql security definer
  set search_path = public as \$\$
declare
  v_src_order uuid; v_tgt_session uuid; v_tgt_order uuid;
begin
  select id into v_src_order from public.orders where session_id = p_source_session_id
    and status_ext <> 'void' limit 1;
  select s.id, o.id into v_tgt_session, v_tgt_order from public.table_sessions s
    join public.orders o on o.session_id = s.id
    where s.table_id = p_target_table_id and s.closed_at is null and o.status_ext <> 'void' limit 1;
  if p_item_ids is not null then
    update public.order_items set order_id = v_tgt_order where id = any(p_item_ids);
    return '{"mode":"partial"}';
  end if;
  if v_tgt_session is null then
    update public.table_sessions set table_id = p_target_table_id where id = p_source_session_id;
    return '{"mode":"full"}';
  end if;
  update public.order_items set order_id = v_tgt_order where order_id = v_src_order;
  update public.orders set closed_at = now(), status_ext = 'void' where id = v_src_order;
  update public.table_sessions set closed_at = now() where id = p_source_session_id;
  return '{"mode":"full","merged_with_existing":true}';
end \$\$;
create function public.fn_update_item_discount(p_item uuid, p_discount numeric) returns void
  language plpgsql security definer set search_path = public as \$\$
begin update public.order_items set discounts = p_discount where id = p_item; end \$\$;
create function public.fn_confirm_order_to_kitchen(p_order_id uuid) returns void
  language plpgsql security definer set search_path = public as \$\$
begin update public.order_items set status = 'pending'
  where order_id = p_order_id and status in ('draft', 'pending'); end \$\$;
create function public.fn_confirm_order_items_to_kitchen(p_order_id uuid, p_item_ids uuid[]) returns void
  language plpgsql security definer set search_path = public as \$\$
begin update public.order_items set status = 'pending'
  where order_id = p_order_id and id = any(p_item_ids) and status = 'draft'; end \$\$;
-- Cobrar una venta rápida también saca los borradores de 'draft': no es un envío.
create function public.fn_close_order_and_table(p_order_id uuid) returns void
  language plpgsql security definer set search_path = public as \$\$
begin update public.order_items set status = 'paid' where order_id = p_order_id; end \$\$;
create function public.fn_apply_order_edit(p_item uuid, p_discount numeric) returns void
  language plpgsql security definer set search_path = public as \$\$
begin perform public.fn_update_item_discount(p_item, p_discount); end \$\$;
SQL
ok "esquema"

run "migración 20260709_0001 (real)" -f "$M/20260709_0001_shared_user_across_branches.sql"
run "migración 20260919_0002 (real)" -f "$M/20260919_0002_order_item_removals.sql"
run "migración 20261013_0001" -f "$M/20261013_0001_change_history.sql"
REC_0001=$(Q -At -c "select md5(prosrc) from pg_proc where proname = 'fn_change_history_record'")

# Sesión + orden + ítems enviados en una mesa; imprime "session order".
mk_table() { # mesa
  local S O
  S=$(Q -At -c "insert into public.table_sessions (id, business_id, table_id) values (gen_random_uuid(), '$BIZ', '$1') returning id;" | head -1)
  O=$(Q -At -c "insert into public.orders (id, session_id, business_id, total) values (gen_random_uuid(), '$S', '$BIZ', 900) returning id;" | head -1)
  Q -c "insert into public.order_items (order_id, business_id, product_name, qty, quantity, unit_price, status, kitchen_sent_at)
        values ('$O', '$BIZ', 'Mojito', 2, 2, 300, 'pending', now()), ('$O', '$BIZ', 'Nachos', 1, 1, 300, 'pending', now());" >/dev/null
  echo "$S $O"
}

echo "== Antes de 0002: pasar a una mesa ocupada salía como «anuló la cuenta»"
read -r SA OA <<<"$(mk_table "$T1")"
read -r SB OB <<<"$(mk_table "$T2")"
# Solo pasa si la cuenta de origen ya tenía un pago (sin pago, 0001 la salta).
Q -c "insert into public.payments (business_id, order_id, payment_method_id, amount) values ('$BIZ', '$OA', '$PM_CASH', 300);" >/dev/null
Q -c "$(ctx /rpc/fn_transfer_table_session $TABLET) select public.fn_transfer_table_session('$SA', '$T2');" >/dev/null
expect "0001 la anotó como anulación (el error)" "$(N "table_name = 'orders' and action = 'void' and row_id = '$OA'")" "1"

run "migración 20261013_0002" -f "$M/20261013_0002_change_history_operations.sql"
run "migración 20261013_0002 otra vez (idempotente)" -f "$M/20261013_0002_change_history_operations.sql"
expect "esa línea ya no dice anuló: pasó la cuenta" \
  "$(H "table_name || '|' || action || '|' || (changes ->> 'event')" "row_id = '$OA'")" "table_sessions|update|items_transfer"
expect "y no quedó ninguna anulación falsa" "$(N "table_name = 'orders' and action = 'void'")" "0"

echo "== Caja: lo que se agrega, retira o gasta"
CS=$(Q -At -c "$(ctx /rpc/fn_open_cash_session $TABLET) insert into public.cash_register_sessions (cash_register_id, user_id, start_amount, device_name)
  values ('$REG', '$TABLET', 2000, 'Caja Bar') returning id;" | tail -1)
expect "abrir la caja: caja, equipo y fondo" \
  "$(H "action || '|' || label || '|' || context || '|' || actor_name || '|' || (changes ->> 'event') || '|' || (changes ->> 'start_amount')" "row_id = '$CS'")" \
  "create|Caja 1|Caja Bar|Juan Pérez|cash_open|2000"
CT=$(Q -At -c "$(ctx /rpc/fn_cash_transaction_create $TABLET) insert into public.cash_transactions (session_id, amount, type, reason_code, description, created_by, approved_by, approval_pin_used)
  values ('$CS', 500, 'deposit', 'change_bank', 'Cambio del banco', '$TABLET', '$ADMIN', true) returning id;" | tail -1)
expect "entrada a la caja: motivo, quién y quién autorizó" \
  "$(H "action || '|' || label || '|' || context || '|' || actor_name || '|' || (changes ->> 'event') || '|' || (changes ->> 'amount') || '|' || (changes ->> 'approved_by')" "row_id = '$CT'")" \
  "create|Caja 1|Fondo para cambio|Juan Pérez|cash_deposit|500|Luis Admin"
Q -c "$(ctx /rpc/fn_cash_transaction_create $TABLET) insert into public.cash_transactions (session_id, amount, type, reason_code, created_by)
      values ('$CS', 200, 'expense', 'petty_cash', '$TABLET'), ('$CS', 300, 'withdrawal', 'change_bank', '$TABLET');" >/dev/null
expect "gasto y retiro también" "$(N "table_name = 'cash_transactions' and changes ->> 'event' in ('cash_expense', 'cash_withdrawal')")" "2"
Q -c "$(ctx /rpc/fn_process_payment_v3 $TABLET) insert into public.cash_transactions (session_id, amount, type, description)
      values ('$CS', 900, 'sale', 'Venta 1234'), ('$CS', 400, 'deposit', 'Abono a crédito AB-00001');" >/dev/null
expect "cobros y abonos del sistema no (salen en su tabla)" "$(N "table_name = 'cash_transactions'")" "3"
Q -c "$(ctx /cash_transactions $ADMIN) update public.cash_transactions set amount = 50 where id = '$CT';" >/dev/null
expect "editar un movimiento: quién lo editó y el monto" \
  "$(H "action || '|' || actor_name || '|' || (changes -> 'amount')::text" "row_id = '$CT'")" "update|Luis Admin|[500, 50]"
Q -c "$(ctx /cash_transactions $ADMIN) delete from public.cash_transactions where id = '$CT';" >/dev/null
expect "borrar un movimiento" "$(H "action || '|' || actor_name" "row_id = '$CT'")" "delete|Luis Admin"
Q -c "$(ctx /audit_logs $TABLET) insert into public.audit_logs (business_id, user_id, action, reason, ref_table, ref_id)
      values ('$BIZ', '$TABLET', 'cash_recount', '{\"cash\": 2300, \"card\": 0, \"transfer\": 0}', 'cash_register_sessions', '$CS');" >/dev/null
expect "recontar la caja" "$(H "(changes ->> 'event') || '|' || (changes ->> 'cash') || '|' || label" "row_id = '$CS'")" "cash_recount|2300|Caja 1"
Q -c "$(ctx /rpc/fn_close_cash_session $TABLET) update public.cash_register_sessions set status = 'closed', end_amount = 2300, difference = -0,
      notes = 'Todo bien | Cerrado por $TABLET (rol: cashier)' where id = '$CS';" >/dev/null
expect "cerrar la caja: contado y notas sin ids" \
  "$(H "(changes ->> 'event') || '|' || (changes ->> 'end_amount') || '|' || (changes ->> 'notes')" "row_id = '$CS'")" "cash_close|2300|Todo bien"
CS2=$(Q -At -c "insert into public.cash_register_sessions (cash_register_id, user_id, start_amount) values ('$REG', '$TABLET', 0) returning id;" | tail -1)
Q -c "$(ctx /rpc/fn_force_close_cash_session $OWNER) update public.cash_register_sessions set status = 'closed',
      notes = ' [FORCE_CLOSED by $OWNER on 2026-10-13 23:10: El cajero se fue]' where id = '$CS2';" >/dev/null
expect "cerrar a la fuerza: dueño y motivo" \
  "$(H "(changes ->> 'event') || '|' || actor_name || '|' || (changes ->> 'notes')" "row_id = '$CS2' and action = 'update'")" \
  "cash_force_close|Ana Dueña|[Cierre forzado: El cajero se fue]"

echo "== Pasar cuentas y productos de mesa"
read -r SC OC <<<"$(mk_table "$T3")"
Q -c "$(ctx /rpc/fn_transfer_table_session $TABLET) select public.fn_transfer_table_session('$SC', '$T1');" >/dev/null
expect "pasar la cuenta a una mesa libre" \
  "$(H "(changes ->> 'event') || '|' || label || '|' || context || '|' || actor_name" "row_id = '$SC'")" "table_transfer|Mesa 3|Mesa 1|Juan Pérez"
read -r SD OD <<<"$(mk_table "$T3")"
Q -c "$(ctx /rpc/fn_transfer_table_session $TABLET) select public.fn_transfer_table_session('$SD', '$T1');" >/dev/null
expect "pasar a una mesa ocupada: una línea con los productos" \
  "$(H "(changes ->> 'event') || '|' || label || '|' || context || '|' || (changes ->> 'items_count') || '|' || (changes -> 'products')::text" "row_id = '$OD'")" \
  'items_transfer|Mesa 3|Mesa 1|2|["2 × Mojito", "1 × Nachos"]'
expect "y no dice que la anuló" "$(N "table_name = 'orders' and action = 'void'")" "0"
read -r SE OE <<<"$(mk_table "$T3")"
IT=$(Q -At -c "select id from public.order_items where order_id = '$OE' and product_name = 'Nachos'")
Q -c "$(ctx /rpc/fn_transfer_table_session $TABLET) select public.fn_transfer_table_session('$SE', '$T1', array['$IT']::uuid[]);" >/dev/null
expect "pasar un solo producto" "$(H "(changes ->> 'items_count') || '|' || (changes -> 'products')::text" "row_id = '$OE'")" '1|["1 × Nachos"]'
Q -c "$(ctx /table_sessions $TABLET) update public.table_sessions set table_id = '$T2' where id = '$SE';" >/dev/null
expect "mover la sesión por otro camino no es un traslado" "$(N "row_id = '$SE'")" "0"

echo "== Descuentos y cortesías"
read -r SF OF <<<"$(mk_table "$T2")"
I1=$(Q -At -c "select id from public.order_items where order_id = '$OF' and product_name = 'Mojito'")
I2=$(Q -At -c "select id from public.order_items where order_id = '$OF' and product_name = 'Nachos'")
Q -c "$(ctx /rpc/fn_apply_order_edit $TABLET) select public.fn_apply_order_edit('$I1', 60);" >/dev/null
Q -c "$(ctx /rpc/fn_apply_order_edit $TABLET) select public.fn_apply_order_edit('$I2', 30);" >/dev/null
expect "descuento repartido en dos líneas = una línea por cuenta" \
  "$(N "row_id = '$OF' and changes ->> 'event' = 'discount'")" "1"
expect "con el total antes → después y la mesa" \
  "$(H "label || '|' || actor_name || '|' || (changes -> 'discount')::text || '|' || jsonb_array_length(jsonb_path_query_array(changes, '\$.lines.*'))" "row_id = '$OF'")" \
  "Mesa 2|Juan Pérez|[0.00, 90.00]|2"
Q -c "$(ctx /rpc/fn_recalc $TABLET) update public.order_items set discounts = 99 where id = '$I1';" >/dev/null
expect "un recálculo que no pidió nadie no cuenta" "$(H "(changes -> 'discount')::text" "row_id = '$OF'")" "[0.00, 90.00]"
Q -c "update public.order_items set notes = '[CORTESIA:Cumpleaños]' where id = '$I2';
      $(ctx /rpc/fn_apply_order_edit $TABLET) select public.fn_apply_order_edit('$I2', 300);" >/dev/null
expect "cortesía con su motivo (misma línea, dentro de 2 min)" \
  "$(H "(changes ->> 'courtesy') || '|' || (changes -> 'discount')::text" "row_id = '$OF'")" "Cumpleaños|[0.00, 360.00]"

echo "== Pagos, mesero, notas"
PAY=$(Q -At -c "insert into public.payments (business_id, order_id, payment_method_id, amount) values ('$BIZ', '$OF', '$PM_CASH', 900) returning id;" | head -1)
Q -c "$(ctx /payments $ADMIN) update public.payments set payment_method_id = '$PM_CARD' where id = '$PAY';" >/dev/null
expect "cambiar el método de pago" \
  "$(H "(changes ->> 'event') || '|' || label || '|' || (changes -> 'payment_method')::text" "row_id = '$PAY'")" \
  'payment_method|Mesa 2|["Efectivo", "Tarjeta"]'
Q -c "$(ctx /rpc/fn_reassign_table_waiter $OWNER) insert into public.table_session_waiter_changes
      (business_id, session_id, table_id, from_employee_id, to_employee_id, changed_by, reason)
      values ('$BIZ', '$SF', '$T2', '$EMP_JUAN', '$EMP_MARIA', '$OWNER', 'Cambio de turno');" >/dev/null
expect "cambiar el mesero" \
  "$(H "(changes ->> 'event') || '|' || label || '|' || (changes -> 'waiter')::text || '|' || (changes ->> 'reason')" "row_id = '$SF'")" \
  'waiter_change|Mesa 2|["Juan Pérez", "María Gómez"]|Cambio de turno'
FD=$(Q -At -c "insert into public.fiscal_documents (business_id, ncf_number, total) values ('$BIZ', 'B0100000123', 900) returning id;" | head -1)
expect "una factura normal no se anota" "$(N "table_name = 'fiscal_documents'")" "0"
Q -c "$(ctx /rpc/fn_issue_credit_note $ADMIN) insert into public.fiscal_documents (business_id, ncf_number, total, related_document_id, modification_reason, issued_by)
      values ('$BIZ', 'B0400000007', 900, '$FD', 'Devolución', '$ADMIN');" >/dev/null
expect "nota de crédito: la nueva y la original" \
  "$(H "label || '|' || context || '|' || (changes ->> 'reason') || '|' || actor_name" "table_name = 'fiscal_documents'")" \
  "B0400000007|B0100000123|Devolución|Luis Admin"
SN=$(Q -At -c "insert into public.sales_notes (business_id, note_number, total) values ('$BIZ', 'NV-00012', 450) returning id;" | head -1)
Q -c "$(ctx /sales_notes $TABLET) update public.sales_notes set status = 'cancelled', cancellation_reason = 'Error' where id = '$SN';" >/dev/null
expect "anular una nota de venta" "$(H "action || '|' || label || '|' || (changes ->> 'reason')" "row_id = '$SN'")" "void|NV-00012|Error"

echo "== Créditos y abonos"
CC=$(Q -At -c "insert into public.customer_credits (business_id, customer_id, original_amount, balance) values ('$BIZ', '$CUST', 1000, 1000) returning id;" | head -1)
Q -c "$(ctx /rpc/fn_register_credit_abono_v2 $TABLET) insert into public.credit_payments (credit_id, amount, payment_method_id, received_by, code, business_id)
      values ('$CC', 400, '$PM_CASH', '$TABLET', 'AB-00001', '$BIZ');" >/dev/null
expect "abono de un cliente" \
  "$(H "label || '|' || context || '|' || (changes ->> 'amount') || '|' || (changes ->> 'payment_method')" "table_name = 'credit_payments'")" \
  "AB-00001|Pedro Cliente|400|Efectivo"
Q -c "$(ctx /customer_credits $OWNER) update public.customer_credits set status = 'cancelled', notes = 'Incobrable' where id = '$CC';" >/dev/null
expect "cancelar un crédito a mano" "$(H "action || '|' || label || '|' || (changes ->> 'notes')" "row_id = '$CC'")" "void|Pedro Cliente|Incobrable"
SCR=$(Q -At -c "$(ctx /supplier_credits $ADMIN) insert into public.supplier_credits (business_id, supplier_id, invoice_number, original_amount, balance, created_by)
  values ('$BIZ', '$SUP', 'F-881', 5000, 5000, '$ADMIN') returning id;" | tail -1)
expect "cuenta por pagar nueva" "$(H "action || '|' || label || '|' || context" "row_id = '$SCR'")" "create|Distribuidora Vocatus|F-881"
Q -c "$(ctx /rpc/fn_register_supplier_credit_payment $ADMIN) insert into public.supplier_credit_payments (supplier_credit_id, amount, payment_method_code, paid_by)
      values ('$SCR', 2000, 'cash', '$ADMIN');" >/dev/null
expect "pago a proveedor" "$(H "label || '|' || (changes ->> 'amount') || '|' || (changes ->> 'payment_method')" "table_name = 'supplier_credit_payments'")" \
  "Distribuidora Vocatus|2000|Efectivo"
Q -c "$(ctx /rpc/fn_table_deposit_add $TABLET) insert into public.table_deposit_movements (business_id, table_id, type, amount, balance_after, payment_method_id, created_by)
      values ('$BIZ', '$T2', 'deposit', 3000, 3000, '$PM_CASH', '$TABLET'),
             ('$BIZ', '$T2', 'consumption', -900, 2100, null, null);" >/dev/null
expect "abono por mesa sí; el consumo de la venta no" \
  "$(N "table_name = 'table_deposit_movements'")|$(H "(changes ->> 'event') || '|' || label || '|' || (changes ->> 'amount')" "table_name = 'table_deposit_movements'")" \
  "1|deposit_deposit|Mesa 2|3000"

echo "== Inventario"
INV=$(Q -At -c "insert into public.inventory_items (business_id, name) values ('$BIZ', 'Ron blanco') returning id;" | head -1)
Q -c "begin; $(ctx /rpc/fn_inventory_adjust $ADMIN)
      insert into public.inventory_movements (id, business_id, warehouse_id, item_id, movement_type, quantity, reference_type, created_by)
        values ('96000000-0000-0000-0000-000000000002', '$BIZ', '$WH', '$INV', 'adjustment', -3, 'stock_adjustment', '$ADMIN');
      update public.inventory_movements set reason_code = 'correction' where id = '96000000-0000-0000-0000-000000000002';
      commit;" >/dev/null
expect "ajuste con el motivo que se pone después del insert" \
  "$(H "(changes ->> 'event') || '|' || label || '|' || context || '|' || (changes ->> 'quantity') || '|' || (changes ->> 'reason_code') || '|' || actor_name" "table_name = 'inventory_movements'")" \
  "stock_adjust|Ron blanco|Bar|-3|correction|Luis Admin"
Q -c "begin; $(ctx /rpc/fn_inventory_adjust $ADMIN)
      insert into public.inventory_movements (id, business_id, warehouse_id, item_id, movement_type, quantity, reference_type, created_by)
        values ('96000000-0000-0000-0000-000000000001', '$BIZ', '$WH', '$INV', 'waste', -1, 'manual_outflow', '$ADMIN');
      update public.inventory_movements set reason_code = 'breakage', destination = 'Basura'
        where id = '96000000-0000-0000-0000-000000000001';
      commit;" >/dev/null
expect "salida: se lee al COMMIT, ya con motivo y destino" \
  "$(H "(changes ->> 'event') || '|' || (changes ->> 'reason_code') || '|' || (changes ->> 'destination')" "row_id = '96000000-0000-0000-0000-000000000001'")" \
  "stock_outflow|breakage|Basura"
Q -c "$(ctx /rpc/fn_confirm_order_items_to_kitchen $TABLET) insert into public.inventory_movements (business_id, warehouse_id, item_id, movement_type, quantity, reference_type)
      values ('$BIZ', '$WH', '$INV', 'sale', -2, 'order');
      $(ctx /rpc/fn_physical_count_complete $ADMIN) insert into public.inventory_movements (business_id, warehouse_id, item_id, movement_type, quantity, reference_type)
      values ('$BIZ', '$WH', '$INV', 'adjustment', 5, 'physical_count');" >/dev/null
expect "consumo de la venta y líneas de un conteo no" "$(N "table_name = 'inventory_movements'")" "2"
PO=$(Q -At -c "$(ctx /rpc/fn_purchase_order_create $ADMIN) insert into public.purchase_orders (business_id, supplier_id, warehouse_id, order_number, total, idempotency_key)
  values ('$BIZ', '$SUP', '$WH2', 'PO-12', 8000, 'k1') returning id;" | tail -1)
expect "orden de compra: número y proveedor" "$(H "action || '|' || label || '|' || context || '|' || (changes ->> 'warehouse_id')" "row_id = '$PO'")" \
  "create|PO-12|Distribuidora Vocatus|Principal"
Q -c "$(ctx /rpc/fn_purchase_order_cancel $ADMIN) update public.purchase_orders set status = 'cancelled' where id = '$PO';" >/dev/null
expect "cancelarla" "$(H "(changes -> 'status')::text" "row_id = '$PO'")" '["draft", "cancelled"]'
FA=$(Q -At -c "insert into public.fixed_assets (business_id, code, name) values ('$BIZ', 'AF-001', 'Nevera Imbera') returning id;" | head -1)
Q -c "$(ctx /rpc/fn_fixed_asset_move $ADMIN) insert into public.fixed_asset_movements (asset_id, business_id, event_type, from_warehouse_name, to_warehouse_name, created_by)
      values ('$FA', '$BIZ', 'relocated', 'Bar', 'Principal', '$ADMIN');" >/dev/null
expect "activo fijo movido" "$(H "(changes ->> 'event') || '|' || label || '|' || (changes -> 'warehouse_id')::text" "row_id = '$FA'")" \
  'asset_relocated|Nevera Imbera|["Bar", "Principal"]'

echo "== Configuración y seguridad"
MENU=$(Q -At -c "insert into public.menus (business_id, name) values ('$BIZ', 'Menú noche') returning id;" | head -1)
MI=$(Q -At -c "insert into public.menu_items (business_id, name) values ('$BIZ', 'Pizza') returning id;" | head -1)
Q -c "$(ctx /menu_item_links $OWNER) insert into public.menu_item_links (menu_id, item_id) values ('$MENU', '$MI');" >/dev/null
expect "agregar un producto a un menú" "$(H "action || '|' || label || '|' || context" "table_name = 'menu_item_links'")" "create|Pizza|Menú noche"
DS=$(Q -At -c "insert into public.device_sessions (business_id, device_id, device_name, employee_name) values ('$BIZ', 'dev-1', 'PC Barra', 'Juan Pérez') returning id;" | head -1)
Q -c "$(ctx /rpc/fn_device_sessions_revoke $OWNER) update public.device_sessions set revoked_at = now(), revoked_by = '$OWNER' where id = '$DS';" >/dev/null
expect "cerrar la sesión de un equipo a distancia" "$(H "(changes ->> 'event') || '|' || label || '|' || context || '|' || actor_name" "row_id = '$DS'")" \
  "device_revoke|PC Barra|Juan Pérez|Ana Dueña"
Q -c "update public.device_sessions set last_seen_at = now() where id = '$DS';" >/dev/null
expect "los pings no" "$(N "row_id = '$DS'")" "1"
LP=$(Q -At -c "insert into public.loyalty_stamp_programs (business_id, name) values ('$BIZ', 'Café #10') returning id;" | tail -1)
Q -c "$(ctx /rpc/fn_loyalty_adjust_stamps $ADMIN) insert into public.loyalty_stamp_adjustments (business_id, program_id, customer_id, stamps, reason, created_by)
      values ('$BIZ', '$LP', '$CUST', 2, 'Compensación', '$ADMIN');" >/dev/null
expect "ajustar sellos" "$(H "label || '|' || context || '|' || (changes ->> 'stamps')" "table_name = 'loyalty_stamp_adjustments'")" "Pedro Cliente|Café #10|2"

echo "== Envíos a cocina (20261013_0003)"
run "migración 20261013_0003" -f "$M/20261013_0003_change_history_kitchen.sql"
run "migración 20261013_0003 otra vez (idempotente)" -f "$M/20261013_0003_change_history_kitchen.sql"
SK=$(Q -At -c "insert into public.table_sessions (id, business_id, table_id) values (gen_random_uuid(), '$BIZ', '$T3') returning id;" | head -1)
OK_=$(Q -At -c "insert into public.orders (id, session_id, business_id) values (gen_random_uuid(), '$SK', '$BIZ') returning id;" | head -1)
K1=$(Q -At -c "insert into public.order_items (order_id, business_id, product_name, qty, quantity, notes, created_by_employee_id)
  values ('$OK_', '$BIZ', 'Hamburguesa', 2, 2, 'sin cebolla [PROMO_AUTO:x]', '$EMP_MARIA') returning id;" | head -1)
Q -c "insert into public.order_item_modifiers values ('$K1', 'Queso extra', 1);
      insert into public.order_items (order_id, business_id, product_name, qty, quantity, created_by_employee_id)
      values ('$OK_', '$BIZ', 'Coca-Cola', 1, 1, '$EMP_MARIA');" >/dev/null
Q -c "$(ctx /rpc/fn_confirm_order_to_kitchen $TABLET) select public.fn_confirm_order_to_kitchen('$OK_');" >/dev/null
expect "un envío = una línea con los productos, del mesero del PIN" \
  "$(H "action || '|' || label || '|' || actor_name || '|' || (changes ->> 'items_count') || '|' || (changes -> 'products')::text" "table_name = 'kitchen_rounds' and row_id = '$OK_'")" \
  'create|Mesa 3|María Gómez|2|["2 × Hamburguesa + Queso extra (sin cebolla)", "1 × Coca-Cola"]'
Q -c "$(ctx /rpc/fn_confirm_order_to_kitchen $TABLET) select public.fn_confirm_order_to_kitchen('$OK_');" >/dev/null
expect "reenviar sin borradores nuevos no suma nada" "$(N "table_name = 'kitchen_rounds' and row_id = '$OK_'")" "1"
K3=$(Q -At -c "insert into public.order_items (order_id, business_id, product_name, qty, quantity) values ('$OK_', '$BIZ', 'Postre', 1, 1) returning id;" | head -1)
Q -c "$(ctx /rpc/fn_confirm_order_items_to_kitchen $TABLET) select public.fn_confirm_order_items_to_kitchen('$OK_', array['$K3']::uuid[]);" >/dev/null
expect "segunda ronda = otra línea (sin PIN: la cuenta logueada)" \
  "$(N "table_name = 'kitchen_rounds' and row_id = '$OK_'")|$(H "actor_name || '|' || (changes ->> 'items_count')" "table_name = 'kitchen_rounds' and row_id = '$OK_'")" \
  "2|Juan Pérez|1"
SQ=$(Q -At -c "insert into public.table_sessions (id, business_id, origin) values (gen_random_uuid(), '$BIZ', 'quick') returning id;" | head -1)
OQ=$(Q -At -c "insert into public.orders (id, session_id, business_id) values (gen_random_uuid(), '$SQ', '$BIZ') returning id;" | head -1)
Q -c "insert into public.order_items (order_id, business_id, product_name) values ('$OQ', '$BIZ', 'Café');
      $(ctx /rpc/fn_close_order_and_table $TABLET) select public.fn_close_order_and_table('$OQ');" >/dev/null
expect "cobrar una venta rápida no es un envío" "$(N "table_name = 'kitchen_rounds' and row_id = '$OQ'")" "0"
Q -c "$(ctx /order_items $TABLET) update public.order_items set status = 'ready' where id = '$K1';" >/dev/null
expect "cocina marcando listo no suma nada" "$(N "table_name = 'kitchen_rounds'")" "2"

echo "== Nunca bloquea la venta"
Q -c "alter table public.change_history rename to change_history_x;" >/dev/null
run "si el historial falla, el descuento igual se guarda" \
  -c "$(ctx /rpc/fn_apply_order_edit $TABLET) select public.fn_apply_order_edit('$I1', 10);"
expect "y quedó" "$(Q -At -c "select discounts from public.order_items where id = '$I1'")" "10.00"
Q -c "alter table public.change_history_x rename to change_history;" >/dev/null

echo "== Reversa"
run "ROLLBACK de 0003" -f "$M/20261013_0003_change_history_kitchen_ROLLBACK.sql"
expect "sin el trigger de cocina" "$(Q -At -c "select count(*) from pg_trigger where tgname = 'trg_zz_change_history_kitchen'")" "0"
run "ROLLBACK de 0002" -f "$M/20261013_0002_change_history_operations_ROLLBACK.sql"
expect "el trigger general vuelve a ser el de 0001" \
  "$(Q -At -c "select md5(prosrc) from pg_proc where proname = 'fn_change_history_record'")" "$REC_0001"
expect "sin triggers de 0002" "$(Q -At -c "select count(*) from pg_trigger where tgname in ('trg_zz_change_history_move', 'trg_zz_change_history_discount', 'trg_zz_change_history_method') or (tgname = 'trg_zz_change_history' and tgrelid = 'public.cash_transactions'::regclass)")" "0"
expect "los de 0001 siguen" "$(Q -At -c "select count(*) from pg_trigger where tgname = 'trg_zz_change_history_void'")" "2"
B=$(N)
Q -c "$(ctx /menu_items $OWNER) update public.menu_items set price = 5 where id = '$MI';" >/dev/null
expect "0001 sigue anotando después de la reversa" "$(N)" "$((B + 1))"
run "re-aplicar 0002 después de la reversa" -f "$M/20261013_0002_change_history_operations.sql"

echo
if [[ $FAIL -eq 0 ]]; then echo "TODO OK"; else echo "HAY FALLAS"; fi
exit $FAIL
