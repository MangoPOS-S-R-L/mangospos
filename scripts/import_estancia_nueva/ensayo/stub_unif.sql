-- Stub mínimo para ensayar UNIF_0/1/9 (unificar bodegas de la cafetería).
-- Columnas sacadas de supabase/schema.sql y de las migraciones 20260308_0016
-- (sync de stock), 20260513_0017 (reason_code), 20260513_0018 (transferencias),
-- 20260516_0006 (producción), 20260516_0011 (conteo físico), 20260901_0001/0005.
-- consume_inventory_from_order es un DOBLE: muda el consumo de la orden a la
-- bodega de la cascada, como la real (reconciliación por par) y anota la llamada.
create extension if not exists pgcrypto;

create type public.movement_type as enum
  ('purchase', 'sale', 'adjustment', 'transfer_in', 'transfer_out', 'waste',
   'return', 'production_in', 'production_out');
create type public.order_status as enum
  ('open', 'sent_to_kitchen', 'partially_paid', 'paid', 'void');

create table public.business_settings (
  business_id uuid primary key,
  inventory_mode text not null default 'none',
  warehouse_sections_enabled boolean default false,
  transfers_require_approval boolean not null default false,
  inventory_costing_method text default 'last_price'
);

create table public.print_areas (
  id uuid primary key default gen_random_uuid(),
  business_id uuid not null, name text not null, code text not null,
  is_active boolean not null default true,
  created_at timestamptz not null default now()
);

create table public.warehouses (
  id uuid primary key default gen_random_uuid(),
  business_id uuid not null,
  name text not null,
  address text,
  is_main boolean default false,
  is_active boolean default true,
  created_at timestamptz default now(),
  shows_in_pos boolean not null default false,
  warehouse_type text not null default 'general',
  production_area_id uuid
);

create table public.inventory_items (
  id uuid primary key default gen_random_uuid(),
  business_id uuid not null,
  sku text, barcode text, name text not null,
  unit text default 'unidad', cost numeric default 0,
  is_active boolean default true,
  created_at timestamptz default now()
);

create table public.inventory_stock (
  id uuid primary key default gen_random_uuid(),
  warehouse_id uuid not null references public.warehouses(id),
  item_id uuid not null references public.inventory_items(id),
  quantity numeric default 0,
  last_updated timestamptz default now(),
  unique (warehouse_id, item_id)
);

create table public.inventory_movements (
  id uuid primary key default gen_random_uuid(),
  business_id uuid not null,
  warehouse_id uuid not null references public.warehouses(id),
  item_id uuid not null references public.inventory_items(id),
  movement_type public.movement_type not null,
  quantity numeric not null,
  cost_per_unit numeric,
  reference_id uuid,
  reference_type text,
  notes text,
  created_by uuid,
  created_at timestamptz default now(),
  reason_code text check (reason_code is null or reason_code in
    ('physical_count', 'breakage', 'expiration', 'theft', 'donation', 'correction', 'other'))
);

create function public.fn_sync_inventory_stock_on_movement() returns trigger
language plpgsql as $$
begin
  insert into public.inventory_stock (warehouse_id, item_id, quantity, last_updated)
  values (new.warehouse_id, new.item_id, new.quantity, now())
  on conflict (warehouse_id, item_id)
  do update set quantity = public.inventory_stock.quantity + excluded.quantity,
                last_updated = now();
  return new;
end $$;
create trigger trg_inventory_stock_sync after insert on public.inventory_movements
  for each row execute function public.fn_sync_inventory_stock_on_movement();

create table public.physical_count_sessions (
  id uuid primary key default gen_random_uuid(),
  business_id uuid not null,
  warehouse_id uuid not null references public.warehouses(id),
  code text not null,
  status text not null default 'draft'
    check (status in ('draft', 'in_progress', 'completed', 'cancelled')),
  cancellation_reason text,
  started_at timestamptz not null default now(),
  frozen_at timestamptz, completed_at timestamptz, cancelled_at timestamptz,
  unique (business_id, code)
);

create table public.physical_count_lines (
  id uuid primary key default gen_random_uuid(),
  session_id uuid not null references public.physical_count_sessions(id),
  item_id uuid not null references public.inventory_items(id),
  snapshot_quantity numeric(14,4) not null,
  counted_quantity numeric(14,4),
  applied_adjustment_id uuid references public.inventory_movements(id),
  unique (session_id, item_id)
);

create table public.stock_transfers (
  id uuid primary key default gen_random_uuid(),
  business_id uuid not null,
  from_warehouse_id uuid not null references public.warehouses(id),
  to_warehouse_id uuid not null references public.warehouses(id),
  transfer_number text not null,
  status text not null default 'sent'
    check (status in ('pending_approval', 'sent', 'received', 'cancelled'))
);

create table public.purchase_orders (
  id uuid primary key default gen_random_uuid(),
  business_id uuid not null,
  warehouse_id uuid references public.warehouses(id),
  status text default 'draft'
);

create table public.orders (
  id uuid primary key default gen_random_uuid(),
  session_id uuid,
  status text not null default 'open'
    check (status in ('open', 'sent', 'served', 'canceled', 'paid')),
  status_ext public.order_status not null default 'open'
);

create table public._consume_calls (order_id uuid, at timestamptz default clock_timestamp());

create function public.consume_inventory_from_order(_order_id uuid) returns void
language plpgsql as $$
declare v_b uuid; v_pool uuid; r record;
begin
  insert into public._consume_calls (order_id) values (_order_id);
  select business_id into v_b from public.inventory_movements
   where reference_id = _order_id limit 1;
  select id into v_pool from public.warehouses
   where business_id = v_b and coalesce(is_active, true) and shows_in_pos
   order by is_main desc, created_at limit 1;
  if v_pool is null then
    select id into v_pool from public.warehouses where business_id = v_b
     order by is_main desc, created_at asc nulls first, id limit 1;
  end if;
  for r in
    select item_id, warehouse_id, sum(quantity) as q from public.inventory_movements
     where reference_id = _order_id and reference_type = 'order' and movement_type = 'sale'
     group by 1, 2 having sum(quantity) <> 0
  loop
    if r.warehouse_id <> v_pool then
      insert into public.inventory_movements
        (business_id, warehouse_id, item_id, movement_type, quantity, reference_id, reference_type)
      values (v_b, r.warehouse_id, r.item_id, 'sale', -r.q, _order_id, 'order'),
             (v_b, v_pool,         r.item_id, 'sale',  r.q, _order_id, 'order');
    end if;
  end loop;
end $$;

-- Capas de costo: DOBLE simplificado de fn_inventory_cost_layers_apply
-- (20260902_0012). Entradas crean capa; salidas consumen la más nueva (UEPS);
-- lo que no alcanza queda como faltante (aquí: simplemente no consume nada).
create table public.inventory_cost_layers (
  id uuid primary key default gen_random_uuid(),
  seq bigint generated always as identity,
  business_id uuid not null, item_id uuid not null, warehouse_id uuid not null,
  source_movement_id uuid references public.inventory_movements(id) on delete set null,
  source_type text not null,
  received_at timestamptz not null default now(),
  quantity_in numeric(14,4) not null check (quantity_in > 0),
  quantity_remaining numeric(14,4) not null check (quantity_remaining >= 0),
  unit_cost numeric(14,4) not null default 0,
  notes text
);

create function public.fn_stub_cost_layers() returns trigger
language plpgsql as $$
declare v_m text; v_need numeric; r record; v_take numeric;
begin
  select coalesce(inventory_costing_method, 'last_price') into v_m
    from public.business_settings where business_id = new.business_id;
  if coalesce(v_m, 'last_price') = 'last_price' or new.quantity = 0 then
    return new;
  end if;
  if new.quantity > 0 then
    insert into public.inventory_cost_layers
      (business_id, item_id, warehouse_id, source_movement_id, source_type,
       received_at, quantity_in, quantity_remaining, unit_cost)
    values (new.business_id, new.item_id, new.warehouse_id, new.id,
            case when new.movement_type::text in ('sale', 'transfer_out', 'waste', 'production_out') then 'return'
                 when new.movement_type::text in ('purchase', 'transfer_in', 'return', 'production_in')
                   then new.movement_type::text
                 else 'adjustment' end,
            new.created_at, new.quantity, new.quantity, coalesce(new.cost_per_unit, 0));
    return new;
  end if;
  v_need := -new.quantity;
  for r in
    select id, quantity_remaining from public.inventory_cost_layers
     where business_id = new.business_id and item_id = new.item_id
       and warehouse_id = new.warehouse_id and quantity_remaining > 0
     order by received_at desc, seq desc
  loop
    exit when v_need <= 0;
    v_take := least(r.quantity_remaining, v_need);
    update public.inventory_cost_layers set quantity_remaining = quantity_remaining - v_take
     where id = r.id;
    v_need := v_need - v_take;
  end loop;
  return new;
end $$;

create trigger trg_inventory_cost_layers after insert on public.inventory_movements
  for each row execute function public.fn_stub_cost_layers();
