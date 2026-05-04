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
        .order('sort_order', ascending: true)
        .order('name', ascending: true);

    return List<Map<String, dynamic>>.from(
      response,
    ).map(ModifierGroupSummary.fromMap).toList(growable: false);
  }

  /// Reordena globalmente los grupos del negocio. Asigna sort_order = 1..N
  /// usando el RPC fn_reorder_modifier_groups_global.
  Future<void> reorderGroupsGlobal({
    required String businessId,
    required List<String> orderedGroupIds,
  }) async {
    if (orderedGroupIds.isEmpty) return;
    await _client.rpc(
      'fn_reorder_modifier_groups_global',
      params: {
        'p_business_id': businessId,
        'p_group_ids': orderedGroupIds,
      },
    );
  }

  Future<List<ModifierOption>> getModifiers(String businessId) async {
    final response = await _client
        .from('modifiers')
        .select('id, group_id, name, price_delta, is_active, created_at')
        .eq('business_id', businessId)
        .order('sort_order', ascending: true)
        .order('name', ascending: true);

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

  /// Lista los grupos asignados a un producto en el orden actual (position).
  /// Devuelve una lista de mapas con `id`, `name` y `position`.
  Future<List<Map<String, dynamic>>> getGroupsForMenuItem(
    String menuItemId,
  ) async {
    final response = await _client
        .from('menu_item_groups')
        .select(
          'group_id, position, modifier_groups!inner(id, name, is_active)',
        )
        .eq('menu_item_id', menuItemId)
        .order('position', ascending: true);

    final rows = List<Map<String, dynamic>>.from(response);
    return rows.map((row) {
      final group = row['modifier_groups'] as Map<String, dynamic>?;
      return <String, dynamic>{
        'id': group?['id']?.toString() ?? row['group_id']?.toString() ?? '',
        'name': group?['name']?.toString() ?? '',
        'is_active': group?['is_active'] ?? true,
        'position': row['position'] ?? 0,
      };
    }).toList(growable: false);
  }

  /// Persiste el nuevo orden de grupos asignados a un producto.
  /// Usa el RPC fn_reorder_modifier_groups que actualiza atómicamente.
  Future<void> reorderModifierGroupsForMenuItem({
    required String menuItemId,
    required List<String> orderedGroupIds,
  }) async {
    await _client.rpc(
      'fn_reorder_modifier_groups',
      params: {
        'p_menu_item_id': menuItemId,
        'p_group_ids': orderedGroupIds,
      },
    );
  }

  /// Persiste el nuevo orden de modificadores (opciones) dentro de un grupo.
  /// Actualiza modifiers.sort_order para cada id en orden 1..N.
  Future<void> reorderModifiersInGroup({
    required String groupId,
    required List<String> orderedModifierIds,
  }) async {
    if (orderedModifierIds.isEmpty) return;
    for (var i = 0; i < orderedModifierIds.length; i++) {
      await _client
          .from('modifiers')
          .update({'sort_order': i + 1})
          .eq('id', orderedModifierIds[i])
          .eq('group_id', groupId);
    }
  }
}
