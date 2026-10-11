import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';

import '../storage/storage_service.dart';

/// Bitácora local y acotada de la cola offline, por negocio: cuándo se guardó
/// cada operación, cada pasada de subida (qué vio, qué hizo) y el resultado
/// de cada intento, más los pasos de las comandas locales. Sirve para
/// explicar una retención larga (p. ej. 72 min) y no solo contarla: sin
/// pasadas = el uplink no corría; pasadas que la saltan = espera/backoff;
/// intentos con error = el servidor la rechaza.
///
/// Solo ids, tipos, horas y errores recortados: nunca tokens ni credenciales.
/// Nunca lanza ni demora a quien registra: las escrituras se juntan en una
/// microtarea y se serializan.
class OfflineQueueTrace {
  OfflineQueueTrace._();

  static final OfflineQueueTrace instance = OfflineQueueTrace._();

  /// Eventos que se conservan por negocio (los más recientes).
  static const int maxEvents = 200;
  static const int _maxDetail = 160;
  static const String keyPrefix = 'offline_queue_trace_';

  final Map<String, List<Map<String, Object?>>> _buffer = {};
  bool _flushScheduled = false;
  Future<void> _writing = Future<void>.value();

  static String _key(String businessId) => '$keyPrefix$businessId';

  void record(
    String businessId,
    String event, {
    String? op,
    String? type,
    String? order,
    String? detail,
  }) {
    if (businessId.isEmpty) return;
    final text = detail == null
        ? null
        : (detail.length > _maxDetail
              ? '${detail.substring(0, _maxDetail)}…'
              : detail);
    (_buffer[businessId] ??= []).add({
      'at': DateTime.now().toIso8601String(),
      'ev': event,
      'op': ?op,
      'type': ?type,
      'order': ?order,
      'detail': ?text,
    });
    if (_flushScheduled) return;
    _flushScheduled = true;
    scheduleMicrotask(() {
      _flushScheduled = false;
      _writing = _writing.then((_) => _flush()).catchError((Object e) {
        debugPrint('[OfflineQueueTrace] no se guardó: $e');
      });
    });
  }

  Future<void> _flush() async {
    if (_buffer.isEmpty) return;
    final batch = Map.of(_buffer);
    _buffer.clear();
    final storage = await StorageService.getInstance();
    for (final entry in batch.entries) {
      final current = await _readRaw(storage, entry.key);
      current.addAll(entry.value);
      final kept = current.length > maxEvents
          ? current.sublist(current.length - maxEvents)
          : current;
      await storage.write(_key(entry.key), jsonEncode(kept));
    }
  }

  Future<List<Map<String, Object?>>> _readRaw(
    StorageService storage,
    String businessId,
  ) async {
    try {
      final raw = await storage.read(_key(businessId));
      if (raw == null || raw.isEmpty) return [];
      final decoded = jsonDecode(raw);
      if (decoded is! List) return [];
      return [
        for (final entry in decoded)
          if (entry is Map) Map<String, Object?>.from(entry),
      ];
    } catch (_) {
      return [];
    }
  }

  /// Eventos guardados de [businessId], del más viejo al más nuevo (incluye
  /// los que aún no se escribían).
  Future<List<Map<String, Object?>>> read(String businessId) async {
    // El guardado pendiente se agenda en una microtarea anterior a esta:
    // dejarla correr y esperar su escritura.
    await Future<void>.microtask(() {});
    await _writing;
    final storage = await StorageService.getInstance();
    return [...await _readRaw(storage, businessId), ...?_buffer[businessId]];
  }

  /// Texto para copiar y compartir (soporte).
  static String format(List<Map<String, Object?>> events) {
    String two(int v) => v.toString().padLeft(2, '0');
    final lines = <String>[];
    for (final e in events) {
      final at = DateTime.tryParse(e['at']?.toString() ?? '')?.toLocal();
      final clock = at == null
          ? '--:--:--'
          : '${two(at.day)}/${two(at.month)} '
                '${two(at.hour)}:${two(at.minute)}:${two(at.second)}';
      final order = e['order']?.toString();
      lines.add(
        [
          clock,
          e['ev'],
          if (e['type'] != null) e['type'],
          if (order != null && order.isNotEmpty)
            'orden ${order.length > 8 ? order.substring(0, 8) : order}',
          if (e['op'] != null) 'op ${e['op']}',
          if (e['detail'] != null) '— ${e['detail']}',
        ].join(' · '),
      );
    }
    return lines.join('\n');
  }
}
