import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';

/// Un job de impresión BLE pendiente de enviar a una impresora concreta.
///
/// El [jobId] es la clave de idempotencia: si el mismo ticket se intenta
/// encolar dos veces (p. ej. un reintento del dispatcher mientras la impresora
/// reconecta), la segunda se ignora y no se duplica el papel.
@immutable
class BlePrintJob {
  const BlePrintJob({
    required this.jobId,
    required this.remoteId,
    required this.data,
    required this.enqueuedAt,
    this.attempts = 0,
  });

  /// Clave de idempotencia (estable por ticket+impresora).
  final String jobId;

  /// remoteId/MAC de la impresora BT destino.
  final String remoteId;

  /// Bytes ESC/POS a enviar.
  final List<int> data;

  final DateTime enqueuedAt;

  /// Cuántas veces se intentó enviar sin éxito.
  final int attempts;

  BlePrintJob withAttempt() => BlePrintJob(
        jobId: jobId,
        remoteId: remoteId,
        data: data,
        enqueuedAt: enqueuedAt,
        attempts: attempts + 1,
      );

  Map<String, dynamic> toJson() => {
        'jobId': jobId,
        'remoteId': remoteId,
        'dataB64': base64Encode(data),
        'enqueuedAt': enqueuedAt.toIso8601String(),
        'attempts': attempts,
      };

  static BlePrintJob? fromJson(Map<String, dynamic> json) {
    try {
      return BlePrintJob(
        jobId: json['jobId'] as String,
        remoteId: json['remoteId'] as String,
        data: base64Decode(json['dataB64'] as String),
        enqueuedAt:
            DateTime.tryParse(json['enqueuedAt'] as String? ?? '') ??
                DateTime.now(),
        attempts: (json['attempts'] as num?)?.toInt() ?? 0,
      );
    } catch (_) {
      return null; // fila corrupta → se descarta al cargar.
    }
  }
}

/// Cola FIFO persistente e idempotente de jobs de impresión BLE (PRD BT — F2.3).
///
/// Los jobs que llegan mientras la impresora está `disconnected`/`reconnecting`
/// se encolan y se vacían en orden al reconectar. La persistencia a disco
/// (JSON en app-support dir) hace que sobrevivan a un reinicio del proceso
/// durante un corte largo; el escenario común (printer apagada/encendida con la
/// app viva) se cubre con la copia en memoria.
///
/// No es thread-safe entre isolates: se asume un único consumidor (el
/// [BlePrinterConnectionManager]).
class BlePrintJobQueue {
  BlePrintJobQueue({this.maxJobs = 500, this.maxAttempts = 10});

  /// Tope duro para no crecer sin límite si una impresora queda muerta. Al
  /// excederlo se descarta el más viejo (con log) — preferible a un OOM.
  final int maxJobs;

  /// Tras este número de intentos fallidos un job se descarta (con log) para
  /// no bloquear indefinidamente la cabeza de la cola.
  final int maxAttempts;

  final List<BlePrintJob> _jobs = [];
  bool _loaded = false;
  final String _fileName = 'ble_print_queue.json';

  /// Escrituras serializadas para no corromper el archivo con saves solapados.
  Future<void> _persistChain = Future.value();

  int get length => _jobs.length;

  bool contains(String jobId) => _jobs.any((j) => j.jobId == jobId);

  /// Carga la cola persistida. Idempotente; seguro de llamar más de una vez.
  Future<void> load() async {
    if (_loaded) return;
    _loaded = true;
    if (kIsWeb) return; // sin FS en web; opera solo en memoria.
    try {
      final file = await _file();
      if (!await file.exists()) return;
      final raw = await file.readAsString();
      if (raw.trim().isEmpty) return;
      final list = jsonDecode(raw);
      if (list is! List) return;
      for (final e in list) {
        if (e is Map<String, dynamic>) {
          final job = BlePrintJob.fromJson(e);
          if (job != null) _jobs.add(job);
        }
      }
      debugPrint('[BleQueue] cargados ${_jobs.length} jobs pendientes');
    } catch (e) {
      debugPrint('[BleQueue] load falló (se ignora): $e');
    }
  }

  /// Encola un job. Devuelve `false` si ya estaba (dedupe por jobId).
  Future<bool> enqueue(BlePrintJob job) async {
    if (contains(job.jobId)) return false;
    _jobs.add(job);
    if (_jobs.length > maxJobs) {
      final dropped = _jobs.removeAt(0);
      debugPrint(
        '[BleQueue] cola llena (>$maxJobs): descartado job más viejo '
        '${dropped.jobId} (remoteId=${dropped.remoteId})',
      );
    }
    await _persist();
    return true;
  }

  /// Jobs pendientes para [remoteId] en orden FIFO.
  List<BlePrintJob> jobsFor(String remoteId) =>
      _jobs.where((j) => j.remoteId == remoteId).toList(growable: false);

  /// Quita un job tras enviarse con éxito.
  Future<void> remove(String jobId) async {
    final before = _jobs.length;
    _jobs.removeWhere((j) => j.jobId == jobId);
    if (_jobs.length != before) await _persist();
  }

  /// Registra un intento fallido. Devuelve `true` si el job se descartó por
  /// superar [maxAttempts] (la cabeza dejaría de bloquear la cola).
  Future<bool> markFailedAttempt(String jobId) async {
    final idx = _jobs.indexWhere((j) => j.jobId == jobId);
    if (idx < 0) return false;
    final next = _jobs[idx].withAttempt();
    if (next.attempts >= maxAttempts) {
      _jobs.removeAt(idx);
      debugPrint(
        '[BleQueue] job $jobId descartado tras ${next.attempts} intentos '
        '(remoteId=${next.remoteId}) — no bloquea la cola',
      );
      await _persist();
      return true;
    }
    _jobs[idx] = next;
    await _persist();
    return false;
  }

  Future<File> _file() async {
    final dir = await getApplicationSupportDirectory();
    return File('${dir.path}/$_fileName');
  }

  Future<void> _persist() {
    if (kIsWeb) return Future.value();
    // Encadenamos para que dos _persist() no escriban a la vez.
    _persistChain = _persistChain.then((_) async {
      try {
        final file = await _file();
        final snapshot = _jobs.map((j) => j.toJson()).toList();
        await file.writeAsString(jsonEncode(snapshot), flush: true);
      } catch (e) {
        debugPrint('[BleQueue] persist falló (se ignora): $e');
      }
    });
    return _persistChain;
  }
}
