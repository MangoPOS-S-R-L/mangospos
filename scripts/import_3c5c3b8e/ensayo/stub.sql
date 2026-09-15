-- Stub mínimo del esquema de prod para ensayar la carga de 007 BAR & SNACK.
-- Base: el stub de Tía Sara + las columnas/tablas de inventario sacadas de
-- supabase/schema.sql y las migraciones 20260308_0016 (stock sync),
-- 20260508_0001 (print_area_code nullable), 20260513_0012/0013 (flags),
-- 20260514_0011, 20260516_0003/0012/0015, 20260517_0001, 20260613_0001,
-- 20260714_0001 (recost último precio), 20260901_0001/0005.
create extension if not exists pgcrypto;

create type public.movement_type as enum
  ('purchase', 'sale', 'adjustment', 'transfer_in', 'transfer_out', 'waste');

create table public.businesses (
  id uuid primary key,
  business_name text, branch_name text, business_type text, country text,
  status text, created_at timestamptz not null default now()
);

create table public.business_settings (
  business_id uuid primary key references public.businesses(id),
  service_fee_enabled boolean default false,
  inventory_mode text default 'none' not null
    check (inventory_mode in ('none', 'basic', 'advanced')),
  currency_code text default 'DOP',
  auto_print_order boolean default true,
  kitchen_enabled boolean default true not null,
  warehouse_sections_enabled boolean default false
);

create table public.taxes (
  id uuid primary key default gen_random_uuid(),
  business_id uuid not null references public.businesses(id),
  name text not null, rate numeric not null,
  is_active boolean default true, is_service_fee boolean default false,
  include_in_ecf boolean default true,
  apply_on_zone boolean default true, apply_on_manual boolean default true,
  apply_on_quick boolean default true, apply_on_takeout boolean default true,
  apply_on_delivery boolean default true
);

create table public.print_areas (
  id uuid default gen_random_uuid() not null primary key,
  business_id uuid not null references public.businesses(id) on delete cascade,
  name text not null, code text not null,
  is_active boolean default true not null,
  created_at timestamptz default now() not null,
  constraint print_areas_business_id_code_key unique (business_id, code)
);

create table public.print_area_printers (
  area_id uuid not null references public.print_areas(id) on delete cascade,
  printer_id uuid not null
);

create table public.categories (
  id uuid not null primary key,
  business_id uuid not null,
  name text not null,
  position integer default 0 not null,
  is_active boolean default true not null,
  created_at timestamptz default now() not null
);

create table public.warehouses (
  id uuid default gen_random_uuid() not null primary key,
  business_id uuid not null,
  name text not null,
  address text,
  is_main boolean default false,
  is_active boolean default true,
  created_at timestamptz default now(),
  warehouse_type text not null default 'general',
  shows_in_pos boolean not null default false
);

create table public.inventory_items (
  id uuid default gen_random_uuid() not null primary key,
  business_id uuid not null,
  sku text,
  name text not null,
  description text,
  unit text default 'unidad',
  cost numeric default 0,
  min_stock numeric default 0,
  max_stock numeric,
  is_active boolean default true,
  created_at timestamptz default now(),
  item_classification text default 'simple',
  costing_method text not null default 'average',
  barcode text,
  tracks_lots boolean not null default false,
  updated_at timestamptz not null default now()
);

create table public.inventory_movements (
  id uuid default gen_random_uuid() not null primary key,
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
  created_at timestamptz default now()
);

create table public.inventory_stock (
  id uuid default gen_random_uuid() not null primary key,
  warehouse_id uuid not null references public.warehouses(id),
  item_id uuid not null references public.inventory_items(id) on delete cascade,
  quantity numeric default 0,
  last_updated timestamptz default now(),
  constraint inventory_stock_warehouse_id_item_id_key unique (warehouse_id, item_id)
);

create table public.menu_items (
  id uuid default gen_random_uuid() not null primary key,
  business_id uuid not null,
  category_id uuid references public.categories(id),
  name text not null,
  price numeric(12,2) default 0 not null,
  tax_mode text default 'exclusive' not null,
  sku text,
  barcode text,
  is_active boolean default true not null,
  created_at timestamptz default now() not null,
  description text,
  is_beverage boolean default false not null,
  cost numeric,
  updated_at timestamptz,
  position integer default 0,
  item_type text not null default 'standard',
  print_area_code text default null,
  is_inventory_tracked boolean not null default false,
  inventory_item_id uuid references public.inventory_items(id),
  auto_disabled boolean not null default false,
  allow_negative_sale boolean not null default false,
  constraint menu_items_tax_mode_check check (tax_mode in ('exclusive','inclusive')),
  constraint menu_items_item_type_check check (item_type in ('standard','combo','extra_only'))
);

create table public.menu_item_taxes (
  item_id uuid not null references public.menu_items(id) on delete cascade,
  tax_id uuid not null references public.taxes(id) on delete cascade,
  primary key (item_id, tax_id)
);

create table public.menu_item_print_areas (
  menu_item_id uuid not null references public.menu_items(id) on delete cascade,
  print_area_id uuid not null references public.print_areas(id) on delete cascade,
  created_at timestamptz not null default now(),
  primary key (menu_item_id, print_area_id)
);

create table public.menus (
  id uuid not null primary key,
  business_id uuid not null,
  name text not null,
  is_active boolean default true not null,
  created_at timestamptz default now() not null
);

create table public.menu_item_links (
  menu_id uuid not null references public.menus(id) on delete cascade,
  item_id uuid not null references public.menu_items(id) on delete cascade,
  position integer default 0 not null,
  created_at timestamptz default now() not null,
  primary key (menu_id, item_id)
);

create table public.recipes (
  id uuid primary key default gen_random_uuid(),
  menu_item_id uuid references public.menu_items(id) on delete cascade
);

create table public.order_items (
  id uuid primary key default gen_random_uuid(),
  product_id uuid references public.menu_items(id) on delete restrict
);

-- trg_inventory_stock_sync (20260308_0016)
create or replace function public.fn_sync_inventory_stock_on_movement()
returns trigger language plpgsql as $$
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

-- trg_inventory_movement_recost, último precio (20260714_0001)
create or replace function public.fn_inventory_movement_recost()
returns trigger language plpgsql as $$
begin
  if new.movement_type <> 'purchase' then return new; end if;
  if new.cost_per_unit is null or new.cost_per_unit <= 0 then return new; end if;
  if new.quantity is null or new.quantity <= 0 then return new; end if;
  update public.inventory_items set cost = round(new.cost_per_unit::numeric, 4)
   where id = new.item_id and business_id = new.business_id;
  return new;
end $$;
create trigger trg_inventory_movement_recost after insert on public.inventory_movements
for each row execute function public.fn_inventory_movement_recost();

-- Semilla base: tienda sin cocina, ITBIS 18%, áreas de sistema, bodega principal.
insert into public.businesses (id, business_name, business_type, status)
values ('3c5c3b8e-28e6-45f0-8dc7-85e3efe8d30c', '007 BAR & SNACK, SRL', 'Tienda de Conveniencia', 'active');
insert into public.business_settings (business_id, kitchen_enabled)
values ('3c5c3b8e-28e6-45f0-8dc7-85e3efe8d30c', false);
insert into public.taxes (business_id, name, rate)
values ('3c5c3b8e-28e6-45f0-8dc7-85e3efe8d30c', 'ITBIS', 18);
insert into public.print_areas (business_id, name, code) values
  ('3c5c3b8e-28e6-45f0-8dc7-85e3efe8d30c', 'Caja', 'cashier'),
  ('3c5c3b8e-28e6-45f0-8dc7-85e3efe8d30c', 'Fiscal', 'fiscal'),
  ('3c5c3b8e-28e6-45f0-8dc7-85e3efe8d30c', 'Cierre de caja', 'cash_close');
insert into public.warehouses (business_id, name, is_main)
values ('3c5c3b8e-28e6-45f0-8dc7-85e3efe8d30c', 'Almacén Principal', true);
