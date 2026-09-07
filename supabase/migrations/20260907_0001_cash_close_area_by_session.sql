-- =============================================================================
-- 20260907_0001 — Desglose por área del CIERRE acotado a la SESIÓN de caja
-- =============================================================================
--
-- BUG DE CAMPO (07/09/2026, Barra Payán). En un local con DOS registradoras, el
-- ticket de cierre cuadraba arriba (RD$500, 1 transacción — eso sale por
-- `session_id`) pero abajo "VENTAS POR AREA DE PRODUCCION" imprimía RD$925:
-- estaba sumando las ventas de la OTRA caja.
--
-- Causa: `print_service` pide los dos desgloses con `(_business_id, _from, _to)`
-- usando la VENTANA DE TIEMPO de la sesión. Eso barre todo lo que el negocio
-- vendió en ese rato, venga de la caja que venga. Con una sola registradora
-- coincidía y por eso nunca se notó.
--
-- El vínculo correcto ya existe: `payments.session_id`.
--
-- ESTRATEGIA: ADITIVA. Dos funciones NUEVAS acotadas por sesión.
--   - NO se toca `get_sales_summary_v2`: la vive el dashboard y los reportes,
--     su definición viva DIVERGE del repo (trae el bloque de costos/márgenes
--     RF-R1 que no está en ninguna migración), y agregarle un parámetro con
--     default volvería AMBIGUAS las llamadas de 3 argumentos que ya existen.
--   - NO se toca `get_products_by_production_area` por lo mismo.
-- Si algo falla, la app cae al camino de hoy y el cierre sale como siempre.
--
-- Se copia EXACTA la fórmula de reparto de `get_sales_summary_v2`
-- (`items_allocated`): lo cobrado por orden se reparte entre las líneas según
-- el peso de su bruto, para que los desgloses concilien con lo que se cobró y
-- no con la suma de precios de menú.
--
-- Sin impacto fiscal: no toca emisión, NCF ni fiscal_documents.
-- =============================================================================

begin;

-- ── Ventas por área, de UNA sesión de caja ───────────────────────────────────
create or replace function public.get_sales_by_production_area_for_session(
  _session_id uuid
)
returns jsonb
language plpgsql
stable security definer
set search_path to 'public'
as $function$
declare
  result      jsonb;
  v_business  uuid;
begin
  -- El negocio sale de la propia sesión (vía su registradora), no del caller:
  -- así no hay forma de pedir la sesión de un negocio y el desglose de otro.
  select cr.business_id into v_business
  from cash_register_sessions crs
  join cash_registers cr on cr.id = crs.cash_register_id
  where crs.id = _session_id;

  if v_business is null then
    return '[]'::jsonb;
  end if;

  -- Access check: mismo criterio que las otras RPC de reportes. El alias
  -- EXPLÍCITO de columna es obligatorio — sin él, `current_user_business_ids()`
  -- rompe con 42703 para `authenticated` (y nunca para service_role, por eso
  -- no se detecta en pruebas de admin).
  if auth.role() != 'service_role' then
    if not exists (
      select 1 from public.current_user_business_ids() as c(business_id)
      where c.business_id = v_business
    ) then
      raise exception 'access denied' using errcode = '42501';
    end if;
  end if;

  with
  -- LA DIFERENCIA con la versión por ventana de tiempo: se filtra por la
  -- sesión de caja, no por `created_at` entre dos horas.
  completed_payments as (
    select p.order_id, (p.amount - coalesce(p.change_amount, 0)) as net_amount
    from payments p
    where p.session_id = _session_id
      and (p.status = 'completed' or p.status is null)
  ),
  amount_by_order as (
    select order_id, sum(net_amount) as amount
    from completed_payments
    where order_id is not null
    group by order_id
  ),
  scoped_items as (
    select oi.order_id,
      coalesce(nullif(oi.qty, 0), oi.quantity, 0) as qty,
      (oi.subtotal + oi.tax) as gross_amount,
      coalesce(pa.name, nullif(oi.print_area_code, ''), 'Sin área') as area_name
    from order_items oi
    left join print_areas pa
      on pa.business_id = v_business and pa.code = oi.print_area_code
    where oi.business_id = v_business
      and oi.order_id in (select order_id from amount_by_order)
      and oi.status != 'void'
  ),
  order_gross as (
    select order_id, sum(gross_amount) as sum_gross
    from scoped_items group by order_id
  ),
  -- Reparto proporcional idéntico al de get_sales_summary_v2.
  items_allocated as (
    select i.*,
      case when og.sum_gross > 0
           then i.gross_amount * abo.amount / og.sum_gross
           else i.gross_amount end as alloc_amount
    from scoped_items i
    join order_gross og on og.order_id = i.order_id
    join amount_by_order abo on abo.order_id = i.order_id
  ),
  by_area as (
    select area_name as label,
      coalesce(sum(alloc_amount), 0) as amount,
      coalesce(sum(qty), 0) as quantity,
      count(distinct order_id) as count
    from items_allocated group by area_name
  )
  select coalesce(
    jsonb_agg(
      jsonb_build_object('label', label, 'amount', amount,
        'quantity', quantity, 'count', count)
      order by amount desc),
    '[]'::jsonb)
  into result
  from by_area;

  return result;
end;
$function$;

-- ── Productos por área, de UNA sesión de caja ────────────────────────────────
create or replace function public.get_products_by_production_area_for_session(
  _session_id uuid
)
returns jsonb
language plpgsql
stable security definer
set search_path to 'public'
as $function$
declare
  result      jsonb;
  v_business  uuid;
begin
  select cr.business_id into v_business
  from cash_register_sessions crs
  join cash_registers cr on cr.id = crs.cash_register_id
  where crs.id = _session_id;

  if v_business is null then
    return '[]'::jsonb;
  end if;

  if auth.role() != 'service_role' then
    if not exists (
      select 1 from public.current_user_business_ids() as c(business_id)
      where c.business_id = v_business
    ) then
      raise exception 'access denied' using errcode = '42501';
    end if;
  end if;

  with
  order_ids as (
    select distinct p.order_id
    from payments p
    where p.session_id = _session_id
      and (p.status = 'completed' or p.status is null)
      and p.order_id is not null
  ),
  scoped_items as (
    select
      coalesce(pa.name, nullif(oi.print_area_code, ''), 'Sin área') as area_name,
      oi.product_name,
      coalesce(nullif(oi.qty, 0), oi.quantity, 0) as qty
    from order_items oi
    left join print_areas pa
      on pa.business_id = v_business and pa.code = oi.print_area_code
    where oi.business_id = v_business
      and oi.order_id in (select order_id from order_ids)
      and oi.status != 'void'
  ),
  by_area_product as (
    select area_name, product_name,
      coalesce(sum(qty), 0) as quantity
    from scoped_items
    group by area_name, product_name
    having coalesce(sum(qty), 0) > 0
  ),
  by_area as (
    select area_name,
      sum(quantity) as area_quantity,
      jsonb_agg(
        jsonb_build_object('product', product_name, 'quantity', quantity)
        order by quantity desc, product_name
      ) as products
    from by_area_product
    group by area_name
  )
  select coalesce(
    jsonb_agg(
      jsonb_build_object('label', area_name, 'quantity', area_quantity,
        'products', products)
      order by area_quantity desc, area_name),
    '[]'::jsonb)
  into result
  from by_area;

  return result;
end;
$function$;

grant execute on function
  public.get_sales_by_production_area_for_session(uuid)
  to authenticated, service_role;

grant execute on function
  public.get_products_by_production_area_for_session(uuid)
  to authenticated, service_role;

comment on function public.get_sales_by_production_area_for_session(uuid) is
  'Ventas por área de producción de UNA sesión de caja (vía payments.session_id). '
  'Para el ticket de cierre en locales con varias registradoras, donde acotar '
  'por ventana de tiempo mezclaba las ventas de las otras cajas.';

comment on function public.get_products_by_production_area_for_session(uuid) is
  'Productos por área de producción de UNA sesión de caja (vía '
  'payments.session_id). Complemento por-producto de '
  'get_sales_by_production_area_for_session.';

commit;
