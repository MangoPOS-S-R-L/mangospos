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

@immutable
class MenuBrowserState {
  final bool loading;
  final String? error;
  final List<MenuCategory> categories;
  final String? selectedCategoryId;
  final List<MenuProduct> products;
  final String search;
  final MenuProduct? selectedProduct;

  const MenuBrowserState({
    this.loading = false,
    this.error,
    this.categories = const [],
    this.selectedCategoryId,
    this.products = const [],
    this.search = '',
    this.selectedProduct,
  });

  MenuBrowserState copyWith({
    bool? loading,
    String? error,
    List<MenuCategory>? categories,
    String? selectedCategoryId,
    List<MenuProduct>? products,
    String? search,
    MenuProduct? selectedProduct,
  }) {
    return MenuBrowserState(
      loading: loading ?? this.loading,
      error: error,
      categories: categories ?? this.categories,
      selectedCategoryId: selectedCategoryId ?? this.selectedCategoryId,
      products: products ?? this.products,
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
          .select('id,name')
          .eq('is_active', true)
          .order('position', ascending: true);

      final categories = (cats as List<dynamic>)
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
        state = state.copyWith(products: const []);
      }
    } catch (e) {
      state = state.copyWith(
        loading: false,
        error: 'No se pudieron cargar categorías: $e',
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
