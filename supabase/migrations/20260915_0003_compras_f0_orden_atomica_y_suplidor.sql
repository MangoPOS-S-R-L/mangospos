-- =============================================================================
-- 20260915_0003 — Compras F0: orden de compra atómica + a quién se le compra
--
-- PRD: docs/PRD_COMPRAS_PEDIDO_SUGERIDO.md (F0, decisiones D3/D7/D9).
--
-- QUÉ ARREGLA:
--   B1  «Crear OC» de Reorden mandaba status 'pending', que el enum no admite:
--       la función solo acepta draft/sent y lo dice con un error claro.
--   B5  Crear una orden eran DOS inserts sueltos (cabecera y líneas) y el
--       número salía de leer el último + 1: una falla dejaba cabeceras
--       huérfanas y dos personas a la vez sacaban el mismo número.
--       `fn_purchase_order_create` hace todo en UNA transacción y numera bajo
--       un candado por negocio. Con `p_idempotency_key`, un doble clic
--       devuelve la misma orden en vez de crear dos.
--   B3  El reorden le pedía al suplidor de la ÚLTIMA orden, aunque fuera un
--       borrador o una cancelada, e ignoraba al preferido.
--       `fn_purchase_resolve_suppliers` decide por insumo (D3):
--         preferido → el ÚNICO vínculo activo → el de la última compra
--         RECIBIDA (órdenes, recepciones directas o conduce).
--       Devuelve también el tiempo de entrega, la presentación de compra, el
--       mínimo de compra y el costo por unidad base con su procedencia.
--   B8  `inventory_items.preferred_supplier_id` no existe en prod: se asegura
--       con la MISMA definición de 20260813_0001.
--   B4  `supplier_items.last_price` no decía en qué unidad estaba: queda
--       documentado como precio por UNIDAD DE COMPRA.
--
-- COLUMNAS ASEGURADAS: la función escribe columnas que llegaron en migraciones
--   que un negocio puede no tener aplicadas (invoice_number 20260704_0001,
--   discount 20260725_0001, ncf 20260814_0003, empaque 20260608_0002). Se
--   agregan con la MISMA definición y `if not exists`: donde ya están no pasa
--   nada. `idempotency_key` es nueva.
--
-- PERMISOS: las dos funciones son SECURITY INVOKER — corren con las políticas
--   RLS de siempre (po_write / po_write_compras). Quien hoy no puede crear
--   una orden, tampoco puede con esto.
--
-- NEGOCIOS SIN INVENTARIO: no se enteran. Nada de esto escribe filas al
--   aplicarse; las funciones solo actúan cuando alguien crea una orden.
--
-- PRUEBA: supabase/tests/compras_f0_local_test.sh (Postgres 15 local).
-- IDEMPOTENTE: sí. REVERSIBLE: sí (_ROLLBACK).
-- =============================================================================

begin;

set local lock_timeout = '5s';
set local statement_timeout = '60s';

-- ---------------------------------------------------------------------------
-- 1. Columnas
-- ---------------------------------------------------------------------------
alter table public.purchase_orders
  add column if not exists invoice_number text;                     -- 20260704_0001
alter table public.purchase_orders
  add column if not exists discount numeric not null default 0;     -- 20260725_0001
alter table public.purchase_order_items
  add column if not exists discount numeric not null default 0;     -- 20260725_0001
alter table public.purchase_orders
  add column if not exists ncf varchar(20);                         -- 20260814_0003
alter table public.purchase_order_items
  add column if not exists purchase_unit text;                      -- 20260608_0002
alter table public.purchase_order_items
  add column if not exists pack_size numeric;                       -- 20260608_0002

alter table public.inventory_items
  add column if not exists preferred_supplier_id uuid
    references public.suppliers(id) on delete set null;             -- 20260813_0001
create index if not exists idx_inventory_items_preferred_supplier
  on public.inventory_items (preferred_supplier_id)
  where preferred_supplier_id is not null;

alter table public.purchase_orders
  add column if not exists idempotency_key text;
create unique index if not exists idx_purchase_orders_idempotency
  on public.purchase_orders (business_id, idempotency_key)
  where idempotency_key is not null;

comment on column public.purchase_orders.idempotency_key is
  'Llave que manda la app al crear la orden. Repetir la llamada con la misma '
  'llave devuelve la orden ya creada (doble clic, reintento sin red).';

comment on column public.supplier_items.last_price is
  'Precio de lista por UNIDAD DE COMPRA (purchase_unit, que contiene '
  'pack_size unidades base). Costo por unidad base = last_price / pack_size.';

-- ---------------------------------------------------------------------------
-- 2. Crear una orden de compra, completa o nada
-- ---------------------------------------------------------------------------
create or replace function public.fn_purchase_order_create(
  p_business_id     uuid,
  p_warehouse_id    uuid,
  p_supplier_id     uuid,
  p_lines           jsonb,
  p_status          text  default 'draft',
  p_expected_date   date  default null,
  p_header          jsonb default '{}'::jsonb,
  p_idempotency_key text  default null
)
returns jsonb
language plpgsql
security invoker
set search_path = public
as $$
declare
  v_header    jsonb := coalesce(p_header, '{}'::jsonb);
  v_requested text  := nullif(trim(v_header ->> 'order_number'), '');
  v_key       text  := nullif(trim(p_idempotency_key), '');
  v_existing  record;
  v_number    text;
  v_next      integer;
  v_order_id  uuid;
  v_line      jsonb;
  v_item_id   uuid;
  v_qty       numeric;
  v_cost      numeric;
  v_lines     integer := 0;
begin
  if p_business_id is null or p_warehouse_id is null then
    raise exception 'PURCHASE_ORDER_INVALID: falta el negocio o el almacén';
  end if;

  -- 'received' NO se crea acá: la mercancía entra por la RPC de recepción,
  -- que es la que mueve stock y costo.
  if coalesce(p_status, 'draft') not in ('draft', 'sent') then
    raise exception 'PURCHASE_ORDER_INVALID_STATUS: una orden nace en draft o sent, no en %', p_status;
  end if;

  if p_lines is null or jsonb_typeof(p_lines) <> 'array'
     or jsonb_array_length(p_lines) = 0 then
    raise exception 'PURCHASE_ORDER_EMPTY: la orden no tiene líneas';
  end if;

  if not exists (
    select 1 from public.warehouses w
     where w.id = p_warehouse_id and w.business_id = p_business_id
  ) then
    raise exception 'PURCHASE_ORDER_INVALID: el almacén no es de este negocio';
  end if;

  if p_supplier_id is not null and not exists (
    select 1 from public.suppliers s
     where s.id = p_supplier_id and s.business_id = p_business_id
  ) then
    raise exception 'PURCHASE_ORDER_INVALID: el suplidor no es de este negocio';
  end if;

  -- Un solo candado por negocio para la llave y el número: dos cajeros a la
  -- vez esperan su turno en vez de sacar el mismo número.
  perform pg_advisory_xact_lock(
    hashtextextended('purchase_order_number:' || p_business_id::text, 0)
  );

  if v_key is not null then
    select po.id, po.order_number
      into v_existing
      from public.purchase_orders po
     where po.business_id = p_business_id
       and po.idempotency_key = v_key;
    if found then
      return jsonb_build_object(
        'id', v_existing.id,
        'order_number', v_existing.order_number,
        'reused', true
      );
    end if;
  end if;

  -- El número que pidió la pantalla, si está libre; si no, el siguiente
  -- PO-00000 del negocio (mismo formato que la app).
  if v_requested is not null and not exists (
    select 1 from public.purchase_orders po
     where po.business_id = p_business_id and po.order_number = v_requested
  ) then
    v_number := v_requested;
  else
    select coalesce(max(substring(po.order_number from '^PO-(\d{1,9})$')::integer), 0) + 1
      into v_next
      from public.purchase_orders po
     where po.business_id = p_business_id
       and po.order_number ~ '^PO-\d{1,9}$';
    v_number := 'PO-' || lpad(v_next::text, 5, '0');
  end if;

  insert into public.purchase_orders (
    business_id, supplier_id, warehouse_id, order_number, status,
    subtotal, tax, discount, total, expected_date, notes,
    invoice_number, ncf, idempotency_key, created_by
  )
  values (
    p_business_id, p_supplier_id, p_warehouse_id, v_number,
    coalesce(p_status, 'draft')::public.purchase_status,
    coalesce(nullif(v_header ->> 'subtotal', '')::numeric, 0),
    coalesce(nullif(v_header ->> 'tax', '')::numeric, 0),
    greatest(coalesce(nullif(v_header ->> 'discount', '')::numeric, 0), 0),
    coalesce(nullif(v_header ->> 'total', '')::numeric, 0),
    p_expected_date,
    nullif(trim(v_header ->> 'notes'), ''),
    nullif(trim(v_header ->> 'invoice_number'), ''),
    nullif(trim(v_header ->> 'ncf'), ''),
    v_key,
    auth.uid()
  )
  returning id into v_order_id;

  for v_line in select value from jsonb_array_elements(p_lines) loop
    v_qty  := nullif(v_line ->> 'quantity_ordered', '')::numeric;
    v_cost := coalesce(nullif(v_line ->> 'unit_cost', '')::numeric, 0);
    v_item_id := nullif(v_line ->> 'inventory_item_id', '')::uuid;

    if coalesce(v_qty, 0) <= 0 then
      raise exception 'PURCHASE_ORDER_LINE_INVALID: la cantidad debe ser mayor que 0 (línea %)', v_lines + 1;
    end if;
    if v_cost < 0 then
      raise exception 'PURCHASE_ORDER_LINE_INVALID: el costo no puede ser negativo (línea %)', v_lines + 1;
    end if;
    if v_item_id is not null and not exists (
      select 1 from public.inventory_items ii
       where ii.id = v_item_id and ii.business_id = p_business_id
    ) then
      raise exception 'PURCHASE_ORDER_ITEM_INVALID: el insumo de la línea % no es de este negocio', v_lines + 1;
    end if;

    insert into public.purchase_order_items (
      purchase_order_id, inventory_item_id, description,
      quantity_ordered, unit_cost, tax_rate, total, discount,
      purchase_unit, pack_size
    )
    values (
      v_order_id, v_item_id, nullif(trim(v_line ->> 'description'), ''),
      v_qty, v_cost,
      coalesce(nullif(v_line ->> 'tax_rate', '')::numeric, 18),
      coalesce(nullif(v_line ->> 'total', '')::numeric, v_qty * v_cost),
      greatest(coalesce(nullif(v_line ->> 'discount', '')::numeric, 0), 0),
      nullif(trim(v_line ->> 'purchase_unit'), ''),
      coalesce(nullif(nullif(v_line ->> 'pack_size', '')::numeric, 0), 1)
    );
    v_lines := v_lines + 1;
  end loop;

  return jsonb_build_object(
    'id', v_order_id,
    'order_number', v_number,
    'reused', false,
    'lines', v_lines
  );
end;
$$;

comment on function public.fn_purchase_order_create(uuid, uuid, uuid, jsonb, text, date, jsonb, text) is
  'Crea una orden de compra (cabecera + líneas) en una sola transacción, con '
  'número PO-00000 bajo candado por negocio e idempotencia opcional. Cantidades '
  'y costos de las líneas en UNIDAD BASE; purchase_unit/pack_size son la foto '
  'del empaque. Nace en draft o sent. Ver 20260915_0003.';

-- ---------------------------------------------------------------------------
-- 3. A quién se le compra cada insumo, y a qué precio
-- ---------------------------------------------------------------------------
create or replace function public.fn_purchase_resolve_suppliers(
  p_business_id uuid,
  p_item_ids    uuid[] default null
)
returns table (
  item_id          uuid,
  supplier_id      uuid,
  supplier_name    text,
  supplier_source  text,
  lead_time_days   integer,
  purchase_unit    text,
  pack_size        numeric,
  min_order_qty    numeric,
  unit_cost_base   numeric,
  cost_source      text,
  last_purchase_at timestamptz
)
language sql
stable
security invoker
set search_path = public
as $$
  with items as (
    select ii.id, ii.cost, ii.purchase_unit, ii.pack_size, ii.preferred_supplier_id
      from public.inventory_items ii
     where ii.business_id = p_business_id
       and (p_item_ids is null or ii.id = any (p_item_ids))
  ),
  -- Mercancía que ENTRÓ, con su suplidor, por las tres puertas: orden
  -- recibida, recepción directa y recepción con conduce. Nunca borradores:
  -- un borrador no tiene movimiento.
  purchases as (
    select im.item_id, po.supplier_id, im.cost_per_unit, im.created_at
      from public.inventory_movements im
      join public.purchase_orders po on po.id = im.reference_id
     where im.business_id = p_business_id
       and im.movement_type = 'purchase'
       and im.reference_type = 'purchase_order'
       and po.supplier_id is not null
       and (p_item_ids is null or im.item_id = any (p_item_ids))
    union all
    select im.item_id, dr.supplier_id, im.cost_per_unit, im.created_at
      from public.inventory_movements im
      join public.direct_receipts dr on dr.id = im.reference_id
     where im.business_id = p_business_id
       and im.movement_type = 'purchase'
       and im.reference_type = 'direct_receipt'
       and dr.supplier_id is not null
       and (p_item_ids is null or im.item_id = any (p_item_ids))
    union all
    select im.item_id, pr.supplier_id, im.cost_per_unit, im.created_at
      from public.inventory_movements im
      join public.purchase_reception_lines prl on prl.id = im.reference_id
      join public.purchase_receptions pr on pr.id = prl.reception_id
     where im.business_id = p_business_id
       and im.movement_type = 'purchase'
       and im.reference_type = 'purchase_reception_line'
       and pr.supplier_id is not null
       and (p_item_ids is null or im.item_id = any (p_item_ids))
  ),
  last_purchase as (
    select distinct on (p.item_id) p.item_id, p.supplier_id
      from purchases p
     order by p.item_id, p.created_at desc
  ),
  links as (
    select si.inventory_item_id as item_id,
           count(*) as active_links,
           (array_agg(si.supplier_id order by si.updated_at desc nulls last))[1] as newest_supplier
      from public.supplier_items si
     where si.business_id = p_business_id
       and si.is_active
       and (p_item_ids is null or si.inventory_item_id = any (p_item_ids))
     group by si.inventory_item_id
  ),
  chosen as (
    select i.id as item_id,
           i.cost,
           i.purchase_unit as item_purchase_unit,
           i.pack_size     as item_pack_size,
           case
             when i.preferred_supplier_id is not null then i.preferred_supplier_id
             when l.active_links = 1                 then l.newest_supplier
             else lp.supplier_id
           end as supplier_id,
           case
             when i.preferred_supplier_id is not null then 'preferido'
             when l.active_links = 1                 then 'vinculo'
             when lp.supplier_id is not null         then 'ultima_compra'
           end as supplier_source
      from items i
      left join links l on l.item_id = i.id
      left join last_purchase lp on lp.item_id = i.id
  ),
  priced as (
    select c.*,
           s.name as supplier_name,
           s.lead_time_days,
           si.min_order_qty,
           si.last_price,
           -- La presentación va en PAREJA: la del vínculo si trae unidad y
           -- contenido; si no, la del insumo. Mezclarlas daría «Caja × 1».
           (nullif(trim(si.purchase_unit), '') is not null
              and coalesce(si.pack_size, 0) > 0) as link_has_pack,
           si.purchase_unit as link_unit,
           si.pack_size     as link_pack
      from chosen c
      left join public.suppliers s on s.id = c.supplier_id
      left join public.supplier_items si
        on si.supplier_id = c.supplier_id
       and si.inventory_item_id = c.item_id
       and si.is_active
  )
  select
    p.item_id,
    p.supplier_id,
    p.supplier_name,
    p.supplier_source,
    p.lead_time_days::integer,
    case when p.link_has_pack then trim(p.link_unit)
         else nullif(trim(p.item_purchase_unit), '') end,
    case when p.link_has_pack then p.link_pack
         else coalesce(nullif(p.item_pack_size, 0), 1) end,
    p.min_order_qty,
    coalesce(
      lc.cost_per_unit,
      case when coalesce(p.last_price, 0) > 0 then
        p.last_price / case when p.link_has_pack then p.link_pack
                            else coalesce(nullif(p.item_pack_size, 0), 1) end
      end,
      nullif(p.cost, 0)
    ),
    case
      when lc.cost_per_unit is not null   then 'ultima_compra'
      when coalesce(p.last_price, 0) > 0  then 'lista'
      when coalesce(p.cost, 0) > 0        then 'insumo'
    end,
    lc.created_at
  from priced p
  left join lateral (
    select pu.cost_per_unit, pu.created_at
      from purchases pu
     where pu.item_id = p.item_id
       and pu.supplier_id = p.supplier_id
       and coalesce(pu.cost_per_unit, 0) > 0
     order by pu.created_at desc
     limit 1
  ) lc on true;
$$;

comment on function public.fn_purchase_resolve_suppliers(uuid, uuid[]) is
  'Por insumo: a quién comprarle (preferido → único vínculo activo → última '
  'compra RECIBIDA), su tiempo de entrega, la presentación de compra, el mínimo '
  'de compra y el costo por unidad base (última compra a ese suplidor → precio '
  'de lista / empaque → costo del insumo). Ver 20260915_0003.';

grant execute on function public.fn_purchase_order_create(uuid, uuid, uuid, jsonb, text, date, jsonb, text) to authenticated;
grant execute on function public.fn_purchase_resolve_suppliers(uuid, uuid[]) to authenticated;

commit;

notify pgrst, 'reload schema';
