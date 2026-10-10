#!/usr/bin/env bash
# Postgres local desechable; no toca ninguna base remota.
# Prueba 20261010_0006 (T04): ediciones versionadas con las funciones de
# edición y el cobro VIVOS (fixtures/live_order_edit_functions_20261010.sql),
# los cuerpos reales de membresía y de fn_close_order_and_table, y dobles
# simples para totales e impuestos.
set -euo pipefail
REPO=$(cd "$(dirname "$0")/../.." && pwd)
M=$REPO/supabase/migrations
PG=${PG_BIN:-/opt/homebrew/opt/postgresql@15/bin}
PORT=${PG_PORT:-55465}
WORK=${1:-$(mktemp -d)}
D=$WORK/pg_versioned_edits
mkdir -p "$D"
"$PG/initdb" -D "$D/data" -U postgres --auth=trust >/dev/null
"$PG/pg_ctl" -D "$D/data" -o "-p $PORT -c listen_addresses=127.0.0.1 -c unix_socket_directories=''" -l "$D/log" start -w >/dev/null
trap '"$PG/pg_ctl" -D "$D/data" stop -m fast >/dev/null 2>&1' EXIT
Q() { "$PG/psql" -h 127.0.0.1 -p "$PORT" -U postgres -X -q -v ON_ERROR_STOP=1 "$@"; }
QU() { local uid=$1; shift; PGOPTIONS="-c request.jwt.claim.sub=$uid -c request.jwt.claim.role=authenticated" Q "$@"; }
MEMBER=a0000000-0000-0000-0000-000000000001
OUTSIDER=a0000000-0000-0000-0000-000000000004

Q <<'SQL'
create role anon; create role authenticated; create role service_role;
alter default privileges in schema public grant all on functions to anon, authenticated, service_role;
create schema auth;
grant usage on schema auth to anon, authenticated, service_role;
create function auth.uid() returns uuid language sql stable as $$
  select nullif(nullif(current_setting('request.jwt.claim.sub', true), ''), '')::uuid
$$;
create function auth.role() returns text language sql stable as $$
  select nullif(current_setting('request.jwt.claim.role', true), '')
$$;
create type public.order_status as enum ('open','sent_to_kitchen','partially_paid','paid','void');
create type public.item_status as enum ('pending','preparing','ready','served','void','draft','paid');
create type public.ncf_type as enum ('B01','B02','E31','E32');
create table public.businesses(id uuid primary key, owner_id uuid);
create table public.memberships(user_id uuid not null, business_id uuid not null);
create table public.user_businesses(user_id uuid not null, business_id uuid not null,
  shared_across_branches boolean not null default false);
create table public.zones(id uuid primary key default gen_random_uuid(), business_id uuid not null);
create table public.dining_tables(id uuid primary key default gen_random_uuid(),
  zone_id uuid not null references public.zones(id), state text not null default 'occupied');
create table public.customers(id uuid primary key default gen_random_uuid(), business_id uuid, name text);
create table public.table_sessions(id uuid primary key default gen_random_uuid(),
  table_id uuid references public.dining_tables(id), business_id uuid,
  opened_at timestamptz not null default now(), closed_at timestamptz,
  customer_id uuid, customer_name text, note text);
create table public.orders(id uuid primary key default gen_random_uuid(),
  session_id uuid not null references public.table_sessions(id), status text not null default 'open',
  status_ext public.order_status not null default 'open', created_at timestamptz default now(),
  closed_at timestamptz, subtotal numeric not null default 0, discounts numeric not null default 0,
  tax numeric not null default 0, total numeric not null default 0,
  delivery_fee numeric not null default 0, tip numeric not null default 0,
  is_sales_note boolean not null default false);
create table public.order_checks(id uuid primary key default gen_random_uuid(),
  order_id uuid not null references public.orders(id), label text not null default 'Cuenta',
  position integer not null default 1, is_closed boolean not null default false,
  closed_at timestamptz, total numeric not null default 0, customer_id uuid, customer_name text,
  customer_rnc text, requested_ncf_type public.ncf_type);
create table public.order_items(id uuid primary key default gen_random_uuid(),
  order_id uuid references public.orders(id), product_id uuid default gen_random_uuid(),
  quantity numeric not null default 1, qty numeric default 1, unit_price numeric not null default 100,
  check_id uuid, product_name text default 'Producto', sku text, is_takeout boolean not null default false,
  status public.item_status default 'draft', notes text, subtotal numeric, discounts numeric default 0,
  tax numeric default 0, created_at timestamptz default now(), tax_mode text not null default 'exclusive',
  tax_rate numeric not null default 0, original_tax_rate numeric, kitchen_sent_at timestamptz);
create table public.order_item_modifiers(id uuid primary key default gen_random_uuid(),
  item_id uuid references public.order_items(id) on delete cascade, name text, qty numeric, price numeric,
  menu_item_id uuid, modifier_id uuid);
create table public.taxes(id uuid primary key default gen_random_uuid(), business_id uuid);
create table public.order_excluded_taxes(order_id uuid, tax_id uuid, excluded_by uuid,
  unique (order_id, tax_id));
create table public.fiscal_documents(id uuid primary key default gen_random_uuid(), order_id uuid,
  check_id uuid, ncf_number text, status text default 'active');
create table public.payment_methods(id uuid primary key default gen_random_uuid(), business_id uuid,
  code text, is_active boolean default true);
create table public.cash_register_sessions(id uuid primary key default gen_random_uuid(),
  status text default 'open', closed_at timestamptz);
create table public.cash_transactions(id uuid primary key default gen_random_uuid(), session_id uuid,
  amount numeric, type text, description text, related_order_id uuid, created_at timestamptz);
create table public.payments(id uuid primary key default gen_random_uuid(), business_id uuid not null,
  order_id uuid, check_id uuid, fiscal_document_id uuid, payment_method_id uuid, amount numeric not null,
  reference text, change_amount numeric, status text, processed_by uuid, session_id uuid,
  created_at timestamptz, customer_id uuid, customer_rnc text, requested_ncf_type public.ncf_type,
  split_sequence smallint not null default 0, offline_ncf text);

-- Dobles de lo que no se prueba aquí (totales e impuestos).
create function public.trg_test_item_totals() returns trigger language plpgsql as $$
begin
  new.subtotal := new.unit_price * coalesce(new.qty, new.quantity, 1);
  new.tax := 0;
  return new;
end $$;
create trigger trg_compute_item_totals before insert or update on public.order_items
  for each row execute function public.trg_test_item_totals();
create function public.fn_recalc_order_totals(p uuid) returns void language sql as $$
  update public.orders o set subtotal = coalesce((select sum(subtotal) from public.order_items
    where order_id = p and status::text <> 'void'), 0),
    total = coalesce((select sum(subtotal - coalesce(discounts, 0)) from public.order_items
    where order_id = p and status::text <> 'void'), 0) + o.delivery_fee
  where o.id = p
$$;
create function public.calculate_order_totals(p uuid) returns void language sql as $$
  select public.fn_recalc_order_totals(p)
$$;
create function public.calculate_check_totals(p uuid) returns void language sql as $$ select $$;
create function public.fn_populate_item_tax_lines(p uuid) returns void language sql as $$ select $$;
-- Doble de la función viva de unir líneas: suma en el que queda y borra las
-- demás (lo que importa aquí es QUÉ se le pasa).
create function public.fn_consolidate_keeper_atomic(p_keeper uuid, p_remove uuid[],
  p_qty numeric, p_discounts numeric) returns void language plpgsql as $$
begin
  update public.order_items set qty = p_qty, quantity = round(p_qty), discounts = p_discounts
   where id = p_keeper;
  delete from public.order_items where id = any(p_remove) and id <> p_keeper;
end $$;
create function public.fn_resolve_order_item_tax_profile(p_product uuid, p_order uuid, p_takeout boolean)
  returns table(tax_mode text, tax_rate numeric) language sql as $$
  select 'exclusive'::text, case when p_takeout then 0 else 0.18 end::numeric
$$;
create function public.fn_get_or_create_check(p_order uuid, p_position integer) returns uuid
language plpgsql as $$
declare v uuid;
begin
  select id into v from public.order_checks where order_id = p_order and position = p_position;
  if v is null then
    insert into public.order_checks(order_id, position) values (p_order, p_position) returning id into v;
  end if;
  return v;
end $$;
create function public.fn_user_effective_permissions(p_user uuid, p_business uuid)
  returns table(code text, allowed boolean) language sql as $$
  select 'ventas.orden.eliminar_item'::text, true
$$;
create function public.user_has_business_access(p_user uuid, p_business uuid) returns boolean
  language sql as $$ select true $$;
create function public.normalize_ncf_type(p text) returns public.ncf_type language sql as $$
  select nullif(trim(coalesce(p, '')), '')::public.ncf_type
$$;
create function public.test_assert(ok boolean, message text) returns void language plpgsql as $$
begin
  if not coalesce(ok, false) then raise exception 'FAIL: %', message; end if;
  raise notice 'ok: %', message;
end $$;
insert into businesses values ('b0000000-0000-0000-0000-000000000001', 'a0000000-0000-0000-0000-000000000009');
insert into user_businesses values ('a0000000-0000-0000-0000-000000000001', 'b0000000-0000-0000-0000-000000000001', false);
insert into zones(id, business_id) values ('c0000000-0000-0000-0000-000000000001', 'b0000000-0000-0000-0000-000000000001');
insert into payment_methods(business_id, code) values ('b0000000-0000-0000-0000-000000000001', 'cash');
insert into cash_register_sessions(id) values ('d0000000-0000-0000-0000-000000000001');
insert into customers(id, business_id, name) values ('e0000000-0000-0000-0000-000000000001',
  'b0000000-0000-0000-0000-000000000001', 'Ana');
insert into taxes(id, business_id) values ('f0000000-0000-0000-0000-000000000001',
  'b0000000-0000-0000-0000-000000000001');
create table public.test_ids(name text primary key, id uuid);
-- Una cuenta con una línea de 2 a 100. Devuelve la orden.
create function public.test_order(p_name text) returns uuid language plpgsql as $$
declare t uuid; s uuid; o uuid; i uuid;
begin
  insert into dining_tables(zone_id) values ('c0000000-0000-0000-0000-000000000001') returning id into t;
  insert into table_sessions(table_id, business_id) values (t, 'b0000000-0000-0000-0000-000000000001')
    returning id into s;
  insert into orders(session_id) values (s) returning id into o;
  insert into order_items(order_id, qty, quantity) values (o, 2, 2) returning id into i;
  perform public.fn_recalc_order_totals(o);
  insert into test_ids values (p_name, o), (p_name || ':item', i);
  return o;
end $$;
create function public.tid_of(p text) returns uuid language sql stable as $$
  select id from public.test_ids where name = p
$$;
SQL

python3 - "$REPO/supabase" "$D/base.sql" <<'PY'
from pathlib import Path
import sys
root, out = Path(sys.argv[1]), Path(sys.argv[2])
def cut(rel, start, end_marker='$$;'):
    s = (root / rel).read_text()
    a = s.index(start)
    return s[a:s.index(end_marker, a) + len(end_marker)] + '\n'
out.write_text(
    cut('migrations/20260709_0001_shared_user_across_branches.sql',
        'create or replace function public.current_user_business_ids()') +
    cut('migrations/20260709_0001_shared_user_across_branches.sql',
        'create or replace function public.is_member_of_business(p_business uuid)') +
    cut('migrations/20260624_0001_close_checks_on_order_close.sql',
        'CREATE OR REPLACE FUNCTION public.fn_close_order_and_table(', '$function$;'))
PY
Q -f "$D/base.sql" >/dev/null
Q -f "$REPO/supabase/tests/fixtures/live_order_edit_functions_20261010.sql" >/dev/null
Q -f "$M/20261010_0006_versioned_order_edits.sql"
Q -f "$M/20261010_0006_versioned_order_edits.sql"

Q <<'SQL'
create function public.edit(p_op uuid, p_order text, p_kind text, p_target uuid, p_base bigint,
  p_args jsonb default '{}'::jsonb, p_expected jsonb default null, p_force boolean default false)
returns jsonb language sql as $$
  select public.fn_apply_order_edit(p_op, public.tid_of(p_order), p_kind, p_target, p_base,
    p_expected, p_args, p_force)
$$;
create function public.item_version(p text) returns bigint language sql stable as $$
  select version from public.order_items where id = public.tid_of(p || ':item')
$$;
create function public.item_qty(p text) returns numeric language sql stable as $$
  select qty from public.order_items where id = public.tid_of(p || ':item')
$$;
SQL

Q <<'SQL'
do $$
declare r jsonb; r2 jsonb; v bigint; op uuid := gen_random_uuid(); extra uuid;
begin
  -- Edición con la versión vigente.
  perform test_order('basic');
  v := item_version('basic');
  r := edit(op, 'basic', 'qty', tid_of('basic:item'), v, '{"qty": 3}');
  perform test_assert(r ->> 'status' = 'applied' and item_qty('basic') = 3
    and (r ->> 'version')::bigint = v + 1 and item_version('basic') = v + 1,
    'an edit on the current version applies and bumps the line version');

  -- Reintento (respuesta perdida): mismo resultado, sin aplicar otra vez.
  r2 := edit(op, 'basic', 'qty', tid_of('basic:item'), v, '{"qty": 3}');
  perform test_assert((r2 ->> 'replayed')::boolean and r2 ->> 'status' = 'applied'
    and item_version('basic') = v + 1,
    'a repeated operation returns its result without applying twice');

  -- Respuestas invertidas: dos terminales leyeron la misma versión.
  perform test_order('race');
  v := item_version('race');
  r := edit(gen_random_uuid(), 'race', 'qty', tid_of('race:item'), v, '{"qty": 3}');
  r2 := edit(gen_random_uuid(), 'race', 'qty', tid_of('race:item'), v, '{"qty": 5}');
  perform test_assert(r ->> 'status' = 'applied' and r2 ->> 'status' = 'conflict'
    and r2 ->> 'reason' = 'stale_version' and item_qty('race') = 3
    and (r2 -> 'current' ->> 'qty')::numeric = 3,
    'the older edit never overwrites the newer one: conflict with the current state');
  r := edit(gen_random_uuid(), 'race', 'qty', tid_of('race:item'), null, '{"qty": 5}', null, true);
  perform test_assert(r ->> 'status' = 'applied' and item_qty('race') = 5,
    'the operator explicitly applies their change over the current version');

  -- Línea creada sin red (sin versión): compara lo que el operador veía.
  perform test_order('valued');
  r := edit(gen_random_uuid(), 'valued', 'qty', tid_of('valued:item'), null, '{"qty": 4}', '{"qty": 2}');
  perform test_assert(r ->> 'status' = 'applied' and item_qty('valued') = 4,
    'without a version, the expected value matches: applied');
  r := edit(gen_random_uuid(), 'valued', 'qty', tid_of('valued:item'), null, '{"qty": 6}', '{"qty": 2}');
  perform test_assert(r ->> 'status' = 'conflict' and r ->> 'reason' = 'stale_value' and item_qty('valued') = 4,
    'without a version, a changed value is a conflict');
  begin
    perform edit(gen_random_uuid(), 'valued', 'qty', tid_of('valued:item'), null, '{"qty": 6}');
    raise exception 'FAIL: an edit without base was accepted';
  exception when others then
    perform test_assert(sqlerrm like 'EDIT_BASE_REQUIRED%', 'an edit needs a version or the values it saw');
  end;

  -- Cada tipo de línea pasa por su función viva.
  perform test_order('kinds');
  v := item_version('kinds');
  r := edit(gen_random_uuid(), 'kinds', 'notes', tid_of('kinds:item'), v, '{"notes": "sin sal"}');
  v := (r ->> 'version')::bigint;
  r := edit(gen_random_uuid(), 'kinds', 'takeout', tid_of('kinds:item'), v, '{"is_takeout": true}');
  v := (r ->> 'version')::bigint;
  r := edit(gen_random_uuid(), 'kinds', 'discount_notes', tid_of('kinds:item'), v,
            '{"discounts": 10, "notes": "cortesía"}');
  v := (r ->> 'version')::bigint;
  r := edit(gen_random_uuid(), 'kinds', 'details', tid_of('kinds:item'), v,
            '{"product_name": "Pollo", "qty": 4, "is_takeout": false, "discounts": 0, "notes": null}');
  v := (r ->> 'version')::bigint;
  r := edit(gen_random_uuid(), 'kinds', 'modifiers', tid_of('kinds:item'), v,
            '{"modifiers": [{"name": "Queso", "qty": 1, "price": 25}]}');
  v := (r ->> 'version')::bigint;
  r := edit(gen_random_uuid(), 'kinds', 'move', tid_of('kinds:item'), v, '{"check_position": 2}');
  perform test_assert(r ->> 'status' = 'applied'
    and (select qty = 4 and not is_takeout and product_name = 'Pollo' and notes is null
           and check_id is not null from order_items where id = tid_of('kinds:item'))
    and (select count(*) = 1 from order_item_modifiers where item_id = tid_of('kinds:item')),
    'notes, takeout, discount, details, modifiers and move apply through the live functions');

  -- Lo que no edita el operador no cambia la versión: cocina y cobro.
  perform test_order('kitchen');
  v := item_version('kitchen');
  update order_items set status = 'pending', kitchen_sent_at = now() where id = tid_of('kitchen:item');
  perform test_assert(item_version('kitchen') = v, 'sending to the kitchen does not bump the version');

  -- Una escritura de la app anterior (sin versión) sí cambia la versión.
  perform test_order('legacy');
  v := item_version('legacy');
  perform fn_update_item_qty(tid_of('legacy:item'), 7);
  r := edit(gen_random_uuid(), 'legacy', 'qty', tid_of('legacy:item'), v, '{"qty": 3}');
  perform test_assert(r ->> 'status' = 'conflict' and item_qty('legacy') = 7,
    'an old-app write changes the version: a stale edit from the new app is rejected');
  v := item_version('legacy');
  insert into order_item_modifiers(item_id, name, qty, price) values (tid_of('legacy:item'), 'Extra', 1, 5);
  perform test_assert(item_version('legacy') > v, 'adding an extra directly also bumps the line');

  -- Borrar: aplicado; otra vez, ya estaba; editarla después, conflicto.
  perform test_order('delete');
  r := edit(gen_random_uuid(), 'delete', 'delete', tid_of('delete:item'), item_version('delete'));
  r2 := edit(gen_random_uuid(), 'delete', 'delete', tid_of('delete:item'), 1);
  perform test_assert(r ->> 'status' = 'applied' and r2 ->> 'reason' = 'already_deleted'
    and not exists (select 1 from order_items where id = tid_of('delete:item')),
    'deleting a line already deleted by another terminal fulfils the intent');
  r := edit(gen_random_uuid(), 'delete', 'qty', tid_of('delete:item'), 1, '{"qty": 2}');
  perform test_assert(r ->> 'reason' = 'item_missing', 'editing a deleted line is a conflict');

  -- Nivel cuenta: delivery, nota, cliente, impuestos excluidos, cliente de subcuenta.
  perform test_order('order');
  v := (select version from orders where id = tid_of('order'));
  r := edit(gen_random_uuid(), 'order', 'delivery_fee', null, v, '{"amount": 50}');
  perform test_assert(r ->> 'status' = 'applied'
    and (select delivery_fee = 50 and version > v from orders where id = tid_of('order')),
    'delivery fee applies and bumps the order version');
  r2 := edit(gen_random_uuid(), 'order', 'session_customer', null, v,
            '{"customer_id": "e0000000-0000-0000-0000-000000000001", "customer_name": "Ana"}');
  perform test_assert(r2 ->> 'status' = 'conflict' and r2 ->> 'reason' = 'stale_version',
    'an order-level edit on an old order version is a conflict');
  v := (r ->> 'version')::bigint;
  r := edit(gen_random_uuid(), 'order', 'session_customer', null, v,
            '{"customer_id": "e0000000-0000-0000-0000-000000000001", "customer_name": "Ana"}');
  v := (r ->> 'version')::bigint;
  r := edit(gen_random_uuid(), 'order', 'excluded_taxes', null, v,
            '{"tax_ids": ["f0000000-0000-0000-0000-000000000001"]}');
  v := (r ->> 'version')::bigint;
  insert into order_checks(order_id, position) values (tid_of('order'), 2);
  r := edit(gen_random_uuid(), 'order', 'check_customer',
            (select id from order_checks where order_id = tid_of('order') and position = 2), v,
            '{"customer_id": "e0000000-0000-0000-0000-000000000001", "customer_name": "Ana", "customer_rnc": "101"}');
  perform test_assert(r ->> 'status' = 'applied'
    and (select customer_name = 'Ana' from table_sessions ts
           join orders o on o.session_id = ts.id where o.id = tid_of('order'))
    and exists (select 1 from order_excluded_taxes where order_id = tid_of('order'))
    and exists (select 1 from order_checks where order_id = tid_of('order') and customer_rnc = '101'),
    'customer, excluded taxes and check customer apply in sequence on fresh versions');
  begin
    perform edit(gen_random_uuid(), 'order', 'session_note', null, (r ->> 'version')::bigint,
                 '{"note": "pisada"}');
    raise exception 'FAIL: absolute note write accepted';
  exception when others then
    perform test_assert(sqlerrm like 'EDIT_KIND_UNKNOWN%',
      'the session note is never overwritten as a whole');
  end;

  -- Auditoría: dos líneas no se pisan (se agregan en una sola sentencia).
  perform fn_append_session_note(
    (select session_id from orders where id = tid_of('order')), '[ANULACION] uno');
  perform fn_append_session_note(
    (select session_id from orders where id = tid_of('order')), '[ACCESO_MESA] dos');
  perform test_assert((select note = E'[ANULACION] uno\n[ACCESO_MESA] dos' from table_sessions ts
           join orders o on o.session_id = ts.id where o.id = tid_of('order')),
    'audit lines are appended, never replacing the note');

  -- Unir líneas de una subcuenta: con lo que hay AHORA, no con lo leído.
  perform test_order('merge');
  insert into order_checks(order_id, position) values (tid_of('merge'), 2);
  update order_items set check_id = (select id from order_checks where order_id = tid_of('merge') and position = 2),
         qty = 1, quantity = 1, created_at = now() - interval '1 minute'
   where id = tid_of('merge:item');
  insert into order_items(order_id, product_id, qty, quantity, check_id)
  values (tid_of('merge'), (select product_id from order_items where id = tid_of('merge:item')), 1, 1,
          (select id from order_checks where order_id = tid_of('merge') and position = 2))
  returning id into extra;
  -- Otro equipo sube la segunda línea a 3 después de que esta leyó 1 + 1.
  perform fn_update_item_qty(extra, 3);
  r := edit(gen_random_uuid(), 'merge', 'consolidate_check',
            (select id from order_checks where order_id = tid_of('merge') and position = 2), null);
  perform test_assert(r ->> 'status' = 'applied' and (r ->> 'merged')::int = 1
    and item_qty('merge') = 4
    and not exists (select 1 from order_items where id = extra)
    and r -> 'removed' ? extra::text
    and (r -> 'versions' ->> tid_of('merge:item')::text)::bigint = item_version('merge'),
    'consolidation sums the current quantities (1 + 3), not what the terminal read');
  insert into order_items(order_id, product_id, qty, quantity, check_id)
  values (tid_of('merge'), (select product_id from order_items where id = tid_of('merge:item')), 1, 1,
          (select id from order_checks where order_id = tid_of('merge') and position = 2))
  returning id into extra;
  insert into order_item_modifiers(item_id, name, qty, price) values (extra, 'Queso', 1, 25);
  r := edit(gen_random_uuid(), 'merge', 'consolidate_check',
            (select id from order_checks where order_id = tid_of('merge') and position = 2), null);
  perform test_assert((r ->> 'merged')::int = 0 and exists (select 1 from order_items where id = extra),
    'a line with extras is never merged into another');

  -- Mover varias líneas: cada una con su versión.
  perform test_order('batch');
  insert into order_items(order_id) values (tid_of('batch')) returning id into extra;
  r := fn_apply_order_edit(gen_random_uuid(), tid_of('batch'), 'move_batch', null, null, null,
         jsonb_build_object('check_position', 3, 'items', jsonb_build_array(
           jsonb_build_object('id', tid_of('batch:item'), 'version', item_version('batch')),
           jsonb_build_object('id', extra, 'version', 99))));
  perform test_assert(r ->> 'status' = 'conflict' and (select check_id is null from order_items where id = extra),
    'a batch move with one stale line moves nothing');

  -- Cuenta cerrada: nada se edita.
  perform test_order('closed');
  update orders set status_ext = 'paid', closed_at = now() where id = tid_of('closed');
  r := edit(gen_random_uuid(), 'closed', 'qty', tid_of('closed:item'), item_version('closed'), '{"qty": 9}');
  perform test_assert(r ->> 'reason' = 'order_closed' and item_qty('closed') = 2,
    'a paid order is never edited');

  -- Un id de operación no se reutiliza para otra cosa.
  begin
    perform edit(op, 'basic', 'notes', tid_of('basic:item'), item_version('basic'), '{"notes": "x"}');
    raise exception 'FAIL: op id reused';
  exception when others then
    perform test_assert(sqlerrm = 'EDIT_OP_ID_CONFLICT', 'an operation id cannot be reused for another edit');
  end;

  perform test_order('pay_first');
  perform test_order('edit_first');
  perform test_order('member');
  perform test_order('outsider');
end $$;
SQL

# Dos terminales: una cobra (con el candado de la orden) y otra edita.
Q -c "begin; select fn_process_payment_v3(tid_of('pay_first'), null, 'cash', 200, null,
  p_cashier_session_id => 'd0000000-0000-0000-0000-000000000001'); select pg_sleep(2); commit;" >/dev/null &
PAY=$!
sleep 0.5
r=$(Q -t -A -c "select edit(gen_random_uuid(), 'pay_first', 'qty', tid_of('pay_first:item'), item_version('pay_first'), '{\"qty\": 5}') ->> 'reason'")
wait "$PAY"
[ "$r" = "order_closed" ] || { echo "FAIL: edit ran over a concurrent payment ($r)"; exit 1; }
echo "ok: payment first: the concurrent edit waits and finds the order closed"

Q -c "begin; select edit(gen_random_uuid(), 'edit_first', 'qty', tid_of('edit_first:item'), item_version('edit_first'), '{\"qty\": 5}'); select pg_sleep(2); commit;" >/dev/null &
EDIT=$!
sleep 0.5
if Q -c "select fn_process_payment_v3(tid_of('edit_first'), null, 'cash', 200, null,
  p_cashier_session_id => 'd0000000-0000-0000-0000-000000000001')" >"$D/out.txt" 2>&1; then
  wait "$EDIT"; echo "FAIL: payment for the old total closed an order that grew"; exit 1
fi
wait "$EDIT"
grep -q ORDER_PAYMENT_UNDERCOVERED "$D/out.txt" || { cat "$D/out.txt"; echo "FAIL: expected UNDERCOVERED"; exit 1; }
echo "ok: edit first: the payment waits, sees the new quantity and refuses the old total"

# Membresía y permisos.
r=$(QU "$MEMBER" -t -A -c "select edit(gen_random_uuid(), 'member', 'notes', tid_of('member:item'), item_version('member'), '{\"notes\": \"ok\"}') ->> 'status'")
[ "$r" = "applied" ] || { echo "FAIL: member could not edit ($r)"; exit 1; }
echo "ok: a member of the business edits"
if QU "$OUTSIDER" -c "select edit(gen_random_uuid(), 'outsider', 'notes', tid_of('outsider:item'), item_version('outsider'), '{\"notes\": \"x\"}')" >"$D/out.txt" 2>&1; then
  echo "FAIL: outsider edited"; exit 1
fi
grep -q UNAUTHORIZED_BUSINESS "$D/out.txt" || { cat "$D/out.txt"; echo "FAIL: expected UNAUTHORIZED_BUSINESS"; exit 1; }
echo "ok: an outsider is rejected"
Q <<'SQL'
do $$ begin
  perform test_assert(
    not has_function_privilege('anon', 'public.fn_apply_order_edit(uuid, uuid, text, uuid, bigint, jsonb, jsonb, boolean)', 'execute')
    and has_function_privilege('authenticated', 'public.fn_apply_order_edit(uuid, uuid, text, uuid, bigint, jsonb, jsonb, boolean)', 'execute'),
    'anon cannot execute; authenticated can');
end $$;
SQL

# 20261010_0007: cerrar las ediciones directas.
# Salvaguarda: una función INVOKER que dependa de ellas detiene la migración.
Q -c "create function public.test_invoker_uses_delete(p uuid) returns void
  language sql as \$\$ select public.fn_delete_item(p) \$\$;"
if Q -f "$M/20261010_0007_close_direct_order_edits.sql" >"$D/out.txt" 2>&1; then
  echo "FAIL: 0005 closed a function an invoker function depends on"; exit 1
fi
grep -q "test_invoker_uses_delete" "$D/out.txt" || { cat "$D/out.txt"; echo "FAIL: expected the guard"; exit 1; }
echo "ok: 0005 stops if an invoker function depends on a direct edit"
Q -c "drop function public.test_invoker_uses_delete(uuid)"
Q -f "$M/20261010_0007_close_direct_order_edits.sql"
Q -f "$M/20261010_0007_close_direct_order_edits.sql"
Q -c "select test_order('closed_direct')" >/dev/null
OID=$(Q -t -A -c "select tid_of('closed_direct')")
IID=$(Q -t -A -c "select tid_of('closed_direct:item')")
VER=$(Q -t -A -c "select item_version('closed_direct')")
r=$(QU "$MEMBER" -t -A -c "set role authenticated; select fn_apply_order_edit(gen_random_uuid(), '$OID', 'qty', '$IID', $VER, null, '{\"qty\": 6}') ->> 'status'" | tail -1)
[ "$r" = "applied" ] || { echo "FAIL: the gateway stopped working after 0005 ($r)"; exit 1; }
echo "ok: after 0005 the app still edits through the gateway"
if QU "$MEMBER" -c "set role authenticated; select fn_update_item_qty('$IID', 9)" >"$D/out.txt" 2>&1; then
  echo "FAIL: a direct edit is still open after 0005"; exit 1
fi
grep -q "permission denied" "$D/out.txt" || { cat "$D/out.txt"; echo "FAIL: expected permission denied"; exit 1; }
echo "ok: after 0005 a direct edit (old app) is rejected"
Q <<'SQL'
do $$ begin
  perform test_assert(
    has_function_privilege('authenticated', 'public.fn_replace_order_item_modifiers(uuid, jsonb)', 'execute')
    and has_function_privilege('service_role', 'public.fn_delete_item(uuid)', 'execute')
    and not has_function_privilege('anon', 'public.fn_delete_item(uuid)', 'execute'),
    'new-item modifiers stay open; service_role keeps the direct functions');
end $$;
SQL
Q -f "$M/20261010_0007_close_direct_order_edits_ROLLBACK.sql"
QU "$MEMBER" -c "set role authenticated; select fn_update_item_qty('$IID', 9)" >/dev/null
echo "ok: the 0005 rollback reopens the direct functions"

Q -f "$M/20261010_0006_versioned_order_edits_ROLLBACK.sql"
Q <<'SQL'
do $$ begin
  perform test_assert(to_regprocedure('public.fn_apply_order_edit(uuid, uuid, text, uuid, bigint, jsonb, jsonb, boolean)') is null
    and not exists (select 1 from information_schema.columns
                     where table_name = 'order_items' and column_name = 'version'),
    'rollback removes the gateway and the version columns');
end $$;
SQL
echo "Versioned order edits: OK"
