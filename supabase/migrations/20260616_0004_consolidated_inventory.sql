-- =============================================================================
-- 20260616_0004 — Inventario multisucursal: stock consolidado (panel de totales)
-- =============================================================================
--
-- Modelo: cada sucursal es su propio business_id (datos aislados). "La cadena"
-- = los negocios con el MISMO owner_id. Esta RPC arma el "almacén principal":
-- el stock de un producto en TODAS las sucursales del dueño, emparejado por SKU
-- (la misma llave que ya usan las transferencias cross-sucursal), con desglose
-- por sucursal + total + valuación.
--
-- Aditiva y de SOLO LECTURA: no toca pagos, NCF, caja, ventas ni el inventario
-- de cada sucursal. Solo agrega una vista consolidada para el dueño.
--
-- Acceso: SECURITY DEFINER con check explícito — el usuario debe pertenecer al
-- negocio ancla, y solo se consolidan las sucursales del mismo dueño a las que
-- el usuario tiene acceso (current_user_business_ids()).
-- =============================================================================

begin;

create or replace function public.get_consolidated_inventory(
  _anchor_business_id uuid
)
returns jsonb
language plpgsql
stable security definer
set search_path to 'public'
as $function$
declare
  v_owner uuid;
  result  jsonb;
begin
  -- El usuario debe pertenecer al negocio ancla. current_user_business_ids()
  -- devuelve SETOF uuid (escalar), así que el alias ES el valor.
  if not exists (
    select 1 from public.current_user_business_ids() as bid
    where bid = _anchor_business_id
  ) then
    raise exception 'access denied' using errcode = '42501';
  end if;

  select owner_id into v_owner
  from public.businesses
  where id = _anchor_business_id;

  if v_owner is null then
    return jsonb_build_object('branches', '[]'::jsonb, 'products', '[]'::jsonb);
  end if;

  with
  -- Sucursales de la cadena (mismo dueño) a las que el usuario tiene acceso.
  branch_set as (
    select b.id,
           coalesce(nullif(b.branch_name, ''), b.business_name) as name
    from public.businesses b
    where b.owner_id = v_owner
      and b.status = 'active'
      and b.id in (select bid from public.current_user_business_ids() as bid)
  ),
  -- Stock por (sucursal, item) sumando almacenes reales (sin __IN_TRANSIT__).
  stock_rows as (
    select
      w.business_id,
      coalesce(nullif(ii.sku, ''), 'name:' || lower(ii.name)) as match_key,
      ii.name,
      ii.unit,
      ii.sku,
      ii.min_stock,
      coalesce(ii.cost, 0) as cost,
      sum(s.quantity)      as qty
    from public.inventory_stock s
    join public.warehouses w       on w.id = s.warehouse_id
    join public.inventory_items ii on ii.id = s.item_id
    where w.business_id in (select id from branch_set)
      and coalesce(w.name, '') <> '__IN_TRANSIT__'
      and ii.is_active is distinct from false
    group by w.business_id, match_key, ii.name, ii.unit, ii.sku,
             ii.min_stock, ii.cost
  ),
  -- Consolidado por producto (match_key) con desglose por sucursal.
  by_product as (
    select
      match_key,
      max(name) as name,
      max(unit) as unit,
      max(sku)  as sku,
      sum(qty)  as total_qty,
      sum(qty * cost) as total_value,
      jsonb_agg(
        jsonb_build_object(
          'business_id', business_id,
          'qty',        qty,
          'value',      qty * cost,
          'min_stock',  min_stock
        ) order by business_id
      ) as by_branch
    from stock_rows
    group by match_key
  )
  select jsonb_build_object(
    'branches', coalesce(
      (select jsonb_agg(
         jsonb_build_object('business_id', id, 'name', name) order by name)
       from branch_set), '[]'::jsonb),
    'products', coalesce(
      (select jsonb_agg(
         jsonb_build_object(
           'sku',        sku,
           'name',       name,
           'unit',       unit,
           'total_qty',  total_qty,
           'total_value', total_value,
           'by_branch',  by_branch
         ) order by name)
       from by_product), '[]'::jsonb)
  ) into result;

  return result;
end;
$function$;

grant execute on function public.get_consolidated_inventory(uuid)
  to authenticated, service_role;

comment on function public.get_consolidated_inventory(uuid) is
  'Inventario multisucursal (panel de totales): stock por producto (emparejado '
  'por SKU) en todas las sucursales del mismo dueño, con desglose por sucursal '
  '+ total + valuación. Solo lectura; no afecta el inventario de cada sucursal.';

commit;
