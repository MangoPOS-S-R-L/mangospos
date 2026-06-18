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

  /// Etiqueta de presentación (Botella/Trago/Shot…). El catálogo genera
  /// sub-pestañas por categoría a partir de las etiquetas distintas.
  final String? presentation;

  /// Si true, este producto descuenta inventario al venderse. Para
  /// productos sin tracking (false), el grid permite agregar siempre.
  final bool isInventoryTracked;

  /// Si true, el cajero puede agregar el producto al pedido aunque
  /// stock <= 0 (la deuda se salda con la próxima compra). Si false,
  /// el grid bloquea el tap cuando v_menu_items_stock indica agotado.
  final bool allowNegativeSale;

  final List<Map<String, dynamic>> associatedTaxes;

  /// Cuando este tile es una OFERTA vendible (itemType == 'offer'): se vende
  /// como UNA línea a precio original con el descuento del deal (el descuento se
  /// ve abajo en los totales).
  ///  - offerPromoId: id de la promoción (atribución).
  ///  - offerLineQty: cantidad de la única línea (ej. 4 para un 4x3).
  ///  - offerDiscount: descuento total del deal (ej. 250 para un 4x3 de 250).
  /// En tiles normales son null.
  final String? offerPromoId;
  final int? offerLineQty;
  final double? offerDiscount;

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
    this.presentation,
    this.isInventoryTracked = false,
    this.allowNegativeSale = false,
    this.associatedTaxes = const [],
    this.offerPromoId,
    this.offerLineQty,
    this.offerDiscount,
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

    bool toBool(dynamic v) {
      if (v is bool) return v;
      final s = v?.toString().toLowerCase();
      return s == 'true' || s == 't' || s == '1';
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
      presentation: (m['presentation'] as String?)?.trim().isEmpty == true
          ? null
          : m['presentation'] as String?,
      isInventoryTracked: toBool(m['is_inventory_tracked']),
      allowNegativeSale: toBool(m['allow_negative_sale']),
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

enum MenuProductsMode { none, category, menu, all, search, favorites, offers }

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
  // Stock disponible por menu_item_id. Si el producto es tracked y tiene
  // receta 1:1 (o multi-ingrediente reducible a unidades), aquí está la
  // cantidad disponible. Si el producto no es tracked, no aparece en el
  // mapa — la UI no muestra badge.
  final Map<String, num> stockByProductId;

  /// Etiqueta de presentación filtrada en la categoría actual (sub-pestaña
  /// activa). null = "Todas". Se resetea al cambiar de categoría.
  final String? selectedPresentation;

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
    this.stockByProductId = const {},
    this.selectedPresentation,
  });

  /// Etiquetas de presentación distintas en los productos cargados,
  /// ordenadas. Usado por la UI para construir las sub-pestañas.
  List<String> get presentationTabs {
    final set = <String>{};
    for (final p in products) {
      final v = p.presentation?.trim();
      if (v != null && v.isNotEmpty) set.add(v);
    }
    final list = set.toList()..sort();
    return list;
  }

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
    Map<String, num>? stockByProductId,
    String? selectedPresentation,
    bool clearSelectedPresentation = false,
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
      stockByProductId: stockByProductId ?? this.stockByProductId,
      selectedPresentation: clearSelectedPresentation
          ? null
          : (selectedPresentation ?? this.selectedPresentation),
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

  /// Realtime: escucha cambios en inventory_stock y menu_items para que
  /// el cajero vea badges y disponibilidad actualizados sin recargar.
  /// Crítico cuando dos tablets venden en paralelo, o cuando auto-86
  /// desactiva un producto que se agotó.
  RealtimeChannel? _stockChannel;
  Timer? _stockRefreshDebounce;
  Timer? _catalogRefreshDebounce;
  static const _stockRefreshDelay = Duration(milliseconds: 500);

  @override
  void dispose() {
    _stockChannel?.unsubscribe();
    _stockChannel = null;
    _stockRefreshDebounce?.cancel();
    _stockRefreshDebounce = null;
    _catalogRefreshDebounce?.cancel();
    _catalogRefreshDebounce = null;
    super.dispose();
  }

  /// Suscribe (o re-suscribe) el canal realtime. Idempotente.
  /// - inventory_stock: cualquier cambio → refrescar mapa de stock (badges).
  /// - menu_items UPDATE de is_active: auto-86 activó/desactivó un producto
  ///   → recargar catálogo para que aparezca/desaparezca del grid.
  ///
  /// PRD 7 Fase 4.1 — channel scoped por businessId + filter explícito en
  /// menu_items (que sí tiene business_id directo). inventory_stock no
  /// tiene la columna (se relaciona vía warehouse_id → warehouses.business_id),
  /// así que confía en RLS.
  void _subscribeStockRealtime(String businessId) {
    if (_stockChannel != null) return;
    _stockChannel = _client
        .channel('rt:inventory_realtime:$businessId')
        .onPostgresChanges(
          event: PostgresChangeEvent.all,
          schema: 'public',
          table: 'inventory_stock',
          // inventory_stock no tiene business_id directo. RLS filtra.
          callback: (_) => _scheduleStockRefresh(),
        )
        .onPostgresChanges(
          event: PostgresChangeEvent.update,
          schema: 'public',
          table: 'menu_items',
          filter: PostgresChangeFilter(
            type: PostgresChangeFilterType.eq,
            column: 'business_id',
            value: businessId,
          ),
          callback: (payload) {
            // Solo recargar catálogo cuando is_active cambió (auto-86).
            // Cambios cosméticos (precio, nombre) los maneja otro flujo.
            final oldActive = payload.oldRecord['is_active'];
            final newActive = payload.newRecord['is_active'];
            if (oldActive != newActive) {
              _scheduleCatalogRefresh();
            }
          },
        )
        .subscribe();
  }

  /// Debounce: si llegan muchos eventos seguidos (ej. una orden con 10
  /// items dispara 10 movements + recálculos), agrupamos en un solo
  /// refresh ~500ms después del último cambio.
  void _scheduleStockRefresh() {
    _stockRefreshDebounce?.cancel();
    _stockRefreshDebounce = Timer(_stockRefreshDelay, () {
      _loadStockMap();
    });
  }

  /// Recarga el catálogo completo (productos visibles + stock map) cuando
  /// auto-86 activa/desactiva un producto. Cancela el stock debounce
  /// porque loadAll ya invoca _loadStockMap al final.
  void _scheduleCatalogRefresh() {
    _stockRefreshDebounce?.cancel();
    _catalogRefreshDebounce?.cancel();
    _catalogRefreshDebounce = Timer(_stockRefreshDelay, () {
      unawaited(loadAll(
        preselectCategoryId: state.selectedCategoryId,
        preselectMenuId: state.selectedMenuId,
      ));
    });
  }

  static const _menuItemsSelect =
      'id,name,price,image_url,category_id,is_active,position,tax_mode,item_type,presentation,is_inventory_tracked,allow_negative_sale,barcode,sku,menu_item_taxes(tax_id,taxes(name,rate,is_active,is_service_fee,apply_on_zone,apply_on_manual,apply_on_quick,apply_on_delivery))';
  static const _menuListSelect =
      'id,name,price,image_url,category_id,menu_id,is_active,position,tax_mode,item_type,presentation,is_inventory_tracked,allow_negative_sale,effective_tax_rate,barcode,sku,menu_item_taxes(tax_id,taxes(name,rate,is_active,is_service_fee,apply_on_zone,apply_on_manual,apply_on_quick,apply_on_delivery))';

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
      // Stock disponible por producto. Lo cargamos después del catálogo
      // (no bloqueante: si la vista no existe o falla, ignoramos).
      unawaited(_loadStockMap());
      // Suscribir a cambios de stock en tiempo real para que los badges
      // se actualicen cuando otra tablet venda/reciba inventario.
      _subscribeStockRealtime(businessId);
    } catch (e) {
      state = state.copyWith(
        loading: false,
        error: 'No se pudieron cargar categorias: $e',
      );
    }
  }

  /// Hook público para refrescar el stock map. Lo llamamos desde el flujo
  /// de "Enviar a cocina" para que el badge se actualice en el acto en vez
  /// de esperar al próximo `loadAll()`.
  Future<void> refreshStock() => _loadStockMap();

  /// Lee `v_menu_items_stock` y mergea las cantidades disponibles en el
  /// estado. La vista solo retorna productos `is_inventory_tracked = true`
  /// con recetas 1:1; los productos no tracked NO aparecen en el mapa y
  /// no muestran badge en la UI.
  Future<void> _loadStockMap() async {
    try {
      final rows = await _client
          .from('v_menu_items_stock')
          .select('menu_item_id, available_units');
      final map = <String, num>{};
      for (final row in (rows as List)) {
        final m = Map<String, dynamic>.from(row as Map);
        final id = m['menu_item_id']?.toString();
        final units = m['available_units'];
        if (id != null && units != null) {
          if (units is num) {
            map[id] = units;
          } else {
            final parsed = num.tryParse(units.toString());
            if (parsed != null) map[id] = parsed;
          }
        }
      }
      state = state.copyWith(stockByProductId: map);
    } catch (_) {
      // Vista no aplicada o sin permisos: ignoramos silenciosamente.
      // El catálogo sigue funcionando sin badge.
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

  /// Convierte un `time` de Postgres ("HH:mm:ss" / "HH:mm") a minutos desde
  /// medianoche para evaluar la franja horaria (happy hour). null = sin valor.
  int? _promoTimeToMinutes(dynamic value) {
    final raw = value?.toString();
    if (raw == null || raw.isEmpty) return null;
    final parts = raw.split(':');
    if (parts.length < 2) return null;
    final hour = int.tryParse(parts[0]);
    final minute = int.tryParse(parts[1]);
    if (hour == null || minute == null) return null;
    if (hour < 0 || hour > 23 || minute < 0 || minute > 59) return null;
    return hour * 60 + minute;
  }

  /// Carga las OFERTAS vendibles como tiles del catálogo (pestaña "Ofertas").
  /// Cada oferta activa + auto-aplicar que apunta a producto(s) genera un tile
  /// por producto; al tocarlo se agregan las líneas del producto (ver
  /// SalesViewModel.addOfferDeal) y el motor aplica el descuento.
  Future<void> loadOffers() async {
    try {
      state = state.copyWith(loading: true, error: null, selectedProduct: null);
      final businessId = await _resolveBusinessId();

      // Productos del negocio (para precio/impuestos del componente).
      final snapshot = await _ensureCatalogSnapshot(businessId: businessId);
      final byId = <String, MenuProduct>{
        for (final p in _parseProducts(snapshot.allProducts())) p.id: p,
      };

      // Ofertas activas que apuntan a productos. NO se filtra por auto_apply:
      // el tile aplica el descuento vía el precio de oferta, no el motor.
      final promosRaw = await _client
          .from('promotions')
          .select(
            'id,name,promo_type,discount_type,discount_value,'
            'target_scope,applies_to,target_ids,buy_quantity,pay_quantity,'
            'start_time,end_time,is_active',
          )
          .eq('business_id', businessId)
          .eq('is_active', true);

      final now = DateTime.now();
      final nowMin = now.hour * 60 + now.minute;

      final tiles = <MenuProduct>[];
      for (final raw in List<Map<String, dynamic>>.from(promosRaw)) {
        final scope =
            (raw['target_scope'] ?? raw['applies_to'])?.toString() ?? 'all';
        if (scope != 'product') continue;
        final promoId = raw['id']?.toString();
        if (promoId == null) continue;

        // Happy hour: si la oferta tiene franja horaria, ocúltala fuera de ese
        // rango (hora local). end < start => cruza la medianoche.
        final startMin = _promoTimeToMinutes(raw['start_time']);
        final endMin = _promoTimeToMinutes(raw['end_time']);
        if (startMin != null && endMin != null && startMin != endMin) {
          final inWindow = startMin < endMin
              ? (nowMin >= startMin && nowMin < endMin)
              : (nowMin >= startMin || nowMin < endMin);
          if (!inWindow) continue;
        }

        final type =
            (raw['promo_type'] ?? raw['discount_type'])?.toString() ??
            'percentage';
        final buyQty = (raw['buy_quantity'] as num?)?.toInt() ?? 2;
        final payQty = (raw['pay_quantity'] as num?)?.toInt() ?? 1;
        final value = (raw['discount_value'] as num?)?.toDouble() ?? 0;
        final targetIds = (raw['target_ids'] as List?)
                ?.map((e) => e?.toString() ?? '')
                .where((e) => e.isNotEmpty)
                .toList(growable: false) ??
            const <String>[];

        // Etiqueta del deal (badge en el nombre del tile/línea).
        String dealPrefix() {
          switch (type) {
            case 'bogo':
              return '${buyQty}x$payQty';
            case 'fixed':
              return '-RD\$${value.toStringAsFixed(0)}';
            case 'bundle_price':
              return 'RD\$${value.toStringAsFixed(0)}';
            case 'percentage':
            default:
              return '${value.toStringAsFixed(0)}%';
          }
        }

        for (final pid in targetIds) {
          final base = byId[pid];
          if (base == null) continue;

          // UNA línea a precio original (cantidad N) con el descuento del deal.
          // El descuento se ve abajo en los totales.
          final int lineQty;
          final double discount;
          switch (type) {
            case 'bogo':
              // Ej. 4x3 de 250 → qty 4, descuento = 1×250 = 250.
              lineQty = buyQty < 1 ? 1 : buyQty;
              final pay = payQty < 1 ? 1 : payQty;
              final free = (lineQty - pay).clamp(0, lineQty);
              discount = free * base.price;
              break;
            case 'fixed':
              lineQty = 1;
              discount = value.clamp(0, base.price).toDouble();
              break;
            case 'bundle_price':
              lineQty = 1;
              discount = (base.price - value).clamp(0, base.price).toDouble();
              break;
            case 'percentage':
            default:
              lineQty = 1;
              discount = (base.price * (value.clamp(0, 100) / 100.0))
                  .clamp(0, base.price)
                  .toDouble();
          }

          tiles.add(
            MenuProduct(
              id: base.id,
              name: '${dealPrefix()} ${base.name}',
              price: base.price,
              taxMode: base.taxMode,
              taxRate: base.taxRate,
              categoryId: base.categoryId,
              imageUrl: base.imageUrl,
              menuId: base.menuId,
              itemType: 'offer',
              isInventoryTracked: base.isInventoryTracked,
              allowNegativeSale: base.allowNegativeSale,
              associatedTaxes: base.associatedTaxes,
              offerPromoId: promoId,
              offerLineQty: lineQty,
              offerDiscount: double.parse(discount.toStringAsFixed(2)),
            ),
          );
        }
      }

      state = state.copyWith(
        loading: false,
        error: null,
        products: tiles,
        productsMode: MenuProductsMode.offers,
        clearLoadedCategoryId: true,
        clearLoadedMenuId: true,
        selectedProduct: null,
      );
    } catch (e) {
      state = state.copyWith(
        loading: false,
        error: 'No se pudieron cargar las ofertas: $e',
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
        // Resetear sub-pestaña al cambiar de categoría (evita filtro pegado).
        clearSelectedPresentation: true,
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

  /// Filtra el grid de la categoría actual por etiqueta de presentación.
  /// `null` = "Todas".
  void setSelectedPresentation(String? presentation) {
    if (presentation == null) {
      state = state.copyWith(clearSelectedPresentation: true);
    } else {
      state = state.copyWith(selectedPresentation: presentation);
    }
  }
}
