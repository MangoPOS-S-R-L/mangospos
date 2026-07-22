import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import '../../data/models/fiscal_models.dart';
import '../../core/business/business_resolver.dart';
import '../../core/storage/storage_service.dart';

final fiscalServiceProvider = Provider((ref) => FiscalService());

class FiscalService {
  final _db = Supabase.instance.client;

  String _sequencesCacheKey(String bid) => 'fiscal_sequences_cache_$bid';

  /// Secuencias NCF del negocio con cache offline: cada lectura online
  /// exitosa se persiste en disco; sin internet (o con la red colgada) se
  /// devuelve el último snapshot. Sin esto, al cobrar offline el gate del
  /// modal decía "no hay secuencias fiscales activas" aunque el negocio
  /// las tuviera — el NCF real igual lo asigna el server al sincronizar.
  Future<List<FiscalNcfSequence>> getSequences(String businessId) async {
    final bid = await BusinessResolver.ensure(businessId);
    try {
      final res = await _db
          .from('ncf_sequences')
          .select()
          .eq('business_id', bid)
          .order('ncf_type')
          .timeout(const Duration(seconds: 8));

      final rows = List<Map<String, dynamic>>.from(res as List);
      // Cache best-effort: nunca rompe la lectura online.
      try {
        final storage = await StorageService.getInstance();
        await storage.writeList(_sequencesCacheKey(bid), rows);
      } catch (_) {}
      return rows.map(FiscalNcfSequence.fromJson).toList();
    } catch (e) {
      try {
        final storage = await StorageService.getInstance();
        final cached = await storage.readList(_sequencesCacheKey(bid));
        if (cached != null && cached.isNotEmpty) {
          debugPrint(
            'FiscalService: usando secuencias NCF cacheadas offline ($e)',
          );
          return cached
              .map((it) => FiscalNcfSequence.fromJson(
                    Map<String, dynamic>.from(it as Map),
                  ))
              .toList(growable: false);
        }
      } catch (_) {}
      rethrow;
    }
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
    final payload = <String, dynamic>{};

    if (data.containsKey('current_number')) {
      payload['current_number'] = data['current_number'];
    }
    if (data.containsKey('range_end')) {
      payload['range_end'] = data['range_end'];
    }
    if (data.containsKey('is_active')) {
      payload['is_active'] = data['is_active'];
    }
    if (data.containsKey('expiration_date')) {
      payload['expiration_date'] = data['expiration_date'];
    }
    if (data.containsKey('authorized_by')) {
      payload['authorized_by'] = data['authorized_by'];
    }

    if (payload.isEmpty) return;

    await _db.from('ncf_sequences').update(payload).eq('id', id);
  }
}
