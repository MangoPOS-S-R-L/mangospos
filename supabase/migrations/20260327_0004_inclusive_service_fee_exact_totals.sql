begin;

create or replace function public.fn_compute_item_totals()
returns trigger
language plpgsql
as $$
declare
  mods_total numeric(12,2) := 0;
  v_line_amount numeric(12,2) := 0;
  v_tax_rate numeric := greatest(coalesce(new.tax_rate, 0), 0);
  v_tax_mode text := coalesce(new.tax_mode, 'exclusive');
  v_order_id uuid := coalesce(new.order_id, old.order_id);
  v_service_enabled boolean := false;
  v_service_rate numeric := 0;
  v_net_subtotal numeric(12,2) := 0;
  v_service_amount numeric(12,2) := 0;
begin
  select coalesce(sum(price * qty), 0)
    into mods_total
  from public.order_item_modifiers
  where item_id = coalesce(new.id, old.id);

  select
    coalesce(bs.service_fee_enabled, false),
    coalesce(bs.service_fee_rate, 10)
    into v_service_enabled, v_service_rate
  from public.orders o
  join public.table_sessions ts
    on ts.id = o.session_id
  left join public.business_settings bs
    on bs.business_id = ts.business_id
  where o.id = v_order_id
  limit 1;

  if coalesce(new.is_takeout, false) then
    v_service_enabled := false;
    v_service_rate := 0;
  end if;

  v_line_amount := round(
    (coalesce(new.unit_price, 0) * coalesce(new.qty, new.quantity, 1)) +
    mods_total,
    2
  );

  if v_tax_mode = 'inclusive' and v_tax_rate > 0 then
    if v_service_enabled and v_service_rate > 0 then
      v_net_subtotal := round(
        v_line_amount / (1 + (v_tax_rate / 100.0) + (v_service_rate / 100.0)),
        2
      );
      v_service_amount := round(v_net_subtotal * (v_service_rate / 100.0), 2);
      new.subtotal := v_net_subtotal;
      new.tax := round(v_line_amount - v_net_subtotal - v_service_amount, 2);
    else
      v_net_subtotal := round(v_line_amount / (1 + (v_tax_rate / 100.0)), 2);
      new.subtotal := v_net_subtotal;
      new.tax := round(v_line_amount - v_net_subtotal, 2);
    end if;

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

create or replace function public.calculate_order_totals(_order_id uuid)
returns void
language plpgsql
as $$
declare
  _subtotal numeric := 0;
  _tax numeric := 0;
  _discounts numeric := 0;
  _service_fee numeric := 0;
  _extra_service_fee numeric := 0;
  _items_total numeric := 0;
  _total numeric := 0;
  _sf_enabled boolean := false;
  _sf_rate numeric := 0;
begin
  select
    coalesce(bs.service_fee_enabled, false),
    coalesce(bs.service_fee_rate, 10)
    into _sf_enabled, _sf_rate
  from public.orders o
  join public.table_sessions ts on ts.id = o.session_id
  left join public.business_settings bs on bs.business_id = ts.business_id
  where o.id = _order_id
  limit 1;

  select
    coalesce(sum(oi.subtotal), 0),
    coalesce(sum(oi.tax), 0),
    coalesce(sum(oi.discounts), 0),
    coalesce(sum(oi.total), 0),
    coalesce(sum(
      case
        when _sf_enabled and not coalesce(oi.is_takeout, false)
          then round(oi.subtotal * (_sf_rate / 100.0), 2)
        else 0
      end
    ), 0),
    coalesce(sum(
      case
        when _sf_enabled
          and not coalesce(oi.is_takeout, false)
          and coalesce(oi.tax_mode, 'exclusive') <> 'inclusive'
          then round(oi.subtotal * (_sf_rate / 100.0), 2)
        else 0
      end
    ), 0)
  into
    _subtotal,
    _tax,
    _discounts,
    _items_total,
    _service_fee,
    _extra_service_fee
  from public.order_items oi
  where oi.order_id = _order_id
    and oi.status <> 'void';

  _total := _items_total + _extra_service_fee;

  update public.orders
  set
    subtotal = round(_subtotal, 2),
    tax = round(_tax, 2),
    discounts = round(_discounts, 2),
    service_fee = round(_service_fee, 2),
    total = round(_total, 2)
  where id = _order_id;
end;
$$;

create or replace function public.calculate_check_totals(_check_id uuid)
returns void
language plpgsql
as $$
declare
  _subtotal numeric := 0;
  _tax numeric := 0;
  _discounts numeric := 0;
  _service_fee numeric := 0;
  _extra_service_fee numeric := 0;
  _items_total numeric := 0;
  _total numeric := 0;
  _sf_enabled boolean := false;
  _sf_rate numeric := 0;
begin
  select
    coalesce(bs.service_fee_enabled, false),
    coalesce(bs.service_fee_rate, 10)
    into _sf_enabled, _sf_rate
  from public.order_checks ch
  join public.orders o on ch.order_id = o.id
  join public.table_sessions ts on o.session_id = ts.id
  left join public.business_settings bs on bs.business_id = ts.business_id
  where ch.id = _check_id
  limit 1;

  select
    coalesce(sum(oi.subtotal), 0),
    coalesce(sum(oi.tax), 0),
    coalesce(sum(oi.discounts), 0),
    coalesce(sum(oi.total), 0),
    coalesce(sum(
      case
        when _sf_enabled and not coalesce(oi.is_takeout, false)
          then round(oi.subtotal * (_sf_rate / 100.0), 2)
        else 0
      end
    ), 0),
    coalesce(sum(
      case
        when _sf_enabled
          and not coalesce(oi.is_takeout, false)
          and coalesce(oi.tax_mode, 'exclusive') <> 'inclusive'
          then round(oi.subtotal * (_sf_rate / 100.0), 2)
        else 0
      end
    ), 0)
  into
    _subtotal,
    _tax,
    _discounts,
    _items_total,
    _service_fee,
    _extra_service_fee
  from public.order_items oi
  where oi.check_id = _check_id
    and oi.status <> 'void';

  _total := _items_total + _extra_service_fee;

  update public.order_checks
  set
    subtotal = round(_subtotal, 2),
    tax = round(_tax, 2),
    discounts = round(_discounts, 2),
    service_fee = round(_service_fee, 2),
    total = round(_total, 2)
  where id = _check_id;
end;
$$;

commit;
