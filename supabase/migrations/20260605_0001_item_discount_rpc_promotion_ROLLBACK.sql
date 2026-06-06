-- =============================================================================
-- ROLLBACK de 20260605_0001 — restaura fn_update_item_discount_and_notes (3 args)
-- =============================================================================
-- Vuelve a la firma de 3 argumentos (sin escribir promotion_id). NO borra la
-- columna order_items.promotion_id (eso pertenece al ROLLBACK de 20260604_0001).
-- =============================================================================

begin;

drop function if exists public.fn_update_item_discount_and_notes(uuid, numeric, text, uuid);

create or replace function public.fn_update_item_discount_and_notes(
  p_item_id uuid,
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
  v_discount numeric(12,2);
begin
  v_discount := round(greatest(coalesce(p_discounts, 0), 0), 2);

  update public.order_items
     set discounts = v_discount,
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

grant execute on function
  public.fn_update_item_discount_and_notes(uuid, numeric, text) to authenticated;

commit;
