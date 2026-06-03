import 'package:supabase_flutter/supabase_flutter.dart';

import '../../core/utils/catalog_csv_parser.dart';
import 'products_repository.dart';

/// Resultado de una carga masiva de catálogo (fase R3).
class CatalogImportResult {
  CatalogImportResult({
    required this.created,
    required this.skipped,
    required this.failed,
    required this.categoriesCreated,
    required this.errors,
  });

  /// Productos insertados.
  final int created;

  /// Filas omitidas por SKU ya existente (idempotencia).
  final int skipped;

  /// Filas que fallaron al insertar.
  final int failed;

  /// Categorías nuevas creadas durante el import.
  final int categoriesCreated;

  /// Mensajes de error por fila (máx. unos pocos para el resumen).
  final List<String> errors;
}

/// Orquesta la carga masiva: resuelve/crea categorías, resuelve impuestos por
/// nombre, y crea productos idempotentemente (omite SKUs existentes). Reusa
/// [ProductsRepository.createProduct] para que cada producto quede igual que
/// uno creado a mano (impuestos, inventario, etc.).
class CatalogImportRepository {
  CatalogImportRepository(this._client) : _products = ProductsRepository(_client);

  final SupabaseClient _client;
  final ProductsRepository _products;

  static final RegExp _numeric = RegExp(r'^[0-9]+$');

  Future<CatalogImportResult> importRows({
    required String businessId,
    required List<CatalogImportRow> rows,
    String taxMode = 'inclusive',
    String? defaultTaxId,
    void Function(int done, int total)? onProgress,
  }) async {
    // Categorías existentes: nombre (lower) → id.
    final categoriesById = <String, String>{};
    final existingCats = await _products.getCategories(businessId);
    for (final c in existingCats) {
      final name = c['name']?.toString().trim().toLowerCase();
      final id = c['id']?.toString();
      if (name != null && name.isNotEmpty && id != null) {
        categoriesById[name] = id;
      }
    }
    var nextCatPosition = existingCats.length;
    var categoriesCreated = 0;

    // Impuestos del negocio: nombre (lower) → id.
    final taxesByName = <String, String>{};
    final taxRows = await _client
        .from('taxes')
        .select('id,name')
        .eq('business_id', businessId)
        .eq('is_active', true);
    for (final t in (taxRows as List)) {
      final name = t['name']?.toString().trim().toLowerCase();
      final id = t['id']?.toString();
      if (name != null && name.isNotEmpty && id != null) {
        taxesByName[name] = id;
      }
    }

    // SKUs ya registrados (idempotencia).
    final existingSkus = <String>{};
    final skuRows = await _client
        .from('menu_items')
        .select('sku')
        .eq('business_id', businessId)
        .not('sku', 'is', null);
    for (final r in (skuRows as List)) {
      final sku = r['sku']?.toString().trim().toLowerCase();
      if (sku != null && sku.isNotEmpty) existingSkus.add(sku);
    }

    var created = 0;
    var skipped = 0;
    var failed = 0;
    final errors = <String>[];
    final total = rows.length;
    var done = 0;

    Future<String?> resolveCategoryId(String? rawName) async {
      final name = rawName?.trim();
      if (name == null || name.isEmpty) return null;
      final key = name.toLowerCase();
      final existing = categoriesById[key];
      if (existing != null) return existing;
      final inserted = await _client
          .from('categories')
          .insert({
            'business_id': businessId,
            'name': name,
            'position': nextCatPosition++,
            'is_active': true,
          })
          .select('id')
          .single();
      final id = inserted['id'].toString();
      categoriesById[key] = id;
      categoriesCreated++;
      return id;
    }

    for (final row in rows) {
      done++;
      onProgress?.call(done, total);

      final sku = row.sku?.trim();
      if (sku != null && sku.isNotEmpty) {
        final key = sku.toLowerCase();
        if (existingSkus.contains(key)) {
          skipped++;
          continue;
        }
        existingSkus.add(key); // evita duplicados dentro del mismo archivo
      }

      try {
        final categoryId = await resolveCategoryId(row.category);

        // Impuesto: por nombre del CSV, si no por el default elegido.
        String? taxId;
        final taxName = row.tax?.trim().toLowerCase();
        if (taxName != null && taxName.isNotEmpty) {
          taxId = taxesByName[taxName] ?? defaultTaxId;
        } else {
          taxId = defaultTaxId;
        }

        // barcode: el del CSV, o el sku si es numérico (igual que el seed).
        final barcode = (row.barcode?.trim().isNotEmpty ?? false)
            ? row.barcode!.trim()
            : (sku != null && _numeric.hasMatch(sku) ? sku : null);

        await _products.createProduct(
          businessId: businessId,
          name: row.name,
          price: row.price,
          categoryId: categoryId,
          taxMode: taxMode,
          sku: sku,
          cost: row.cost,
          barcode: barcode,
          taxIds: taxId != null ? [taxId] : const [],
        );
        created++;
      } catch (e) {
        failed++;
        if (errors.length < 10) {
          errors.add('Línea ${row.lineNumber} (${row.name}): $e');
        }
      }
    }

    return CatalogImportResult(
      created: created,
      skipped: skipped,
      failed: failed,
      categoriesCreated: categoriesCreated,
      errors: errors,
    );
  }
}
