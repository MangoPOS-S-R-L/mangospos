-- 2026-03-05
-- Ensure item totals are always computed from decimal qty (not integer quantity).

create or replace function public.fn_compute_item_totals()
returns trigger
language plpgsql
as $$
declare
  mods_total numeric(12,2) := 0;
  v_origin public.order_origin;
  v_default_tax numeric := 0;
  v_service_enabled boolean := false;
  v_service_rate numeric := 0;
  v_tax_rate numeric := 0;
  v_qty numeric(10,3);
begin
  select coalesce(sum(price * qty), 0)
    into mods_total
  from public.order_item_modifiers
  where item_id = coalesce(new.id, old.id);

  -- Decimal qty is source of truth for billing math.
  v_qty := round(greatest(coalesce(new.qty, new.quantity::numeric, 1), 0.001), 3);
  new.qty := v_qty;

  -- Keep compatibility with legacy integer quantity consumers.
  if new.quantity is null or new.quantity::numeric <= 0 then
    new.quantity := greatest(round(v_qty), 1);
  end if;

  select
    ts.origin,
    coalesce(bs.default_tax_rate, 0),
    coalesce(bs.service_fee_enabled, false),
    coalesce(bs.service_fee_rate, 0)
  into v_origin, v_default_tax, v_service_enabled, v_service_rate
  from public.orders o
  join public.table_sessions ts on ts.id = o.session_id
  left join public.business_settings bs on bs.business_id = ts.business_id
  where o.id = new.order_id
  limit 1;

  if v_origin = 'quick' then
    v_tax_rate := coalesce(v_service_rate, 0);
  else
    v_tax_rate :=
      coalesce(v_default_tax, 0) +
      (case when v_service_enabled then coalesce(v_service_rate, 0) else 0 end);
  end if;

  new.subtotal := round((new.unit_price * v_qty) + mods_total, 2);
  new.tax := round(new.subtotal * (v_tax_rate / 100.0), 2);
  new.total := new.subtotal - coalesce(new.discounts, 0) + coalesce(new.tax, 0);

  return new;
end;
$$;
