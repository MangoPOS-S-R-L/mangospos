import 'dart:convert';

import 'package:flutter/foundation.dart';

import '../storage/storage_service.dart';

/// Caché local del último snapshot de KPIs del dashboard ("Order Summary")
/// para mostrar la tira sin conexión. Mismo patrón que [ReportsOfflineCache]:
/// cada lectura online exitosa persiste un snapshot; offline el provider sirve
/// ese snapshot (potencialmente stale) + las ventas hechas offline.
///
/// Se guarda UN snapshot por negocio. No se condiciona por rango de fechas
/// porque "hoy vs ayer" se recalcula siempre relativo al momento actual; si el
/// snapshot quedó de un día anterior, el `savedAt` permite avisar al usuario.
class DashboardKpisOfflineCache {
  DashboardKpisOfflineCache._();
  static final DashboardKpisOfflineCache _instance =
      DashboardKpisOfflineCache._();
  factory DashboardKpisOfflineCache() => _instance;

  Future<StorageService> get _storage async => StorageService.getInstance();

  String _key(String businessId) => 'offline_dashboard_kpis_$businessId';

  /// Guarda el snapshot de KPIs ([kpisMap] = `{today: {...}, yesterday: {...}}`).
  Future<void> save({
    required String businessId,
    required Map<String, dynamic> kpisMap,
  }) async {
    try {
      final storage = await _storage;
      final payload = jsonEncode({
        'saved_at': DateTime.now().toIso8601String(),
        'kpis': kpisMap,
      });
      await storage.write(_key(businessId), payload);
    } catch (e) {
      debugPrint('DashboardKpisOfflineCache.save error: $e');
    }
  }

  /// Devuelve el snapshot cacheado + cuándo se capturó. Null si no hay caché.
  Future<({Map<String, dynamic> kpisMap, DateTime savedAt})?> load({
    required String businessId,
  }) async {
    try {
      final storage = await _storage;
      final raw = await storage.read(_key(businessId));
      if (raw == null || raw.isEmpty) return null;
      final payload = Map<String, dynamic>.from(jsonDecode(raw) as Map);
      final kpisMap = Map<String, dynamic>.from(payload['kpis'] as Map);
      final savedAt =
          DateTime.tryParse((payload['saved_at'] as String?) ?? '') ??
              DateTime.fromMillisecondsSinceEpoch(0);
      return (kpisMap: kpisMap, savedAt: savedAt);
    } catch (e) {
      debugPrint('DashboardKpisOfflineCache.load error: $e');
      return null;
    }
  }
}
