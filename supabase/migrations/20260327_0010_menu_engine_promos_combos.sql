-- MangosPOS menu engine upgrade
-- Adds richer modifiers, combo support, and product/day-targeted promotions.
-- Safe to run on existing installations.

begin;

create extension if not exists pgcrypto;

-- 1) Menu items: distinguish standard products vs combos.
alter table public.menu_items
  add column if not exists item_type text not null default 'standard';

alter table public.menu_items
  drop constraint if exists menu_items_item_type_check;

alter table public.menu_items
  add constraint menu_items_item_type_check
  check (item_type in ('standard', 'combo', 'extra_only'));

create index if not exists idx_menu_items_business_item_type
  on public.menu_items (business_id, item_type);

-- 2) Modifier groups: richer behavior for UI / ordering.
alter table public.modifier_groups
  add column if not exists display_type text not null default 'multiple',
  add column if not exists selection_mode text not null default 'modifier',
  add column if not exists is_required boolean not null default false,
  add column if not exists free_qty integer not null default 0,
  add column if not exists max_qty_per_option integer not null default 1,
  add column if not exists sort_order integer not null default 0;

alter table public.modifier_groups
  drop constraint if exists modifier_groups_display_type_check;

alter table public.modifier_groups
  add constraint modifier_groups_display_type_check
  check (display_type in ('single', 'multiple', 'toggle'));

alter table public.modifier_groups
  drop constraint if exists modifier_groups_selection_mode_check;

alter table public.modifier_groups
  add constraint modifier_groups_selection_mode_check
  check (selection_mode in ('modifier', 'extra', 'removal'));

alter table public.modifier_groups
  drop constraint if exists modifier_groups_free_qty_check;

alter table public.modifier_groups
  add constraint modifier_groups_free_qty_check
  check (free_qty >= 0);

alter table public.modifier_groups
  drop constraint if exists modifier_groups_max_qty_per_option_check;

alter table public.modifier_groups
  add constraint modifier_groups_max_qty_per_option_check
  check (max_qty_per_option >= 1);

alter table public.modifier_groups
  drop constraint if exists modifier_groups_sort_order_check;

alter table public.modifier_groups
  add constraint modifier_groups_sort_order_check
  check (sort_order >= 0);

create index if not exists idx_modifier_groups_business_sort
  on public.modifier_groups (business_id, sort_order, created_at desc);

-- 3) Modifiers: sorting/defaults/SKU metadata.
alter table public.modifiers
  add column if not exists sku text,
  add column if not exists default_selected boolean not null default false,
  add column if not exists sort_order integer not null default 0,
  add column if not exists metadata jsonb not null default '{}'::jsonb;

alter table public.modifiers
  drop constraint if exists modifiers_sort_order_check;

alter table public.modifiers
  add constraint modifiers_sort_order_check
  check (sort_order >= 0);

create index if not exists idx_modifiers_group_sort
  on public.modifiers (group_id, sort_order, created_at desc);

-- 4) Combos: each combo product can define groups and selectable products.
create table if not exists public.combo_groups (
  id uuid primary key default gen_random_uuid(),
  business_id uuid not null,
  menu_item_id uuid not null,
  name text not null,
  min_select integer not null default 1,
  max_select integer not null default 1,
  is_required boolean not null default true,
  sort_order integer not null default 0,
  created_at timestamp with time zone not null default now(),
  constraint combo_groups_business_id_fkey
    foreign key (business_id) references public.businesses(id) on delete cascade,
  constraint combo_groups_menu_item_id_fkey
    foreign key (menu_item_id) references public.menu_items(id) on delete cascade,
  constraint combo_groups_min_select_check check (min_select >= 0),
  constraint combo_groups_max_select_check check (max_select >= min_select),
  constraint combo_groups_sort_order_check check (sort_order >= 0)
);

create index if not exists idx_combo_groups_menu_item
  on public.combo_groups (menu_item_id, sort_order, created_at);

create table if not exists public.combo_group_items (
  id uuid primary key default gen_random_uuid(),
  combo_group_id uuid not null,
  menu_item_id uuid not null,
  price_delta numeric(12,2) not null default 0,
  is_default boolean not null default false,
  sort_order integer not null default 0,
  created_at timestamp with time zone not null default now(),
  constraint combo_group_items_combo_group_id_fkey
    foreign key (combo_group_id) references public.combo_groups(id) on delete cascade,
  constraint combo_group_items_menu_item_id_fkey
    foreign key (menu_item_id) references public.menu_items(id) on delete restrict,
  constraint combo_group_items_sort_order_check check (sort_order >= 0),
  constraint combo_group_items_unique unique (combo_group_id, menu_item_id)
);

create index if not exists idx_combo_group_items_group_sort
  on public.combo_group_items (combo_group_id, sort_order, created_at);

-- 5) Promotions: day-based targeting, auto-apply behavior and BOGO math.
alter table public.promotions
  add column if not exists promo_type text,
  add column if not exists auto_apply boolean not null default true,
  add column if not exists priority integer not null default 0,
  add column if not exists stackable boolean not null default false,
  add column if not exists buy_quantity integer,
  add column if not exists pay_quantity integer,
  add column if not exists reward_quantity integer,
  add column if not exists target_scope text,
  add column if not exists metadata jsonb not null default '{}'::jsonb;

update public.promotions
set promo_type = coalesce(nullif(discount_type, ''), 'percentage')
where promo_type is null;

update public.promotions
set target_scope = coalesce(nullif(applies_to, ''), 'all')
where target_scope is null;

alter table public.promotions
  alter column promo_type set default 'percentage',
  alter column promo_type set not null,
  alter column target_scope set default 'all',
  alter column target_scope set not null;

alter table public.promotions
  drop constraint if exists promotions_promo_type_check;

alter table public.promotions
  add constraint promotions_promo_type_check
  check (promo_type in ('percentage', 'fixed', 'bogo', 'bundle_price'));

alter table public.promotions
  drop constraint if exists promotions_target_scope_check;

alter table public.promotions
  add constraint promotions_target_scope_check
  check (target_scope in ('all', 'category', 'product'));

alter table public.promotions
  drop constraint if exists promotions_priority_check;

alter table public.promotions
  add constraint promotions_priority_check
  check (priority >= 0);

alter table public.promotions
  drop constraint if exists promotions_buy_quantity_check;

alter table public.promotions
  add constraint promotions_buy_quantity_check
  check (buy_quantity is null or buy_quantity >= 1);

alter table public.promotions
  drop constraint if exists promotions_pay_quantity_check;

alter table public.promotions
  add constraint promotions_pay_quantity_check
  check (pay_quantity is null or pay_quantity >= 1);

alter table public.promotions
  drop constraint if exists promotions_reward_quantity_check;

alter table public.promotions
  add constraint promotions_reward_quantity_check
  check (reward_quantity is null or reward_quantity >= 1);

alter table public.promotions
  drop constraint if exists promotions_days_of_week_values_check;

alter table public.promotions
  add constraint promotions_days_of_week_values_check
  check (
    days_of_week is null
    or days_of_week <@ array[0,1,2,3,4,5,6]::integer[]
  );

create index if not exists idx_promotions_business_active_window
  on public.promotions (business_id, is_active, start_date, end_date);

create index if not exists idx_promotions_target_scope
  on public.promotions (business_id, target_scope);

create index if not exists idx_promotions_target_ids_gin
  on public.promotions using gin (target_ids);

create index if not exists idx_promotions_days_of_week_gin
  on public.promotions using gin (days_of_week);

commit;
