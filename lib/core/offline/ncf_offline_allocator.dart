import 'package:flutter/foundation.dart';

import '../storage/storage_service.dart';

/// Flag maestro de F4 (NCF offline). Mientras esté en `false`, la emisión de
/// comprobante sin conexión NO se activa — el cobro offline sigue como hoy
/// (sin NCF hasta el sync). Se enciende SOLO tras el visto bueno fiscal del
/// contador (huecos de numeración, contingencia). Ver docs/PRD_OFFLINE_F4_NCF.md.
const bool kOfflineNcfEnabled = false;

/// Rango de NCF asignado a un dispositivo para una serie (sub-rango disjunto
/// del rango autorizado del negocio). Lo entrega el aprovisionamiento (F0) o
/// la configuración fiscal; aquí solo se consume.
@immutable
class NcfRange {
  const NcfRange({
    required this.ncfType,
    required this.serie,
    required this.prefix,
    required this.rangeStart,
    required this.rangeEnd,
    this.seedCurrent,
  });

  final String ncfType;
  final String serie;

  /// Prefijo impreso del NCF (ej. "B02"). El número va con LPAD(8), igual que
  /// la función SQL `generate_ncf` (`prefix || LPAD(n,8)`).
  final String prefix;
  final int rangeStart;
  final int rangeEnd;

  /// Último `current_number` conocido del server para esta serie (snapshot
  /// online). Evita reasignar números que el server ya consumió si el rango
  /// local arrancó atrás. Null si no se conoce.
  final int? seedCurrent;
}

/// Resultado de una asignación offline.
@immutable
class NcfAssignment {
  const NcfAssignment({
    required this.ncf,
    required this.number,
    required this.ncfType,
    required this.serie,
  });

  final String ncf;
  final int number;
  final String ncfType;
  final String serie;
}

/// Asigna números de NCF sin conexión desde el rango del dispositivo, llevando
/// el contador localmente (StorageService). Núcleo de F4 — lógica pura de
/// asignación, sin tocar la red ni la BD. La emisión real (crear el
/// fiscal_document, imprimir, encolar uplink) se cablea aparte y va detrás de
/// [kOfflineNcfEnabled].
///
/// Si el rango se agota, [allocate] devuelve null → el caller cae a recibo
/// PROVISIONAL sin NCF (NCF asignado al reconectar), que es la política
/// elegida para agotamiento.
class NcfOfflineAllocator {
  NcfOfflineAllocator({StorageService? storage}) : _injectedStorage = storage;

  final StorageService? _injectedStorage;
  Future<StorageService> get _storage async =>
      _injectedStorage ?? await StorageService.getInstance();

  String _key(String businessId, String ncfType, String serie) =>
      'offline_ncf_last_${businessId}_${ncfType}_$serie';

  // Mutex por-serie: cuando este allocator es el ÚNICO asignador de la LAN
  // (el Hub), varias cajas piden NCF a la vez. El read-modify-write del
  // contador debe serializarse para no asignar el mismo número dos veces.
  // Dart es un solo hilo, pero los `await` (storage) permiten interleaving;
  // este lock encadena las asignaciones de la misma serie.
  final Map<String, Future<void>> _locks = {};

  Future<T> _synchronized<T>(String key, Future<T> Function() action) {
    final prev = _locks[key] ?? Future<void>.value();
    final next = prev.then((_) => action());
    // El lock guarda un future que completa cuando termina esta acción
    // (tragando el error para no romper la cadena de la serie).
    _locks[key] = next.then((_) {}, onError: (_) {});
    return next;
  }

  /// Asigna el próximo NCF del rango. Devuelve null si el rango está agotado.
  /// Serializado por (negocio, tipo, serie) → seguro como asignador único del
  /// Hub ante peticiones concurrentes de varias cajas.
  Future<NcfAssignment?> allocate({
    required String businessId,
    required NcfRange range,
  }) {
    final key = _key(businessId, range.ncfType, range.serie);
    return _synchronized(key, () async {
      final storage = await _storage;
      final stored = int.tryParse(await storage.read(key) ?? '');

      // El "último consumido" base es el mayor entre: lo que llevamos local,
      // el current_number del server (seed) y rangeStart-1 (rango virgen).
      var last = range.rangeStart - 1;
      for (final candidate in [stored, range.seedCurrent]) {
        if (candidate != null && candidate > last) last = candidate;
      }

      final next = last + 1;
      if (next > range.rangeEnd) {
        // Agotado → el caller emite recibo provisional sin NCF.
        return null;
      }

      await storage.write(key, '$next');
      return NcfAssignment(
        ncf: formatNcf(range.prefix, next),
        number: next,
        ncfType: range.ncfType,
        serie: range.serie,
      );
    });
  }

  /// Último número consumido localmente para esta serie (para reconciliación
  /// al reconectar: subir `current_number` del server a este valor). Null si
  /// no se ha emitido nada offline en esta serie.
  Future<int?> lastConsumed({
    required String businessId,
    required String ncfType,
    required String serie,
  }) async {
    final storage = await _storage;
    return int.tryParse(await storage.read(_key(businessId, ncfType, serie)) ?? '');
  }

  /// Cuántos números quedan en el rango (para alertar al 80%).
  Future<int> remaining({
    required String businessId,
    required NcfRange range,
  }) async {
    final last = await lastConsumed(
          businessId: businessId,
          ncfType: range.ncfType,
          serie: range.serie,
        ) ??
        (range.seedCurrent ?? range.rangeStart - 1);
    final rem = range.rangeEnd - last;
    return rem < 0 ? 0 : rem;
  }

  /// Reinicia el contador local de una serie. Se llama tras reconciliar con el
  /// server (o al reasignar un rango nuevo). Best-effort.
  Future<void> reset({
    required String businessId,
    required String ncfType,
    required String serie,
  }) async {
    try {
      final storage = await _storage;
      await storage.delete(_key(businessId, ncfType, serie));
    } catch (e) {
      debugPrint('NcfOfflineAllocator.reset error: $e');
    }
  }

  /// Formato del NCF: `prefix` + número con 8 dígitos (LPAD), idéntico a la
  /// función SQL `generate_ncf`.
  static String formatNcf(String prefix, int number) =>
      '$prefix${number.toString().padLeft(8, '0')}';
}
