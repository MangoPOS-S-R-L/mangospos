-- =============================================================================
-- Capa de apertura desde el conteo físico + reportes valorados por capas.
-- Segunda mitad de los entregables 1, 2 y 5 del informe DH del 02-09-2026.
--
-- POR QUÉ DESDE EL CONTEO Y NO DESDE LA HISTORIA:
--   El informe (sección 5, acción 1) decide cerrar agosto por método periódico
--   contra el conteo ciego del 01-09-2026, y advierte que las existencias
--   actuales "arrastran los negativos y los stocks ficticios de 1,000". Sembrar
--   las capas desde los 20,304 movimientos heredaría exactamente esa basura:
--   las 436 líneas de recepción directa sin costo, el saco de azúcar a
--   RD$4,500 y los 89 negativos. La apertura nace del conteo, valorada a la
--   última compra RESPALDADA CON NCF, que es el criterio del Art. 57 del
--   Reglamento 139-98.
--
-- ENTREGA:
--   1. fn_inventory_last_invoiced_cost — costo por artículo en cascada, dando
--      prioridad a la compra con comprobante fiscal sobre la que no lo tiene.
--   2. fn_inventory_seed_opening_layers — crea las capas de apertura desde una
--      sesión de conteo físico. Corre en seco por defecto (p_dry_run = true):
--      devuelve el resumen valorado sin escribir nada, para cotejarlo con DH
--      ANTES de sembrar.
--   3. v_inventory_valuation_layers — inventario valorado por capas. Es el
--      reporte que el informe pide y que hoy no existe: la valuación actual
--      (v_inventory_valuation) multiplica por inventory_items.cost, o sea por
--      el último precio, que es justo la cifra que la auditoría rechaza.
--   4. v_inventory_cost_of_sales — costo de venta por movimiento y período.
--   5. v_inventory_cost_shortfalls — salidas sin capa que las respalde.
--
-- REQUIERE: 20260902_0012 (tablas y motor).
-- =============================================================================

begin;

-- ---------------------------------------------------------------------------
-- 1. Costo de la última compra respaldada
-- ---------------------------------------------------------------------------

create or replace function public.fn_inventory_last_invoiced_cost(
  p_business_id uuid,
  p_item_id uuid,
  out unit_cost numeric,
  out document_number text,
  out document_date date,
  out supplier_id uuid,
  out is_estimated boolean
)
language plpgsql
stable
security definer
set search_path = public
as $$
begin
  -- 1. Recepción con conduce y NCF. Es el respaldo más fuerte que existe.
  select m.cost_per_unit,
         nullif(pr.ncf, ''),
         coalesce(pr.document_date, pr.reception_date),
         pr.supplier_id,
         false
    into unit_cost, document_number, document_date, supplier_id, is_estimated
    from public.inventory_movements m
    join public.purchase_reception_lines prl on prl.id = m.reference_id
    join public.purchase_receptions pr on pr.id = prl.reception_id
   where m.business_id = p_business_id
     and m.item_id = p_item_id
     and m.movement_type = 'purchase'
     and m.reference_type = 'purchase_reception_line'
     and coalesce(m.cost_per_unit, 0) > 0
     and nullif(pr.ncf, '') is not null
   order by m.created_at desc
   limit 1;

  if unit_cost is not null then
    return;
  end if;

  -- 2. Orden de compra con NCF o número de factura.
  select m.cost_per_unit,
         coalesce(nullif(po.ncf, ''), nullif(po.invoice_number, '')),
         coalesce(po.received_date, po.created_at::date),
         po.supplier_id,
         false
    into unit_cost, document_number, document_date, supplier_id, is_estimated
    from public.inventory_movements m
    join public.purchase_orders po on po.id = m.reference_id
   where m.business_id = p_business_id
     and m.item_id = p_item_id
     and m.movement_type = 'purchase'
     and m.reference_type in ('purchase_order', 'purchase_order_item')
     and coalesce(m.cost_per_unit, 0) > 0
     and coalesce(nullif(po.ncf, ''), nullif(po.invoice_number, '')) is not null
   order by m.created_at desc
   limit 1;

  if unit_cost is not null then
    return;
  end if;

  -- 3. Cualquier compra con costo, sin documento. Queda marcada.
  select m.cost_per_unit, null, m.created_at::date, null, true
    into unit_cost, document_number, document_date, supplier_id, is_estimated
    from public.inventory_movements m
   where m.business_id = p_business_id
     and m.item_id = p_item_id
     and m.movement_type = 'purchase'
     and coalesce(m.cost_per_unit, 0) > 0
   order by m.created_at desc
   limit 1;

  if unit_cost is not null then
    return;
  end if;

  -- 4. Costo maestro del insumo (último precio). Último recurso.
  select coalesce(ii.cost, 0), null, null, null, true
    into unit_cost, document_number, document_date, supplier_id, is_estimated
    from public.inventory_items ii
   where ii.id = p_item_id
     and ii.business_id = p_business_id;

  unit_cost    := coalesce(unit_cost, 0);
  is_estimated := coalesce(is_estimated, true);
  return;
end;
$$;

comment on function public.fn_inventory_last_invoiced_cost(uuid, uuid) is
  'Costo unitario de un insumo según la última compra RESPALDADA: recepción '
  'con NCF, luego orden con NCF o factura, luego cualquier compra con costo, '
  'luego el costo maestro. is_estimated = true cuando no hubo comprobante '
  'que lo sustente (Art. 57 Regl. 139-98).';

-- ---------------------------------------------------------------------------
-- 2. Sembrar la apertura desde una sesión de conteo físico
-- ---------------------------------------------------------------------------

create or replace function public.fn_inventory_seed_opening_layers(
  p_session_id uuid,
  p_dry_run boolean default true
) returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_session   public.physical_count_sessions;
  v_role      text;
  v_cost      record;
  v_line      record;
  v_at        timestamptz;
  v_lines     integer := 0;
  v_units     numeric := 0;
  v_value     numeric := 0;
  v_est_lines integer := 0;
  v_est_value numeric := 0;
  v_existing  integer := 0;
begin
  select * into v_session
    from public.physical_count_sessions
   where id = p_session_id;

  if v_session.id is null then
    raise exception 'SESSION_NOT_FOUND';
  end if;

  v_role := public.user_business_role(auth.uid(), v_session.business_id);
  if coalesce(v_role, '') not in ('owner', 'admin', 'manager') then
    raise exception 'INSUFFICIENT_ROLE';
  end if;

  if v_session.status not in ('in_progress', 'completed') then
    raise exception 'SESSION_NOT_COUNTABLE: status=%', v_session.status;
  end if;

  select count(*) into v_existing
    from public.inventory_cost_layers l
   where l.business_id  = v_session.business_id
     and l.warehouse_id = v_session.warehouse_id
     and l.source_type  = 'opening';

  if v_existing > 0 and not p_dry_run then
    raise exception 'OPENING_LAYERS_EXIST: % capas de apertura en esta bodega',
      v_existing;
  end if;

  v_at := coalesce(v_session.completed_at, v_session.frozen_at,
                   v_session.started_at, now());

  for v_line in
    select l.item_id, l.counted_quantity
      from public.physical_count_lines l
     where l.session_id = p_session_id
       and coalesce(l.counted_quantity, 0) > 0
  loop
    select * into v_cost
      from public.fn_inventory_last_invoiced_cost(
             v_session.business_id, v_line.item_id);

    v_lines := v_lines + 1;
    v_units := v_units + v_line.counted_quantity;
    v_value := v_value + (v_line.counted_quantity * coalesce(v_cost.unit_cost, 0));

    if coalesce(v_cost.is_estimated, true) then
      v_est_lines := v_est_lines + 1;
      v_est_value := v_est_value
                     + (v_line.counted_quantity * coalesce(v_cost.unit_cost, 0));
    end if;

    if not p_dry_run then
      insert into public.inventory_cost_layers (
        business_id, item_id, warehouse_id, source_movement_id, source_type,
        supplier_id, document_number, document_date, received_at,
        quantity_in, quantity_remaining, unit_cost, is_estimated, notes
      ) values (
        v_session.business_id, v_line.item_id, v_session.warehouse_id, null,
        'opening', v_cost.supplier_id, v_cost.document_number,
        coalesce(v_cost.document_date, v_at::date), v_at,
        v_line.counted_quantity, v_line.counted_quantity,
        round(coalesce(v_cost.unit_cost, 0), 4),
        coalesce(v_cost.is_estimated, true),
        concat('Apertura desde conteo ', v_session.code)
      );
    end if;
  end loop;

  return jsonb_build_object(
    'dry_run',          p_dry_run,
    'session_code',     v_session.code,
    'business_id',      v_session.business_id,
    'warehouse_id',     v_session.warehouse_id,
    'lines',            v_lines,
    'units',            round(v_units, 4),
    'total_value',      round(v_value, 2),
    'estimated_lines',  v_est_lines,
    'estimated_value',  round(v_est_value, 2),
    'existing_opening_layers', v_existing
  );
end;
$$;

comment on function public.fn_inventory_seed_opening_layers(uuid, boolean) is
  'Crea las capas de apertura de una bodega desde una sesión de conteo '
  'físico, valoradas a la última compra respaldada con NCF. Corre en seco '
  'por defecto: devuelve el resumen valorado sin escribir. estimated_value '
  'es la porción del inventario que NO tiene comprobante que la sustente.';

-- ---------------------------------------------------------------------------
-- 3. Inventario valorado por capas (el reporte que pide el informe)
-- ---------------------------------------------------------------------------

create or replace view public.v_inventory_valuation_layers
with (security_invoker = on) as
select
  l.business_id,
  l.item_id,
  ii.sku                                        as item_sku,
  ii.name                                       as item_name,
  ii.unit                                       as item_unit,
  l.warehouse_id,
  w.name                                        as warehouse_name,
  sum(l.quantity_remaining)                     as quantity,
  sum(l.quantity_remaining * l.unit_cost)       as value,
  case
    when sum(l.quantity_remaining) > 0
      then round(sum(l.quantity_remaining * l.unit_cost)
                 / sum(l.quantity_remaining), 4)
    else 0
  end                                           as effective_unit_cost,
  ii.cost                                       as master_unit_cost,
  (sum(l.quantity_remaining) * coalesce(ii.cost, 0))
                                                as value_at_last_price,
  count(*)                                      as open_layers,
  count(*) filter (where l.is_estimated)        as estimated_layers,
  sum(l.quantity_remaining * l.unit_cost)
    filter (where l.is_estimated)               as estimated_value,
  min(l.received_at)                            as oldest_layer_at,
  max(l.received_at)                            as newest_layer_at
from public.inventory_cost_layers l
join public.inventory_items ii on ii.id = l.item_id
join public.warehouses w on w.id = l.warehouse_id
where l.quantity_remaining > 0
group by l.business_id, l.item_id, ii.sku, ii.name, ii.unit, ii.cost,
         l.warehouse_id, w.name;

comment on view public.v_inventory_valuation_layers is
  'Inventario valorado por capas de costo. value = lo que realmente costó lo '
  'que queda; value_at_last_price = lo que muestra la valuación vieja. La '
  'diferencia entre ambas es la partida de conciliación del informe DH.';

-- ---------------------------------------------------------------------------
-- 4. Costo de venta
-- ---------------------------------------------------------------------------

create or replace view public.v_inventory_cost_of_sales
with (security_invoker = on) as
select
  c.business_id,
  c.movement_id,
  m.movement_type,
  m.reference_id                                as order_id,
  c.item_id,
  ii.sku                                        as item_sku,
  ii.name                                       as item_name,
  c.warehouse_id,
  m.created_at                                  as occurred_at,
  sum(c.quantity - c.quantity_returned)         as quantity,
  sum((c.quantity - c.quantity_returned) * c.unit_cost)
                                                as cost_of_sales,
  bool_or(c.is_shortfall)                       as has_shortfall
from public.inventory_cost_consumptions c
join public.inventory_movements m on m.id = c.movement_id
join public.inventory_items ii on ii.id = c.item_id
where c.quantity > c.quantity_returned
group by c.business_id, c.movement_id, m.movement_type, m.reference_id,
         c.item_id, ii.sku, ii.name, c.warehouse_id, m.created_at;

comment on view public.v_inventory_cost_of_sales is
  'Costo de venta real por movimiento, neto de devoluciones por edición o '
  'cancelación de orden. Filtrar movement_type = sale para el costo de venta '
  'del período.';

-- ---------------------------------------------------------------------------
-- 5. Faltantes: salidas sin capa que las respalde
-- ---------------------------------------------------------------------------

create or replace view public.v_inventory_cost_shortfalls
with (security_invoker = on) as
select
  c.business_id,
  c.item_id,
  ii.sku                                        as item_sku,
  ii.name                                       as item_name,
  c.warehouse_id,
  w.name                                        as warehouse_name,
  count(*)                                      as shortfall_movements,
  sum(c.quantity - c.quantity_returned)         as shortfall_quantity,
  sum((c.quantity - c.quantity_returned) * c.unit_cost)
                                                as shortfall_value,
  min(c.created_at)                             as first_at,
  max(c.created_at)                             as last_at
from public.inventory_cost_consumptions c
join public.inventory_items ii on ii.id = c.item_id
join public.warehouses w on w.id = c.warehouse_id
where c.is_shortfall
  and c.quantity > c.quantity_returned
group by c.business_id, c.item_id, ii.sku, ii.name, c.warehouse_id, w.name;

comment on view public.v_inventory_cost_shortfalls is
  'Salidas que no encontraron capa disponible: se costearon al último costo '
  'conocido. Es la cara contable de los 89 artículos con existencia negativa '
  'del hallazgo 5. Se reconcilia contra el conteo físico.';

-- ---------------------------------------------------------------------------
-- 6. Grants
-- ---------------------------------------------------------------------------

grant select on public.inventory_cost_layers to authenticated;
grant select on public.inventory_cost_consumptions to authenticated;
grant select on public.v_inventory_valuation_layers to authenticated;
grant select on public.v_inventory_cost_of_sales to authenticated;
grant select on public.v_inventory_cost_shortfalls to authenticated;

grant execute on function
  public.fn_inventory_last_known_cost(uuid, uuid, uuid) to authenticated;
grant execute on function
  public.fn_inventory_last_invoiced_cost(uuid, uuid) to authenticated;
grant execute on function
  public.fn_inventory_seed_opening_layers(uuid, boolean) to authenticated;

commit;
