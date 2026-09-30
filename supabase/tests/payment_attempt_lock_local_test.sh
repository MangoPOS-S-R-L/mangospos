#!/usr/bin/env bash
# =============================================================================
# Prueba LOCAL del candado de cobro por cuenta (20260929_0002).
# Postgres 15 DESECHABLE; corre el archivo REAL del repo. fn_process_payment_v3
# es un stub con la MISMA firma que la viva (16 args): solo importa que el
# candado impida que dos intentos cobren la misma cuenta. No toca ninguna base.
#
#   bash supabase/tests/payment_attempt_lock_local_test.sh [carpeta_trabajo]
# Variables: PG_BIN (default homebrew postgresql@15), PG_PORT (default 55448).
# =============================================================================
set -u
REPO=$(cd "$(dirname "$0")/../.." && pwd)
M=$REPO/supabase/migrations
PG=${PG_BIN:-/opt/homebrew/opt/postgresql@15/bin}
PORT=${PG_PORT:-55448}
WORK=${1:-$(mktemp -d)}
D=$WORK/pg_payment_lock
rm -rf "$D"; mkdir -p "$D"
"$PG/initdb" -D "$D/data" -U postgres --auth=trust >/dev/null || exit 1
"$PG/pg_ctl" -D "$D/data" -o "-p $PORT -c listen_addresses=127.0.0.1 -c unix_socket_directories=''" \
  -l "$D/log" start -w >/dev/null || { cat "$D/log"; exit 1; }
trap '"$PG/pg_ctl" -D "$D/data" stop -m fast >/dev/null 2>&1' EXIT
Q() { "$PG/psql" -h 127.0.0.1 -p "$PORT" -U postgres -X -q -v ON_ERROR_STOP=1 "$@"; }
FAIL=0
ok()  { echo "  ok     $1"; }
bad() { echo "  FALLA  $1"; FAIL=1; }

O1=11111111-1111-1111-1111-111111111111   # cuenta completa
O2=22222222-2222-2222-2222-222222222222   # cuenta con subcuentas
O3=33333333-3333-3333-3333-333333333333   # ya cobrada
CA=aaaaaaaa-0000-0000-0000-00000000000a
CB=aaaaaaaa-0000-0000-0000-00000000000b
A1=bbbbbbbb-0000-0000-0000-000000000001   # intento PC-1
A2=bbbbbbbb-0000-0000-0000-000000000002   # intento PC-2

echo "== Esquema mínimo + stub de fn_process_payment_v3"
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
alter default privileges in schema public grant all on tables to anon, authenticated;
alter default privileges in schema public grant execute on functions to anon, authenticated;
grant usage on schema public to anon, authenticated;
create type public.order_status as enum ('open','sent_to_kitchen','partially_paid','paid','void');
create table public.zones (id uuid primary key, business_id uuid not null);
create table public.dining_tables (id uuid primary key, zone_id uuid not null);
create table public.table_sessions (id uuid primary key, business_id uuid, table_id uuid);
create table public.orders (id uuid primary key, session_id uuid not null, closed_at timestamptz,
  status_ext public.order_status default 'open');
create table public.order_checks (id uuid primary key, order_id uuid, is_closed boolean default false);
create table public.payments (
  id uuid primary key default gen_random_uuid(),
  order_id uuid, check_id uuid, payment_method_id text, amount numeric,
  change_amount numeric default 0, status text default 'completed',
  split_sequence smallint not null default 0, created_at timestamptz default now());
create unique index payments_unique_completed_per_check_method_seq on public.payments (
  order_id, coalesce(check_id, '00000000-0000-0000-0000-000000000000'::uuid),
  payment_method_id, split_sequence) where status = 'completed';
alter table public.payments enable row level security;
create policy payments_rw on public.payments to authenticated using (true) with check (true);
insert into public.table_sessions (id,business_id) values
  ('eeeeeeee-0000-0000-0000-000000000001','ffffffff-0000-0000-0000-000000000001');
insert into public.orders values
  ('$O1','eeeeeeee-0000-0000-0000-000000000001',null,'open'),
  ('$O2','eeeeeeee-0000-0000-0000-000000000001',null,'open'),
  ('$O3','eeeeeeee-0000-0000-0000-000000000001',now(),'paid');
insert into public.order_checks values ('$CA', '$O2', false), ('$CB', '$O2', false);

create function public.fn_process_payment_v3(
  p_order_id uuid, p_check_id uuid, p_payment_method_id text, p_amount numeric,
  p_reference text, p_customer_id uuid default null, p_customer_rnc text default null,
  p_cashier_session_id uuid default null, p_change_amount numeric default 0,
  p_requested_ncf_type text default null, p_close_order boolean default true,
  p_split_sequence smallint default 0, p_close_check boolean default true,
  p_paid_at timestamptz default null, p_offline_ncf text default null)
returns public.payments language plpgsql security definer set search_path = public as \$\$
declare v public.payments;
begin
  perform 1 from orders where id = p_order_id for update;
  if p_offline_ncf = 'SENTINEL' then
    raise exception 'OFFLINE_NCF_FORWARDED';
  end if;
  insert into payments(order_id, check_id, payment_method_id, amount, change_amount, split_sequence)
  values (p_order_id, p_check_id, p_payment_method_id, p_amount, p_change_amount, p_split_sequence)
  returning * into v;
  if p_check_id is not null and p_close_check then
    update order_checks set is_closed = true where id = p_check_id;
  elsif p_check_id is null and p_close_order then
    update orders set closed_at = now(), status_ext = 'paid' where id = p_order_id;
  end if;
  return v;
end \$\$;
SQL

echo "== Migración real"
if Q -f "$M/20260929_0002_payment_attempt_lock.sql" >/dev/null 2>&1; then ok "migración aplica"
else Q -f "$M/20260929_0002_payment_attempt_lock.sql"; bad "migración"; exit 1; fi
Q -f "$M/20260929_0002_payment_attempt_lock.sql" >/dev/null 2>&1 && ok "migración re-ejecutable" || bad "migración re-ejecutable"

acq() { # order attempt check_or_null label [ttl]
  Q -At -c "select public.fn_payment_attempt_acquire('$1','$2',$3,'dev-$4','$4',${5:-120})::text"; }
pay() { # attempt order check_or_null method amount seq close
  local close=$7
  Q -At -c "select id from public.fn_process_payment_v3_attempt('$1','$2',$3,'$4',$5,null,null,null,null,0,null,$close,$6::smallint,$close,null)"; }
count() { Q -At -c "select count(*) from public.payments where order_id='$1'"; }

echo "== Candado"
R=$(acq $O1 $A1 null caja1)
echo "$R" | grep -q '"acquired": true' && echo "$R" | grep -q '"paid_by_others": 0' \
  && ok "PC-1 toma el candado (nada cobrado antes)" || bad "acquire PC-1: $R"
R=$(acq $O1 $A2 null mesero2)
echo "$R" | grep -q '"acquired": false' && echo "$R" | grep -q '"reason": "held"' && echo "$R" | grep -q '"holder_label": "caja1"' \
  && ok "PC-2 ve que PC-1 está cobrando (y quién)" || bad "acquire PC-2: $R"
acq $O1 $A1 null caja1 | grep -q '"acquired": true' && ok "el mismo intento puede re-tomarlo (reintento/reinicio)" || bad "re-acquire mismo intento"

echo "== Cobro"
pay $A1 $O1 null cash 40 0 false >/dev/null && ok "PC-1 cobra abono 1 (40)" || bad "abono 1"
[ "$(Q -At -c "select client_attempt_id from public.payments where order_id='$O1'")" = "$A1" ] \
  && ok "el pago queda marcado con su intento" || bad "client_attempt_id no estampado"
if pay $A2 $O1 null card 100 0 true >/dev/null 2>&1; then bad "PC-2 no debía poder cobrar"
else pay $A2 $O1 null card 100 0 true 2>&1 | grep -q PAYMENT_LOCKED_BY_OTHER_DEVICE \
  && ok "PC-2 con candado ajeno: PAYMENT_LOCKED_BY_OTHER_DEVICE" || bad "PC-2 error inesperado"; fi
if Q -At -c "select public.fn_process_payment_v3('$O1',null,'card',100,null)" >/dev/null 2>&1; then
  bad "cobro SIN candado (build viejo/modal simple) debía bloquearse"
else ok "cobro sin candado (build viejo, modal simple, replay) también se bloquea"; fi
if Q -c "set role authenticated; insert into public.payments(order_id, payment_method_id, amount) values ('$O1','cash',5)" >/dev/null 2>&1; then
  bad "insert directo como authenticated debía bloquearse"
else Q -c "set role authenticated; insert into public.payments(order_id, payment_method_id, amount) values ('$O1','cash',5)" 2>&1 | grep -q PAYMENT_LOCKED_BY_OTHER_DEVICE \
  && ok "insert directo como authenticated: bloqueado POR EL CANDADO" || bad "insert authenticated falló por otra razón"; fi
[ "$(count $O1)" = "1" ] && ok "solo quedó el abono de PC-1" || bad "pagos en O1: $(count $O1)"
pay $A1 $O1 null cash 60 1 true >/dev/null && ok "PC-1 cierra con el abono 2 (60)" || bad "abono 2"
[ "$(Q -At -c "select count(*) from public.order_payment_attempts where order_id='$O1'")" = "0" ] \
  && ok "el abono que cierra suelta el candado" || bad "candado no liberado"
acq $O1 $A2 null mesero2 | grep -q '"reason": "closed"' && ok "cuenta cobrada: acquire responde closed" || bad "acquire tras cierre"

echo "== Cobro a medias en otra PC: cobrar solo el restante"
acq $O2 $A1 "'$CA'" caja1 >/dev/null
pay $A1 $O2 "'$CA'" cash 40 0 false >/dev/null
# PC-1 muere; el candado vence.
Q -c "update public.order_payment_attempts set expires_at = now() - interval '1 second' where order_id='$O2'"
R=$(acq $O2 $A2 "'$CA'" mesero2)
echo "$R" | grep -q '"acquired": true' && ok "candado vencido: PC-2 lo toma" || bad "acquire tras vencer: $R"
echo "$R" | grep -q '"paid_by_others": 40' && ok "PC-2 ve los 40 ya cobrados en esa subcuenta" || bad "paid_by_others: $R"
echo "$R" | grep -q '"next_split_sequence": 1' && ok "siguiente split_sequence libre = 1" || bad "next_seq: $R"
pay $A2 $O2 "'$CA'" cash 60 1 true >/dev/null && ok "PC-2 cobra el restante (60) sin chocar con el índice" || bad "restante"
[ "$(Q -At -c "select sum(amount) from public.payments where check_id='$CA'")" = "100" ] \
  && ok "subcuenta A: total cobrado 100, no 140" || bad "subcuenta A: $(Q -At -c "select sum(amount) from public.payments where check_id='$CA'")"
R=$(acq $O2 $A1 "'$CB'" caja1)
echo "$R" | grep -q '"paid_by_others": 0' && ok "subcuenta B no hereda lo cobrado en A" || bad "subcuenta B: $R"
Q -At -c "select public.fn_payment_attempt_release('$O2','$A1')" | grep -q t && ok "release suelta el candado" || bad "release"
Q -At -c "select public.fn_payment_attempt_release('$O2','$A1')" | grep -q f && ok "release repetido: idempotente" || bad "release repetido"

echo "== Concurrencia: dos PC toman el candado a la vez"
O4=44444444-4444-4444-4444-444444444444
Q -c "insert into public.orders values ('$O4','eeeeeeee-0000-0000-0000-000000000001', null, 'open')"
( Q -At -c "begin; select public.fn_payment_attempt_acquire('$O4','$A1',null,'dev-1','caja1'); select pg_sleep(2); commit;" > "$D/c1.out" 2>&1 ) &
P1=$!
sleep 0.3
( acq $O4 $A2 null mesero2 > "$D/c2.out" 2>&1 ) &
P2=$!
wait $P1; wait $P2
grep -q '"acquired": true' "$D/c1.out" && grep -q '"reason": "held"' "$D/c2.out" \
  && ok "solo uno gana; el otro esperó y vio el candado" || bad "concurrencia: $(cat "$D/c1.out") | $(cat "$D/c2.out")"

echo "== Sin candado: todo igual que antes"
O5=55555555-5555-5555-5555-555555555555
Q -c "insert into public.orders values ('$O5','eeeeeeee-0000-0000-0000-000000000001', null, 'open')"
Q -c "insert into public.zones values ('dddddddd-0000-0000-0000-000000000001','ffffffff-0000-0000-0000-000000000001'); insert into public.dining_tables values ('cccccccc-0000-0000-0000-000000000001','dddddddd-0000-0000-0000-000000000001'); insert into public.table_sessions values ('eeeeeeee-0000-0000-0000-000000000002',null,'cccccccc-0000-0000-0000-000000000001'); insert into public.orders values ('77777777-7777-7777-7777-777777777777','eeeeeeee-0000-0000-0000-000000000002',null,'open')"
acq 77777777-7777-7777-7777-777777777777 $A1 null caja1 | grep -q '"acquired": true' \
  && ok "sesión antigua sin business_id: resuelve negocio por zona" || bad "mesa antigua quedó bloqueada"
Q -At -c "select public.fn_process_payment_v3('$O5',null,'cash',10,null)" >/dev/null 2>&1 \
  && ok "cuenta sin candado: cobro normal pasa" || bad "cobro sin candado falló"
Q -c "set role authenticated; insert into public.payments(order_id, payment_method_id, amount, split_sequence) values ('$O5','card',1,7)" >/dev/null 2>&1 \
  && ok "sin candado, insert directo como authenticated pasa (el trigger no pide EXECUTE)" || { Q -c "set role authenticated; insert into public.payments(order_id, payment_method_id, amount, split_sequence) values ('$O5','card',1,7)"; bad "insert authenticated sin candado falló"; }

echo "== Permisos"
O6=66666666-6666-6666-6666-666666666666
Q -c "insert into public.orders values ('$O6','eeeeeeee-0000-0000-0000-000000000001',null,'open')"
Q -At -c "select public.fn_process_payment_v3_attempt('$A1','$O6',null,'cash',1,null)" 2>&1 \
  | grep -q PAYMENT_ATTEMPT_EXPIRED \
  && ok "sin acquire previo: wrapper no cobra" || bad "wrapper cobró sin candado"
Q -At -c "select public.fn_payment_attempt_acquire('$O6','$A1','$CA')" 2>&1 \
  | grep -q CHECK_OUT_OF_SCOPE \
  && ok "subcuenta de otra orden: rechazada" || bad "subcuenta ajena admitida"
Q -At -c "select set_config('test.authorized','off',true); select public.fn_payment_attempt_acquire('$O6','$A1')" 2>&1 \
  | grep -q UNAUTHORIZED_BUSINESS \
  && ok "usuario fuera del negocio: no toma candado" || bad "usuario ajeno tomó candado"
Q -At -c "select set_config('test.authorized','off',true); select public.fn_payment_attempt_release('$O2','$A1')" 2>&1 \
  | grep -q UNAUTHORIZED_BUSINESS \
  && ok "usuario fuera del negocio: no suelta candado" || bad "usuario ajeno soltó candado"
acq $O6 $A1 null caja1 >/dev/null
NCF_RESULT=$(Q -At -c "select public.fn_process_payment_v3_attempt('$A1','$O6',null,'cash',1,null,null,null,null,0,null,true,0::smallint,true,null,120,'SENTINEL')" 2>&1)
echo "$NCF_RESULT" | grep -q OFFLINE_NCF_FORWARDED \
  && ok "NCF offline llega intacto a la función de pago viva" || bad "wrapper perdió NCF offline: $NCF_RESULT"
Q -c "update public.order_payment_attempts set expires_at = now() - interval '1 second' where order_id='$O6'"
Q -At -c "select public.fn_process_payment_v3_attempt('$A1','$O6',null,'cash',1,null)" 2>&1 \
  | grep -q PAYMENT_ATTEMPT_EXPIRED \
  && ok "candado vencido: wrapper no cobra sin revalidar saldo" || bad "wrapper cobró con candado vencido"
Q -At -c "select set_config('test.authorized','off',true); select public.fn_process_payment_v3_attempt('$A1','$O6',null,'cash',1,null)" 2>&1 \
  | grep -q UNAUTHORIZED_BUSINESS \
  && ok "usuario fuera del negocio: no cobra" || bad "usuario ajeno cobró"
if Q -c "set role authenticated; select * from public.order_payment_attempts" >/dev/null 2>&1; then
  bad "authenticated no debe leer la tabla del candado"; else ok "authenticated no lee la tabla del candado"; fi
if Q -c "set role anon; select public.fn_payment_attempt_acquire('$O5','$A1')" >/dev/null 2>&1; then
  bad "anon no debe tomar candados"; else ok "anon no toma candados"; fi
Q -c "set role authenticated; select public.fn_payment_attempt_acquire('$O5','$A1')" >/dev/null 2>&1 \
  && ok "authenticated sí toma candados" || bad "authenticated no pudo tomar candado"

echo "== Rollback"
Q -f "$M/20260929_0002_payment_attempt_lock_ROLLBACK.sql" >/dev/null 2>&1 && ok "rollback aplica" || bad "rollback"
[ "$(Q -At -c "select count(*) from pg_trigger where tgname='trg_000_payments_attempt_guard'")" = "0" ] \
  && ok "rollback quita el trigger" || bad "trigger sigue"
Q -At -c "select public.fn_process_payment_v3('$O4',null,'cash',1,null)" >/dev/null 2>&1 \
  && ok "tras rollback, cobro normal sin guardia" || bad "cobro tras rollback"

echo
if [ $FAIL -eq 0 ]; then echo "TODO OK"; else echo "HAY FALLAS"; fi
exit $FAIL
