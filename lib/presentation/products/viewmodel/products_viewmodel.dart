import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

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

  ProductsViewModel(this._repository);

  List<Map<String, dynamic>> _products = [];
  List<Map<String, dynamic>> _categories = [];
  List<Map<String, dynamic>> _menus = [];
  bool _isLoading = false;
  String? _businessId;

  List<Map<String, dynamic>> get products => _products;
  List<Map<String, dynamic>> get categories => _categories;
  List<Map<String, dynamic>> get menus => _menus;
  bool get isLoading => _isLoading;

  Future<void> init() async {
    _isLoading = true;
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
      debugPrint('Error initializing ProductsViewModel: $e');
    } finally {
      _isLoading = false;
      notifyListeners();
    }
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
    String? sku,
    String? description,
    String? menuId,
    double? cost,
    String? barcode,
    bool hasVariants = false,
    bool isActive = true,
    File? imageFile,
    Uint8List? imageBytes,
    List<String> taxIds = const [],
    String? productType,
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
        sku: sku,
        description: description,
        menuId: menuId,
        cost: cost,
        barcode: barcode,
        hasVariants: hasVariants,
        isActive: isActive,
        imagePath: imagePath,
        imageUrl: imageUrl,
        taxIds: taxIds,
      );

      await _fetchProducts();
      notifyListeners();
    } catch (e) {
      debugPrint('Error adding product: $e | productType=$productType');
      rethrow;
    }
  }

  Future<void> updateProduct({
    required String id,
    required String name,
    required double price,
    required String? categoryId,
    String? sku,
    required bool isActive,
    String? description,
    String? menuId,
    double? cost,
    String? barcode,
    bool hasVariants = false,
    File? imageFile,
    Uint8List? imageBytes,
    List<String> taxIds = const [],
    String? productType,
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
        sku: sku,
        description: description,
        menuId: menuId,
        cost: cost,
        barcode: barcode,
        hasVariants: hasVariants,
        imagePath: imagePath,
        imageUrl: imageUrl,
        taxIds: taxIds,
      );

      await _fetchProducts();
      notifyListeners();
    } catch (e) {
      debugPrint('Error updating product: $e | productType=$productType');
      rethrow;
    }
  }

  Future<void> toggleAvailability(String id, bool currentValue) async {
    try {
      await _repository.toggleAvailability(id: id, isActive: !currentValue);
      await _fetchProducts();
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
      notifyListeners();
    } catch (e) {
      debugPrint('Error deleting product: $e');
      rethrow;
    }
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
