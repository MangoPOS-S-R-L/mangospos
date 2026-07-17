import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/legacy.dart';
import 'package:mangopos/data/models/category.dart' as model;
import 'package:mangopos/data/repositories/category_repository.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:uuid/uuid.dart';

import '../../../core/storage/image_upload_helper.dart';
import '../../../core/utils/export/report_exporter.dart';
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
  Map<String, List<Map<String, dynamic>>> _printAreasByProduct = {};
  bool _isLoading = false;
  String? _businessId;
  String? _error;
  String _searchQuery = '';
  String? _selectedCategoryFilterId;
  String? _selectedMenuFilterId;
  String? _selectedPrintAreaFilterId;
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
          final matchesPrintArea = _selectedPrintAreaFilterId == null ||
              _productMatchesPrintArea(product, _selectedPrintAreaFilterId!);

          return matchesSearch &&
              matchesCategory &&
              matchesMenu &&
              matchesPrintArea;
        })
        .toList(growable: false);
  }

  /// True si el producto está asignado al área dada (N:M en menu_item_print_areas
  /// o fallback por `print_area_code` legacy comparando contra el `code` del
  /// área en la lista cargada).
  bool _productMatchesPrintArea(
    Map<String, dynamic> product,
    String areaId,
  ) {
    final productId = product['id']?.toString() ?? '';
    final modern = _printAreasByProduct[productId];
    if (modern != null && modern.isNotEmpty) {
      return modern.any((a) => a['id']?.toString() == areaId);
    }
    final legacyCode = product['print_area_code']?.toString();
    if (legacyCode == null || legacyCode.isEmpty) return false;
    for (final areas in _printAreasByProduct.values) {
      for (final a in areas) {
        if (a['id']?.toString() == areaId &&
            a['code']?.toString() == legacyCode) {
          return true;
        }
      }
    }
    return false;
  }

  /// Lista única de áreas de producción derivada de las asignaciones cargadas.
  /// Sirve para poblar el dropdown del filtro sin un round-trip aparte.
  List<Map<String, dynamic>> get availablePrintAreas {
    final seen = <String>{};
    final result = <Map<String, dynamic>>[];
    for (final areas in _printAreasByProduct.values) {
      for (final a in areas) {
        final id = a['id']?.toString();
        if (id == null || id.isEmpty) continue;
        if (seen.add(id)) result.add(a);
      }
    }
    result.sort((a, b) =>
        (a['name']?.toString() ?? '').compareTo(b['name']?.toString() ?? ''));
    return result;
  }

  List<Map<String, dynamic>> get categories => _categories;
  List<Map<String, dynamic>> get menus => _menus;
  Map<String, List<Map<String, dynamic>>> get printAreasByProduct =>
      _printAreasByProduct;
  bool get isLoading => _isLoading;
  String? get error => _error;
  String get searchQuery => _searchQuery;
  String? get selectedCategoryFilterId => _selectedCategoryFilterId;
  String? get selectedMenuFilterId => _selectedMenuFilterId;
  String? get selectedPrintAreaFilterId => _selectedPrintAreaFilterId;

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

      // Single round-trip via RPC `get_products_catalog`. Antes eran 4
      // round-trips (3 paralelos: products/categories/menus + uno nested
      // para v_menu_items_stock dentro de getProducts). El RPC retorna
      // todo embebido con CTEs en ~30ms server-side.
      //
      // En paralelo cargamos el mapa N:M de áreas de producción
      // (menu_item_print_areas), que el RPC no embebe. Es una sola query
      // a una tabla pequeña, no impacta perf percibida.
      final catalogFuture =
          _repository.getProductsCatalog(resolvedBusinessId);
      final areasFuture =
          _repository.getPrintAreasByProduct(resolvedBusinessId);
      final results = await Future.wait<dynamic>([catalogFuture, areasFuture]);
      if (generation != _loadGeneration) return;

      final catalog = results[0]
          as ({
            List<Map<String, dynamic>> products,
            List<Map<String, dynamic>> categories,
            List<Map<String, dynamic>> menus,
          });
      final areasByProduct =
          results[1] as Map<String, List<Map<String, dynamic>>>;

      final businessChanged = _businessId != resolvedBusinessId;
      _businessId = resolvedBusinessId;
      _products = catalog.products;
      _categories = catalog.categories;
      _menus = catalog.menus;
      _printAreasByProduct = areasByProduct;
      // El RPC `get_products_catalog` puede no exponer `presentation`.
      // Merge defensivo: traemos id+presentation aparte para que el editor
      // prellene la etiqueta y NO la borre al re-guardar. Best-effort: si la
      // columna aún no existe (migración no aplicada), se ignora.
      await _mergePresentations(resolvedBusinessId, generation);
      if (businessChanged) {
        _searchQuery = '';
        _selectedCategoryFilterId = null;
        _selectedMenuFilterId = null;
        _selectedPrintAreaFilterId = null;
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

  void setPrintAreaFilter(String? areaId) {
    _selectedPrintAreaFilterId =
        areaId == null || areaId.isEmpty ? null : areaId;
    notifyListeners();
  }

  /// Resetea búsqueda y filtros de categoría/menú/área en una sola pasada.
  /// Útil para el botón "Limpiar filtros" cuando el cajero ya no recuerda
  /// qué filtros tiene puestos.
  void clearAllFilters() {
    _searchQuery = '';
    _selectedCategoryFilterId = null;
    _selectedMenuFilterId = null;
    _selectedPrintAreaFilterId = null;
    notifyListeners();
  }

  bool get hasActiveFilters =>
      _searchQuery.isNotEmpty ||
      _selectedCategoryFilterId != null ||
      _selectedMenuFilterId != null ||
      _selectedPrintAreaFilterId != null;

  /// Trae `id, presentation` de menu_items y lo mergea en `_products`. El
  /// RPC del catálogo no siempre expone la columna; sin esto, editar un
  /// producto mostraría la etiqueta vacía y al re-guardar la borraría.
  /// Best-effort: si la columna no existe (migración pendiente), se ignora.
  Future<void> _mergePresentations(String businessId, int generation) async {
    try {
      final rows = await _supabase
          .from('menu_items')
          .select('id, presentation')
          .eq('business_id', businessId);
      if (generation != _loadGeneration) return;
      final byId = <String, dynamic>{
        for (final r in (rows as List))
          (r as Map)['id'].toString(): r['presentation'],
      };
      for (final p in _products) {
        final id = p['id']?.toString();
        if (id != null && byId.containsKey(id)) {
          p['presentation'] = byId[id];
        }
      }
    } catch (_) {
      // Columna inexistente o sin permisos: la etiqueta no es crítica.
    }
  }

  /// Etiquetas de presentación distintas ya usadas (autocompletar para
  /// mantener consistencia: "Botella" en vez de variantes sueltas).
  List<String> get presentationOptions {
    final set = <String>{};
    for (final p in _products) {
      final v = p['presentation']?.toString().trim();
      if (v != null && v.isNotEmpty) set.add(v);
    }
    final list = set.toList()..sort();
    return list;
  }

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
    final printAreaIds = availablePrintAreas
        .map((area) => area['id']?.toString())
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
    if (_selectedPrintAreaFilterId != null &&
        !printAreaIds.contains(_selectedPrintAreaFilterId)) {
      _selectedPrintAreaFilterId = null;
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
    String? presentation,
    // Printing v2 (Slice 4.B): N:M de áreas. Si no se provee, no se
    // toca la tabla menu_item_print_areas.
    List<String>? printAreaIds,
    File? imageFile,
    Uint8List? imageBytes,
    List<String> taxIds = const [],
    // 👇 inventario por producto
    bool isInventoryTracked = false,
    double initialStock = 0,
    // Stock inicial repartido por bodega {warehouseId: cantidad}.
    // Null/vacío = initialStock va a la bodega principal.
    Map<String, double>? initialStockByWarehouse,
    bool allowNegativeSale = false,
    // Conversión del insumo ligado (solo al crear inventariable).
    String? baseUnit,
    String? purchaseUnit,
    double? packSize,
  }) async {
    if (_businessId == null) return;

    try {
      String? imagePath;
      String? imageUrl;

      if (imageFile != null || imageBytes != null) {
        // PRD 7 Fase 2.2: comprimir antes de subir. JPEG, 1024px, q=85.
        // Una foto típica de iPhone (~5 MB) baja a ~100-150 KB.
        final rawBytes = imageBytes ?? await imageFile!.readAsBytes();
        final compressed = await ImageUploadHelper.compressForMenu(rawBytes);
        // El helper devuelve JPEG (o el original si falla la compresión).
        // Usamos `.jpg` como extensión salvo que la compresión falle y
        // los bytes originales sean PNG — el navegador igual lo sirve OK
        // porque `contentType` se infiere del payload, pero mantenemos
        // la extensión real para que cached_network_image no se confunda.
        final ext = identical(compressed, rawBytes)
            ? _guessExt(imageFile?.path ?? 'upload.jpg')
            : 'jpg';
        final key =
            'items/$_businessId/${DateTime.now().millisecondsSinceEpoch}.$ext';
        final storage = _supabase.storage.from('menu-items');

        await storage.uploadBinary(
          key,
          compressed,
          fileOptions: const FileOptions(upsert: true),
        );

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
        presentation: presentation,
        imagePath: imagePath,
        imageUrl: imageUrl,
        taxIds: taxIds,
        isInventoryTracked: isInventoryTracked,
        initialStock: initialStock,
        initialStockByWarehouse: initialStockByWarehouse,
        allowNegativeSale: allowNegativeSale,
        baseUnit: baseUnit,
        purchaseUnit: purchaseUnit,
        packSize: packSize,
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
          // Pero SÍ surfaceamos el error en state.error para que el cajero
          // sepa que las áreas multi-print no se guardaron — antes se
          // tragaba silencioso y se reportaba "no puedo reasignar áreas".
          debugPrint('addProduct: fallo guardando N:M áreas: $e');
          _error =
              'Producto guardado, pero las áreas de impresión multi-print no se actualizaron: $e';
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
    String? presentation,
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
    // Stock inicial por bodega al activar tracking. Null/vacío = principal.
    Map<String, double>? initialStockByWarehouse,
    bool? allowNegativeSale,
  }) async {
    try {
      String? imagePath;
      String? imageUrl;

      if (imageFile != null || imageBytes != null) {
        // PRD 7 Fase 2.2: comprimir client-side (ver addProduct arriba).
        final rawBytes = imageBytes ?? await imageFile!.readAsBytes();
        final compressed = await ImageUploadHelper.compressForMenu(rawBytes);
        final ext = identical(compressed, rawBytes)
            ? _guessExt(imageFile?.path ?? 'upload.jpg')
            : 'jpg';
        final key =
            'items/$_businessId/${DateTime.now().millisecondsSinceEpoch}.$ext';
        final storage = _supabase.storage.from('menu-items');

        await storage.uploadBinary(
          key,
          compressed,
          fileOptions: const FileOptions(upsert: true),
        );

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
        presentation: presentation,
        imagePath: imagePath,
        imageUrl: imageUrl,
        taxIds: taxIds,
        isInventoryTracked: isInventoryTracked,
        initialStock: initialStock,
        initialStockByWarehouse: initialStockByWarehouse,
        allowNegativeSale: allowNegativeSale,
      );

      // Printing v2 (Slice 4.B): persistir N:M de áreas si el dialog
      // las proveyó. setAreasForMenuItem hace replace (delete-all + insert).
      if (printAreaIds != null) {
        try {
          final mipa = MenuItemPrintAreaRepository(_supabase);
          await mipa.setAreasForMenuItem(id, printAreaIds);
        } catch (e) {
          debugPrint('updateProduct: fallo guardando N:M áreas: $e');
          _error =
              'Producto guardado, pero las áreas de impresión multi-print no se actualizaron: $e';
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

  /// Elimina un producto definitivamente. Los tickets históricos quedan
  /// intactos porque `order_items` tiene `product_name` y `unit_price`
  /// denormalizados y su FK a `menu_items` está como `ON DELETE SET NULL`.
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
      final ok = await ReportExporter.exportExcel(
        filename: 'plantilla_productos',
        sheetName: 'Plantilla',
        headers: const [
          'Nombre',
          'Precio',
          'Costo',
          'SKU',
          'Codigo de Barras',
          'Categoria',
          'Impuesto',
        ],
        rows: const [],
      );

      _error = ok
          ? 'Plantilla descargada.'
          : 'No se pudo descargar; se copió al portapapeles.';
      notifyListeners();
    } catch (e) {
      debugPrint('Error downloading template: $e');
      _error = 'Error descargando plantilla: $e';
      notifyListeners();
    }
  }

  Future<void> exportProductsToExcel() async {
    try {
      // Export COMPLETO: toda la información del producto, incluida el área de
      // producción. Las 7 primeras columnas (Nombre, Precio, Costo, SKU,
      // Codigo de Barras, Categoria, Impuesto) usan los nombres EXACTOS que
      // entiende el import (CatalogCsvParser) para que el round-trip siga
      // funcionando — el resto de columnas el import las ignora. El impuesto va
      // por NOMBRE; 'Nombre' va antes que 'Descripcion' a propósito (ambos son
      // alias de 'name' en el parser; toma el primero).
      // Ver lib/core/utils/catalog_csv_parser.dart.
      String siNo(dynamic v) => v == true ? 'Si' : 'No';

      final rows = <List<String>>[];
      for (final product in _products) {
        final categoryName =
            _asMap(product['categories'])['name']?.toString() ?? '';
        // TODOS los impuestos vinculados, separados por ", " (el import los
        // resuelve por nombre y soporta varios). En CSV la celda se entrecomilla
        // automáticamente, así que la coma no rompe el formato. Vacío = default.
        final taxLinks = product['menu_item_taxes'];
        final taxName = (taxLinks is List)
            ? taxLinks
                  .map(
                    (l) => _asMap(_asMap(l)['taxes'])['name']?.toString() ?? '',
                  )
                  .where((n) => n.isNotEmpty)
                  .join(', ')
            : '';
        rows.add([
          // ── Compatibles con el import (NO cambiar nombres ni orden) ──
          product['name']?.toString() ?? '',
          product['price']?.toString() ?? '0',
          product['cost']?.toString() ?? '',
          product['sku']?.toString() ?? '',
          product['barcode']?.toString() ?? '',
          categoryName,
          taxName,
          // ── Resto de la información (solo lectura para el import) ──
          product['print_area_code']?.toString() ?? '',
          product['description']?.toString() ?? '',
          product['tax_mode']?.toString() ?? '',
          siNo(product['is_active']),
          siNo(product['is_beverage']),
          siNo(product['has_prep']),
          product['prep_minutes']?.toString() ?? '',
          product['sold_by_type']?.toString() ?? '',
          product['image_url']?.toString() ?? '',
          product['id']?.toString() ?? '',
        ]);
      }

      final ok = await ReportExporter.exportExcel(
        filename: 'productos',
        sheetName: 'Productos',
        headers: const [
          'Nombre',
          'Precio',
          'Costo',
          'SKU',
          'Codigo de Barras',
          'Categoria',
          'Impuesto',
          'Area de Produccion',
          'Descripcion',
          'Modo Impuesto',
          'Activo',
          'Es Bebida',
          'Tiene Preparacion',
          'Prep (min)',
          'Vendido por',
          'Imagen',
          'ID',
        ],
        rows: rows,
      );

      _error = ok
          ? 'Productos exportados (${rows.length}).'
          : 'No se pudo descargar; se copió al portapapeles como respaldo.';
      notifyListeners();
    } catch (e) {
      debugPrint('Error exporting products: $e');
      _error = 'Error exportando productos: $e';
      notifyListeners();
    }
  }

  // El import masivo ahora vive en ImportCatalogDialog + CatalogImportRepository
  // (categorías, impuestos, idempotencia por SKU, resiliencia por fila y
  // soporte CSV/Excel). Ver lib/presentation/products/widgets/import_catalog_dialog.dart.
}
