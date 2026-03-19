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
        .from('secuencias_ncf')
        .select()
        .eq('business_id', bid)
        .order('tipo');
    
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
    await _db.from('secuencias_ncf').insert({
      'business_id': bid,
      'tipo': tipo,
      'serie': serie,
      'ultimo_seq': ultimoSeq,
      'maximo_seq': maximoSeq,
      'activo': true,
    });
  }

  Future<Map<String, dynamic>> getBusinessFiscalSettings(String businessId) async {
    final bid = await BusinessResolver.ensure(businessId);
    final res = await _db
        .from('businesses')
        .select('prefer_electronic_billing, fiscal_rnc, fiscal_name')
        .eq('id', bid)
        .single();
    return res;
  }

  Future<void> updateBusinessFiscalSettings(String businessId, Map<String, dynamic> data) async {
    final bid = await BusinessResolver.ensure(businessId);
    await _db.from('businesses').update(data).eq('id', bid);
  }

  Future<void> updateSequence(String id, Map<String, dynamic> data) async {
    await _db.from('secuencias_ncf').update({
      ...data,
      'updated_at': DateTime.now().toIso8601String(),
    }).eq('id', id);
  }

  Future<String> getNextNcf(String businessId, String tipo) async {
    final bid = await BusinessResolver.ensure(businessId);
    final res = await _db.rpc('siguiente_ncf', params: {
      'p_business_id': bid,
      'p_tipo': tipo,
    });
    return res as String;
  }
}
