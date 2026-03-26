begin;

update public.order_items oi
set tax_rate = coalesce(oi.tax_rate, 0)
where oi.order_id is not null;

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
