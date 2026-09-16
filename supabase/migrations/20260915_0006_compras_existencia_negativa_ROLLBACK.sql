-- =============================================================================
-- ROLLBACK de 20260915_0006_compras_existencia_negativa
-- Vuelve a poner la definición EXACTA de la 0004 (la existencia negativa se
-- resta tal cual). No escribe datos.
-- =============================================================================

begin;

set local lock_timeout = '5s';
set local statement_timeout = '60s';

do $guard$
begin
  if not exists (
    select 1 from pg_proc p join pg_namespace n on n.oid = p.pronamespace
     where n.nspname = 'public' and p.proname = 'fn_purchase_resolve_suppliers'
  ) then
    raise exception 'Falta aplicar 20260915_0003 (fn_purchase_resolve_suppliers). No se aplicó nada.';
  end if;
end
$guard$;

create or replace function public.fn_purchase_projection(
  p_business_id            uuid,
  p_warehouse_id           uuid    default null,
  p_coverage_days          integer default 7,
  p_days_back              integer default 30,
  p_default_lead_time_days integer default 2,
  p_safety_days            integer default 3,
  p_supplier_id            uuid    default null,
  p_only_needed            boolean default false
)
returns table (
  item_id              uuid,
  item_name            text,
  sku                  text,
  unit                 text,
  item_classification  text,
  stock                numeric,
  in_transit           numeric,
  on_order             numeric,
  consumption          numeric,
  window_days          integer,
  daily_consumption    numeric,
  min_stock            numeric,
  min_stock_source     text,
  lead_time_days       integer,
  lead_time_is_default boolean,
  target               numeric,
  suggested_base       numeric,
  days_of_supply       numeric,
  suggested_min_stock  numeric,
  supplier_id          uuid,
  supplier_name        text,
  supplier_source      text,
  purchase_unit        text,
  pack_size            numeric,
  min_order_qty        numeric,
  unit_cost_base       numeric,
  cost_source          text,
  estimated_cost       numeric
)
language sql
stable
security invoker
set search_path = public
as $$
  with params as (
    select greatest(coalesce(p_coverage_days, 7), 0)              as coverage,
           greatest(coalesce(nullif(p_days_back, 0), 30), 1)      as days_back,
           greatest(coalesce(p_default_lead_time_days, 2), 0)     as default_lead,
           greatest(coalesce(p_safety_days, 3), 0)                as safety
  ),
  -- Almacenes que cuentan: el elegido, o todos los activos del negocio sin el
  -- de tránsito (la mercancía en camino se suma aparte, una sola vez).
  wh as (
    select w.id
      from public.warehouses w
     where w.business_id = p_business_id
       and coalesce(w.is_active, true)
       and w.name is distinct from '__IN_TRANSIT__'
       and (p_warehouse_id is null or w.id = p_warehouse_id)
  ),
  items as (
    select ii.id, ii.name, ii.sku, ii.unit, ii.min_stock,
           coalesce(ii.item_classification, 'simple') as item_classification
      from public.inventory_items ii
     where ii.business_id = p_business_id
       and coalesce(ii.is_active, true)
       and coalesce(ii.item_classification, 'simple') not in ('service', 'combo')
  ),
  stock as (
    select s.item_id,
           sum(s.quantity) as qty,
           -- Mínimo del almacén: solo tiene sentido con UN almacén elegido.
           max(s.min_stock) filter (where p_warehouse_id is not null) as wh_min
      from public.inventory_stock s
      join wh on wh.id = s.warehouse_id
     group by s.item_id
  ),
  -- Enviado y no recibido hacia un almacén que cuenta. Entre negocios, la línea
  -- trae el insumo del negocio que ENVÍA y `target_item_id` se llena recién al
  -- recibir: se casa aquí igual que fn_inventory_resolve_item_for_business
  -- (SKU sin mayúsculas ni espacios, luego nombre). Lo que aquí no existe se
  -- crea al recibir y hoy no tiene fila que proyectar. `target_item_id` se lee
  -- por JSON: en una base sin 20260514_0004 la columna no existe.
  transit_lines as (
    select (to_jsonb(sti) ->> 'target_item_id')::uuid as target_item_id,
           src.id          as source_item_id,
           src.business_id as source_business_id,
           nullif(btrim(src.sku), '') as source_sku,
           btrim(src.name) as source_name,
           sti.quantity_sent
      from public.stock_transfer_items sti
      join public.stock_transfers st on st.id = sti.stock_transfer_id
      join wh on wh.id = st.to_warehouse_id
      left join public.inventory_items src on src.id = sti.item_id
     where st.status = 'sent'
  ),
  transit_resolved as (
    select coalesce(
             tl.target_item_id,
             case when tl.source_business_id = p_business_id then tl.source_item_id end,
             (select t.id from public.inventory_items t
               where t.business_id = p_business_id
                 and tl.source_sku is not null
                 and lower(btrim(t.sku)) = lower(tl.source_sku)
               limit 1),
             (select t.id from public.inventory_items t
               where t.business_id = p_business_id
                 and lower(btrim(t.name)) = lower(tl.source_name)
               limit 1)
           ) as item_id,
           tl.quantity_sent
      from transit_lines tl
  ),
  transit as (
    select tr.item_id, sum(tr.quantity_sent) as qty
      from transit_resolved tr
     where tr.item_id is not null
     group by tr.item_id
  ),
  -- Ya pedido y sin recibir: órdenes enviadas o parciales. Un borrador todavía
  -- no es un compromiso con el suplidor.
  on_order as (
    select poi.inventory_item_id as item_id,
           sum(greatest(poi.quantity_ordered - coalesce(poi.quantity_received, 0), 0)) as qty
      from public.purchase_order_items poi
      join public.purchase_orders po on po.id = poi.purchase_order_id
     where po.business_id = p_business_id
       and po.status::text in ('sent', 'partial')
       and (p_warehouse_id is null or po.warehouse_id = p_warehouse_id)
       and poi.inventory_item_id is not null
     group by 1
  ),
  movements as (
    select im.item_id,
           -sum(im.quantity) filter (
             where im.movement_type::text in ('sale', 'waste', 'production_out')
               and im.created_at >= now() - make_interval(days => (select days_back from params))
           )                     as consumption,
           min(im.created_at)    as first_movement_at
      from public.inventory_movements im
     where im.business_id = p_business_id
       and (p_warehouse_id is null or im.warehouse_id = p_warehouse_id)
     group by im.item_id
  ),
  resolved as (
    select * from public.fn_purchase_resolve_suppliers(p_business_id, null)
  ),
  base as (
    select i.id                                        as item_id,
           i.name                                      as item_name,
           i.sku,
           i.unit,
           i.item_classification,
           coalesce(st.qty, 0)                          as stock,
           coalesce(tr.qty, 0)                          as in_transit,
           coalesce(oo.qty, 0)                          as on_order,
           greatest(coalesce(m.consumption, 0), 0)      as consumption,
           case
             when m.first_movement_at is null then (select days_back from params)
             else least(
               (select days_back from params),
               greatest(1, ceil(extract(epoch from (now() - m.first_movement_at)) / 86400.0)::integer)
             )
           end                                          as window_days,
           case when st.wh_min is not null then st.wh_min
                else coalesce(i.min_stock, 0) end        as min_stock,
           case when st.wh_min is not null then 'almacen'
                else 'insumo' end                         as min_stock_source,
           r.lead_time_days                             as supplier_lead,
           r.supplier_id,
           r.supplier_name,
           r.supplier_source,
           r.purchase_unit,
           r.pack_size,
           r.min_order_qty,
           r.unit_cost_base,
           r.cost_source
      from items i
      left join stock    st on st.item_id = i.id
      left join transit  tr on tr.item_id = i.id
      left join on_order oo on oo.item_id = i.id
      left join movements m on m.item_id  = i.id
      left join resolved r  on r.item_id  = i.id
  ),
  rates as (
    select b.*,
           b.consumption / b.window_days                                      as daily,
           coalesce(b.supplier_lead, (select default_lead from params))       as lead,
           (b.supplier_lead is null)                                          as lead_default,
           b.stock + b.in_transit + b.on_order                                as available
      from base b
  ),
  projected as (
    select r.*,
           r.daily * (r.lead + (select coverage from params)) + r.min_stock   as target_qty,
           r.daily * (r.lead + (select safety from params))                   as min_suggestion
      from rates r
  )
  select p.item_id,
         p.item_name,
         p.sku,
         p.unit,
         p.item_classification,
         p.stock,
         p.in_transit,
         p.on_order,
         p.consumption,
         p.window_days,
         round(p.daily, 4),
         p.min_stock,
         p.min_stock_source,
         p.lead,
         p.lead_default,
         round(p.target_qty, 4),
         round(greatest(0, p.target_qty - p.available), 4),
         case when p.daily > 0 then round(p.available / p.daily, 1) end,
         round(p.min_suggestion, 4),
         p.supplier_id,
         p.supplier_name,
         p.supplier_source,
         p.purchase_unit,
         p.pack_size,
         p.min_order_qty,
         p.unit_cost_base,
         p.cost_source,
         round(greatest(0, p.target_qty - p.available) * coalesce(p.unit_cost_base, 0), 2)
    from projected p
   where (p_supplier_id is null or p.supplier_id = p_supplier_id)
     and (not coalesce(p_only_needed, false) or p.target_qty - p.available > 0)
   -- item_id al final: orden estable para paginar (PostgREST corta en 1,000
   -- filas y un negocio como Penda tiene 2,308 insumos).
   order by greatest(0, p.target_qty - p.available) * coalesce(p.unit_cost_base, 0) desc,
            p.item_name,
            p.item_id;
$$;

comment on function public.fn_purchase_projection(uuid, uuid, integer, integer, integer, integer, uuid, boolean) is
  'Pedido sugerido por insumo (solo lectura): consumo diario NETO (ventas + '
  'mermas + producción, sin transferencias ni ajustes) de la ventana real, '
  'objetivo = consumo × (entrega + cobertura) + mínimo, sugerido = objetivo − '
  'existencia − en tránsito − ya pedido, con suplidor/presentación/costo de '
  'fn_purchase_resolve_suppliers. Todo en unidad base. Ver 20260915_0004.';

grant execute on function public.fn_purchase_projection(uuid, uuid, integer, integer, integer, integer, uuid, boolean) to authenticated;

commit;

notify pgrst, 'reload schema';
