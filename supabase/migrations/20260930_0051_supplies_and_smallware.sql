-- =============================================================================
-- 20260930_0051 — Gastables y menaje: lo que el negocio compra y NO vende.
--
-- PEDIDO DEL DUEÑO (2026-09-30): «tenemos pendiente la parte de materiales
-- gastables y de activos fijos, como papel higiénico, cristalería, artículos de
-- cocina y cosas así».
--
-- DECISIONES (tomadas con el dueño):
--   · Tres tipos de cosa, no uno:
--       gastable (supply)    papel higiénico, servilletas, cloro, fundas,
--                            guantes. Se compra, se guarda y se CONSUME.
--       menaje (smallware)   copas, vasos, platos, cubiertos, ollas, sartenes,
--                            cuchillos. Se controla POR CANTIDAD (120 copas en
--                            el Bar), no pieza por pieza. No se consume: sale
--                            por rotura o pérdida y se repone hasta el «par».
--       activo fijo          horno, nevera, TV, mobiliario: uno por uno, con
--                            código. Va aparte, en 20260930_0052.
--   · Un gastable se da por consumido AL SALIR DEL ALMACÉN (salida «Consumo
--     interno» con el área a la que va: baños, cocina, salón). El conteo físico
--     cuadra el resto.
--   · Los gastables para llevar (foam, bolsas) que se descuentan solos con la
--     venta quedan para otra fase: tocan el motor de consumo de ventas.
--
-- POR QUÉ REUSAR inventory_items Y NO UNA TABLA NUEVA:
--   Gastables y menaje se compran, se reciben, se guardan en bodegas, se
--   transfieren, se piden por requisición y se cuentan — igual que un insumo.
--   Con una clase nueva heredan todo eso sin un segundo motor de stock. El
--   «par» del menaje es el mínimo que ya existe (por bodega en
--   inventory_stock.min_stock, general en inventory_items.min_stock).
--
-- ENTREGA:
--   1. inventory_items.item_classification acepta 'supply' y 'smallware'.
--   2. inventory_movements.reason_code acepta 'internal_use' (Consumo interno).
--   3. inventory_movements.destination: a qué área fue un consumo interno.
--   4. fn_inventory_record_outflow con p_destination (9 parámetros; se quita la
--      de 8). Una app vieja que llama con 8 nombres sigue funcionando: el
--      noveno tiene default.
--   5. fn_inventory_yield_analysis (20260930_0050) deja fuera gastables y
--      menaje — es el rendimiento de la COMIDA — y cuenta un consumo interno
--      como consumo, no como merma. Se reemplaza entera aquí para que dé lo
--      mismo si la 0050 ya se aplicó o no.
--   6. fn_inventory_supplies_overview: el panel «Gastables y menaje».
--
-- CANDADOS: inventory_movements es la tabla más grande del sistema. Los dos
-- CHECK se agregan NOT VALID (no recorren la tabla: solo validan filas nuevas)
-- en una transacción corta con tope de 5 s, y se VALIDAN al final en una
-- transacción aparte, que no bloquea ventas (SHARE UPDATE EXCLUSIVE). La
-- columna nueva es nullable y sin default: es solo catálogo, no reescribe
-- nada.
--
-- Los CHECK se reconstruyen a partir del que está VIVO (+ los valores nuevos),
-- no de una lista escrita aquí: si la base tiene un valor que el repo no
-- conoce, se conserva en vez de perderse en silencio.
--
-- ANTES DE APLICAR (la BD viva puede diverger del repo):
--   select pg_get_functiondef(
--     'public.fn_inventory_record_outflow(uuid,uuid,uuid,numeric,text,text,numeric,uuid)'::regprocedure);
--   Debe ser la de 20260928_0001 (con p_reference_id y el candado por llave).
--
-- IDEMPOTENTE: sí. REVERSIBLE: sí (_ROLLBACK), siempre que no haya filas con
-- las clases o el motivo nuevos.
-- =============================================================================

-- ── 1. Estructura (candado corto) ───────────────────────────────────────────
begin;

set local lock_timeout = '5s';

do $$
declare
  v_def   text;
  v_codes text[];
begin
  -- 1a. Clases de insumo.
  select pg_get_constraintdef(c.oid) into v_def
    from pg_constraint c
   where c.conname = 'inventory_items_classification_check'
     and c.conrelid = 'public.inventory_items'::regclass;

  if v_def is not null and v_def like '%''smallware''%' and v_def like '%''supply''%' then
    raise notice 'inventory_items: el CHECK ya acepta supply y smallware.';
  else
    select array(
      select distinct x
        from unnest(
          coalesce((select array_agg(v)
                      from regexp_matches(coalesce(v_def, ''), '''([^'']*)''', 'g') m,
                           unnest(string_to_array(btrim(m[1], '{}'), ',')) v
                     where v <> ''),
                   '{}'::text[])
          || array['simple', 'raw_material', 'finished_product', 'combo', 'service',
                   'supply', 'smallware']) x
       order by x)
      into v_codes;

    alter table public.inventory_items
      drop constraint if exists inventory_items_classification_check;
    execute format(
      'alter table public.inventory_items
         add constraint inventory_items_classification_check
         check (item_classification = any (array[%s]::text[])) not valid',
      (select string_agg(quote_literal(x), ', ' order by x) from unnest(v_codes) x));
    raise notice 'inventory_items: CHECK ampliado a %', v_codes;
  end if;

  -- 1b. Motivos de movimiento.
  select pg_get_constraintdef(c.oid) into v_def
    from pg_constraint c
   where c.conname = 'inventory_movements_reason_code_check'
     and c.conrelid = 'public.inventory_movements'::regclass;

  if v_def is not null and v_def like '%''internal_use''%' then
    raise notice 'inventory_movements: el CHECK ya acepta internal_use.';
  elsif exists (
    select 1 from information_schema.columns
     where table_schema = 'public'
       and table_name = 'inventory_movements'
       and column_name = 'reason_code'
  ) then
    select array(
      select distinct x
        from unnest(
          coalesce((select array_agg(v)
                      from regexp_matches(coalesce(v_def, ''), '''([^'']*)''', 'g') m,
                           unnest(string_to_array(btrim(m[1], '{}'), ',')) v
                     where v <> ''),
                   '{}'::text[])
          || array['physical_count', 'breakage', 'expiration', 'cleaning', 'theft',
                   'donation', 'correction', 'other', 'internal_use']) x
       order by x)
      into v_codes;

    alter table public.inventory_movements
      drop constraint if exists inventory_movements_reason_code_check;
    execute format(
      'alter table public.inventory_movements
         add constraint inventory_movements_reason_code_check
         check (reason_code is null or reason_code = any (array[%s]::text[])) not valid',
      (select string_agg(quote_literal(x), ', ' order by x) from unnest(v_codes) x));
    raise notice 'inventory_movements: CHECK ampliado a %', v_codes;
  end if;
end
$$;

-- 1c. Área a la que fue un consumo interno. Texto libre corto (la app sugiere
-- Baños, Cocina, Bar, Salón…): no es una bodega ni un área de impresión.
alter table public.inventory_movements
  add column if not exists destination text;

comment on column public.inventory_movements.destination is
  'Área a la que fue un consumo interno (Baños, Cocina, Salón…). Solo en '
  'salidas con reason_code = internal_use. Ver 20260930_0051.';

comment on column public.inventory_items.item_classification is
  'Rol del item: simple (default), raw_material, finished_product, combo, '
  'service (no físico), supply (gastable: se consume en la operación, no se '
  'vende) o smallware (menaje: reutilizable, por cantidad; sale por rotura o '
  'pérdida). Ver 20260516_0003 y 20260930_0051.';

commit;

-- ── 2. Funciones ────────────────────────────────────────────────────────────
begin;

set local lock_timeout = '5s';

-- 2a. Salida con motivo y área destino.
drop function if exists public.fn_inventory_record_outflow(
  uuid, uuid, uuid, numeric, text, text, numeric, uuid
);

create or replace function public.fn_inventory_record_outflow(
  p_business_id uuid,
  p_warehouse_id uuid,
  p_item_id uuid,
  p_quantity numeric,
  p_reason_code text,
  p_notes text default null,
  p_cost_per_unit numeric default null,
  p_reference_id uuid default null,
  p_destination text default null
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_result jsonb;
  v_movement_id uuid;
  v_existing public.inventory_movements;
  v_item_cost numeric;
  v_destination text := left(nullif(btrim(coalesce(p_destination, '')), ''), 80);
begin
  if p_quantity is null or p_quantity <= 0 then
    raise exception 'INVALID_QUANTITY';
  end if;
  if p_reason_code is null
     or p_reason_code not in (
       'breakage', 'expiration', 'cleaning', 'theft', 'donation', 'internal_use'
     ) then
    raise exception 'INVALID_OUTFLOW_REASON: %', coalesce(p_reason_code, 'null');
  end if;
  -- El área solo describe un consumo interno. En una rotura no significa nada.
  if p_reason_code <> 'internal_use' then
    v_destination := null;
  end if;

  -- Reintento de la MISMA salida (respuesta perdida, cola offline): se
  -- devuelve la que ya quedó. El candado serializa dos envíos simultáneos.
  if p_reference_id is not null then
    perform pg_advisory_xact_lock(
      hashtextextended('manual_outflow:' || p_reference_id::text, 0));
    select * into v_existing
      from public.inventory_movements m
     where m.business_id = p_business_id
       and m.item_id = p_item_id
       and m.reference_type = 'manual_outflow'
       and m.reference_id = p_reference_id
     limit 1;
    if found then
      return jsonb_build_object(
        'id', v_existing.id,
        'business_id', v_existing.business_id,
        'warehouse_id', v_existing.warehouse_id,
        'item_id', v_existing.item_id,
        'movement_type', v_existing.movement_type,
        'quantity', v_existing.quantity,
        'created_at', v_existing.created_at,
        'reason_code', p_reason_code,
        'destination', v_existing.destination,
        'replayed', true
      );
    end if;
  end if;

  -- Rol, bodega activa e insumo del negocio los valida la función base.
  v_result := public.fn_inventory_record_movement(
    p_business_id    => p_business_id,
    p_warehouse_id   => p_warehouse_id,
    p_item_id        => p_item_id,
    p_movement_type  => 'waste'::public.movement_type,
    p_quantity       => p_quantity,
    p_cost_per_unit  => p_cost_per_unit,
    p_reference_id   => p_reference_id,
    p_reference_type => 'manual_outflow',
    p_notes          => p_notes
  );

  v_movement_id := nullif(v_result->>'id', '')::uuid;
  if v_movement_id is not null then
    -- Sin costo de la app: el del insumo, para que el kardex valore la salida.
    select ii.cost into v_item_cost
      from public.inventory_items ii
     where ii.id = p_item_id and ii.business_id = p_business_id;
    update public.inventory_movements
       set cost_per_unit = v_item_cost
     where id = v_movement_id
       and cost_per_unit is null
       and v_item_cost is not null;

    if v_destination is not null then
      update public.inventory_movements
         set destination = v_destination
       where id = v_movement_id;
    end if;

    begin
      update public.inventory_movements
         set reason_code = p_reason_code
       where id = v_movement_id;
    exception when check_violation then
      -- CHECK viejo: la salida ya quedó; el motivo viaja en la nota que armó
      -- la app.
      null;
    end;
  end if;

  return v_result || jsonb_build_object(
    'reason_code', p_reason_code,
    'destination', v_destination,
    'replayed', false);
end;
$$;

revoke all on function public.fn_inventory_record_outflow(
  uuid, uuid, uuid, numeric, text, text, numeric, uuid, text
) from public;
revoke all on function public.fn_inventory_record_outflow(
  uuid, uuid, uuid, numeric, text, text, numeric, uuid, text
) from anon;
grant execute on function public.fn_inventory_record_outflow(
  uuid, uuid, uuid, numeric, text, text, numeric, uuid, text
) to authenticated;

-- 2b. Rendimiento: solo comida; el consumo interno es consumo.
--     Idéntica a 20260930_0050 salvo dos cosas, marcadas con «0051».
create or replace function public.fn_inventory_yield_analysis(
  p_business_id  uuid,
  p_days_back    int  default 30,
  p_warehouse_id uuid default null
)
returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  v_days  int;
  v_today date;
  v_from  timestamptz;
  v_result jsonb;
begin
  if p_business_id is null then
    raise exception 'MISSING_REQUIRED_PARAMS';
  end if;
  if not public.user_has_business_access(auth.uid(), p_business_id) then
    raise exception 'NOT_AUTHORIZED';
  end if;

  v_days  := least(greatest(abs(coalesce(nullif(p_days_back, 0), 30)), 1), 366);
  v_today := (now() at time zone 'America/Santo_Domingo')::date;
  v_from  := ((v_today - (v_days - 1))::timestamp) at time zone 'America/Santo_Domingo';

  with mv as materialized (
    select
      im.item_id,
      b.bucket,
      case when b.bucket = 'waste' then coalesce(r.reason, 'unspecified') end as reason,
      im.quantity as qty,
      im.quantity * coalesce(nullif(im.cost_per_unit, 0), ii.cost, 0) as value,
      (im.created_at at time zone 'America/Santo_Domingo')::date as day
    from public.inventory_movements im
    join public.inventory_items ii on ii.id = im.item_id
    cross join lateral (
      select coalesce(
        case when im.reason_code in ('breakage','expiration','cleaning','theft','donation',
                                     'internal_use')
             then im.reason_code end,
        case when im.reference_type = 'order_item_removal' then 'order_removal' end,
        case split_part(coalesce(im.notes, ''), ' — ', 1)
          when 'Rotura / dañado'     then 'breakage'
          when 'Vencido'             then 'expiration'
          when 'Limpieza'            then 'cleaning'
          when 'Faltante / robo'     then 'theft'
          when 'Donación / cortesía' then 'donation'
          when 'Consumo interno'     then 'internal_use'
        end) as reason
    ) r
    cross join lateral (
      select case
        when im.movement_type::text = 'purchase' then 'purchase'
        when im.movement_type::text in ('sale', 'production_out', 'return') then 'consumption'
        when im.movement_type::text = 'production_in' then 'produced'
        -- 0051: lo que se usó en el negocio se CONSUMIÓ; no se perdió.
        when im.movement_type::text = 'waste' and r.reason = 'internal_use' then 'consumption'
        when im.movement_type::text = 'waste' then 'waste'
        when im.movement_type::text = 'adjustment'
             and im.quantity < 0
             and im.reason_code = 'internal_use'
          then 'consumption'
        when im.movement_type::text = 'adjustment'
             and im.quantity < 0
             and im.reason_code in ('breakage','expiration','cleaning','theft','donation')
          then 'waste'
        when im.movement_type::text = 'adjustment' then 'count_adjust'
        when im.movement_type::text in ('transfer_in', 'transfer_out') then 'transfer'
        else 'other'
      end as bucket
    ) b
    where im.business_id = p_business_id
      and im.created_at >= v_from
      and (p_warehouse_id is null or im.warehouse_id = p_warehouse_id)
      -- 0051: gastables y menaje tienen su propio panel; aquí es la comida.
      and coalesce(ii.item_classification, 'simple') not in ('supply', 'smallware')
  ),
  per_item as (
    select
      m.item_id,
      sum(m.qty)    filter (where m.bucket = 'purchase')     as purchased_qty,
      sum(m.value)  filter (where m.bucket = 'purchase')     as purchased_value,
      -sum(m.qty)   filter (where m.bucket = 'consumption')  as consumed_qty,
      -sum(m.value) filter (where m.bucket = 'consumption')  as consumed_value,
      sum(m.qty)    filter (where m.bucket = 'produced')     as produced_qty,
      -sum(m.qty)   filter (where m.bucket = 'waste')        as waste_qty,
      -sum(m.value) filter (where m.bucket = 'waste')        as waste_value,
      sum(m.qty)    filter (where m.bucket = 'count_adjust') as count_adjust_qty,
      sum(m.value)  filter (where m.bucket = 'count_adjust') as count_adjust_value,
      sum(m.qty)    filter (where m.bucket = 'transfer')     as transfer_qty
    from mv m
    group by m.item_id
  ),
  reasons_per_item as (
    select r.item_id,
           jsonb_object_agg(r.reason, jsonb_build_object(
             'qty', r.qty, 'value', round(r.value, 2), 'count', r.cnt)) as by_reason
    from (
      select m.item_id, m.reason,
             -sum(m.qty) as qty, -sum(m.value) as value, count(*) as cnt
        from mv m
       where m.bucket = 'waste'
       group by m.item_id, m.reason
    ) r
    group by r.item_id
  ),
  stock as (
    select s.item_id, sum(s.quantity) as current_stock
      from public.inventory_stock s
      join public.warehouses w
        on w.id = s.warehouse_id
       and coalesce(w.is_active, true)
       and w.name is distinct from '__IN_TRANSIT__'
     where w.business_id = p_business_id
       and (p_warehouse_id is null or s.warehouse_id = p_warehouse_id)
     group by s.item_id
  ),
  items as (
    select coalesce(jsonb_agg(jsonb_build_object(
             'item_id',            ii.id,
             'item_name',          ii.name,
             'item_sku',           ii.sku,
             'item_unit',          ii.unit,
             'unit_cost',          coalesce(ii.cost, 0),
             'current_stock',      coalesce(st.current_stock, 0),
             'purchased_qty',      coalesce(p.purchased_qty, 0),
             'purchased_value',    round(coalesce(p.purchased_value, 0), 2),
             'consumed_qty',       coalesce(p.consumed_qty, 0),
             'consumed_value',     round(coalesce(p.consumed_value, 0), 2),
             'produced_qty',       coalesce(p.produced_qty, 0),
             'waste_qty',          coalesce(p.waste_qty, 0),
             'waste_value',        round(coalesce(p.waste_value, 0), 2),
             'count_adjust_qty',   coalesce(p.count_adjust_qty, 0),
             'count_adjust_value', round(coalesce(p.count_adjust_value, 0), 2),
             'transfer_qty',       coalesce(p.transfer_qty, 0),
             'waste_by_reason',    coalesce(r.by_reason, '{}'::jsonb)
           ) order by coalesce(p.waste_value, 0) desc, ii.name), '[]'::jsonb) as j
      from per_item p
      join public.inventory_items ii on ii.id = p.item_id
      left join reasons_per_item r on r.item_id = p.item_id
      left join stock st on st.item_id = p.item_id
     where ii.business_id = p_business_id
       and (coalesce(p.purchased_qty, 0) <> 0
            or coalesce(p.consumed_qty, 0) <> 0
            or coalesce(p.produced_qty, 0) <> 0
            or coalesce(p.waste_qty, 0) <> 0
            or coalesce(p.count_adjust_qty, 0) <> 0)
  ),
  reasons as (
    select coalesce(jsonb_agg(jsonb_build_object(
             'reason', x.reason, 'qty', x.qty,
             'value', round(x.value, 2), 'count', x.cnt
           ) order by x.value desc), '[]'::jsonb) as j
      from (
        select m.reason, -sum(m.qty) as qty, -sum(m.value) as value, count(*) as cnt
          from mv m
         where m.bucket = 'waste'
         group by m.reason
      ) x
  ),
  daily as (
    select coalesce(jsonb_agg(jsonb_build_object(
             'day', to_char(d.day, 'YYYY-MM-DD'),
             'consumed_value', round(coalesce(a.consumed_value, 0), 2),
             'waste_value',    round(coalesce(a.waste_value, 0), 2)
           ) order by d.day), '[]'::jsonb) as j
      from generate_series(v_today - (v_days - 1), v_today, interval '1 day') as d(day)
      left join (
        select m.day,
               -sum(m.value) filter (where m.bucket = 'consumption') as consumed_value,
               -sum(m.value) filter (where m.bucket = 'waste')       as waste_value
          from mv m
         group by m.day
      ) a on a.day = d.day::date
  )
  select jsonb_build_object(
           'from',      to_char(v_today - (v_days - 1), 'YYYY-MM-DD'),
           'to',        to_char(v_today, 'YYYY-MM-DD'),
           'days',      v_days,
           'items',     (select j from items),
           'by_reason', (select j from reasons),
           'daily',     (select j from daily)
         )
    into v_result;

  return v_result;
end;
$$;

revoke all on function public.fn_inventory_yield_analysis(uuid, int, uuid) from public;
revoke all on function public.fn_inventory_yield_analysis(uuid, int, uuid) from anon;
grant execute on function public.fn_inventory_yield_analysis(uuid, int, uuid) to authenticated;

comment on function public.fn_inventory_yield_analysis(uuid, int, uuid) is
  'Rendimiento por insumo (sin gastables ni menaje) en los últimos p_days_back '
  'días de RD: compra, consumo (ventas + producción + consumo interno, neto), '
  'merma por motivo, ajustes de conteo. Solo lee. Ver 20260930_0050 y 0051.';

-- 2c. Panel «Gastables y menaje».
--
-- Por cada gastable y cada pieza de menaje ACTIVA del negocio (tenga o no
-- movimientos: el menaje que nunca se rompe también tiene que verse contra su
-- par), en el período:
--
--   purchased   compras (netas)
--   sold        salió por venta o producción (un vaso para llevar metido en
--               una receta): neto de devoluciones
--   used        consumo interno (internal_use)
--   broken      rotura
--   lost        faltante / robo
--   other_out   las demás salidas (vencido, limpieza, donación, sin motivo,
--               producto quitado de la cuenta)
--   count_adjust diferencias de conteo — en el menaje, las copas que faltaron
--               al contar sin que nadie reportara rotura
--
-- El motivo se lee igual que en el rendimiento: reason_code, si no el prefijo
-- de la nota. Las existencias no cuentan la bodega de tránsito. El mínimo (el
-- «par» del menaje) es el de la bodega elegida si tiene uno; si no, el del
-- insumo — el mismo criterio que el pedido sugerido (20260915_0006).
--
-- DEVUELVE jsonb:
--   { from, to, days,
--     items: [{ item_id, item_name, item_sku, item_unit, classification,
--               unit_cost, stock, min_stock, min_source,
--               purchased_qty, purchased_value, sold_qty, sold_value,
--               used_qty, used_value, broken_qty, broken_value,
--               lost_qty, lost_value, other_out_qty, other_out_value,
--               count_adjust_qty, count_adjust_value,
--               by_warehouse: [{ warehouse_id, warehouse_name, qty, min_stock }] }],
--     by_destination: [{ destination, value, count }] }   -- consumo interno
create or replace function public.fn_inventory_supplies_overview(
  p_business_id  uuid,
  p_days_back    int  default 30,
  p_warehouse_id uuid default null
)
returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  v_days   int;
  v_today  date;
  v_from   timestamptz;
  v_result jsonb;
begin
  if p_business_id is null then
    raise exception 'MISSING_REQUIRED_PARAMS';
  end if;
  if not public.user_has_business_access(auth.uid(), p_business_id) then
    raise exception 'NOT_AUTHORIZED';
  end if;

  v_days  := least(greatest(abs(coalesce(nullif(p_days_back, 0), 30)), 1), 366);
  v_today := (now() at time zone 'America/Santo_Domingo')::date;
  v_from  := ((v_today - (v_days - 1))::timestamp) at time zone 'America/Santo_Domingo';

  with it as materialized (
    select ii.id, ii.name, ii.sku, ii.unit, coalesce(ii.cost, 0) as cost,
           coalesce(ii.min_stock, 0) as min_stock,
           ii.item_classification as classification
      from public.inventory_items ii
     where ii.business_id = p_business_id
       and coalesce(ii.is_active, true)
       and ii.item_classification in ('supply', 'smallware')
  ),
  wh as (
    select w.id, w.name
      from public.warehouses w
     where w.business_id = p_business_id
       and coalesce(w.is_active, true)
       and w.name is distinct from '__IN_TRANSIT__'
       and (p_warehouse_id is null or w.id = p_warehouse_id)
  ),
  st as (
    select s.item_id, s.warehouse_id, wh.name as warehouse_name,
           coalesce(s.quantity, 0) as qty, s.min_stock
      from public.inventory_stock s
      join wh on wh.id = s.warehouse_id
      join it on it.id = s.item_id
  ),
  st_item as (
    select st.item_id,
           sum(st.qty) as qty,
           -- Mínimo de bodega: solo con UNA bodega elegida (igual que 0006).
           max(st.min_stock) filter (where p_warehouse_id is not null) as wh_min,
           jsonb_agg(jsonb_build_object(
             'warehouse_id',   st.warehouse_id,
             'warehouse_name', st.warehouse_name,
             'qty',            st.qty,
             'min_stock',      st.min_stock
           ) order by st.qty desc, st.warehouse_name) as by_warehouse
      from st
     group by st.item_id
  ),
  mv as materialized (
    select im.item_id, im.quantity as qty,
           im.quantity * coalesce(nullif(im.cost_per_unit, 0), it.cost) as value,
           im.destination,
           case
             when im.movement_type::text = 'purchase' then 'purchase'
             when im.movement_type::text in ('sale', 'production_out', 'return') then 'sold'
             -- Un ajuste es salida solo si el MOTIVO GUARDADO lo es (igual que
             -- en el rendimiento): un conteo con «Vencido» en la nota es conteo.
             when im.movement_type::text = 'waste'
               or (im.movement_type::text = 'adjustment' and im.quantity < 0
                   and im.reason_code in ('breakage','expiration','cleaning','theft',
                                          'donation','internal_use'))
               then case r.reason
                      when 'internal_use' then 'used'
                      when 'breakage'     then 'broken'
                      when 'theft'        then 'lost'
                      else 'other_out'
                    end
             when im.movement_type::text = 'adjustment' then 'count_adjust'
             else 'other'
           end as bucket
      from public.inventory_movements im
      join it on it.id = im.item_id
      cross join lateral (
        select coalesce(
          case when im.reason_code in ('breakage','expiration','cleaning','theft',
                                       'donation','internal_use')
               then im.reason_code end,
          case split_part(coalesce(im.notes, ''), ' — ', 1)
            when 'Rotura / dañado'     then 'breakage'
            when 'Vencido'             then 'expiration'
            when 'Limpieza'            then 'cleaning'
            when 'Faltante / robo'     then 'theft'
            when 'Donación / cortesía' then 'donation'
            when 'Consumo interno'     then 'internal_use'
          end) as reason
      ) r
     where im.business_id = p_business_id
       and im.created_at >= v_from
       and (p_warehouse_id is null or im.warehouse_id = p_warehouse_id)
  ),
  agg as (
    select m.item_id,
      sum(m.qty)    filter (where m.bucket = 'purchase')     as purchased_qty,
      sum(m.value)  filter (where m.bucket = 'purchase')     as purchased_value,
      -sum(m.qty)   filter (where m.bucket = 'sold')         as sold_qty,
      -sum(m.value) filter (where m.bucket = 'sold')         as sold_value,
      -sum(m.qty)   filter (where m.bucket = 'used')         as used_qty,
      -sum(m.value) filter (where m.bucket = 'used')         as used_value,
      -sum(m.qty)   filter (where m.bucket = 'broken')       as broken_qty,
      -sum(m.value) filter (where m.bucket = 'broken')       as broken_value,
      -sum(m.qty)   filter (where m.bucket = 'lost')         as lost_qty,
      -sum(m.value) filter (where m.bucket = 'lost')         as lost_value,
      -sum(m.qty)   filter (where m.bucket = 'other_out')    as other_out_qty,
      -sum(m.value) filter (where m.bucket = 'other_out')    as other_out_value,
      sum(m.qty)    filter (where m.bucket = 'count_adjust') as count_adjust_qty,
      sum(m.value)  filter (where m.bucket = 'count_adjust') as count_adjust_value
    from mv m
    group by m.item_id
  ),
  items as (
    select coalesce(jsonb_agg(jsonb_build_object(
             'item_id',            it.id,
             'item_name',          it.name,
             'item_sku',           it.sku,
             'item_unit',          it.unit,
             'classification',     it.classification,
             'unit_cost',          it.cost,
             'stock',              coalesce(s.qty, 0),
             'min_stock',          case when s.wh_min is not null then s.wh_min
                                        else it.min_stock end,
             'min_source',         case when s.wh_min is not null then 'almacen'
                                        else 'insumo' end,
             'purchased_qty',      coalesce(a.purchased_qty, 0),
             'purchased_value',    round(coalesce(a.purchased_value, 0), 2),
             'sold_qty',           coalesce(a.sold_qty, 0),
             'sold_value',         round(coalesce(a.sold_value, 0), 2),
             'used_qty',           coalesce(a.used_qty, 0),
             'used_value',         round(coalesce(a.used_value, 0), 2),
             'broken_qty',         coalesce(a.broken_qty, 0),
             'broken_value',       round(coalesce(a.broken_value, 0), 2),
             'lost_qty',           coalesce(a.lost_qty, 0),
             'lost_value',         round(coalesce(a.lost_value, 0), 2),
             'other_out_qty',      coalesce(a.other_out_qty, 0),
             'other_out_value',    round(coalesce(a.other_out_value, 0), 2),
             'count_adjust_qty',   coalesce(a.count_adjust_qty, 0),
             'count_adjust_value', round(coalesce(a.count_adjust_value, 0), 2),
             'by_warehouse',       coalesce(s.by_warehouse, '[]'::jsonb)
           ) order by it.classification, it.name), '[]'::jsonb) as j
      from it
      left join st_item s on s.item_id = it.id
      left join agg a on a.item_id = it.id
  ),
  destinations as (
    select coalesce(jsonb_agg(jsonb_build_object(
             'destination', d.destination,
             'value',       round(d.value, 2),
             'count',       d.cnt
           ) order by d.value desc, d.destination nulls last), '[]'::jsonb) as j
      from (
        select nullif(btrim(m.destination), '') as destination,
               -sum(m.value) as value, count(*) as cnt
          from mv m
         where m.bucket = 'used'
         group by 1
      ) d
  )
  select jsonb_build_object(
           'from',           to_char(v_today - (v_days - 1), 'YYYY-MM-DD'),
           'to',             to_char(v_today, 'YYYY-MM-DD'),
           'days',           v_days,
           'items',          (select j from items),
           'by_destination', (select j from destinations)
         )
    into v_result;

  return v_result;
end;
$$;

revoke all on function public.fn_inventory_supplies_overview(uuid, int, uuid) from public;
revoke all on function public.fn_inventory_supplies_overview(uuid, int, uuid) from anon;
grant execute on function public.fn_inventory_supplies_overview(uuid, int, uuid) to authenticated;

comment on function public.fn_inventory_supplies_overview(uuid, int, uuid) is
  'Gastables y menaje: existencia contra mínimo/par, compras, consumo interno '
  '(por área), roturas, pérdidas y diferencias de conteo en el período. Solo '
  'lee. Ver 20260930_0051.';

notify pgrst, 'reload schema';

commit;

-- ── 3. Validar los CHECK (no bloquea ventas; si tarda, se puede cortar) ──────
-- NOT VALID ya protege las filas nuevas; esto solo confirma las viejas.
do $$
begin
  if exists (select 1 from pg_constraint
              where conname = 'inventory_items_classification_check'
                and conrelid = 'public.inventory_items'::regclass
                and not convalidated) then
    alter table public.inventory_items
      validate constraint inventory_items_classification_check;
  end if;
end
$$;

do $$
begin
  if exists (select 1 from pg_constraint
              where conname = 'inventory_movements_reason_code_check'
                and conrelid = 'public.inventory_movements'::regclass
                and not convalidated) then
    alter table public.inventory_movements
      validate constraint inventory_movements_reason_code_check;
  end if;
end
$$;
