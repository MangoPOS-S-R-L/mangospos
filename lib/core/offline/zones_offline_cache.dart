import 'dart:convert';

import 'package:flutter/foundation.dart';

import '../storage/storage_service.dart';

/// Cache local de zonas + estado de mesas para soporte offline (solo lectura).
///
/// Estrategia:
///   - Cada lectura exitosa de `ZonesRepository.fetchZones` /
///     `fetchByZone` persiste un snapshot crudo (List<Map>) por
///     businessId y zoneId respectivamente.
///   - En error de red, los wrappers `*WithCache` del repo consultan
///     estos snapshots y los devuelven junto con un timestamp, para que
///     el cajero vea las mesas (datos potencialmente stale) en vez de
///     pantalla vacia con "Reintentar".
///   - Los datos pueden estar desactualizados (sesiones abiertas en
///     otro terminal mientras estabamos offline no se reflejan). Cuando
///     el internet vuelve, la siguiente `loadZoneStatus` trae lo fresco.
class ZonesOfflineCache {
  ZonesOfflineCache._();

  static final ZonesOfflineCache _instance = ZonesOfflineCache._();
  factory ZonesOfflineCache() => _instance;

  Future<StorageService> get _storage async => StorageService.getInstance();

  String _zonesKey(String businessId) => 'offline_zones_snapshot_$businessId';
  String _statusKey(String zoneId) => 'offline_zone_status_snapshot_$zoneId';

  Future<void> saveZonesSnapshot({
    required String businessId,
    required List<Map<String, dynamic>> zonesRaw,
  }) async {
    try {
      final storage = await _storage;
      final payload = jsonEncode({
        'saved_at': DateTime.now().toIso8601String(),
        'zones': zonesRaw,
      });
      await storage.write(_zonesKey(businessId), payload);
    } catch (e) {
      debugPrint('ZonesOfflineCache.saveZonesSnapshot error: $e');
    }
  }

  Future<({List<Map<String, dynamic>> zones, DateTime savedAt})?>
      loadZonesSnapshot({required String businessId}) async {
    try {
      final storage = await _storage;
      final raw = await storage.read(_zonesKey(businessId));
      if (raw == null || raw.isEmpty) return null;
      final payload = Map<String, dynamic>.from(jsonDecode(raw) as Map);
      final zones = (payload['zones'] as List? ?? const [])
          .map((e) => Map<String, dynamic>.from(e as Map))
          .toList(growable: false);
      final savedAt = DateTime.tryParse(
            (payload['saved_at'] as String?) ?? '',
          ) ??
          DateTime.fromMillisecondsSinceEpoch(0);
      return (zones: zones, savedAt: savedAt);
    } catch (e) {
      debugPrint('ZonesOfflineCache.loadZonesSnapshot error: $e');
      return null;
    }
  }

  Future<void> saveZoneStatusSnapshot({
    required String zoneId,
    required List<Map<String, dynamic>> rowsRaw,
  }) async {
    try {
      final storage = await _storage;
      final payload = jsonEncode({
        'saved_at': DateTime.now().toIso8601String(),
        'rows': rowsRaw,
      });
      await storage.write(_statusKey(zoneId), payload);
    } catch (e) {
      debugPrint('ZonesOfflineCache.saveZoneStatusSnapshot error: $e');
    }
  }

  Future<({List<Map<String, dynamic>> rows, DateTime savedAt})?>
      loadZoneStatusSnapshot({required String zoneId}) async {
    try {
      final storage = await _storage;
      final raw = await storage.read(_statusKey(zoneId));
      if (raw == null || raw.isEmpty) return null;
      final payload = Map<String, dynamic>.from(jsonDecode(raw) as Map);
      final rows = (payload['rows'] as List? ?? const [])
          .map((e) => Map<String, dynamic>.from(e as Map))
          .toList(growable: false);
      final savedAt = DateTime.tryParse(
            (payload['saved_at'] as String?) ?? '',
          ) ??
          DateTime.fromMillisecondsSinceEpoch(0);
      return (rows: rows, savedAt: savedAt);
    } catch (e) {
      debugPrint('ZonesOfflineCache.loadZoneStatusSnapshot error: $e');
      return null;
    }
  }
}
