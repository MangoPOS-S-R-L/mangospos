import 'dart:convert';

import 'package:flutter/foundation.dart';

import '../storage/storage_service.dart';

/// Cache local de la fila `business_settings` del negocio (config: modo de
/// cierre, abrir gaveta, mostrar descuento, multicopia, banners de cocina,
/// features, etc.) para soporte offline (F6-3).
///
/// Estrategia (misma familia que [ZonesOfflineCache]):
///   - Cada lectura exitosa en `PosSettingsRepository` persiste la fila CRUDA
///     completa por businessId (un solo registro por negocio).
///   - Ante error de red, los getters parsean su columna desde esta fila
///     cacheada en vez de caer al valor por defecto → el POS conserva la
///     config real del negocio aunque se caiga internet.
///   - El [OfflineSyncCoordinator] (F6) la hidrata proactivamente al
///     reconectar vía `PosSettingsRepository.refreshBusinessSettings`.
///
/// Solo config (no secretos), así que se guarda en claro como los demás
/// snapshots de lectura.
class BusinessSettingsOfflineCache {
  BusinessSettingsOfflineCache._();

  static final BusinessSettingsOfflineCache _instance =
      BusinessSettingsOfflineCache._();
  factory BusinessSettingsOfflineCache() => _instance;

  Future<StorageService> get _storage async => StorageService.getInstance();

  String _key(String businessId) => 'offline_business_settings_$businessId';

  Future<void> saveRow({
    required String businessId,
    required Map<String, dynamic> row,
  }) async {
    try {
      final storage = await _storage;
      final payload = jsonEncode({
        'saved_at': DateTime.now().toIso8601String(),
        'row': row,
      });
      await storage.write(_key(businessId), payload);
    } catch (e) {
      debugPrint('BusinessSettingsOfflineCache.saveRow error: $e');
    }
  }

  /// Fila cacheada de `business_settings`, o null si nunca se cacheó.
  Future<Map<String, dynamic>?> loadRow(String businessId) async {
    try {
      final storage = await _storage;
      final raw = await storage.read(_key(businessId));
      if (raw == null || raw.isEmpty) return null;
      final payload = Map<String, dynamic>.from(jsonDecode(raw) as Map);
      final row = payload['row'];
      if (row is! Map) return null;
      return Map<String, dynamic>.from(row);
    } catch (e) {
      debugPrint('BusinessSettingsOfflineCache.loadRow error: $e');
      return null;
    }
  }
}
