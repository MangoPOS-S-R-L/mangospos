#!/usr/bin/env bash
# =============================================================================
# Prueba LOCAL del alta de ítem idempotente (20260929_0001).
# Postgres 15 DESECHABLE con el esquema mínimo; corre el archivo REAL del repo.
# fn_add_item_from_menu es un stub (la viva no se toca): solo importa que el
# wrapper garantice UN efecto por client_op_id. No toca ninguna base real.
#
#   bash supabase/tests/add_item_idempotent_local_test.sh [carpeta_trabajo]
# Variables: PG_BIN (default homebrew postgresql@15), PG_PORT (default 55447).
# =============================================================================
set -u
REPO=$(cd "$(dirname "$0")/../.." && pwd)
M=$REPO/supabase/migrations
PG=${PG_BIN:-/opt/homebrew/opt/postgresql@15/bin}
PORT=${PG_PORT:-55447}
WORK=${1:-$(mktemp -d)}
D=$WORK/pg_add_item_idem
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
  else echo "$OUT" | grep -E "ERROR" | sed 's/^psql:[^:]*:[0-9]*: //'; bad "$label"; fi
}

ORDER=11111111-1111-1111-1111-111111111111
ORDER2=22222222-2222-2222-2222-222222222222
CLOSED=33333333-3333-3333-3333-333333333333
MENU=44444444-4444-4444-4444-444444444444
EMP=55555555-5555-5555-5555-555555555555

echo "== Esquema mínimo + stub de fn_add_item_from_menu"
Q <<SQL || { bad "esquema"; exit 1; }
create role authenticated; create role anon; create role service_role;
create schema auth;
create function auth.role() returns text language sql stable as \$\$
  select coalesce(current_setting('test.jwt_role', true), 'authenticated')
\$\$;
create function public.is_member_of_business(p_business uuid) returns boolean
language sql stable as \$\$
  select coalesce(current_setting('test.authorized', true), 'on') = 'on'
\$\$;
-- Como Supabase: todo objeto nuevo del esquema public nace con permisos para
-- anon/authenticated; la migración tiene que revocarlos explícitamente.
alter default privileges in schema public grant all on tables to anon, authenticated;
alter default privileges in schema public grant execute on functions to anon, authenticated;
grant usage on schema public to anon, authenticated;
create table public.menu_items (id uuid primary key, name text, price numeric);
create table public.zones (id uuid primary key, business_id uuid not null);
create table public.dining_tables (id uuid primary key, zone_id uuid not null);
create table public.table_sessions (id uuid primary key, business_id uuid, table_id uuid);
create table public.orders (id uuid primary key, session_id uuid not null,
  closed_at timestamptz);
create table public.order_items (
  id uuid primary key default gen_random_uuid(),
  order_id uuid not null, product_id uuid, product_name text,
  qty numeric default 1, notes text, created_by_employee_id uuid,
  created_at timestamptz default now());
insert into public.menu_items values ('$MENU', 'Presidente', 250);
insert into public.table_sessions (id,business_id) values
  ('eeeeeeee-0000-0000-0000-000000000001','ffffffff-0000-0000-0000-000000000001');
insert into public.orders values
  ('$ORDER','eeeeeeee-0000-0000-0000-000000000001',null),
  ('$ORDER2','eeeeeeee-0000-0000-0000-000000000001',null),
  ('$CLOSED','eeeeeeee-0000-0000-0000-000000000001',now());

-- Misma firma que la viva. 'sleep' alarga la transacción para la prueba de
-- concurrencia; 'boom' simula un fallo DESPUÉS del INSERT.
create function public.fn_add_item_from_menu(
  p_order_id uuid, p_menu_item_id uuid, p_qty numeric default 1,
  p_check_position integer default 1, p_is_takeout boolean default false,
  p_notes text default null) returns uuid
language plpgsql security definer set search_path to 'public' as \$\$
declare v_id uuid;
begin
  if exists (select 1 from orders where id = p_order_id and closed_at is not null) then
    raise exception 'MP401: cuenta ya cobrada' using errcode = 'MP401';
  end if;
  insert into order_items(order_id, product_id, product_name, qty, notes)
  select p_order_id, id, name, p_qty, p_notes from menu_items where id = p_menu_item_id
  returning id into v_id;
  if v_id is null then raise exception 'MENU_ITEM_NOT_FOUND'; end if;
  if p_notes = 'sleep' then perform pg_sleep(2); end if;
  if p_notes = 'boom' then raise exception 'fallo simulado despues del insert'; end if;
  return v_id;
end \$\$;

-- Stub de la oferta, misma firma que la viva (7 args). p_name='boom' simula
-- que la función viva revienta (p. ej. resolvedor de impuestos ambiguo).
create function public.fn_add_offer_deal(
  p_order_id uuid, p_menu_item_id uuid, p_qty numeric default 1,
  p_discount numeric default 0, p_name text default null,
  p_promotion_id uuid default null, p_check_position integer default 1) returns uuid
language plpgsql security definer set search_path to 'public' as \$\$
declare v_id uuid;
begin
  if p_name = 'boom' then raise exception 'function fn_resolve_order_item_tax_profile(uuid, uuid) is not unique' using errcode = '42725'; end if;
  insert into order_items(order_id, product_id, product_name, qty, notes)
  select p_order_id, id, coalesce(p_name, name), p_qty, '[DEAL:]' from menu_items where id = p_menu_item_id
  returning id into v_id;
  return v_id;
end \$\$;

-- Extras: SIN la columna modifier_id a propósito (base con 20260907_0002 sin
-- aplicar): la función debe detectarlo y no intentar escribirla.
create table public.order_item_modifiers (
  id uuid primary key default gen_random_uuid(),
  item_id uuid not null references public.order_items(id) on delete cascade,
  name text not null, qty numeric(10,3) not null default 1,
  price numeric(12,2) not null default 0, menu_item_id uuid);
-- 'sleep' alarga la transacción para la prueba de concurrencia.
create function public.tg_mod_sleep() returns trigger language plpgsql as \$\$
begin if new.name = 'sleep' then perform pg_sleep(2); end if; return new; end \$\$;
create trigger trg_mod_sleep after insert on public.order_item_modifiers
  for each row execute function public.tg_mod_sleep();
-- RLS como en prod (item_mods_rw): authenticated solo ve extras de ítems visibles.
alter table public.order_items enable row level security;
alter table public.order_item_modifiers enable row level security;
create policy items_rw on public.order_items to authenticated
  using (order_id <> '$ORDER2') with check (order_id <> '$ORDER2');
create policy item_mods_rw on public.order_item_modifiers to authenticated
  using (exists (select 1 from public.order_items oi where oi.id = item_id))
  with check (exists (select 1 from public.order_items oi where oi.id = item_id));
SQL

echo "== Migración real"
Q -f "$M/20260929_0001_add_item_idempotent.sql" >/dev/null 2>&1 || { Q -f "$M/20260929_0001_add_item_idempotent.sql"; bad "migración"; exit 1; }
ok "migración aplica"
# Reaplicar: debe ser re-ejecutable.
Q -f "$M/20260929_0001_add_item_idempotent.sql" >/dev/null 2>&1 && ok "migración re-ejecutable" || bad "migración re-ejecutable"

call() { # op order notes [emp]
  local emp=${4:-}
  local empArg="null"; [ -n "$emp" ] && empArg="'$emp'"
  Q -At -c "select public.fn_add_item_from_menu_idempotent('$1','$2','$MENU',1,1,false,$3,$empArg)::text"
}
count() { Q -At -c "select count(*) from public.order_items where order_id = '$1'"; }

echo "== Casos"
OP1=aaaaaaaa-0000-0000-0000-000000000001
R1=$(call $OP1 $ORDER "'nota'" $EMP)
ITEM1=$(echo "$R1" | sed -E 's/.*"item_id": "([^"]+)".*/\1/')
echo "$R1" | grep -q '"replayed": false' && ok "primer alta: replayed=false" || bad "primer alta ($R1)"
[ "$(count $ORDER)" = "1" ] && ok "primer alta: 1 ítem" || bad "primer alta: $(count $ORDER) ítems"
[ "$(Q -At -c "select created_by_employee_id from public.order_items where id='$ITEM1'")" = "$EMP" ] \
  && ok "autor estampado en la misma transacción" || bad "autor no estampado"

R2=$(call $OP1 $ORDER "'nota'" $EMP)
echo "$R2" | grep -q "\"item_id\": \"$ITEM1\"" && echo "$R2" | grep -q '"replayed": true' \
  && ok "reintento mismo op: mismo ítem, replayed=true" || bad "reintento ($R2)"
[ "$(count $ORDER)" = "1" ] && ok "reintento no duplica" || bad "reintento duplicó: $(count $ORDER)"

OP2=aaaaaaaa-0000-0000-0000-000000000002
call $OP2 $ORDER "'nota'" >/dev/null
[ "$(count $ORDER)" = "2" ] && ok "otro op = otra unidad (tocar 2 veces sí agrega 2)" || bad "otro op: $(count $ORDER)"

if Q -At -c "select public.fn_add_item_from_menu_idempotent('$OP1','$ORDER2','$MENU')" >/dev/null 2>&1; then
  bad "op reusado en otra orden debía fallar"
else
  Q -At -c "select public.fn_add_item_from_menu_idempotent('$OP1','$ORDER2','$MENU')" 2>&1 | grep -q CLIENT_OP_ID_CONFLICT \
    && ok "op reusado en otra orden: CLIENT_OP_ID_CONFLICT" || bad "op en otra orden: error inesperado"
fi
[ "$(count $ORDER2)" = "0" ] && ok "otra orden intacta" || bad "otra orden recibió ítem"
Q -At -c "select public.fn_add_item_from_menu_idempotent('$OP1','$ORDER','$MENU',2,1,false,'nota','$EMP')" 2>&1 \
  | grep -q CLIENT_OP_ID_CONFLICT \
  && ok "mismo op con cantidad distinta: rechazado" || bad "op aceptó otro contenido"
Q -At -c "select set_config('test.authorized','off',true); select public.fn_add_item_from_menu_idempotent('$OP1','$ORDER','$MENU',1,1,false,'nota','$EMP')" 2>&1 \
  | grep -q UNAUTHORIZED_BUSINESS \
  && ok "usuario fuera del negocio: no consulta ni crea ítem" || bad "usuario ajeno accedió al ítem"
Q -c "insert into public.zones values ('dddddddd-0000-0000-0000-000000000001','ffffffff-0000-0000-0000-000000000001'); insert into public.dining_tables values ('cccccccc-0000-0000-0000-000000000001','dddddddd-0000-0000-0000-000000000001'); insert into public.table_sessions values ('eeeeeeee-0000-0000-0000-000000000002',null,'cccccccc-0000-0000-0000-000000000001'); insert into public.orders values ('66666666-6666-6666-6666-666666666666','eeeeeeee-0000-0000-0000-000000000002',null)"
call aaaaaaaa-0000-0000-0000-000000000099 66666666-6666-6666-6666-666666666666 "'mesa antigua'" >/dev/null \
  && ok "sesión antigua sin business_id: resuelve negocio por zona" || bad "mesa antigua quedó bloqueada"

Q -c "delete from public.order_items where id = '$ITEM1'"
R3=$(call $OP1 $ORDER "'nota'" $EMP)
echo "$R3" | grep -q '"item_exists": false' && echo "$R3" | grep -q '"replayed": true' \
  && ok "ítem borrado: el reintento NO lo resucita (item_exists=false)" || bad "borrado ($R3)"
[ "$(count $ORDER)" = "1" ] && ok "ítem borrado sigue borrado" || bad "resucitó: $(count $ORDER)"

OP3=aaaaaaaa-0000-0000-0000-000000000003
Q -At -c "select public.fn_add_item_from_menu_idempotent('$OP3','$ORDER','$MENU',1,1,false,'boom')" >/dev/null 2>&1 \
  && bad "fallo simulado debía lanzar" || ok "fallo después del INSERT lanza"
[ "$(Q -At -c "select count(*) from public.order_item_client_ops where client_op_id='$OP3'")" = "0" ] \
  && ok "fallo: la bitácora se revierte con el alta" || bad "fallo dejó op huérfano"
call $OP3 $ORDER "'ok'" | grep -q '"replayed": false' && ok "tras el fallo, el reintento hace el alta" || bad "reintento tras fallo"

OP4=aaaaaaaa-0000-0000-0000-000000000004
Q -At -c "select public.fn_add_item_from_menu_idempotent('$OP4','$CLOSED','$MENU')" 2>&1 | grep -q MP401 \
  && ok "orden cobrada: propaga MP401 (mensaje amigable en la app)" || bad "orden cobrada: sin MP401"
[ "$(Q -At -c "select count(*) from public.order_item_client_ops where client_op_id='$OP4'")" = "0" ] \
  && ok "orden cobrada: nada registrado" || bad "orden cobrada dejó op"

Q -At -c "select public.fn_add_item_from_menu_idempotent(null,'$ORDER','$MENU')" 2>&1 | grep -q CLIENT_OP_ID_REQUIRED \
  && ok "sin client_op_id: CLIENT_OP_ID_REQUIRED" || bad "sin client_op_id no lanzó"

echo "== Concurrencia: dos reintentos simultáneos del mismo op"
OP5=aaaaaaaa-0000-0000-0000-000000000005
BEFORE=$(count $ORDER)
( call $OP5 $ORDER "'sleep'" > "$D/c1.out" 2>&1 ) &
P1=$!
sleep 0.3
( call $OP5 $ORDER "'sleep'" > "$D/c2.out" 2>&1 ) &
P2=$!
wait $P1; wait $P2
A=$(sed -E 's/.*"item_id": "([^"]+)".*/\1/' "$D/c1.out")
B=$(sed -E 's/.*"item_id": "([^"]+)".*/\1/' "$D/c2.out")
[ -n "$A" ] && [ "$A" = "$B" ] && ok "ambos reciben el MISMO ítem" || bad "ítems distintos: $(cat "$D/c1.out") | $(cat "$D/c2.out")"
[ "$(count $ORDER)" = "$((BEFORE + 1))" ] && ok "exactamente 1 ítem nuevo" || bad "se crearon $(( $(count $ORDER) - BEFORE ))"
grep -q '"replayed": true' "$D/c2.out" && ok "el segundo esperó y vio el commit (replayed=true)" || bad "segundo: $(cat "$D/c2.out")"

echo "== Permisos"
run "authenticated puede ejecutar la función" -c "grant usage on schema public to authenticated; set role authenticated; select public.fn_add_item_from_menu_idempotent('aaaaaaaa-0000-0000-0000-000000000006','$ORDER','$MENU');"
if Q -c "set role authenticated; select * from public.order_item_client_ops" >/dev/null 2>&1; then
  bad "authenticated NO debe leer la bitácora directo"
else ok "authenticated no lee la bitácora directo"; fi
if Q -c "set role anon; select public.fn_add_item_from_menu_idempotent('aaaaaaaa-0000-0000-0000-000000000007','$ORDER','$MENU')" >/dev/null 2>&1; then
  bad "anon NO debe ejecutar la función"
else ok "anon no ejecuta la función"; fi

echo "== Oferta idempotente"
OPD=bbbbbbbb-0000-0000-0000-000000000001
deal() { Q -At -c "select public.fn_add_offer_deal_idempotent('$1','$ORDER','$MENU',4,250,$2,null,1,null)::text"; }
BEFORE=$(count $ORDER)
D1=$(deal $OPD "'4x3 Presidente'")
D2=$(deal $OPD "'4x3 Presidente'")
DI1=$(echo "$D1" | sed -E 's/.*"item_id": "([^"]+)".*/\1/')
echo "$D2" | grep -q "\"item_id\": \"$DI1\"" && echo "$D2" | grep -q '"replayed": true' \
  && ok "oferta: reintento devuelve la misma línea" || bad "oferta reintento ($D1 | $D2)"
[ "$(count $ORDER)" = "$((BEFORE + 1))" ] && ok "oferta: una sola línea" || bad "oferta duplicó"
OPD2=bbbbbbbb-0000-0000-0000-000000000002
Q -At -c "select public.fn_add_offer_deal_idempotent('$OPD2','$ORDER','$MENU',4,250,'boom')" 2>&1 | grep -q 'is not unique' \
  && ok "oferta: si la función viva revienta, se propaga el error" || bad "oferta boom sin error"
[ "$(Q -At -c "select count(*) from public.order_item_client_ops where client_op_id='$OPD2'")" = "0" ] \
  && ok "oferta fallida: op libre para caer al alta normal con el mismo id" || bad "oferta fallida dejó op"
call $OPD2 $ORDER "'fallback'" | grep -q '"replayed": false' \
  && ok "caída al alta normal con el MISMO client_op_id" || bad "caída al alta normal"

echo "== Reemplazo atómico de modificadores"
IT=$(Q -At -c "select id from public.order_items where order_id='$ORDER' order by created_at limit 1")
mods() { Q -At -c "select string_agg(name || ':' || qty || ':' || price || ':' || coalesce(menu_item_id::text,'-'), ',' order by name) from public.order_item_modifiers where item_id='$IT'"; }
Q -At -c "select public.fn_replace_order_item_modifiers('$IT', '[{\"name\":\"Queso\",\"qty\":1,\"price\":50},{\"name\":\"Tocino\",\"qty\":2,\"price\":75,\"menu_item_id\":\"$MENU\",\"modifier_id\":\"$MENU\"}]')" >/dev/null \
  && ok "reemplazo aplica (modifier_id ignorado: la columna no existe aquí)" || bad "reemplazo falló"
[ "$(mods)" = "Queso:1.000:50.00:-,Tocino:2.000:75.00:$MENU" ] && ok "extras guardados con menu_item_id" || bad "extras: $(mods)"
Q -At -c "select public.fn_replace_order_item_modifiers('$IT', '[{\"name\":\"Queso\",\"qty\":1,\"price\":50},{\"name\":\"Tocino\",\"qty\":2,\"price\":75,\"menu_item_id\":\"$MENU\"}]')" >/dev/null
[ "$(Q -At -c "select count(*) from public.order_item_modifiers where item_id='$IT'")" = "2" ] \
  && ok "repetir el reemplazo no duplica" || bad "reemplazo repetido duplicó"
Q -At -c "select public.fn_replace_order_item_modifiers('$IT', '[{\"qty\":1}]')" >/dev/null 2>&1 \
  && bad "extra sin nombre debía fallar" || ok "extra inválido: falla"
[ "$(Q -At -c "select count(*) from public.order_item_modifiers where item_id='$IT'")" = "2" ] \
  && ok "fallo a mitad: los extras previos siguen (atómico)" || bad "fallo dejó el ítem sin extras"
Q -At -c "select public.fn_replace_order_item_modifiers('$IT', '[]')" >/dev/null
[ "$(Q -At -c "select count(*) from public.order_item_modifiers where item_id='$IT'")" = "0" ] \
  && ok "lista vacía = quitar todos los extras" || bad "lista vacía"
Q -At -c "select public.fn_replace_order_item_modifiers('cccccccc-0000-0000-0000-000000000000', '[]')" 2>&1 | grep -q ITEM_NOT_FOUND \
  && ok "ítem inexistente: ITEM_NOT_FOUND" || bad "ítem inexistente"

echo "== Reemplazo bajo RLS (SECURITY INVOKER)"
HIDDEN=$(Q -At -c "insert into public.order_items(order_id, product_name) values ('$ORDER2','oculto') returning id")
run "authenticated reemplaza extras de un ítem visible" -c "set role authenticated; select public.fn_replace_order_item_modifiers('$IT', '[{\"name\":\"Hielo\",\"qty\":1,\"price\":0}]');"
if Q -c "set role authenticated; select public.fn_replace_order_item_modifiers('$HIDDEN', '[{\"name\":\"X\"}]')" 2>&1 | grep -q ITEM_NOT_FOUND; then
  ok "ítem fuera de su alcance (RLS): ITEM_NOT_FOUND, sin escribir"
else bad "RLS: pudo tocar un ítem ajeno"; fi

echo "== Concurrencia: dos reemplazos simultáneos del mismo ítem"
( Q -At -c "select public.fn_replace_order_item_modifiers('$IT', '[{\"name\":\"sleep\"}]')" > "$D/m1.out" 2>&1 ) &
P1=$!
sleep 0.3
( Q -At -c "select public.fn_replace_order_item_modifiers('$IT', '[{\"name\":\"Final\"}]')" > "$D/m2.out" 2>&1 ) &
P2=$!
wait $P1; wait $P2
[ "$(mods)" = "Final:1.000:0.00:-" ] && ok "gana el último, sin extras duplicados" || bad "extras tras concurrencia: $(mods)"

echo "== Rollback"
Q -f "$M/20260929_0001_add_item_idempotent_ROLLBACK.sql" >/dev/null 2>&1 && ok "rollback aplica" || bad "rollback"
[ "$(Q -At -c "select count(*) from pg_proc where proname='fn_add_item_from_menu_idempotent'")" = "0" ] \
  && ok "rollback quita la función" || bad "función sigue"
[ "$(Q -At -c "select count(*) from pg_proc where proname='fn_add_item_from_menu'")" = "1" ] \
  && ok "rollback deja fn_add_item_from_menu intacta" || bad "rollback tocó fn_add_item_from_menu"
[ "$(Q -At -c "select count(*) from pg_proc where proname in ('fn_add_offer_deal_idempotent','fn_replace_order_item_modifiers')")" = "0" ] \
  && ok "rollback quita oferta idempotente y reemplazo atómico" || bad "rollback dejó funciones"

echo
if [ $FAIL -eq 0 ]; then echo "TODO OK"; else echo "HAY FALLAS"; fi
exit $FAIL
