import 'dart:convert';

import 'package:flutter/foundation.dart';

import '../storage/storage_service.dart';

/// Cache local del resumen de ventas para ver reportes del día sin conexión
/// (F5, solo lectura). Sigue el mismo patrón que [ZonesOfflineCache] /
/// inventory: cada lectura online exitosa persiste un snapshot; en error de
/// red el repositorio sirve ese snapshot (potencialmente stale) en vez de
/// fallar con pantalla vacía.
///
/// Se guarda UN snapshot por negocio, junto con el rango (`from`/`to`) que
/// representa. Offline solo se sirve si el rango pedido COINCIDE con el
/// cacheado — así el cajero no ve datos de "hoy" al pedir "ayer". Si no hay
/// cache para ese rango, el repositorio propaga el error (como hoy).
class ReportsOfflineCache {
  ReportsOfflineCache._();
  static final ReportsOfflineCache _instance = ReportsOfflineCache._();
  factory ReportsOfflineCache() => _instance;

  Future<StorageService> get _storage async => StorageService.getInstance();

  // Key por tipo de resumen ("sales", "cash", …). 'sales' conserva la key
  // histórica de F5-1 (`offline_reports_sales_summary_$businessId`) para no
  // invalidar snapshots ya guardados.
  String _key(String kind, String businessId) =>
      'offline_reports_${kind}_summary_$businessId';

  /// Guarda un snapshot de resumen ([kind]) por negocio + rango.
  Future<void> saveSummary({
    required String kind,
    required String businessId,
    required String fromIso,
    required String toIso,
    required Map<String, dynamic> summary,
  }) async {
    try {
      final storage = await _storage;
      final payload = jsonEncode({
        'saved_at': DateTime.now().toIso8601String(),
        'from': fromIso,
        'to': toIso,
        'summary': summary,
      });
      await storage.write(_key(kind, businessId), payload);
    } catch (e) {
      debugPrint('ReportsOfflineCache._save($kind) error: $e');
    }
  }

  /// Devuelve el snapshot ([kind]) cacheado SOLO si el rango coincide con el
  /// pedido. `savedAt` = cuándo se capturó (para el aviso). Null si no hay
  /// cache o el rango no coincide.
  Future<({Map<String, dynamic> summary, DateTime savedAt})?> loadSummary({
    required String kind,
    required String businessId,
    required String fromIso,
    required String toIso,
  }) async {
    try {
      final storage = await _storage;
      final raw = await storage.read(_key(kind, businessId));
      if (raw == null || raw.isEmpty) return null;
      final payload = Map<String, dynamic>.from(jsonDecode(raw) as Map);
      if (payload['from'] != fromIso || payload['to'] != toIso) return null;
      final summary = Map<String, dynamic>.from(payload['summary'] as Map);
      final savedAt =
          DateTime.tryParse((payload['saved_at'] as String?) ?? '') ??
              DateTime.fromMillisecondsSinceEpoch(0);
      return (summary: summary, savedAt: savedAt);
    } catch (e) {
      debugPrint('ReportsOfflineCache._load($kind) error: $e');
      return null;
    }
  }

  // --- Ventas (F5-1) ---
  Future<void> saveSalesSummary({
    required String businessId,
    required String fromIso,
    required String toIso,
    required Map<String, dynamic> summary,
  }) =>
      saveSummary(
          kind: 'sales',
          businessId: businessId,
          fromIso: fromIso,
          toIso: toIso,
          summary: summary);

  Future<({Map<String, dynamic> summary, DateTime savedAt})?> loadSalesSummary({
    required String businessId,
    required String fromIso,
    required String toIso,
  }) =>
      loadSummary(
          kind: 'sales', businessId: businessId, fromIso: fromIso, toIso: toIso);

  // --- Finanzas / caja (F5-2) ---
  Future<void> saveCashSummary({
    required String businessId,
    required String fromIso,
    required String toIso,
    required Map<String, dynamic> summary,
  }) =>
      saveSummary(
          kind: 'cash',
          businessId: businessId,
          fromIso: fromIso,
          toIso: toIso,
          summary: summary);

  Future<({Map<String, dynamic> summary, DateTime savedAt})?> loadCashSummary({
    required String businessId,
    required String fromIso,
    required String toIso,
  }) =>
      loadSummary(
          kind: 'cash', businessId: businessId, fromIso: fromIso, toIso: toIso);
}
