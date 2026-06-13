import 'dart:convert';

import 'package:flutter/foundation.dart';

import '../storage/storage_service.dart';

/// Cache local de la fila `ncf_sequences` (serie central del negocio) por
/// `(businessId, ncfType)`, para que el dispositivo conozca el rango y el
/// `current_number` de la serie cuando se cae internet (F4 / modelo b).
///
/// Estrategia (misma familia que [BusinessSettingsOfflineCache]):
///   - Cada lectura exitosa en [NcfRangeService] persiste la fila cruda.
///   - Sin red, [NcfRangeService.resolveBusinessSeries] sirve la fila cacheada
///     → el Hub puede asignar NCF secuencial desde la última semilla conocida.
///   - El [OfflineSyncCoordinator] (F6) la rehidrata al reconectar/periódico.
///
/// El rango/serie NCF es configuración del negocio (no secreto), así que se
/// guarda en claro como los demás snapshots de lectura.
class NcfSequenceOfflineCache {
  NcfSequenceOfflineCache._();

  static final NcfSequenceOfflineCache _instance = NcfSequenceOfflineCache._();
  factory NcfSequenceOfflineCache() => _instance;

  Future<StorageService> get _storage async => StorageService.getInstance();

  String _key(String businessId, String ncfType) =>
      'offline_ncf_seq_${businessId}_$ncfType';

  Future<void> saveRow({
    required String businessId,
    required String ncfType,
    required Map<String, dynamic> row,
  }) async {
    try {
      final storage = await _storage;
      final payload = jsonEncode({
        'saved_at': DateTime.now().toIso8601String(),
        'row': row,
      });
      await storage.write(_key(businessId, ncfType), payload);
    } catch (e) {
      debugPrint('NcfSequenceOfflineCache.saveRow error: $e');
    }
  }

  /// Fila cacheada de `ncf_sequences` para el tipo, o null si nunca se cacheó.
  Future<Map<String, dynamic>?> loadRow({
    required String businessId,
    required String ncfType,
  }) async {
    try {
      final storage = await _storage;
      final raw = await storage.read(_key(businessId, ncfType));
      if (raw == null || raw.isEmpty) return null;
      final payload = Map<String, dynamic>.from(jsonDecode(raw) as Map);
      final row = payload['row'];
      if (row is! Map) return null;
      return Map<String, dynamic>.from(row);
    } catch (e) {
      debugPrint('NcfSequenceOfflineCache.loadRow error: $e');
      return null;
    }
  }
}
