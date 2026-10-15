-- Reversa de 20261013_0001_change_history.sql: quita los triggers, las
-- funciones y la tabla. OJO: borra el historial guardado hasta ahora.
-- order_item_removals queda intacta (el historial solo copiaba de ahí).

begin;

set local lock_timeout = '5s';

do $$
declare
  t text;
begin
  foreach t in array array[
    'menu_items', 'categories', 'menus', 'modifier_groups', 'modifiers',
    'menu_item_groups', 'menu_item_taxes', 'combo_groups', 'promotions',
    'coupons', 'taxes', 'recipes', 'recipe_ingredients', 'inventory_items',
    'warehouses', 'employees', 'employee_roles', 'roles', 'role_permissions',
    'user_permission_overrides', 'user_businesses', 'customers', 'suppliers',
    'zones', 'dining_tables', 'printers', 'print_areas', 'cash_registers',
    'cash_transaction_reasons', 'payment_methods', 'bank_accounts',
    'ncf_sequences', 'fiscal_settings', 'businesses', 'business_settings',
    'order_item_removals'
  ] loop
    if to_regclass('public.' || t) is not null then
      execute format('drop trigger if exists trg_zz_change_history on public.%I', t);
    end if;
  end loop;
end;
$$;

drop trigger if exists trg_zz_change_history_void on public.orders;
drop trigger if exists trg_zz_change_history_void on public.payments;

drop function if exists public.fn_change_history_record();
drop function if exists public.fn_change_history_on_removal();
drop function if exists public.fn_change_history_on_order_void();
drop function if exists public.fn_change_history_on_payment_void();
drop function if exists private.fn_change_history_upsert_removal(jsonb);
drop function if exists private.fn_change_history_merge(text, jsonb, text, jsonb);
drop function if exists private.fn_change_history_scope(text, jsonb);
drop function if exists private.fn_change_history_snapshot(text, jsonb, text);
drop function if exists private.fn_change_history_value(text, jsonb, text);
drop function if exists private.fn_change_history_keep(text, text, text);
drop function if exists private.fn_change_history_person(uuid, uuid, uuid);

drop table if exists public.change_history;
drop function if exists public.fn_change_history_business_ids();

commit;
