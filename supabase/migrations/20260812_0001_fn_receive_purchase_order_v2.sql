-- =============================================================================
-- PRD 6.1 · F3 — fn_receive_purchase_order_v2: recepción con costo real,
-- bloque fiscal (606), variación con aprobación e idempotencia.
--
-- CONTEXTO:
--   Construida SOBRE fn_receive_purchase_order_partial (20260514_0005), que
--   queda intacta: mismas validaciones de orden/línea, misma ruta de
--   movimientos ('purchase' → trigger trg_inventory_movement_recost recalcula
--   el costo ponderado solo). Lo nuevo:
--     - Escribe la entidad purchase_receptions + purchase_reception_lines
--       (20260811_0002) con costo REAL facturado y el bloque fiscal.
--     - Sobrante permitido (discrepancy='over'): recibir 30 de 24 acumula.
--     - Cierre corto ('short_closed'): cierra la PO con pendientes.
--     - Variación de costo vs. la OC sobre el umbral del negocio
--       (business_settings.cost_variance_threshold_pct): exige approved_by;
--       si quien recibe puede aprobar (owner/admin), auto-aprueba y lo deja
--       en bitácora (approved_by + auto_approved en la respuesta).
--     - IDEMPOTENCIA: pg_advisory_xact_lock por (business, clave) serializa
--       reenvíos concurrentes; si la clave ya existe, la respuesta se
--       RECONSTRUYE desde las filas (nunca un blob guardado) y vuelve con
--       "replayed": true. La clave commitea en la MISMA transacción que los
--       efectos: un fallo a mitad revierte todo y el reintento arranca limpio.
--
-- CONTRATO (errores como strings mapeables en Dart, patrón process_payment_v3):
--   AUTH_REQUIRED, WAREHOUSE_NOT_FOUND, PURCHASE_RECEIVE_ACCESS_DENIED,
--   IDEMPOTENCY_KEY_REQUIRED, EMPTY_LINE_ITEMS, INVALID_CLOSE_MODE,
--   INVALID_LINE_ROW, PURCHASE_ORDER_NOT_FOUND, PURCHASE_ORDER_CANCELLED,
--   PURCHASE_ORDER_ALREADY_RECEIVED, LINE_NOT_IN_ORDER, SUPPLIER_INVALID,
--   PURCHASE_ORDER_ITEM_INVALID, COST_VARIANCE_UNAPPROVED.
--
-- BACKWARDS-COMPATIBLE:
--   Función nueva; fn_receive_purchase_order y ..._partial no se tocan.
-- =============================================================================

begin;

create or replace function public.fn_receive_purchase_order_v2(
  p_warehouse_id uuid,
  p_lines jsonb,                      -- [{item_id?, poi_id?, qty, actual_unit_cost, approved_by?}]
  p_idempotency_key text,
  p_order_id uuid default null,       -- null = recepción libre
  p_supplier_id uuid default null,
  p_fiscal jsonb default null,        -- {ncf, ncf_type, ncf_modified, document_date, payment_date,
                                      --  goods_amount, services_amount, itbis_invoiced, itbis_withheld,
                                      --  isr_withheld, isc, legal_tip, payment_method}
  p_close_mode text default 'complete', -- 'partial' | 'short_closed' | 'complete'
  p_notes text default null
) returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_user_id uuid := auth.uid();
  v_business_id uuid;
  v_role text;
  v_can_approve boolean;
  v_threshold numeric;
  v_order public.purchase_orders;
  v_existing public.purchase_receptions;
  v_reception_id uuid;
  v_row jsonb;
  v_poi_id uuid;
  v_item_id uuid;
  v_qty numeric;
  v_cost numeric;
  v_approved_by uuid;
  v_auto_approved boolean;
  v_any_auto boolean := false;
  v_line public.purchase_order_items;
  v_pending numeric;
  v_variance numeric;
  v_discrepancy text;
  v_line_id uuid;
  v_movements integer := 0;
  v_outstanding integer;
  v_final_status text;
  v_reception_status text;
begin
  -- ── Validaciones de entrada ──
  if v_user_id is null then
    raise exception 'AUTH_REQUIRED';
  end if;
  if p_idempotency_key is null or btrim(p_idempotency_key) = '' then
    raise exception 'IDEMPOTENCY_KEY_REQUIRED';
  end if;
  if p_lines is null
     or jsonb_typeof(p_lines) <> 'array'
     or jsonb_array_length(p_lines) = 0 then
    raise exception 'EMPTY_LINE_ITEMS';
  end if;
  if p_close_mode not in ('partial', 'short_closed', 'complete') then
    raise exception 'INVALID_CLOSE_MODE: %', p_close_mode;
  end if;

  select business_id into v_business_id
    from public.warehouses
    where id = p_warehouse_id;
  if v_business_id is null then
    raise exception 'WAREHOUSE_NOT_FOUND';
  end if;

  select public.user_business_role(v_user_id, v_business_id) into v_role;
  if coalesce(v_role, '') not in ('owner', 'admin', 'manager')
     and not public.user_has_business_permission(v_business_id, 'compras.acceso') then
    raise exception 'PURCHASE_RECEIVE_ACCESS_DENIED';
  end if;
  v_can_approve := coalesce(v_role, '') in ('owner', 'admin');

  if p_supplier_id is not null and not exists (
    select 1 from public.suppliers s
    where s.id = p_supplier_id and s.business_id = v_business_id
  ) then
    raise exception 'SUPPLIER_INVALID';
  end if;

  -- ── Idempotencia: serializar reenvíos y detectar replay ──
  perform pg_advisory_xact_lock(
    hashtextextended(v_business_id::text || ':' || p_idempotency_key, 0));

  select * into v_existing
    from public.purchase_receptions
    where business_id = v_business_id
      and idempotency_key = p_idempotency_key;

  if found then
    -- Respuesta derivada del estado real — nunca un blob guardado.
    select count(*) into v_movements
      from public.inventory_movements im
      where im.reference_type = 'purchase_reception_line'
        and im.reference_id in (
          select prl.id from public.purchase_reception_lines prl
          where prl.reception_id = v_existing.id
        );
    if v_existing.purchase_order_id is not null then
      select status::text into v_final_status
        from public.purchase_orders
        where id = v_existing.purchase_order_id;
    end if;
    return jsonb_build_object(
      'replayed', true,
      'reception_id', v_existing.id,
      'reception_status', v_existing.status,
      'movements_created', v_movements,
      'po_status', v_final_status
    );
  end if;

  -- ── Orden (si aplica) ──
  if p_order_id is not null then
    select * into v_order
      from public.purchase_orders
      where id = p_order_id
      for update;
    if not found or v_order.business_id <> v_business_id then
      raise exception 'PURCHASE_ORDER_NOT_FOUND';
    end if;
    if v_order.status = 'cancelled' then
      raise exception 'PURCHASE_ORDER_CANCELLED';
    end if;
    if v_order.status = 'received' then
      raise exception 'PURCHASE_ORDER_ALREADY_RECEIVED';
    end if;
  end if;

  select coalesce(cost_variance_threshold_pct, 3) into v_threshold
    from public.business_settings
    where business_id = v_business_id;
  v_threshold := coalesce(v_threshold, 3);

  v_reception_status := case p_close_mode
    when 'complete' then 'complete'
    when 'partial' then 'partial'
    else 'short_closed'
  end;

  -- ── Cabecera (la clave viaja aquí: misma transacción que los efectos) ──
  insert into public.purchase_receptions (
    business_id, warehouse_id, purchase_order_id, supplier_id,
    ncf, ncf_type, ncf_modified, document_date, payment_date,
    goods_amount, services_amount, itbis_invoiced, itbis_withheld,
    isr_withheld, isc, legal_tip, payment_method,
    status, idempotency_key, received_by
  ) values (
    v_business_id, p_warehouse_id, p_order_id,
    coalesce(p_supplier_id, v_order.supplier_id),
    nullif(p_fiscal->>'ncf', ''),
    nullif(p_fiscal->>'ncf_type', ''),
    nullif(p_fiscal->>'ncf_modified', ''),
    nullif(p_fiscal->>'document_date', '')::date,
    nullif(p_fiscal->>'payment_date', '')::date,
    nullif(p_fiscal->>'goods_amount', '')::numeric,
    nullif(p_fiscal->>'services_amount', '')::numeric,
    nullif(p_fiscal->>'itbis_invoiced', '')::numeric,
    nullif(p_fiscal->>'itbis_withheld', '')::numeric,
    nullif(p_fiscal->>'isr_withheld', '')::numeric,
    nullif(p_fiscal->>'isc', '')::numeric,
    nullif(p_fiscal->>'legal_tip', '')::numeric,
    nullif(p_fiscal->>'payment_method', ''),
    v_reception_status, p_idempotency_key, v_user_id
  )
  returning id into v_reception_id;

  -- ── Líneas ──
  for v_row in select * from jsonb_array_elements(p_lines)
  loop
    v_poi_id := nullif(v_row->>'poi_id', '')::uuid;
    v_item_id := nullif(v_row->>'item_id', '')::uuid;
    v_qty := nullif(v_row->>'qty', '')::numeric;
    v_cost := nullif(v_row->>'actual_unit_cost', '')::numeric;
    v_approved_by := nullif(v_row->>'approved_by', '')::uuid;
    v_auto_approved := false;

    if v_qty is null or v_cost is null then
      raise exception 'INVALID_LINE_ROW';
    end if;
    if v_qty <= 0 then
      continue; -- mismo criterio que la RPC parcial
    end if;
    if v_cost < 0 then
      raise exception 'INVALID_LINE_ROW';
    end if;

    v_variance := null;
    v_discrepancy := 'extra'; -- default: línea libre, fuera de la OC

    if v_poi_id is not null then
      if p_order_id is null then
        raise exception 'LINE_NOT_IN_ORDER: % (recepcion libre)', v_poi_id;
      end if;
      select * into v_line
        from public.purchase_order_items
        where id = v_poi_id and purchase_order_id = p_order_id
        for update;
      if not found then
        raise exception 'LINE_NOT_IN_ORDER: %', v_poi_id;
      end if;

      v_item_id := coalesce(v_item_id, v_line.inventory_item_id);
      v_pending := greatest(
        coalesce(v_line.quantity_ordered, 0) - coalesce(v_line.quantity_received, 0), 0);
      v_discrepancy := case
        when v_qty = v_pending then 'ok'
        when v_qty < v_pending then 'short'
        else 'over'
      end;

      -- Variación de costo real vs. costo de la OC.
      if coalesce(v_line.unit_cost, 0) > 0 then
        v_variance := round(
          (v_cost - v_line.unit_cost) / v_line.unit_cost * 100, 4);
        if abs(v_variance) > v_threshold and v_approved_by is null then
          if v_can_approve then
            v_approved_by := v_user_id;  -- auto-aprobación en bitácora
            v_auto_approved := true;
            v_any_auto := true;
          else
            raise exception 'COST_VARIANCE_UNAPPROVED: line=% variance=%%%',
              v_poi_id, v_variance;
          end if;
        end if;
      end if;

      update public.purchase_order_items
         set quantity_received = coalesce(quantity_received, 0) + v_qty
       where id = v_poi_id;
    end if;

    if v_item_id is not null and not exists (
      select 1 from public.inventory_items ii
      where ii.id = v_item_id and ii.business_id = v_business_id
    ) then
      raise exception 'PURCHASE_ORDER_ITEM_INVALID';
    end if;

    insert into public.purchase_reception_lines (
      reception_id, purchase_order_item_id, item_id,
      quantity_received, actual_unit_cost, cost_variance_pct,
      approved_by, discrepancy
    ) values (
      v_reception_id, v_poi_id, v_item_id,
      v_qty, v_cost, v_variance, v_approved_by, v_discrepancy
    )
    returning id into v_line_id;

    -- Movimiento de inventario con el COSTO REAL: el trigger
    -- trg_inventory_movement_recost recalcula el ponderado solo.
    if v_item_id is not null then
      insert into public.inventory_movements (
        business_id, warehouse_id, item_id, movement_type, quantity,
        cost_per_unit, reference_id, reference_type, notes, created_by
      ) values (
        v_business_id, p_warehouse_id, v_item_id, 'purchase', v_qty,
        v_cost, v_line_id, 'purchase_reception_line',
        coalesce(
          nullif(btrim(coalesce(p_notes, '')), ''),
          case
            when v_order.order_number is not null
              then concat('Recepcion de ', v_order.order_number)
            else 'Recepcion directa de compra'
          end
        ),
        v_user_id
      );
      v_movements := v_movements + 1;
    end if;
  end loop;

  -- ── Estado final de la OC ──
  if p_order_id is not null then
    if p_close_mode = 'short_closed' then
      -- Cierre corto: se cierra aunque queden pendientes.
      v_final_status := 'received';
    else
      select count(*) into v_outstanding
        from public.purchase_order_items poi
        where poi.purchase_order_id = p_order_id
          and coalesce(poi.quantity_ordered, 0) > coalesce(poi.quantity_received, 0);
      if v_outstanding = 0 then
        v_final_status := 'received';
      elsif exists (
        select 1 from public.purchase_order_items poi
        where poi.purchase_order_id = p_order_id
          and coalesce(poi.quantity_received, 0) > 0
      ) then
        v_final_status := 'partial';
      else
        v_final_status := v_order.status::text;
      end if;
    end if;

    update public.purchase_orders
       set status = v_final_status::public.purchase_status,
           received_date = case
             when v_final_status = 'received' then coalesce(received_date, current_date)
             else received_date
           end
     where id = p_order_id;
  end if;

  return jsonb_build_object(
    'replayed', false,
    'reception_id', v_reception_id,
    'reception_status', v_reception_status,
    'movements_created', v_movements,
    'po_status', v_final_status,
    'auto_approved', v_any_auto
  );
end;
$$;

grant execute on function public.fn_receive_purchase_order_v2(
  uuid, jsonb, text, uuid, uuid, jsonb, text, text
) to authenticated;

comment on function public.fn_receive_purchase_order_v2(
  uuid, jsonb, text, uuid, uuid, jsonb, text, text
) is
  'Recepción v2 (PRD 6.1 F3): costo real por línea + bloque fiscal 606 + '
  'umbral de variación con aprobación + idempotencia por clave (reenviar la '
  'misma clave devuelve la recepción existente con replayed=true). Construida '
  'sobre la ruta de movimientos estándar; el costeo ponderado lo dispara el '
  'trigger trg_inventory_movement_recost.';

commit;
