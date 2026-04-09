import 'package:supabase_flutter/supabase_flutter.dart';

import '../datasources/queries/products_queries.dart';
import '../utils/business_id_resolver.dart';

class ProductsRepository {
  final SupabaseClient _client;

  ProductsRepository(this._client);

  Future<String?> getBusinessIdForCurrentUser() async {
    return resolveBusinessIdOrNull(_client, 'auto');
  }

  Future<List<Map<String, dynamic>>> getProducts(String businessId) async {
    final response = await _client
        .from(ProductsQueries.tableMenuItems)
        .select(ProductsQueries.selectProducts)
        .eq('business_id', businessId)
        .order('created_at', ascending: false);

    return List<Map<String, dynamic>>.from(response);
  }

  Future<List<Map<String, dynamic>>> getCategories(String businessId) async {
    final response = await _client
        .from(ProductsQueries.tableCategories)
        .select()
        .eq('business_id', businessId)
        .order('name');

    return List<Map<String, dynamic>>.from(response);
  }

  Future<List<Map<String, dynamic>>> getMenus(String businessId) async {
    final response = await _client
        .from(ProductsQueries.tableMenus)
        .select()
        .eq('business_id', businessId)
        .order('name');

    return List<Map<String, dynamic>>.from(response);
  }

  Future<Map<String, dynamic>> createProduct({
    required String businessId,
    required String name,
    required double price,
    required String? categoryId,
    String taxMode = 'exclusive',
    String? sku,
    String? description,
    String? menuId,
    double? cost,
    String? barcode,
    bool hasVariants = false,
    bool isActive = true,
    String itemType = 'standard',
    String printAreaCode = 'kitchen_hot',
    String? imagePath,
    String? imageUrl,
    List<String> taxIds = const [],
  }) async {
    final created = await _client
        .from(ProductsQueries.tableMenuItems)
        .insert(
          {
            'business_id': businessId,
            'name': name,
            'price': price,
            'tax_mode': taxMode,
            'category_id': categoryId,
            'sku': sku,
            'is_active': isActive,
            'description': description,
            'cost': cost,
            'barcode': barcode,
            'has_variants': hasVariants,
            'item_type': itemType,
            'print_area_code': printAreaCode,
            'image_path': imagePath,
            'image_url': imageUrl,
          }..removeWhere((key, value) => value == null),
        )
        .select()
        .single();

    final itemId = created['id'] as String;

    if (menuId != null && menuId.isNotEmpty) {
      await _client.from(ProductsQueries.tableMenuItemLinks).insert({
        'item_id': itemId,
        'menu_id': menuId,
        'position': 0,
      });
    }

    if (taxIds.isNotEmpty) {
      final taxLinks = taxIds
          .map((taxId) => {'item_id': itemId, 'tax_id': taxId})
          .toList();
      await _client.from(ProductsQueries.tableMenuItemTaxes).insert(taxLinks);
    }

    return Map<String, dynamic>.from(created);
  }

  Future<void> updateProduct({
    required String id,
    required String name,
    required double price,
    required String? categoryId,
    required bool isActive,
    String taxMode = 'exclusive',
    String? sku,
    String? description,
    String? menuId,
    double? cost,
    String? barcode,
    bool hasVariants = false,
    String itemType = 'standard',
    String printAreaCode = 'kitchen_hot',
    String? imagePath,
    String? imageUrl,
    List<String> taxIds = const [],
  }) async {
    final updates = <String, dynamic>{
      'name': name,
      'price': price,
      'tax_mode': taxMode,
      'category_id': categoryId,
      'sku': sku,
      'is_active': isActive,
      'description': description,
      'cost': cost,
      'barcode': barcode,
      'has_variants': hasVariants,
      'item_type': itemType,
      'print_area_code': printAreaCode,
    };

    if (imagePath != null) {
      updates['image_path'] = imagePath;
      updates['image_url'] = imageUrl;
    }

    updates.removeWhere((key, value) => value == null);

    await _client
        .from(ProductsQueries.tableMenuItems)
        .update(updates)
        .eq('id', id);

    await _client
        .from(ProductsQueries.tableMenuItemLinks)
        .delete()
        .eq('item_id', id);

    if (menuId != null && menuId.isNotEmpty) {
      await _client.from(ProductsQueries.tableMenuItemLinks).insert({
        'item_id': id,
        'menu_id': menuId,
        'position': 0,
      });
    }

    await _client
        .from(ProductsQueries.tableMenuItemTaxes)
        .delete()
        .eq('item_id', id);

    if (taxIds.isNotEmpty) {
      final taxLinks = taxIds
          .map((taxId) => {'item_id': id, 'tax_id': taxId})
          .toList();
      await _client.from(ProductsQueries.tableMenuItemTaxes).insert(taxLinks);
    }
  }

  Future<void> toggleAvailability({
    required String id,
    required bool isActive,
  }) async {
    await _client
        .from(ProductsQueries.tableMenuItems)
        .update({'is_active': isActive})
        .eq('id', id);
  }

  Future<void> deleteProduct(String id) async {
    await _client
        .from(ProductsQueries.tableMenuItemLinks)
        .delete()
        .eq('item_id', id);
    await _client
        .from(ProductsQueries.tableMenuItemTaxes)
        .delete()
        .eq('item_id', id);
    await _client.from(ProductsQueries.tableMenuItems).delete().eq('id', id);
  }
}
