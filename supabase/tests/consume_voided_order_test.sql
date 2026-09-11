-- =============================================================================
-- Golden test · Una orden anulada devuelve el inventario (mig 20260910_0002)
--
-- CÓMO CORRERLO: pegar COMPLETO en el SQL editor de Supabase (o psql como
-- superusuario), DESPUÉS de aplicar la migración. Todo corre dentro de una
-- transacción que TERMINA EN ROLLBACK: no deja rastro en la base. Si algo
-- falla, la transacción aborta con el mensaje del caso.
--
-- Casos:
--   T1  Orden viva: el producto inventariable descuenta al vender.
--   T2  Al anular la orden, el trigger devuelve el stock SOLO. Éste es el
--       bug que se arregla: antes el consumo se quedaba pegado.
--   T3  Idempotencia: volver a llamar la función sobre la orden anulada no
--       escribe nada nuevo.
--   T4  Tocar un renglón de una orden anulada NO vuelve a descontar. Era la
--       fuga que dejaba movimientos de "Auto-consumo por venta" días después
--       de anulada la orden.
--   T5  Si la orden resucita, el consumo vuelve. La devolución no es
--       terminal.
-- =============================================================================

begin;

create temp table t_ctx (k text primary key, v text) on commit drop;

create or replace function pg_temp.chk(p_label text, p_got numeric, p_want numeric)
returns void language plpgsql as $fn$
begin
  if p_got is distinct from p_want then
    raise exception 'FALLA % -> obtuvo %, esperaba %', p_label, p_got, p_want;
  end if;
  raise notice 'ok  %  = %', p_label, p_got;
end $fn$;

create or replace function pg_temp.stock()
returns numeric language sql as $fn$
  select coalesce(s.quantity, 0)
  from public.inventory_stock s
  where s.item_id     = (select t.v from t_ctx t where t.k='item')::uuid
    and s.warehouse_id = (select t.v from t_ctx t where t.k='wh')::uuid;
$fn$;

create or replace function pg_temp.movs()
returns numeric language sql as $fn$
  select count(*)::numeric
  from public.inventory_movements m
  where m.reference_id   = (select t.v from t_ctx t where t.k='order')::uuid
    and m.reference_type = 'order';
$fn$;

-- ── Semilla ───────────────────────────────────────────────────────────────
do $$
declare
  v_owner uuid := gen_random_uuid();
  v_biz uuid; v_wh uuid; v_item uuid; v_menu uuid;
  v_zone uuid; v_table uuid; v_session uuid; v_order uuid; v_line uuid;
begin
  insert into auth.users (id, email) values (v_owner, 'owner_anulada@test.local');

  -- El dominio es NOT NULL y tiene que casar con businesses_domain_format.
  insert into public.businesses (owner_id, business_name, domain)
    values (v_owner, 'Test Orden Anulada', 'test-orden-anulada.mangopos.do')
    returning id into v_biz;

  -- El trigger create_business_defaults ya sembró settings, zona y bodega.
  insert into public.user_businesses (user_id, business_id, role)
    values (v_owner, v_biz, 'owner') on conflict do nothing;
  insert into public.business_settings (business_id) values (v_biz)
  on conflict do nothing;

  -- El inventario tiene que estar PRENDIDO o la función aborta de entrada.
  update public.business_settings
     set inventory_mode = 'advanced'
   where business_id = v_biz;

  select w.id into v_wh from public.warehouses w
   where w.business_id = v_biz
   order by coalesce(w.is_main, false) desc, w.name limit 1;
  if v_wh is null then
    insert into public.warehouses (business_id, name, is_main)
      values (v_biz, 'Principal', true) returning id into v_wh;
  end if;

  insert into public.inventory_items (business_id, name, unit, cost)
    values (v_biz, 'Refresco Test', 'unidad', 25) returning id into v_item;

  -- Producto TERMINADO con link directo, que es el caso de The Pizza Hot.
  insert into public.menu_items
    (business_id, name, price, is_inventory_tracked, inventory_item_id)
    values (v_biz, 'Refresco', 60, true, v_item) returning id into v_menu;

  -- Stock de partida: 100.
  insert into public.inventory_movements
    (business_id, warehouse_id, item_id, movement_type, quantity,
     cost_per_unit, reference_type)
    values (v_biz, v_wh, v_item, 'purchase', 100, 25, 'initial_stock');

  select z.id into v_zone from public.zones z
   where z.business_id = v_biz order by z.sort_index limit 1;
  if v_zone is null then
    insert into public.zones (business_id, name) values (v_biz, 'Salón')
      returning id into v_zone;
  end if;

  insert into public.dining_tables (zone_id, code) values (v_zone, 'T1')
    returning id into v_table;

  insert into public.table_sessions (table_id, opened_by, business_id)
    values (v_table, v_owner, v_biz) returning id into v_session;

  insert into public.orders (session_id, status)
    values (v_session, 'open') returning id into v_order;

  insert into public.order_items
    (order_id, product_id, quantity, qty, unit_price, product_name)
    values (v_order, v_menu, 3, 3, 60, 'Refresco') returning id into v_line;

  insert into t_ctx values
    ('owner', v_owner::text), ('biz', v_biz::text), ('wh', v_wh::text),
    ('item', v_item::text), ('menu', v_menu::text), ('order', v_order::text),
    ('line', v_line::text);
end $$;

select set_config('request.jwt.claim.sub', (select v from t_ctx where k='owner'), true);
select set_config('request.jwt.claims',
  json_build_object('sub', (select v from t_ctx where k='owner'),
                    'role', 'authenticated')::text, true);

-- ── T1 · Orden viva: descuenta ────────────────────────────────────────────
do $$ begin
  perform public.consume_inventory_from_order(
    (select v from t_ctx where k='order')::uuid);
  perform pg_temp.chk('T1 stock tras vender 3', pg_temp.stock(), 97::numeric);
  perform pg_temp.chk('T1 un solo movimiento', pg_temp.movs(), 1::numeric);
end $$;

-- ── T2 · Anular la orden devuelve el stock, sin que nadie lo pida ─────────
update public.orders
   set status = 'canceled', status_ext = 'void'::public.order_status
 where id = (select v from t_ctx where k='order')::uuid;

do $$ begin
  perform pg_temp.chk('T2 stock devuelto al anular', pg_temp.stock(), 100::numeric);
  perform pg_temp.chk('T2 quedó la devolución escrita', pg_temp.movs(), 2::numeric);
  perform pg_temp.chk('T2 la devolución dice por qué',
    (select count(*)::numeric from public.inventory_movements
      where reference_id = (select v from t_ctx where k='order')::uuid
        and notes = 'Devolución por anulación de la orden'), 1::numeric);
end $$;

-- ── T3 · Idempotencia sobre la orden anulada ──────────────────────────────
do $$ begin
  perform public.consume_inventory_from_order(
    (select v from t_ctx where k='order')::uuid);
  perform public.consume_inventory_from_order(
    (select v from t_ctx where k='order')::uuid);
  perform pg_temp.chk('T3 stock intacto', pg_temp.stock(), 100::numeric);
  perform pg_temp.chk('T3 sin movimientos nuevos', pg_temp.movs(), 2::numeric);
end $$;

-- ── T4 · Editar un renglón de la orden anulada NO vuelve a descontar ──────
-- Era la fuga: el trigger de order_items reconcilia, la función no miraba el
-- estado de la orden, y el consumo revivía días después.
update public.order_items
   set qty = 5, quantity = 5
 where id = (select v from t_ctx where k='line')::uuid;

do $$ begin
  perform pg_temp.chk('T4 la edición no resucitó el consumo',
    pg_temp.stock(), 100::numeric);
  perform pg_temp.chk('T4 sin movimientos nuevos', pg_temp.movs(), 2::numeric);
end $$;

-- ── T5 · Si la orden resucita, el consumo vuelve ──────────────────────────
update public.orders
   set status = 'open', status_ext = 'open'::public.order_status
 where id = (select v from t_ctx where k='order')::uuid;

do $$ begin
  -- Ahora el renglón dice 5, así que el esperado es 5, no 3.
  perform pg_temp.chk('T5 vuelve a descontar al resucitar',
    pg_temp.stock(), 95::numeric);
end $$;

rollback;
