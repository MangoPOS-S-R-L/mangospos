import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:mangopos/data/models/category.dart' as model;
import 'package:mangopos/data/repositories/category_repository.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:uuid/uuid.dart';
import 'package:excel/excel.dart';
import 'package:file_picker/file_picker.dart';
import 'package:path_provider/path_provider.dart';

import '../../../data/repositories/products_repository.dart';
import '../../../data/repositories/printing_v2_repository.dart';

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
  int _loadGeneration = 0;

  List<Map<String, dynamic>> get products => _products;
  List<Map<String, dynamic>> get filteredProducts {
    final query = _searchQuery.trim().toLowerCase();
    return _products
        .where((product) {
          final name = product['name']?.toString().toLowerCase() ?? '';
          final sku = product['sku']?.toString().toLowerCase() ?? '';
          final barcode = product['barcode']?.toString().toLowerCase() ?? '';
          final categoryId = product['category_id']?.toString();
          final links = _asList(product['menu_item_links']);
          final menuIds = links
              .map(_asMap)
              .map((link) => link['menu_id']?.toString())
              .whereType<String>()
              .where((id) => id.isNotEmpty)
              .toSet();

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
              menuIds.contains(_selectedMenuFilterId);

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

  Future<void> init({String? businessId}) async {
    final generation = ++_loadGeneration;
    _isLoading = true;
    _error = null;
    notifyListeners();

    try {
      final resolvedBusinessId = businessId?.trim().isNotEmpty == true
          ? businessId!.trim()
          : await _repository.getBusinessIdForCurrentUser();
      if (resolvedBusinessId == null || resolvedBusinessId.isEmpty) {
        throw Exception(
          'No se encontró negocio activo para este usuario. Verifica membresía.',
        );
      }

      final results = await Future.wait([
        _repository.getProducts(resolvedBusinessId),
        _repository.getCategories(resolvedBusinessId),
        _repository.getMenus(resolvedBusinessId),
      ]);
      if (generation != _loadGeneration) return;

      final businessChanged = _businessId != resolvedBusinessId;
      _businessId = resolvedBusinessId;
      _products = results[0];
      _categories = results[1];
      _menus = results[2];
      if (businessChanged) {
        _searchQuery = '';
        _selectedCategoryFilterId = null;
        _selectedMenuFilterId = null;
      }
      _sanitizeFilters();
    } catch (e) {
      if (generation != _loadGeneration) return;
      _error = 'Error cargando productos: $e';
      debugPrint('Error initializing ProductsViewModel: $e');
    } finally {
      if (generation == _loadGeneration) {
        _isLoading = false;
        notifyListeners();
      }
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

  /// Resetea búsqueda y filtros de categoría/menú en una sola pasada.
  /// Útil para el botón "Limpiar filtros" cuando el cajero ya no recuerda
  /// qué filtros tiene puestos.
  void clearAllFilters() {
    _searchQuery = '';
    _selectedCategoryFilterId = null;
    _selectedMenuFilterId = null;
    notifyListeners();
  }

  bool get hasActiveFilters =>
      _searchQuery.isNotEmpty ||
      _selectedCategoryFilterId != null ||
      _selectedMenuFilterId != null;

  Future<void> _fetchProducts() async {
    if (_businessId == null) return;
    _products = await _repository.getProducts(_businessId!);
  }

  Future<void> _fetchCategories() async {
    if (_businessId == null) return;
    _categories = await _repository.getCategories(_businessId!);
  }

  void _sanitizeFilters() {
    final categoryIds = _categories
        .map((category) => category['id']?.toString())
        .whereType<String>()
        .toSet();
    final menuIds = _menus
        .map((menu) => menu['id']?.toString())
        .whereType<String>()
        .toSet();

    if (_selectedCategoryFilterId != null &&
        !categoryIds.contains(_selectedCategoryFilterId)) {
      _selectedCategoryFilterId = null;
    }
    if (_selectedMenuFilterId != null &&
        !menuIds.contains(_selectedMenuFilterId)) {
      _selectedMenuFilterId = null;
    }
  }

  static List<dynamic> _asList(dynamic value) {
    return value is List ? value : const [];
  }

  static Map<String, dynamic> _asMap(dynamic value) {
    if (value is Map<String, dynamic>) return value;
    if (value is Map) return Map<String, dynamic>.from(value);
    return const <String, dynamic>{};
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
    String? printAreaCode,
    // Printing v2 (Slice 4.B): N:M de áreas. Si no se provee, no se
    // toca la tabla menu_item_print_areas.
    List<String>? printAreaIds,
    File? imageFile,
    Uint8List? imageBytes,
    List<String> taxIds = const [],
    // 👇 inventario por producto
    bool isInventoryTracked = false,
    double initialStock = 0,
    bool allowNegativeSale = false,
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

      final created = await _repository.createProduct(
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
        printAreaCode: printAreaCode,
        imagePath: imagePath,
        imageUrl: imageUrl,
        taxIds: taxIds,
        isInventoryTracked: isInventoryTracked,
        initialStock: initialStock,
        allowNegativeSale: allowNegativeSale,
      );

      // Printing v2 (Slice 4.B): persistir N:M con el id recién creado.
      final newId = created['id']?.toString();
      if (printAreaIds != null && newId != null && newId.isNotEmpty) {
        try {
          final mipa = MenuItemPrintAreaRepository(_supabase);
          await mipa.setAreasForMenuItem(newId, printAreaIds);
        } catch (e) {
          // No bloquear el flujo si el N:M falla; el legacy print_area_code
          // ya quedó persistido en createProduct y cubre el caso 1-de-1.
          debugPrint('addProduct: fallo guardando N:M áreas: $e');
        }
      }

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
    String? printAreaCode,
    // Printing v2 (Slice 4.B): N:M de áreas. NULL = no tocar; lista vacía
    // = limpiar todas las asignaciones.
    List<String>? printAreaIds,
    File? imageFile,
    Uint8List? imageBytes,
    List<String> taxIds = const [],
    // 👇 inventario por producto. Si difiere del valor actual del producto,
    // se llama la RPC para sincronizar.
    bool? isInventoryTracked,
    double initialStock = 0,
    bool? allowNegativeSale,
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
        printAreaCode: printAreaCode,
        imagePath: imagePath,
        imageUrl: imageUrl,
        taxIds: taxIds,
        isInventoryTracked: isInventoryTracked,
        initialStock: initialStock,
        allowNegativeSale: allowNegativeSale,
      );

      // Printing v2 (Slice 4.B): persistir N:M de áreas si el dialog
      // las proveyó. setAreasForMenuItem hace replace atómico.
      if (printAreaIds != null) {
        try {
          final mipa = MenuItemPrintAreaRepository(_supabase);
          await mipa.setAreasForMenuItem(id, printAreaIds);
        } catch (e) {
          debugPrint('updateProduct: fallo guardando N:M áreas: $e');
        }
      }

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

  Future<void> downloadTemplate() async {
    try {
      final excel = Excel.createExcel();
      final sheet = excel['Sheet1'];
      sheet.appendRow([
        TextCellValue('Nombre'),
        TextCellValue('Precio'),
        TextCellValue('Costo'),
        TextCellValue('SKU'),
        TextCellValue('Codigo de Barras'),
        TextCellValue('Descripcion'),
      ]);
      
      var directory = await getDownloadsDirectory();
      if (directory == null) {
        directory = await getApplicationDocumentsDirectory();
      }
      final filePath = '${directory.path}/plantilla_productos.xlsx';
      final file = File(filePath);
      
      final bytes = excel.encode();
      if (bytes != null) {
        await file.writeAsBytes(bytes);
      }
      
      _error = 'Plantilla guardada en: $filePath';
      notifyListeners();
    } catch (e) {
      debugPrint('Error downloading template: $e');
      _error = 'Error descargando plantilla: $e';
      notifyListeners();
    }
  }

  Future<void> exportProductsToExcel() async {
    try {
      final excel = Excel.createExcel();
      final sheet = excel['Sheet1'];
      sheet.appendRow([
        TextCellValue('ID'),
        TextCellValue('Nombre'),
        TextCellValue('Precio'),
        TextCellValue('Costo'),
        TextCellValue('SKU'),
        TextCellValue('Codigo de Barras'),
        TextCellValue('Categoria'),
        TextCellValue('Activo'),
      ]);
      
      for (var product in _products) {
        final categoryName = _asMap(product['categories'])['name']?.toString() ?? '';
        sheet.appendRow([
          TextCellValue(product['id']?.toString() ?? ''),
          TextCellValue(product['name']?.toString() ?? ''),
          TextCellValue(product['price']?.toString() ?? '0'),
          TextCellValue(product['cost']?.toString() ?? '0'),
          TextCellValue(product['sku']?.toString() ?? ''),
          TextCellValue(product['barcode']?.toString() ?? ''),
          TextCellValue(categoryName),
          TextCellValue(product['is_active'] == true ? 'Si' : 'No'),
        ]);
      }
      
      var directory = await getDownloadsDirectory();
      if (directory == null) {
        directory = await getApplicationDocumentsDirectory();
      }
      final filePath = '${directory.path}/productos.xlsx';
      final file = File(filePath);
      
      final bytes = excel.encode();
      if (bytes != null) {
        await file.writeAsBytes(bytes);
      }
      
      _error = 'Productos exportados a: $filePath';
      notifyListeners();
    } catch (e) {
      debugPrint('Error exporting products: $e');
      _error = 'Error exportando productos: $e';
      notifyListeners();
    }
  }

  Future<void> importProductsFromExcel() async {
    if (_businessId == null) return;
    
    try {
      FilePickerResult? result = await FilePicker.platform.pickFiles(
        type: FileType.custom,
        allowedExtensions: ['xlsx', 'xls'],
      );

      if (result != null) {
        _isLoading = true;
        notifyListeners();

        final file = File(result.files.single.path!);
        var bytes = file.readAsBytesSync();
        var excel = Excel.decodeBytes(bytes);

        for (var table in excel.tables.keys) {
          final sheet = excel.tables[table];
          if (sheet == null) continue;
          
          bool isHeader = true;
          for (var row in sheet.rows) {
            if (isHeader) {
              isHeader = false;
              continue;
            }
            
            if (row.isEmpty || row[0] == null) continue;
            
            final name = row[0]?.value?.toString() ?? '';
            if (name.isEmpty) continue;
            
            final priceStr = row.length > 1 ? row[1]?.value?.toString() ?? '0' : '0';
            final price = double.tryParse(priceStr) ?? 0.0;
            
            final costStr = row.length > 2 ? row[2]?.value?.toString() ?? '0' : '0';
            final cost = double.tryParse(costStr) ?? 0.0;
            
            final sku = row.length > 3 ? row[3]?.value?.toString() : null;
            final barcode = row.length > 4 ? row[4]?.value?.toString() : null;
            final description = row.length > 5 ? row[5]?.value?.toString() : null;
            
            await _repository.createProduct(
              businessId: _businessId!,
              name: name,
              price: price,
              categoryId: null,
              cost: cost,
              sku: sku,
              barcode: barcode,
              description: description,
              taxMode: 'exclusive',
              isActive: true,
              itemType: 'standard',
              // Bulk-import desde Excel: no asignamos area por default — el
              // admin debe editar cada producto y elegir un area configurada.
              hasVariants: false,
              taxIds: [],
            );
          }
        }
        
        await _fetchProducts();
        _error = 'Productos importados exitosamente';
        _isLoading = false;
        notifyListeners();
      }
    } catch (e) {
      debugPrint('Error importing products: $e');
      _error = 'Error importando productos: $e';
      _isLoading = false;
      notifyListeners();
    }
  }
}
