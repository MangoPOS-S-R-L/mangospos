-- =============================================================================
-- Recepción de mercancía en almacén ("conduce") — requerimiento del contable.
--
-- QUÉ PIDE EL NEGOCIO:
--   Registrar una compra NO debe meter la mercancía al inventario. El stock
--   entra cuando el almacén la RECIBE, y esa recepción produce un documento
--   numerado e imprimible (el "conduce") que dice qué se recibió de cada
--   producto. Ese papel es el soporte contable de la entrada.
--
-- QUÉ YA EXISTÍA (y este archivo NO reinventa):
--   - purchase_receptions / purchase_reception_lines  (20260811_0002)
--   - business_settings.cost_variance_threshold_pct   (20260811_0003)
--   - fn_receive_purchase_order_v2                    (20260812_0001)
--   Esas tres migraciones se escribieron para el PRD 6.1 pero la app nunca
--   las usó: el diálogo de recepción sigue llamando
--   fn_receive_purchase_order_partial, que mueve stock sin dejar documento.
--
-- QUÉ AGREGA ESTE ARCHIVO:
--   1. Prerrequisitos idempotentes. El servidor puede estar detrás del repo
--      (ver memoria "BD viva diverge de migraciones del repo"), así que las
--      tablas y columnas de 0811_0002/0003 se aseguran acá con IF NOT EXISTS.
--      Si ya están, estos bloques no hacen nada.
--   2. purchase_receptions.reception_number: el número del conduce, correlativo
--      por negocio (RM-00001). Un documento que se archiva necesita número
--      propio: el uuid no sirve para reclamarle nada a nadie.
--   3. purchase_receptions.notes: la nota del recibidor, que hoy se pierde
--      dentro del texto del movimiento de inventario.
--   4. Snapshot de nombre/unidad/sku en la línea: el conduce se reimprime
--      meses después y tiene que salir IGUAL aunque el insumo se haya
--      renombrado. Un documento contable no se reescribe solo.
--   5. business_settings.require_goods_receipt: cuando está en true, la app
--      no deja registrar una compra ya "Recibida" — el stock solo entra por
--      la pantalla de recepción. Default false = ningún negocio existente
--      cambia de comportamiento.
--   6. fn_receive_purchase_order_v2 reemplazada: misma firma y mismo contrato
--      de 20260812_0001, más la numeración del conduce, la nota, los
--      snapshots de línea y una respuesta que ya trae lo que el ticket
--      necesita imprimir.
--
-- IDEMPOTENTE / BACKWARDS-COMPATIBLE:
--   - Solo tablas/columnas nuevas y un CREATE OR REPLACE de una función que
--     hoy no tiene un solo llamador en la app.
--   - fn_receive_purchase_order y ..._partial no se tocan: la app vieja
--     (y cualquier build en campo) sigue funcionando igual.
-- =============================================================================

begin;

-- ── 1. Prerrequisitos de 20260811_0002 / 0003 ───────────────────────────────
-- Copiados textualmente para que este archivo corra solo en un servidor que
-- se quedó atrás. En uno al día, todos estos statements son no-ops.

create table if not exists public.purchase_receptions (
  id uuid primary key default gen_random_uuid(),
  business_id uuid not null references public.businesses(id) on delete cascade,
  warehouse_id uuid not null references public.warehouses(id),
  purchase_order_id uuid references public.purchase_orders(id),
  supplier_id uuid references public.suppliers(id),
  reception_date date not null default current_date,
  ncf text,
  ncf_type text,
  ncf_modified text,
  document_date date,
  payment_date date,
  goods_amount numeric(14,2),
  services_amount numeric(14,2),
  itbis_invoiced numeric(14,2),
  itbis_withheld numeric(14,2),
  isr_withheld numeric(14,2),
  isc numeric(14,2),
  legal_tip numeric(14,2),
  payment_method text,
  status text not null default 'draft'
    check (status in ('draft', 'partial', 'short_closed', 'complete', 'cancelled')),
  idempotency_key text,
  received_by uuid,
  created_at timestamptz default now() not null
);

create unique index if not exists uq_purchase_receptions_idem
  on public.purchase_receptions (business_id, idempotency_key)
  where idempotency_key is not null;

create index if not exists idx_purchase_receptions_business
  on public.purchase_receptions (business_id, reception_date desc);

create index if not exists idx_purchase_receptions_po
  on public.purchase_receptions (purchase_order_id)
  where purchase_order_id is not null;

create table if not exists public.purchase_reception_lines (
  id uuid primary key default gen_random_uuid(),
  reception_id uuid not null references public.purchase_receptions(id) on delete cascade,
  purchase_order_item_id uuid references public.purchase_order_items(id),
  item_id uuid references public.inventory_items(id),
  quantity_received numeric(14,3) not null check (quantity_received > 0),
  actual_unit_cost numeric(14,4) not null check (actual_unit_cost >= 0),
  cost_variance_pct numeric(8,4),
  approved_by uuid,
  discrepancy text
    check (discrepancy in ('ok', 'short', 'over', 'extra') or discrepancy is null)
);

create index if not exists idx_purchase_reception_lines_reception
  on public.purchase_reception_lines (reception_id);

create unique index if not exists uq_inventory_movements_reception_line
  on public.inventory_movements (reference_id)
  where reference_type = 'purchase_reception_line';

alter table public.purchase_receptions enable row level security;

drop policy if exists "pr_select" on public.purchase_receptions;
create policy "pr_select" on public.purchase_receptions
  for select to authenticated
  using (public.user_has_business_access(auth.uid(), business_id));

drop policy if exists "pr_write" on public.purchase_receptions;
create policy "pr_write" on public.purchase_receptions
  to authenticated
  using (
    public.user_business_role(auth.uid(), business_id)
      = any (array['owner','admin','manager'])
  )
  with check (
    public.user_business_role(auth.uid(), business_id)
      = any (array['owner','admin','manager'])
  );

alter table public.purchase_reception_lines enable row level security;

drop policy if exists "prl_select" on public.purchase_reception_lines;
create policy "prl_select" on public.purchase_reception_lines
  for select to authenticated
  using (
    exists (
      select 1 from public.purchase_receptions pr
      where pr.id = purchase_reception_lines.reception_id
        and public.user_has_business_access(auth.uid(), pr.business_id)
    )
  );

drop policy if exists "prl_write" on public.purchase_reception_lines;
create policy "prl_write" on public.purchase_reception_lines
  to authenticated
  using (
    exists (
      select 1 from public.purchase_receptions pr
      where pr.id = purchase_reception_lines.reception_id
        and public.user_business_role(auth.uid(), pr.business_id)
          = any (array['owner','admin','manager'])
    )
  )
  with check (
    exists (
      select 1 from public.purchase_receptions pr
      where pr.id = purchase_reception_lines.reception_id
        and public.user_business_role(auth.uid(), pr.business_id)
          = any (array['owner','admin','manager'])
    )
  );

alter table public.business_settings
  add column if not exists cost_variance_threshold_pct numeric(6,3) default 3 not null;

-- ── 2. Número del conduce y nota del recibidor ──────────────────────────────

alter table public.purchase_receptions
  add column if not exists reception_number text,
  add column if not exists notes text;

-- Correlativo por negocio: dos recepciones del mismo negocio no pueden
-- compartir número. Parcial porque las filas viejas (si las hubiera) quedan
-- en null y no deben bloquear el índice.
create unique index if not exists uq_purchase_receptions_number
  on public.purchase_receptions (business_id, reception_number)
  where reception_number is not null;

comment on column public.purchase_receptions.reception_number is
  'Número del conduce de recepción, correlativo por negocio (RM-00001). Es el '
  'identificador con el que el contable archiva y reclama la entrada de '
  'mercancía; el uuid no sirve para eso.';

-- ── 3. Snapshot de la línea ─────────────────────────────────────────────────
-- El conduce se reimprime meses después. Si el insumo cambió de nombre o de
-- unidad, la reimpresión tiene que salir como salió el día que se firmó.

alter table public.purchase_reception_lines
  add column if not exists item_name text,
  add column if not exists item_sku text,
  add column if not exists item_unit text,
  add column if not exists description text;

comment on column public.purchase_reception_lines.item_name is
  'Nombre del insumo AL MOMENTO de recibir. Snapshot a propósito: un '
  'documento firmado no se reescribe cuando alguien renombra el maestro.';

-- ── 4. Bandera de negocio: obligar la recepción ─────────────────────────────

alter table public.business_settings
  add column if not exists require_goods_receipt boolean default false not null;

comment on column public.business_settings.require_goods_receipt is
  'true = registrar una compra NUNCA mueve stock; la mercancía entra solo por '
  'la pantalla de recepción, que emite el conduce. Default false para no '
  'cambiarle el flujo a los negocios que ya venían recibiendo al registrar.';

commit;

-- ============================================================================
-- 5. fn_receive_purchase_order_v2 — recepción que emite conduce.
--
-- Mismo contrato de 20260812_0001 (idempotencia por clave, costo real,
-- bloque fiscal 606, umbral de variación con aprobación) más:
--   - reception_number correlativo por negocio.
--   - notes de la recepción guardadas en la cabecera, no solo en el
--     movimiento de inventario.
--   - snapshot de nombre/sku/unidad/descripción por línea.
--   - la respuesta trae el número, para que la app imprima sin releer.
--
-- Errores (strings mapeables en Dart, patrón process_payment_v3):
--   AUTH_REQUIRED, WAREHOUSE_NOT_FOUND, PURCHASE_RECEIVE_ACCESS_DENIED,
--   IDEMPOTENCY_KEY_REQUIRED, EMPTY_LINE_ITEMS, INVALID_CLOSE_MODE,
--   INVALID_LINE_ROW, PURCHASE_ORDER_NOT_FOUND, PURCHASE_ORDER_CANCELLED,
--   PURCHASE_ORDER_ALREADY_RECEIVED, LINE_NOT_IN_ORDER, SUPPLIER_INVALID,
--   PURCHASE_ORDER_ITEM_INVALID, COST_VARIANCE_UNAPPROVED.
-- ============================================================================

begin;

create or replace function public.fn_receive_purchase_order_v2(
  p_warehouse_id uuid,
  p_lines jsonb,                      -- [{item_id?, poi_id?, qty, actual_unit_cost, approved_by?}]
  p_idempotency_key text,
  p_order_id uuid default null,       -- null = recepción libre
  p_supplier_id uuid default null,
  p_fiscal jsonb default null,
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
  v_reception_number text;
  v_seq bigint;
  v_row jsonb;
  v_poi_id uuid;
  v_item_id uuid;
  v_qty numeric;
  v_cost numeric;
  v_approved_by uuid;
  v_auto_approved boolean;
  v_any_auto boolean := false;
  v_line public.purchase_order_items;
  v_item public.inventory_items;
  v_pending numeric;
  v_variance numeric;
  v_discrepancy text;
  v_line_id uuid;
  v_movements integer := 0;
  v_outstanding integer;
  v_final_status text;
  v_reception_status text;
  v_notes text := nullif(btrim(coalesce(p_notes, '')), '');
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
  v_can_approve := coalesce(v_role, '') in ('owner', 'admin');

  if coalesce(v_role, '') not in ('owner', 'admin', 'manager') then
    -- El motor de permisos (20260803_0001) puede no estar aplicado en un
    -- servidor viejo. Sin él, la puerta se queda en los roles y punto: un
    -- 42883 no puede convertirse en acceso concedido.
    begin
      if not public.user_has_business_permission(v_business_id, 'compras.acceso') then
        raise exception 'PURCHASE_RECEIVE_ACCESS_DENIED';
      end if;
    exception
      when undefined_function then
        raise exception 'PURCHASE_RECEIVE_ACCESS_DENIED';
    end;
  end if;

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
      'reception_number', v_existing.reception_number,
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

  -- ── Número del conduce ──
  -- Un lock propio por negocio (distinto del de la clave de idempotencia)
  -- serializa SOLO la numeración: dos recepciones simultáneas del mismo
  -- negocio no pueden sacar el mismo número.
  perform pg_advisory_xact_lock(
    hashtextextended(v_business_id::text || ':reception_number', 0));
  -- El cast va ADENTRO del max: comparar 'RM-100000' contra 'RM-99999' como
  -- texto devuelve el número equivocado en cuanto el negocio pasa las 99,999
  -- recepciones.
  select coalesce(
           max(nullif(regexp_replace(reception_number, '\D', '', 'g'), '')::bigint),
           0) + 1
    into v_seq
    from public.purchase_receptions
    where business_id = v_business_id
      and reception_number is not null;
  v_reception_number := 'RM-' || lpad(v_seq::text, 5, '0');

  -- ── Cabecera (la clave viaja aquí: misma transacción que los efectos) ──
  insert into public.purchase_receptions (
    business_id, warehouse_id, purchase_order_id, supplier_id,
    reception_number, notes,
    ncf, ncf_type, ncf_modified, document_date, payment_date,
    goods_amount, services_amount, itbis_invoiced, itbis_withheld,
    isr_withheld, isc, legal_tip, payment_method,
    status, idempotency_key, received_by
  ) values (
    v_business_id, p_warehouse_id, p_order_id,
    coalesce(p_supplier_id, v_order.supplier_id),
    v_reception_number, v_notes,
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
    v_line := null;

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

    v_item := null;
    if v_item_id is not null then
      select * into v_item
        from public.inventory_items ii
        where ii.id = v_item_id and ii.business_id = v_business_id;
      if not found then
        raise exception 'PURCHASE_ORDER_ITEM_INVALID';
      end if;
    end if;

    insert into public.purchase_reception_lines (
      reception_id, purchase_order_item_id, item_id,
      quantity_received, actual_unit_cost, cost_variance_pct,
      approved_by, discrepancy,
      item_name, item_sku, item_unit, description
    ) values (
      v_reception_id, v_poi_id, v_item_id,
      v_qty, v_cost, v_variance, v_approved_by, v_discrepancy,
      -- Snapshot: así se imprimió, así se reimprime.
      coalesce(v_item.name, v_line.description, 'Artículo'),
      v_item.sku,
      v_item.unit,
      v_line.description
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
        concat_ws(' · ',
          concat('Recepcion ', v_reception_number),
          case
            when v_order.order_number is not null
              then concat('OC ', v_order.order_number)
            else null
          end,
          v_notes
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
    'reception_number', v_reception_number,
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
  'Recepción de mercancía en almacén: mueve el stock, deja el documento '
  '(purchase_receptions + lines) con número de conduce correlativo por '
  'negocio y snapshot por línea, y es idempotente por clave (reenviar la '
  'misma clave devuelve la recepción existente con replayed=true). El costeo '
  'ponderado lo dispara el trigger trg_inventory_movement_recost.';

commit;
