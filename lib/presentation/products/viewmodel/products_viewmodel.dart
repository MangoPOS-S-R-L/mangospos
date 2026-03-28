import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:mangopos/data/models/category.dart' as model;
import 'package:mangopos/data/repositories/category_repository.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:uuid/uuid.dart';

import '../../../data/repositories/products_repository.dart';

final productsRepositoryProvider = Provider<ProductsRepository>((ref) {
  return ProductsRepository(Supabase.instance.client);
});

final productsViewModelProvider = ChangeNotifierProvider<ProductsViewModel>((
  ref,
) {
  return ProductsViewModel(ref.read(productsRepositoryProvider));
});

class ProductsViewModel extends ChangeNotifier {
  final SupabaseClient _supabase = Supabase.instance.client;
  final ProductsRepository _repository;
  final CategoryRepository _categoryRepository = CategoryRepository();

  ProductsViewModel(this._repository);

  List<Map<String, dynamic>> _products = [];
  List<Map<String, dynamic>> _categories = [];
  List<Map<String, dynamic>> _menus = [];
  bool _isLoading = false;
  String? _businessId;
  String? _error;
  String _searchQuery = '';
  String? _selectedCategoryFilterId;
  String? _selectedMenuFilterId;

  List<Map<String, dynamic>> get products => _products;
  List<Map<String, dynamic>> get filteredProducts {
    final query = _searchQuery.trim().toLowerCase();
    return _products
        .where((product) {
          final name = product['name']?.toString().toLowerCase() ?? '';
          final sku = product['sku']?.toString().toLowerCase() ?? '';
          final barcode = product['barcode']?.toString().toLowerCase() ?? '';
          final categoryId = product['category_id']?.toString();
          final links =
              product['menu_item_links'] as List<dynamic>? ?? const [];
          String? firstMenuId;
          if (links.isNotEmpty) {
            final firstLink = links.first;
            if (firstLink is Map<String, dynamic>) {
              firstMenuId = firstLink['menu_id']?.toString();
            }
          }

          final matchesSearch =
              query.isEmpty ||
              name.contains(query) ||
              sku.contains(query) ||
              barcode.contains(query);
          final matchesCategory =
              _selectedCategoryFilterId == null ||
              categoryId == _selectedCategoryFilterId;
          final matchesMenu =
              _selectedMenuFilterId == null ||
              firstMenuId == _selectedMenuFilterId;

          return matchesSearch && matchesCategory && matchesMenu;
        })
        .toList(growable: false);
  }

  List<Map<String, dynamic>> get categories => _categories;
  List<Map<String, dynamic>> get menus => _menus;
  bool get isLoading => _isLoading;
  String? get error => _error;
  String get searchQuery => _searchQuery;
  String? get selectedCategoryFilterId => _selectedCategoryFilterId;
  String? get selectedMenuFilterId => _selectedMenuFilterId;

  Future<void> init() async {
    _isLoading = true;
    _error = null;
    notifyListeners();

    try {
      _businessId = await _repository.getBusinessIdForCurrentUser();
      if (_businessId == null) {
        throw Exception(
          'No se encontró negocio activo para este usuario. Verifica membresía.',
        );
      }

      await Future.wait([_fetchProducts(), _fetchCategories(), _fetchMenus()]);
    } catch (e) {
      _error = 'Error cargando productos: $e';
      debugPrint('Error initializing ProductsViewModel: $e');
    } finally {
      _isLoading = false;
      notifyListeners();
    }
  }

  void setSearchQuery(String value) {
    _searchQuery = value;
    notifyListeners();
  }

  void setCategoryFilter(String? categoryId) {
    _selectedCategoryFilterId = categoryId == null || categoryId.isEmpty
        ? null
        : categoryId;
    notifyListeners();
  }

  void setMenuFilter(String? menuId) {
    _selectedMenuFilterId = menuId == null || menuId.isEmpty ? null : menuId;
    notifyListeners();
  }

  Future<void> _fetchProducts() async {
    if (_businessId == null) return;
    _products = await _repository.getProducts(_businessId!);
  }

  Future<void> _fetchCategories() async {
    if (_businessId == null) return;
    _categories = await _repository.getCategories(_businessId!);
  }

  Future<void> _fetchMenus() async {
    if (_businessId == null) return;
    _menus = await _repository.getMenus(_businessId!);
  }

  Future<void> addProduct({
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
    File? imageFile,
    Uint8List? imageBytes,
    List<String> taxIds = const [],
  }) async {
    if (_businessId == null) return;

    try {
      String? imagePath;
      String? imageUrl;

      if (imageFile != null || imageBytes != null) {
        final ext = _guessExt(imageFile?.path ?? 'upload.jpg');
        final key =
            'items/$_businessId/${DateTime.now().millisecondsSinceEpoch}.$ext';
        final storage = _supabase.storage.from('menu-items');

        if (imageBytes != null) {
          await storage.uploadBinary(
            key,
            imageBytes,
            fileOptions: const FileOptions(upsert: true),
          );
        } else {
          await storage.upload(
            key,
            imageFile!,
            fileOptions: const FileOptions(upsert: true),
          );
        }

        imagePath = key;
        imageUrl = storage.getPublicUrl(key);
      }

      await _repository.createProduct(
        businessId: _businessId!,
        name: name,
        price: price,
        categoryId: categoryId,
        taxMode: taxMode,
        sku: sku,
        description: description,
        menuId: menuId,
        cost: cost,
        barcode: barcode,
        hasVariants: hasVariants,
        isActive: isActive,
        itemType: itemType,
        imagePath: imagePath,
        imageUrl: imageUrl,
        taxIds: taxIds,
      );

      await _fetchProducts();
      _error = null;
      notifyListeners();
    } catch (e) {
      debugPrint('Error adding product: $e');
      rethrow;
    }
  }

  Future<void> updateProduct({
    required String id,
    required String name,
    required double price,
    required String? categoryId,
    String taxMode = 'exclusive',
    String? sku,
    required bool isActive,
    String? description,
    String? menuId,
    double? cost,
    String? barcode,
    bool hasVariants = false,
    String itemType = 'standard',
    File? imageFile,
    Uint8List? imageBytes,
    List<String> taxIds = const [],
  }) async {
    try {
      String? imagePath;
      String? imageUrl;

      if (imageFile != null || imageBytes != null) {
        final ext = _guessExt(imageFile?.path ?? 'upload.jpg');
        final key =
            'items/$_businessId/${DateTime.now().millisecondsSinceEpoch}.$ext';
        final storage = _supabase.storage.from('menu-items');

        if (imageBytes != null) {
          await storage.uploadBinary(
            key,
            imageBytes,
            fileOptions: const FileOptions(upsert: true),
          );
        } else {
          await storage.upload(
            key,
            imageFile!,
            fileOptions: const FileOptions(upsert: true),
          );
        }

        imagePath = key;
        imageUrl = storage.getPublicUrl(key);
      }

      await _repository.updateProduct(
        id: id,
        name: name,
        price: price,
        categoryId: categoryId,
        isActive: isActive,
        taxMode: taxMode,
        sku: sku,
        description: description,
        menuId: menuId,
        cost: cost,
        barcode: barcode,
        hasVariants: hasVariants,
        itemType: itemType,
        imagePath: imagePath,
        imageUrl: imageUrl,
        taxIds: taxIds,
      );

      await _fetchProducts();
      _error = null;
      notifyListeners();
    } catch (e) {
      debugPrint('Error updating product: $e');
      rethrow;
    }
  }

  Future<void> toggleAvailability(String id, bool currentValue) async {
    try {
      await _repository.toggleAvailability(id: id, isActive: !currentValue);
      await _fetchProducts();
      _error = null;
      notifyListeners();
    } catch (e) {
      debugPrint('Error toggling product availability: $e');
      rethrow;
    }
  }

  Future<void> deleteProduct(String id) async {
    try {
      await _repository.deleteProduct(id);
      await _fetchProducts();
      _error = null;
      notifyListeners();
    } catch (e) {
      debugPrint('Error deleting product: $e');
      rethrow;
    }
  }

  Future<Map<String, dynamic>> createCategory({required String name}) async {
    if (_businessId == null) {
      throw Exception('No hay negocio activo para crear categorías');
    }

    final normalizedName = name.trim();
    if (normalizedName.isEmpty) {
      throw Exception('El nombre de la categoría es requerido');
    }

    final existing = _categories.where((c) {
      final categoryName = c['name']?.toString().trim().toLowerCase() ?? '';
      return categoryName == normalizedName.toLowerCase();
    });
    if (existing.isNotEmpty) {
      return Map<String, dynamic>.from(existing.first);
    }

    final nextPosition =
        _categories.fold<int>(0, (maxPos, category) {
          final raw = category['position'];
          final pos = raw is int
              ? raw
              : int.tryParse(raw?.toString() ?? '') ?? 0;
          return pos > maxPos ? pos : maxPos;
        }) +
        1;

    final created = await _categoryRepository.create(
      model.Category(
        id: const Uuid().v4(),
        businessId: _businessId!,
        name: normalizedName,
        position: nextPosition,
        isActive: true,
      ),
    );

    await _fetchCategories();
    notifyListeners();

    return {
      'id': created.id,
      'business_id': created.businessId,
      'name': created.name,
      'position': created.position,
      'is_active': created.isActive,
      'created_at': created.createdAt?.toIso8601String(),
    };
  }

  String _guessExt(String path) {
    final p = path.toLowerCase();
    if (p.endsWith('.png')) return 'png';
    if (p.endsWith('.webp')) return 'webp';
    if (p.endsWith('.jpeg')) return 'jpeg';
    if (p.endsWith('.jpg')) return 'jpg';
    return 'jpg';
  }
}
