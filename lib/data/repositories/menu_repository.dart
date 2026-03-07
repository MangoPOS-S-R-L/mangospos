// lib/data/repositories/menu_repository.dart
import 'package:supabase_flutter/supabase_flutter.dart';
import '../models/menu.dart';
import '../../core/business/business_resolver.dart';

class MenuRepository {
  static const _table = 'menus';
  static const _view = 'v_menus_with_counts';
  final _sp = Supabase.instance.client;

  Future<List<Menu>> list(String businessId, {String search = ''}) async {
    // 1) Resolver "auto" -> UUID
    final bid = await BusinessResolver.ensure(businessId);

    // 2) Construir query con business_id ya resuelto
    var q =
        _sp.from(_view).select().eq('business_id', bid)
            as PostgrestFilterBuilder;

    if (search.trim().isNotEmpty) {
      q = q.ilike('name', '%${search.trim()}%');
    }

    // 3) order SIEMPRE al final
    final res = await q.order('created_at', ascending: true);

    return (res as List)
        .map((e) => Menu.fromMap(e as Map<String, dynamic>))
        .toList();
  }

  Future<Menu> create(Menu data) async {
    try {
      final res = await _sp
          .from(_table)
          .insert(data.toInsert(includeExtended: true))
          .select()
          .single();
      return Menu.fromMap(res);
    } on PostgrestException catch (e) {
      if (_isMissingExtendedColumn(e)) {
        final res = await _sp
            .from(_table)
            .insert(data.toInsert(includeExtended: false))
            .select()
            .single();
        return Menu.fromMap(res);
      }
      rethrow;
    }
  }

  Future<void> update(String id, Map<String, dynamic> patch) async {
    try {
      await _sp.from(_table).update(patch).eq('id', id);
    } on PostgrestException catch (e) {
      if (_isMissingExtendedColumn(e)) {
        final fallback = Map<String, dynamic>.from(patch)
          ..remove('description')
          ..remove('schedule');
        await _sp.from(_table).update(fallback).eq('id', id);
        return;
      }
      rethrow;
    }
  }

  Future<void> remove(String id) async {
    await _sp.from(_table).delete().eq('id', id);
  }

  bool _isMissingExtendedColumn(PostgrestException e) {
    if (e.code != '42703') return false;
    final msg = e.message.toLowerCase();
    return msg.contains('description') || msg.contains('schedule');
  }
}
