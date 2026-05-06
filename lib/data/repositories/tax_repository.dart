// lib/data/repositories/tax_repository.dart
import 'package:supabase_flutter/supabase_flutter.dart';
import '../models/tax.dart';
import '../../core/business/business_resolver.dart';

class TaxRepository {
  static const _table = 'taxes';
  final _sp = Supabase.instance.client;

  Future<List<Tax>> list(String businessId) async {
    final bid = await BusinessResolver.ensure(businessId);
    final res = await _sp.from(_table).select().eq('business_id', bid).order('created_at');
    return (res as List).map((e) => Tax.fromMap(e as Map<String, dynamic>)).toList();
  }

  Future<Tax> create({
    required String businessId,
    required String name,
    required double rate,
    bool isActive = true,
    bool applyOnZone = true,
    bool applyOnManual = true,
    bool applyOnQuick = true,
    bool applyOnDelivery = true,
    bool applyOnTakeout = true,
    bool isServiceFee = false,
    bool? includeInEcf,
  }) async {
    final bid = await BusinessResolver.ensure(businessId);
    // Default sensato si el caller no decide: ITBIS-like va al e-CF;
    // propina-like (is_service_fee=true) NO va al e-CF.
    final resolvedIncludeInEcf = includeInEcf ?? !isServiceFee;
    final row = await _sp.from(_table).insert({
      'business_id': bid,
      'name': name,
      'rate': rate,
      'is_active': isActive,
      'apply_on_zone': applyOnZone,
      'apply_on_manual': applyOnManual,
      'apply_on_quick': applyOnQuick,
      'apply_on_delivery': applyOnDelivery,
      'apply_on_takeout': applyOnTakeout,
      'is_service_fee': isServiceFee,
      'include_in_ecf': resolvedIncludeInEcf,
    }).select().single();
    return Tax.fromMap(row);
  }


  Future<void> update(String id, Map<String, dynamic> patch) async {
    await _sp.from(_table).update(patch).eq('id', id);
  }

  Future<void> remove(String id) async {
    await _sp.from(_table).delete().eq('id', id);
  }
}
