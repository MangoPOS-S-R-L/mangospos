-- =============================================================================
-- ROLLBACK de 20260930_0051_supplies_and_smallware.sql
--
-- GENERADO POR SCRIPT, no transcrito a mano: las funciones que vuelven son el
-- texto exacto de 20260928_0001 (salida de 8 parámetros) y de 20260930_0050
-- (rendimiento). Copiar a mano una versión intermedia ya borró funcionalidad
-- en silencio una vez.
--
-- SE NIEGA si ya hay datos que dependen de la 0051: insumos clasificados como
-- gastable o menaje, o salidas con motivo «Consumo interno». Achicar el CHECK
-- con esas filas dentro las dejaría inválidas. Primero reclasificarlas.
--
-- La columna `destination` solo se llena con internal_use: si no hay ninguna,
-- está vacía y se puede quitar sin perder nada.
-- =============================================================================

begin;

set local lock_timeout = '5s';

do $$
begin
  if exists (select 1 from public.inventory_items
              where item_classification in ('supply', 'smallware')) then
    raise exception 'ROLLBACK_BLOCKED: hay insumos clasificados como gastable o menaje. Reclasifícalos antes.';
  end if;
  if exists (select 1 from public.inventory_movements
              where reason_code = 'internal_use') then
    raise exception 'ROLLBACK_BLOCKED: hay salidas con motivo Consumo interno.';
  end if;
end
$$;

drop function if exists public.fn_inventory_supplies_overview(uuid, int, uuid);

drop function if exists public.fn_inventory_record_outflow(
  uuid, uuid, uuid, numeric, text, text, numeric, uuid, text
);

-- ── Salida de 8 parámetros, tal cual 20260928_0001 ──
create or replace function public.fn_inventory_record_outflow(
  p_business_id uuid,
  p_warehouse_id uuid,
  p_item_id uuid,
  p_quantity numeric,
  p_reason_code text,
  p_notes text default null,
  p_cost_per_unit numeric default null,
  p_reference_id uuid default null
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
begin
  if p_quantity is null or p_quantity <= 0 then
    raise exception 'INVALID_QUANTITY';
  end if;
  if p_reason_code is null
     or p_reason_code not in (
       'breakage', 'expiration', 'cleaning', 'theft', 'donation'
     ) then
    raise exception 'INVALID_OUTFLOW_REASON: %', coalesce(p_reason_code, 'null');
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
    -- Sin costo de la app: el del insumo, para que el kardex valore la merma.
    select ii.cost into v_item_cost
      from public.inventory_items ii
     where ii.id = p_item_id and ii.business_id = p_business_id;
    update public.inventory_movements
       set cost_per_unit = v_item_cost
     where id = v_movement_id
       and cost_per_unit is null
       and v_item_cost is not null;

    begin
      update public.inventory_movements
         set reason_code = p_reason_code
       where id = v_movement_id;
    exception when check_violation then
      -- CHECK viejo (sin 'cleaning'): la salida ya quedó; el motivo viaja en
      -- la nota que armó la app.
      null;
    end;
  end if;

  return v_result || jsonb_build_object('reason_code', p_reason_code, 'replayed', false);
end;
$$;

revoke all on function public.fn_inventory_record_outflow(
  uuid, uuid, uuid, numeric, text, text, numeric, uuid
) from public;
revoke all on function public.fn_inventory_record_outflow(
  uuid, uuid, uuid, numeric, text, text, numeric, uuid
) from anon;
grant execute on function public.fn_inventory_record_outflow(
  uuid, uuid, uuid, numeric, text, text, numeric, uuid
) to authenticated;

-- ── Rendimiento, tal cual 20260930_0050 ──
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
      case when b.bucket = 'waste' then
        coalesce(
          case when im.reason_code in ('breakage','expiration','cleaning','theft','donation')
               then im.reason_code end,
          case when im.reference_type = 'order_item_removal' then 'order_removal' end,
          case split_part(coalesce(im.notes, ''), ' — ', 1)
            when 'Rotura / dañado'     then 'breakage'
            when 'Vencido'             then 'expiration'
            when 'Limpieza'            then 'cleaning'
            when 'Faltante / robo'     then 'theft'
            when 'Donación / cortesía' then 'donation'
          end,
          'unspecified')
      end as reason,
      im.quantity as qty,
      im.quantity * coalesce(nullif(im.cost_per_unit, 0), ii.cost, 0) as value,
      (im.created_at at time zone 'America/Santo_Domingo')::date as day
    from public.inventory_movements im
    join public.inventory_items ii on ii.id = im.item_id
    cross join lateral (
      select case
        when im.movement_type::text = 'purchase' then 'purchase'
        when im.movement_type::text in ('sale', 'production_out', 'return') then 'consumption'
        when im.movement_type::text = 'production_in' then 'produced'
        when im.movement_type::text = 'waste' then 'waste'
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
  'Rendimiento por insumo en los últimos p_days_back días de RD: compra, '
  'consumo (ventas + producción, neto), merma por motivo, ajustes de conteo. '
  'Solo lee. Ver 20260930_0050.';

-- ── CHECK sin los valores nuevos (reconstruido desde el vivo) ──
do $$
declare
  v_def   text;
  v_codes text[];
begin
  select pg_get_constraintdef(c.oid) into v_def
    from pg_constraint c
   where c.conname = 'inventory_items_classification_check'
     and c.conrelid = 'public.inventory_items'::regclass;
  if v_def is not null then
    select array(
      select distinct v
        from regexp_matches(v_def, '''([^'']*)''', 'g') m,
             unnest(string_to_array(btrim(m[1], '{}'), ',')) v
       where v <> '' and v not in ('supply', 'smallware')
       order by 1)
      into v_codes;
    alter table public.inventory_items
      drop constraint inventory_items_classification_check;
    execute format(
      'alter table public.inventory_items
         add constraint inventory_items_classification_check
         check (item_classification = any (array[%s]::text[]))',
      (select string_agg(quote_literal(x), ', ' order by x) from unnest(v_codes) x));
  end if;

  select pg_get_constraintdef(c.oid) into v_def
    from pg_constraint c
   where c.conname = 'inventory_movements_reason_code_check'
     and c.conrelid = 'public.inventory_movements'::regclass;
  if v_def is not null then
    select array(
      select distinct v
        from regexp_matches(v_def, '''([^'']*)''', 'g') m,
             unnest(string_to_array(btrim(m[1], '{}'), ',')) v
       where v <> '' and v <> 'internal_use'
       order by 1)
      into v_codes;
    alter table public.inventory_movements
      drop constraint inventory_movements_reason_code_check;
    -- NOT VALID: las filas viejas ya cumplían (se verificó arriba que no hay
    -- internal_use) y así no se recorre la tabla con el candado tomado.
    execute format(
      'alter table public.inventory_movements
         add constraint inventory_movements_reason_code_check
         check (reason_code is null or reason_code = any (array[%s]::text[])) not valid',
      (select string_agg(quote_literal(x), ', ' order by x) from unnest(v_codes) x));
  end if;
end
$$;

alter table public.inventory_movements drop column if exists destination;

notify pgrst, 'reload schema';

commit;
