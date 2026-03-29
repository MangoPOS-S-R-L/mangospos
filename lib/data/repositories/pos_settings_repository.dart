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

  final SupabaseClient _client;

  Future<bool> getPromptPeopleCountOnTableOpen(String businessId) async {
    try {
      final row = await _client
          .from('businesses')
          .select('prompt_people_count_on_table_open')
          .eq('id', businessId)
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
    await _client
        .from('businesses')
        .update({'prompt_people_count_on_table_open': enabled})
        .eq('id', businessId);
  }

  Future<String> getReceiptItemDisplayMode(String businessId) async {
    final cached = _receiptModeCache[businessId];
    if (cached != null &&
        DateTime.now().difference(cached.cachedAt) < _receiptModeCacheTtl) {
      return cached.mode;
    }

    try {
      final row = await _client
          .from('businesses')
          .select('receipt_item_display_mode')
          .eq('id', businessId)
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

    await _client
        .from('businesses')
        .update({'receipt_item_display_mode': normalized})
        .eq('id', businessId);
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
