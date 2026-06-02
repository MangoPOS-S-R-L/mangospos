import 'package:supabase_flutter/supabase_flutter.dart';

import 'offline_catalog_service.dart';

/// Baja el catálogo (categorías, menús, productos) del negocio y reescribe el
/// snapshot offline. Es la contraparte NO interactiva de
/// `MenuBrowserViewModel._refreshCatalogSnapshot`: misma consulta y mismo
/// formato de snapshot, pero pensada para correr en background desde el
/// `OfflineSyncCoordinator` (F6) sin depender de que se abra la pantalla de
/// venta.
///
/// Preserva `menuProducts` y `favoriteProductIds` del snapshot previo (igual
/// que el viewmodel): esos los hidrata el flujo interactivo, no esta bajada.
class CatalogRefreshService {
  CatalogRefreshService(this._client, {OfflineCatalogService? catalog})
      : _catalog = catalog ?? OfflineCatalogService();

  final SupabaseClient _client;
  final OfflineCatalogService _catalog;

  // Mismo select que MenuBrowserViewModel: si uno cambia, revisar el otro.
  static const _menuItemsSelect =
      'id,name,price,image_url,category_id,is_active,position,tax_mode,item_type,is_inventory_tracked,allow_negative_sale,barcode,sku,menu_item_taxes(tax_id,taxes(name,rate,is_active,is_service_fee,apply_on_zone,apply_on_manual,apply_on_quick,apply_on_delivery))';

  Future<void> refresh(String businessId) async {
    final existing = await _catalog.loadSnapshot(businessId);
    final results = await Future.wait<dynamic>([
      _client
          .from('categories')
          .select('id,name,color')
          .eq('business_id', businessId)
          .eq('is_active', true)
          .order('position', ascending: true),
      _client
          .from('menus')
          .select('id,name')
          .eq('business_id', businessId)
          .eq('is_active', true)
          .order('created_at', ascending: true),
      _client
          .from('menu_items')
          .select('$_menuItemsSelect,updated_at')
          .eq('business_id', businessId)
          .eq('is_active', true)
          .order('position', ascending: true)
          .order('name', ascending: true),
    ]);

    final categories = _rowsToMaps(results[0]);
    final menus = _rowsToMaps(results[1]);
    final products = _rowsToMaps(results[2]);
    final menuProducts =
        existing?.menuProducts ?? const <Map<String, dynamic>>[];
    final favoriteIds = existing?.favoriteProductIds ?? const <String>[];
    final maxUpdatedAt = _extractMaxUpdatedAt(products);

    await _catalog.saveSnapshot(
      businessId: businessId,
      categories: categories,
      menus: menus,
      products: products,
      menuProducts: menuProducts,
      favoriteProductIds: favoriteIds,
      lastProductUpdatedAt: maxUpdatedAt,
      productCount: products.length,
    );
  }

  List<Map<String, dynamic>> _rowsToMaps(dynamic rows) {
    if (rows is! List) return const [];
    return rows
        .map((row) => Map<String, dynamic>.from(row as Map))
        .toList(growable: false);
  }

  DateTime? _extractMaxUpdatedAt(List<Map<String, dynamic>> products) {
    DateTime? max;
    for (final p in products) {
      final raw = p['updated_at']?.toString();
      if (raw == null) continue;
      final dt = DateTime.tryParse(raw);
      if (dt != null && (max == null || dt.isAfter(max))) {
        max = dt;
      }
    }
    return max;
  }
}
