import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import '../../data/models/fiscal_models.dart';
import '../../core/business/business_resolver.dart';

final fiscalServiceProvider = Provider((ref) => FiscalService());

class FiscalService {
  final _db = Supabase.instance.client;

  Future<List<FiscalNcfSequence>> getSequences(String businessId) async {
    final bid = await BusinessResolver.ensure(businessId);
    final res = await _db
        .from('ncf_sequences')
        .select()
        .eq('business_id', bid)
        .order('ncf_type');

    return (res as List).map((it) => FiscalNcfSequence.fromJson(it)).toList();
  }

  Future<void> initializeSequence({
    required String businessId,
    required String tipo,
    required String serie,
    required int ultimoSeq,
    required int maximoSeq,
  }) async {
    final bid = await BusinessResolver.ensure(businessId);
    final ncfType = '$serie$tipo';
    await _db.from('ncf_sequences').upsert({
      'business_id': bid,
      'ncf_type': ncfType,
      'serie': serie,
      'prefix': ncfType,
      'range_start': 1,
      'range_end': maximoSeq,
      'current_number': ultimoSeq,
      'is_active': true,
    }, onConflict: 'business_id,ncf_type,serie');
  }

  Future<Map<String, dynamic>> getBusinessFiscalSettings(
    String businessId,
  ) async {
    final bid = await BusinessResolver.ensure(businessId);
    final res = await _db
        .from('fiscal_settings')
        .select(
          'business_id, rnc, business_legal_name, ecf_enabled, default_ncf_type',
        )
        .eq('business_id', bid)
        .maybeSingle();

    if (res != null) return res;

    return {
      'business_id': bid,
      'rnc': '',
      'business_legal_name': '',
      'ecf_enabled': false,
      'default_ncf_type': 'B02',
    };
  }

  Future<void> updateBusinessFiscalSettings(
    String businessId,
    Map<String, dynamic> data,
  ) async {
    final bid = await BusinessResolver.ensure(businessId);
    final ecfEnabled = (data['ecf_enabled'] ?? false) as bool;
    final defaultNcfType =
        (data['default_ncf_type'] ?? (ecfEnabled ? 'E32' : 'B02')).toString();

    await _db.from('fiscal_settings').upsert({
      'business_id': bid,
      'rnc': (data['rnc'] ?? '').toString(),
      'business_legal_name': (data['business_legal_name'] ?? '').toString(),
      'ecf_enabled': ecfEnabled,
      'default_ncf_type': defaultNcfType,
    }, onConflict: 'business_id');
  }

  Future<void> updateSequence(String id, Map<String, dynamic> data) async {
    await _db
        .from('ncf_sequences')
        .update({...data, 'updated_at': DateTime.now().toIso8601String()})
        .eq('id', id);
  }
}
