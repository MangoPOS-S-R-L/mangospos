// Sprint 5 — Estado del dashboard "Salud de impresión".
//
// Modela cada impresora del negocio con sus métricas de la última hora
// (pending, failed, printing) y un nivel agregado de salud (verde,
// amarillo, rojo). También guarda la lista de jobs activos para la
// sección "Cola pendiente".

import 'package:equatable/equatable.dart';

import 'package:mangopos/data/models/printing_v2.dart';

/// Nivel de salud agregado por impresora. Lo deriva la viewmodel a
/// partir de online + last_seen + counts de jobs.
enum PrinterHealthLevel {
  /// Online, sin failed, pocos pending → semáforo verde.
  ok,

  /// Online pero con pending acumulado o failed transitorios →
  /// semáforo amarillo. Atención pero no crítico.
  warning,

  /// Offline (sin heartbeat reciente) o failed terminales →
  /// semáforo rojo. Acción del cajero requerida.
  down,
}

class PrinterHealth extends Equatable {
  final String id;
  final String name;
  final String type;
  final bool online;
  final DateTime? lastSeen;
  final String? hostDeviceId;
  final String? fallbackPrinterId;
  final int pendingCount;
  final int failedCount;
  final int printingCount;
  /// Slice C — Status granular reportado por el agent vía `printer_health`
  /// (Fase 1). NULL = nunca reportó (el agent no soporta probe o no corrió
  /// todavía). Posibles: online / offline / low_paper / no_paper /
  /// cover_open / error / unknown.
  final PrinterHealthStatus? granularStatus;

  const PrinterHealth({
    required this.id,
    required this.name,
    required this.type,
    required this.online,
    this.lastSeen,
    this.hostDeviceId,
    this.fallbackPrinterId,
    this.pendingCount = 0,
    this.failedCount = 0,
    this.printingCount = 0,
    this.granularStatus,
  });

  factory PrinterHealth.fromMap(Map<String, dynamic> map) {
    return PrinterHealth(
      id: map['id']?.toString() ?? '',
      name: map['name']?.toString() ?? 'Sin nombre',
      type: map['type']?.toString() ?? 'network',
      online: map['online'] == true,
      lastSeen: map['last_seen'] == null
          ? null
          : DateTime.tryParse(map['last_seen'].toString()),
      hostDeviceId: map['host_device_id']?.toString(),
      fallbackPrinterId: map['fallback_printer_id']?.toString(),
      pendingCount: (map['pending_count'] as num?)?.toInt() ?? 0,
      failedCount: (map['failed_count'] as num?)?.toInt() ?? 0,
      printingCount: (map['printing_count'] as num?)?.toInt() ?? 0,
    );
  }

  PrinterHealth copyWith({
    PrinterHealthStatus? granularStatus,
  }) {
    return PrinterHealth(
      id: id,
      name: name,
      type: type,
      online: online,
      lastSeen: lastSeen,
      hostDeviceId: hostDeviceId,
      fallbackPrinterId: fallbackPrinterId,
      pendingCount: pendingCount,
      failedCount: failedCount,
      printingCount: printingCount,
      granularStatus: granularStatus ?? this.granularStatus,
    );
  }

  /// Calcula el nivel de salud agregado. Reglas:
  /// - `down`: offline, jobs failed terminales, o status granular crítico
  ///   (offline / cover_open / error).
  /// - `warning`: online pero con pendingCount ≥ 5, printingCount alto,
  ///   lastSeen entre 60s y 5min, o status granular menor (no_paper /
  ///   low_paper).
  /// - `ok`: el resto (online, sin colas grandes, heartbeat fresco).
  ///
  /// Slice C: el `granularStatus` (de printer_health table) tiene
  /// PRECEDENCIA cuando está poblado — refleja un probe real al hardware
  /// más reciente que los heurísticos de jobs/heartbeat.
  PrinterHealthLevel get level {
    // Si el agent reportó status granular, usar eso como verdad principal.
    final granular = granularStatus;
    if (granular != null) {
      if (granular == PrinterHealthStatus.offline ||
          granular == PrinterHealthStatus.coverOpen ||
          granular == PrinterHealthStatus.error) {
        return PrinterHealthLevel.down;
      }
      if (granular == PrinterHealthStatus.noPaper ||
          granular == PrinterHealthStatus.lowPaper) {
        return PrinterHealthLevel.warning;
      }
      // online / unknown → seguir con heurísticos legacy.
    }

    if (!online) return PrinterHealthLevel.down;
    if (failedCount > 0) return PrinterHealthLevel.down;
    final ls = lastSeen;
    if (ls != null) {
      final age = DateTime.now().toUtc().difference(ls.toUtc());
      if (age > const Duration(minutes: 5)) {
        return PrinterHealthLevel.down;
      }
      if (age > const Duration(seconds: 60)) {
        return PrinterHealthLevel.warning;
      }
    }
    if (pendingCount >= 5) return PrinterHealthLevel.warning;
    return PrinterHealthLevel.ok;
  }

  /// Slice C: label human-readable del status granular para mostrar en UI.
  /// Retorna NULL si no hay granular reportado (caer al display legacy).
  String? get granularStatusLabel => switch (granularStatus) {
        null => null,
        PrinterHealthStatus.online => null, // no agrega info
        PrinterHealthStatus.offline => 'Offline',
        PrinterHealthStatus.lowPaper => 'Poco papel',
        PrinterHealthStatus.noPaper => 'Sin papel',
        PrinterHealthStatus.coverOpen => 'Tapa abierta',
        PrinterHealthStatus.error => 'Error',
        PrinterHealthStatus.unknown => null,
      };

  @override
  List<Object?> get props => [
    id,
    name,
    type,
    online,
    lastSeen,
    hostDeviceId,
    fallbackPrinterId,
    pendingCount,
    failedCount,
    printingCount,
    granularStatus,
  ];
}

class PrintJobRow extends Equatable {
  final String id;
  final String? printerId;
  final String? printerName;
  final String? printerType;
  final String? areaCode;
  final String? kind;
  final String status;
  final int retryCount;
  final String? lastError;
  final DateTime? nextRetryAt;
  final DateTime createdAt;
  final int failoverCount;
  final String? originalPrinterId;

  const PrintJobRow({
    required this.id,
    this.printerId,
    this.printerName,
    this.printerType,
    this.areaCode,
    this.kind,
    required this.status,
    required this.retryCount,
    this.lastError,
    this.nextRetryAt,
    required this.createdAt,
    this.failoverCount = 0,
    this.originalPrinterId,
  });

  factory PrintJobRow.fromMap(Map<String, dynamic> map) {
    final printerJoin = map['printers'] as Map<String, dynamic>?;
    return PrintJobRow(
      id: map['id']?.toString() ?? '',
      printerId: map['printer_id']?.toString(),
      printerName: printerJoin?['name']?.toString(),
      printerType: printerJoin?['type']?.toString(),
      areaCode: map['area_code']?.toString(),
      kind: map['kind']?.toString(),
      status: map['status']?.toString() ?? 'pending',
      retryCount: (map['retry_count'] as num?)?.toInt() ?? 0,
      lastError: map['last_error']?.toString() ?? map['error']?.toString(),
      nextRetryAt: map['next_retry_at'] == null
          ? null
          : DateTime.tryParse(map['next_retry_at'].toString()),
      createdAt: map['created_at'] == null
          ? DateTime.now()
          : (DateTime.tryParse(map['created_at'].toString()) ?? DateTime.now()),
      failoverCount: (map['failover_count'] as num?)?.toInt() ?? 0,
      originalPrinterId: map['original_printer_id']?.toString(),
    );
  }

  /// True si el job está terminal (5 retries agotados, sin next_retry).
  /// La UI puede ofrecer "Reintentar" para resetear retry_count.
  bool get isTerminalFailed =>
      status == 'failed' && retryCount >= 5 && nextRetryAt == null;

  /// True si está en backoff esperando próximo intento automático.
  bool get isPendingRetry =>
      status == 'failed' && retryCount < 5 && nextRetryAt != null;

  @override
  List<Object?> get props => [
    id,
    printerId,
    printerName,
    printerType,
    areaCode,
    kind,
    status,
    retryCount,
    lastError,
    nextRetryAt,
    createdAt,
    failoverCount,
    originalPrinterId,
  ];
}

class PrintingHealthState extends Equatable {
  final List<PrinterHealth> printers;
  final List<PrintJobRow> activeJobs;
  final bool loading;
  final String? error;
  final DateTime? lastUpdatedAt;

  const PrintingHealthState({
    this.printers = const [],
    this.activeJobs = const [],
    this.loading = false,
    this.error,
    this.lastUpdatedAt,
  });

  PrintingHealthState copyWith({
    List<PrinterHealth>? printers,
    List<PrintJobRow>? activeJobs,
    bool? loading,
    String? error,
    bool clearError = false,
    DateTime? lastUpdatedAt,
  }) {
    return PrintingHealthState(
      printers: printers ?? this.printers,
      activeJobs: activeJobs ?? this.activeJobs,
      loading: loading ?? this.loading,
      error: clearError ? null : (error ?? this.error),
      lastUpdatedAt: lastUpdatedAt ?? this.lastUpdatedAt,
    );
  }

  /// Jobs failed terminales (>=5 intentos, sin next_retry). Si > 0,
  /// la UI muestra banner naranja al tope llamando la atención.
  int get terminalFailedJobsCount =>
      activeJobs.where((j) => j.isTerminalFailed).length;

  /// Total de jobs pendientes/en proceso/en retry.
  int get jobsInFlight =>
      activeJobs.where((j) => !j.isTerminalFailed).length;

  @override
  List<Object?> get props => [
    printers,
    activeJobs,
    loading,
    error,
    lastUpdatedAt,
  ];
}
