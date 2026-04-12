import 'dart:convert';

import 'package:flutter/foundation.dart';

import 'package:mangopos/core/storage/storage_service.dart';

@immutable
class OfflineCatalogSnapshot {
  const OfflineCatalogSnapshot({
    required this.savedAt,
    required this.categories,
    required this.menus,
    required this.products,
    required this.menuProducts,
    required this.favoriteProductIds,
    this.lastProductUpdatedAt,
    this.productCount = 0,
  });

  final DateTime savedAt;
  final List<Map<String, dynamic>> categories;
  final List<Map<String, dynamic>> menus;
  final List<Map<String, dynamic>> products;
  final List<Map<String, dynamic>> menuProducts;
  final List<String> favoriteProductIds;

  /// Tracks the most recent updated_at from menu_items for delta detection.
  final DateTime? lastProductUpdatedAt;

  /// Tracks the number of active products for quick change detection.
  final int productCount;

  bool get hasData =>
      categories.isNotEmpty ||
      menus.isNotEmpty ||
      products.isNotEmpty ||
      menuProducts.isNotEmpty;

  List<Map<String, dynamic>> productsByCategory(String categoryId) {
    if (categoryId.trim().isEmpty) {
      return allProducts();
    }
    return products
        .where((item) => item['category_id']?.toString() == categoryId)
        .map(_copyMap)
        .toList(growable: false);
  }

  List<Map<String, dynamic>> productsByMenu(String menuId) {
    return menuProducts
        .where((item) => item['menu_id']?.toString() == menuId)
        .map(_copyMap)
        .toList(growable: false);
  }

  List<Map<String, dynamic>> searchProducts(String query) {
    final q = query.trim().toLowerCase();
    if (q.isEmpty) {
      return const [];
    }

    final filtered = products
        .where((item) {
          final name = item['name']?.toString().toLowerCase() ?? '';
          return name.contains(q);
        })
        .map(_copyMap)
        .toList(growable: false);
    filtered.sort(_sortByName);
    return filtered;
  }

  List<Map<String, dynamic>> favoriteProducts() {
    if (favoriteProductIds.isEmpty) {
      return const [];
    }

    final productById = <String, Map<String, dynamic>>{
      for (final item in products) item['id']?.toString() ?? '': item,
    }..remove('');

    return favoriteProductIds
        .map((id) => productById[id])
        .whereType<Map<String, dynamic>>()
        .map(_copyMap)
        .toList(growable: false);
  }

  List<Map<String, dynamic>> allProducts() =>
      products.map(_copyMap).toList(growable: false);

  factory OfflineCatalogSnapshot.fromJson(Map<String, dynamic> json) {
    return OfflineCatalogSnapshot(
      savedAt:
          DateTime.tryParse(json['saved_at']?.toString() ?? '') ??
          DateTime.fromMillisecondsSinceEpoch(0),
      categories: _toMapList(json['categories']),
      menus: _toMapList(json['menus']),
      products: _toMapList(json['products']),
      menuProducts: _toMapList(json['menu_products']),
      favoriteProductIds: _toStringList(json['favorite_product_ids']),
      lastProductUpdatedAt:
          DateTime.tryParse(json['last_product_updated_at']?.toString() ?? ''),
      productCount: json['product_count'] as int? ?? 0,
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'saved_at': savedAt.toIso8601String(),
      'categories': categories.map(_copyMap).toList(growable: false),
      'menus': menus.map(_copyMap).toList(growable: false),
      'products': products.map(_copyMap).toList(growable: false),
      'menu_products': menuProducts.map(_copyMap).toList(growable: false),
      'favorite_product_ids': favoriteProductIds,
      if (lastProductUpdatedAt != null)
        'last_product_updated_at': lastProductUpdatedAt!.toIso8601String(),
      'product_count': productCount,
    };
  }

  static List<Map<String, dynamic>> _toMapList(dynamic value) {
    if (value is! List) {
      return const [];
    }
    return value
        .whereType<Map>()
        .map((item) => Map<String, dynamic>.from(item))
        .toList(growable: false);
  }

  static List<String> _toStringList(dynamic value) {
    if (value is! List) {
      return const [];
    }
    return value
        .map((item) => item?.toString() ?? '')
        .where((item) => item.isNotEmpty)
        .toList(growable: false);
  }

  static Map<String, dynamic> _copyMap(Map<String, dynamic> value) =>
      Map<String, dynamic>.from(value);

  static int _sortByName(Map<String, dynamic> a, Map<String, dynamic> b) {
    final left = a['name']?.toString().toLowerCase() ?? '';
    final right = b['name']?.toString().toLowerCase() ?? '';
    return left.compareTo(right);
  }
}

class OfflineCatalogService {
  OfflineCatalogService._();

  static final OfflineCatalogService _instance = OfflineCatalogService._();

  factory OfflineCatalogService() => _instance;

  Future<StorageService> get _storage async => StorageService.getInstance();

  String _snapshotKey(String businessId) => 'offline_catalog_$businessId';

  Future<OfflineCatalogSnapshot?> loadSnapshot(String businessId) async {
    final storage = await _storage;
    final raw = await storage.read(_snapshotKey(businessId));
    if (raw == null || raw.isEmpty) {
      return null;
    }

    try {
      return OfflineCatalogSnapshot.fromJson(
        Map<String, dynamic>.from(jsonDecode(raw) as Map),
      );
    } catch (e) {
      debugPrint('OfflineCatalogService.loadSnapshot error: $e');
      return null;
    }
  }

  Future<void> saveSnapshot({
    required String businessId,
    List<Map<String, dynamic>>? categories,
    List<Map<String, dynamic>>? menus,
    List<Map<String, dynamic>>? products,
    List<Map<String, dynamic>>? menuProducts,
    List<String>? favoriteProductIds,
    DateTime? lastProductUpdatedAt,
    int? productCount,
  }) async {
    final storage = await _storage;
    final existing = await loadSnapshot(businessId);
    final snapshot = OfflineCatalogSnapshot(
      savedAt: DateTime.now(),
      categories: categories ?? existing?.categories ?? const [],
      menus: menus ?? existing?.menus ?? const [],
      products: products ?? existing?.products ?? const [],
      menuProducts: menuProducts ?? existing?.menuProducts ?? const [],
      favoriteProductIds:
          favoriteProductIds ?? existing?.favoriteProductIds ?? const [],
      lastProductUpdatedAt:
          lastProductUpdatedAt ?? existing?.lastProductUpdatedAt,
      productCount: productCount ?? existing?.productCount ?? 0,
    );
    await storage.write(_snapshotKey(businessId), jsonEncode(snapshot.toJson()));
  }
}
