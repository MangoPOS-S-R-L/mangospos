#!/usr/bin/env bash
# =============================================================================
# Prueba LOCAL de las tarjetas de sellos (20260930_0053).
# Postgres 15 DESECHABLE; corre el archivo REAL del repo sobre un esquema
# mínimo (solo las columnas que la migración lee). No toca ninguna base.
#
#   bash supabase/tests/loyalty_stamp_cards_local_test.sh [carpeta_trabajo]
# Variables: PG_BIN (default homebrew postgresql@15), PG_PORT (default 55453).
# =============================================================================
set -u
REPO=$(cd "$(dirname "$0")/../.." && pwd)
M=$REPO/supabase/migrations
PG=${PG_BIN:-/opt/homebrew/opt/postgresql@15/bin}
PORT=${PG_PORT:-55453}
WORK=${1:-$(mktemp -d)}
D=$WORK/pg_loyalty
rm -rf "$D"; mkdir -p "$D"
"$PG/initdb" -D "$D/data" -U postgres --auth=trust >/dev/null || exit 1
"$PG/pg_ctl" -D "$D/data" -o "-p $PORT -c listen_addresses=127.0.0.1 -c unix_socket_directories=''" \
  -l "$D/log" start -w >/dev/null || { cat "$D/log"; exit 1; }
trap '"$PG/pg_ctl" -D "$D/data" stop -m fast >/dev/null 2>&1' EXIT
Q() { "$PG/psql" -h 127.0.0.1 -p "$PORT" -U postgres -X -q -v ON_ERROR_STOP=1 "$@"; }
FAIL=0
ok()  { echo "  ok     $1"; }
bad() { echo "  FALLA  $1"; FAIL=1; }

B1=b0000000-0000-0000-0000-000000000001
B2=b0000000-0000-0000-0000-000000000002
U1=a0000000-0000-0000-0000-000000000001   # dueño
U2=a0000000-0000-0000-0000-000000000002   # cajero
U3=a0000000-0000-0000-0000-000000000003   # ajeno
C1=c0000000-0000-0000-0000-000000000001   # Juan
C2=c0000000-0000-0000-0000-000000000002   # Pedro
CX=c0000000-0000-0000-0000-00000000000f   # cliente de otro negocio
CAT_CAFE=ca000000-0000-0000-0000-000000000001
CAT_PIZZA=ca000000-0000-0000-0000-000000000002
ESP=d0000000-0000-0000-0000-000000000001   # espresso 100
LAT=d0000000-0000-0000-0000-000000000002   # latte 150
PIZ=d0000000-0000-0000-0000-000000000003   # pizza 500
AGUA=d0000000-0000-0000-0000-000000000004
OTRO=d0000000-0000-0000-0000-00000000000f  # producto de otro negocio
TBL=e0000000-0000-0000-0000-000000000001

echo "== Esquema mínimo"
Q <<SQL || { bad "esquema"; exit 1; }
create role authenticated; create role anon; create role service_role;
create schema auth;
create function auth.uid() returns uuid language sql stable as \$\$
  select nullif(current_setting('test.uid', true), '')::uuid
\$\$;
grant usage on schema public, auth to anon, authenticated;
grant execute on function auth.uid() to authenticated, anon;
create type public.item_status as enum ('pending','preparing','ready','served','void','draft','paid');
create type public.order_status as enum ('open','sent_to_kitchen','partially_paid','paid','void');

create table public.businesses (id uuid primary key, owner_id uuid);
create table public.user_businesses (user_id uuid, business_id uuid, role text);
create table public.customers (id uuid primary key, business_id uuid not null, name text);
create table public.categories (id uuid primary key, business_id uuid not null, name text);
create table public.menu_items (id uuid primary key, business_id uuid not null,
  category_id uuid, name text);
create table public.zones (id uuid primary key, business_id uuid not null);
create table public.dining_tables (id uuid primary key, zone_id uuid not null);
create table public.table_sessions (id uuid primary key default gen_random_uuid(),
  table_id uuid, business_id uuid, customer_id uuid, closed_at timestamptz);
create table public.orders (id uuid primary key default gen_random_uuid(),
  session_id uuid not null, status_ext public.order_status default 'open',
  closed_at timestamptz, total numeric default 0);
create table public.order_checks (id uuid primary key default gen_random_uuid(),
  order_id uuid, is_closed boolean default false, customer_id uuid,
  total numeric default 0);
create table public.order_items (id uuid primary key default gen_random_uuid(),
  order_id uuid not null, check_id uuid, product_id uuid,
  status public.item_status default 'pending',
  qty numeric(12,5), quantity numeric(12,5),
  subtotal numeric default 0, tax numeric default 0, discounts numeric default 0,
  total numeric default 0, notes text, created_at timestamptz default now());
create table public.payments (id uuid primary key default gen_random_uuid(),
  order_id uuid, check_id uuid, amount numeric, status text default 'completed');

-- total de la línea: el trigger real (fn_compute_item_totals) resta el
-- descuento UNA vez del gross.
create function public.t_item_total() returns trigger language plpgsql as \$\$
begin new.total := new.subtotal + new.tax - new.discounts; return new; end \$\$;
create trigger t_item_total before insert or update on public.order_items
  for each row execute function public.t_item_total();

create function public.calculate_order_totals(p uuid) returns void language sql as \$\$
  update public.orders set total = coalesce((select sum(total) from public.order_items
   where order_id = p and status not in ('paid','void')), 0) where id = p
\$\$;
create function public.calculate_check_totals(p uuid) returns void language sql as \$\$
  update public.order_checks set total = coalesce((select sum(total) from public.order_items
   where check_id = p and status not in ('paid','void')), 0) where id = p
\$\$;
create function public.trigger_set_updated_at() returns trigger language plpgsql as \$\$
begin new.updated_at := now(); return new; end \$\$;
-- Igual que en la base real: SECURITY DEFINER (las policies las llaman
-- como authenticated y user_businesses tiene su propio RLS).
create function public.user_business_role(_user_id uuid, _business_id uuid) returns text
language sql stable security definer as \$\$
  select coalesce(
    (select role from public.user_businesses where user_id = _user_id and business_id = _business_id),
    (select 'owner' from public.businesses where id = _business_id and owner_id = _user_id))
\$\$;
create function public.user_has_business_access(_user_id uuid, _business_id uuid) returns boolean
language sql stable security definer as \$\$
  select exists (select 1 from public.user_businesses where user_id = _user_id and business_id = _business_id)
      or exists (select 1 from public.businesses where id = _business_id and owner_id = _user_id)
\$\$;
create function public.user_has_business_permission(p_business uuid, p_code text) returns boolean
language sql stable as \$\$
  select coalesce(current_setting('test.perm', true), '') = p_code
\$\$;

insert into public.businesses values ('$B1', '$U1'), ('$B2', '$U3');
insert into public.user_businesses values ('$U2', '$B1', 'cashier');
insert into public.customers values ('$C1','$B1','Juan'), ('$C2','$B1','Pedro'), ('$CX','$B2','Otro');
insert into public.categories values ('$CAT_CAFE','$B1','Café'), ('$CAT_PIZZA','$B1','Pizza');
insert into public.menu_items values
  ('$ESP','$B1','$CAT_CAFE','Espresso'), ('$LAT','$B1','$CAT_CAFE','Latte'),
  ('$PIZ','$B1','$CAT_PIZZA','Pizza'), ('$AGUA','$B1',null,'Agua'),
  ('$OTRO','$B2',null,'Ajeno');
insert into public.zones values ('f0000000-0000-0000-0000-000000000001', '$B1');
insert into public.dining_tables values ('$TBL', 'f0000000-0000-0000-0000-000000000001');

-- Arma una orden con UNA línea. p_paid: cobra y cierra como lo hace
-- fn_process_payment_v3 (ítems 'paid' + pago completed + orden/cuenta cerrada).
create function public.t_order(p_session_customer uuid, p_check_customer uuid,
  p_product uuid, p_qty numeric, p_unit numeric, p_paid boolean,
  p_notes text default null, p_discount numeric default 0,
  p_created timestamptz default now()) returns uuid language plpgsql as \$\$
declare s uuid; o uuid; c uuid; i uuid;
begin
  insert into public.table_sessions(table_id, business_id, customer_id)
    values ('$TBL', '$B1', p_session_customer) returning id into s;
  insert into public.orders(session_id) values (s) returning id into o;
  insert into public.order_checks(order_id, customer_id) values (o, p_check_customer) returning id into c;
  insert into public.order_items(order_id, check_id, product_id, qty, quantity,
    subtotal, tax, discounts, notes, created_at)
  values (o, c, p_product, p_qty, p_qty, round(p_qty*p_unit/1.18, 2),
    round(p_qty*p_unit - p_qty*p_unit/1.18, 2), p_discount, p_notes, p_created)
  returning id into i;
  if p_paid then
    update public.order_items set status = 'paid' where order_id = o;
    insert into public.payments(order_id, amount) values (o, p_qty*p_unit);
    update public.order_checks set is_closed = true where order_id = o;
    update public.orders set status_ext = 'paid', closed_at = now() where id = o;
  end if;
  return i;
end \$\$;
SQL

echo "== Migración real"
if Q -f "$M/20260930_0053_loyalty_stamp_cards.sql" >/dev/null 2>&1; then ok "migración aplica"
else Q -f "$M/20260930_0053_loyalty_stamp_cards.sql"; bad "migración"; exit 1; fi
Q -f "$M/20260930_0053_loyalty_stamp_cards.sql" >/dev/null 2>&1 && ok "migración re-ejecutable" || bad "migración re-ejecutable"

# as <uid> [perm] -- sql
as_user() { local uid=$1 perm=$2; shift 2
  Q -At -c "set role authenticated; set test.uid = '$uid'; set test.perm = '$perm'; $*"; }
card() { # uid customer program_name field
  as_user "$1" "" "select coalesce((select e->>'$4' from jsonb_array_elements(public.fn_loyalty_customer_cards('$2')) e where e->>'name' = '$3'), 'none')"; }
expect() { # descripción valor_esperado valor
  [ "$3" = "$2" ] && ok "$1" || bad "$1 (esperado $2, salió $3)"; }
expect_err() { # descripción código comando...
  local desc=$1 code=$2; shift 2
  local out; out=$("$@" 2>&1) && { bad "$desc (no falló)"; return; }
  echo "$out" | grep -q "$code" && ok "$desc" || bad "$desc: $out"; }

echo "== Programas (RLS y validación)"
expect_err "cajero sin permiso NO crea programas" "row-level security" \
  as_user $U2 "" "insert into public.loyalty_stamp_programs(business_id,name,target_ids,stamps_required) values ('$B1','X','{$ESP}',10)"
expect_err "producto de otro negocio: LOYALTY_TARGETS_INVALID" LOYALTY_TARGETS_INVALID \
  as_user $U1 "" "insert into public.loyalty_stamp_programs(business_id,name,target_ids,stamps_required) values ('$B1','X','{$OTRO}',10)"
expect_err "10 sellos mínimo 2: 1 no vale" loyalty_stamp_programs_stamps_chk \
  as_user $U1 "" "insert into public.loyalty_stamp_programs(business_id,name,target_ids,stamps_required) values ('$B1','X','{$ESP}',1)"
P1=$(as_user $U1 "" "insert into public.loyalty_stamp_programs(business_id,name,target_ids,stamps_required,count_mode,starts_at) values ('$B1','Tarjeta Café','{$ESP,$LAT}',10,'unit', now() - interval '1 day') returning id" | head -1)
[ -n "$P1" ] && ok "dueño crea «Tarjeta Café» (10 sellos por UNIDAD, espresso+latte)" || bad "crear P1"
P2=$(as_user $U2 "settings.descuentos_propinas.gestionar" "insert into public.loyalty_stamp_programs(business_id,name,target_scope,target_ids,stamps_required,count_mode,starts_at) values ('$B1','Tarjeta Pizza','category','{$CAT_PIZZA}',5,'unit', now() - interval '1 day') returning id" | head -1)
[ -n "$P2" ] && ok "cajero CON permiso crea «Tarjeta Pizza» (5 sellos, por categoría)" || bad "crear P2"
expect_err "modo de conteo inválido" loyalty_stamp_programs_count_mode_chk \
  as_user $U1 "" "insert into public.loyalty_stamp_programs(business_id,name,target_ids,stamps_required,count_mode) values ('$B1','X','{$ESP}',5,'dia')"
expect "el cajero ve los programas" 2 "$(as_user $U2 "" "select count(*) from public.loyalty_stamp_programs")"
expect "el ajeno no ve nada" 0 "$(as_user $U3 "" "select count(*) from public.loyalty_stamp_programs")"

echo "== Sellos ganados"
Q -c "select public.t_order('$C1', null, '$ESP', 3, 100, true)" >/dev/null
expect "3 espressos cobrados (cliente de la mesa) = 3 sellos" 3 "$(card $U2 $C1 'Tarjeta Café' balance)"
# Cuenta dividida: C1 en la subcuenta con 4 lattes; el KDS pisó el 'paid'.
I=$(Q -At -c "select public.t_order(null, '$C1', '$LAT', 4, 150, true)")
Q -c "update public.order_items set status = 'served' where id = '$I'"
expect "subcuenta cerrada cuenta aunque el KDS pisara el 'paid' (3+4)" 7 "$(card $U2 $C1 'Tarjeta Café' balance)"
Q -c "select public.t_order('$C1', '$C2', '$ESP', 2, 100, true)" >/dev/null
expect "subcuenta de Pedro en mesa de Juan: los sellos son de Pedro" 2 "$(card $U2 $C2 'Tarjeta Café' balance)"
expect "... y Juan sigue igual" 7 "$(card $U2 $C1 'Tarjeta Café' balance)"
Q -c "select public.t_order('$C1', null, '$ESP', 5, 100, false)" >/dev/null
expect "cuenta abierta sin cobrar no suma" 7 "$(card $U2 $C1 'Tarjeta Café' balance)"
I=$(Q -At -c "select public.t_order('$C1', null, '$ESP', 5, 100, true)")
Q -c "update public.order_items set status='void' where id='$I'; update public.payments set status='cancelled' where order_id=(select order_id from public.order_items where id='$I')" >/dev/null
expect "venta anulada (ítems void) no suma" 7 "$(card $U2 $C1 'Tarjeta Café' balance)"
I=$(Q -At -c "select public.t_order('$C1', null, '$ESP', 5, 100, true)")
Q -c "update public.order_items set status='served' where id='$I';
      update public.order_checks set is_closed=false where id=(select check_id from public.order_items where id='$I');
      update public.payments set status='cancelled' where order_id=(select order_id from public.order_items where id='$I')" >/dev/null
expect "anulación por subcuenta (served + reabierta) no suma" 7 "$(card $U2 $C1 'Tarjeta Café' balance)"
I=$(Q -At -c "select public.t_order('$C1', null, '$ESP', 4, 100, true)")
Q -c "update public.orders set status_ext='void' where id=(select order_id from public.order_items where id='$I')" >/dev/null
expect "orden cerrada como void (replay offline) no suma" 7 "$(card $U2 $C1 'Tarjeta Café' balance)"
Q -c "select public.t_order('$C1', null, '$ESP', 1, 100, true, '[CORTESIA:cumple]', 100)" >/dev/null
expect "cortesía (línea regalada) no suma" 7 "$(card $U2 $C1 'Tarjeta Café' balance)"
Q -c "select public.t_order('$C1', null, '$ESP', 1, 100, true, '[PROMO_AUTO:x]', 100)" >/dev/null
expect "unidad gratis de un 2x1 en línea aparte no suma" 7 "$(card $U2 $C1 'Tarjeta Café' balance)"
Q -c "select public.t_order('$C1', null, '$ESP', 6, 100, true, null, 0, now() - interval '3 days')" >/dev/null
expect "compras de antes del inicio del programa no suman" 7 "$(card $U2 $C1 'Tarjeta Café' balance)"
Q -c "select public.t_order('$C1', null, '$AGUA', 9, 50, true)" >/dev/null
expect "producto fuera del programa no suma" 7 "$(card $U2 $C1 'Tarjeta Café' balance)"
Q -c "select public.t_order('$C1', null, '$ESP', 1, 100, true, 'sin azucar [LOYALTY:------------------------------------]')" >/dev/null
expect "nota con texto raro no rompe el cálculo (y suma su café)" 8 "$(card $U2 $C1 'Tarjeta Café' balance)"
expect "tarjeta por categoría: sin pizzas, 0" 0 "$(card $U2 $C1 'Tarjeta Pizza' balance)"
expect "la tarjeta trae los productos que suman" 2 "$(as_user $U2 "" "select jsonb_array_length(e->'eligible_product_ids') from jsonb_array_elements(public.fn_loyalty_customer_cards('$C1')) e where e->>'name'='Tarjeta Café'")"
expect_err "el ajeno no puede leer la tarjeta" LOYALTY_ACCESS_DENIED card $U3 $C1 'Tarjeta Café' balance

echo "== Ajuste manual (cargar la tarjeta física)"
expect_err "cajero sin permiso no ajusta" LOYALTY_ADJUST_DENIED \
  as_user $U2 "" "select public.fn_loyalty_adjust_stamps('$P1','$C1',2,'tarjeta fisica')"
expect_err "motivo obligatorio" LOYALTY_REASON_REQUIRED \
  as_user $U1 "" "select public.fn_loyalty_adjust_stamps('$P1','$C1',2,' ')"
expect_err "no se puede dejar en negativo" NOT_ENOUGH_STAMPS \
  as_user $U1 "" "select public.fn_loyalty_adjust_stamps('$P1','$C1',-9,'error')"
as_user $U2 "clientes.crear_editar" "select public.fn_loyalty_adjust_stamps('$P1','$C1',2,'tarjeta fisica con 2 marcas')" >/dev/null \
  && ok "cajero con clientes.crear_editar carga 2 sellos" || bad "ajuste con permiso"
expect "8 + 2 = 10 sellos" 10 "$(card $U2 $C1 'Tarjeta Café' balance)"
expect "10 de 10 → 1 premio disponible" 1 "$(card $U2 $C1 'Tarjeta Café' available_rewards)"
expect "el progreso de la tarjeta vuelve a 0" 0 "$(card $U2 $C1 'Tarjeta Café' progress)"
expect_err "cliente de otro negocio" CUSTOMER_NOT_FOUND \
  as_user $U1 "" "select public.fn_loyalty_adjust_stamps('$P1','$CX',2,'tarjeta')"

echo "== Canje"
IO=$(Q -At -c "select public.t_order('$C1', null, '$ESP', 2, 100, false, 'poco hielo')")
IP=$(Q -At -c "select public.t_order('$C2', null, '$ESP', 1, 100, false)")
IA=$(Q -At -c "select public.t_order('$C1', null, '$AGUA', 1, 50, false)")
expect_err "el ajeno no canjea" LOYALTY_ACCESS_DENIED \
  as_user $U3 "" "select public.fn_loyalty_redeem_reward('$P1','$C1','$IO',1)"
expect_err "línea de otro cliente" ITEM_NOT_FOR_CUSTOMER \
  as_user $U2 "" "select public.fn_loyalty_redeem_reward('$P1','$C1','$IP',1)"
expect_err "producto fuera del programa" ITEM_NOT_IN_PROGRAM \
  as_user $U2 "" "select public.fn_loyalty_redeem_reward('$P1','$C1','$IA',1)"
expect_err "más unidades gratis que las de la línea" LOYALTY_INVALID_UNITS \
  as_user $U2 "" "select public.fn_loyalty_redeem_reward('$P1','$C1','$IO',3)"
expect_err "2 premios con sellos para 1" NOT_ENOUGH_STAMPS \
  as_user $U2 "" "select public.fn_loyalty_redeem_reward('$P1','$C1','$IO',2)"
R=$(as_user $U2 "" "select public.fn_loyalty_redeem_reward('$P1','$C1','$IO',1)")
echo "$R" | grep -q '"discount": 100.00' && ok "canje: 1 espresso gratis de 2 (descuento 100.00)" || bad "canje: $R"
expect "la línea queda con descuento 100 y total 100" "100.00|100.00" \
  "$(Q -At -c "select round(discounts,2)||'|'||round(total,2) from public.order_items where id='$IO'")"
expect "la nota del cajero se conserva y lleva el marcador" 1 \
  "$(Q -At -c "select count(*) from public.order_items where id='$IO' and notes like 'poco hielo'||chr(10)||'[LOYALTY:%:1]'")"
expect "el total de la orden se recalculó" 100 \
  "$(Q -At -c "select round(total) from public.orders where id=(select order_id from public.order_items where id='$IO')")"
expect "premio puesto en cuenta abierta = sellos reservados" 10 "$(card $U2 $C1 'Tarjeta Café' reserved)"
expect "... y ya no hay premio disponible" 0 "$(card $U2 $C1 'Tarjeta Café' available_rewards)"
expect_err "no se canjea dos veces sobre la misma línea" ITEM_ALREADY_DISCOUNTED \
  as_user $U2 "" "select public.fn_loyalty_redeem_reward('$P1','$C1','$IO',1)"
IO2=$(Q -At -c "select public.t_order('$C1', null, '$LAT', 1, 150, false)")
expect_err "otra línea sin sellos suficientes" NOT_ENOUGH_STAMPS \
  as_user $U2 "" "select public.fn_loyalty_redeem_reward('$P1','$C1','$IO2',1)"

echo "== Quitar el premio"
R=$(as_user $U2 "" "select public.fn_loyalty_cancel_reward('$IO')")
echo "$R" | grep -q '"stamps_returned": 10' && ok "quitar premio devuelve 10 sellos" || bad "cancel: $R"
expect "la línea vuelve a su precio y a su nota" "0.00|200.00|poco hielo" \
  "$(Q -At -c "select round(discounts,2)||'|'||round(total,2)||'|'||notes from public.order_items where id='$IO'")"
expect "el premio vuelve a estar disponible" 1 "$(card $U2 $C1 'Tarjeta Café' available_rewards)"
expect_err "quitar premio donde no hay" NO_LOYALTY_REWARD \
  as_user $U2 "" "select public.fn_loyalty_cancel_reward('$IO')"

echo "== Marcador reemplazado por otro descuento"
as_user $U2 "" "select public.fn_loyalty_redeem_reward('$P1','$C1','$IO2',1)" >/dev/null && ok "canje en el latte" || bad "canje latte"
Q -c "update public.order_items set discounts = 150, notes = '[CORTESIA:gerente]' where id='$IO2'" >/dev/null
expect "una cortesía encima quita el premio: los sellos vuelven" 1 "$(card $U2 $C1 'Tarjeta Café' available_rewards)"
Q -c "update public.order_items set status='void' where id='$IO2'" >/dev/null

echo "== Cobrar la cuenta con el premio"
as_user $U2 "" "select public.fn_loyalty_redeem_reward('$P1','$C1','$IO',1)" >/dev/null && ok "canje de nuevo" || bad "re-canje"
Q -c "update public.order_items set status='paid' where id='$IO';
      insert into public.payments(order_id, amount) select order_id, 100 from public.order_items where id='$IO';
      update public.order_checks set is_closed=true where id=(select check_id from public.order_items where id='$IO');
      update public.orders set status_ext='paid', closed_at=now() where id=(select order_id from public.order_items where id='$IO')" >/dev/null
expect "premio cobrado = sellos canjeados" 10 "$(card $U2 $C1 'Tarjeta Café' redeemed)"
expect "nada reservado" 0 "$(card $U2 $C1 'Tarjeta Café' reserved)"
expect "el café pagado de esa línea suma, el regalado no (8+1 compras)" 9 "$(card $U2 $C1 'Tarjeta Café' earned)"
expect "saldo: 9 compras + 2 ajuste − 10 canjeados = 1" 1 "$(card $U2 $C1 'Tarjeta Café' balance)"
expect_err "ya cobrada: no se quita el premio" ITEM_NOT_OPEN \
  as_user $U2 "" "select public.fn_loyalty_cancel_reward('$IO')"
Q -c "update public.order_items set status='void' where id='$IO';
      update public.payments set status='cancelled' where order_id=(select order_id from public.order_items where id='$IO')" >/dev/null
expect "si se anula esa venta, el premio y su compra se revierten (8+2)" 10 "$(card $U2 $C1 'Tarjeta Café' balance)"

echo "== Tarjeta por categoría"
for n in 1 2 3; do Q -c "select public.t_order('$C1', null, '$PIZ', 1, 500, true)" >/dev/null; done
Q -c "select public.t_order('$C1', null, '$PIZ', 2, 500, true)" >/dev/null
expect "5 pizzas (categoría Pizza) = 1 pizza gratis" 1 "$(card $U2 $C1 'Tarjeta Pizza' available_rewards)"

echo "== Por COMPRA (cartón de The Pizza Hot Villa Tapia: 5 marcas, la 6ª gratis)"
P3=$(as_user $U1 "" "insert into public.loyalty_stamp_programs(business_id,name,target_scope,target_ids,stamps_required,starts_at) values ('$B1','Tarjeta Villa Tapia','category','{$CAT_PIZZA}',5, now() - interval '1 day') returning id" | head -1)
[ -n "$P3" ] && ok "sin decir modo, la tarjeta cuenta por compra" || bad "crear P3"
expect "la tarjeta dice su modo" visit "$(card $U2 $C2 'Tarjeta Villa Tapia' count_mode)"
Q -c "select public.t_order('$C2', null, '$PIZ', 3, 500, true)" >/dev/null
expect "una compra con 3 pizzas = 1 marca" 1 "$(card $U2 $C2 'Tarjeta Villa Tapia' balance)"
Q -c "select public.t_order('$C2', null, '$ESP', 2, 100, true)" >/dev/null
expect "compra sin pizzas no marca" 1 "$(card $U2 $C2 'Tarjeta Villa Tapia' balance)"
Q -c "select public.t_order('$C2', null, '$PIZ', 1, 500, false)" >/dev/null
expect "compra sin cobrar no marca" 1 "$(card $U2 $C2 'Tarjeta Villa Tapia' balance)"
for n in 1 2 3 4; do Q -c "select public.t_order('$C2', null, '$PIZ', 1, 500, true)" >/dev/null; done
expect "5 compras = 5 marcas" 5 "$(card $U2 $C2 'Tarjeta Villa Tapia' balance)"
expect "... y la 6ª va gratis" 1 "$(card $U2 $C2 'Tarjeta Villa Tapia' available_rewards)"
R1=$(Q -At -c "select public.t_order('$C2', null, '$PIZ', 1, 500, false)")
as_user $U2 "" "select public.fn_loyalty_redeem_reward('$P3','$C2','$R1',1)" >/dev/null && ok "canje de la 6ª" || bad "canje P3"
expect "la pizza gratis completa (500)" "500.00" "$(Q -At -c "select round(discounts,2) from public.order_items where id='$R1'")"
Q -c "update public.order_items set status='paid' where id='$R1';
      insert into public.payments(order_id, amount) select order_id, 0 from public.order_items where id='$R1';
      update public.order_checks set is_closed=true where id=(select check_id from public.order_items where id='$R1');
      update public.orders set status_ext='paid', closed_at=now() where id=(select order_id from public.order_items where id='$R1')" >/dev/null
expect "la visita en que solo se llevó la gratis NO marca (tarjeta nueva en 0)" 0 "$(card $U2 $C2 'Tarjeta Villa Tapia' balance)"
expect "compras que cuentan: siguen siendo 5" 5 "$(card $U2 $C2 'Tarjeta Villa Tapia' earned)"
as_user $U1 "" "select public.fn_loyalty_adjust_stamps('$P3','$C2',5,'carton fisico lleno')" >/dev/null && ok "se carga un cartón lleno (5)" || bad "ajuste P3"
R2=$(Q -At -c "select public.t_order('$C2', null, '$PIZ', 2, 500, false)")
as_user $U2 "" "select public.fn_loyalty_redeem_reward('$P3','$C2','$R2',1)" >/dev/null && ok "canje en una compra de 2 pizzas" || bad "canje P3 #2"
Q -c "update public.order_items set status='paid' where id='$R2';
      insert into public.payments(order_id, amount) select order_id, 500 from public.order_items where id='$R2';
      update public.order_checks set is_closed=true where id=(select check_id from public.order_items where id='$R2');
      update public.orders set status_ext='paid', closed_at=now() where id=(select order_id from public.order_items where id='$R2')" >/dev/null
expect "la gratis + una pagada: esa compra SÍ marca (1)" 1 "$(card $U2 $C2 'Tarjeta Villa Tapia' balance)"

echo "== Programa desactivado"
as_user $U1 "" "update public.loyalty_stamp_programs set is_active=false where id='$P2'" >/dev/null
expect "no aparece en la tarjeta del cliente" none "$(card $U2 $C1 'Tarjeta Pizza' balance)"
IZ=$(Q -At -c "select public.t_order('$C1', null, '$PIZ', 1, 500, false)")
expect_err "no se canjea" LOYALTY_PROGRAM_NOT_FOUND \
  as_user $U2 "" "select public.fn_loyalty_redeem_reward('$P2','$C1','$IZ',1)"

echo "== Dos cajas canjeando a la vez (hay sellos para UN premio)"
expect "punto de partida: 1 premio" 1 "$(card $U2 $C1 'Tarjeta Café' available_rewards)"
IA1=$(Q -At -c "select public.t_order('$C1', null, '$ESP', 1, 100, false)")
IA2=$(Q -At -c "select public.t_order('$C1', null, '$ESP', 1, 100, false)")
( as_user $U2 "" "begin; select public.fn_loyalty_redeem_reward('$P1','$C1','$IA1',1); select pg_sleep(2); commit;" >/dev/null 2>&1 ) &
sleep 0.7
expect_err "la 2da caja espera a la 1ra y no gasta los mismos sellos" NOT_ENOUGH_STAMPS \
  as_user $U2 "" "select public.fn_loyalty_redeem_reward('$P1','$C1','$IA2',1)"
wait
expect "quedó un solo premio reservado" 10 "$(card $U2 $C1 'Tarjeta Café' reserved)"

echo "== Rollback"
Q -f "$M/20260930_0053_loyalty_stamp_cards_ROLLBACK.sql" >/dev/null 2>&1 \
  && [ "$(Q -At -c "select count(*) from pg_proc where proname like 'fn_loyalty%'")" = "0" ] \
  && ok "rollback limpia todo" || bad "rollback"

echo
[ $FAIL -eq 0 ] && echo "TODO OK" || echo "HAY FALLAS"
exit $FAIL
