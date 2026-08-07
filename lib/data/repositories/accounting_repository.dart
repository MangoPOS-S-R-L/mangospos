import 'package:supabase_flutter/supabase_flutter.dart';

import '../datasources/queries/accounting_queries.dart';
import '../models/accounting_models.dart';

/// Acceso al módulo contable.
///
/// Todo lo que crea o modifica asientos pasa por RPC `security definer`: la
/// validación de partida doble, el período abierto y la numeración correlativa
/// viven en la base, no acá. El repositorio solo lee catálogos y dispara las
/// RPC.
class AccountingRepository {
  final SupabaseClient _client;

  AccountingRepository(this._client);

  // ── Catálogo de cuentas ───────────────────────────────────────────────────

  Future<List<AccountingAccount>> getAccounts(
    String businessId, {
    bool onlyActive = false,
    bool onlyPostable = false,
  }) async {
    var query = _client
        .from(AccountingQueries.tableAccounts)
        .select(AccountingQueries.selectAccounts)
        .eq('business_id', businessId);
    if (onlyActive) query = query.eq('is_active', true);
    if (onlyPostable) query = query.eq('is_postable', true);
    final rows = await query.order('code');
    return List<Map<String, dynamic>>.from(rows)
        .map(AccountingAccount.fromMap)
        .toList();
  }

  Future<void> upsertAccount({
    required String businessId,
    String? id,
    required String code,
    required String name,
    required String accountType,
    String? parentId,
    bool isPostable = true,
    bool isActive = true,
    String? description,
  }) async {
    final payload = <String, dynamic>{
      'business_id': businessId,
      'code': code.trim(),
      'name': name.trim(),
      'account_type': accountType,
      'parent_id': parentId,
      'is_postable': isPostable,
      'is_active': isActive,
      'description': description?.trim(),
    };
    if (id == null) {
      await _client.from(AccountingQueries.tableAccounts).insert(payload);
    } else {
      await _client
          .from(AccountingQueries.tableAccounts)
          .update(payload)
          .eq('id', id);
    }
  }

  /// Las cuentas no se borran (romperían asientos históricos): se desactivan.
  Future<void> setAccountActive(String accountId, bool isActive) async {
    await _client
        .from(AccountingQueries.tableAccounts)
        .update({'is_active': isActive}).eq('id', accountId);
  }

  /// Siembra catálogo estándar RD + mapeos evento→cuenta. Idempotente.
  Future<Map<String, dynamic>> seedChart(String businessId) async {
    final res = await _client.rpc(
      AccountingQueries.rpcSeedChart,
      params: {'p_business_id': businessId},
    );
    return Map<String, dynamic>.from(res as Map);
  }

  Future<bool> isInitialized(String businessId) async {
    final row = await _client
        .from(AccountingQueries.tableSettings)
        .select('business_id, initialized_at')
        .eq('business_id', businessId)
        .maybeSingle();
    return row != null && row['initialized_at'] != null;
  }

  // ── Centros de costo ──────────────────────────────────────────────────────

  Future<List<AccountingCostCenter>> getCostCenters(String businessId) async {
    final rows = await _client
        .from(AccountingQueries.tableCostCenters)
        .select(AccountingQueries.selectCostCenters)
        .eq('business_id', businessId)
        .order('code');
    return List<Map<String, dynamic>>.from(rows)
        .map(AccountingCostCenter.fromMap)
        .toList();
  }

  Future<void> upsertCostCenter({
    required String businessId,
    String? id,
    required String code,
    required String name,
    required String kind,
    bool isActive = true,
  }) async {
    final payload = <String, dynamic>{
      'business_id': businessId,
      'code': code.trim(),
      'name': name.trim(),
      'kind': kind,
      'is_active': isActive,
    };
    if (id == null) {
      await _client.from(AccountingQueries.tableCostCenters).insert(payload);
    } else {
      await _client
          .from(AccountingQueries.tableCostCenters)
          .update(payload)
          .eq('id', id);
    }
  }

  // ── Períodos ──────────────────────────────────────────────────────────────

  Future<List<AccountingPeriod>> getPeriods(String businessId) async {
    final rows = await _client
        .from(AccountingQueries.tablePeriods)
        .select(AccountingQueries.selectPeriods)
        .eq('business_id', businessId)
        .order('year', ascending: false)
        .order('month', ascending: false);
    return List<Map<String, dynamic>>.from(rows)
        .map(AccountingPeriod.fromMap)
        .toList();
  }

  Future<void> setPeriodStatus({
    required String businessId,
    required int year,
    required int month,
    required String status,
    String? notes,
  }) async {
    await _client.rpc(
      AccountingQueries.rpcSetPeriodStatus,
      params: {
        'p_business_id': businessId,
        'p_year': year,
        'p_month': month,
        'p_status': status,
        'p_notes': notes,
      },
    );
  }

  // ── Asientos ──────────────────────────────────────────────────────────────

  Future<List<AccountingEntry>> getEntries(
    String businessId, {
    required DateTime from,
    required DateTime to,
    String? sourceType,
  }) async {
    var query = _client
        .from(AccountingQueries.tableEntries)
        .select(AccountingQueries.selectEntries)
        .eq('business_id', businessId)
        .gte('entry_date', _d(from))
        .lte('entry_date', _d(to));
    if (sourceType != null) query = query.eq('source_type', sourceType);
    final rows = await query.order('entry_number', ascending: false);
    return List<Map<String, dynamic>>.from(rows)
        .map(AccountingEntry.fromMap)
        .toList();
  }

  Future<List<Map<String, dynamic>>> getEntryLines(String entryId) async {
    final rows = await _client
        .from(AccountingQueries.tableEntryLines)
        .select(AccountingQueries.selectEntryLines)
        .eq('entry_id', entryId)
        .order('line_no');
    return List<Map<String, dynamic>>.from(rows);
  }

  /// Postea un asiento manual. La BD rechaza descuadres (`UNBALANCED_ENTRY`)
  /// y meses cerrados (`PERIOD_CLOSED`).
  Future<String> postEntry({
    required String businessId,
    required DateTime date,
    required String description,
    required List<JournalLineDraft> lines,
    String? reference,
  }) async {
    final payload = lines
        .where((l) => !l.isEmpty)
        .map((l) => l.toJson())
        .toList(growable: false);
    final res = await _client.rpc(
      AccountingQueries.rpcPostEntry,
      params: {
        'p_business_id': businessId,
        'p_entry_date': _d(date),
        'p_description': description.trim(),
        'p_lines': payload,
        'p_reference': reference?.trim(),
        'p_source_type': 'manual',
      },
    );
    return res as String;
  }

  Future<String> reverseEntry({
    required String entryId,
    DateTime? date,
    String? reason,
  }) async {
    final res = await _client.rpc(
      AccountingQueries.rpcReverseEntry,
      params: {
        'p_entry_id': entryId,
        'p_date': date == null ? null : _d(date),
        'p_reason': reason?.trim(),
      },
    );
    return res as String;
  }

  /// Genera los asientos automáticos del rango desde ventas, compras, caja y
  /// créditos. Idempotente: re-correrlo sobre el mismo rango no duplica.
  Future<Map<String, dynamic>> generateAutomatic({
    required String businessId,
    required DateTime from,
    required DateTime to,
  }) async {
    final res = await _client.rpc(
      AccountingQueries.rpcGenerateAll,
      params: {
        'p_business_id': businessId,
        'p_from': _d(from),
        'p_to': _d(to),
      },
    );
    return Map<String, dynamic>.from(res as Map);
  }

  // ── Mapeos evento → cuenta ────────────────────────────────────────────────

  Future<List<Map<String, dynamic>>> getMappings(String businessId) async {
    final rows = await _client
        .from(AccountingQueries.tableMappings)
        .select(AccountingQueries.selectMappings)
        .eq('business_id', businessId)
        .order('event_key');
    return List<Map<String, dynamic>>.from(rows);
  }

  Future<void> setMapping({
    required String businessId,
    required String eventKey,
    required String accountId,
  }) async {
    await _client.from(AccountingQueries.tableMappings).upsert({
      'business_id': businessId,
      'event_key': eventKey,
      'account_id': accountId,
      'updated_at': DateTime.now().toIso8601String(),
    }, onConflict: 'business_id,event_key');
  }

  // ── Reportes ──────────────────────────────────────────────────────────────

  Future<List<Map<String, dynamic>>> journal({
    required String businessId,
    required DateTime from,
    required DateTime to,
  }) =>
      _rpcRows(AccountingQueries.rpcJournal, {
        'p_business_id': businessId,
        'p_from': _d(from),
        'p_to': _d(to),
      });

  Future<List<Map<String, dynamic>>> ledger({
    required String businessId,
    required String accountId,
    required DateTime from,
    required DateTime to,
  }) =>
      _rpcRows(AccountingQueries.rpcLedger, {
        'p_business_id': businessId,
        'p_account_id': accountId,
        'p_from': _d(from),
        'p_to': _d(to),
      });

  Future<List<Map<String, dynamic>>> trialBalance({
    required String businessId,
    required DateTime from,
    required DateTime to,
    String? costCenterId,
  }) =>
      _rpcRows(AccountingQueries.rpcTrialBalance, {
        'p_business_id': businessId,
        'p_from': _d(from),
        'p_to': _d(to),
        'p_cost_center_id': costCenterId,
      });

  Future<List<Map<String, dynamic>>> incomeStatement({
    required String businessId,
    required DateTime from,
    required DateTime to,
  }) =>
      _rpcRows(AccountingQueries.rpcIncomeStatement, {
        'p_business_id': businessId,
        'p_from': _d(from),
        'p_to': _d(to),
      });

  Future<List<Map<String, dynamic>>> balanceSheet({
    required String businessId,
    required DateTime asOf,
  }) =>
      _rpcRows(AccountingQueries.rpcBalanceSheet, {
        'p_business_id': businessId,
        'p_as_of': _d(asOf),
      });

  Future<List<Map<String, dynamic>>> _rpcRows(
    String fn,
    Map<String, dynamic> params,
  ) async {
    final res = await _client.rpc(fn, params: params);
    if (res == null) return const [];
    return List<Map<String, dynamic>>.from(res as List);
  }

  static String _d(DateTime date) =>
      '${date.year.toString().padLeft(4, '0')}-'
      '${date.month.toString().padLeft(2, '0')}-'
      '${date.day.toString().padLeft(2, '0')}';
}
