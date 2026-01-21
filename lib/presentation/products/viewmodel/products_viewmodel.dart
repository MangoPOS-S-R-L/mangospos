import 'dart:io';
import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

final productsViewModelProvider = ChangeNotifierProvider<ProductsViewModel>((
  ref,
) {
  return ProductsViewModel();
});

class ProductsViewModel extends ChangeNotifier {
  final SupabaseClient _supabase = Supabase.instance.client;

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
      await _fetchBusinessId();
      if (_businessId != null) {
        await Future.wait([
          _fetchProducts(),
          _fetchCategories(),
          _fetchMenus(),
        ]);
      }
    } catch (e) {
      debugPrint('Error initializing ProductsViewModel: $e');
    } finally {
      _isLoading = false;
      notifyListeners();
    }
  }

  Future<void> _fetchBusinessId() async {
    final user = _supabase.auth.currentUser;
    if (user == null) return;

    try {
      final ub = await _supabase
          .from('user_businesses')
          .select('business_id')
          .eq('user_id', user.id)
          .order('created_at', ascending: true)
          .limit(1)
          .maybeSingle();

      if (ub != null && ub['business_id'] != null) {
        _businessId = ub['business_id'].toString();
      }
    } catch (e) {
      debugPrint('Error fetching business ID: $e');
    }
  }

  Future<void> _fetchProducts() async {
    if (_businessId == null) return;
    try {
      final response = await _supabase
          .from('menu_items')
          .select('*, categories(name)')
          .eq('business_id', _businessId!)
          .order('created_at', ascending: false);

      _products = List<Map<String, dynamic>>.from(response);
    } catch (e) {
      debugPrint('Error fetching products: $e');
    }
  }

  Future<void> _fetchCategories() async {
    if (_businessId == null) return;
    try {
      final response = await _supabase
          .from('categories')
          .select()
          .eq('business_id', _businessId!)
          .order('name');

      _categories = List<Map<String, dynamic>>.from(response);
    } catch (e) {
      debugPrint('Error fetching categories: $e');
    }
  }

  Future<void> _fetchMenus() async {
    if (_businessId == null) return;
    try {
      final response = await _supabase
          .from('menus')
          .select()
          .eq('business_id', _businessId!)
          .order('name');

      _menus = List<Map<String, dynamic>>.from(response);
    } catch (e) {
      debugPrint('Error fetching menus: $e');
    }
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

      final res = await _supabase
          .from('menu_items')
          .insert({
            'business_id': _businessId,
            'name': name,
            'price': price,
            'category_id': categoryId,
            'sku': sku,
            'is_active': isActive,
            'description': description,
            'cost': cost,
            'barcode': barcode,
            'has_variants': hasVariants,
            'image_path': imagePath,
            'image_url': imageUrl,
            'product_type': productType, // New field
          })
          .select()
          .single();

      final newItemId = res['id'] as String;

      // Link menu
      if (menuId != null) {
        await _supabase.from('menu_item_menus').insert({
          'menu_item_id': newItemId,
          'menu_id': menuId,
        });
      }

      // Link taxes
      if (taxIds.isNotEmpty) {
        final taxLinks = taxIds
            .map((tid) => {'menu_item_id': newItemId, 'tax_id': tid})
            .toList();
        await _supabase.from('menu_item_taxes').insert(taxLinks);
      }

      await _fetchProducts();
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

      final updates = {
        'name': name,
        'price': price,
        'category_id': categoryId,
        'sku': sku,
        'is_active': isActive,
        'description': description,
        'cost': cost,
        'barcode': barcode,
        'has_variants': hasVariants,
        'product_type': productType, // New field
      };

      if (imagePath != null) {
        updates['image_path'] = imagePath;
        updates['image_url'] = imageUrl;
      }

      await _supabase.from('menu_items').update(updates).eq('id', id);

      // Update menu link (simple approach: delete all and re-add if needed, or upsert)
      // For simplicity, we'll delete existing for this item and add new if menuId is present
      await _supabase.from('menu_item_menus').delete().eq('menu_item_id', id);
      if (menuId != null) {
        await _supabase.from('menu_item_menus').insert({
          'menu_item_id': id,
          'menu_id': menuId,
        });
      }

      // Update taxes
      await _supabase.from('menu_item_taxes').delete().eq('menu_item_id', id);
      if (taxIds.isNotEmpty) {
        final taxLinks = taxIds
            .map((tid) => {'menu_item_id': id, 'tax_id': tid})
            .toList();
        await _supabase.from('menu_item_taxes').insert(taxLinks);
      }

      await _fetchProducts();
      notifyListeners();
    } catch (e) {
      debugPrint('Error updating product: $e');
      rethrow;
    }
  }

  Future<void> deleteProduct(String id) async {
    try {
      await _supabase.from('menu_items').delete().eq('id', id);
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
