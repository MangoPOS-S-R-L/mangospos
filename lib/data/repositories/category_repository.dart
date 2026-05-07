// lib/data/repositories/category_repository.dart
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:mangopos/data/models/category.dart';
import '../../core/business/business_resolver.dart'; // ⬅️ importa el resolver

class CategoryRepository {
  static const _table = 'categories';
  final _client = Supabase.instance.client;

  Future<List<Category>> list(String businessId) async {
    // Resuelve "auto" -> UUID real
    final bid = await BusinessResolver.ensure(businessId);

    final res = await _client
        .from(_table)
        .select()
        .eq('business_id', bid)
        .order('position', ascending: true)
        .order('name', ascending: true);

    return (res as List).map((e) => Category.fromMap(e)).toList();
  }

  Future<Category> create(Category data) async {
    // Si el modelo trae business_id = "auto", resuélvelo antes de insertar
    final insert = Map<String, dynamic>.from(data.toInsert());
    final v = insert['business_id'];
    if (v is String && v.toLowerCase() == 'auto') {
      insert['business_id'] = await BusinessResolver.ensure(v);
    }

    final res = await _client.from(_table).insert(insert).select().single();
    return Category.fromMap(res);
  }

  Future<void> update(String id, Map<String, dynamic> patch) async {
    // Defensa por si patch trae business_id = "auto"
    final v = patch['business_id'];
    if (v is String && v.toLowerCase() == 'auto') {
      patch = {...patch, 'business_id': await BusinessResolver.ensure(v)};
    }
    await _client.from(_table).update(patch).eq('id', id);
  }

  Future<void> remove(String id) async {
    await _client.from(_table).delete().eq('id', id);
  }

  /// Persiste el nuevo orden de categorías en `categories.position`. Igual
  /// patrón que `reorderZones` en zonas: step de 10 (10, 20, 30...) para
  /// permitir inserciones manuales sin reescribir todo. Hace UPDATE
  /// individual por categoría que cambió de posición — Supabase no
  /// soporta batch upsert por id distinto en una sola llamada.
  Future<void> reorder(List<Category> ordered) async {
    for (var i = 0; i < ordered.length; i++) {
      final cat = ordered[i];
      final newPos = (i + 1) * 10;
      if (cat.position == newPos) continue;
      await _client
          .from(_table)
          .update({'position': newPos})
          .eq('id', cat.id);
    }
  }
}
