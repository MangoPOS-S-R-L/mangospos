-- 2026-03-05
-- RPC for full item edit from product detail modal (qty + discount/courtesy + notes).

create or replace function public.fn_update_item_details(
  p_item_id uuid,
  p_product_name text,
  p_qty numeric,
  p_is_takeout boolean,
  p_discounts numeric,
  p_notes text
)
returns void
language plpgsql
security definer
set search_path=public
as $$
declare
  v_order_id uuid;
  v_check_id uuid;
  v_qty numeric(10,3);
  v_discount numeric(12,2);
begin
  v_qty := round(greatest(coalesce(p_qty, 1), 0.001), 3);
  v_discount := round(greatest(coalesce(p_discounts, 0), 0), 2);

  update public.order_items
     set product_name = coalesce(nullif(trim(coalesce(p_product_name, '')), ''), product_name),
         qty = v_qty,
         quantity = greatest(round(v_qty), 1),
         is_takeout = coalesce(p_is_takeout, false),
         discounts = v_discount,
         notes = nullif(trim(coalesce(p_notes, '')), '')
   where id = p_item_id
   returning order_id, check_id into v_order_id, v_check_id;

  if v_order_id is null then
    raise exception 'ITEM_NOT_FOUND';
  end if;

  perform public.calculate_order_totals(v_order_id);
  if v_check_id is not null then
    perform public.calculate_check_totals(v_check_id);
  end if;
end;
$$;

grant execute on function public.fn_update_item_details(uuid, text, numeric, boolean, numeric, text) to authenticated;
