#!/usr/bin/env bash
# Postgres local desechable; no toca ninguna base remota.
# Prueba 20261013_0003: el Supervisor con `productos.editar` puede guardar
# Modificadores (asignar a productos, grupos, opciones, insumos); sin el permiso,
# con allow=false o con la ficha inactiva sigue bloqueado; nada cruza de negocio;
# el owner no pierde nada; idempotente y con rollback.
# Corre los mismos casos ANTES (reproduce el 42501 de la foto) y DESPUÉS.
set -u
REPO=$(cd "$(dirname "$0")/../.." && pwd)
MIG=$REPO/supabase/migrations/20261013_0003_modifiers_rls_honor_app_permissions.sql
PG=${PG_BIN:-/opt/homebrew/opt/postgresql@15/bin}
PORT=${PG_PORT:-55463}
WORK=${1:-$(mktemp -d)}
D=$WORK/pg_modifiers_rls
mkdir -p "$D"
"$PG/initdb" -D "$D/data" -U postgres --auth=trust >/dev/null
"$PG/pg_ctl" -D "$D/data" -o "-p $PORT -c listen_addresses=127.0.0.1 -c unix_socket_directories=''" -l "$D/log" start -w >/dev/null
trap '"$PG/pg_ctl" -D "$D/data" stop -m fast >/dev/null 2>&1' EXIT
PSQL=("$PG/psql" -X -h 127.0.0.1 -p "$PORT" -U postgres)
DB=modrls

O=00000000-0000-0000-0000-0000000000a0
S=00000000-0000-0000-0000-0000000000a1
S2=00000000-0000-0000-0000-0000000000a2
S3=00000000-0000-0000-0000-0000000000a3
S4=00000000-0000-0000-0000-0000000000a4
MA1=44444444-0000-0000-0000-0000000000a1
MA2=44444444-0000-0000-0000-0000000000a2
MB1=44444444-0000-0000-0000-0000000000b1
GA=55555555-0000-0000-0000-0000000000a1
GB=55555555-0000-0000-0000-0000000000b1
MODA=77777777-0000-0000-0000-0000000000a1
MODB=77777777-0000-0000-0000-0000000000b1
IIA=66666666-0000-0000-0000-0000000000a1
IIB=66666666-0000-0000-0000-0000000000b1
BA=aaaaaaaa-0000-0000-0000-000000000000
BB=bbbbbbbb-0000-0000-0000-000000000000
NEWG=55555555-0000-0000-0000-0000000000a9
NEWM=77777777-0000-0000-0000-0000000000a9

pass=0; fail=0
# q <user> <sql que devuelve un número>  → imprime el número o "42501"
q() {
  local out
  out=$("${PSQL[@]}" -d "$DB" -At -v ON_ERROR_STOP=1 2>&1 <<SQL
begin;
set local role authenticated;
select set_config('request.jwt.claim.sub', '$1', true) \g /dev/null
$2
rollback;
SQL
)
  if grep -q "row-level security" <<<"$out"; then echo 42501
  elif grep -q "ERROR" <<<"$out"; then echo "ERR: $out"
  else grep -E '^[0-9]+$' <<<"$out" | tail -1
  fi
}
check() { # nombre esperado obtenido
  if [[ "$2" == "$3" ]]; then pass=$((pass+1)); printf '  ok   %-62s %s\n' "$1" "$3"
  else fail=$((fail+1)); printf '  FAIL %-62s esperado=%s obtenido=%s\n' "$1" "$2" "$3"; fi
}

# Guardar de "Asignación a productos" = DELETE por group_id + INSERT (replaceAssignments)
save_assign() { # user group items...
  local u=$1 g=$2; shift 2
  local vals="" sep=""
  for m in "$@"; do vals+="$sep('$m','$g')"; sep=","; done
  q "$u" "with d as (delete from public.menu_item_groups where group_id = '$g' returning 1) select count(*) from d;
insert into public.menu_item_groups (menu_item_id, group_id) values $vals;
select count(*) from public.menu_item_groups where group_id = '$g';"
}

suite() {
  echo "── Asignación a productos (el error de la foto)"
  check "S guarda Taco Tuesday + Unidad en Extra TT"            "$1" "$(save_assign $S $GA $MA1 $MA2)"
  check "S2 (rol sin productos.editar) guarda"                   42501 "$(save_assign $S2 $GA $MA1)"
  check "S3 (productos.editar allow=false) guarda"               42501 "$(save_assign $S3 $GA $MA1)"
  check "S4 (ficha employees inactiva) guarda"                   42501 "$(save_assign $S4 $GA $MA1)"
  check "Owner guarda (policy base intacta)"                     2 "$(save_assign $O $GA $MA1 $MA2)"
  check "S: DELETE asignaciones de A afecta filas"               "$2" "$(q $S "with d as (delete from public.menu_item_groups where group_id='$GA' returning 1) select count(*) from d;")"
  check "S2: DELETE asignaciones de A afecta 0 (no miente)"      0 "$(q $S2 "with d as (delete from public.menu_item_groups where group_id='$GA' returning 1) select count(*) from d;")"
  check "S: producto de A + grupo de B"                          42501 "$(q $S "insert into public.menu_item_groups values ('$MA1','$GB',0); select 1;")"
  check "S: producto de B + grupo de B (sin permiso en B)"       42501 "$(q $S "insert into public.menu_item_groups values ('$MB1','$GB',0); select 1;")"
  check "S: DELETE asignaciones de B (sin permiso en B)"         0 "$(q $S "with d as (delete from public.menu_item_groups where group_id='$GB' returning 1) select count(*) from d;")"
  check "S: UPDATE position en A"                                "$2" "$(q $S "with u as (update public.menu_item_groups set position=5 where group_id='$GA' returning 1) select count(*) from u;")"
  check "S: UPDATE moviendo la fila a grupo de B"                "$3" "$(q $S "with u as (update public.menu_item_groups set group_id='$GB' where group_id='$GA' returning 1) select count(*) from u;")"

  echo "── Grupos"
  check "S crea grupo en A"                                      "$4" "$(q $S "with i as (insert into public.modifier_groups (id,business_id,name) values ('$NEWG','$BA','Nuevo') returning 1) select count(*) from i;")"
  check "S crea grupo en B (sin permiso)"                        42501 "$(q $S "insert into public.modifier_groups (id,business_id,name) values ('$NEWG','$BB','Nuevo'); select 1;")"
  check "S edita grupo de A"                                     "$2" "$(q $S "with u as (update public.modifier_groups set name='X' where id='$GA' returning 1) select count(*) from u;")"
  check "S mueve grupo de A al negocio B"                        "$3" "$(q $S "with u as (update public.modifier_groups set business_id='$BB' where id='$GA' returning 1) select count(*) from u;")"
  check "S borra grupo de A"                                     "$2" "$(q $S "with d as (delete from public.modifier_groups where id='$GA' returning 1) select count(*) from d;")"
  check "S borra grupo de B"                                     0 "$(q $S "with d as (delete from public.modifier_groups where id='$GB' returning 1) select count(*) from d;")"
  check "S2 edita grupo de A (0 filas)"                          0 "$(q $S2 "with u as (update public.modifier_groups set name='X' where id='$GA' returning 1) select count(*) from u;")"

  echo "── Opciones"
  check "S agrega opción a grupo de A"                           "$4" "$(q $S "with i as (insert into public.modifiers (id,business_id,group_id,name) values ('$NEWM','$BA','$GA','Queso') returning 1) select count(*) from i;")"
  check "S agrega opción en A colgada de grupo de B"             42501 "$(q $S "insert into public.modifiers (id,business_id,group_id,name) values ('$NEWM','$BA','$GB','Queso'); select 1;")"
  check "S edita precio de Guacamole"                            "$2" "$(q $S "with u as (update public.modifiers set price_delta=120 where id='$MODA' returning 1) select count(*) from u;")"
  check "S reordena opción (sort_order)"                         "$2" "$(q $S "with u as (update public.modifiers set sort_order=2 where id='$MODA' and group_id='$GA' returning 1) select count(*) from u;")"
  check "S cuelga Guacamole de grupo de B"                       "$3" "$(q $S "with u as (update public.modifiers set group_id='$GB' where id='$MODA' returning 1) select count(*) from u;")"
  check "S borra Guacamole"                                      "$2" "$(q $S "with d as (delete from public.modifiers where id='$MODA' returning 1) select count(*) from d;")"
  check "S borra opción de B"                                    0 "$(q $S "with d as (delete from public.modifiers where id='$MODB' returning 1) select count(*) from d;")"

  echo "── Insumos de la opción"
  check "S liga insumo de A a Guacamole"                         "$4" "$(q $S "with i as (insert into public.modifier_ingredients (modifier_id,inventory_item_id,quantity,unit) values ('$MODA','$IIA',1,'g') returning 1) select count(*) from i;")"
  check "S liga insumo de B a Guacamole"                         42501 "$(q $S "insert into public.modifier_ingredients (modifier_id,inventory_item_id,quantity,unit) values ('$MODA','$IIB',1,'g'); select 1;")"
  check "S2 liga insumo de A"                                    42501 "$(q $S2 "insert into public.modifier_ingredients (modifier_id,inventory_item_id,quantity,unit) values ('$MODA','$IIA',1,'g'); select 1;")"

  echo "── Lectura (no cambia)"
  check "S lee asignaciones de A"                                1 "$(q $S "select count(*) from public.menu_item_groups mig join public.menu_items mi on mi.id=mig.menu_item_id where mi.business_id='$BA';")"
}

"${PSQL[@]}" -q -c "create database $DB" >/dev/null
"${PSQL[@]}" -q -d $DB -v ON_ERROR_STOP=1 >/dev/null <<'SETUP' || { echo "setup falló"; exit 1; }
-- Esquema mínimo para probar 20261013_0003 (políticas base copiadas de schema.sql
-- y de 20260907_0001; puente de 20260803_0001).
do $$ begin create role authenticated nologin; exception when duplicate_object then null; end $$;
create schema auth;
create function auth.uid() returns uuid language sql stable as
  $$ select nullif(current_setting('request.jwt.claim.sub', true), '')::uuid $$;
grant usage on schema auth to authenticated;

create table public.businesses (id uuid primary key);
create table public.user_businesses (user_id uuid, business_id uuid, role text);
create table public.menu_items (id uuid primary key, business_id uuid not null, name text);
create table public.inventory_items (id uuid primary key, business_id uuid not null);
create table public.permissions (id uuid primary key default gen_random_uuid(), code text unique);
create table public.roles (id uuid primary key default gen_random_uuid(), business_id uuid, name text);
create table public.role_permissions (role_id uuid, permission_id uuid, allow boolean);
create table public.employees (id uuid primary key default gen_random_uuid(), user_id uuid, business_id uuid, status text);
create table public.employee_roles (employee_id uuid, role_id uuid);

create table public.modifier_groups (
  id uuid primary key, business_id uuid not null, name text not null,
  min_select int not null default 0, max_select int not null default 0,
  is_active boolean not null default true, sort_order int default 0,
  created_at timestamptz not null default now());
create table public.modifiers (
  id uuid primary key, business_id uuid not null, group_id uuid, name text not null,
  price_delta numeric(12,2) not null default 0, is_active boolean not null default true,
  sort_order int default 0, created_at timestamptz not null default now());
create table public.menu_item_groups (
  menu_item_id uuid not null, group_id uuid not null, position int not null default 0);
create table public.modifier_ingredients (
  id uuid primary key default gen_random_uuid(),
  modifier_id uuid not null references public.modifiers(id) on delete cascade,
  inventory_item_id uuid not null references public.inventory_items(id),
  quantity numeric not null, unit text not null);

create function public.current_user_business_ids() returns setof uuid
language sql stable security definer set search_path = public as
  $$ select business_id from public.user_businesses where user_id = auth.uid() $$;
create function public.user_has_business_access(u uuid, b uuid) returns boolean
language sql stable security definer set search_path = public as
  $$ select exists (select 1 from public.user_businesses where user_id = u and business_id = b) $$;
create function public.user_business_role(u uuid, b uuid) returns text
language sql stable security definer set search_path = public as
  $$ select role from public.user_businesses where user_id = u and business_id = b limit 1 $$;

-- Puente (20260803_0001)
create function public.user_has_business_permission(p_business uuid, p_permission_code text)
returns boolean language sql stable security definer set search_path = public as $$
  select exists (
    select 1
    from public.employees e
    join public.employee_roles er on er.employee_id = e.id
    join public.role_permissions rp on rp.role_id = er.role_id
    join public.permissions p on p.id = rp.permission_id
    where e.user_id = auth.uid()
      and e.business_id = p_business
      and coalesce(e.status, 'active') = 'active'
      and p.code = p_permission_code
      and coalesce(rp.allow, true)
  );
$$;

grant select, insert, update, delete on all tables in schema public to authenticated;
grant execute on all functions in schema public to authenticated;

alter table public.menu_items enable row level security;
create policy mi_read on public.menu_items for select to authenticated
  using (business_id in (select public.current_user_business_ids()));
alter table public.inventory_items enable row level security;
create policy ii_read on public.inventory_items for select to authenticated
  using (business_id in (select public.current_user_business_ids()));

-- Base vivas (schema.sql)
alter table public.menu_item_groups enable row level security;
CREATE POLICY "menu_item_groups_read" ON "public"."menu_item_groups" FOR SELECT TO "authenticated" USING ((EXISTS ( SELECT 1
   FROM "public"."menu_items" "mi"
  WHERE (("mi"."id" = "menu_item_groups"."menu_item_id") AND ("mi"."business_id" IN ( SELECT "public"."current_user_business_ids"() AS "current_user_business_ids"))))));
CREATE POLICY "menu_item_groups_write" ON "public"."menu_item_groups" TO "authenticated" USING ((EXISTS ( SELECT 1
   FROM "public"."menu_items" "mi"
  WHERE (("mi"."id" = "menu_item_groups"."menu_item_id") AND (EXISTS ( SELECT 1
           FROM "public"."user_businesses" "ub"
          WHERE (("ub"."business_id" = "mi"."business_id") AND ("ub"."user_id" = "auth"."uid"()) AND ("ub"."role" = ANY (ARRAY['owner'::"text", 'admin'::"text"]))))))))) WITH CHECK ((EXISTS ( SELECT 1
   FROM "public"."menu_items" "mi"
  WHERE (("mi"."id" = "menu_item_groups"."menu_item_id") AND (EXISTS ( SELECT 1
           FROM "public"."user_businesses" "ub"
          WHERE (("ub"."business_id" = "mi"."business_id") AND ("ub"."user_id" = "auth"."uid"()) AND ("ub"."role" = ANY (ARRAY['owner'::"text", 'admin'::"text"])))))))));

alter table public.modifier_groups enable row level security;
CREATE POLICY "modifier_groups_read" ON "public"."modifier_groups" FOR SELECT TO "authenticated" USING (("business_id" IN ( SELECT "public"."current_user_business_ids"() AS "current_user_business_ids")));
CREATE POLICY "modifier_groups_write" ON "public"."modifier_groups" TO "authenticated" USING ((EXISTS ( SELECT 1
   FROM "public"."user_businesses" "ub"
  WHERE (("ub"."business_id" = "modifier_groups"."business_id") AND ("ub"."user_id" = "auth"."uid"()) AND ("ub"."role" = ANY (ARRAY['owner'::"text", 'admin'::"text"])))))) WITH CHECK ((EXISTS ( SELECT 1
   FROM "public"."user_businesses" "ub"
  WHERE (("ub"."business_id" = "modifier_groups"."business_id") AND ("ub"."user_id" = "auth"."uid"()) AND ("ub"."role" = ANY (ARRAY['owner'::"text", 'admin'::"text"]))))));

alter table public.modifiers enable row level security;
CREATE POLICY "modifiers_read" ON "public"."modifiers" FOR SELECT TO "authenticated" USING (("business_id" IN ( SELECT "public"."current_user_business_ids"() AS "current_user_business_ids")));
CREATE POLICY "modifiers_write" ON "public"."modifiers" TO "authenticated" USING ((EXISTS ( SELECT 1
   FROM "public"."user_businesses" "ub"
  WHERE (("ub"."business_id" = "modifiers"."business_id") AND ("ub"."user_id" = "auth"."uid"()) AND ("ub"."role" = ANY (ARRAY['owner'::"text", 'admin'::"text"])))))) WITH CHECK ((EXISTS ( SELECT 1
   FROM "public"."user_businesses" "ub"
  WHERE (("ub"."business_id" = "modifiers"."business_id") AND ("ub"."user_id" = "auth"."uid"()) AND ("ub"."role" = ANY (ARRAY['owner'::"text", 'admin'::"text"]))))));

alter table public.modifier_ingredients enable row level security;
create policy "mi_ing_select" on public.modifier_ingredients for select to authenticated
  using (exists (select 1 from public.modifiers m where m.id = modifier_ingredients.modifier_id
                 and public.user_has_business_access(auth.uid(), m.business_id)));
create policy "mi_ing_write" on public.modifier_ingredients for all to authenticated
  using (exists (select 1 from public.modifiers m where m.id = modifier_ingredients.modifier_id
                 and public.user_business_role(auth.uid(), m.business_id) = any (array['owner'::text, 'admin'::text])))
  with check (exists (select 1 from public.modifiers m
                 join public.inventory_items ii on ii.id = modifier_ingredients.inventory_item_id
                 where m.id = modifier_ingredients.modifier_id and ii.business_id = m.business_id
                 and public.user_business_role(auth.uid(), m.business_id) = any (array['owner'::text, 'admin'::text])));

-- ── Fixtures ────────────────────────────────────────────────────────────────
-- A = negocio de la foto; B = otro tenant.
-- O  = owner de A (sin ficha employees)
-- S  = Supervisor (manager) de A con productos.editar
-- S2 = Supervisor de A cuyo rol NO tiene productos.editar
-- S3 = Supervisor de A con productos.editar pero allow=false
-- S4 = Supervisor de A con permiso pero employees.status='inactive'
-- S  también es manager de B pero SIN permiso allí.
insert into public.businesses values
 ('aaaaaaaa-0000-0000-0000-000000000000'), ('bbbbbbbb-0000-0000-0000-000000000000');
insert into public.permissions (id, code) values
 ('11111111-0000-0000-0000-000000000000', 'productos.editar'),
 ('11111111-0000-0000-0000-000000000001', 'productos.acceso');
insert into public.roles (id, business_id, name) values
 ('22222222-0000-0000-0000-00000000000a', 'aaaaaaaa-0000-0000-0000-000000000000', 'Supervisor'),
 ('22222222-0000-0000-0000-00000000002a', 'aaaaaaaa-0000-0000-0000-000000000000', 'Supervisor sin editar'),
 ('22222222-0000-0000-0000-00000000003a', 'aaaaaaaa-0000-0000-0000-000000000000', 'Supervisor denegado'),
 ('22222222-0000-0000-0000-00000000000b', 'bbbbbbbb-0000-0000-0000-000000000000', 'Supervisor B sin editar');
insert into public.role_permissions values
 ('22222222-0000-0000-0000-00000000000a', '11111111-0000-0000-0000-000000000000', true),
 ('22222222-0000-0000-0000-00000000000a', '11111111-0000-0000-0000-000000000001', true),
 ('22222222-0000-0000-0000-00000000002a', '11111111-0000-0000-0000-000000000001', true),
 ('22222222-0000-0000-0000-00000000003a', '11111111-0000-0000-0000-000000000000', false),
 ('22222222-0000-0000-0000-00000000000b', '11111111-0000-0000-0000-000000000001', true);
insert into public.user_businesses values
 ('00000000-0000-0000-0000-0000000000a0', 'aaaaaaaa-0000-0000-0000-000000000000', 'owner'),
 ('00000000-0000-0000-0000-0000000000a1', 'aaaaaaaa-0000-0000-0000-000000000000', 'manager'),
 ('00000000-0000-0000-0000-0000000000a1', 'bbbbbbbb-0000-0000-0000-000000000000', 'manager'),
 ('00000000-0000-0000-0000-0000000000a2', 'aaaaaaaa-0000-0000-0000-000000000000', 'manager'),
 ('00000000-0000-0000-0000-0000000000a3', 'aaaaaaaa-0000-0000-0000-000000000000', 'manager'),
 ('00000000-0000-0000-0000-0000000000a4', 'aaaaaaaa-0000-0000-0000-000000000000', 'manager');
insert into public.employees (id, user_id, business_id, status) values
 ('33333333-0000-0000-0000-0000000000a1', '00000000-0000-0000-0000-0000000000a1', 'aaaaaaaa-0000-0000-0000-000000000000', 'active'),
 ('33333333-0000-0000-0000-0000000000b1', '00000000-0000-0000-0000-0000000000a1', 'bbbbbbbb-0000-0000-0000-000000000000', 'active'),
 ('33333333-0000-0000-0000-0000000000a2', '00000000-0000-0000-0000-0000000000a2', 'aaaaaaaa-0000-0000-0000-000000000000', 'active'),
 ('33333333-0000-0000-0000-0000000000a3', '00000000-0000-0000-0000-0000000000a3', 'aaaaaaaa-0000-0000-0000-000000000000', 'active'),
 ('33333333-0000-0000-0000-0000000000a4', '00000000-0000-0000-0000-0000000000a4', 'aaaaaaaa-0000-0000-0000-000000000000', 'inactive');
insert into public.employee_roles values
 ('33333333-0000-0000-0000-0000000000a1', '22222222-0000-0000-0000-00000000000a'),
 ('33333333-0000-0000-0000-0000000000b1', '22222222-0000-0000-0000-00000000000b'),
 ('33333333-0000-0000-0000-0000000000a2', '22222222-0000-0000-0000-00000000002a'),
 ('33333333-0000-0000-0000-0000000000a3', '22222222-0000-0000-0000-00000000003a'),
 ('33333333-0000-0000-0000-0000000000a4', '22222222-0000-0000-0000-00000000000a');

-- Catálogo: A tiene Taco Tuesday / Unidad de taco + grupo «Extra TT» con Guacamole.
insert into public.menu_items values
 ('44444444-0000-0000-0000-0000000000a1', 'aaaaaaaa-0000-0000-0000-000000000000', 'Taco Tuesday'),
 ('44444444-0000-0000-0000-0000000000a2', 'aaaaaaaa-0000-0000-0000-000000000000', 'UNIDAD DE TACO'),
 ('44444444-0000-0000-0000-0000000000b1', 'bbbbbbbb-0000-0000-0000-000000000000', 'Producto B');
insert into public.inventory_items values
 ('66666666-0000-0000-0000-0000000000a1', 'aaaaaaaa-0000-0000-0000-000000000000'),
 ('66666666-0000-0000-0000-0000000000b1', 'bbbbbbbb-0000-0000-0000-000000000000');
insert into public.modifier_groups (id, business_id, name) values
 ('55555555-0000-0000-0000-0000000000a1', 'aaaaaaaa-0000-0000-0000-000000000000', 'Extra TT'),
 ('55555555-0000-0000-0000-0000000000b1', 'bbbbbbbb-0000-0000-0000-000000000000', 'Grupo B');
insert into public.modifiers (id, business_id, group_id, name, price_delta) values
 ('77777777-0000-0000-0000-0000000000a1', 'aaaaaaaa-0000-0000-0000-000000000000', '55555555-0000-0000-0000-0000000000a1', 'Guacamole Extra', 100),
 ('77777777-0000-0000-0000-0000000000b1', 'bbbbbbbb-0000-0000-0000-000000000000', '55555555-0000-0000-0000-0000000000b1', 'Opción B', 50);
insert into public.menu_item_groups (menu_item_id, group_id) values
 ('44444444-0000-0000-0000-0000000000a2', '55555555-0000-0000-0000-0000000000a1'),
 ('44444444-0000-0000-0000-0000000000b1', '55555555-0000-0000-0000-0000000000b1');
SETUP

echo "════ ANTES de la migración (reproduce la foto)"
# Antes: S no puede nada → inserts 42501, updates/deletes 0 filas
suite 42501 0 0 42501

echo "════ Aplicando $MIG"
"${PSQL[@]}" -q -d $DB -v ON_ERROR_STOP=1 -f "$MIG" >/dev/null || { echo "migración falló"; exit 1; }
echo "════ Re-aplicando (idempotencia)"
"${PSQL[@]}" -q -d $DB -v ON_ERROR_STOP=1 -f "$MIG" >/dev/null || { echo "2ª aplicación falló"; exit 1; }

echo "════ DESPUÉS de la migración"
suite 2 1 42501 1

echo "════ ROLLBACK"
"${PSQL[@]}" -q -d $DB -v ON_ERROR_STOP=1 -f "${MIG%.sql}_ROLLBACK.sql" >/dev/null || { echo "rollback falló"; exit 1; }
check "Tras rollback S vuelve a fallar" 42501 "$(save_assign $S $GA $MA1)"
check "Tras rollback Owner sigue pudiendo" 1 "$(save_assign $O $GA $MA1)"

echo; echo "RESULTADO: $pass ok, $fail fallas"
[[ $fail -eq 0 ]]
