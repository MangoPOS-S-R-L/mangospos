import 'package:flutter/foundation.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'ncf_offline_allocator.dart';
import 'ncf_sequence_offline_cache.dart';

/// Resuelve el rango/serie de NCF que consume el [NcfOfflineAllocator] para
/// emitir offline (F4, lado de lectura).
///
/// Dos modos:
///   - [resolveBusinessSeries] (modelo b, el elegido): UNA serie central
///     autorizada por DGII que el Hub reparte secuencial. Lee la fila activa de
///     `ncf_sequences` para `(business, ncf_type)` sin filtrar por dispositivo.
///     Cachea offline ([NcfSequenceOfflineCache]) → sin red sirve la última
///     semilla conocida.
///   - [resolveDeviceRange] (modelo a, fallback): serie/sub-rango por
///     dispositivo (`device_id = deviceId`).
///
/// NO reparte rangos (el "carvado" es lado de escritura, decisión del contador;
/// ver docs/PRD_OFFLINE_F4_NCF.md §4). Resiliente: ante fila ausente o error de
/// red devuelve null (→ recibo provisional) salvo que haya cache offline.
class NcfRangeService {
  NcfRangeService(this._client, {NcfSequenceOfflineCache? cache})
      : _cache = cache ?? NcfSequenceOfflineCache();

  final SupabaseClient _client;
  final NcfSequenceOfflineCache _cache;

  /// Columnas mínimas que necesita el allocator/Hub.
  static const String _cols =
      'serie, prefix, range_start, range_end, current_number, is_active';

  /// Modelo (b): serie central del negocio para [ncfType]. Cachea al leer
  /// online; sin red cae a la fila cacheada. null si no hay serie ni cache.
  Future<NcfRange?> resolveBusinessSeries({
    required String businessId,
    required String ncfType,
  }) async {
    try {
      final rows = await _client
          .from('ncf_sequences')
          .select(_cols)
          .eq('business_id', businessId)
          .eq('ncf_type', ncfType)
          .eq('is_active', true)
          .order('created_at', ascending: false)
          .limit(1);

      final list = rows as List;
      if (list.isNotEmpty) {
        final row = Map<String, dynamic>.from(list.first as Map);
        await _cache.saveRow(
            businessId: businessId, ncfType: ncfType, row: row);
        return _rowToRange(ncfType, row);
      }
      return _fromCache(businessId, ncfType);
    } catch (e) {
      debugPrint('NcfRangeService.resolveBusinessSeries error: $e');
      return _fromCache(businessId, ncfType);
    }
  }

  /// Refresca el cache offline de TODAS las series activas del negocio (lo
  /// llama el coordinador F6). Best-effort; no lanza.
  Future<void> refreshAllSeries(String businessId) async {
    try {
      final rows = await _client
          .from('ncf_sequences')
          .select('ncf_type, $_cols')
          .eq('business_id', businessId)
          .eq('is_active', true);

      for (final r in rows as List) {
        final row = Map<String, dynamic>.from(r as Map);
        final type = row['ncf_type']?.toString();
        if (type == null || type.isEmpty) continue;
        await _cache.saveRow(businessId: businessId, ncfType: type, row: row);
      }
    } catch (e) {
      debugPrint('NcfRangeService.refreshAllSeries error: $e');
    }
  }

  /// Modelo (a, fallback): serie/sub-rango asignado a ESTE dispositivo.
  Future<NcfRange?> resolveDeviceRange({
    required String businessId,
    required String ncfType,
    required String deviceId,
  }) async {
    try {
      final row = await _client
          .from('ncf_sequences')
          .select(_cols)
          .eq('business_id', businessId)
          .eq('ncf_type', ncfType)
          .eq('device_id', deviceId)
          .eq('is_active', true)
          .maybeSingle();

      if (row == null) return null;
      return _rowToRange(ncfType, row);
    } catch (e) {
      debugPrint('NcfRangeService.resolveDeviceRange error: $e');
      return null;
    }
  }

  Future<NcfRange?> _fromCache(String businessId, String ncfType) async {
    final row = await _cache.loadRow(businessId: businessId, ncfType: ncfType);
    if (row == null) return null;
    return _rowToRange(ncfType, row);
  }

  /// Convierte una fila de `ncf_sequences` en [NcfRange]. Para la serie central
  /// (modelo b) el campo `serie` puede venir null → usa el `prefix` como clave
  /// estable (consistente entre cajas, no vacío para el endpoint del Hub).
  NcfRange? _rowToRange(String ncfType, Map<String, dynamic> row) {
    final rangeStart = (row['range_start'] as num?)?.toInt();
    final rangeEnd = (row['range_end'] as num?)?.toInt();
    final prefix = row['prefix']?.toString();
    if (rangeStart == null ||
        rangeEnd == null ||
        prefix == null ||
        prefix.isEmpty) {
      return null;
    }
    final rawSerie = row['serie']?.toString();
    final serie = (rawSerie != null && rawSerie.isNotEmpty) ? rawSerie : prefix;
    return NcfRange(
      ncfType: ncfType,
      serie: serie,
      prefix: prefix,
      rangeStart: rangeStart,
      rangeEnd: rangeEnd,
      seedCurrent: (row['current_number'] as num?)?.toInt(),
    );
  }
}
