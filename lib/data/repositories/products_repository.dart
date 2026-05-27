import 'package:supabase_flutter/supabase_flutter.dart';

import '../datasources/queries/products_queries.dart';
import '../utils/business_id_resolver.dart';

class ProductsRepository {
  final SupabaseClient _client;

  ProductsRepository(this._client);

  Future<String?> getBusinessIdForCurrentUser() async {
    return resolveBusinessIdOrNull(_client, 'auto');
  }

  /// Catálogo completo (products + categories + menus) en un solo
  /// round-trip via RPC. Reemplaza las 3 queries que hacía la pantalla
  /// de productos al inicializar (~4 round-trips contando el stock).
  ///
  /// Retorna `(products, categories, menus)` en el mismo shape que las
  /// 3 funciones individuales — products tiene `categories`, `menu_item_links`,
  /// `menu_item_taxes` y `stock` ya embebidos por el RPC.
  Future<
    ({
      List<Map<String, dynamic>> products,
      List<Map<String, dynamic>> categories,
      List<Map<String, dynamic>> menus,
    })
  > getProductsCatalog(String businessId) async {
    final response = await _client.rpc(
      'get_products_catalog',
      params: {'_business_id': businessId},
    );

    if (response == null) {
      return (
        products: const <Map<String, dynamic>>[],
        categories: const <Map<String, dynamic>>[],
        menus: const <Map<String, dynamic>>[],
      );
    }

    final payload = Map<String, dynamic>.from(response as Map);

    List<Map<String, dynamic>> toList(dynamic raw) {
      if (raw is! List) return const [];
      return raw
          .whereType<Map>()
          .map((m) => Map<String, dynamic>.from(m))
          .toList(growable: false);
    }

    return (
      products: toList(payload['products']),
      categories: toList(payload['categories']),
      menus: toList(payload['menus']),
    );
  }

  Future<List<Map<String, dynamic>>> getProducts(String businessId) async {
    final response = await _client
        .from(ProductsQueries.tableMenuItems)
        .select(ProductsQueries.selectProducts)
        .eq('business_id', businessId)
        .order('created_at', ascending: false);

    final products = List<Map<String, dynamic>>.from(response);

    // Merge stock disponible por producto. Si la vista no existe (migración
    // no aplicada), ignoramos silenciosamente — el resto del query no debe
    // romperse por una migración faltante.
    try {
      final stockRows = await _client
          .from(ProductsQueries.viewMenuItemsStock)
          .select(ProductsQueries.selectMenuItemsStock);
      final stockByItem = <String, Map<String, dynamic>>{};
      for (final row in (stockRows as List)) {
        final map = Map<String, dynamic>.from(row as Map);
        final id = map['menu_item_id']?.toString();
        if (id != null) stockByItem[id] = map;
      }
      for (final p in products) {
        final id = p['id']?.toString();
        if (id != null && stockByItem.containsKey(id)) {
          p['stock'] = stockByItem[id];
        }
      }
    } catch (_) {
      // Vista no aplicada o sin permisos. No es crítico — productos
      // siguen apareciendo, solo sin la columna de stock.
    }

    return products;
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
    String? printAreaCode,
    String? imagePath,
    String? imageUrl,
    List<String> taxIds = const [],
    // 👇 inventario por producto
    bool isInventoryTracked = false,
    double initialStock = 0,
    bool allowNegativeSale = false,
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
            'allow_negative_sale': allowNegativeSale,
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

    // Si se pide tracking, llamar la RPC que crea inventory_item + receta
    // 1:1 + opcionalmente registra stock inicial en la bodega principal.
    if (isInventoryTracked) {
      await setInventoryTracked(
        menuItemId: itemId,
        tracked: true,
        initialStock: initialStock,
      );
    }

    return Map<String, dynamic>.from(created);
  }

  /// Activa/desactiva el tracking de inventario de un producto. Llama la
  /// RPC `fn_menu_item_set_inventory_tracked`. Si `tracked=true` e
  /// `initialStock > 0`, registra un movimiento purchase en la bodega
  /// principal del business.
  Future<Map<String, dynamic>> setInventoryTracked({
    required String menuItemId,
    required bool tracked,
    double initialStock = 0,
    String? warehouseId,
  }) async {
    final response = await _client.rpc(
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
    String? printAreaCode,
    String? imagePath,
    String? imageUrl,
    List<String> taxIds = const [],
    // 👇 inventario por producto. Si difiere del valor actual, después del
    // update llama la RPC para sincronizar receta/inventory_item/stock.
    bool? isInventoryTracked,
    double initialStock = 0,
    bool? allowNegativeSale,
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
      if (allowNegativeSale != null) 'allow_negative_sale': allowNegativeSale,
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

    // Sincronizar flag de inventario si el caller lo proveyó. Si se activa,
    // la RPC crea receta/inventory_item y opcionalmente registra stock
    // inicial. Si se desactiva, baja el flag preservando histórico.
    if (isInventoryTracked != null) {
      await setInventoryTracked(
        menuItemId: id,
        tracked: isInventoryTracked,
        initialStock: isInventoryTracked ? initialStock : 0,
      );
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

  /// Elimina un producto del menú definitivamente.
  ///
  /// Las FKs que apuntan a `menu_items` están configuradas para que el
  /// delete sea siempre seguro:
  ///   - `order_items.product_id`        → ON DELETE SET NULL (preserva el
  ///                                        ticket histórico con su nombre
  ///                                        y precio snapshotted)
  ///   - `recipes.menu_item_id`          → ON DELETE CASCADE (la receta
  ///                                        muere con el producto)
  ///   - `menu_item_groups/links/taxes`  → ON DELETE CASCADE
  ///   - `menu_item_print_areas`         → ON DELETE CASCADE
  ///
  /// Resultado: el catálogo queda limpio y los reportes/tickets viejos
  /// siguen funcionando porque `order_items` ya tenía denormalizado el
  /// `product_name`, `unit_price`, etc.
  ///
  /// Borramos primero `menu_item_links` y `menu_item_taxes` aunque ya
  /// cascadeen, por una razón pragmática: algunos ambientes viejos donde
  /// el CASCADE no estaba aún (instalaciones pre-migration) necesitan el
  /// cleanup explícito. Es no-op cuando las FKs ya cascadan.
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
