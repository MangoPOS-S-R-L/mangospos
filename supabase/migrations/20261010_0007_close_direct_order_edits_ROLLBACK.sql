-- Reversa de 20261010_0007: las funciones de edición directa vuelven a quedar
-- abiertas para `authenticated` (como antes). anon no recupera el acceso.
begin;

do $$
declare
  r record;
begin
  for r in
    select p.oid::regprocedure::text as fn
      from pg_proc p
      join pg_namespace n on n.oid = p.pronamespace
     where n.nspname = 'public'
       and p.proname = any (array[
         'fn_update_item_qty', 'fn_update_item_notes', 'fn_update_item_details',
         'fn_update_item_discount', 'fn_update_item_discount_and_notes',
         'fn_delete_item', 'fn_move_item_to_check', 'fn_move_items_to_check_batch',
         'fn_toggle_item_takeout', 'fn_mark_order_takeout', 'fn_set_delivery_fee',
         'fn_set_order_excluded_taxes', 'fn_assign_customer_to_session',
         'fn_consolidate_keeper_atomic'
       ])
  loop
    execute format('grant execute on function %s to authenticated, service_role', r.fn);
  end loop;
end $$;

commit;
