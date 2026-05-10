import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

final posSettingsRepositoryProvider = Provider<PosSettingsRepository>(
  (ref) => PosSettingsRepository(Supabase.instance.client),
);

class PosSettingsRepository {
  PosSettingsRepository(this._client);

  static const String receiptItemsGrouped = 'grouped';
  static const String receiptItemsSeparate = 'separate';
  static const Duration _receiptModeCacheTtl = Duration(minutes: 5);
  static final Map<String, _CachedReceiptMode> _receiptModeCache = {};

  /// Modo compacto: un solo modal con efectivo + tarjeta + transferencia.
  /// Comportamiento actual del POS.
  static const String cashCloseCompact = 'compact';

  /// Modo detallado: wizard de 3 pasos (efectivo / tarjeta + transferencia /
  /// revision). Ambos modos son a ciegas durante el conteo.
  static const String cashCloseDetailed = 'detailed';

  final SupabaseClient _client;

  Future<String> getCashCloseMode(String businessId) async {
    try {
      final row = await _client
          .from('business_settings')
          .select('cash_close_mode')
          .eq('business_id', businessId)
          .maybeSingle();

      final raw = row?['cash_close_mode']?.toString();
      return raw == cashCloseDetailed ? cashCloseDetailed : cashCloseCompact;
    } catch (_) {
      return cashCloseCompact;
    }
  }

  Future<void> setCashCloseMode({
    required String businessId,
    required String mode,
  }) async {
    final normalized = mode == cashCloseDetailed
        ? cashCloseDetailed
        : cashCloseCompact;

    await _client.from('business_settings').upsert({
      'business_id': businessId,
      'cash_close_mode': normalized,
    }, onConflict: 'business_id');
  }

  Future<bool> getPromptPeopleCountOnTableOpen(String businessId) async {
    try {
      final row = await _client
          .from('business_settings')
          .select('prompt_people_count_on_table_open')
          .eq('business_id', businessId)
          .maybeSingle();

      return row?['prompt_people_count_on_table_open'] == true;
    } catch (_) {
      return false;
    }
  }

  Future<void> setPromptPeopleCountOnTableOpen({
    required String businessId,
    required bool enabled,
  }) async {
    await _client.from('business_settings').upsert({
      'business_id': businessId,
      'prompt_people_count_on_table_open': enabled,
    }, onConflict: 'business_id');
  }

  Future<String> getReceiptItemDisplayMode(String businessId) async {
    final cached = _receiptModeCache[businessId];
    if (cached != null &&
        DateTime.now().difference(cached.cachedAt) < _receiptModeCacheTtl) {
      return cached.mode;
    }

    try {
      final row = await _client
          .from('business_settings')
          .select('receipt_item_display_mode')
          .eq('business_id', businessId)
          .maybeSingle();

      final mode = row?['receipt_item_display_mode']?.toString();
      final normalized = mode == receiptItemsSeparate
          ? receiptItemsSeparate
          : receiptItemsGrouped;
      _receiptModeCache[businessId] = _CachedReceiptMode(
        normalized,
        DateTime.now(),
      );
      return normalized;
    } catch (_) {
      return receiptItemsGrouped;
    }
  }

  Future<void> setReceiptItemDisplayMode({
    required String businessId,
    required String mode,
  }) async {
    final normalized = mode == receiptItemsSeparate
        ? receiptItemsSeparate
        : receiptItemsGrouped;

    await _client.from('business_settings').upsert({
      'business_id': businessId,
      'receipt_item_display_mode': normalized,
    }, onConflict: 'business_id');
    _receiptModeCache[businessId] = _CachedReceiptMode(
      normalized,
      DateTime.now(),
    );
  }
}

class _CachedReceiptMode {
  const _CachedReceiptMode(this.mode, this.cachedAt);

  final String mode;
  final DateTime cachedAt;
}
