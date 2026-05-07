// lib/data/repositories/bank_accounts_repository.dart
//
// CRUD de cuentas bancarias del negocio. Usado por:
// - Settings → Tipos de Pago → Transferencias (admin)
// - Modal de cobro al seleccionar transferencia (cajero, solo `listActive`)

import 'package:supabase_flutter/supabase_flutter.dart';

import '../../core/business/business_resolver.dart';
import '../models/bank_account.dart';

class BankAccountsRepository {
  static const _table = 'bank_accounts';
  final SupabaseClient _client;

  BankAccountsRepository([SupabaseClient? client])
      : _client = client ?? Supabase.instance.client;

  /// Lista todas las cuentas del negocio (activas e inactivas), ordenadas
  /// por sort_order y luego por bank_name. Usado en la pantalla de admin.
  Future<List<BankAccount>> list(String businessId) async {
    final bid = await BusinessResolver.ensure(businessId);
    final res = await _client
        .from(_table)
        .select()
        .eq('business_id', bid)
        .order('sort_order', ascending: true)
        .order('bank_name', ascending: true);
    return (res as List)
        .map((e) => BankAccount.fromMap(Map<String, dynamic>.from(e as Map)))
        .toList(growable: false);
  }

  /// Solo cuentas activas. Usado por el modal de cobro para que el
  /// cajero no vea cuentas dadas de baja.
  Future<List<BankAccount>> listActive(String businessId) async {
    final bid = await BusinessResolver.ensure(businessId);
    final res = await _client
        .from(_table)
        .select()
        .eq('business_id', bid)
        .eq('is_active', true)
        .order('sort_order', ascending: true)
        .order('bank_name', ascending: true);
    return (res as List)
        .map((e) => BankAccount.fromMap(Map<String, dynamic>.from(e as Map)))
        .toList(growable: false);
  }

  Future<BankAccount> create(BankAccount data) async {
    final insert = Map<String, dynamic>.from(data.toInsert());
    final v = insert['business_id'];
    if (v is String && v.toLowerCase() == 'auto') {
      insert['business_id'] = await BusinessResolver.ensure(v);
    }
    // El id lo genera la DB si no se manda; permitimos que el modelo
    // mande uno explícito (UUID generado en cliente) para optimismo.
    final res = await _client.from(_table).insert(insert).select().single();
    return BankAccount.fromMap(Map<String, dynamic>.from(res as Map));
  }

  Future<void> update(String id, Map<String, dynamic> patch) async {
    final v = patch['business_id'];
    if (v is String && v.toLowerCase() == 'auto') {
      patch = {...patch, 'business_id': await BusinessResolver.ensure(v)};
    }
    await _client.from(_table).update(patch).eq('id', id);
  }

  Future<void> remove(String id) async {
    await _client.from(_table).delete().eq('id', id);
  }

  /// Persiste el nuevo orden. Step de 10 (mismo patrón que zonas y
  /// categorías) para permitir inserciones manuales sin reescribir
  /// todas las filas. Skip si la posición ya coincide.
  Future<void> reorder(List<BankAccount> ordered) async {
    for (var i = 0; i < ordered.length; i++) {
      final acc = ordered[i];
      final newPos = (i + 1) * 10;
      if (acc.sortOrder == newPos) continue;
      await _client
          .from(_table)
          .update({'sort_order': newPos})
          .eq('id', acc.id);
    }
  }
}
