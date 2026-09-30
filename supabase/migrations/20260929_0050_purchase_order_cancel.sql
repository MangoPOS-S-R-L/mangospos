-- =============================================================================
-- 20260929_0050 — Anular una compra registrada.
--
-- Numerada en el rango 0050+ a propósito: el dueño y el asistente trabajan en
-- paralelo y los dos empezaban a contar desde 0001 (colisiones el 2026-09-07).
--
-- QUÉ ARREGLA:
--   Una compra registrada solo se podía EDITAR (20260923_0002). Una compra
--   que no debió existir —la factura se registró dos veces, era de otro local,
--   el proveedor se llevó la mercancía— no tenía salida: había que dejarla en
--   cero a mano y ajustar el inventario suelto. El permiso
--   `compras.ordenes.anular` existía desde 20260308_0022, pero ninguna pantalla
--   ni función lo usaba.
--
-- QUÉ HACE, TODO EN UNA TRANSACCIÓN:
--   1. Devuelve al almacén EXACTAMENTE lo que la compra metió. No lo calcula
--      desde las líneas de la orden sino desde los MOVIMIENTOS que la orden
--      generó (recepción completa, parcial, conduce y correcciones de la
--      edición), agrupados por almacén e insumo. Así sale bien aunque una
--      recepción haya entrado a otro costo que el de la orden, o aunque la
--      orden se haya editado y movido de almacén.
--      La reversa es un movimiento 'purchase' NEGATIVO (igual que la reversa
--      de la edición), valorado al costo neto con que entró.
--   2. Costo maestro: si ESTA compra fue la última que fijó el costo del
--      insumo (regla de último precio, 20260714_0001) y nadie lo cambió
--      después, vuelve al costo de la última compra VÁLIDA anterior. Si no
--      hay ninguna, se deja como está (no hay de dónde sacar el anterior).
--   3. Conduces: los de esta orden quedan 'cancelled'. El papel NO se borra;
--      el estado evita que sigan contando como compra válida (y dispara el
--      re-aprendizaje del precio del suplidor de 20260915_0008).
--   4. Cuenta por pagar: sin abonos se cancela (saldo 0). CON abonos la
--      anulación se RECHAZA (PURCHASE_ORDER_PAYABLE_HAS_PAYMENTS), la misma
--      regla que el dueño fijó para la edición el 2026-09-23: no se deja
--      dinero pagado colgando de una compra que "no existió".
--   5. La orden queda 'cancelled' con quién, cuándo y por qué. Las líneas NO
--      se tocan: son el registro de lo que se había digitado. El trigger de
--      20260915_0008 re-aprende el precio del suplidor.
--   6. Bitácora en purchase_order_edits (action = 'cancel') con el antes y el
--      después completos.
--
-- VISTA PREVIA (p_preview = true): no escribe nada. Devuelve lo que se va a
--   devolver al inventario (con la existencia antes/después, para avisar de
--   los negativos) y si la cuenta por pagar bloquea. La pantalla la muestra
--   ANTES de pedir la confirmación.
--
-- EXISTENCIA NEGATIVA: se permite, igual que en la edición. Si la mercancía
--   ya se vendió, el negativo es la verdad del almacén; la vista previa lo
--   avisa con nombre y cantidad.
--
-- IDEMPOTENTE: anular una orden ya anulada devuelve replayed=true sin hacer
--   nada (el FOR UPDATE sobre la orden serializa el doble toque). Las
--   recepciones (v2/conduce) también toman ese candado y rechazan una orden
--   cancelada, así que no puede entrar mercancía a medio anular.
--
-- CONTRATO DE ERRORES (strings mapeables en Dart):
--   AUTH_REQUIRED, PURCHASE_ORDER_NOT_FOUND, PURCHASE_ORDER_CANCEL_DENIED,
--   PURCHASE_ORDER_CANCEL_REASON_REQUIRED, PURCHASE_ORDER_PAYABLE_HAS_PAYMENTS.
--
-- LO QUE NO TOCA: ventas, pagos, NCF de ventas, cierre de caja. La
--   contabilidad (20260805_0001) no se revierte aquí: si ese módulo llega a
--   estar activo y ya generó el asiento de la compra, hay que reversarlo allá.
--
-- DEPENDE DE: nada nuevo. Crea purchase_order_edits si 20260923_0002 aún no se
--   aplicó (misma definición; aplicar la otra después no choca).
--
-- IDEMPOTENTE (la migración): sí. REVERSIBLE: sí (_ROLLBACK).
-- =============================================================================

begin;

set local lock_timeout = '5s';
set local statement_timeout = '60s';

-- ---------------------------------------------------------------------------
-- 0. Quién, cuándo y por qué se anuló (la pantalla lo muestra en el detalle).
-- ---------------------------------------------------------------------------
alter table public.purchase_orders
  add column if not exists cancelled_at timestamptz;
alter table public.purchase_orders
  add column if not exists cancelled_by uuid;
alter table public.purchase_orders
  add column if not exists cancel_reason text;

-- ---------------------------------------------------------------------------
-- 1. Permiso (ya existe desde 20260308_0022; se asegura por si la BD viva no
--    lo tiene). No se pisa el nombre ni la descripción existentes.
-- ---------------------------------------------------------------------------
insert into public.permissions (code, name, module, description) values
  ('compras.ordenes.anular',
   'Anular ordenes de compra',
   'inventory',
   'Anula una compra registrada: devuelve la mercancia del inventario, cancela la cuenta por pagar sin abonos y deja bitacora.')
on conflict (code) do nothing;

insert into public.role_permissions (role_id, permission_id, allow)
select r.id, p.id, true
from public.roles r
cross join public.permissions p
where r.is_system = true
  and lower(r.name) in ('owner', 'admin', 'manager')
  and p.code = 'compras.ordenes.anular'
on conflict (role_id, permission_id) do nothing;

-- ---------------------------------------------------------------------------
-- 2. Bitácora (misma tabla que la edición; se crea si 20260923_0002 aún no
--    está aplicada) + columna que distingue edición de anulación.
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

alter table public.purchase_order_edits enable row level security;

drop policy if exists "poe_select" on public.purchase_order_edits;
create policy "poe_select" on public.purchase_order_edits
  for select to authenticated
  using (public.user_has_business_access(auth.uid(), business_id));

alter table public.purchase_order_edits
  add column if not exists action text not null default 'edit';

comment on column public.purchase_order_edits.action is
  '''edit'' = corrección (fn_purchase_order_update); ''cancel'' = anulación '
  '(fn_purchase_order_cancel). Ver 20260929_0050.';

-- ---------------------------------------------------------------------------
-- 3. Anular la orden, completa o nada
-- ---------------------------------------------------------------------------
create or replace function public.fn_purchase_order_cancel(
  p_order_id        uuid,
  p_reason          text    default null,
  p_idempotency_key text    default null,
  p_preview         boolean default false
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_user_id     uuid := auth.uid();
  v_key         text := nullif(btrim(p_idempotency_key), '');
  v_reason      text := nullif(btrim(p_reason), '');
  v_preview     boolean := coalesce(p_preview, false);
  v_order       public.purchase_orders;
  v_business_id uuid;
  v_role        text;
  v_line_ids    uuid[];
  v_recv_ids    uuid[];
  v_item_ids    uuid[];
  v_plan        jsonb;
  v_step        jsonb;
  v_qty         numeric;
  v_movements   integer := 0;
  v_negative    integer := 0;
  v_credit      public.supplier_credits;
  v_has_credit  boolean := false;
  v_paid        numeric := 0;
  v_receptions  integer := 0;
  v_costs       integer := 0;
  v_before      jsonb;
  v_after       jsonb;
  v_item_id     uuid;
  v_last_id     uuid;
  v_last_cost   numeric;
  v_last_ref    text;
  v_last_refid  uuid;
  v_cur_cost    numeric;
  v_prev_cost   numeric;
begin
  if v_user_id is null then
    raise exception 'AUTH_REQUIRED';
  end if;

  -- La vista previa no bloquea a nadie; la anulación sí toma la orden.
  if v_preview then
    select * into v_order from public.purchase_orders where id = p_order_id;
  else
    select * into v_order from public.purchase_orders where id = p_order_id for update;
  end if;
  if not found then
    raise exception 'PURCHASE_ORDER_NOT_FOUND';
  end if;
  v_business_id := v_order.business_id;

  select public.user_business_role(v_user_id, v_business_id) into v_role;
  if coalesce(v_role, '') not in ('owner', 'admin', 'manager')
     and not public.user_has_business_permission(v_business_id, 'compras.ordenes.anular') then
    raise exception 'PURCHASE_ORDER_CANCEL_DENIED';
  end if;

  -- Ya anulada: un doble toque o un reintento no hace nada más.
  if v_order.status::text = 'cancelled' then
    return jsonb_build_object(
      'id', p_order_id,
      'status', 'cancelled',
      'replayed', true,
      'preview', v_preview,
      'movements_created', 0,
      'costs_restored', 0,
      'receptions_cancelled', 0,
      'payable_cancelled', false,
      'negative_items', 0,
      'lines', '[]'::jsonb
    );
  end if;

  if not v_preview and (v_reason is null or char_length(v_reason) < 3) then
    raise exception 'PURCHASE_ORDER_CANCEL_REASON_REQUIRED';
  end if;

  -- ── Qué movimientos son de esta orden ──
  -- Líneas de la orden, incluidas las que una edición borró (sus movimientos
  -- de corrección siguen referenciando su id).
  select coalesce(array_agg(distinct x.id), '{}') into v_line_ids
    from (
      select poi.id
        from public.purchase_order_items poi
       where poi.purchase_order_id = p_order_id
      union
      select nullif(l ->> 'id', '')::uuid
        from public.purchase_order_edits e
        cross join lateral jsonb_array_elements(
          coalesce(e.before_snapshot -> 'lines', '[]'::jsonb)
          || coalesce(e.after_snapshot -> 'lines', '[]'::jsonb)) l
       where e.purchase_order_id = p_order_id
    ) x
   where x.id is not null;

  select coalesce(array_agg(prl.id), '{}') into v_recv_ids
    from public.purchase_reception_lines prl
    join public.purchase_receptions pr on pr.id = prl.reception_id
   where pr.purchase_order_id = p_order_id;

  -- Insumos que la orden pudo mover: acota la búsqueda al índice
  -- (business_id, item_id) del kardex en vez de barrer todo el negocio.
  select coalesce(array_agg(distinct x.item_id), '{}') into v_item_ids
    from (
      select poi.inventory_item_id as item_id
        from public.purchase_order_items poi
       where poi.purchase_order_id = p_order_id
      union
      select nullif(l ->> 'inventory_item_id', '')::uuid
        from public.purchase_order_edits e
        cross join lateral jsonb_array_elements(
          coalesce(e.before_snapshot -> 'lines', '[]'::jsonb)
          || coalesce(e.after_snapshot -> 'lines', '[]'::jsonb)) l
       where e.purchase_order_id = p_order_id
      union
      select prl.item_id
        from public.purchase_reception_lines prl
       where prl.id = any (v_recv_ids)
    ) x
   where x.item_id is not null;

  -- ── Plan: lo que entró neto, por almacén e insumo ──
  select coalesce(jsonb_agg(jsonb_build_object(
           'warehouse_id',   g.warehouse_id,
           'warehouse_name', w.name,
           'item_id',        g.item_id,
           'item_name',      coalesce(ii.name, 'Insumo'),
           'unit',           ii.unit,
           'quantity',       g.net_qty,
           'unit_cost',      case
                               when g.net_value > 0 then round(g.net_value / g.net_qty, 4)
                               else coalesce(g.last_cost, 0)
                             end,
           'stock_before',   coalesce(st.quantity, 0),
           'stock_after',    coalesce(st.quantity, 0) - g.net_qty
         ) order by coalesce(ii.name, ''), w.name), '[]'::jsonb)
    into v_plan
    from (
      select m.warehouse_id,
             m.item_id,
             sum(m.quantity)                                  as net_qty,
             sum(m.quantity * coalesce(m.cost_per_unit, 0))   as net_value,
             (array_agg(m.cost_per_unit order by m.created_at desc)
                filter (where m.quantity > 0 and coalesce(m.cost_per_unit, 0) > 0))[1]
                                                              as last_cost
        from public.inventory_movements m
       where m.business_id = v_business_id
         and m.item_id = any (v_item_ids)
         and m.movement_type = 'purchase'
         and (
               (m.reference_type = 'purchase_order' and m.reference_id = p_order_id)
            or (m.reference_type = 'purchase_reception_line' and m.reference_id = any (v_recv_ids))
            or (m.reference_type in ('purchase_order_item',
                                     'purchase_order_edit',
                                     'purchase_order_edit_reversal')
                and m.reference_id = any (v_line_ids))
             )
       group by m.warehouse_id, m.item_id
      having sum(m.quantity) > 0.000001
    ) g
    left join public.inventory_items ii on ii.id = g.item_id
    left join public.warehouses w on w.id = g.warehouse_id
    left join public.inventory_stock st
      on st.warehouse_id = g.warehouse_id and st.item_id = g.item_id;

  select count(*) into v_negative
    from jsonb_array_elements(v_plan) s
   where (s ->> 'stock_after')::numeric < 0;

  -- ── Cuenta por pagar vinculada ──
  select * into v_credit
    from public.supplier_credits
   where purchase_order_id = p_order_id
     and status <> 'cancelled'
   order by created_at
   limit 1;
  v_has_credit := found;
  if v_has_credit then
    select coalesce(sum(scp.amount), 0) into v_paid
      from public.supplier_credit_payments scp
     where scp.supplier_credit_id = v_credit.id;
  end if;

  select count(*) into v_receptions
    from public.purchase_receptions pr
   where pr.purchase_order_id = p_order_id
     and pr.status <> 'cancelled';

  if v_preview then
    return jsonb_build_object(
      'id', p_order_id,
      'status', v_order.status::text,
      'replayed', false,
      'preview', true,
      'lines', v_plan,
      'negative_items', v_negative,
      'receptions_to_cancel', v_receptions,
      'has_payable', v_has_credit,
      'payable_amount', case when v_has_credit then v_credit.original_amount end,
      'payable_paid', v_paid,
      'blocked_reason', case when v_paid > 0 then 'PURCHASE_ORDER_PAYABLE_HAS_PAYMENTS' end
    );
  end if;

  if v_paid > 0 then
    raise exception
      'PURCHASE_ORDER_PAYABLE_HAS_PAYMENTS: la cuenta por pagar ya tiene abonos por %; resuelvela antes de anular la compra', v_paid;
  end if;

  -- Foto del ANTES, para la bitácora.
  select jsonb_build_object(
           'order', to_jsonb(v_order),
           'lines', coalesce((
             select jsonb_agg(to_jsonb(poi) order by poi.id)
               from public.purchase_order_items poi
              where poi.purchase_order_id = p_order_id), '[]'::jsonb)
         )
    into v_before;

  -- ── 1. Devolver la mercancía ──
  for v_step in select value from jsonb_array_elements(v_plan) loop
    v_qty := (v_step ->> 'quantity')::numeric;
    insert into public.inventory_movements (
      business_id, warehouse_id, item_id, movement_type, quantity,
      cost_per_unit, reference_id, reference_type, notes, created_by
    ) values (
      v_business_id,
      (v_step ->> 'warehouse_id')::uuid,
      (v_step ->> 'item_id')::uuid,
      'purchase',
      -v_qty,
      nullif((v_step ->> 'unit_cost')::numeric, 0),
      p_order_id,
      'purchase_order_cancel',
      left(concat('Anulacion de ', v_order.order_number, ': ', v_reason), 500),
      v_user_id
    );
    v_movements := v_movements + 1;
  end loop;

  -- ── 2. Costo maestro ──
  for v_item_id in
    select distinct (s ->> 'item_id')::uuid from jsonb_array_elements(v_plan) s
  loop
    -- La última entrada de compra del insumo, venga de donde venga.
    select m.id, m.cost_per_unit, m.reference_type, m.reference_id
      into v_last_id, v_last_cost, v_last_ref, v_last_refid
      from public.inventory_movements m
     where m.business_id = v_business_id
       and m.item_id = v_item_id
       and m.movement_type = 'purchase'
       and m.quantity > 0
       and coalesce(m.cost_per_unit, 0) > 0
     order by m.created_at desc, m.id desc
     limit 1;

    continue when v_last_id is null;
    -- Solo si fue ESTA orden la que dejó el costo...
    continue when not (
         (v_last_ref = 'purchase_order' and v_last_refid = p_order_id)
      or (v_last_ref = 'purchase_reception_line' and v_last_refid = any (v_recv_ids))
      or (v_last_ref in ('purchase_order_item', 'purchase_order_edit')
          and v_last_refid = any (v_line_ids)));

    -- ...y nadie lo cambió a mano después.
    select ii.cost into v_cur_cost
      from public.inventory_items ii
     where ii.id = v_item_id and ii.business_id = v_business_id;
    continue when v_cur_cost is null
               or round(v_cur_cost::numeric, 4) <> round(v_last_cost::numeric, 4);

    -- La última compra VÁLIDA anterior (ni de esta orden ni de otra anulada).
    v_prev_cost := null;
    select m.cost_per_unit into v_prev_cost
      from public.inventory_movements m
      left join public.purchase_orders po
        on m.reference_type = 'purchase_order' and po.id = m.reference_id
      left join public.purchase_reception_lines prl
        on m.reference_type = 'purchase_reception_line' and prl.id = m.reference_id
      left join public.purchase_receptions pr
        on pr.id = prl.reception_id
      left join public.purchase_order_items poi
        on m.reference_type in ('purchase_order_item', 'purchase_order_edit')
       and poi.id = m.reference_id
      left join public.purchase_orders po2
        on po2.id = poi.purchase_order_id
     where m.business_id = v_business_id
       and m.item_id = v_item_id
       and m.movement_type = 'purchase'
       and m.quantity > 0
       and coalesce(m.cost_per_unit, 0) > 0
       and not (
             (m.reference_type = 'purchase_order' and m.reference_id = p_order_id)
          or (m.reference_type = 'purchase_reception_line' and m.reference_id = any (v_recv_ids))
          or (m.reference_type in ('purchase_order_item', 'purchase_order_edit')
              and m.reference_id = any (v_line_ids)))
       and coalesce(po.status::text, '') <> 'cancelled'
       and coalesce(pr.status, '') <> 'cancelled'
       and coalesce(po2.status::text, '') <> 'cancelled'
       -- Recepción directa anulada: su entrada sigue en el kardex, pero la
       -- anulación dejó un movimiento 'direct_receipt_cancel' con su id.
       and not (m.reference_type = 'direct_receipt' and exists (
             select 1 from public.inventory_movements c
              where c.business_id = v_business_id
                and c.item_id = v_item_id
                and c.reference_type = 'direct_receipt_cancel'
                and c.reference_id = m.reference_id))
     order by m.created_at desc, m.id desc
     limit 1;

    if v_prev_cost is not null then
      update public.inventory_items
         set cost = round(v_prev_cost::numeric, 4)
       where id = v_item_id and business_id = v_business_id;
      v_costs := v_costs + 1;
    end if;
  end loop;

  -- ── 3. Conduces ── (antes que la orden: el re-aprendizaje del precio del
  -- suplidor que dispara cada uno ya los ve anulados)
  update public.purchase_receptions
     set status = 'cancelled'
   where purchase_order_id = p_order_id
     and status <> 'cancelled';
  get diagnostics v_receptions = row_count;

  -- ── 4. Cuenta por pagar (sin abonos: se verificó arriba) ──
  if v_has_credit then
    update public.supplier_credits
       set status  = 'cancelled',
           balance = 0,
           notes   = left(concat_ws(' | ', nullif(btrim(notes), ''),
                                    concat('Anulada con la compra ', v_order.order_number, ': ', v_reason)), 1000)
     where id = v_credit.id;
  end if;

  -- ── 5. La orden ──
  update public.purchase_orders
     set status        = 'cancelled'::public.purchase_status,
         cancelled_at  = now(),
         cancelled_by  = v_user_id,
         cancel_reason = v_reason
   where id = p_order_id;

  -- ── 6. Bitácora ──
  select * into v_order from public.purchase_orders where id = p_order_id;
  select jsonb_build_object(
           'order', to_jsonb(v_order),
           'lines', coalesce((
             select jsonb_agg(to_jsonb(poi) order by poi.id)
               from public.purchase_order_items poi
              where poi.purchase_order_id = p_order_id), '[]'::jsonb),
           'reversals', v_plan
         )
    into v_after;

  insert into public.purchase_order_edits (
    business_id, purchase_order_id, edited_by, reason,
    before_snapshot, after_snapshot, movements_created, idempotency_key, action
  ) values (
    v_business_id, p_order_id, v_user_id, v_reason,
    v_before, v_after, v_movements, v_key, 'cancel'
  );

  return jsonb_build_object(
    'id', p_order_id,
    'status', 'cancelled',
    'replayed', false,
    'preview', false,
    'movements_created', v_movements,
    'costs_restored', v_costs,
    'receptions_cancelled', v_receptions,
    'payable_cancelled', v_has_credit,
    'negative_items', v_negative,
    'lines', v_plan
  );
end;
$$;

revoke all on function public.fn_purchase_order_cancel(uuid, text, text, boolean) from public;
revoke all on function public.fn_purchase_order_cancel(uuid, text, text, boolean) from anon;
grant execute on function public.fn_purchase_order_cancel(uuid, text, text, boolean) to authenticated;

comment on function public.fn_purchase_order_cancel(uuid, text, text, boolean) is
  'Anula una compra registrada en una sola transaccion: devuelve al almacen lo '
  'que la orden metio (neto de recepciones y correcciones), restaura el costo '
  'maestro si esta compra lo habia fijado, cancela conduces y la cuenta por '
  'pagar sin abonos, y deja bitacora (purchase_order_edits.action=cancel). '
  'p_preview=true solo describe lo que haria. Ver 20260929_0050.';

commit;
