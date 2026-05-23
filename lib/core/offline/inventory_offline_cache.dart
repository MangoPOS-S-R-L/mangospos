import 'dart:convert';

import 'package:flutter/foundation.dart';

import '../storage/storage_service.dart';

/// Cache local de inventario para soporte offline (modo optimista).
///
/// Estrategia:
///   - Cada vez que el repo lee items+stock con éxito desde server, llamamos
///     [saveItemsSnapshot]. El snapshot incluye items + map item_id → qty.
///   - En error de red, el repo llama [loadItemsSnapshot] para servir la
///     última lista conocida — el cajero ve stock potencialmente stale en
///     vez de pantalla vacía.
///   - Cuando se aplica un ajuste/movimiento offline, llamamos
///     [applyStockDelta] o [setStock] para actualizar la copia local. Al
///     siguiente sync, el server resuelve cualquier drift entre terminales
///     (LWW por timestamp del movement).
///
/// El snapshot se almacena por (businessId, warehouseId) porque el stock
/// es per-warehouse. Si el cajero cambia de warehouse, se hidrata uno
/// nuevo a la primera lectura exitosa.
class InventoryOfflineCache {
  InventoryOfflineCache._();

  static final InventoryOfflineCache _instance = InventoryOfflineCache._();
  factory InventoryOfflineCache() => _instance;

  Future<StorageService> get _storage async => StorageService.getInstance();

  String _snapshotKey(String businessId, String warehouseId) =>
      'offline_inventory_snapshot_${businessId}_$warehouseId';

  /// Persiste lista de items + map de stock. [itemsRaw] es la respuesta
  /// cruda de `inventory_items` (Map). [stockByItem] es el map
  /// item_id → quantity recuperado de `inventory_stock`.
  Future<void> saveItemsSnapshot({
    required String businessId,
    required String warehouseId,
    required List<Map<String, dynamic>> itemsRaw,
    required Map<String, double> stockByItem,
  }) async {
    try {
      final storage = await _storage;
      final payload = jsonEncode({
        'saved_at': DateTime.now().toIso8601String(),
        'items': itemsRaw,
        'stock': stockByItem,
      });
      await storage.write(_snapshotKey(businessId, warehouseId), payload);
    } catch (e) {
      debugPrint('InventoryOfflineCache.saveItemsSnapshot error: $e');
    }
  }

  /// Devuelve el snapshot (items + stock) si existe. Si no hay snapshot
  /// previo, devuelve null y el repo propaga el error original al
  /// ViewModel.
  Future<({List<Map<String, dynamic>> items, Map<String, double> stock})?>
      loadItemsSnapshot({
    required String businessId,
    required String warehouseId,
  }) async {
    try {
      final storage = await _storage;
      final raw = await storage.read(_snapshotKey(businessId, warehouseId));
      if (raw == null || raw.isEmpty) return null;
      final payload = Map<String, dynamic>.from(jsonDecode(raw) as Map);
      final items = (payload['items'] as List? ?? const [])
          .map((e) => Map<String, dynamic>.from(e as Map))
          .toList(growable: false);
      final rawStock = Map<String, dynamic>.from(
        (payload['stock'] as Map?) ?? const {},
      );
      final stock = <String, double>{};
      rawStock.forEach((key, value) {
        stock[key] = value is num
            ? value.toDouble()
            : double.tryParse(value?.toString() ?? '') ?? 0;
      });
      return (items: items, stock: stock);
    } catch (e) {
      debugPrint('InventoryOfflineCache.loadItemsSnapshot error: $e');
      return null;
    }
  }

  /// Setea el stock absoluto de un item (usado por ajuste con conteo
  /// físico — el cajero ingresa lo que contó, eso ES el stock nuevo).
  Future<void> setStock({
    required String businessId,
    required String warehouseId,
    required String itemId,
    required double quantity,
  }) async {
    await _patchStock(
      businessId: businessId,
      warehouseId: warehouseId,
      itemId: itemId,
      patch: (_) => quantity,
    );
  }

  /// Aplica un delta al stock actual. Usado por recordMovement (waste
  /// resta, purchase suma, etc.). Si el item no existía en el cache, lo
  /// inicializa en `delta` (asumiendo arranco en 0).
  Future<void> applyStockDelta({
    required String businessId,
    required String warehouseId,
    required String itemId,
    required double delta,
  }) async {
    await _patchStock(
      businessId: businessId,
      warehouseId: warehouseId,
      itemId: itemId,
      patch: (current) => current + delta,
    );
  }

  Future<void> _patchStock({
    required String businessId,
    required String warehouseId,
    required String itemId,
    required double Function(double current) patch,
  }) async {
    try {
      final storage = await _storage;
      final key = _snapshotKey(businessId, warehouseId);
      final raw = await storage.read(key);
      if (raw == null || raw.isEmpty) return; // sin snapshot, nada que mutar
      final payload = Map<String, dynamic>.from(jsonDecode(raw) as Map);
      final stockRaw = Map<String, dynamic>.from(
        (payload['stock'] as Map?) ?? const {},
      );
      final currentQty = (stockRaw[itemId] is num)
          ? (stockRaw[itemId] as num).toDouble()
          : double.tryParse(stockRaw[itemId]?.toString() ?? '') ?? 0;
      stockRaw[itemId] = patch(currentQty);
      payload['stock'] = stockRaw;
      payload['mutated_at'] = DateTime.now().toIso8601String();
      await storage.write(key, jsonEncode(payload));
    } catch (e) {
      debugPrint('InventoryOfflineCache._patchStock error: $e');
    }
  }
}
