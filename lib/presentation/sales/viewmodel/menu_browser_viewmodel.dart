import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

@immutable
class MenuCategory {
  final String id;
  final String name;
  const MenuCategory({required this.id, required this.name});

  factory MenuCategory.fromMap(Map<String, dynamic> m) =>
      MenuCategory(id: m['id'] as String, name: (m['name'] ?? '') as String);
}

@immutable
class MenuProduct {
  final String id;
  final String name;
  final double price;
  final String? imageUrl;
  final String categoryId;

  const MenuProduct({
    required this.id,
    required this.name,
    required this.price,
    required this.categoryId,
    this.imageUrl,
  });

  factory MenuProduct.fromMap(Map<String, dynamic> m) => MenuProduct(
    id: m['id'] as String,
    name: (m['name'] ?? '') as String,
    price: (m['price'] is num) ? (m['price'] as num).toDouble() : 0.0,
    categoryId: (m['category_id'] ?? '') as String,
    imageUrl: m['image_url'] as String?,
  );
}

enum MenuProductsMode { none, category, all, search, favorites }

@immutable
class MenuBrowserState {
  final bool loading;
  final String? error;
  final List<MenuCategory> categories;
  final String? selectedCategoryId;
  final List<MenuProduct> products;
  final MenuProductsMode productsMode;
  final String? loadedCategoryId;
  final String search;
  final MenuProduct? selectedProduct;

  const MenuBrowserState({
    this.loading = false,
    this.error,
    this.categories = const [],
    this.selectedCategoryId,
    this.products = const [],
    this.productsMode = MenuProductsMode.none,
    this.loadedCategoryId,
    this.search = '',
    this.selectedProduct,
  });

  MenuBrowserState copyWith({
    bool? loading,
    String? error,
    List<MenuCategory>? categories,
    String? selectedCategoryId,
    List<MenuProduct>? products,
    MenuProductsMode? productsMode,
    String? loadedCategoryId,
    bool clearLoadedCategoryId = false,
    String? search,
    MenuProduct? selectedProduct,
  }) {
    return MenuBrowserState(
      loading: loading ?? this.loading,
      error: error,
      categories: categories ?? this.categories,
      selectedCategoryId: selectedCategoryId ?? this.selectedCategoryId,
      products: products ?? this.products,
      productsMode: productsMode ?? this.productsMode,
      loadedCategoryId: clearLoadedCategoryId
          ? null
          : (loadedCategoryId ?? this.loadedCategoryId),
      search: search ?? this.search,
      selectedProduct: selectedProduct ?? this.selectedProduct,
    );
  }
}

/// Proveedor del ViewModel
final menuBrowserVmProvider =
    StateNotifierProvider<MenuBrowserViewModel, MenuBrowserState>((ref) {
      final client = Supabase.instance.client;
      return MenuBrowserViewModel(client);
    });

class MenuBrowserViewModel extends StateNotifier<MenuBrowserState> {
  MenuBrowserViewModel(this._client) : super(const MenuBrowserState());

  final SupabaseClient _client;

  Future<void> loadAll({String? preselectCategoryId}) async {
    try {
      state = state.copyWith(loading: true, error: null);

      final cats = await _client
          .from('categories')
          .select('id,name,business_id')
          .eq('is_active', true)
          .order('position', ascending: true);

      final rawCategories = cats as List<dynamic>;
      final categories = rawCategories
          .map((e) => MenuCategory.fromMap(e as Map<String, dynamic>))
          .toList();

      // Selecciona primera categoría si no hay una preseleccionada
      final selected =
          preselectCategoryId ??
          (categories.isNotEmpty ? categories.first.id : null);

      state = state.copyWith(
        loading: false,
        categories: categories,
        selectedCategoryId: selected,
        selectedProduct: null,
      );

      if (selected != null) {
        await loadProductsByCategory(selected);
      } else {
        state = state.copyWith(
          products: const [],
          productsMode: MenuProductsMode.none,
          clearLoadedCategoryId: true,
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

      final rows = await _client
          .from('menu_items')
          .select('id,name,price,image_url,category_id,is_active,position')
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

      final rows = await _client
          .from('menu_items')
          .select('id,name,price,image_url,category_id,is_active,position')
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
      state = state.copyWith(
        loading: true,
        error: null,
        selectedCategoryId: categoryId,
        selectedProduct: null,
      );

      final rows = await _client
          .from('menu_items')
          .select('id,name,price,image_url,category_id,is_active')
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
        selectedProduct: null,
      );
    } catch (e) {
      state = state.copyWith(
        loading: false,
        error: 'No se pudieron cargar los productos: $e',
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

      final rows = await _client
          .from('menu_items')
          .select('id,name,price,image_url,category_id,is_active')
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
