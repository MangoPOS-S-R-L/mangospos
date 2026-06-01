import 'package:flutter/foundation.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'ncf_offline_allocator.dart';

/// Resuelve el rango de NCF asignado a un dispositivo (F4-2, lado de lectura).
///
/// Lee de `ncf_sequences` la fila de la serie de ESTE dispositivo
/// (`device_id = deviceId`) y la convierte en un [NcfRange] que consume el
/// [NcfOfflineAllocator] para emitir offline.
///
/// NO reparte rangos (eso es el "carvado", lado de escritura): partir la
/// numeración depende de cómo DGII autorizó al negocio (series separadas por
/// terminal vs partición del rango de una serie) — decisión del contador. Ver
/// docs/PRD_OFFLINE_F4_NCF.md §4. Mientras no exista una fila con `device_id`
/// asignado, esto devuelve null y el cobro offline cae a recibo provisional.
///
/// Resiliente: si la columna `device_id` aún no existe (migración 20260601_0004
/// sin aplicar), no hay fila, o falla la red, devuelve null sin romper.
class NcfRangeService {
  NcfRangeService(this._client);

  final SupabaseClient _client;

  Future<NcfRange?> resolveDeviceRange({
    required String businessId,
    required String ncfType,
    required String deviceId,
  }) async {
    try {
      final row = await _client
          .from('ncf_sequences')
          .select(
            'serie, prefix, range_start, range_end, current_number, is_active',
          )
          .eq('business_id', businessId)
          .eq('ncf_type', ncfType)
          .eq('device_id', deviceId)
          .eq('is_active', true)
          .maybeSingle();

      if (row == null) return null;

      final rangeStart = (row['range_start'] as num?)?.toInt();
      final rangeEnd = (row['range_end'] as num?)?.toInt();
      final prefix = row['prefix']?.toString();
      final serie = row['serie']?.toString();
      if (rangeStart == null ||
          rangeEnd == null ||
          prefix == null ||
          serie == null) {
        return null;
      }

      return NcfRange(
        ncfType: ncfType,
        serie: serie,
        prefix: prefix,
        rangeStart: rangeStart,
        rangeEnd: rangeEnd,
        seedCurrent: (row['current_number'] as num?)?.toInt(),
      );
    } catch (e) {
      debugPrint('NcfRangeService.resolveDeviceRange error: $e');
      return null;
    }
  }
}
