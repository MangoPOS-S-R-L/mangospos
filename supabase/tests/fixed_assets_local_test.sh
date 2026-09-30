#!/usr/bin/env bash
# =============================================================================
# Prueba LOCAL de Activos fijos (20260930_0052).
# Postgres 15 DESECHABLE con el esquema mínimo (negocios, bodegas, empleados,
# perfiles, catálogo de permisos y la user_has_business_permission REAL de
# 20260803_0001); corre los archivos REALES del repo. No toca ninguna base.
#
#   bash supabase/tests/fixed_assets_local_test.sh [carpeta_trabajo]
# Variables: PG_BIN (default homebrew postgresql@15), PG_PORT (default 55472).
# =============================================================================
set -u
REPO=$(cd "$(dirname "$0")/../.." && pwd)
M=$REPO/supabase/migrations
MIG=$M/20260930_0052_fixed_assets.sql
RB=$M/20260930_0052_fixed_assets_ROLLBACK.sql
PG=${PG_BIN:-/opt/homebrew/opt/postgresql@15/bin}
PORT=${PG_PORT:-55472}
WORK=${1:-$(mktemp -d)}
D=$WORK/pg_fixed_assets
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
  if OUT=$(Q "$@" 2>&1); then echo "$OUT" | grep -E "NOTICE:  (ok|--)" | sed 's/^.*NOTICE:  /  /'; ok "$label";
  else echo "$OUT" | grep -E "NOTICE:  ok|ERROR" | sed 's/^.*NOTICE:  /  /; s/^psql:[^:]*:[0-9]*: //'; bad "$label"; fi
}

echo "== Esquema mínimo"
Q <<'SQL' || { bad "esquema"; exit 1; }
create role authenticated; create role anon; create role service_role;
create schema auth;
grant usage on schema auth to authenticated, anon;
create table auth.users (id uuid primary key);
-- Usuarios:
--   9999 dueño de B1 · 8888 mesero de B1 sin permiso · 7777 cajera de B1 con
--   un rol a la medida que trae inventario.activos.gestionar · 6666 dueño de B2.
insert into auth.users values
  ('99999999-9999-9999-9999-999999999999'),
  ('88888888-8888-8888-8888-888888888888'),
  ('77777777-7777-7777-7777-777777777777'),
  ('66666666-6666-6666-6666-666666666666');

-- auth.uid() conmutable, para probar quién hace cada cosa.
create function auth.uid() returns uuid language sql stable as $$
  select coalesce(nullif(current_setting('test.uid', true), ''),
                  '99999999-9999-9999-9999-999999999999')::uuid
$$;

create table public.businesses (id uuid primary key, business_name text, owner_id uuid);
create table public.warehouses (id uuid primary key, business_id uuid not null, name text not null);
create table public.employees (id uuid primary key, business_id uuid not null, user_id uuid,
  first_name text not null, last_name text not null, status text not null default 'active');
create table public.profiles (id uuid primary key, email text not null, full_name text);

create table public.permissions (id uuid primary key default gen_random_uuid(), code text unique not null,
  name text, module text, description text);
create table public.roles (id uuid primary key default gen_random_uuid(), business_id uuid, name text,
  is_system boolean default false);
create table public.role_permissions (role_id uuid, permission_id uuid, allow boolean default true,
  primary key (role_id, permission_id));
create table public.employee_roles (employee_id uuid not null, role_id uuid not null);

-- Membresías (lo que en prod es user_businesses + businesses.owner_id).
create table public.memberships (user_id uuid, business_id uuid, role text);
insert into public.memberships values
  ('99999999-9999-9999-9999-999999999999','11111111-1111-1111-1111-111111111111','owner'),
  ('88888888-8888-8888-8888-888888888888','11111111-1111-1111-1111-111111111111','waiter'),
  ('77777777-7777-7777-7777-777777777777','11111111-1111-1111-1111-111111111111','cashier'),
  ('66666666-6666-6666-6666-666666666666','22222222-2222-2222-2222-222222222222','owner');

-- Los helpers de prod son SECURITY DEFINER: el RLS los evalúa sin permisos
-- sobre las tablas de membresía.
create function public.user_business_role(p_user uuid, p_business uuid) returns text
language sql stable security definer set search_path = public as $$
  select role from public.memberships where user_id = p_user and business_id = p_business $$;
create function public.user_has_business_access(p_user uuid, p_business uuid) returns boolean
language sql stable security definer set search_path = public as $$
  select exists (select 1 from public.memberships where user_id = p_user and business_id = p_business) $$;

-- La REAL (20260803_0001): el permiso tiene que existir en public.permissions
-- para que el join lo encuentre. Es el fallo silencioso que se prueba abajo.
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

-- Datos
insert into public.businesses values
  ('11111111-1111-1111-1111-111111111111','La Penda','99999999-9999-9999-9999-999999999999'),
  ('22222222-2222-2222-2222-222222222222','Otro Bar','66666666-6666-6666-6666-666666666666');
insert into public.warehouses values
  ('a0000000-0000-0000-0000-000000000001','11111111-1111-1111-1111-111111111111','Principal'),
  ('a0000000-0000-0000-0000-000000000002','11111111-1111-1111-1111-111111111111','Cocina'),
  ('a0000000-0000-0000-0000-00000000000f','11111111-1111-1111-1111-111111111111','__IN_TRANSIT__'),
  ('b0000000-0000-0000-0000-000000000001','22222222-2222-2222-2222-222222222222','Principal B2');
insert into public.employees (id, business_id, user_id, first_name, last_name) values
  ('e0000000-0000-0000-0000-000000000001','11111111-1111-1111-1111-111111111111', null, 'Juan', 'Pérez'),
  ('e0000000-0000-0000-0000-000000000002','11111111-1111-1111-1111-111111111111', null, 'Ana', 'Gómez'),
  ('e0000000-0000-0000-0000-000000000003','11111111-1111-1111-1111-111111111111',
   '77777777-7777-7777-7777-777777777777', 'Carla', 'Ruiz'),
  ('e0000000-0000-0000-0000-000000000009','22222222-2222-2222-2222-222222222222', null, 'Pedro', 'Otro');
insert into public.profiles values
  ('99999999-9999-9999-9999-999999999999','dueno@penda.do','Dueño Penda'),
  ('66666666-6666-6666-6666-666666666666','dueno@otro.do', null);

-- Roles de sistema por negocio + uno a la medida (sin permisos todavía).
insert into public.roles (business_id, name, is_system)
select b, r, true
  from unnest(array['11111111-1111-1111-1111-111111111111','22222222-2222-2222-2222-222222222222']::uuid[]) b
 cross join unnest(array['owner','admin','manager','waiter']) r;
insert into public.roles (id, business_id, name, is_system) values
  ('c0000000-0000-0000-0000-000000000001','11111111-1111-1111-1111-111111111111','Encargada de activos', false);
insert into public.employee_roles values
  ('e0000000-0000-0000-0000-000000000003','c0000000-0000-0000-0000-000000000001');

create schema test;
grant usage on schema test to authenticated, anon;
create function test.chk(p_label text, p_ok boolean, p_detail text default '') returns void language plpgsql as $$
begin
  if p_ok is not true then raise exception 'FALLA % %', p_label, coalesce(p_detail, ''); end if;
  raise notice 'ok  %', p_label;
end $$;
-- Corre una sentencia y devuelve el error (o null si pasó).
create function test.err(p_sql text) returns text language plpgsql as $$
begin
  execute p_sql;
  return null;
exception when others then
  return sqlerrm;
end $$;
create function test.as_user(p_uid text) returns void language sql as $$
  select set_config('test.uid', p_uid, true) $$;
-- plpgsql: la tabla todavía no existe al crear el helper.
create function test.hist(p_asset uuid) returns bigint language plpgsql as $$
begin
  return (select count(*) from public.fixed_asset_movements where asset_id = p_asset);
end $$;
SQL
ok "esquema mínimo"

echo "== Migración real"
run "aplica 20260930_0052"            -f "$MIG"
run "idempotente (segunda pasada)"    -f "$MIG"

echo "== Comportamiento"
run "casos" <<'SQL'
do $$
declare
  B1 constant uuid := '11111111-1111-1111-1111-111111111111';
  B2 constant uuid := '22222222-2222-2222-2222-222222222222';
  W_PRIN constant uuid := 'a0000000-0000-0000-0000-000000000001';
  W_COC  constant uuid := 'a0000000-0000-0000-0000-000000000002';
  W_TRAN constant uuid := 'a0000000-0000-0000-0000-00000000000f';
  W_B2   constant uuid := 'b0000000-0000-0000-0000-000000000001';
  E_JUAN constant uuid := 'e0000000-0000-0000-0000-000000000001';
  E_ANA  constant uuid := 'e0000000-0000-0000-0000-000000000002';
  E_B2   constant uuid := 'e0000000-0000-0000-0000-000000000009';
  v jsonb; v2 jsonb; v_id uuid; v_id2 uuid; v_msg text; v_req uuid := gen_random_uuid();
  m record;
begin
  perform test.as_user('99999999-9999-9999-9999-999999999999');

  -- ── 1. Alta y numeración ──
  v := public.fn_fixed_asset_create(B1, jsonb_build_object(
    'name', '  Horno de convección  ', 'category', 'Equipo de cocina', 'brand', 'Rational',
    'model', 'iCombi Pro 6-1/1', 'serial_number', 'RAT-12345', 'purchase_date', '2025-03-15',
    'purchase_cost', 850000.5, 'supplier_name', 'Equipos del Caribe', 'warranty_until', '2027-03-15',
    'warehouse_id', W_COC, 'location_note', 'Cocina caliente, junto a la plancha',
    'assigned_employee_id', E_JUAN, 'notes', 'Mantenimiento cada 6 meses'));
  v_id := (v->>'id')::uuid;
  perform test.chk('1 primer código AF-00001', v->>'code' = 'AF-00001', v::text);
  perform test.chk('1 nombre recortado', v->>'name' = 'Horno de convección', v->>'name');
  perform test.chk('1 estado por defecto active', v->>'status' = 'active');
  perform test.chk('1 costo', (v->>'purchase_cost')::numeric = 850000.50, v->>'purchase_cost');
  perform test.chk('1 bodega embebida como el SELECT de PostgREST', v->'warehouses'->>'name' = 'Cocina', v::text);
  perform test.chk('1 responsable embebido', v->'employees'->>'first_name' = 'Juan', v::text);
  perform test.chk('1 client_request_id no sale en el json', not (v ? 'client_request_id'));
  perform test.chk('1 created_by = quien lo creó',
    (select created_by = '99999999-9999-9999-9999-999999999999' from public.fixed_assets where id = v_id));
  select * into m from public.fixed_asset_movements where asset_id = v_id;
  perform test.chk('1 historia: una fila created', test.hist(v_id) = 1 and m.event_type = 'created', m::text);
  perform test.chk('1 historia: foto de bodega, ubicación, responsable y estado',
    m.to_warehouse_id = W_COC and m.to_warehouse_name = 'Cocina'
    and m.to_location_note = 'Cocina caliente, junto a la plancha'
    and m.to_employee_id = E_JUAN and m.to_employee_name = 'Juan Pérez' and m.to_status = 'active', m::text);
  perform test.chk('1 historia: quién (sin ser empleado, sale su perfil)',
    m.created_by = '99999999-9999-9999-9999-999999999999' and m.created_by_name = 'Dueño Penda', m::text);

  v2 := public.fn_fixed_asset_create(B1, jsonb_build_object('name', 'Nevera vertical',
    'category', 'Refrigeración', 'client_request_id', v_req));
  v_id2 := (v2->>'id')::uuid;
  perform test.chk('1 segundo código AF-00002', v2->>'code' = 'AF-00002', v2::text);
  perform test.chk('1 sin bodega ni responsable: embebidos en null',
    v2->'warehouses' = 'null'::jsonb and v2->'employees' = 'null'::jsonb, v2::text);

  -- Reintento del mismo formulario (timeout): la misma ficha, sin historia nueva.
  v := public.fn_fixed_asset_create(B1, jsonb_build_object('name', 'Nevera vertical',
    'client_request_id', v_req));
  perform test.chk('1 reintento devuelve la misma ficha', (v->>'id')::uuid = v_id2 and v->>'code' = 'AF-00002');
  perform test.chk('1 reintento no crea otra', (select count(*) from public.fixed_assets where business_id = B1) = 2);
  perform test.chk('1 reintento no deja historia', test.hist(v_id2) = 1);

  -- La numeración es POR NEGOCIO.
  perform test.as_user('66666666-6666-6666-6666-666666666666');
  v := public.fn_fixed_asset_create(B2, jsonb_build_object('name', 'Aire acondicionado', 'warehouse_id', W_B2));
  perform test.chk('1 otro negocio arranca en AF-00001', v->>'code' = 'AF-00001', v::text);
  perform test.chk('1 quién sin nombre de perfil: su correo',
    (select created_by_name from public.fixed_asset_movements where asset_id = (v->>'id')::uuid) = 'dueno@otro.do');

  -- Un código importado alto no se come la secuencia (cast numérico, no texto).
  insert into public.fixed_assets (business_id, code, name) values (B2, 'AF-99999', 'Importado');
  v := public.fn_fixed_asset_create(B2, jsonb_build_object('name', 'Motor de delivery', 'category', 'Vehículo'));
  perform test.chk('1 después de AF-99999 viene AF-100000', v->>'code' = 'AF-100000', v->>'code');
  perform test.as_user('99999999-9999-9999-9999-999999999999');

  -- ── 2. Validaciones del alta ──
  v_msg := test.err(format($q$select public.fn_fixed_asset_create(%L, '{"name":"   "}')$q$, B1));
  perform test.chk('2 nombre obligatorio', v_msg like 'FIXED_ASSET_NAME_REQUIRED%', v_msg);
  v_msg := test.err(format($q$select public.fn_fixed_asset_create(%L, '{"name":"x","purchase_cost":-1}')$q$, B1));
  perform test.chk('2 costo negativo', v_msg like 'FIXED_ASSET_INVALID_COST%', v_msg);
  v_msg := test.err(format($q$select public.fn_fixed_asset_create(%L, '{"name":"x","status":"retired"}')$q$, B1));
  perform test.chk('2 no se da de alta ya dado de baja', v_msg like 'FIXED_ASSET_INVALID_STATUS%', v_msg);
  v_msg := test.err(format($q$select public.fn_fixed_asset_create(%L, %L)$q$, B1,
    jsonb_build_object('name', 'x', 'warehouse_id', W_B2)));
  perform test.chk('2 bodega de otro negocio', v_msg like 'WAREHOUSE_NOT_IN_BUSINESS%', v_msg);
  v_msg := test.err(format($q$select public.fn_fixed_asset_create(%L, %L)$q$, B1,
    jsonb_build_object('name', 'x', 'warehouse_id', W_TRAN)));
  perform test.chk('2 la bodega de tránsito no es un lugar', v_msg like 'WAREHOUSE_NOT_IN_BUSINESS%', v_msg);
  v_msg := test.err(format($q$select public.fn_fixed_asset_create(%L, %L)$q$, B1,
    jsonb_build_object('name', 'x', 'assigned_employee_id', E_B2)));
  perform test.chk('2 empleado de otro negocio', v_msg like 'EMPLOYEE_NOT_IN_BUSINESS%', v_msg);
  perform test.chk('2 los rechazos no dejaron fichas', (select count(*) from public.fixed_assets where business_id = B1) = 2);

  -- ── 3. Edición ──
  v := public.fn_fixed_asset_update(v_id, jsonb_build_object('name', 'Horno combinado',
    'purchase_cost', 900000, 'brand', 'Rational', 'serial_number', null,
    -- Ubicación, responsable y estado se ignoran en la edición.
    'warehouse_id', W_PRIN, 'assigned_employee_id', E_ANA, 'status', 'lost'));
  perform test.chk('3 edita los datos', v->>'name' = 'Horno combinado' and (v->>'purchase_cost')::numeric = 900000
    and v->>'serial_number' is null, v::text);
  perform test.chk('3 no mueve ni cambia estado',
    (v->>'warehouse_id')::uuid = W_COC and (v->>'assigned_employee_id')::uuid = E_JUAN and v->>'status' = 'active', v::text);
  perform test.chk('3 claves ausentes no se tocan', v->>'model' = 'iCombi Pro 6-1/1' and v->>'notes' = 'Mantenimiento cada 6 meses');
  select * into m from public.fixed_asset_movements where asset_id = v_id and event_type = 'updated';
  perform test.chk('3 una fila updated con lo que cambió',
    test.hist(v_id) = 2 and m.changes ? 'name' and m.changes ? 'purchase_cost' and m.changes ? 'serial_number'
    and not (m.changes ? 'brand') and m.changes->'name'->>'from' = 'Horno de convección'
    and m.changes->'name'->>'to' = 'Horno combinado', coalesce(m.changes::text, 'sin fila'));
  v := public.fn_fixed_asset_update(v_id, jsonb_build_object('name', 'Horno combinado', 'brand', 'Rational'));
  perform test.chk('3 guardar sin cambios no deja historia', test.hist(v_id) = 2);
  v_msg := test.err(format($q$select public.fn_fixed_asset_update(%L, '{"name":""}')$q$, v_id));
  perform test.chk('3 no se puede borrar el nombre', v_msg like 'FIXED_ASSET_NAME_REQUIRED%', v_msg);
  v_msg := test.err(format($q$select public.fn_fixed_asset_update(%L, '{"name":"x"}')$q$, gen_random_uuid()));
  perform test.chk('3 ficha inexistente', v_msg like 'FIXED_ASSET_NOT_FOUND%', v_msg);

  -- ── 4. Traslado y reasignación ──
  v := public.fn_fixed_asset_move(v_id, W_PRIN, 'Pasillo de atrás', E_ANA, 'Remodelación de la cocina');
  perform test.chk('4 queda en su nuevo lugar',
    (v->>'warehouse_id')::uuid = W_PRIN and v->>'location_note' = 'Pasillo de atrás'
    and (v->>'assigned_employee_id')::uuid = E_ANA and v->'warehouses'->>'name' = 'Principal', v::text);
  perform test.chk('4 dos filas: relocated + reassigned', test.hist(v_id) = 4);
  select * into m from public.fixed_asset_movements where asset_id = v_id and event_type = 'relocated';
  perform test.chk('4 relocated con de/hacia y la nota',
    m.from_warehouse_name = 'Cocina' and m.to_warehouse_name = 'Principal'
    and m.from_location_note = 'Cocina caliente, junto a la plancha' and m.to_location_note = 'Pasillo de atrás'
    and m.notes = 'Remodelación de la cocina' and m.created_by_name = 'Dueño Penda', m::text);
  select * into m from public.fixed_asset_movements where asset_id = v_id and event_type = 'reassigned';
  perform test.chk('4 reassigned con de/hacia',
    m.from_employee_id = E_JUAN and m.from_employee_name = 'Juan Pérez'
    and m.to_employee_id = E_ANA and m.to_employee_name = 'Ana Gómez', m::text);

  v := public.fn_fixed_asset_move(v_id, W_PRIN, 'Pasillo de atrás', E_ANA, null);
  perform test.chk('4 mover al mismo lugar no deja historia', test.hist(v_id) = 4);
  v := public.fn_fixed_asset_move(v_id, W_PRIN, 'Pasillo de atrás', null, 'Ana renunció');
  perform test.chk('4 quitar responsable: solo reassigned',
    test.hist(v_id) = 5 and v->>'assigned_employee_id' is null and v->'employees' = 'null'::jsonb, v::text);
  v := public.fn_fixed_asset_move(v_id, W_PRIN, '  Depósito  ', null, null);
  perform test.chk('4 cambiar solo la nota de ubicación: relocated',
    test.hist(v_id) = 6 and v->>'location_note' = 'Depósito', v::text);
  v_msg := test.err(format($q$select public.fn_fixed_asset_move(%L, %L, null, null)$q$, v_id, W_B2));
  perform test.chk('4 no se traslada a otro negocio', v_msg like 'WAREHOUSE_NOT_IN_BUSINESS%', v_msg);

  -- ── 5. Estados, baja y reactivación ──
  v := public.fn_fixed_asset_set_status(v_id, 'needs_repair', 'No calienta parejo');
  select * into m from public.fixed_asset_movements where asset_id = v_id order by created_at desc, id limit 1;
  perform test.chk('5 status_changed active → needs_repair',
    v->>'status' = 'needs_repair' and test.hist(v_id) = 7 and m.event_type = 'status_changed'
    and m.from_status = 'active' and m.to_status = 'needs_repair' and m.notes = 'No calienta parejo', m::text);
  v := public.fn_fixed_asset_set_status(v_id, 'needs_repair', null);
  perform test.chk('5 el mismo estado otra vez no deja historia', test.hist(v_id) = 7);
  v_msg := test.err(format($q$select public.fn_fixed_asset_set_status(%L, 'broken')$q$, v_id));
  perform test.chk('5 estado inválido', v_msg like 'FIXED_ASSET_INVALID_STATUS%', v_msg);
  v_msg := test.err(format($q$select public.fn_fixed_asset_set_status(%L, 'retired', '   ')$q$, v_id));
  perform test.chk('5 baja sin motivo se rechaza', v_msg like 'FIXED_ASSET_RETIRE_REASON_REQUIRED%', v_msg);
  perform test.chk('5 el rechazo no cambió nada',
    (select status = 'needs_repair' and retired_at is null from public.fixed_assets where id = v_id) and test.hist(v_id) = 7);

  v := public.fn_fixed_asset_set_status(v_id, 'retired', 'Se vendió como chatarra');
  perform test.chk('5 dado de baja con fecha y motivo',
    v->>'status' = 'retired' and v->>'retired_at' is not null and v->>'retired_reason' = 'Se vendió como chatarra', v::text);
  select * into m from public.fixed_asset_movements where asset_id = v_id and event_type = 'retired';
  perform test.chk('5 historia retired', test.hist(v_id) = 8 and m.from_status = 'needs_repair'
    and m.to_status = 'retired' and m.notes = 'Se vendió como chatarra', coalesce(m::text, 'sin fila'));
  v_msg := test.err(format($q$select public.fn_fixed_asset_move(%L, %L, null, null)$q$, v_id, W_COC));
  perform test.chk('5 lo dado de baja no se traslada', v_msg like 'FIXED_ASSET_RETIRED%', v_msg);

  v := public.fn_fixed_asset_set_status(v_id, 'active', 'Se reparó y volvió');
  perform test.chk('5 reactivar limpia la baja',
    v->>'status' = 'active' and v->>'retired_at' is null and v->>'retired_reason' is null, v::text);
  select * into m from public.fixed_asset_movements where asset_id = v_id and event_type = 'reactivated';
  perform test.chk('5 historia reactivated', test.hist(v_id) = 9 and m.from_status = 'retired'
    and m.to_status = 'active', coalesce(m::text, 'sin fila'));
  perform test.chk('5 la historia completa, en orden',
    (select array_agg(event_type order by created_at, id) from public.fixed_asset_movements where asset_id = v_id)
    @> array['created','updated','relocated','reassigned','status_changed','retired','reactivated']);

  -- ── 6. Quién puede escribir ──
  -- Dueño de OTRO negocio: ni crear en B1 ni tocar fichas de B1.
  perform test.as_user('66666666-6666-6666-6666-666666666666');
  v_msg := test.err(format($q$select public.fn_fixed_asset_create(%L, '{"name":"intruso"}')$q$, B1));
  perform test.chk('6 otro negocio no crea en B1', v_msg like 'NOT_AUTHORIZED%', v_msg);
  v_msg := test.err(format($q$select public.fn_fixed_asset_update(%L, '{"name":"intruso"}')$q$, v_id));
  perform test.chk('6 otro negocio no edita', v_msg like 'NOT_AUTHORIZED%', v_msg);
  v_msg := test.err(format($q$select public.fn_fixed_asset_move(%L, null, null, null)$q$, v_id));
  perform test.chk('6 otro negocio no traslada', v_msg like 'NOT_AUTHORIZED%', v_msg);
  v_msg := test.err(format($q$select public.fn_fixed_asset_set_status(%L, 'lost', 'x')$q$, v_id));
  perform test.chk('6 otro negocio no cambia estado', v_msg like 'NOT_AUTHORIZED%', v_msg);

  -- Mesero de B1 sin el permiso: ve, pero no escribe.
  perform test.as_user('88888888-8888-8888-8888-888888888888');
  v_msg := test.err(format($q$select public.fn_fixed_asset_create(%L, '{"name":"x"}')$q$, B1));
  perform test.chk('6 mesero sin permiso no crea', v_msg like 'FIXED_ASSET_DENIED%', v_msg);
  v_msg := test.err(format($q$select public.fn_fixed_asset_set_status(%L, 'lost', 'x')$q$, v_id));
  perform test.chk('6 mesero sin permiso no cambia estado', v_msg like 'FIXED_ASSET_DENIED%', v_msg);

  -- Cajera con rol a la medida: denegada hasta que el rol trae el permiso.
  perform test.as_user('77777777-7777-7777-7777-777777777777');
  v_msg := test.err(format($q$select public.fn_fixed_asset_create(%L, '{"name":"x"}')$q$, B1));
  perform test.chk('6 cajera sin el permiso en su rol', v_msg like 'FIXED_ASSET_DENIED%', v_msg);
  insert into public.role_permissions (role_id, permission_id, allow)
  select 'c0000000-0000-0000-0000-000000000001', p.id, true
    from public.permissions p where p.code = 'inventario.activos.gestionar';
  v := public.fn_fixed_asset_create(B1, jsonb_build_object('name', 'Licuadora', 'category', 'Equipo de cocina'));
  perform test.chk('6 con inventario.activos.gestionar sí crea (AF-00003)', v->>'code' = 'AF-00003', v::text);
  perform test.chk('6 la historia la firma la empleada',
    (select created_by_name from public.fixed_asset_movements where asset_id = (v->>'id')::uuid) = 'Carla Ruiz');
  perform test.as_user('99999999-9999-9999-9999-999999999999');

  -- ── 7. Nombres de las FK que usa el SELECT de la app como pista del embed
  --       (warehouses!fixed_assets_warehouse_id_fkey, employees!…) ──
  perform test.chk('7 FK con el nombre que espera la app',
    (select count(*) from pg_constraint
      where conrelid = 'public.fixed_assets'::regclass
        and conname in ('fixed_assets_warehouse_id_fkey',
                        'fixed_assets_assigned_employee_id_fkey')) = 2);

  -- ── 7. Permisos en el catálogo ──
  perform test.chk('7 los dos códigos en public.permissions',
    (select count(*) from public.permissions
      where code in ('inventario.activos.acceso','inventario.activos.gestionar') and module = 'inventory') = 2);
  perform test.chk('7 concedidos a owner/admin/manager de sistema de cada negocio (2 × 3 × 2)',
    (select count(*) from public.role_permissions rp
       join public.roles r on r.id = rp.role_id
       join public.permissions p on p.id = rp.permission_id
      where p.code like 'inventario.activos.%' and r.is_system) = 12);
  perform test.chk('7 el mesero de sistema no los recibe',
    not exists (select 1 from public.role_permissions rp
       join public.roles r on r.id = rp.role_id
       join public.permissions p on p.id = rp.permission_id
      where p.code like 'inventario.activos.%' and r.name = 'waiter'));
end $$;
SQL

echo "== RLS y grants como 'authenticated' (lo que ve PostgREST)"
# Supabase le da ALL sobre las tablas nuevas a authenticated por default
# privileges; se simula para que la barrera probada sea el RLS, no el GRANT.
Q -c "grant insert, update, delete on public.fixed_assets, public.fixed_asset_movements to authenticated;" \
  >/dev/null || bad "grants de supabase"
run "lectura aislada por negocio" <<'SQL'
begin;
set local test.uid = '99999999-9999-9999-9999-999999999999';
set local role authenticated;
do $$ begin
  perform test.chk('rls B1 ve sus 3 fichas y ninguna de B2',
    (select count(*) from public.fixed_assets) = 3
    and not exists (select 1 from public.fixed_assets where business_id <> '11111111-1111-1111-1111-111111111111'));
  perform test.chk('rls B1 ve solo su historia',
    (select count(*) from public.fixed_asset_movements) > 0
    and not exists (select 1 from public.fixed_asset_movements
                     where business_id <> '11111111-1111-1111-1111-111111111111'));
end $$;
commit;
begin;
set local test.uid = '66666666-6666-6666-6666-666666666666';
set local role authenticated;
do $$ begin
  perform test.chk('rls B2 ve solo sus 3 fichas',
    (select count(*) from public.fixed_assets) = 3
    and not exists (select 1 from public.fixed_assets where business_id <> '22222222-2222-2222-2222-222222222222'));
end $$;
commit;
begin;
set local test.uid = '88888888-8888-8888-8888-888888888888';
set local role authenticated;
do $$ begin
  perform test.chk('rls el mesero de B1 también LEE (solo escribir está gateado)',
    (select count(*) from public.fixed_assets) = 3);
end $$;
commit;
begin;
set local test.uid = '12345678-1234-1234-1234-123456789012';
set local role authenticated;
do $$ begin
  perform test.chk('rls un usuario sin negocio no ve nada', (select count(*) from public.fixed_assets) = 0);
end $$;
commit;
SQL
run "escritura directa bloqueada; RPC sí" <<'SQL'
begin;
set local test.uid = '99999999-9999-9999-9999-999999999999';
set local role authenticated;
do $$
declare v_msg text; v jsonb;
begin
  v_msg := test.err($q$insert into public.fixed_assets (business_id, code, name)
    values ('11111111-1111-1111-1111-111111111111', 'AF-77777', 'directo')$q$);
  perform test.chk('insert directo rechazado por RLS', v_msg like '%row-level security%', coalesce(v_msg, 'pasó'));
  v_msg := test.err($q$update public.fixed_assets set status = 'lost'$q$);
  perform test.chk('update directo no toca nada',
    v_msg is null and not exists (select 1 from public.fixed_assets where status = 'lost'), coalesce(v_msg, ''));
  v_msg := test.err($q$delete from public.fixed_asset_movements$q$);
  perform test.chk('la historia no se puede borrar',
    (select count(*) from public.fixed_asset_movements) > 0, coalesce(v_msg, ''));
  v_msg := test.err($q$select public.fn_fixed_asset_log(gen_random_uuid(),
    '11111111-1111-1111-1111-111111111111', 'created')$q$);
  perform test.chk('el helper de historia no es API', v_msg like 'permission denied%', coalesce(v_msg, 'pasó'));
  v_msg := test.err($q$select public.fn_fixed_asset_can_manage('11111111-1111-1111-1111-111111111111')$q$);
  perform test.chk('el helper de permiso no es API', v_msg like 'permission denied%', coalesce(v_msg, 'pasó'));
  v := public.fn_fixed_asset_create('11111111-1111-1111-1111-111111111111',
         '{"name":"TV de la barra","category":"Electrónica"}');
  perform test.chk('el RPC funciona con el rol authenticated', v->>'code' = 'AF-00004', v::text);
end $$;
commit;
begin;
set local role anon;
do $$
declare v_msg text;
begin
  v_msg := test.err($q$select public.fn_fixed_asset_create('11111111-1111-1111-1111-111111111111', '{"name":"x"}')$q$);
  perform test.chk('anon no ejecuta los RPC', v_msg like 'permission denied%', coalesce(v_msg, 'pasó'));
end $$;
commit;
SQL

echo "== Idempotencia con datos"
run "re-aplicar con datos cargados" -f "$MIG"
run "los datos siguen y la secuencia también" <<'SQL'
do $$
declare v jsonb;
begin
  perform test.as_user('99999999-9999-9999-9999-999999999999');
  perform test.chk('fichas intactas',
    (select count(*) from public.fixed_assets where business_id = '11111111-1111-1111-1111-111111111111') = 4);
  v := public.fn_fixed_asset_create('11111111-1111-1111-1111-111111111111', '{"name":"Silla alta"}');
  perform test.chk('sigue en AF-00005', v->>'code' = 'AF-00005', v::text);
  perform test.chk('permisos sin duplicar',
    (select count(*) from public.permissions where code like 'inventario.activos.%') = 2);
end $$;
SQL

echo "== Rollback"
run "rollback aplica"          -f "$RB"
run "rollback otra vez (limpio)" -f "$RB"
run "no queda nada" <<'SQL'
do $$ begin
  perform test.chk('tablas fuera',
    to_regclass('public.fixed_assets') is null and to_regclass('public.fixed_asset_movements') is null);
  perform test.chk('funciones fuera',
    not exists (select 1 from pg_proc where proname like 'fn_fixed_asset%'));
  perform test.chk('los permisos se quedan (a propósito)',
    (select count(*) from public.permissions where code like 'inventario.activos.%') = 2);
end $$;
SQL
run "re-instalar después del rollback" -f "$MIG"
run "instalación limpia arranca en AF-00001" <<'SQL'
do $$
declare v jsonb;
begin
  perform test.as_user('99999999-9999-9999-9999-999999999999');
  v := public.fn_fixed_asset_create('11111111-1111-1111-1111-111111111111', '{"name":"Freidora"}');
  perform test.chk('AF-00001 otra vez', v->>'code' = 'AF-00001', v::text);
end $$;
SQL

echo
if [ "$FAIL" = 0 ]; then echo "TODO OK"; else echo "HAY FALLAS"; fi
exit $FAIL
