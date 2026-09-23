-- =============================================================================
-- 20260923_0002 — Editar una compra ya registrada (cabecera + líneas), con
-- ajuste de inventario y de la cuenta por pagar.
--
-- QUÉ ARREGLA:
--   Una compra registrada era INMUTABLE. Un cero de más en una cantidad, un
--   costo mal digitado o una factura tecleada en la orden equivocada solo se
--   podían "arreglar" con un ajuste de inventario suelto, que no deja rastro
--   de que la compra estaba mal: el kardex quedaba con una entrada de compra
--   correcta y un ajuste sin explicación al lado.
--
-- CÓMO CORRIGE EL STOCK (decisión del dueño, 2026-09-23):
--   Cada línea que YA había recibido mercancía se corrige con REVERSA +
--   REENTRADA, no con un delta:
--     - reversa:   movimiento 'purchase' NEGATIVO por lo que había entrado,
--                  al costo viejo y en el almacén viejo.
--     - reentrada: movimiento 'purchase' POSITIVO por lo que queda tras la
--                  edición, al costo nuevo y en el almacén nuevo.
--   Así el kardex queda valorado exacto (no solo la cantidad) y un cambio de
--   costo o de almacén se corrige igual de bien que un cambio de cantidad.
--   La reversa NO recostea (trg_inventory_movement_recost ignora quantity<=0)
--   y la reentrada deja el costo maestro en el costo CORREGIDO — que es la
--   regla de último precio de 20260714_0001 aplicada al dato bueno.
--   Si nada que toque stock cambió en la línea, no se escribe ningún
--   movimiento: editar solo el NCF no ensucia el kardex.
--
-- LO RECIBIDO SIGUE A LA EDICIÓN:
--   - línea que había entrado COMPLETA  → vuelve a quedar completa con la
--     cantidad corregida (corregir "entraron 12" a 10 deja 10 recibidas).
--   - línea PARCIAL → conserva lo que entró, sin pasarse de lo pedido.
--   - línea NUEVA en una orden ya 'received' → entra completa: una orden
--     recibida no puede quedar con una línea pendiente.
--   - línea BORRADA → se devuelve al almacén todo lo que había entrado.
--
-- CONDUCES INTACTOS:
--   purchase_receptions / purchase_reception_lines NO se tocan: son el papel
--   de lo que físicamente llegó ese día y no se reescribe. Al borrar una
--   línea de la orden solo se suelta el puntero purchase_order_item_id (la
--   app lee el conduce por item_id y por el snapshot, nunca por esa columna).
--
-- CUENTA POR PAGAR:
--   Si la compra fue a crédito y cambia el total: sin abonos, la CxP se
--   ajusta al nuevo total; con abonos, la edición se RECHAZA
--   (PURCHASE_ORDER_PAYABLE_HAS_PAYMENTS) — no se deja una deuda por debajo
--   de lo ya pagado.
--
-- AUDITORÍA: purchase_order_edits guarda el ANTES y el DESPUÉS completos,
--   quién editó y el motivo. Sin esto, editar compras es un agujero.
--
-- IDEMPOTENCIA: p_idempotency_key evita que un doble clic postee dos veces
--   las correcciones de stock; repetir la llamada devuelve el mismo resultado.
--
-- CONTRATO DE ERRORES (strings mapeables en Dart):
--   AUTH_REQUIRED, PURCHASE_ORDER_NOT_FOUND, PURCHASE_ORDER_CANCELLED,
--   PURCHASE_ORDER_EDIT_DENIED, PURCHASE_ORDER_EMPTY,
--   PURCHASE_ORDER_INVALID, PURCHASE_ORDER_LINE_INVALID,
--   PURCHASE_ORDER_ITEM_INVALID, LINE_NOT_IN_ORDER,
--   PURCHASE_ORDER_PAYABLE_HAS_PAYMENTS, PURCHASE_ORDER_TOTAL_INVALID.
--
-- PERMISOS: SECURITY DEFINER (escribe inventory_movements), con chequeo
--   explícito: rol owner/admin/manager, o el permiso nuevo
--   `compras.ordenes.editar`.
--
-- IDEMPOTENTE: sí. REVERSIBLE: sí (_ROLLBACK).
-- =============================================================================

begin;

set local lock_timeout = '5s';
set local statement_timeout = '60s';

-- ---------------------------------------------------------------------------
-- 0. Columnas que la funcion escribe (mismas definiciones que sus migraciones
--    de origen; donde ya estan, no pasa nada). La BD viva diverge del repo:
--    sin esto la funcion falla con 42703 en un negocio sin la migracion.
-- ---------------------------------------------------------------------------
alter table public.purchase_orders
  add column if not exists invoice_number text;                     -- 20260704_0001
alter table public.purchase_orders
  add column if not exists discount numeric not null default 0;     -- 20260725_0001
alter table public.purchase_orders
  add column if not exists ncf varchar(20);                         -- 20260814_0003
alter table public.purchase_order_items
  add column if not exists discount numeric not null default 0;     -- 20260725_0001
alter table public.purchase_order_items
  add column if not exists purchase_unit text;                      -- 20260608_0002
alter table public.purchase_order_items
  add column if not exists pack_size numeric;                       -- 20260608_0002

-- ---------------------------------------------------------------------------
-- 1. Permiso
-- ---------------------------------------------------------------------------
insert into public.permissions (code, name, module, description) values
  ('compras.ordenes.editar',
   'Editar ordenes de compra registradas',
   'inventory',
   'Permite corregir una compra ya registrada (proveedor, factura, NCF, productos, cantidades y costos). Si la mercancia ya entro, ajusta el inventario con movimientos de correccion y deja bitacora.')
on conflict (code) do update
  set name = excluded.name,
      module = excluded.module,
      description = excluded.description;

insert into public.role_permissions (role_id, permission_id, allow)
select r.id, p.id, true
from public.roles r
cross join public.permissions p
where r.is_system = true
  and lower(r.name) in ('owner', 'admin', 'manager')
  and p.code = 'compras.ordenes.editar'
on conflict (role_id, permission_id) do nothing;

-- ---------------------------------------------------------------------------
-- 2. Bitácora de ediciones
-- ---------------------------------------------------------------------------
create table if not exists public.purchase_order_edits (
  id                uuid primary key default gen_random_uuid(),
  business_id       uuid not null references public.businesses(id) on delete cascade,
  purchase_order_id uuid not null references public.purchase_orders(id) on delete cascade,
  edited_by         uuid references auth.users(id),
  reason            text,
  before_snapshot   jsonb not null,
  after_snapshot    jsonb not null,
  movements_created integer not null default 0,
  idempotency_key   text,
  created_at        timestamptz not null default now()
);

create index if not exists idx_purchase_order_edits_order
  on public.purchase_order_edits (purchase_order_id, created_at desc);

create unique index if not exists uq_purchase_order_edits_idempotency
  on public.purchase_order_edits (business_id, idempotency_key)
  where idempotency_key is not null;

comment on table public.purchase_order_edits is
  'Bitacora de correcciones a compras ya registradas: el antes y el despues '
  'completos (cabecera + lineas), quien edito y por que. Ver 20260923_0002.';

alter table public.purchase_order_edits enable row level security;

drop policy if exists "poe_select" on public.purchase_order_edits;
create policy "poe_select" on public.purchase_order_edits
  for select to authenticated
  using (public.user_has_business_access(auth.uid(), business_id));

-- Sin politica de escritura a proposito: las filas las pone la RPC
-- (security definer). Nadie edita la bitacora desde el cliente.

-- ---------------------------------------------------------------------------
-- 3. Editar la orden, completa o nada
-- ---------------------------------------------------------------------------
create or replace function public.fn_purchase_order_update(
  p_order_id        uuid,
  p_lines           jsonb,
  p_header          jsonb default '{}'::jsonb,
  p_reason          text  default null,
  p_idempotency_key text  default null
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_user_id     uuid := auth.uid();
  v_header      jsonb := coalesce(p_header, '{}'::jsonb);
  v_key         text  := nullif(btrim(p_idempotency_key), '');
  v_order       public.purchase_orders;
  v_business_id uuid;
  v_role        text;
  v_replay      public.purchase_order_edits;
  v_wh_new      uuid;
  v_sup_new     uuid;
  v_was_full    boolean;
  v_line        jsonb;
  v_idx         integer := 0;
  v_poi_id      uuid;
  v_new_id      uuid;
  v_seen        uuid[] := '{}';
  v_old         public.purchase_order_items;
  v_dead        public.purchase_order_items;
  v_qty_new     numeric;
  v_cost_new    numeric;
  v_item_new    uuid;
  v_recv_old    numeric;
  v_recv_new    numeric;
  v_touch_stock boolean;
  v_movements   integer := 0;
  v_before      jsonb;
  v_after       jsonb;
  v_subtotal    numeric := 0;
  v_tax         numeric := 0;
  v_discount    numeric;
  v_total       numeric;
  v_outstanding integer;
  v_any_recv    boolean;
  v_status      text;
  v_credit      public.supplier_credits;
  v_paid        numeric;
  v_credit_adj  boolean := false;
  v_invoice     text;
  v_ncf         text;
  v_notes       text;
  v_expected    date;
begin
  if v_user_id is null then
    raise exception 'AUTH_REQUIRED';
  end if;

  select * into v_order
    from public.purchase_orders
   where id = p_order_id
   for update;
  if not found then
    raise exception 'PURCHASE_ORDER_NOT_FOUND';
  end if;
  v_business_id := v_order.business_id;

  if v_order.status = 'cancelled' then
    raise exception 'PURCHASE_ORDER_CANCELLED';
  end if;

  select public.user_business_role(v_user_id, v_business_id) into v_role;
  if coalesce(v_role, '') not in ('owner', 'admin', 'manager')
     and not public.user_has_business_permission(v_business_id, 'compras.ordenes.editar') then
    raise exception 'PURCHASE_ORDER_EDIT_DENIED';
  end if;

  -- Un doble clic no postea dos veces las correcciones de stock.
  if v_key is not null then
    perform pg_advisory_xact_lock(
      hashtextextended('purchase_order_edit:' || v_business_id::text || ':' || v_key, 0));
    select * into v_replay
      from public.purchase_order_edits
     where business_id = v_business_id
       and idempotency_key = v_key;
    if found then
      return jsonb_build_object(
        'id', v_replay.purchase_order_id,
        'replayed', true,
        'movements_created', v_replay.movements_created,
        'status', v_replay.after_snapshot -> 'order' ->> 'status'
      );
    end if;
  end if;

  if p_lines is null
     or jsonb_typeof(p_lines) <> 'array'
     or jsonb_array_length(p_lines) = 0 then
    raise exception 'PURCHASE_ORDER_EMPTY: la orden no puede quedar sin lineas';
  end if;

  v_wh_new  := coalesce(nullif(v_header ->> 'warehouse_id', '')::uuid, v_order.warehouse_id);
  v_sup_new := coalesce(nullif(v_header ->> 'supplier_id', '')::uuid, v_order.supplier_id);

  if v_wh_new is null or not exists (
    select 1 from public.warehouses w
     where w.id = v_wh_new and w.business_id = v_business_id
  ) then
    raise exception 'PURCHASE_ORDER_INVALID: el almacen no es de este negocio';
  end if;
  if v_sup_new is not null and not exists (
    select 1 from public.suppliers s
     where s.id = v_sup_new and s.business_id = v_business_id
  ) then
    raise exception 'PURCHASE_ORDER_INVALID: el suplidor no es de este negocio';
  end if;

  -- Foto del ANTES, para la bitacora.
  select jsonb_build_object(
           'order', to_jsonb(v_order),
           'lines', coalesce((
             select jsonb_agg(to_jsonb(poi) order by poi.id)
               from public.purchase_order_items poi
              where poi.purchase_order_id = p_order_id), '[]'::jsonb)
         )
    into v_before;

  v_was_full := (v_order.status = 'received');

  -- ── Lineas que vienen en la edicion ──
  for v_line in select value from jsonb_array_elements(p_lines) loop
    v_idx := v_idx + 1;
    v_poi_id   := nullif(v_line ->> 'id', '')::uuid;
    v_qty_new  := nullif(v_line ->> 'quantity_ordered', '')::numeric;
    v_cost_new := coalesce(nullif(v_line ->> 'unit_cost', '')::numeric, 0);
    v_item_new := nullif(v_line ->> 'inventory_item_id', '')::uuid;

    if coalesce(v_qty_new, 0) <= 0 then
      raise exception 'PURCHASE_ORDER_LINE_INVALID: la cantidad debe ser mayor que 0 (linea %)', v_idx;
    end if;
    if v_cost_new < 0 then
      raise exception 'PURCHASE_ORDER_LINE_INVALID: el costo no puede ser negativo (linea %)', v_idx;
    end if;
    if v_item_new is not null and not exists (
      select 1 from public.inventory_items ii
       where ii.id = v_item_new and ii.business_id = v_business_id
    ) then
      raise exception 'PURCHASE_ORDER_ITEM_INVALID: el insumo de la linea % no es de este negocio', v_idx;
    end if;

    if v_poi_id is not null then
      -- ── Linea existente ──
      select * into v_old
        from public.purchase_order_items
       where id = v_poi_id and purchase_order_id = p_order_id
       for update;
      if not found then
        raise exception 'LINE_NOT_IN_ORDER: %', v_poi_id;
      end if;

      v_recv_old := coalesce(v_old.quantity_received, 0);
      if v_recv_old <= 0 then
        v_recv_new := 0;
      elsif v_recv_old >= coalesce(v_old.quantity_ordered, 0) then
        -- Entro completa: sigue completa con la cantidad corregida.
        v_recv_new := v_qty_new;
      else
        -- Parcial: conserva lo que entro, sin pasarse de lo pedido.
        v_recv_new := least(v_recv_old, v_qty_new);
      end if;

      v_touch_stock := (v_recv_old > 0 or v_recv_new > 0)
        and (v_recv_old <> v_recv_new
             or coalesce(v_old.unit_cost, 0) <> v_cost_new
             or v_old.inventory_item_id is distinct from v_item_new
             or v_order.warehouse_id is distinct from v_wh_new);

      if v_touch_stock then
        if v_recv_old > 0 and v_old.inventory_item_id is not null then
          insert into public.inventory_movements (
            business_id, warehouse_id, item_id, movement_type, quantity,
            cost_per_unit, reference_id, reference_type, notes, created_by
          ) values (
            v_business_id, v_order.warehouse_id, v_old.inventory_item_id,
            'purchase', -v_recv_old, v_old.unit_cost,
            v_old.id, 'purchase_order_edit_reversal',
            concat('Correccion de ', v_order.order_number, ': reversa de lo recibido'),
            v_user_id
          );
          v_movements := v_movements + 1;
        end if;
        if v_recv_new > 0 and v_item_new is not null then
          insert into public.inventory_movements (
            business_id, warehouse_id, item_id, movement_type, quantity,
            cost_per_unit, reference_id, reference_type, notes, created_by
          ) values (
            v_business_id, v_wh_new, v_item_new,
            'purchase', v_recv_new, v_cost_new,
            v_old.id, 'purchase_order_edit',
            concat('Correccion de ', v_order.order_number, ': entrada corregida'),
            v_user_id
          );
          v_movements := v_movements + 1;
        end if;
      end if;

      update public.purchase_order_items
         set inventory_item_id = v_item_new,
             description       = nullif(btrim(v_line ->> 'description'), ''),
             quantity_ordered  = v_qty_new,
             quantity_received = v_recv_new,
             unit_cost         = v_cost_new,
             tax_rate          = coalesce(nullif(v_line ->> 'tax_rate', '')::numeric, 18),
             total             = coalesce(nullif(v_line ->> 'total', '')::numeric, v_qty_new * v_cost_new),
             discount          = greatest(coalesce(nullif(v_line ->> 'discount', '')::numeric, 0), 0),
             purchase_unit     = nullif(btrim(v_line ->> 'purchase_unit'), ''),
             pack_size         = coalesce(nullif(nullif(v_line ->> 'pack_size', '')::numeric, 0), 1)
       where id = v_poi_id;

      v_seen := v_seen || v_poi_id;
    else
      -- ── Linea nueva ──
      -- En una orden ya recibida, lo que se agrega tambien entro: dejarla
      -- pendiente convertiria una compra cerrada en una parcial fantasma.
      v_recv_new := case when v_was_full then v_qty_new else 0 end;

      insert into public.purchase_order_items (
        purchase_order_id, inventory_item_id, description,
        quantity_ordered, quantity_received, unit_cost, tax_rate, total,
        discount, purchase_unit, pack_size
      ) values (
        p_order_id, v_item_new, nullif(btrim(v_line ->> 'description'), ''),
        v_qty_new, v_recv_new, v_cost_new,
        coalesce(nullif(v_line ->> 'tax_rate', '')::numeric, 18),
        coalesce(nullif(v_line ->> 'total', '')::numeric, v_qty_new * v_cost_new),
        greatest(coalesce(nullif(v_line ->> 'discount', '')::numeric, 0), 0),
        nullif(btrim(v_line ->> 'purchase_unit'), ''),
        coalesce(nullif(nullif(v_line ->> 'pack_size', '')::numeric, 0), 1)
      )
      returning id into v_new_id;

      if v_recv_new > 0 and v_item_new is not null then
        insert into public.inventory_movements (
          business_id, warehouse_id, item_id, movement_type, quantity,
          cost_per_unit, reference_id, reference_type, notes, created_by
        ) values (
          v_business_id, v_wh_new, v_item_new,
          'purchase', v_recv_new, v_cost_new,
          v_new_id, 'purchase_order_edit',
          concat('Correccion de ', v_order.order_number, ': linea agregada'),
          v_user_id
        );
        v_movements := v_movements + 1;
      end if;

      v_seen := v_seen || v_new_id;
    end if;
  end loop;

  -- ── Lineas que la edicion quito ──
  for v_dead in
    select * from public.purchase_order_items
     where purchase_order_id = p_order_id
       and not (id = any (v_seen))
  loop
    if coalesce(v_dead.quantity_received, 0) > 0
       and v_dead.inventory_item_id is not null then
      insert into public.inventory_movements (
        business_id, warehouse_id, item_id, movement_type, quantity,
        cost_per_unit, reference_id, reference_type, notes, created_by
      ) values (
        v_business_id, v_order.warehouse_id, v_dead.inventory_item_id,
        'purchase', -v_dead.quantity_received, v_dead.unit_cost,
        v_dead.id, 'purchase_order_edit_reversal',
        concat('Correccion de ', v_order.order_number, ': linea eliminada'),
        v_user_id
      );
      v_movements := v_movements + 1;
    end if;

    -- El conduce NO se reescribe: solo se suelta el puntero a la linea que
    -- deja de existir (la app lo lee por item_id y por el snapshot).
    update public.purchase_reception_lines
       set purchase_order_item_id = null
     where purchase_order_item_id = v_dead.id;

    delete from public.purchase_order_items where id = v_dead.id;
  end loop;

  -- ── Cabecera ──
  select coalesce(sum(poi.total), 0),
         coalesce(sum(poi.total * coalesce(poi.tax_rate, 0) / 100.0), 0)
    into v_subtotal, v_tax
    from public.purchase_order_items poi
   where poi.purchase_order_id = p_order_id;

  v_subtotal := coalesce(nullif(v_header ->> 'subtotal', '')::numeric, v_subtotal);
  v_tax      := coalesce(nullif(v_header ->> 'tax', '')::numeric, v_tax);
  v_discount := greatest(coalesce(nullif(v_header ->> 'discount', '')::numeric, 0), 0);
  v_discount := least(v_discount, v_subtotal + v_tax);
  v_total    := coalesce(nullif(v_header ->> 'total', '')::numeric,
                         v_subtotal + v_tax - v_discount);

  v_invoice  := nullif(btrim(v_header ->> 'invoice_number'), '');
  v_ncf      := nullif(btrim(v_header ->> 'ncf'), '');
  v_notes    := nullif(btrim(v_header ->> 'notes'), '');
  v_expected := coalesce(nullif(v_header ->> 'expected_date', '')::date, v_order.expected_date);

  -- Estado recalculado por lo que quedo pendiente tras la edicion.
  select count(*) into v_outstanding
    from public.purchase_order_items poi
   where poi.purchase_order_id = p_order_id
     and coalesce(poi.quantity_ordered, 0) > coalesce(poi.quantity_received, 0);
  select exists (
    select 1 from public.purchase_order_items poi
     where poi.purchase_order_id = p_order_id
       and coalesce(poi.quantity_received, 0) > 0
  ) into v_any_recv;

  v_status := case
    when v_outstanding = 0 then 'received'
    when v_any_recv then 'partial'
    when v_order.status::text = 'draft' then 'draft'
    else 'sent'
  end;

  update public.purchase_orders
     set supplier_id    = v_sup_new,
         warehouse_id   = v_wh_new,
         status         = v_status::public.purchase_status,
         subtotal       = v_subtotal,
         tax            = v_tax,
         discount       = v_discount,
         total          = v_total,
         expected_date  = v_expected,
         notes          = v_notes,
         invoice_number = v_invoice,
         ncf            = v_ncf,
         received_date  = case
                            when v_status in ('received', 'partial')
                              then coalesce(received_date, current_date)
                            else null
                          end
   where id = p_order_id;

  -- ── Cuenta por pagar vinculada ──
  select * into v_credit
    from public.supplier_credits
   where purchase_order_id = p_order_id
     and status <> 'cancelled'
   order by created_at
   limit 1;

  if found then
    select coalesce(sum(scp.amount), 0) into v_paid
      from public.supplier_credit_payments scp
     where scp.supplier_credit_id = v_credit.id;

    if round(v_total, 2) <> round(v_credit.original_amount, 2) then
      if v_paid > 0 then
        raise exception
          'PURCHASE_ORDER_PAYABLE_HAS_PAYMENTS: la cuenta por pagar ya tiene abonos por %; cambia el total solo despues de resolverla', v_paid;
      end if;
      if v_total <= 0 then
        raise exception
          'PURCHASE_ORDER_TOTAL_INVALID: una compra a credito no puede quedar en 0';
      end if;
      update public.supplier_credits
         set original_amount = v_total,
             balance         = v_total,
             supplier_id     = coalesce(v_sup_new, supplier_id),
             invoice_number  = coalesce(v_invoice, invoice_number)
       where id = v_credit.id;
      v_credit_adj := true;
    elsif v_sup_new is distinct from v_credit.supplier_id
          or coalesce(v_invoice, '') is distinct from coalesce(v_credit.invoice_number, '') then
      update public.supplier_credits
         set supplier_id    = coalesce(v_sup_new, supplier_id),
             invoice_number = coalesce(v_invoice, invoice_number)
       where id = v_credit.id;
    end if;
  end if;

  -- ── Foto del DESPUES + bitacora ──
  select * into v_order from public.purchase_orders where id = p_order_id;
  select jsonb_build_object(
           'order', to_jsonb(v_order),
           'lines', coalesce((
             select jsonb_agg(to_jsonb(poi) order by poi.id)
               from public.purchase_order_items poi
              where poi.purchase_order_id = p_order_id), '[]'::jsonb)
         )
    into v_after;

  insert into public.purchase_order_edits (
    business_id, purchase_order_id, edited_by, reason,
    before_snapshot, after_snapshot, movements_created, idempotency_key
  ) values (
    v_business_id, p_order_id, v_user_id, nullif(btrim(p_reason), ''),
    v_before, v_after, v_movements, v_key
  );

  return jsonb_build_object(
    'id', p_order_id,
    'replayed', false,
    'status', v_status,
    'total', v_total,
    'movements_created', v_movements,
    'payable_adjusted', v_credit_adj
  );
end;
$$;

comment on function public.fn_purchase_order_update(uuid, jsonb, jsonb, text, text) is
  'Corrige una compra ya registrada (cabecera + lineas) en una sola '
  'transaccion. Lo que ya habia entrado al almacen se corrige con reversa + '
  'reentrada de movimientos de compra (cantidad Y costo), el estado se '
  'recalcula y la cuenta por pagar sin abonos se ajusta al nuevo total. Deja '
  'el antes/despues en purchase_order_edits. Ver 20260923_0002.';

commit;
