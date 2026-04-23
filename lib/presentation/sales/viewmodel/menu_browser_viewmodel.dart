import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../../core/tax/tax_engine.dart';
import '../../../core/network/connectivity_service.dart';
import '../../../core/offline/offline_catalog_service.dart';
import '../../../data/utils/business_id_resolver.dart';
import '../../../services/session/session_controller.dart';

@immutable
class MenuCategory {
  final String id;
  final String name;
  final String? color;

  const MenuCategory({required this.id, required this.name, this.color});

  factory MenuCategory.fromMap(Map<String, dynamic> m) => MenuCategory(
    id: m['id'] as String,
    name: (m['name'] ?? '') as String,
    color: m['color'] as String?,
  );
}

@immutable
class MenuDefinition {
  final String id;
  final String name;

  const MenuDefinition({required this.id, required this.name});

  factory MenuDefinition.fromMap(Map<String, dynamic> m) =>
      MenuDefinition(id: m['id'] as String, name: (m['name'] ?? '') as String);
}

@immutable
class MenuProduct {
  final String id;
  final String name;
  final double price;
  final String taxMode;
  final double taxRate;
  final String? imageUrl;
  final String categoryId;
  final String? menuId;
  final String itemType;

  final List<Map<String, dynamic>> associatedTaxes;

  const MenuProduct({
    required this.id,
    required this.name,
    required this.price,
    required this.taxMode,
    required this.taxRate,
    required this.categoryId,
    this.imageUrl,
    this.menuId,
    this.itemType = 'standard',
    this.associatedTaxes = const [],
  });

  factory MenuProduct.fromMap(Map<String, dynamic> m) {
    double resolvedRate = 0;
    final taxList = <Map<String, dynamic>>[];
    final taxLinks = m['menu_item_taxes'];

    if (taxLinks is List) {
      for (final rawLink in taxLinks) {
        if (rawLink is! Map) continue;
        final rawTax = rawLink['taxes'];
        if (rawTax is Map) {
          taxList.add(Map<String, dynamic>.from(rawTax));
        }
      }
    }

    for (final tx in taxList) {
      final tax = TaxDef.fromMap(tx);
      if (!tax.isActive || tax.effectiveIsServiceFee) continue;
      resolvedRate += tax.rate;
    }

    return MenuProduct(
      id: m['id'] as String,
      name: (m['name'] ?? '') as String,
      price: (m['price'] is num) ? (m['price'] as num).toDouble() : 0.0,
      taxMode: m['tax_mode']?.toString() == 'inclusive'
          ? 'inclusive'
          : 'exclusive',
      taxRate: resolvedRate,
      categoryId: (m['category_id'] ?? '') as String,
      imageUrl: m['image_url'] as String?,
      menuId: m['menu_id'] as String?,
      itemType: m['item_type']?.toString() ?? 'standard',
      associatedTaxes: taxList,
    );
  }

  double calculateTaxRate(String origin) {
    final saleOrigin = parseSaleOrigin(origin);
    double total = 0;
    for (final tx in associatedTaxes) {
      final tax = TaxDef.fromMap(tx);
      if (!tax.isActive || tax.effectiveIsServiceFee) continue;
      if (tax.appliesTo(saleOrigin)) total += tax.rate;
    }
    return total;
  }

  double calculateFullTaxRate() {
    double total = 0;
    for (final tx in associatedTaxes) {
      final tax = TaxDef.fromMap(tx);
      if (!tax.isActive || tax.effectiveIsServiceFee) continue;
      total += tax.rate;
    }
    return total;
  }
}

enum MenuProductsMode { none, category, menu, all, search, favorites }

@immutable
class MenuBrowserState {
  final bool loading;
  final String? error;
  final List<MenuCategory> categories;
  final List<MenuDefinition> menus;
  final String? selectedCategoryId;
  final String? selectedMenuId;
  final List<MenuProduct> products;
  final MenuProductsMode productsMode;
  final String? loadedCategoryId;
  final String? loadedMenuId;
  final String search;
  final MenuProduct? selectedProduct;

  const MenuBrowserState({
    this.loading = false,
    this.error,
    this.categories = const [],
    this.menus = const [],
    this.selectedCategoryId,
    this.selectedMenuId,
    this.products = const [],
    this.productsMode = MenuProductsMode.none,
    this.loadedCategoryId,
    this.loadedMenuId,
    this.search = '',
    this.selectedProduct,
  });

  MenuBrowserState copyWith({
    bool? loading,
    String? error,
    List<MenuCategory>? categories,
    List<MenuDefinition>? menus,
    String? selectedCategoryId,
    String? selectedMenuId,
    List<MenuProduct>? products,
    MenuProductsMode? productsMode,
    String? loadedCategoryId,
    String? loadedMenuId,
    bool clearLoadedCategoryId = false,
    bool clearLoadedMenuId = false,
    String? search,
    MenuProduct? selectedProduct,
  }) {
    return MenuBrowserState(
      loading: loading ?? this.loading,
      error: error,
      categories: categories ?? this.categories,
      menus: menus ?? this.menus,
      selectedCategoryId: selectedCategoryId ?? this.selectedCategoryId,
      selectedMenuId: selectedMenuId ?? this.selectedMenuId,
      products: products ?? this.products,
      productsMode: productsMode ?? this.productsMode,
      loadedCategoryId: clearLoadedCategoryId
          ? null
          : (loadedCategoryId ?? this.loadedCategoryId),
      loadedMenuId: clearLoadedMenuId
          ? null
          : (loadedMenuId ?? this.loadedMenuId),
      search: search ?? this.search,
      selectedProduct: selectedProduct ?? this.selectedProduct,
    );
  }
}

final menuBrowserVmProvider =
    StateNotifierProvider<MenuBrowserViewModel, MenuBrowserState>((ref) {
      final client = Supabase.instance.client;
      ref.watch(sessionProvider.select((s) => s.activeBusinessId));
      return MenuBrowserViewModel(client, ref);
    });

class MenuBrowserViewModel extends StateNotifier<MenuBrowserState> {
  MenuBrowserViewModel(this._client, this.ref)
    : super(const MenuBrowserState()) {
    unawaited(_connectivity.initialize());
  }

  final SupabaseClient _client;
  final Ref ref;
  final ConnectivityService _connectivity = ConnectivityService();
  final OfflineCatalogService _offlineCatalog = OfflineCatalogService();

  /// Whether a background sync is already running (prevents duplicate syncs).
  bool _backgroundSyncRunning = false;

  static const _menuItemsSelect =
      'id,name,price,image_url,category_id,is_active,position,tax_mode,item_type,menu_item_taxes(tax_id,taxes(name,rate,is_active,is_service_fee,apply_on_zone,apply_on_manual,apply_on_quick,apply_on_delivery))';
  static const _menuListSelect =
      'id,name,price,image_url,category_id,menu_id,is_active,position,tax_mode,item_type,effective_tax_rate,menu_item_taxes(tax_id,taxes(name,rate,is_active,is_service_fee,apply_on_zone,apply_on_manual,apply_on_quick,apply_on_delivery))';

  Future<String> _resolveBusinessId() async {
    final sessionBusinessId = ref.read(sessionProvider).activeBusinessId;
    if (sessionBusinessId != null && sessionBusinessId.isNotEmpty) {
      return sessionBusinessId;
    }

    final resolved = await resolveBusinessIdOrNull(_client, 'auto');
    if (resolved == null || resolved.isEmpty) {
      throw Exception('No se pudo resolver el negocio actual');
    }

    return resolved;
  }

  Future<OfflineCatalogSnapshot> _ensureCatalogSnapshot({
    required String businessId,
    bool refresh = false,
  }) async {
    await _connectivity.initialize();
    final localSnapshot = await _offlineCatalog.loadSnapshot(businessId);
    final hasLocalData = localSnapshot?.hasData == true;

    if (!refresh && hasLocalData) {
      return localSnapshot!;
    }

    if (!_connectivity.isConnected && hasLocalData) {
      return localSnapshot!;
    }

    try {
      return await _refreshCatalogSnapshot(businessId);
    } catch (e) {
      if (hasLocalData) {
        debugPrint('MenuBrowserViewModel usando catalogo offline: $e');
        return localSnapshot!;
      }
      rethrow;
    }
  }

  /// Lightweight query: checks max(updated_at) and count from menu_items
  /// to determine if the local cache is still valid.
  Future<bool> _hasCatalogChanges({
    required String businessId,
    required OfflineCatalogSnapshot localSnapshot,
  }) async {
    try {
      // Single lightweight query: count + max updated_at
      final row = await _client
          .from('menu_items')
          .select('updated_at')
          .eq('business_id', businessId)
          .eq('is_active', true)
          .order('updated_at', ascending: false)
          .limit(1)
          .maybeSingle();

      // Also get count
      final countResult = await _client
          .from('menu_items')
          .select('id')
          .eq('business_id', businessId)
          .eq('is_active', true)
          .count();

      final remoteCount = countResult.count;
      final remoteUpdatedAt = row != null
          ? DateTime.tryParse(row['updated_at']?.toString() ?? '')
          : null;

      final localUpdatedAt = localSnapshot.lastProductUpdatedAt;
      final localCount = localSnapshot.productCount;

      // Changed if count differs or there's a newer updated_at
      if (remoteCount != localCount) {
        debugPrint('Catalog changed: count $localCount → $remoteCount');
        return true;
      }

      if (remoteUpdatedAt != null &&
          (localUpdatedAt == null || remoteUpdatedAt.isAfter(localUpdatedAt))) {
        debugPrint(
          'Catalog changed: updated_at $localUpdatedAt → $remoteUpdatedAt',
        );
        return true;
      }

      debugPrint('Catalog up-to-date (count=$remoteCount)');
      return false;
    } catch (e) {
      debugPrint('Error checking catalog changes: $e');
      // On error, assume changes to be safe
      return true;
    }
  }

  /// Extracts the max updated_at from a list of product maps.
  DateTime? _extractMaxUpdatedAt(List<Map<String, dynamic>> products) {
    DateTime? max;
    for (final p in products) {
      final raw = p['updated_at']?.toString();
      if (raw == null) continue;
      final dt = DateTime.tryParse(raw);
      if (dt != null && (max == null || dt.isAfter(max))) {
        max = dt;
      }
    }
    return max;
  }

  Future<OfflineCatalogSnapshot> _refreshCatalogSnapshot(
    String businessId,
  ) async {
    final existing = await _offlineCatalog.loadSnapshot(businessId);
    final results = await Future.wait<dynamic>([
      _client
          .from('categories')
          .select('id,name,color')
          .eq('business_id', businessId)
          .eq('is_active', true)
          .order('position', ascending: true),
      _client
          .from('menus')
          .select('id,name')
          .eq('business_id', businessId)
          .eq('is_active', true)
          .order('created_at', ascending: true),
      _client
          .from('menu_items')
          .select('$_menuItemsSelect,updated_at')
          .eq('business_id', businessId)
          .eq('is_active', true)
          .order('position', ascending: true)
          .order('name', ascending: true),
    ]);

    final categories = _rowsToMaps(results[0]);
    final menus = _rowsToMaps(results[1]);
    final products = _rowsToMaps(results[2]);
    final menuProducts =
        existing?.menuProducts ?? const <Map<String, dynamic>>[];
    final favoriteIds = existing?.favoriteProductIds ?? const <String>[];
    final maxUpdatedAt = _extractMaxUpdatedAt(products);

    await _offlineCatalog.saveSnapshot(
      businessId: businessId,
      categories: categories,
      menus: menus,
      products: products,
      menuProducts: menuProducts,
      favoriteProductIds: favoriteIds,
      lastProductUpdatedAt: maxUpdatedAt,
      productCount: products.length,
    );

    return OfflineCatalogSnapshot(
      savedAt: DateTime.now(),
      categories: categories,
      menus: menus,
      products: products,
      menuProducts: menuProducts,
      favoriteProductIds: favoriteIds,
      lastProductUpdatedAt: maxUpdatedAt,
      productCount: products.length,
    );
  }

  /// Triggers a background sync: checks for changes and refreshes state
  /// only if the catalog has actually changed in the database.
  void _syncCatalogInBackground(String businessId) {
    if (_backgroundSyncRunning) return;
    _backgroundSyncRunning = true;

    Future.microtask(() async {
      try {
        final localSnapshot = await _offlineCatalog.loadSnapshot(businessId);
        if (localSnapshot == null || !localSnapshot.hasData) {
          // No local data — full refresh already happened via loadAll
          return;
        }

        await _connectivity.initialize();
        if (!_connectivity.isConnected) return;

        final hasChanges = await _hasCatalogChanges(
          businessId: businessId,
          localSnapshot: localSnapshot,
        );

        if (!hasChanges) return;

        // Changes detected — do a full refresh
        final freshSnapshot = await _refreshCatalogSnapshot(businessId);

        // Update state only if still mounted
        if (!mounted) return;

        final categories = _parseCategories(freshSnapshot.categories);
        final menus = _parseMenus(freshSnapshot.menus);

        // Re-apply current view context with fresh data
        final currentMode = state.productsMode;
        final currentCategoryId = state.loadedCategoryId;

        List<MenuProduct> updatedProducts;
        if (currentMode == MenuProductsMode.category &&
            currentCategoryId != null) {
          updatedProducts = _parseProducts(
            freshSnapshot.productsByCategory(currentCategoryId),
          );
        } else if (currentMode == MenuProductsMode.all) {
          updatedProducts = _parseProducts(freshSnapshot.allProducts());
        } else if (currentMode == MenuProductsMode.search &&
            state.search.isNotEmpty) {
          updatedProducts = _parseProducts(
            freshSnapshot.searchProducts(state.search),
          );
        } else {
          updatedProducts = state.products;
        }

        state = state.copyWith(
          categories: categories,
          menus: menus,
          products: updatedProducts,
        );

        debugPrint('Background catalog sync completed');
      } catch (e) {
        debugPrint('Background catalog sync failed: $e');
      } finally {
        _backgroundSyncRunning = false;
      }
    });
  }

  Future<List<MenuProduct>> _loadMenuProductsSnapshot({
    required String businessId,
    required String menuId,
  }) async {
    final snapshot = await _offlineCatalog.loadSnapshot(businessId);
    final cachedRows = snapshot?.productsByMenu(menuId) ?? const [];

    if (cachedRows.isNotEmpty) {
      // Return cached immediately, refresh in background
      _refreshMenuProductsInBackground(businessId: businessId, menuId: menuId);
      return _parseProducts(cachedRows);
    }

    await _connectivity.initialize();
    if (!_connectivity.isConnected) {
      return const [];
    }

    return await _fetchAndCacheMenuProducts(
      businessId: businessId,
      menuId: menuId,
    );
  }

  Future<List<MenuProduct>> _fetchAndCacheMenuProducts({
    required String businessId,
    required String menuId,
  }) async {
    final rows = await _client
        .from('v_menu_items_list')
        .select(_menuListSelect)
        .eq('business_id', businessId)
        .eq('menu_id', menuId)
        .eq('is_active', true)
        .order('position', ascending: true)
        .order('name', ascending: true);

    final freshRows = _rowsToMaps(rows);
    if (freshRows.isEmpty) {
      return const [];
    }

    final snapshot = await _offlineCatalog.loadSnapshot(businessId);
    final preserved = snapshot?.menuProducts ?? const <Map<String, dynamic>>[];
    final mergedRows = [
      ...preserved.where((item) => item['menu_id']?.toString() != menuId),
      ...freshRows,
    ];

    await _offlineCatalog.saveSnapshot(
      businessId: businessId,
      menuProducts: mergedRows,
    );

    return _parseProducts(freshRows);
  }

  void _refreshMenuProductsInBackground({
    required String businessId,
    required String menuId,
  }) {
    Future.microtask(() async {
      try {
        await _connectivity.initialize();
        if (!_connectivity.isConnected) return;

        final freshProducts = await _fetchAndCacheMenuProducts(
          businessId: businessId,
          menuId: menuId,
        );

        if (!mounted) return;

        // Update state only if we're still viewing this menu
        if (state.productsMode == MenuProductsMode.menu &&
            state.loadedMenuId == menuId) {
          state = state.copyWith(products: freshProducts);
        }
      } catch (e) {
        debugPrint('Background menu products refresh failed: $e');
      }
    });
  }

  List<Map<String, dynamic>> _rowsToMaps(dynamic rows) {
    if (rows is! List) {
      return const [];
    }

    return rows
        .map((row) => Map<String, dynamic>.from(row as Map))
        .toList(growable: false);
  }

  List<MenuCategory> _parseCategories(List<Map<String, dynamic>> rows) =>
      rows.map(MenuCategory.fromMap).toList(growable: false);

  List<MenuDefinition> _parseMenus(List<Map<String, dynamic>> rows) =>
      rows.map(MenuDefinition.fromMap).toList(growable: false);

  List<MenuProduct> _parseProducts(List<Map<String, dynamic>> rows) =>
      rows.map(MenuProduct.fromMap).toList(growable: false);

  Future<void> _restoreProductsForCurrentContext() async {
    if (state.loadedMenuId != null && state.loadedMenuId!.isNotEmpty) {
      await loadProductsByMenu(state.loadedMenuId!);
      return;
    }
    if (state.loadedCategoryId != null && state.loadedCategoryId!.isNotEmpty) {
      await loadProductsByCategory(state.loadedCategoryId!);
      return;
    }
    if (state.selectedCategoryId != null &&
        state.selectedCategoryId!.isNotEmpty) {
      await loadProductsByCategory(state.selectedCategoryId!);
      return;
    }
    if (state.selectedMenuId != null && state.selectedMenuId!.isNotEmpty) {
      await loadProductsByMenu(state.selectedMenuId!);
      return;
    }
    await loadAllProducts();
  }

  Future<void> loadAll({
    String? preselectCategoryId,
    String? preselectMenuId,
  }) async {
    try {
      final businessId = await _resolveBusinessId();

      // 1. Try to show cached data immediately (no loading spinner)
      final localSnapshot = await _offlineCatalog.loadSnapshot(businessId);
      final hasLocalData = localSnapshot?.hasData == true;

      if (hasLocalData) {
        _applyCatalogSnapshot(
          localSnapshot!,
          preselectCategoryId: preselectCategoryId,
          preselectMenuId: preselectMenuId,
        );
        // 2. Check for changes in background — UI already responsive
        _syncCatalogInBackground(businessId);
      } else {
        // No cache — must fetch from network (show loading)
        state = state.copyWith(loading: true, error: null);
        final snapshot = await _ensureCatalogSnapshot(
          businessId: businessId,
          refresh: true,
        );
        _applyCatalogSnapshot(
          snapshot,
          preselectCategoryId: preselectCategoryId,
          preselectMenuId: preselectMenuId,
        );
      }
    } catch (e) {
      state = state.copyWith(
        loading: false,
        error: 'No se pudieron cargar categorias: $e',
      );
    }
  }

  /// Applies a catalog snapshot to state without network calls.
  void _applyCatalogSnapshot(
    OfflineCatalogSnapshot snapshot, {
    String? preselectCategoryId,
    String? preselectMenuId,
  }) {
    final categories = _parseCategories(snapshot.categories);
    final menus = _parseMenus(snapshot.menus);
    final selectedCategory =
        preselectCategoryId ??
        (categories.isNotEmpty ? categories.first.id : null);
    final selectedMenu =
        preselectMenuId ?? (menus.isNotEmpty ? menus.first.id : null);
    final initialProducts = selectedCategory == null
        ? const <MenuProduct>[]
        : _parseProducts(snapshot.productsByCategory(selectedCategory));

    state = state.copyWith(
      loading: false,
      error: null,
      categories: categories,
      menus: menus,
      selectedCategoryId: selectedCategory,
      selectedMenuId: selectedMenu,
      products: initialProducts,
      productsMode: selectedCategory == null
          ? MenuProductsMode.none
          : MenuProductsMode.category,
      loadedCategoryId: selectedCategory,
      clearLoadedMenuId: true,
      selectedProduct: null,
    );
  }

  Future<void> loadAllProducts() async {
    try {
      state = state.copyWith(loading: true, error: null, selectedProduct: null);
      final businessId = await _resolveBusinessId();
      final snapshot = await _ensureCatalogSnapshot(businessId: businessId);

      state = state.copyWith(
        loading: false,
        error: null,
        products: _parseProducts(snapshot.allProducts()),
        productsMode: MenuProductsMode.all,
        clearLoadedCategoryId: true,
        clearLoadedMenuId: true,
        selectedProduct: null,
      );
    } catch (e) {
      state = state.copyWith(
        loading: false,
        error: 'No se pudo cargar el menu: $e',
      );
    }
  }

  Future<void> loadFavoriteProducts() async {
    OfflineCatalogSnapshot? snapshot;

    try {
      state = state.copyWith(loading: true, error: null, selectedProduct: null);
      final businessId = await _resolveBusinessId();
      snapshot = await _ensureCatalogSnapshot(businessId: businessId);
      final allProducts = _parseProducts(snapshot.allProducts());

      if (allProducts.isEmpty) {
        state = state.copyWith(
          loading: false,
          error: null,
          products: const [],
          productsMode: MenuProductsMode.favorites,
          clearLoadedCategoryId: true,
          clearLoadedMenuId: true,
          selectedProduct: null,
        );
        return;
      }

      await _connectivity.initialize();
      if (!_connectivity.isConnected) {
        state = state.copyWith(
          loading: false,
          error: null,
          products: _parseProducts(snapshot.favoriteProducts()),
          productsMode: MenuProductsMode.favorites,
          clearLoadedCategoryId: true,
          clearLoadedMenuId: true,
          selectedProduct: null,
        );
        return;
      }

      final productIds = allProducts.map((p) => p.id).toList(growable: false);
      final orderRows = await _client
          .from('order_items')
          .select('product_id, qty, created_at')
          .inFilter('product_id', productIds)
          .order('created_at', ascending: false)
          .limit(500);

      final scoreByProduct = <String, double>{};
      for (final row in (orderRows as List<dynamic>)) {
        final map = row as Map<String, dynamic>;
        final productId = map['product_id'] as String?;
        if (productId == null || productId.isEmpty) {
          continue;
        }
        final qty = (map['qty'] is num) ? (map['qty'] as num).toDouble() : 1.0;
        scoreByProduct[productId] = (scoreByProduct[productId] ?? 0) + qty;
      }

      final favorites =
          allProducts
              .where((product) => scoreByProduct.containsKey(product.id))
              .toList()
            ..sort(
              (a, b) => (scoreByProduct[b.id] ?? 0).compareTo(
                scoreByProduct[a.id] ?? 0,
              ),
            );

      await _offlineCatalog.saveSnapshot(
        businessId: businessId,
        favoriteProductIds: favorites
            .map((product) => product.id)
            .toList(growable: false),
      );

      state = state.copyWith(
        loading: false,
        error: null,
        products: favorites,
        productsMode: MenuProductsMode.favorites,
        clearLoadedCategoryId: true,
        clearLoadedMenuId: true,
        selectedProduct: null,
      );
    } catch (e) {
      final fallback = snapshot?.favoriteProducts() ?? const [];
      if (fallback.isNotEmpty) {
        state = state.copyWith(
          loading: false,
          error: null,
          products: _parseProducts(fallback),
          productsMode: MenuProductsMode.favorites,
          clearLoadedCategoryId: true,
          clearLoadedMenuId: true,
          selectedProduct: null,
        );
        return;
      }

      state = state.copyWith(
        loading: false,
        error: 'No se pudieron cargar los favoritos: $e',
      );
    }
  }

  Future<void> loadProductsByCategory(String categoryId) async {
    try {
      if (categoryId.trim().isEmpty) {
        await loadAllProducts();
        return;
      }

      final businessId = await _resolveBusinessId();
      state = state.copyWith(
        loading: true,
        error: null,
        selectedCategoryId: categoryId,
        clearLoadedMenuId: true,
        selectedProduct: null,
      );

      final snapshot = await _ensureCatalogSnapshot(businessId: businessId);
      final products = _parseProducts(snapshot.productsByCategory(categoryId));

      state = state.copyWith(
        loading: false,
        error: null,
        products: products,
        productsMode: MenuProductsMode.category,
        loadedCategoryId: categoryId,
        selectedMenuId: state.selectedMenuId,
        selectedProduct: null,
      );
    } catch (e) {
      state = state.copyWith(
        loading: false,
        error: 'No se pudieron cargar los productos: $e',
      );
    }
  }

  Future<void> loadDefaultMenuProducts() async {
    final selectedMenuId =
        state.selectedMenuId ??
        (state.menus.isNotEmpty ? state.menus.first.id : null);
    if (selectedMenuId == null || selectedMenuId.isEmpty) {
      state = state.copyWith(
        products: const [],
        productsMode: MenuProductsMode.none,
        clearLoadedMenuId: true,
        error: null,
      );
      return;
    }

    await loadProductsByMenu(selectedMenuId);
  }

  Future<void> loadProductsByMenu(String menuId) async {
    try {
      if (menuId.trim().isEmpty) {
        await loadDefaultMenuProducts();
        return;
      }

      final businessId = await _resolveBusinessId();
      state = state.copyWith(
        loading: true,
        error: null,
        selectedMenuId: menuId,
        clearLoadedCategoryId: true,
        selectedProduct: null,
      );

      final products = await _loadMenuProductsSnapshot(
        businessId: businessId,
        menuId: menuId,
      );

      state = state.copyWith(
        loading: false,
        error: null,
        products: products,
        productsMode: MenuProductsMode.menu,
        loadedMenuId: menuId,
        selectedProduct: null,
      );
    } catch (e) {
      state = state.copyWith(
        loading: false,
        error: 'No se pudieron cargar los productos del menu: $e',
      );
    }
  }

  Future<void> searchProducts(String text) async {
    final q = text.trim();
    state = state.copyWith(search: q, selectedProduct: null);

    if (q.isEmpty) {
      await _restoreProductsForCurrentContext();
      return;
    }

    try {
      state = state.copyWith(loading: true, error: null);
      final businessId = await _resolveBusinessId();
      final snapshot = await _ensureCatalogSnapshot(businessId: businessId);

      state = state.copyWith(
        loading: false,
        error: null,
        products: _parseProducts(snapshot.searchProducts(q)),
        productsMode: MenuProductsMode.search,
        clearLoadedCategoryId: true,
        clearLoadedMenuId: true,
        selectedProduct: null,
      );
    } catch (e) {
      state = state.copyWith(
        loading: false,
        error: 'No se pudieron buscar productos: $e',
      );
    }
  }

  void startAddProduct(MenuProduct p) {
    state = state.copyWith(selectedProduct: p);
  }

  void cancelAddProduct() {
    state = state.copyWith(selectedProduct: null);
  }
}
