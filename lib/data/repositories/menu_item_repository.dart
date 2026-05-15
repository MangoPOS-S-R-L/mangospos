import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:uuid/uuid.dart';
import '../models/menu_item.dart';
import '../../core/business/business_resolver.dart';

class MenuItemRepository {
  static const _tableItems = 'menu_items';
  static const _tableLinks = 'menu_item_links';
  static const _viewList = 'v_menu_items_list';
  static const _tableItemTaxes =
      'menu_item_taxes'; // << tabla de vínculo impuestos

  final SupabaseClient _sp = Supabase.instance.client;

  Future<List<MenuItem>> list(
    String businessId, {
    String search = '',
    int limit = 1000,
  }) async {
    final bid = await BusinessResolver.ensure(businessId);
    var q = _sp.from(_viewList).select().eq('business_id', bid);

    final s = search.trim();
    if (s.isNotEmpty) {
      q = q.or('name.ilike.%$s%,sku.ilike.%$s%');
    }

    final res = await q.order('created_at', ascending: true).limit(limit);

    return (res as List)
        .map((e) => MenuItem.fromMap(e as Map<String, dynamic>))
        .toList(growable: false);
  }

  Future<MenuItem> create({
    required String businessId,
    required String name,
    String? description,
    String? categoryId,
    double price = 0,
    String? sku,
    int prepMinutes = 0,
    bool hasVariants = false,
    bool isActive = true,
    String? imageUrl,
    String? imagePath,
    String? attachMenuId,
    bool hasPrep = false,

    // 👇 nuevos
    String? soldBy, // 'unit' | 'weight'
    List<String>? taxIds, // ids de impuestos a vincular
    double? cost, // (si decides guardar costo)
    String? barcode, // código de barras

    // 👇 Sprint inventario por producto
    bool isInventoryTracked = false,
    double initialStock = 0,
  }) async {
    final bid = await BusinessResolver.ensure(businessId);
    final id = const Uuid().v4();

    final insert = <String, dynamic>{
      'id': id,
      'business_id': bid,
      'name': name,
      'description': description,
      'category_id': categoryId,
      'price': price,
      'sku': sku,
      'prep_minutes': hasPrep ? prepMinutes : 0,
      'has_variants': hasVariants,
      'is_active': isActive,
      'image_url': imageUrl,
      'image_path': imagePath,
      'has_prep': hasPrep,

      // 👇 nuevos campos si existen en tu schema
      'sold_by': soldBy, // text
      'cost': cost, // numeric
      'barcode': barcode, // text
    }..removeWhere((k, v) => v == null);

    final row = await _sp.from(_tableItems).insert(insert).select().single();

    if (attachMenuId != null && attachMenuId.isNotEmpty) {
      await _sp.from(_tableLinks).insert({
        'menu_id': attachMenuId,
        'item_id': id,
        'position': 0,
      });
    }

    // 👇 vincula impuestos (si hay)
    if (taxIds != null && taxIds.isNotEmpty) {
      await _sp
          .from(_tableItemTaxes)
          .insert(taxIds.map((tid) => {'item_id': id, 'tax_id': tid}).toList());
    }

    // Si se pide tracking de inventario, llamar la RPC que crea inventory_item
    // + receta 1:1 y registra stock inicial en la bodega principal. La RPC
    // actualiza is_inventory_tracked al final.
    if (isInventoryTracked) {
      await setInventoryTracked(
        menuItemId: id,
        tracked: true,
        initialStock: initialStock,
      );
    }

    return MenuItem.fromMap(row);
  }

  /// Activa/desactiva el flag de inventario en un producto. Si se activa,
  /// la RPC se asegura de que exista inventory_item + receta 1:1 y, si
  /// `initialStock > 0`, registra un movimiento purchase en la bodega
  /// principal. Si se desactiva, solo baja el flag (no borra movimientos
  /// para preservar histórico).
  Future<Map<String, dynamic>> setInventoryTracked({
    required String menuItemId,
    required bool tracked,
    double initialStock = 0,
    String? warehouseId,
  }) async {
    final response = await _sp.rpc(
      'fn_menu_item_set_inventory_tracked',
      params: {
        'p_menu_item_id': menuItemId,
        'p_tracked': tracked,
        'p_initial_stock': initialStock,
        if (warehouseId != null) 'p_warehouse_id': warehouseId,
      },
    );
    return response is Map
        ? Map<String, dynamic>.from(response)
        : <String, dynamic>{};
  }

  Future<void> update(String id, Map<String, dynamic> patch) async {
    if (patch['has_prep'] == false) {
      patch = {...patch, 'prep_minutes': 0};
    }
    patch.removeWhere((k, v) => v == null);
    await _sp.from(_tableItems).update(patch).eq('id', id);
  }

  Future<void> toggleActive(String id, bool v) => update(id, {'is_active': v});

  Future<void> updateImagePath(String id, String path) =>
      update(id, {'image_path': path});

  Future<void> remove(String id) async {
    // elimina vínculos con menús e impuestos
    await _sp.from(_tableLinks).delete().eq('item_id', id);
    await _sp.from(_tableItemTaxes).delete().eq('item_id', id);
    await _sp.from(_tableItems).delete().eq('id', id);
  }

  Future<void> linkToMenu({
    required String menuId,
    required String itemId,
    int? position,
  }) async {
    final pos = position ?? await _nextPosition(menuId);
    await _sp.from(_tableLinks).insert({
      'menu_id': menuId,
      'item_id': itemId,
      'position': pos,
    });
  }

  Future<void> unlinkFromMenu({
    required String menuId,
    required String itemId,
  }) async {
    await _sp.from(_tableLinks).delete().match({
      'menu_id': menuId,
      'item_id': itemId,
    });
  }

  Future<void> reorderInMenu({
    required String menuId,
    required String itemId,
    required int newPosition,
  }) async {
    await _sp.from(_tableLinks).update({'position': newPosition}).match({
      'menu_id': menuId,
      'item_id': itemId,
    });
  }

  Future<int> _nextPosition(String menuId) async {
    final res = await _sp
        .from(_tableLinks)
        .select('position')
        .eq('menu_id', menuId)
        .order('position', ascending: false)
        .limit(1);
    if (res.isNotEmpty && res.first['position'] != null) {
      return (res.first['position'] as int) + 1;
    }
    return 0;
  }
}
