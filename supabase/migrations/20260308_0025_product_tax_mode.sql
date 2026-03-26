-- 20260308_0025_product_tax_mode.sql
-- Agrega modo de impuesto por producto e integra el calculo real en ventas.

alter table if exists public.menu_items
  add column if not exists tax_mode text;

update public.menu_items
set tax_mode = coalesce(tax_mode, 'exclusive');

alter table if exists public.menu_items
  alter column tax_mode set default 'exclusive',
  alter column tax_mode set not null;

do $$
begin
  if not exists (
    select 1
    from pg_constraint
    where conname = 'menu_items_tax_mode_check'
  ) then
    alter table public.menu_items
      add constraint menu_items_tax_mode_check
      check (tax_mode in ('exclusive', 'inclusive'));
  end if;
end $$;

alter table if exists public.order_items
  add column if not exists tax_mode text;

alter table if exists public.order_items
  add column if not exists tax_rate numeric;

update public.order_items
set tax_mode = coalesce(tax_mode, 'exclusive'),
    tax_rate = coalesce(tax_rate, 0);

alter table if exists public.order_items
  alter column tax_mode set default 'exclusive',
  alter column tax_mode set not null,
  alter column tax_rate set default 0,
  alter column tax_rate set not null;

do $$
begin
  if not exists (
    select 1
    from pg_constraint
    where conname = 'order_items_tax_mode_check'
  ) then
    alter table public.order_items
      add constraint order_items_tax_mode_check
      check (tax_mode in ('exclusive', 'inclusive'));
  end if;
end $$;

create or replace function public.fn_resolve_order_item_tax_profile(
  p_product_id uuid,
  p_order_id uuid
) returns table (
  tax_mode text,
  tax_rate numeric
)
language sql
stable
as $$
  with item as (
    select coalesce(mi.tax_mode, 'exclusive') as tax_mode
    from public.menu_items mi
    where mi.id = p_product_id
  ),
  linked_tax as (
    select coalesce(sum(t.rate), 0)::numeric as tax_rate
    from public.menu_item_taxes mit
    join public.taxes t
      on t.id = mit.tax_id
    where mit.item_id = p_product_id
      and coalesce(t.is_active, true)
  ),
  business_default as (
    select coalesce(bs.default_tax_rate, 0)::numeric as tax_rate
    from public.orders o
    join public.table_sessions ts
      on ts.id = o.session_id
    left join public.business_settings bs
      on bs.business_id = ts.business_id
    where o.id = p_order_id
    limit 1
  )
  select
    coalesce((select tax_mode from item), 'exclusive') as tax_mode,
    case
      when coalesce((select tax_rate from linked_tax), 0) > 0
        then coalesce((select tax_rate from linked_tax), 0)
      else coalesce((select tax_rate from business_default), 0)
    end as tax_rate;
$$;

update public.order_items oi
set tax_mode = (
      select profile.tax_mode
      from public.fn_resolve_order_item_tax_profile(
        oi.product_id,
        oi.order_id
      ) as profile
    ),
    tax_rate = (
      select profile.tax_rate
      from public.fn_resolve_order_item_tax_profile(
        oi.product_id,
        oi.order_id
      ) as profile
    )
where coalesce(oi.tax_rate, 0) = 0
   or oi.tax_mode not in ('exclusive', 'inclusive');

create or replace function public.fn_add_item_from_menu(
  p_order_id uuid,
  p_menu_item_id uuid,
  p_qty numeric default 1,
  p_check_position integer default 1,
  p_is_takeout boolean default false,
  p_notes text default null
) returns uuid
language plpgsql
security definer
set search_path to 'public'
as $$
declare
  v_name text;
  v_price numeric(12,2);
  v_tax_mode text;
  v_tax_rate numeric := 0;
  v_check uuid;
  v_item_id uuid;
  v_qty numeric(10,3);
begin
  v_qty := greatest(coalesce(p_qty, 1), 1);

  select name, price
    into v_name, v_price
  from public.menu_items
  where id = p_menu_item_id
  limit 1;

  if v_name is null then
    raise exception 'MENU_ITEM_NOT_FOUND';
  end if;

  select profile.tax_mode, profile.tax_rate
    into v_tax_mode, v_tax_rate
  from public.fn_resolve_order_item_tax_profile(p_menu_item_id, p_order_id) profile;

  v_check := public.fn_get_or_create_check(p_order_id, p_check_position);

  insert into public.order_items(
    order_id,
    check_id,
    product_id,
    product_name,
    qty,
    quantity,
    unit_price,
    tax_mode,
    tax_rate,
    is_takeout,
    notes,
    status
  ) values (
    p_order_id,
    v_check,
    p_menu_item_id,
    v_name,
    v_qty,
    greatest(round(v_qty), 1)::int,
    v_price,
    coalesce(v_tax_mode, 'exclusive'),
    coalesce(v_tax_rate, 0),
    coalesce(p_is_takeout, false),
    p_notes,
    'draft'
  )
  returning id into v_item_id;

  perform public.fn_recalc_order_totals(p_order_id);
  return v_item_id;
end;
$$;

create or replace function public.fn_compute_item_totals()
returns trigger
language plpgsql
as $$
declare
  mods_total numeric(12,2) := 0;
  v_line_amount numeric(12,2) := 0;
  v_tax_rate numeric := greatest(coalesce(new.tax_rate, 0), 0);
  v_tax_mode text := coalesce(new.tax_mode, 'exclusive');
  v_net_subtotal numeric(12,2) := 0;
begin
  select coalesce(sum(price * qty), 0)
    into mods_total
  from public.order_item_modifiers
  where item_id = coalesce(new.id, old.id);

  v_line_amount := round(
    (coalesce(new.unit_price, 0) * coalesce(new.qty, new.quantity, 1)) +
    mods_total,
    2
  );

  if v_tax_mode = 'inclusive' and v_tax_rate > 0 then
    v_net_subtotal := round(v_line_amount / (1 + (v_tax_rate / 100.0)), 2);
    new.subtotal := v_net_subtotal;
    new.tax := round(v_line_amount - v_net_subtotal, 2);
    new.total := round(v_line_amount - coalesce(new.discounts, 0), 2);
  else
    new.subtotal := v_line_amount;
    new.tax := round(new.subtotal * (v_tax_rate / 100.0), 2);
    new.total := round(
      new.subtotal - coalesce(new.discounts, 0) + coalesce(new.tax, 0),
      2
    );
  end if;

  return new;
end;
$$;

create or replace view public.v_menu_items_list
with (security_invoker = 'on') as
select
  i.id,
  i.business_id,
  i.name,
  i.description,
  i.category_id,
  c.name as category_name,
  i.price,
  i.sku,
  i.prep_minutes,
  i.has_variants,
  i.is_active,
  i.image_url,
  i.created_at,
  l.menu_id,
  m.name as menu_name,
  l.position,
  i.tax_mode,
  coalesce((
    select sum(t.rate)
    from public.menu_item_taxes mit
    join public.taxes t
      on t.id = mit.tax_id
    where mit.item_id = i.id
      and coalesce(t.is_active, true)
  ), 0)::numeric as effective_tax_rate
from public.menu_items i
left join lateral (
  select l1.menu_id, l1.position
  from public.menu_item_links l1
  where l1.item_id = i.id
  order by l1.position
  limit 1
) l on true
left join public.menus m
  on m.id = l.menu_id
left join public.categories c
  on c.id = i.category_id;
