-- =============================================================================
-- ROLLBACK de 20260805_0001_accounting_core.sql
--
-- Borra el módulo contable completo. No toca ninguna tabla del POS: lo único
-- que revierte fuera de `accounting_*` es la columna que se le agregó a
-- `cash_transaction_reasons` y los permisos sembrados.
--
-- OJO: esto elimina los asientos. Si ya se cerró un mes con esta
-- contabilidad, exportá el libro diario antes de correrlo.
-- =============================================================================

begin;

drop trigger if exists trg_accounting_guard_line on public.accounting_entry_lines;
drop trigger if exists trg_accounting_guard_entry on public.accounting_entries;

drop function if exists public.fn_accounting_balance_sheet(uuid, date);
drop function if exists public.fn_accounting_income_statement(uuid, date, date);
drop function if exists public.fn_accounting_trial_balance(uuid, date, date, uuid);
drop function if exists public.fn_accounting_ledger(uuid, uuid, date, date);
drop function if exists public.fn_accounting_journal(uuid, date, date);
drop function if exists public.fn_accounting_generate_all(uuid, date, date);
drop function if exists public.fn_accounting_generate_credits(uuid, date, date);
drop function if exists public.fn_accounting_generate_cash(uuid, date, date);
drop function if exists public.fn_accounting_generate_purchases(uuid, date, date);
drop function if exists public.fn_accounting_generate_sales(uuid, date, date);
drop function if exists public.fn_accounting_account_for(uuid, text);
drop function if exists public.fn_accounting_reverse_entry(uuid, date, text);
drop function if exists public.fn_accounting_post_entry(uuid, date, text, jsonb, text, text, uuid, text);
drop function if exists public.fn_accounting_set_period_status(uuid, integer, integer, text, text);
drop function if exists public.fn_accounting_ensure_period(uuid, date);
drop function if exists public.fn_accounting_seed_chart(uuid);
drop function if exists public.fn_accounting_guard_line();
drop function if exists public.fn_accounting_guard_entry();

do $$
begin
  if to_regclass('public.cash_transaction_reasons') is not null then
    alter table public.cash_transaction_reasons
      drop column if exists accounting_account_id;
  end if;
end;
$$;

drop table if exists public.accounting_entry_lines;
drop table if exists public.accounting_entries;
drop table if exists public.accounting_account_mappings;
drop table if exists public.accounting_periods;
drop table if exists public.accounting_cost_centers;
drop table if exists public.accounting_settings;
drop table if exists public.accounting_accounts;

drop function if exists public.fn_accounting_can(uuid, text);

do $$
begin
  if to_regclass('public.permissions') is not null then
    delete from public.permissions where code like 'contabilidad.%';
  end if;
exception when others then
  raise notice 'Limpieza de permisos contables omitida: %', sqlerrm;
end;
$$;

commit;
