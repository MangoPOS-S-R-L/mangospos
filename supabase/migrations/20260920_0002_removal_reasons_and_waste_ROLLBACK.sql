-- ROLLBACK de 20260920_0002 — quita el catálogo de motivos y la merma.
-- OJO: los movimientos `waste` ya escritos NO se borran (son inventario real);
-- si hay que deshacerlos, es con un ajuste, no aquí.

begin;

drop function if exists public.fn_note_order_item_removal(uuid, text, uuid, text, boolean);
drop function if exists public.fn_book_removal_waste(uuid);

-- Se restaura la firma de 3 argumentos de 20260919_0002.
create or replace function public.fn_note_order_item_removal(
  p_item_id     uuid,
  p_reason      text default null,
  p_employee_id uuid default null
)
returns boolean
language plpgsql
security definer
set search_path = public
as $$
declare
  v_id       uuid;
  v_business uuid;
begin
  select r.id, r.business_id
    into v_id, v_business
  from public.order_item_removals r
  where r.item_id = p_item_id
    and r.business_id in (select public.current_user_business_ids())
    and r.removed_at > now() - interval '3 days'
  order by r.removed_at desc
  limit 1;

  if v_id is null then
    return false;
  end if;

  update public.order_item_removals r
     set reason = coalesce(
           r.reason,
           nullif(left(trim(coalesce(p_reason, '')), 500), '')
         ),
         reason_employee_id = coalesce(
           r.reason_employee_id,
           (select e.id from public.employees e
             where e.id = p_employee_id and e.business_id = v_business)
         )
   where r.id = v_id;
  return true;
end;
$$;

grant execute on function public.fn_note_order_item_removal(uuid, text, uuid)
  to authenticated;

alter table public.order_item_removals drop column if exists reason_code;
alter table public.order_item_removals drop column if exists is_waste;
alter table public.order_item_removals drop column if exists waste_booked;

drop table if exists public.order_item_removal_reasons;

notify pgrst, 'reload schema';

commit;
