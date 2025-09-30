// lib/presentation/.../menu items/state/menu_items_state.dart
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../../../../../data/models/menu_item.dart';
import '../../../../../../data/models/category.dart' as model;
import '../../../../../../data/models/menu.dart';

class MenuItemsState {
  final AsyncValue<List<MenuItem>> data;
  final AsyncValue<List<model.Category>> categories;
  final AsyncValue<List<Menu>> menus;

  final String search;
  final String? filterMenuId;
  final String? filterCategoryId;
  final String? selectedId;

  const MenuItemsState({
    this.data = const AsyncData([]),
    this.categories = const AsyncData([]),
    this.menus = const AsyncData([]),
    this.search = '',
    this.filterMenuId,
    this.filterCategoryId,
    this.selectedId,
  });

  bool get loading => data.isLoading || categories.isLoading || menus.isLoading;

  String? get error => data.hasError ? data.error.toString() : null;

  List<MenuItem> get list => data.value ?? [];

  List<MenuItem> get filtered {
    final q = search.trim().toLowerCase();
    return list.where((it) {
      final okSearch =
          q.isEmpty ||
          it.name.toLowerCase().contains(q) ||
          (it.sku ?? '').toLowerCase().contains(q) ||
          (it.barcode ?? '').toLowerCase().contains(q);
      final okMenu = filterMenuId == null || it.menuId == filterMenuId;
      final okCat =
          filterCategoryId == null || it.categoryId == filterCategoryId;
      return okSearch && okMenu && okCat;
    }).toList();
  }

  List<model.Category> get categoriesList => categories.value ?? [];
  List<Menu> get menusList => menus.value ?? [];

  MenuItemsState copyWith({
    AsyncValue<List<MenuItem>>? data,
    AsyncValue<List<model.Category>>? categories,
    AsyncValue<List<Menu>>? menus,
    String? search,
    String? filterMenuId,
    String? filterCategoryId,
    String? selectedId,
    bool clearSelected = false,
  }) {
    return MenuItemsState(
      data: data ?? this.data,
      categories: categories ?? this.categories,
      menus: menus ?? this.menus,
      search: search ?? this.search,
      filterMenuId: filterMenuId ?? this.filterMenuId,
      filterCategoryId: filterCategoryId ?? this.filterCategoryId,
      selectedId: clearSelected ? null : (selectedId ?? this.selectedId),
    );
  }
}
