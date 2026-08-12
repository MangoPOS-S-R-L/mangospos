-- =============================================================================
-- Golden tests · fn_receive_purchase_order_v2 (PRD 6.1 F3)
--
-- CÓMO CORRERLO: pegar COMPLETO en el SQL editor de Supabase (o psql como
-- superusuario). Todo corre dentro de una transacción que TERMINA EN ROLLBACK:
-- no deja rastro en la base. Si algún ASSERT falla, la transacción aborta con
-- el mensaje del caso; si todo pasa, la última fila dice ALL TESTS PASSED y
-- aun así se revierte todo.
--
-- Casos (criterios de aceptación del PRD):
--   T1  Recepción parcial (20 de 24) → PO 'partial', stock +20, 1 movimiento
--   T2  Reenvío TRIPLE con la misma clave → replayed=true, sin duplicados
--   T3  Segunda recepción completa el resto → PO 'received'
--   T4  Sobrante (30 de 24) → discrepancy 'over', PO 'received'
--   T5  Cierre corto (5 de 24, short_closed) → PO 'received' con pendiente
--   T6  Variación de costo sobre umbral como OWNER → auto-aprobación en bitácora
--   T7  Variación sobre umbral como MANAGER sin aprobador → COST_VARIANCE_UNAPPROVED
--   T8  Recepción libre (sin OC) → movimiento creado, po_status null
--   T9  Stock NEGATIVO previo + costeo ponderado → nuevo costo = costo recibido
--   T10 Stock CERO + costeo → costo = costo recibido (no promedia base inválida)
-- =============================================================================

begin;

-- ── Semilla: usuario, negocio, bodega, suplidor, insumos ──
create temp table t_ctx (k text primary key, v text) on commit drop;

do $$
declare
  v_owner uuid := gen_random_uuid();
  v_manager uuid := gen_random_uuid();
  v_biz uuid;
  v_wh uuid;
  v_sup uuid;
  v_item_a uuid;
  v_item_b uuid;
begin
  insert into auth.users (id, email) values
    (v_owner, 'owner_test_v2@test.local'),
    (v_manager, 'manager_test_v2@test.local');

  insert into public.businesses (owner_id, business_name, domain)
    values (v_owner, 'Test Recepciones V2', 'test-recepciones-v2')
    returning id into v_biz;

  insert into public.user_businesses (user_id, business_id, role)
    values (v_owner, v_biz, 'owner'), (v_manager, v_biz, 'manager');

  -- Umbral 3% (default) + modo avanzado para que corra el costeo ponderado.
  insert into public.business_settings (business_id, inventory_mode)
    values (v_biz, 'advanced')
  on conflict do nothing;
  update public.business_settings
     set inventory_mode = 'advanced',
         cost_variance_threshold_pct = 3
   where business_id = v_biz;

  insert into public.warehouses (business_id, name, is_main)
    values (v_biz, 'Principal', true) returning id into v_wh;

  insert into public.suppliers (business_id, name, rnc, tax_id_type)
    values (v_biz, 'Suplidor Test', '123456789', 'rnc') returning id into v_sup;

  insert into public.inventory_items (business_id, name, unit, cost)
    values (v_biz, 'Arroz test', 'lb', 100) returning id into v_item_a;
  insert into public.inventory_items (business_id, name, unit, cost)
    values (v_biz, 'Aceite test', 'unidad', 50) returning id into v_item_b;

  insert into t_ctx values
    ('owner', v_owner::text), ('manager', v_manager::text),
    ('biz', v_biz::text), ('wh', v_wh::text), ('sup', v_sup::text),
    ('item_a', v_item_a::text), ('item_b', v_item_b::text);
end $$;

-- Autenticarse como OWNER (cubre las dos implementaciones de auth.uid()).
select set_config('request.jwt.claim.sub', (select v from t_ctx where k='owner'), true);
select set_config('request.jwt.claims',
  json_build_object('sub', (select v from t_ctx where k='owner'), 'role', 'authenticated')::text, true);

-- ── PO-1: 24 × Arroz @100 + 10 × Aceite @50 ──
do $$
declare
  v_po uuid; v_poi_a uuid; v_poi_b uuid;
begin
  insert into public.purchase_orders
    (business_id, supplier_id, warehouse_id, order_number, status, subtotal, tax, total)
  values ((select v from t_ctx where k='biz')::uuid,
          (select v from t_ctx where k='sup')::uuid,
          (select v from t_ctx where k='wh')::uuid,
          'PO-TEST-1', 'sent', 2900, 0, 2900)
  returning id into v_po;
  insert into public.purchase_order_items
    (purchase_order_id, inventory_item_id, description, quantity_ordered, unit_cost, tax_rate, total)
  values (v_po, (select v from t_ctx where k='item_a')::uuid, 'Arroz test', 24, 100, 0, 2400)
  returning id into v_poi_a;
  insert into public.purchase_order_items
    (purchase_order_id, inventory_item_id, description, quantity_ordered, unit_cost, tax_rate, total)
  values (v_po, (select v from t_ctx where k='item_b')::uuid, 'Aceite test', 10, 50, 0, 500)
  returning id into v_poi_b;
  insert into t_ctx values ('po1', v_po::text), ('poi_a', v_poi_a::text), ('poi_b', v_poi_b::text);
end $$;

-- ── T1: recepción parcial 20 de 24 ──
do $$
declare
  v_res jsonb; v_stock numeric; v_received numeric;
begin
  v_res := public.fn_receive_purchase_order_v2(
    p_warehouse_id => (select v from t_ctx where k='wh')::uuid,
    p_lines => jsonb_build_array(jsonb_build_object(
      'poi_id', (select v from t_ctx where k='poi_a'),
      'qty', 20, 'actual_unit_cost', 100)),
    p_idempotency_key => 'test-key-T1',
    p_order_id => (select v from t_ctx where k='po1')::uuid,
    p_close_mode => 'partial',
    p_fiscal => jsonb_build_object('ncf', 'B0100000001', 'itbis_invoiced', 0)
  );
  assert (v_res->>'replayed')::boolean = false, 'T1: no debia ser replay';
  assert v_res->>'po_status' = 'partial', 'T1: PO debia quedar partial, quedo ' || (v_res->>'po_status');
  assert (v_res->>'movements_created')::int = 1, 'T1: debia crear 1 movimiento';

  select coalesce(sum(quantity),0) into v_stock from public.inventory_stock
    where item_id = (select v from t_ctx where k='item_a')::uuid;
  assert v_stock = 20, 'T1: stock debia ser 20, es ' || v_stock;

  select quantity_received into v_received from public.purchase_order_items
    where id = (select v from t_ctx where k='poi_a')::uuid;
  assert v_received = 20, 'T1: quantity_received debia ser 20';

  insert into t_ctx values ('t1_reception', v_res->>'reception_id');
end $$;

-- ── T2: reenvío triple con la misma clave — cero duplicados ──
do $$
declare
  v_res jsonb; v_count int; v_movs int; i int;
begin
  for i in 1..3 loop
    v_res := public.fn_receive_purchase_order_v2(
      p_warehouse_id => (select v from t_ctx where k='wh')::uuid,
      p_lines => jsonb_build_array(jsonb_build_object(
        'poi_id', (select v from t_ctx where k='poi_a'),
        'qty', 20, 'actual_unit_cost', 100)),
      p_idempotency_key => 'test-key-T1',   -- LA MISMA clave de T1
      p_order_id => (select v from t_ctx where k='po1')::uuid,
      p_close_mode => 'partial'
    );
    assert (v_res->>'replayed')::boolean = true, 'T2: reenvio debia ser replay';
    assert v_res->>'reception_id' = (select v from t_ctx where k='t1_reception'),
      'T2: debia devolver la recepcion original';
  end loop;

  select count(*) into v_count from public.purchase_receptions
    where idempotency_key = 'test-key-T1';
  assert v_count = 1, 'T2: debia existir UNA recepcion con la clave, hay ' || v_count;

  select count(*) into v_movs from public.inventory_movements
    where item_id = (select v from t_ctx where k='item_a')::uuid;
  assert v_movs = 1, 'T2: los reenvios NO deben duplicar movimientos, hay ' || v_movs;
end $$;

-- ── T3: segunda recepción completa el resto → received ──
do $$
declare
  v_res jsonb; v_status text;
begin
  v_res := public.fn_receive_purchase_order_v2(
    p_warehouse_id => (select v from t_ctx where k='wh')::uuid,
    p_lines => jsonb_build_array(
      jsonb_build_object('poi_id', (select v from t_ctx where k='poi_a'),
        'qty', 4, 'actual_unit_cost', 100),
      jsonb_build_object('poi_id', (select v from t_ctx where k='poi_b'),
        'qty', 10, 'actual_unit_cost', 50)),
    p_idempotency_key => 'test-key-T3',
    p_order_id => (select v from t_ctx where k='po1')::uuid,
    p_close_mode => 'complete'
  );
  assert v_res->>'po_status' = 'received', 'T3: PO debia quedar received';
  select status::text into v_status from public.purchase_orders
    where id = (select v from t_ctx where k='po1')::uuid;
  assert v_status = 'received', 'T3: status en tabla debia ser received';
end $$;

-- ── T4: sobrante — PO-2 pide 24, llegan 30 ──
do $$
declare
  v_po uuid; v_poi uuid; v_res jsonb; v_disc text; v_received numeric;
begin
  insert into public.purchase_orders
    (business_id, supplier_id, warehouse_id, order_number, status, subtotal, tax, total)
  values ((select v from t_ctx where k='biz')::uuid,
          (select v from t_ctx where k='sup')::uuid,
          (select v from t_ctx where k='wh')::uuid,
          'PO-TEST-2', 'sent', 2400, 0, 2400) returning id into v_po;
  insert into public.purchase_order_items
    (purchase_order_id, inventory_item_id, description, quantity_ordered, unit_cost, tax_rate, total)
  values (v_po, (select v from t_ctx where k='item_a')::uuid, 'Arroz test', 24, 100, 0, 2400)
  returning id into v_poi;

  v_res := public.fn_receive_purchase_order_v2(
    p_warehouse_id => (select v from t_ctx where k='wh')::uuid,
    p_lines => jsonb_build_array(jsonb_build_object(
      'poi_id', v_poi, 'qty', 30, 'actual_unit_cost', 100)),
    p_idempotency_key => 'test-key-T4',
    p_order_id => v_po,
    p_close_mode => 'complete'
  );
  assert v_res->>'po_status' = 'received', 'T4: PO con sobrante debia quedar received';

  select discrepancy into v_disc from public.purchase_reception_lines
    where reception_id = (v_res->>'reception_id')::uuid;
  assert v_disc = 'over', 'T4: discrepancy debia ser over, es ' || coalesce(v_disc,'null');

  select quantity_received into v_received from public.purchase_order_items where id = v_poi;
  assert v_received = 30, 'T4: quantity_received debia acumular 30';
end $$;

-- ── T5: cierre corto — llegan 5 de 24 y se cierra igual ──
do $$
declare
  v_po uuid; v_poi uuid; v_res jsonb; v_status text;
begin
  insert into public.purchase_orders
    (business_id, supplier_id, warehouse_id, order_number, status, subtotal, tax, total)
  values ((select v from t_ctx where k='biz')::uuid,
          (select v from t_ctx where k='sup')::uuid,
          (select v from t_ctx where k='wh')::uuid,
          'PO-TEST-3', 'sent', 2400, 0, 2400) returning id into v_po;
  insert into public.purchase_order_items
    (purchase_order_id, inventory_item_id, description, quantity_ordered, unit_cost, tax_rate, total)
  values (v_po, (select v from t_ctx where k='item_a')::uuid, 'Arroz test', 24, 100, 0, 2400)
  returning id into v_poi;

  v_res := public.fn_receive_purchase_order_v2(
    p_warehouse_id => (select v from t_ctx where k='wh')::uuid,
    p_lines => jsonb_build_array(jsonb_build_object(
      'poi_id', v_poi, 'qty', 5, 'actual_unit_cost', 100)),
    p_idempotency_key => 'test-key-T5',
    p_order_id => v_po,
    p_close_mode => 'short_closed'
  );
  assert v_res->>'po_status' = 'received', 'T5: cierre corto debia dejar received';
  select status::text into v_status from public.purchase_orders where id = v_po;
  assert v_status = 'received', 'T5: status en tabla debia ser received';
end $$;

-- ── T6: variación sobre umbral como OWNER → auto-aprobación ──
do $$
declare
  v_po uuid; v_poi uuid; v_res jsonb; v_approved uuid; v_variance numeric;
begin
  insert into public.purchase_orders
    (business_id, supplier_id, warehouse_id, order_number, status, subtotal, tax, total)
  values ((select v from t_ctx where k='biz')::uuid,
          (select v from t_ctx where k='sup')::uuid,
          (select v from t_ctx where k='wh')::uuid,
          'PO-TEST-4', 'sent', 1000, 0, 1000) returning id into v_po;
  insert into public.purchase_order_items
    (purchase_order_id, inventory_item_id, description, quantity_ordered, unit_cost, tax_rate, total)
  values (v_po, (select v from t_ctx where k='item_a')::uuid, 'Arroz test', 10, 100, 0, 1000)
  returning id into v_poi;

  -- Costo real 120 vs 100 = +20% (umbral 3%).
  v_res := public.fn_receive_purchase_order_v2(
    p_warehouse_id => (select v from t_ctx where k='wh')::uuid,
    p_lines => jsonb_build_array(jsonb_build_object(
      'poi_id', v_poi, 'qty', 10, 'actual_unit_cost', 120)),
    p_idempotency_key => 'test-key-T6',
    p_order_id => v_po,
    p_close_mode => 'complete'
  );
  assert (v_res->>'auto_approved')::boolean = true, 'T6: owner debia auto-aprobar';

  select approved_by, cost_variance_pct into v_approved, v_variance
    from public.purchase_reception_lines
    where reception_id = (v_res->>'reception_id')::uuid;
  assert v_approved = (select v from t_ctx where k='owner')::uuid,
    'T6: approved_by debia ser el owner (bitacora de auto-aprobacion)';
  assert v_variance = 20, 'T6: variacion debia ser 20%, es ' || v_variance;
end $$;

-- ── T7: variación sobre umbral como MANAGER → bloqueada ──
select set_config('request.jwt.claim.sub', (select v from t_ctx where k='manager'), true);
select set_config('request.jwt.claims',
  json_build_object('sub', (select v from t_ctx where k='manager'), 'role', 'authenticated')::text, true);

do $$
declare
  v_po uuid; v_poi uuid; v_res jsonb; v_blocked boolean := false;
begin
  insert into public.purchase_orders
    (business_id, supplier_id, warehouse_id, order_number, status, subtotal, tax, total)
  values ((select v from t_ctx where k='biz')::uuid,
          (select v from t_ctx where k='sup')::uuid,
          (select v from t_ctx where k='wh')::uuid,
          'PO-TEST-5', 'sent', 1000, 0, 1000) returning id into v_po;
  insert into public.purchase_order_items
    (purchase_order_id, inventory_item_id, description, quantity_ordered, unit_cost, tax_rate, total)
  values (v_po, (select v from t_ctx where k='item_a')::uuid, 'Arroz test', 10, 100, 0, 1000)
  returning id into v_poi;

  begin
    v_res := public.fn_receive_purchase_order_v2(
      p_warehouse_id => (select v from t_ctx where k='wh')::uuid,
      p_lines => jsonb_build_array(jsonb_build_object(
        'poi_id', v_poi, 'qty', 10, 'actual_unit_cost', 120)),
      p_idempotency_key => 'test-key-T7',
      p_order_id => v_po,
      p_close_mode => 'complete'
    );
  exception when others then
    v_blocked := sqlerrm like 'COST_VARIANCE_UNAPPROVED%';
  end;
  assert v_blocked, 'T7: manager sin aprobador debia recibir COST_VARIANCE_UNAPPROVED';

  -- El bloqueo debe dejar CERO rastro (transaccion interna abortada).
  assert not exists (
    select 1 from public.purchase_receptions where idempotency_key = 'test-key-T7'
  ), 'T7: no debia quedar recepcion tras el bloqueo';
end $$;

-- De vuelta como owner para el resto.
select set_config('request.jwt.claim.sub', (select v from t_ctx where k='owner'), true);
select set_config('request.jwt.claims',
  json_build_object('sub', (select v from t_ctx where k='owner'), 'role', 'authenticated')::text, true);

-- ── T8: recepción libre (sin OC) ──
do $$
declare
  v_res jsonb; v_movs int;
begin
  v_res := public.fn_receive_purchase_order_v2(
    p_warehouse_id => (select v from t_ctx where k='wh')::uuid,
    p_lines => jsonb_build_array(jsonb_build_object(
      'item_id', (select v from t_ctx where k='item_b'),
      'qty', 6, 'actual_unit_cost', 55)),
    p_idempotency_key => 'test-key-T8',
    p_supplier_id => (select v from t_ctx where k='sup')::uuid,
    p_close_mode => 'complete'
  );
  assert v_res->>'po_status' is null, 'T8: recepcion libre no tiene po_status';
  assert (v_res->>'movements_created')::int = 1, 'T8: debia crear 1 movimiento';

  select count(*) into v_movs from public.inventory_movements im
    join public.purchase_reception_lines prl on prl.id = im.reference_id
    where im.reference_type = 'purchase_reception_line'
      and prl.reception_id = (v_res->>'reception_id')::uuid;
  assert v_movs = 1, 'T8: movimiento debia referenciar la linea de recepcion';
end $$;

-- ── T9 + T10: costeo ponderado con stock negativo y stock cero ──
do $$
declare
  v_item uuid; v_res jsonb; v_cost numeric;
begin
  -- Insumo fresco con costo maestro 100 y stock 0.
  insert into public.inventory_items (business_id, name, unit, cost)
    values ((select v from t_ctx where k='biz')::uuid, 'Cafe test', 'lb', 100)
    returning id into v_item;

  -- T10: stock CERO → recibir a 80 debe dejar costo = 80 (no promedia).
  v_res := public.fn_receive_purchase_order_v2(
    p_warehouse_id => (select v from t_ctx where k='wh')::uuid,
    p_lines => jsonb_build_array(jsonb_build_object(
      'item_id', v_item, 'qty', 10, 'actual_unit_cost', 80)),
    p_idempotency_key => 'test-key-T10',
    p_close_mode => 'complete'
  );
  select cost into v_cost from public.inventory_items where id = v_item;
  assert v_cost = 80, 'T10: con stock 0 el costo debia ser 80, es ' || v_cost;

  -- Dejar el stock NEGATIVO (consumo directo mayor al stock).
  insert into public.inventory_movements
    (business_id, warehouse_id, item_id, movement_type, quantity, notes, created_by)
  values ((select v from t_ctx where k='biz')::uuid,
          (select v from t_ctx where k='wh')::uuid,
          v_item, 'waste', -25, 'ajuste test negativo',
          (select v from t_ctx where k='owner')::uuid);

  -- T9: stock -15 → recibir a 60 debe dejar costo = 60 (guard de base invalida).
  v_res := public.fn_receive_purchase_order_v2(
    p_warehouse_id => (select v from t_ctx where k='wh')::uuid,
    p_lines => jsonb_build_array(jsonb_build_object(
      'item_id', v_item, 'qty', 5, 'actual_unit_cost', 60)),
    p_idempotency_key => 'test-key-T9',
    p_close_mode => 'complete'
  );
  select cost into v_cost from public.inventory_items where id = v_item;
  assert v_cost = 60, 'T9: con stock negativo el costo debia ser 60, es ' || v_cost;
end $$;

select 'ALL TESTS PASSED — fn_receive_purchase_order_v2' as resultado;

rollback;
