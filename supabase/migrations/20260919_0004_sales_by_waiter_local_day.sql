-- =============================================================================
-- Ventas por mesero: día LOCAL del negocio + franja horaria por noche.
--
-- (1) BUG DEL CORTE DE DÍA
--   `fn_sales_by_waiter` y `fn_sales_by_waiter_products` filtraban con
--   `oi.created_at::date between p_from_date and p_to_date`.
--   `order_items.created_at` es timestamptz, así que `::date` se resuelve en
--   el TimeZone de la sesión de Postgres — UTC en PostgREST. En RD (UTC-4)
--   eso corta el día a las 8:00 PM locales: todo lo que un mesero vendió
--   después de las 8 PM cae en el día SIGUIENTE. Medido en el negocio
--   6d13ed3f (nocturno) el 2026-09-19: 610 de 666 ítems (92%) y RD$3,880,400
--   de RD$4,151,400 (93%) no salían en el día que les tocaba.
--   La caja nunca fue el filtro: el reporte ya incluye órdenes abiertas y sin
--   cobrar; lo que fallaba era el corte de día. Misma trampa ya documentada en
--   20260902_0014_analytics_cost_layers.sql.
--
-- (2) FRANJA HORARIA (p_start_time / p_end_time)
--   Para un negocio nocturno el "día" no es 00:00-24:00. La franja se aplica
--   a CADA día del rango, y si la hora de fin es <= la de inicio se entiende
--   que cruza la medianoche:
--       rango 13..19 + franja 20:00->03:00
--       = noche del 13 (13 20:00 -> 14 03:00) ... noche del 19 (19 20:00 -> 20 03:00)
--   El default 00:00/00:00 cae solo en la rama "cruza" y reproduce exactamente
--   el día local completo, así que las llamadas viejas (4 args) no cambian.
--
-- IMPLEMENTACIÓN: se resuelve la zona del negocio (`business_settings.timezone`,
--   default 'America/Santo_Domingo' — mismo patrón de fn_mall_sales_export y
--   del módulo de contabilidad) y se acota con
--       [from + start, to (+1 si cruza) + end)
--   más un predicado sobre la hora local. Ese par es EQUIVALENTE a filtrar por
--   "noche a la que pertenece el ítem" (demostrado por los dos extremos) y
--   además es sargable: la cota usa índice sobre created_at en vez de castear
--   cada fila.
--
-- No cambia atribución ni filtros de anulación. La app sigue pudiendo llamar
-- con 4 args; manda p_start_time/p_end_time solo cuando el usuario elige franja.
--
-- IDEMPOTENTE: drop de las firmas previas (3 y 4 args) + create. El drop es
-- OBLIGATORIO: si quedaran dos firmas, PostgREST no resuelve por nombre
-- (PGRST203 ambiguous).
-- =============================================================================

begin;

drop function if exists public.fn_sales_by_waiter(uuid, date, date);
drop function if exists public.fn_sales_by_waiter(uuid, date, date, text);
drop function if exists public.fn_sales_by_waiter_products(uuid, date, date, text);

create or replace function public.fn_sales_by_waiter(
  p_business_id uuid,
  p_from_date date,
  p_to_date date,
  p_search text default null,
  p_start_time time default '00:00',
  p_end_time time default '00:00'
)
returns table (
  employee_id uuid,
  employee_name text,
  orders_count bigint,
  items_count bigint,
  units numeric,
  gross_amount numeric,
  discounts_amount numeric,
  net_amount numeric
)
language plpgsql
security definer
set search_path = public
as $$
declare
  v_search text := nullif(btrim(coalesce(p_search, '')), '');
  v_start time := coalesce(p_start_time, time '00:00');
  v_end   time := coalesce(p_end_time, time '00:00');
  v_cross boolean;
  v_tz text;
  v_from timestamptz;
  v_to timestamptz;
begin
  if p_business_id is null then
    raise exception 'BUSINESS_ID_REQUIRED';
  end if;
  if p_from_date is null or p_to_date is null then
    raise exception 'DATE_RANGE_REQUIRED';
  end if;
  if not public.user_has_business_access(auth.uid(), p_business_id) then
    raise exception 'UNAUTHORIZED_BUSINESS';
  end if;

  select coalesce(bs.timezone, 'America/Santo_Domingo')
    into v_tz
  from public.business_settings bs
  where bs.business_id = p_business_id;
  v_tz := coalesce(v_tz, 'America/Santo_Domingo');

  -- fin <= inicio => la franja cruza la medianoche. El default (00:00/00:00)
  -- cae aquí y equivale al día local completo.
  v_cross := v_end <= v_start;
  v_from := (p_from_date + v_start) at time zone v_tz;
  v_to   := ((p_to_date + (case when v_cross then 1 else 0 end)) + v_end)
              at time zone v_tz;

  return query
  with attributed_items as (
    select
      coalesce(oi.created_by_employee_id, ts.opened_by_employee_id) as emp_id,
      oi.order_id,
      coalesce(oi.qty, oi.quantity::numeric, 0) as units,
      oi.subtotal,
      oi.tax,
      coalesce(oi.discounts, 0) as discounts,
      oi.id as item_id
    from public.order_items oi
    join public.orders o on o.id = oi.order_id
    join public.table_sessions ts on ts.id = o.session_id
    where ts.business_id = p_business_id
      and oi.status <> 'void'
      and o.status_ext is distinct from 'void'
      and oi.created_at >= v_from
      and oi.created_at < v_to
      and (
        case
          when v_cross then
            ((oi.created_at at time zone v_tz)::time >= v_start
             or (oi.created_at at time zone v_tz)::time < v_end)
          else
            ((oi.created_at at time zone v_tz)::time >= v_start
             and (oi.created_at at time zone v_tz)::time < v_end)
        end
      )
      and coalesce(oi.created_by_employee_id, ts.opened_by_employee_id) is not null
      and (
        v_search is null
        or oi.product_name ilike '%' || v_search || '%'
        or oi.sku ilike '%' || v_search || '%'
      )
  )
  select
    ai.emp_id as employee_id,
    e.first_name || coalesce(' ' || nullif(btrim(e.last_name), ''), '')
      as employee_name,
    count(distinct ai.order_id)::bigint as orders_count,
    count(ai.item_id)::bigint as items_count,
    sum(ai.units) as units,
    sum(ai.subtotal + ai.tax) as gross_amount,
    sum(ai.discounts) as discounts_amount,
    sum(ai.subtotal + ai.tax - ai.discounts) as net_amount
  from attributed_items ai
  join public.employees e on e.id = ai.emp_id
  group by ai.emp_id, e.first_name, e.last_name
  order by net_amount desc nulls last;
end;
$$;

grant execute on function
  public.fn_sales_by_waiter(uuid, date, date, text, time, time)
  to authenticated;

comment on function
  public.fn_sales_by_waiter(uuid, date, date, text, time, time) is
  'Reporte de ventas por mesero. Atribuye cada item al empleado que lo '
  'agregó (created_by_employee_id), con fallback al que abrió la mesa '
  '(opened_by_employee_id). Items sin ninguna atribución quedan excluidos. '
  'p_search filtra items por product_name/sku (ilike). El rango es el DÍA '
  'LOCAL del negocio (business_settings.timezone); p_start_time/p_end_time '
  'acotan una franja horaria que se aplica a cada día del rango y cruza la '
  'medianoche cuando fin <= inicio (default 00:00/00:00 = día completo).';

create or replace function public.fn_sales_by_waiter_products(
  p_business_id uuid,
  p_from_date date,
  p_to_date date,
  p_search text default null,
  p_start_time time default '00:00',
  p_end_time time default '00:00'
)
returns table (
  employee_id uuid,
  employee_name text,
  product_name text,
  sku text,
  units numeric,
  items_count bigint,
  gross_amount numeric,
  discounts_amount numeric,
  net_amount numeric
)
language plpgsql
security definer
set search_path = public
as $$
declare
  v_search text := nullif(btrim(coalesce(p_search, '')), '');
  v_start time := coalesce(p_start_time, time '00:00');
  v_end   time := coalesce(p_end_time, time '00:00');
  v_cross boolean;
  v_tz text;
  v_from timestamptz;
  v_to timestamptz;
begin
  if p_business_id is null then
    raise exception 'BUSINESS_ID_REQUIRED';
  end if;
  if p_from_date is null or p_to_date is null then
    raise exception 'DATE_RANGE_REQUIRED';
  end if;
  if not public.user_has_business_access(auth.uid(), p_business_id) then
    raise exception 'UNAUTHORIZED_BUSINESS';
  end if;

  select coalesce(bs.timezone, 'America/Santo_Domingo')
    into v_tz
  from public.business_settings bs
  where bs.business_id = p_business_id;
  v_tz := coalesce(v_tz, 'America/Santo_Domingo');

  v_cross := v_end <= v_start;
  v_from := (p_from_date + v_start) at time zone v_tz;
  v_to   := ((p_to_date + (case when v_cross then 1 else 0 end)) + v_end)
              at time zone v_tz;

  return query
  with attributed_items as (
    select
      coalesce(oi.created_by_employee_id, ts.opened_by_employee_id) as emp_id,
      coalesce(nullif(btrim(oi.product_name), ''), 'Sin nombre')
        as prod_name,
      oi.sku as prod_sku,
      coalesce(oi.qty, oi.quantity::numeric, 0) as units,
      oi.subtotal,
      oi.tax,
      coalesce(oi.discounts, 0) as discounts,
      oi.id as item_id
    from public.order_items oi
    join public.orders o on o.id = oi.order_id
    join public.table_sessions ts on ts.id = o.session_id
    where ts.business_id = p_business_id
      and oi.status <> 'void'
      and o.status_ext is distinct from 'void'
      and oi.created_at >= v_from
      and oi.created_at < v_to
      and (
        case
          when v_cross then
            ((oi.created_at at time zone v_tz)::time >= v_start
             or (oi.created_at at time zone v_tz)::time < v_end)
          else
            ((oi.created_at at time zone v_tz)::time >= v_start
             and (oi.created_at at time zone v_tz)::time < v_end)
        end
      )
      and coalesce(oi.created_by_employee_id, ts.opened_by_employee_id) is not null
      and (
        v_search is null
        or oi.product_name ilike '%' || v_search || '%'
        or oi.sku ilike '%' || v_search || '%'
      )
  )
  select
    ai.emp_id as employee_id,
    e.first_name || coalesce(' ' || nullif(btrim(e.last_name), ''), '')
      as employee_name,
    ai.prod_name as product_name,
    max(ai.prod_sku) as sku,
    sum(ai.units) as units,
    count(ai.item_id)::bigint as items_count,
    sum(ai.subtotal + ai.tax) as gross_amount,
    sum(ai.discounts) as discounts_amount,
    sum(ai.subtotal + ai.tax - ai.discounts) as net_amount
  from attributed_items ai
  join public.employees e on e.id = ai.emp_id
  group by ai.emp_id, e.first_name, e.last_name, ai.prod_name
  order by employee_name asc, net_amount desc nulls last;
end;
$$;

grant execute on function
  public.fn_sales_by_waiter_products(uuid, date, date, text, time, time)
  to authenticated;

comment on function
  public.fn_sales_by_waiter_products(uuid, date, date, text, time, time) is
  'Desglose de productos vendidos por cada mesero. Una fila por '
  '(empleado, producto). Misma atribución, filtro p_search, día local y '
  'franja horaria que fn_sales_by_waiter.';

commit;
