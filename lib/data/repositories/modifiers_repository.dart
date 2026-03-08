import 'package:supabase_flutter/supabase_flutter.dart';

import '../../presentation/settings/more settings/menus/modifiers/state/modifiers_state.dart';

class ModifiersRepository {
  final SupabaseClient _client;

  ModifiersRepository(this._client);

  double _toDouble(dynamic value) {
    if (value is num) return value.toDouble();
    return double.tryParse(value?.toString() ?? '') ?? 0;
  }

  Future<List<ModifierProduct>> getProducts(String businessId) async {
    final response = await _client
        .from('menu_items')
        .select('id, name, is_active')
        .eq('business_id', businessId)
        .order('name');

    return List<Map<String, dynamic>>.from(
      response,
    ).map(ModifierProduct.fromMap).toList(growable: false);
  }

  Future<List<ModifierGroupSummary>> getGroups(String businessId) async {
    final response = await _client
        .from('modifier_groups')
        .select('id, name, min_select, max_select, is_active, created_at')
        .eq('business_id', businessId)
        .order('created_at', ascending: false);

    return List<Map<String, dynamic>>.from(
      response,
    ).map(ModifierGroupSummary.fromMap).toList(growable: false);
  }

  Future<List<ModifierOption>> getModifiers(String businessId) async {
    final response = await _client
        .from('modifiers')
        .select('id, group_id, name, price_delta, is_active, created_at')
        .eq('business_id', businessId)
        .order('created_at', ascending: false);

    return List<Map<String, dynamic>>.from(
      response,
    ).map((row) => ModifierOption.fromMap(row, priceParser: _toDouble)).toList(
      growable: false,
    );
  }

  Future<Map<String, List<String>>> getAssignments(String businessId) async {
    final response = await _client
        .from('menu_item_groups')
        .select('menu_item_id, group_id, menu_items!inner(id, business_id)')
        .eq('menu_items.business_id', businessId);

    final assignments = <String, List<String>>{};
    for (final row in List<Map<String, dynamic>>.from(response)) {
      final groupId = row['group_id']?.toString();
      final menuItemId = row['menu_item_id']?.toString();
      if (groupId == null || groupId.isEmpty || menuItemId == null || menuItemId.isEmpty) {
        continue;
      }
      assignments.putIfAbsent(groupId, () => <String>[]);
      assignments[groupId]!.add(menuItemId);
    }
    return assignments;
  }

  Future<void> createGroup({
    required String businessId,
    required String id,
    required String name,
    required int minSelect,
    required int maxSelect,
    required bool isActive,
  }) async {
    await _client.from('modifier_groups').insert({
      'id': id,
      'business_id': businessId,
      'name': name,
      'min_select': minSelect,
      'max_select': maxSelect,
      'is_active': isActive,
    });
  }

  Future<void> updateGroup({
    required String id,
    required String name,
    required int minSelect,
    required int maxSelect,
    required bool isActive,
  }) async {
    await _client.from('modifier_groups').update({
      'name': name,
      'min_select': minSelect,
      'max_select': maxSelect,
      'is_active': isActive,
    }).eq('id', id);
  }

  Future<void> deleteGroup(String id) async {
    await _client.from('modifier_groups').delete().eq('id', id);
  }

  Future<void> createModifier({
    required String businessId,
    required String id,
    required String groupId,
    required String name,
    required double priceDelta,
    required bool isActive,
  }) async {
    await _client.from('modifiers').insert({
      'id': id,
      'business_id': businessId,
      'group_id': groupId,
      'name': name,
      'price_delta': priceDelta,
      'is_active': isActive,
    });
  }

  Future<void> updateModifier({
    required String id,
    required String groupId,
    required String name,
    required double priceDelta,
    required bool isActive,
  }) async {
    await _client.from('modifiers').update({
      'group_id': groupId,
      'name': name,
      'price_delta': priceDelta,
      'is_active': isActive,
    }).eq('id', id);
  }

  Future<void> deleteModifier(String id) async {
    await _client.from('modifiers').delete().eq('id', id);
  }

  Future<void> replaceAssignments({
    required String groupId,
    required List<String> menuItemIds,
  }) async {
    await _client.from('menu_item_groups').delete().eq('group_id', groupId);
    if (menuItemIds.isEmpty) return;

    await _client.from('menu_item_groups').insert(
      menuItemIds
          .map(
            (menuItemId) => {
              'menu_item_id': menuItemId,
              'group_id': groupId,
            },
          )
          .toList(growable: false),
    );
  }
}
