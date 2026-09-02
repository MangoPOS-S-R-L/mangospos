-- =============================================================================
-- Golden tests · Capas de costo (migs 20260902_0012 y 20260902_0013)
--
-- CÓMO CORRERLO: pegar COMPLETO en el SQL editor de Supabase (o psql como
-- superusuario), DESPUÉS de aplicar las dos migraciones. Todo corre dentro de
-- una transacción que TERMINA EN ROLLBACK: no deja rastro en la base. Si algo
-- falla, la transacción aborta con el mensaje del caso.
--
-- OJO: todo el archivo es UNA sola transacción, así que now() devuelve el
-- mismo timestamp para cada fila. Eso es a propósito: es el escenario que
-- rompe el orden de PEPS/UEPS si el desempate por `seq` no funciona.
--
-- Casos:
--   T1  Motor apagado (last_price, el default) → no crea capas, y el recosteo
--       por último precio sigue vivo. Ningún negocio cambia al aplicar.
--   T2  UEPS: consume la capa más reciente primero, con las dos compras
--       empatadas en el mismo timestamp.
--   T3  PEPS: consume la más antigua primero.
--   T4  Promedio: el promedio del remanente NO se mueve tras la salida, y no
--       aparecen faltantes por polvo de redondeo.
--   T5  Devolución por edición de orden ('sale' con cantidad positiva):
--       restituye la capa consumida, no crea una nueva, y el costo de venta
--       neto queda correcto.
--   T6  Faltante: salida sin capa disponible se costea al último costo
--       conocido y sale en v_inventory_cost_shortfalls.
--   T7  Apertura desde conteo físico: simulacro no escribe, la siembra trae el
--       NCF de la compra respaldada, y la segunda siembra rebota.
--   T8  Cuadre: inventory_stock == suma de capas abiertas.
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

create or replace function pg_temp.mov(
  p_item text, p_type text, p_qty numeric, p_cost numeric default null,
  p_ref uuid default null, p_ref_type text default null)
returns uuid language plpgsql as $fn$
-- `v_id`, no `v`: t_ctx tiene una columna llamada v y plpgsql resolvería el
-- nombre a la variable, no a la columna ("column reference v is ambiguous").
declare v_id uuid;
begin
  insert into public.inventory_movements
    (business_id, warehouse_id, item_id, movement_type, quantity,
     cost_per_unit, reference_id, reference_type)
  values ((select t.v from t_ctx t where t.k='biz')::uuid,
          (select t.v from t_ctx t where t.k='wh')::uuid,
          (select t.v from t_ctx t where t.k=p_item)::uuid,
          p_type::public.movement_type, p_qty, p_cost, p_ref, p_ref_type)
  returning id into v_id;
  return v_id;
end $fn$;

-- ── Semilla ───────────────────────────────────────────────────────────────
do $$
declare
  v_owner uuid := gen_random_uuid();
  v_biz uuid; v_wh uuid;
  v_off uuid; v_lifo uuid; v_fifo uuid; v_avg uuid; v_ret uuid;
  v_short uuid; v_open uuid;
begin
  insert into auth.users (id, email) values (v_owner, 'owner_capas@test.local');

  -- El dominio es NOT NULL y tiene que casar con businesses_domain_format:
  -- ^[a-z0-9](...)*\.mangopos\.do$. Un slug pelado revienta con 23514.
  insert into public.businesses (owner_id, business_name, domain)
    values (v_owner, 'Test Capas de Costo', 'test-capas-costo.mangopos.do')
    returning id into v_biz;

  -- OJO: el trigger `create_business_defaults` ya corrió con el insert de
  -- arriba y sembró business_settings, impuestos, zonas, la BODEGA PRINCIPAL
  -- y la membresía del dueño en user_businesses. La semilla solo completa lo
  -- que falte; duplicarlo revienta con 23505.
  insert into public.user_businesses (user_id, business_id, role)
    values (v_owner, v_biz, 'owner')
  on conflict do nothing;

  insert into public.business_settings (business_id) values (v_biz)
  on conflict do nothing;

  select w.id into v_wh
    from public.warehouses w
   where w.business_id = v_biz
   order by coalesce(w.is_main, false) desc, w.name
   limit 1;

  if v_wh is null then
    insert into public.warehouses (business_id, name, is_main)
      values (v_biz, 'Principal', true) returning id into v_wh;
  end if;

  insert into public.inventory_items (business_id, name, unit, cost)
    values (v_biz, 'Capas OFF', 'und', 0) returning id into v_off;
  insert into public.inventory_items (business_id, name, unit, cost)
    values (v_biz, 'Capas UEPS', 'und', 0) returning id into v_lifo;
  insert into public.inventory_items (business_id, name, unit, cost)
    values (v_biz, 'Capas PEPS', 'und', 0) returning id into v_fifo;
  insert into public.inventory_items (business_id, name, unit, cost)
    values (v_biz, 'Capas PROM', 'und', 0) returning id into v_avg;
  insert into public.inventory_items (business_id, name, unit, cost)
    values (v_biz, 'Capas DEVOL', 'und', 0) returning id into v_ret;
  insert into public.inventory_items (business_id, name, unit, cost)
    values (v_biz, 'Capas FALTA', 'und', 25) returning id into v_short;
  insert into public.inventory_items (business_id, name, unit, cost)
    values (v_biz, 'Capas APERT', 'und', 0) returning id into v_open;

  insert into t_ctx values
    ('owner', v_owner::text), ('biz', v_biz::text), ('wh', v_wh::text),
    ('off', v_off::text), ('lifo', v_lifo::text), ('fifo', v_fifo::text),
    ('avg', v_avg::text), ('ret', v_ret::text), ('short', v_short::text),
    ('open', v_open::text);
end $$;

select set_config('request.jwt.claim.sub', (select v from t_ctx where k='owner'), true);
select set_config('request.jwt.claims',
  json_build_object('sub', (select v from t_ctx where k='owner'),
                    'role', 'authenticated')::text, true);

-- ── T1 · Motor apagado (default last_price) ───────────────────────────────
select pg_temp.mov('off', 'purchase', 10, 100);
do $$ begin
  perform pg_temp.chk('T1 motor apagado no crea capas',
    (select count(*)::numeric from public.inventory_cost_layers
      where business_id = (select v from t_ctx where k='biz')::uuid), 0::numeric);
  perform pg_temp.chk('T1 recosteo por último precio intacto',
    (select cost from public.inventory_items
      where id = (select v from t_ctx where k='off')::uuid), 100::numeric);
end $$;

-- ── T2 · UEPS ─────────────────────────────────────────────────────────────
update public.business_settings set inventory_costing_method = 'lifo'
 where business_id = (select v from t_ctx where k='biz')::uuid;

select pg_temp.mov('lifo', 'purchase', 10, 100);
select pg_temp.mov('lifo', 'purchase', 10, 150);
select pg_temp.mov('lifo', 'sale', -12);
do $$ begin
  -- 10 × 150 + 2 × 100 = 1,700 ; 1,700 / 12 = 141.6667
  perform pg_temp.chk('T2 UEPS costo unitario de la venta',
    (select cost_per_unit from public.inventory_movements
      where item_id = (select v from t_ctx where k='lifo')::uuid
        and movement_type = 'sale'), 141.6667::numeric);
  perform pg_temp.chk('T2 UEPS capa reciente agotada',
    (select quantity_remaining from public.inventory_cost_layers
      where item_id = (select v from t_ctx where k='lifo')::uuid
        and unit_cost = 150), 0::numeric);
  perform pg_temp.chk('T2 UEPS capa antigua con saldo',
    (select quantity_remaining from public.inventory_cost_layers
      where item_id = (select v from t_ctx where k='lifo')::uuid
        and unit_cost = 100), 8::numeric);
end $$;

-- ── T3 · PEPS ─────────────────────────────────────────────────────────────
update public.business_settings set inventory_costing_method = 'fifo'
 where business_id = (select v from t_ctx where k='biz')::uuid;

select pg_temp.mov('fifo', 'purchase', 10, 100);
select pg_temp.mov('fifo', 'purchase', 10, 150);
select pg_temp.mov('fifo', 'sale', -12);
do $$ begin
  -- 10 × 100 + 2 × 150 = 1,300 ; 1,300 / 12 = 108.3333
  perform pg_temp.chk('T3 PEPS costo unitario de la venta',
    (select cost_per_unit from public.inventory_movements
      where item_id = (select v from t_ctx where k='fifo')::uuid
        and movement_type = 'sale'), 108.3333::numeric);
  perform pg_temp.chk('T3 PEPS capa antigua agotada',
    (select quantity_remaining from public.inventory_cost_layers
      where item_id = (select v from t_ctx where k='fifo')::uuid
        and unit_cost = 100), 0::numeric);
end $$;

-- ── T4 · Promedio ─────────────────────────────────────────────────────────
update public.business_settings set inventory_costing_method = 'average'
 where business_id = (select v from t_ctx where k='biz')::uuid;

select pg_temp.mov('avg', 'purchase', 10, 100);
select pg_temp.mov('avg', 'purchase', 10, 200);
select pg_temp.mov('avg', 'sale', -12);
do $$
declare v_qty numeric; v_val numeric;
begin
  perform pg_temp.chk('T4 PROMEDIO costo unitario de la venta',
    (select cost_per_unit from public.inventory_movements
      where item_id = (select v from t_ctx where k='avg')::uuid
        and movement_type = 'sale'), 150::numeric);
  select sum(quantity_remaining), sum(quantity_remaining * unit_cost)
    into v_qty, v_val from public.inventory_cost_layers
   where item_id = (select v from t_ctx where k='avg')::uuid;
  perform pg_temp.chk('T4 PROMEDIO cantidad remanente', v_qty, 8::numeric);
  perform pg_temp.chk('T4 PROMEDIO del remanente no se movió',
    round(v_val / v_qty, 4), 150::numeric);
  perform pg_temp.chk('T4 PROMEDIO sin faltantes por redondeo',
    (select count(*)::numeric from public.inventory_cost_consumptions
      where item_id = (select v from t_ctx where k='avg')::uuid
        and is_shortfall), 0::numeric);
end $$;

-- ── T5 · Devolución por edición de orden ──────────────────────────────────
update public.business_settings set inventory_costing_method = 'lifo'
 where business_id = (select v from t_ctx where k='biz')::uuid;

select pg_temp.mov('ret', 'purchase', 10, 100);
select pg_temp.mov('ret', 'sale', -4);
select pg_temp.mov('ret', 'sale', 3);
do $$ begin
  perform pg_temp.chk('T5 DEVOLUCIÓN restituye la capa',
    (select quantity_remaining from public.inventory_cost_layers
      where item_id = (select v from t_ctx where k='ret')::uuid), 9::numeric);
  perform pg_temp.chk('T5 DEVOLUCIÓN no crea capa espuria',
    (select count(*)::numeric from public.inventory_cost_layers
      where item_id = (select v from t_ctx where k='ret')::uuid), 1::numeric);
  perform pg_temp.chk('T5 DEVOLUCIÓN costeada al costo de salida',
    (select cost_per_unit from public.inventory_movements
      where item_id = (select v from t_ctx where k='ret')::uuid
        and quantity = 3), 100::numeric);
  perform pg_temp.chk('T5 costo de venta neto de la devolución',
    (select round(sum(cost_of_sales), 4) from public.v_inventory_cost_of_sales
      where item_id = (select v from t_ctx where k='ret')::uuid), 100::numeric);
end $$;

-- ── T6 · Faltante ─────────────────────────────────────────────────────────
select pg_temp.mov('short', 'sale', -5);
do $$ begin
  perform pg_temp.chk('T6 FALTANTE costeado al costo maestro',
    (select cost_per_unit from public.inventory_movements
      where item_id = (select v from t_ctx where k='short')::uuid), 25::numeric);
  perform pg_temp.chk('T6 FALTANTE visible en el reporte',
    (select round(shortfall_value, 4) from public.v_inventory_cost_shortfalls
      where item_id = (select v from t_ctx where k='short')::uuid), 125::numeric);
end $$;

-- ── T7 · Apertura desde conteo físico ─────────────────────────────────────
do $$
declare v_rec uuid; v_line uuid; v_ses uuid;
begin
  insert into public.purchase_receptions
    (business_id, warehouse_id, ncf, document_date, reception_date)
  values ((select v from t_ctx where k='biz')::uuid,
          (select v from t_ctx where k='wh')::uuid,
          'B0100000123', date '2026-08-20', date '2026-08-20')
  returning id into v_rec;

  insert into public.purchase_reception_lines
    (reception_id, item_id, quantity_received, actual_unit_cost)
  values (v_rec, (select v from t_ctx where k='open')::uuid, 100, 12.5)
  returning id into v_line;

  -- La compra respaldada, con el motor apagado para no crear capa todavía.
  update public.business_settings set inventory_costing_method = 'last_price'
   where business_id = (select v from t_ctx where k='biz')::uuid;
  perform pg_temp.mov('open', 'purchase', 100, 12.5, v_line,
                      'purchase_reception_line');
  update public.business_settings set inventory_costing_method = 'lifo'
   where business_id = (select v from t_ctx where k='biz')::uuid;

  insert into public.physical_count_sessions
    (business_id, warehouse_id, code, status, frozen_at)
  values ((select v from t_ctx where k='biz')::uuid,
          (select v from t_ctx where k='wh')::uuid,
          'CF-CAPAS-TEST', 'in_progress', now())
  returning id into v_ses;

  insert into public.physical_count_lines
    (session_id, item_id, snapshot_quantity, counted_quantity)
  values (v_ses, (select v from t_ctx where k='open')::uuid, 100, 40);

  insert into t_ctx values ('ses', v_ses::text);
end $$;

do $$
declare r jsonb;
begin
  r := public.fn_inventory_seed_opening_layers(
         (select v from t_ctx where k='ses')::uuid, true);
  raise notice 'T7 simulacro: %', r;
  perform pg_temp.chk('T7 SIMULACRO valor', (r->>'total_value')::numeric, 500::numeric);
  perform pg_temp.chk('T7 SIMULACRO todo con respaldo',
    (r->>'estimated_value')::numeric, 0::numeric);
  perform pg_temp.chk('T7 SIMULACRO no escribe',
    (select count(*)::numeric from public.inventory_cost_layers
      where source_type = 'opening'
        and business_id = (select v from t_ctx where k='biz')::uuid), 0::numeric);

  r := public.fn_inventory_seed_opening_layers(
         (select v from t_ctx where k='ses')::uuid, false);
  perform pg_temp.chk('T7 APERTURA capa creada',
    (select count(*)::numeric from public.inventory_cost_layers
      where source_type = 'opening'
        and business_id = (select v from t_ctx where k='biz')::uuid), 1::numeric);
  perform pg_temp.chk('T7 APERTURA arrastra el NCF',
    (select count(*)::numeric from public.inventory_cost_layers
      where source_type = 'opening' and document_number = 'B0100000123'
        and business_id = (select v from t_ctx where k='biz')::uuid), 1::numeric);
end $$;

do $$
begin
  perform public.fn_inventory_seed_opening_layers(
            (select v from t_ctx where k='ses')::uuid, false);
  raise exception 'FALLA T7: la segunda siembra debió rebotar';
exception when others then
  if sqlerrm like 'OPENING_LAYERS_EXIST%' then
    raise notice 'ok  T7 doble siembra rebotada: %', sqlerrm;
  else
    raise;
  end if;
end $$;

-- ── T8 · Cuadre stock vs capas ────────────────────────────────────────────
do $$
declare v_diff integer;
begin
  select count(*) into v_diff
    from public.inventory_stock st
    left join (
      select item_id, warehouse_id, sum(quantity_remaining) q
        from public.inventory_cost_layers
       where business_id = (select v from t_ctx where k='biz')::uuid
       group by 1, 2
    ) cap on cap.item_id = st.item_id and cap.warehouse_id = st.warehouse_id
   where st.item_id in (
           (select v from t_ctx where k='lifo')::uuid,
           (select v from t_ctx where k='fifo')::uuid,
           (select v from t_ctx where k='avg')::uuid,
           (select v from t_ctx where k='ret')::uuid)
     and abs(coalesce(st.quantity, 0) - coalesce(cap.q, 0)) > 0.0001;
  perform pg_temp.chk('T8 CUADRE stock vs capas abiertas', v_diff::numeric, 0::numeric);
end $$;

select 'ALL TESTS PASSED' as resultado;

rollback;
