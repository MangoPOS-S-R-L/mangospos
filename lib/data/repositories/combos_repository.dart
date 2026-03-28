import 'package:supabase_flutter/supabase_flutter.dart';

class CombosRepository {
  final SupabaseClient _client;

  CombosRepository(this._client);

  Future<String?> resolveBusinessId() async {
    final membership = await _client
        .from('user_businesses')
        .select('business_id')
        .limit(1)
        .maybeSingle();
    return membership?['business_id']?.toString();
  }

  Future<List<Map<String, dynamic>>> getComboProducts(String businessId) async {
    final rows = await _client
        .from('menu_items')
        .select('id, name, price, is_active')
        .eq('business_id', businessId)
        .eq('item_type', 'combo')
        .order('name');
    return List<Map<String, dynamic>>.from(rows);
  }

  Future<List<Map<String, dynamic>>> getProducts(String businessId) async {
    final rows = await _client
        .from('menu_items')
        .select('id, name, price, is_active, item_type')
        .eq('business_id', businessId)
        .eq('is_active', true)
        .neq('item_type', 'combo')
        .order('name');
    return List<Map<String, dynamic>>.from(rows);
  }

  Future<List<Map<String, dynamic>>> getComboGroups(String comboId) async {
    final rows = await _client
        .from('combo_groups')
        .select(
          'id, business_id, menu_item_id, name, min_select, max_select, is_required, sort_order',
        )
        .eq('menu_item_id', comboId)
        .order('sort_order');
    return List<Map<String, dynamic>>.from(rows);
  }

  Future<List<Map<String, dynamic>>> getComboGroupItems(String comboId) async {
    final rows = await _client
        .from('combo_group_items')
        .select(
          'id, combo_group_id, menu_item_id, price_delta, is_default, sort_order, menu_items(id, name, price, is_active)',
        )
        .inFilter(
          'combo_group_id',
          (await getComboGroups(
            comboId,
          )).map((e) => e['id']?.toString()).whereType<String>().toList(),
        );
    return List<Map<String, dynamic>>.from(rows);
  }

  Future<void> createComboGroup({
    required String businessId,
    required String comboId,
    required String name,
    required int minSelect,
    required int maxSelect,
    required int sortOrder,
  }) async {
    await _client.from('combo_groups').insert({
      'business_id': businessId,
      'menu_item_id': comboId,
      'name': name,
      'min_select': minSelect,
      'max_select': maxSelect,
      'is_required': minSelect > 0,
      'sort_order': sortOrder,
    });
  }

  Future<void> deleteComboGroup(String groupId) async {
    await _client.from('combo_groups').delete().eq('id', groupId);
  }

  Future<void> replaceComboGroupItems({
    required String groupId,
    required List<Map<String, dynamic>> items,
  }) async {
    await _client
        .from('combo_group_items')
        .delete()
        .eq('combo_group_id', groupId);
    if (items.isEmpty) return;
    await _client
        .from('combo_group_items')
        .insert(
          items
              .map(
                (item) => {
                  'combo_group_id': groupId,
                  'menu_item_id': item['menu_item_id'],
                  'price_delta': item['price_delta'] ?? 0,
                  'is_default': item['is_default'] ?? false,
                  'sort_order': item['sort_order'] ?? 0,
                },
              )
              .toList(growable: false),
        );
  }

  Future<List<Map<String, dynamic>>> getComboConfig(String comboId) async {
    final groups = await _client
        .from('combo_groups')
        .select(
          'id, name, min_select, max_select, is_required, sort_order, combo_group_items(id, menu_item_id, price_delta, is_default, sort_order, menu_items(id, name, price, is_active))',
        )
        .eq('menu_item_id', comboId)
        .order('sort_order');
    return List<Map<String, dynamic>>.from(groups);
  }
}
