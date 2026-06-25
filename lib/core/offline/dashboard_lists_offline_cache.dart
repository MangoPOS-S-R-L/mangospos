import 'dart:convert';

import 'package:flutter/foundation.dart';

import '../storage/storage_service.dart';

/// Caché local de las listas del dashboard (Top productos, Órdenes recientes,
/// Alertas de inventario) para que la pantalla siga renderizando sin conexión.
///
/// Mismo patrón que [DashboardKpisOfflineCache]: cada lectura online exitosa
/// persiste el último snapshot (lista de maps crudos, tal como llegan del
/// backend); offline el provider sirve ese snapshot. Se guarda un snapshot por
/// `(businessId, section)` — `section` distingue cada widget.
class DashboardListsOfflineCache {
  DashboardListsOfflineCache._();
  static final DashboardListsOfflineCache _instance =
      DashboardListsOfflineCache._();
  factory DashboardListsOfflineCache() => _instance;

  Future<StorageService> get _storage async => StorageService.getInstance();

  String _key(String businessId, String section) =>
      'offline_dashboard_${section}_$businessId';

  /// Persiste [rows] (las filas crudas devueltas por el repositorio).
  Future<void> save({
    required String businessId,
    required String section,
    required List<Map<String, dynamic>> rows,
  }) async {
    try {
      final storage = await _storage;
      await storage.write(_key(businessId, section), jsonEncode(rows));
    } catch (e) {
      debugPrint('DashboardListsOfflineCache.save error: $e');
    }
  }

  /// Devuelve el snapshot cacheado, o `null` si no hay.
  Future<List<Map<String, dynamic>>?> load({
    required String businessId,
    required String section,
  }) async {
    try {
      final storage = await _storage;
      final raw = await storage.read(_key(businessId, section));
      if (raw == null || raw.isEmpty) return null;
      final decoded = jsonDecode(raw) as List;
      return decoded
          .map((e) => Map<String, dynamic>.from(e as Map))
          .toList(growable: false);
    } catch (e) {
      debugPrint('DashboardListsOfflineCache.load error: $e');
      return null;
    }
  }
}
