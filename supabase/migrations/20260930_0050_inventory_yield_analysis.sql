-- =============================================================================
-- 20260930_0050 — Rendimiento por insumo: cuánto de lo que se compra va a
-- producción / ventas y cuánto se pierde en merma (y por qué).
--
-- Numerada en el rango 0050+ a propósito (el dueño y el asistente trabajan en
-- paralelo y los dos contaban desde 0001).
--
-- PEDIDO DEL DUEÑO (2026-09-30): «en la parte de rendimiento por producto esas
-- mermas deben reflejarse, qué tanto es de producción de lo que se compra y
-- qué tanto es merma», con filtros por la razón de la merma.
--
-- POR QUÉ UNA FUNCIÓN NUEVA Y NO EL ANÁLISIS DE ROTACIÓN:
--   fn_inventory_rotation_analysis suma en un solo «outflow» las ventas, las
--   transferencias, las mermas y los ajustes. Para saber el rendimiento hay
--   que separarlos. Esta función clasifica cada movimiento del período:
--
--     compra        purchase (neto: incluye las reversas de editar/anular)
--     consumo       sale + production_out + return (neto: una venta anulada o
--                   un producto quitado de la cuenta devuelve con signo +)
--     producido     production_in (productos terminados)
--     merma         waste (salidas, mermas, producto quitado ya preparado) +
--                   ajustes NEGATIVOS con motivo de salida (rotura, vencido,
--                   limpieza, faltante, donación) — los que imprimen conduce
--     ajuste conteo el resto de los ajustes (conteo físico, corrección):
--                   ni producción ni merma declarada, se muestra aparte
--     transferencia transfer_in / transfer_out (solo con bodega elegida; en
--                   todo el negocio se cancelan entre sí)
--
--   Motivo de la merma: reason_code si es de salida; si no, «producto quitado
--   de la cuenta» (reference_type order_item_removal); si no, el prefijo de la
--   nota que la app guarda siempre («Vencido — …»); si no, «sin motivo».
--
--   Valor: costo del MOVIMIENTO; si no lo guardó, el costo actual del insumo.
--   Día: el de RD (America/Santo_Domingo), no el UTC.
--
-- DEVUELVE jsonb:
--   { from, to, days,
--     items:     [{ item_id, item_name, item_sku, item_unit, unit_cost,
--                   current_stock, purchased_qty, purchased_value,
--                   consumed_qty, consumed_value, produced_qty,
--                   waste_qty, waste_value, count_adjust_qty,
--                   count_adjust_value, transfer_qty,
--                   waste_by_reason: { <reason>: {qty, value, count} } }],
--     by_reason: [{ reason, qty, value, count }],
--     daily:     [{ day, consumed_value, waste_value }] }
--   Solo insumos con algún movimiento en el período.
--
-- SOLO LEE. SECURITY DEFINER con el mismo chequeo de acceso que la rotación.
-- IDEMPOTENTE: sí. REVERSIBLE: sí (_ROLLBACK).
-- =============================================================================

begin;

set local lock_timeout = '5s';

-- La columna viene de 20260513_0017; si una base no la tuviera, la función
-- fallaría con 42703 en vez de clasificar por la nota.
alter table public.inventory_movements
  add column if not exists reason_code text;

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

notify pgrst, 'reload schema';

commit;
