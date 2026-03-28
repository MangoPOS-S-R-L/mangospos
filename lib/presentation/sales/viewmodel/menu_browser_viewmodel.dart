import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import '../../../services/session/session_controller.dart';
import '../../../data/utils/business_id_resolver.dart';

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
  });

  factory MenuProduct.fromMap(Map<String, dynamic> m) {
    double resolvedRate = 0;
    final rawEffectiveRate = m['effective_tax_rate'];
    if (rawEffectiveRate is num) {
      resolvedRate = rawEffectiveRate.toDouble();
    } else if (rawEffectiveRate != null) {
      resolvedRate = double.tryParse(rawEffectiveRate.toString()) ?? 0;
    } else {
      final taxLinks = m['menu_item_taxes'];
      if (taxLinks is List) {
        for (final rawLink in taxLinks) {
          if (rawLink is! Map) continue;
          final rawTax = rawLink['taxes'];
          if (rawTax is Map) {
            final rate = rawTax['rate'];
            if (rate is num) {
              resolvedRate += rate.toDouble();
            } else if (rate != null) {
              resolvedRate += double.tryParse(rate.toString()) ?? 0;
            }
          }
        }
      }
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
    );
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

/// Proveedor del ViewModel
final menuBrowserVmProvider =
    StateNotifierProvider<MenuBrowserViewModel, MenuBrowserState>((ref) {
      final client = Supabase.instance.client;
      // Escuchar cambios en el negocio activo para forzar recreación si cambia
      ref.watch(sessionProvider.select((s) => s.activeBusinessId));
      return MenuBrowserViewModel(client, ref);
    });

class MenuBrowserViewModel extends StateNotifier<MenuBrowserState> {
  MenuBrowserViewModel(this._client, this.ref)
    : super(const MenuBrowserState());

  final SupabaseClient _client;
  final Ref ref;
  static const _menuItemsSelect =
      'id,name,price,image_url,category_id,is_active,position,tax_mode,item_type,menu_item_taxes(tax_id,taxes(rate))';
  static const _menuListSelect =
      'id,name,price,image_url,category_id,menu_id,is_active,position,tax_mode,item_type,effective_tax_rate';
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

  Future<void> loadAll({
    String? preselectCategoryId,
    String? preselectMenuId,
  }) async {
    try {
      state = state.copyWith(loading: true, error: null);
      final businessId = await _resolveBusinessId();

      final cats = await _client
          .from('categories')
          .select('id,name,color')
          .eq('business_id', businessId)
          .eq('is_active', true)
          .order('position', ascending: true);
      final menusRaw = await _client
          .from('menus')
          .select('id,name')
          .eq('business_id', businessId)
          .eq('is_active', true)
          .order('created_at', ascending: true);

      final rawCategories = cats as List<dynamic>;
      final categories = rawCategories
          .map((e) => MenuCategory.fromMap(e as Map<String, dynamic>))
          .toList();
      final menus = (menusRaw as List<dynamic>)
          .map((e) => MenuDefinition.fromMap(e as Map<String, dynamic>))
          .toList();

      final selectedCategory =
          preselectCategoryId ??
          (categories.isNotEmpty ? categories.first.id : null);
      final selectedMenu =
          preselectMenuId ?? (menus.isNotEmpty ? menus.first.id : null);

      state = state.copyWith(
        loading: false,
        categories: categories,
        menus: menus,
        selectedCategoryId: selectedCategory,
        selectedMenuId: selectedMenu,
        selectedProduct: null,
      );

      if (selectedCategory != null) {
        await loadProductsByCategory(selectedCategory);
      } else {
        state = state.copyWith(
          products: const [],
          productsMode: MenuProductsMode.none,
          clearLoadedCategoryId: true,
          clearLoadedMenuId: true,
        );
      }
    } catch (e) {
      state = state.copyWith(
        loading: false,
        error: 'No se pudieron cargar categorías: $e',
      );
    }
  }

  Future<void> loadAllProducts() async {
    try {
      state = state.copyWith(loading: true, error: null, selectedProduct: null);
      final businessId = await _resolveBusinessId();

      final rows = await _client
          .from('menu_items')
          .select(_menuItemsSelect)
          .eq('business_id', businessId)
          .eq('is_active', true)
          .order('position', ascending: true)
          .order('name', ascending: true);

      final products = (rows as List<dynamic>)
          .map((e) => MenuProduct.fromMap(e as Map<String, dynamic>))
          .toList();

      state = state.copyWith(
        loading: false,
        products: products,
        productsMode: MenuProductsMode.all,
        clearLoadedCategoryId: true,
        clearLoadedMenuId: true,
        selectedProduct: null,
      );
    } catch (e) {
      state = state.copyWith(
        loading: false,
        error: 'No se pudo cargar el menú: $e',
      );
    }
  }

  Future<void> loadFavoriteProducts() async {
    try {
      state = state.copyWith(loading: true, error: null, selectedProduct: null);
      final businessId = await _resolveBusinessId();

      final rows = await _client
          .from('menu_items')
          .select(_menuItemsSelect)
          .eq('business_id', businessId)
          .eq('is_active', true)
          .order('position', ascending: true)
          .order('name', ascending: true);

      final allProducts = (rows as List<dynamic>)
          .map((e) => MenuProduct.fromMap(e as Map<String, dynamic>))
          .toList();

      if (allProducts.isEmpty) {
        state = state.copyWith(
          loading: false,
          products: const [],
          productsMode: MenuProductsMode.favorites,
          clearLoadedCategoryId: true,
          clearLoadedMenuId: true,
        );
        return;
      }

      final productIds = allProducts.map((p) => p.id).toList();
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
        if (productId == null || productId.isEmpty) continue;
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

      state = state.copyWith(
        loading: false,
        products: favorites,
        productsMode: MenuProductsMode.favorites,
        clearLoadedCategoryId: true,
        clearLoadedMenuId: true,
        selectedProduct: null,
      );
    } catch (e) {
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

      final rows = await _client
          .from('menu_items')
          .select(_menuItemsSelect)
          .eq('business_id', businessId)
          .eq('is_active', true)
          .eq('category_id', categoryId)
          .order('position', ascending: true);

      final products = (rows as List<dynamic>)
          .map((e) => MenuProduct.fromMap(e as Map<String, dynamic>))
          .toList();

      state = state.copyWith(
        loading: false,
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

      final rows = await _client
          .from('v_menu_items_list')
          .select(_menuListSelect)
          .eq('business_id', businessId)
          .eq('menu_id', menuId)
          .eq('is_active', true)
          .order('position', ascending: true)
          .order('name', ascending: true);

      final products = (rows as List<dynamic>)
          .map((e) => MenuProduct.fromMap(e as Map<String, dynamic>))
          .toList();

      state = state.copyWith(
        loading: false,
        products: products,
        productsMode: MenuProductsMode.menu,
        loadedMenuId: menuId,
        selectedProduct: null,
      );
    } catch (e) {
      state = state.copyWith(
        loading: false,
        error: 'No se pudieron cargar los productos del menú: $e',
      );
    }
  }

  Future<void> searchProducts(String text) async {
    final q = text.trim();
    state = state.copyWith(search: q, selectedProduct: null);

    if (q.isEmpty) {
      // Si se borra la búsqueda, recarga por categoría seleccionada
      if (state.selectedCategoryId != null) {
        await loadProductsByCategory(state.selectedCategoryId!);
      }
      return;
    }

    try {
      state = state.copyWith(loading: true, error: null);
      final businessId = await _resolveBusinessId();

      final rows = await _client
          .from('menu_items')
          .select(_menuItemsSelect)
          .eq('business_id', businessId)
          .eq('is_active', true)
          .ilike('name', '%$q%')
          .order('name', ascending: true);

      final products = (rows as List<dynamic>)
          .map((e) => MenuProduct.fromMap(e as Map<String, dynamic>))
          .toList();

      state = state.copyWith(
        loading: false,
        products: products,
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

  // UI helpers: selección de producto para agregar
  void startAddProduct(MenuProduct p) {
    state = state.copyWith(selectedProduct: p);
  }

  void cancelAddProduct() {
    state = state.copyWith(selectedProduct: null);
  }
}
