#!/usr/bin/env bash
# =============================================================================
# Prueba LOCAL del historial de cambios (20261013_0001).
# Postgres 15 DESECHABLE con el esquema mínimo; corre los archivos REALES del
# repo: 20260709_0001 (quién es admin), 20260919_0002 (registro de productos
# quitados del POS) y 20261013_0001 (+ su ROLLBACK). No toca ninguna base real.
#
#   bash supabase/tests/change_history_local_test.sh [carpeta_trabajo]
# Variables: PG_BIN (default homebrew postgresql@15), PG_PORT (default 55481).
# =============================================================================
set -u
REPO=$(cd "$(dirname "$0")/../.." && pwd)
M=$REPO/supabase/migrations
PG=${PG_BIN:-/opt/homebrew/opt/postgresql@15/bin}
PORT=${PG_PORT:-55481}
WORK=${1:-$(mktemp -d)}
D=$WORK/pg_change_history
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
BIZ2=b0000000-0000-0000-0000-000000000002
OWNER=a0000000-0000-0000-0000-000000000001
TABLET=a0000000-0000-0000-0000-000000000002
ADMIN=a0000000-0000-0000-0000-000000000003
CASHIER=a0000000-0000-0000-0000-000000000004
OWNER2=a0000000-0000-0000-0000-000000000005
MAILONLY=a0000000-0000-0000-0000-000000000006
EMP_ANA=e0000000-0000-0000-0000-000000000001
EMP_JUAN=e0000000-0000-0000-0000-000000000002
EMP_MARIA=e0000000-0000-0000-0000-000000000003
CAT_BEB=c0000000-0000-0000-0000-000000000001
CAT_POS=c0000000-0000-0000-0000-000000000002
TAX_ITBIS=f0000000-0000-0000-0000-000000000001
TAX_LEY=f0000000-0000-0000-0000-000000000002
ZONE=d1000000-0000-0000-0000-000000000001
TBL=d0000000-0000-0000-0000-000000000001
ROLE_CAJ=90000000-0000-0000-0000-000000000001
PERM_DEL=91000000-0000-0000-0000-000000000001
PERM_DISC=91000000-0000-0000-0000-000000000002
PM_CASH=92000000-0000-0000-0000-000000000001

# Contexto de la petición, como lo deja PostgREST. $1 = path ('' = Studio,
# sin JWT), $2 = cuenta (sub).
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
-- Como Supabase: todo objeto nuevo de public nace con permisos para
-- anon/authenticated; la migración tiene que revocarlos.
alter default privileges in schema public grant all on tables to anon, authenticated;
alter default privileges in schema public grant all on sequences to anon, authenticated;
alter default privileges in schema public grant execute on functions to anon, authenticated;

create type public.order_status as enum ('open','sent_to_kitchen','partially_paid','paid','void');
create type public.item_status as enum ('pending','preparing','ready','served','void','draft','paid');
create type public.order_origin as enum ('dine_in','manual','quick','delivery','self_service');

create table public.businesses (id uuid primary key, owner_id uuid, business_name text,
  branch_name text, status text default 'active', plan text);
create table public.memberships (user_id uuid, business_id uuid, role text);
create table public.user_businesses (id uuid primary key default gen_random_uuid(),
  user_id uuid, business_id uuid, role text, permissions text[] default '{all}');
create table public.roles (id uuid primary key, business_id uuid, name text, level text);
create table public.employees (id uuid primary key, business_id uuid, user_id uuid,
  first_name text not null, last_name text not null, pin text, position text,
  created_at timestamptz default now());
create table public.employee_roles (employee_id uuid, role_id uuid, primary key (employee_id, role_id));
create table public.profiles (id uuid primary key, full_name text);
create table public.permissions (id uuid primary key, code text, name text);
create table public.role_permissions (role_id uuid references public.roles(id) on delete cascade,
  permission_id uuid, allow boolean default true, created_at timestamptz default now(),
  primary key (role_id, permission_id));

create table public.categories (id uuid primary key, business_id uuid not null, name text not null,
  position int default 0, is_active boolean default true, created_at timestamptz default now());
create table public.menu_items (id uuid primary key default gen_random_uuid(), business_id uuid not null,
  category_id uuid, name text not null, price numeric(12,2) default 0, is_active boolean default true,
  auto_disabled boolean default false, position int default 0, image_url text,
  created_at timestamptz default now(), updated_at timestamptz);
create table public.taxes (id uuid primary key, business_id uuid not null, name text not null,
  rate numeric not null, is_active boolean default true);
create table public.menu_item_taxes (item_id uuid references public.menu_items(id) on delete cascade,
  tax_id uuid, primary key (item_id, tax_id));
create table public.zones (id uuid primary key, business_id uuid not null, name text, sort_index int default 0);
create table public.dining_tables (id uuid primary key, zone_id uuid, code text not null, label text,
  state text default 'available', pos_x numeric default 0, capacity int default 4);
create table public.ncf_sequences (id uuid primary key default gen_random_uuid(), business_id uuid not null,
  ncf_type text, serie text, prefix text, range_end bigint, current_number bigint, device_id text);
create table public.business_settings (id uuid primary key default gen_random_uuid(),
  business_id uuid unique, tip_enabled boolean default true, sales_note_count int default 0,
  updated_at timestamptz);
create table public.payment_methods (id uuid primary key, business_id uuid, name text, code text);
create table public.inventory_items (id uuid primary key default gen_random_uuid(), business_id uuid, name text);
create table public.recipes (id uuid primary key default gen_random_uuid(), menu_item_id uuid,
  inventory_item_id uuid);
create table public.recipe_ingredients (id uuid primary key default gen_random_uuid(), recipe_id uuid,
  inventory_item_id uuid, quantity numeric, unit text);

-- Operación (lo que pide 20260919_0002 y el historial de anulaciones)
create table public.table_sessions (id uuid primary key, business_id uuid, table_id uuid,
  origin public.order_origin not null default 'dine_in', note text);
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
  ncf_number text, status text default 'active');
create table public.payments (id uuid primary key default gen_random_uuid(),
  business_id uuid not null, order_id uuid, check_id uuid, fiscal_document_id uuid,
  payment_method_id uuid, amount numeric not null, change_amount numeric default 0,
  reference text, status text default 'completed', created_at timestamptz default now());

insert into public.businesses values ('$BIZ', '$OWNER', 'Prodigio', 'Piantini'),
                                     ('$BIZ2', '$OWNER2', 'Otro', null);
insert into public.user_businesses (user_id, business_id, role) values
  ('$TABLET', '$BIZ', 'cashier'), ('$ADMIN', '$BIZ', 'admin'), ('$CASHIER', '$BIZ', 'cashier');
insert into public.employees (id, business_id, user_id, first_name, last_name) values
  ('$EMP_ANA', '$BIZ', '$OWNER', 'Ana', 'Dueña'),
  ('$EMP_JUAN', '$BIZ', '$TABLET', 'Juan', 'Pérez'),
  ('$EMP_MARIA', '$BIZ', null, 'María', 'Gómez');
insert into public.profiles values ('$ADMIN', 'Luis Admin');
insert into auth.users values ('$MAILONLY', 'sofia@correo.com');
insert into public.roles values ('$ROLE_CAJ', '$BIZ', 'Cajero', null);
insert into public.permissions values ('$PERM_DEL', 'ventas.orden.eliminar_item', 'Eliminar ítem'),
                                      ('$PERM_DISC', 'ventas.descuento', 'Aplicar descuento');
insert into public.categories (id, business_id, name) values
  ('$CAT_BEB', '$BIZ', 'Bebidas'), ('$CAT_POS', '$BIZ', 'Postres');
insert into public.taxes values ('$TAX_ITBIS', '$BIZ', 'ITBIS 18%', 18), ('$TAX_LEY', '$BIZ', 'Ley 10%', 10);
insert into public.zones values ('$ZONE', '$BIZ', 'Terraza');
insert into public.dining_tables (id, zone_id, code, label) values ('$TBL', '$ZONE', 'M5', 'Mesa 5');
insert into public.business_settings (business_id) values ('$BIZ');
insert into public.payment_methods values ('$PM_CASH', '$BIZ', 'Efectivo', 'cash');
SQL
ok "esquema"

run "migración 20260709_0001 (quién es admin, real)" -f "$M/20260709_0001_shared_user_across_branches.sql"
run "migración 20260919_0002 (productos quitados, real)" -f "$M/20260919_0002_order_item_removals.sql"

# Un producto quitado ANTES del historial (lo copia la migración).
OLD_ORDER=$(Q -At -c "with s as (insert into public.table_sessions (id, business_id, table_id)
  values (gen_random_uuid(), '$BIZ', '$TBL') returning id)
  insert into public.orders (id, session_id, business_id) select gen_random_uuid(), s.id, '$BIZ' from s returning id;" | head -1)
OLD_ITEM=$(Q -At -c "insert into public.order_items (order_id, business_id, product_name, qty, quantity, unit_price, status, kitchen_sent_at)
  values ('$OLD_ORDER', '$BIZ', 'Old Parr 18', 1, 1, 24000, 'pending', now()) returning id;" | head -1)
Q -c "$(ctx /order_items $TABLET) delete from public.order_items where id = '$OLD_ITEM';" >/dev/null

run "migración 20261013_0001" -f "$M/20261013_0001_change_history.sql"
run "migración 20261013_0001 otra vez (idempotente)" -f "$M/20261013_0001_change_history.sql"

echo "== Permisos"
expect "anon no lee el historial" \
  "$(Q -At -c "select has_table_privilege('anon', 'public.change_history', 'select')")" "f"
expect "authenticated solo lectura" \
  "$(Q -At -c "select has_table_privilege('authenticated', 'public.change_history', 'select')::text
     || has_table_privilege('authenticated', 'public.change_history', 'insert')::text
     || has_table_privilege('authenticated', 'public.change_history', 'update')::text
     || has_table_privilege('authenticated', 'public.change_history', 'delete')::text")" "truefalsefalsefalse"
expect "nadie de la app ejecuta el trigger a mano" \
  "$(Q -At -c "select has_function_privilege('authenticated', 'public.fn_change_history_record()', 'execute')")" "f"
expect "las tablas que no existen se saltan (modifier_groups)" \
  "$(Q -At -c "select count(*) from pg_trigger where tgname = 'trg_zz_change_history' and tgrelid = 'public.categories'::regclass")" "1"

echo "== Atrasado: lo quitado antes de aplicar se copia una sola vez"
expect "producto quitado antes del historial" \
  "$(H "action || '|' || label || '|' || actor_name || '|' || (changes ->> 'amount')" "table_name = 'order_items' and row_id = '$OLD_ITEM'")" \
  "delete|Old Parr 18|Juan Pérez|24000.00"
expect "sin duplicar al re-aplicar" "$(N "row_id = '$OLD_ITEM'")" "1"

echo "== Crear, editar y borrar"
P=$(Q -At -c "$(ctx /menu_items $OWNER) insert into public.menu_items (business_id, category_id, name, price)
  values ('$BIZ', '$CAT_BEB', 'Johnnie Walker 18', 24000) returning id;" | tail -1)
expect "crear: quién, qué y la foto" \
  "$(H "action || '|' || label || '|' || actor_name || '|' || (changes ->> 'price') || '|' || (changes ->> 'category_id')" "row_id = '$P'")" \
  "create|Johnnie Walker 18|Ana Dueña|24000.00|Bebidas"
expect "la foto no trae id ni fechas" \
  "$(H "(changes ? 'id')::text || (changes ? 'created_at')::text || (changes ? 'business_id')::text" "row_id = '$P'")" "falsefalsefalse"
Q -c "$(ctx /menu_items $ADMIN) update public.menu_items set price = 26000, category_id = '$CAT_POS', updated_at = now() where id = '$P';" >/dev/null
expect "editar: antes → después, con nombres" \
  "$(H "action || '|' || actor_name || '|' || (changes -> 'price')::text || '|' || (changes -> 'category_id')::text || '|' || (changes ? 'updated_at')::text" "row_id = '$P'")" \
  'update|Luis Admin|[24000.00, 26000.00]|["Bebidas", "Postres"]|false'
Q -c "$(ctx /menu_items $ADMIN) update public.menu_items set position = 7, updated_at = now() where id = '$P';" >/dev/null
expect "mover de posición no es un cambio" "$(N "row_id = '$P'")" "2"
Q -c "$(ctx /rpc/fn_inventory_adjust $TABLET) update public.menu_items set is_active = false, auto_disabled = true where id = '$P';" >/dev/null
expect "el auto-86 (stock en cero) no se anota" "$(N "row_id = '$P'")" "2"
Q -c "$(ctx /menu_items $TABLET) update public.menu_items set is_active = true, auto_disabled = false where id = '$P';
      $(ctx /menu_items $TABLET) update public.menu_items set is_active = false where id = '$P';" >/dev/null
expect "apagar a mano (agotado) sí se anota" \
  "$(H "actor_name || '|' || (changes -> 'is_active')::text" "row_id = '$P'")" "Juan Pérez|[true, false]"
Q -c "$(ctx /menu_items $MAILONLY) update public.menu_items set image_url = 'a.png' where id = '$P';" >/dev/null
expect "imagen: no se copia, se anota; nombre por correo" \
  "$(H "actor_name || '|' || (changes -> 'image_url')::text" "row_id = '$P'")" 'sofia|[null, "imagen nueva"]'
Q -c "$(ctx '') update public.menu_items set price = 27000 where id = '$P';" >/dev/null
expect "sin usuario (Studio, cron) = Sistema" "$(H "actor_name || '|' || coalesce(source, '-')" "row_id = '$P'")" "Sistema|-"

echo "== Una transacción = el neto"
Q -c "begin; $(ctx /menu_items $OWNER) update public.menu_items set price = 28000 where id = '$P';
      update public.menu_items set price = 29000 where id = '$P'; commit;" >/dev/null
expect "dos ediciones seguidas = una con el primer antes" \
  "$(H "(changes -> 'price')::text" "row_id = '$P'")" "[27000.00, 29000.00]"
B=$(N "row_id = '$P'")
Q -c "begin; $(ctx /menu_items $OWNER) update public.menu_items set price = 1 where id = '$P';
      update public.menu_items set price = 29000 where id = '$P'; commit;" >/dev/null
expect "editar y deshacer en el mismo guardado = nada" "$(N "row_id = '$P'")" "$B"
Q -c "begin; $(ctx /menu_items $OWNER)
      insert into public.menu_items (business_id, name) values ('$BIZ', 'Fantasma');
      delete from public.menu_items where name = 'Fantasma'; commit;" >/dev/null
expect "y la fila de verdad se creó y se borró" "$(Q -At -c "select count(*) from public.menu_items where name = 'Fantasma'")" "0"
expect "crear y borrar en la misma transacción = nada" "$(N "label = 'Fantasma'")" "0"

echo "== Vínculos: impuestos de un producto"
Q -c "$(ctx /menu_item_taxes $OWNER) insert into public.menu_item_taxes values ('$P', '$TAX_ITBIS');" >/dev/null
expect "poner impuesto: producto + impuesto" \
  "$(H "action || '|' || label || '|' || context" "table_name = 'menu_item_taxes'")" "create|Johnnie Walker 18|ITBIS 18%"
B=$(N "table_name = 'menu_item_taxes'")
Q -c "begin; $(ctx /menu_item_taxes $OWNER) delete from public.menu_item_taxes where item_id = '$P';
      insert into public.menu_item_taxes values ('$P', '$TAX_ITBIS'), ('$P', '$TAX_LEY'); commit;" >/dev/null
expect "borrar todo y re-insertar: solo el que es nuevo" "$(N "table_name = 'menu_item_taxes'")" "$((B + 1))"
expect "el nuevo es la Ley 10%" "$(H "action || '|' || context" "table_name = 'menu_item_taxes'")" "create|Ley 10%"

echo "== Vínculos: permisos de un rol"
Q -c "$(ctx /rpc/fn_save_user_access_profile $OWNER) insert into public.role_permissions (role_id, permission_id, allow)
      values ('$ROLE_CAJ', '$PERM_DEL', true), ('$ROLE_CAJ', '$PERM_DISC', true);" >/dev/null
expect "dar permisos al rol" "$(N "table_name = 'role_permissions' and action = 'create'")" "2"
Q -c "begin; $(ctx /rpc/fn_save_user_access_profile $OWNER) delete from public.role_permissions where role_id = '$ROLE_CAJ';
      insert into public.role_permissions (role_id, permission_id, allow)
      values ('$ROLE_CAJ', '$PERM_DEL', false), ('$ROLE_CAJ', '$PERM_DISC', true); commit;" >/dev/null
expect "guardar el rol con un solo cambio = una edición" \
  "$(N "table_name = 'role_permissions' and action = 'update'")" "1"
expect "la edición: rol, permiso y Sí → No" \
  "$(H "label || '|' || context || '|' || (changes -> 'allow')::text" "table_name = 'role_permissions' and action = 'update'")" \
  "Cajero|Eliminar ítem|[true, false]"
Q -c "$(ctx /rpc/fn_seed_business_rbac_defaults $OWNER) insert into public.role_permissions (role_id, permission_id)
      values ('$ROLE_CAJ', '91000000-0000-0000-0000-0000000000ff');" >/dev/null
expect "las semillas no se anotan" "$(N "row_id like '%0000000000ff'")" "0"

echo "== Cascadas y triggers no se anotan"
Q -c "create function public.t_side() returns trigger language plpgsql as \$\$
      begin update public.categories set name = name || '!' where id = '$CAT_BEB'; return null; end \$\$;
      create trigger t_side after update on public.taxes for each row execute function public.t_side();" >/dev/null
Q -c "$(ctx /taxes $OWNER) update public.taxes set rate = 16 where id = '$TAX_ITBIS';" >/dev/null
expect "lo que cambió un trigger de otra tabla no se anota" "$(N "row_id = '$CAT_BEB'")" "0"
expect "pero el cambio de la persona sí" "$(H "(changes -> 'rate')::text" "row_id = '$TAX_ITBIS'")" "[18, 16]"
Q -c "drop trigger t_side on public.taxes;" >/dev/null
B=$(N "table_name = 'menu_item_taxes'")
Q -c "$(ctx /menu_items $OWNER) delete from public.menu_items where id = '$P';" >/dev/null
expect "borrar el producto: una sola línea con la foto" \
  "$(H "action || '|' || label || '|' || (changes ->> 'price')" "row_id = '$P'")" "delete|Johnnie Walker 18|29000.00"
expect "sus impuestos (cascada) no suman líneas" "$(N "table_name = 'menu_item_taxes'")" "$B"

echo "== Ruido que no cuenta"
Q -c "$(ctx /rpc/fn_close_table $TABLET) update public.dining_tables set state = 'occupied', pos_x = 3 where id = '$TBL';" >/dev/null
expect "estado y posición de la mesa no se anotan" "$(N "table_name = 'dining_tables'")" "0"
Q -c "$(ctx /dining_tables $OWNER) update public.dining_tables set label = 'Mesa 5 VIP' where id = '$TBL';" >/dev/null
expect "cambiar el nombre de la mesa sí; zona como contexto" \
  "$(H "label || '|' || context || '|' || (changes -> 'label')::text" "table_name = 'dining_tables'")" 'Mesa 5 VIP|Terraza|["Mesa 5", "Mesa 5 VIP"]'
NCF=$(Q -At -c "$(ctx /ncf_sequences $OWNER) insert into public.ncf_sequences (business_id, ncf_type, serie, prefix, range_end, current_number)
  values ('$BIZ', 'B02', 'B', 'B02', 500, 0) returning id;" | tail -1)
Q -c "$(ctx /rpc/create_fiscal_document $TABLET) update public.ncf_sequences set current_number = current_number + 1 where id = '$NCF';" >/dev/null
expect "cada factura (función) no se anota" "$(N "row_id = '$NCF'")" "1"
Q -c "$(ctx /ncf_sequences $OWNER) update public.ncf_sequences set current_number = 120 where id = '$NCF';" >/dev/null
expect "corregir el número a mano sí" "$(H "(changes -> 'current_number')::text" "row_id = '$NCF'")" "[1, 120]"
Q -c "$(ctx /rpc/fn_sales_note_create $TABLET) update public.business_settings set sales_note_count = 4, updated_at = now() where business_id = '$BIZ';" >/dev/null
expect "el contador de notas de venta no" "$(N "table_name = 'business_settings'")" "0"
Q -c "$(ctx /business_settings $OWNER) update public.business_settings set tip_enabled = false where business_id = '$BIZ';" >/dev/null
expect "la configuración sí" "$(H "(changes -> 'tip_enabled')::text" "table_name = 'business_settings'")" "[true, false]"
Q -c "$(ctx '') update public.businesses set plan = 'pro', status = 'locked' where id = '$BIZ';" >/dev/null
expect "suscripción del negocio (lista blanca) no" "$(N "table_name = 'businesses'")" "0"
Q -c "$(ctx /employees $OWNER) update public.employees set pin = 'hash1' where id = '$EMP_MARIA';" >/dev/null
expect "el PIN se tapa" "$(H "(changes -> 'pin')::text" "row_id = '$EMP_MARIA'")" '[null, "•••• (nuevo)"]'
Q -c "$(ctx /employees $OWNER) update public.employees set position = 'Bartender' where id = '$EMP_MARIA';" >/dev/null
expect "el puesto del empleado sí cuenta (position)" "$(H "(changes -> 'position')::text" "row_id = '$EMP_MARIA'")" '[null, "Bartender"]'

echo "== Recetas: el negocio sale del producto"
INV=$(Q -At -c "insert into public.inventory_items (business_id, name) values ('$BIZ', 'Ron blanco') returning id;" | tail -1)
MI=$(Q -At -c "insert into public.menu_items (business_id, name) values ('$BIZ', 'Mojito') returning id;" | tail -1)
R=$(Q -At -c "$(ctx /recipes $OWNER) insert into public.recipes (menu_item_id) values ('$MI') returning id;" | tail -1)
Q -c "$(ctx /recipe_ingredients $OWNER) insert into public.recipe_ingredients (recipe_id, inventory_item_id, quantity, unit)
      values ('$R', '$INV', 2, 'oz');" >/dev/null
expect "ingrediente: producto + insumo" \
  "$(H "business_id || '|' || label || '|' || context" "table_name = 'recipe_ingredients'")" "$BIZ|Mojito|Ron blanco"

echo "== Productos quitados de una cuenta"
mk_order() {
  Q -At -c "with s as (insert into public.table_sessions (id, business_id, table_id)
              values (gen_random_uuid(), '$BIZ', '$TBL') returning id)
            insert into public.orders (id, session_id, business_id, total)
            select gen_random_uuid(), s.id, '$BIZ', 1250 from s returning id;" | head -1
}
mk_item() { # orden, nombre, estado
  Q -At -c "insert into public.order_items (order_id, business_id, product_name, qty, quantity, unit_price, status, kitchen_sent_at)
            values ('$1', '$BIZ', '$2', 2, 2, 500, '$3', case when '$3' <> 'draft' then now() end) returning id;" | head -1
}
O=$(mk_order)
I=$(mk_item "$O" 'Don Julio Reposado' pending)
Q -c "$(ctx /order_items $TABLET) delete from public.order_items where id = '$I';" >/dev/null
expect "quitar lo enviado: se anota con la mesa" \
  "$(H "action || '|' || label || '|' || context || '|' || actor_name || '|' || (changes ->> 'amount')" "row_id = '$I'")" \
  "delete|Don Julio Reposado|Mesa 5 VIP|Juan Pérez|1000.00"
REM=$(Q -At -c "select id from public.order_item_removals where item_id = '$I'")
Q -c "update public.order_item_removals set reason = 'Cliente cambió de idea', reason_employee_id = '$EMP_MARIA' where id = '$REM';" >/dev/null
expect "el motivo y el PIN llegan después: misma línea" \
  "$(H "actor_name || '|' || (changes ->> 'reason')" "row_id = '$I'")" "María Gómez|Cliente cambió de idea"
expect "una sola línea por producto quitado" "$(N "row_id = '$I'")" "1"
I=$(mk_item "$O" 'Agua' draft)
Q -c "$(ctx /order_items $TABLET) delete from public.order_items where id = '$I';" >/dev/null
expect "lo no enviado (carrito) no se anota" "$(N "row_id = '$I'")" "0"

echo "== Anulaciones"
O=$(mk_order)
Q -c "$(ctx /orders $TABLET) update public.orders set status_ext = 'void' where id = '$O';" >/dev/null
expect "anular una mesa vacía no se anota" "$(N "row_id = '$O'")" "0"
O=$(mk_order)
I=$(mk_item "$O" 'Gold Label' pending)
FD=$(Q -At -c "insert into public.fiscal_documents (id, business_id, order_id, ncf_number) values (gen_random_uuid(), '$BIZ', '$O', 'B0200000123') returning id;" | head -1)
Q -c "insert into public.payments (business_id, order_id, fiscal_document_id, payment_method_id, amount) values ('$BIZ', '$O', '$FD', '$PM_CASH', 1250);" >/dev/null
Q -c "$(ctx /orders $OWNER) update public.orders set status_ext = 'void' where id = '$O';
      $(ctx /payments $OWNER) update public.payments set status = 'cancelled' where order_id = '$O';" >/dev/null
expect "anular una venta cobrada: mesa, NCF y lo cobrado" \
  "$(H "action || '|' || label || '|' || context || '|' || (changes ->> 'paid_total') || '|' || (changes ->> 'items_count')" "row_id = '$O'")" \
  "void|Mesa 5 VIP|B0200000123|1250|1"
expect "sus pagos no duplican la anulación" "$(N "table_name = 'payments'")" "0"
O=$(mk_order)
PAY=$(Q -At -c "insert into public.payments (business_id, order_id, payment_method_id, amount, reference) values ('$BIZ', '$O', '$PM_CASH', 600, 'R-1') returning id;" | head -1)
Q -c "$(ctx /payments $ADMIN) update public.payments set status = 'cancelled' where id = '$PAY';" >/dev/null
expect "anular un pago de una cuenta viva" \
  "$(H "action || '|' || label || '|' || context || '|' || (changes ->> 'amount') || '|' || actor_name" "row_id = '$PAY'")" \
  "void|Mesa 5 VIP|Efectivo|600|Luis Admin"

echo "== Importación grande (500 productos en un solo insert)"
T0=$(date +%s)
Q -c "$(ctx /menu_items $OWNER) insert into public.menu_items (business_id, category_id, name, price)
      select '$BIZ', '$CAT_POS', 'Importado ' || g, g from generate_series(1, 500) g;" >/dev/null
T1=$(date +%s)
expect "una línea por producto importado" "$(N "label like 'Importado %'")" "500"
echo "         (tardó $((T1 - T0)) s con historial)"

echo "== Nunca bloquea la venta"
Q -c "alter table public.change_history rename to change_history_x;" >/dev/null
run "si el historial falla, el cambio del usuario sigue" \
  -c "$(ctx /categories $OWNER) update public.categories set name = 'Bebidas frías' where id = '$CAT_BEB';"
expect "y quedó guardado" "$(Q -At -c "select name from public.categories where id = '$CAT_BEB'")" "Bebidas frías"
Q -c "alter table public.change_history_x rename to change_history;" >/dev/null

echo "== Quién lo ve (RLS)"
see() { Q -At -c "$(ctx /change_history $1) set role authenticated; select count(*) from public.change_history;" | tail -1; }
TOTAL=$(N)
expect "el dueño ve todo su negocio" "$(see $OWNER)" "$TOTAL"
expect "un administrador también" "$(see $ADMIN)" "$TOTAL"
expect "un cajero no ve nada" "$(see $CASHIER)" "0"
expect "el dueño de otro negocio no ve nada" "$(see $OWNER2)" "0"
if Q -c "$(ctx /change_history $OWNER) set role authenticated; delete from public.change_history;" >/dev/null 2>&1; then
  bad "el dueño pudo borrar el historial"
else ok "ni el dueño puede borrar el historial"; fi
if Q -c "$(ctx /change_history $OWNER) set role authenticated; update public.change_history set actor_name = 'x';" >/dev/null 2>&1; then
  bad "el dueño pudo editar el historial"
else ok "ni el dueño puede editarlo"; fi
if Q -c "$(ctx /change_history $OWNER) set role authenticated;
         insert into public.change_history (business_id, table_name, row_id, action) values ('$BIZ', 'x', 'x', 'create');" >/dev/null 2>&1; then
  bad "el dueño pudo inventar una línea"
else ok "ni inventar líneas"; fi

echo "== Reversa"
run "ROLLBACK" -f "$M/20261013_0001_change_history_ROLLBACK.sql"
expect "sin tabla" "$(Q -At -c "select to_regclass('public.change_history') is null")" "t"
expect "sin triggers" "$(Q -At -c "select count(*) from pg_trigger where tgname like 'trg_zz_change_history%'")" "0"
expect "order_item_removals intacta" "$(Q -At -c "select count(*) > 0 from public.order_item_removals")" "t"
run "re-aplicar después de la reversa" -f "$M/20261013_0001_change_history.sql"

echo
if [[ $FAIL -eq 0 ]]; then echo "TODO OK"; else echo "HAY FALLAS"; fi
exit $FAIL
