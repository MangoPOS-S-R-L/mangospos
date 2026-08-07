/// Nombres de tablas, selects y RPCs del módulo contable.
/// Misma convención que `credits_queries.dart` / `purchases_queries.dart`:
/// nada de strings sueltos en el repositorio.
class AccountingQueries {
  // ── Tablas ────────────────────────────────────────────────────────────────
  static const tableAccounts = 'accounting_accounts';
  static const tableCostCenters = 'accounting_cost_centers';
  static const tablePeriods = 'accounting_periods';
  static const tableEntries = 'accounting_entries';
  static const tableEntryLines = 'accounting_entry_lines';
  static const tableMappings = 'accounting_account_mappings';
  static const tableSettings = 'accounting_settings';

  // ── Selects ───────────────────────────────────────────────────────────────
  static const selectAccounts =
      'id, business_id, code, name, account_type, parent_id, is_postable, '
      'is_active, description';

  static const selectCostCenters =
      'id, business_id, code, name, kind, is_active';

  static const selectPeriods =
      'id, business_id, year, month, status, closed_at, reopened_at, notes';

  static const selectEntries =
      'id, entry_number, entry_date, description, reference, source_type, '
      'source_id, source_table, status, total_debit, total_credit, '
      'reverses_entry_id, reversed_by_entry_id, created_at';

  static const selectEntryLines =
      'id, line_no, account_id, cost_center_id, debit, credit, description, '
      'accounting_accounts(code, name), accounting_cost_centers(code, name)';

  static const selectMappings =
      'id, event_key, account_id, accounting_accounts(code, name)';

  // ── RPCs ──────────────────────────────────────────────────────────────────
  static const rpcSeedChart = 'fn_accounting_seed_chart';
  static const rpcPostEntry = 'fn_accounting_post_entry';
  static const rpcReverseEntry = 'fn_accounting_reverse_entry';
  static const rpcSetPeriodStatus = 'fn_accounting_set_period_status';
  static const rpcGenerateAll = 'fn_accounting_generate_all';
  static const rpcJournal = 'fn_accounting_journal';
  static const rpcLedger = 'fn_accounting_ledger';
  static const rpcTrialBalance = 'fn_accounting_trial_balance';
  static const rpcIncomeStatement = 'fn_accounting_income_statement';
  static const rpcBalanceSheet = 'fn_accounting_balance_sheet';
}
