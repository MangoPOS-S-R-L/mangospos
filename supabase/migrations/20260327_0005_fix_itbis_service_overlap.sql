begin;

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
    select
      mi.business_id,
      coalesce(mi.tax_mode, 'exclusive') as tax_mode
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
    select
      coalesce(bs.default_tax_rate, 0)::numeric as default_tax_rate,
      coalesce(bs.service_fee_enabled, false) as service_fee_enabled,
      coalesce(bs.service_fee_rate, 0)::numeric as service_fee_rate
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
      when coalesce((select tax_rate from linked_tax), 0) > 0 then
        case
          when coalesce((select service_fee_enabled from business_default), false)
               and abs(
                 coalesce((select tax_rate from linked_tax), 0) -
                 (
                   coalesce((select default_tax_rate from business_default), 0) +
                   coalesce((select service_fee_rate from business_default), 0)
                 )
               ) <= 0.01
            then coalesce((select default_tax_rate from business_default), 0)
          else coalesce((select tax_rate from linked_tax), 0)
        end
      else coalesce((select default_tax_rate from business_default), 0)
    end as tax_rate;
$$;

update public.order_items oi
set tax_rate = bs.default_tax_rate
from public.orders o
join public.table_sessions ts
  on ts.id = o.session_id
join public.business_settings bs
  on bs.business_id = ts.business_id
where oi.order_id = o.id
  and coalesce(oi.tax_mode, 'exclusive') = 'inclusive'
  and not coalesce(oi.is_takeout, false)
  and coalesce(bs.service_fee_enabled, false)
  and abs(
    coalesce(oi.tax_rate, 0) -
    (coalesce(bs.default_tax_rate, 0) + coalesce(bs.service_fee_rate, 0))
  ) <= 0.01;

do $$
declare
  rec record;
begin
  for rec in
    select distinct oi.order_id
    from public.order_items oi
    where oi.order_id is not null
  loop
    perform public.calculate_order_totals(rec.order_id);
  end loop;

  for rec in
    select distinct oi.check_id
    from public.order_items oi
    where oi.check_id is not null
  loop
    perform public.calculate_check_totals(rec.check_id);
  end loop;
end;
$$;

commit;
