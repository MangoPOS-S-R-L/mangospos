import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

final posSettingsRepositoryProvider = Provider<PosSettingsRepository>(
  (ref) => PosSettingsRepository(Supabase.instance.client),
);

class PosSettingsRepository {
  PosSettingsRepository(this._client);

  static const String receiptItemsGrouped = 'grouped';
  static const String receiptItemsSeparate = 'separate';

  final SupabaseClient _client;

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
    try {
      final row = await _client
          .from('business_settings')
          .select('receipt_item_display_mode')
          .eq('business_id', businessId)
          .maybeSingle();

      final mode = row?['receipt_item_display_mode']?.toString();
      if (mode == receiptItemsSeparate) {
        return receiptItemsSeparate;
      }
      return receiptItemsGrouped;
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
  }
}
