// Modelos data-layer de Printing v2 (Fase 1).
//
// Cubren las tablas/extensiones introducidas por las migraciones
// 20260521_0001..0008:
//   - menu_item_print_areas       → MenuItemPrintArea
//   - device_printer_bindings     → DevicePrinterBinding
//   - printer_health              → PrinterHealthRecord + PrinterHealthStatus
//   - device_agents (extendida)   → DeviceAgent
//
// Convención: cada clase tiene fromMap()/toMap() simétricos. Equatable para
// comparación por valor (útil en tests y notifiers). `@immutable` no porque
// extendemos Equatable que ya garantiza igualdad estructural.
//
// NOTA importante:
//   El archivo `printing_health_state.dart` (presentation layer) define una
//   clase llamada `PrinterHealth` que es UI agregada — combina el row de
//   `printers` con counts de jobs y deriva un `PrinterHealthLevel` (verde/
//   amarillo/rojo). NO confundir con `PrinterHealthRecord` (este archivo)
//   que es el row directo de la tabla `printer_health` (status granular:
//   no_paper / cover_open / etc).

import 'package:equatable/equatable.dart';

// ═════════════════════════════════════════════════════════════════════════════
// 1) MenuItemPrintArea — relación N:M productos ↔ áreas
// ═════════════════════════════════════════════════════════════════════════════

/// Vincula un `menu_items` a un `print_areas` (uno-a-muchos). Reemplaza
/// progresivamente al campo legacy `menu_items.print_area_code` que solo
/// permitía un área por producto.
class MenuItemPrintArea extends Equatable {
  final String menuItemId;
  final String printAreaId;
  final DateTime createdAt;

  const MenuItemPrintArea({
    required this.menuItemId,
    required this.printAreaId,
    required this.createdAt,
  });

  factory MenuItemPrintArea.fromMap(Map<String, dynamic> map) {
    return MenuItemPrintArea(
      menuItemId: map['menu_item_id']?.toString() ?? '',
      printAreaId: map['print_area_id']?.toString() ?? '',
      createdAt: _parseDateTime(map['created_at']) ?? DateTime.now(),
    );
  }

  Map<String, dynamic> toMap() => {
    'menu_item_id': menuItemId,
    'print_area_id': printAreaId,
    'created_at': createdAt.toIso8601String(),
  };

  @override
  List<Object?> get props => [menuItemId, printAreaId, createdAt];
}

// ═════════════════════════════════════════════════════════════════════════════
// 2) DevicePrinterBinding — device ↔ impresora (USB/BT)
// ═════════════════════════════════════════════════════════════════════════════

/// Marca que un device físico (PC/tablet) es el "dueño" de una impresora
/// USB o Bluetooth. Solo ese device puede imprimir físicamente en ella; los
/// jobs encolados con `target_device_id = device_id` se rutean a ese agent.
/// Para impresoras LAN esta tabla es opcional.
class DevicePrinterBinding extends Equatable {
  final String deviceId;
  final String printerId;
  final bool isLocalOwner;
  final DateTime pairedAt;
  final String? notes;

  const DevicePrinterBinding({
    required this.deviceId,
    required this.printerId,
    this.isLocalOwner = true,
    required this.pairedAt,
    this.notes,
  });

  factory DevicePrinterBinding.fromMap(Map<String, dynamic> map) {
    return DevicePrinterBinding(
      deviceId: map['device_id']?.toString() ?? '',
      printerId: map['printer_id']?.toString() ?? '',
      isLocalOwner: map['is_local_owner'] != false,
      pairedAt: _parseDateTime(map['paired_at']) ?? DateTime.now(),
      notes: (map['notes'] as String?)?.trim().isEmpty == true
          ? null
          : map['notes'] as String?,
    );
  }

  Map<String, dynamic> toMap() => {
    'device_id': deviceId,
    'printer_id': printerId,
    'is_local_owner': isLocalOwner,
    'paired_at': pairedAt.toIso8601String(),
    'notes': notes,
  };

  DevicePrinterBinding copyWith({
    String? deviceId,
    String? printerId,
    bool? isLocalOwner,
    DateTime? pairedAt,
    String? notes,
  }) {
    return DevicePrinterBinding(
      deviceId: deviceId ?? this.deviceId,
      printerId: printerId ?? this.printerId,
      isLocalOwner: isLocalOwner ?? this.isLocalOwner,
      pairedAt: pairedAt ?? this.pairedAt,
      notes: notes ?? this.notes,
    );
  }

  @override
  List<Object?> get props =>
      [deviceId, printerId, isLocalOwner, pairedAt, notes];
}

// ═════════════════════════════════════════════════════════════════════════════
// 3) PrinterHealth — status granular por impresora
// ═════════════════════════════════════════════════════════════════════════════

/// Estados granulares reportados por el agent vía `fn_report_printer_health`.
/// Mapean 1:1 al CHECK de la tabla `printer_health.status`.
enum PrinterHealthStatus {
  online,
  offline,
  lowPaper,
  noPaper,
  coverOpen,
  error,
  unknown,
}

extension PrinterHealthStatusX on PrinterHealthStatus {
  String get wireName => switch (this) {
    PrinterHealthStatus.online => 'online',
    PrinterHealthStatus.offline => 'offline',
    PrinterHealthStatus.lowPaper => 'low_paper',
    PrinterHealthStatus.noPaper => 'no_paper',
    PrinterHealthStatus.coverOpen => 'cover_open',
    PrinterHealthStatus.error => 'error',
    PrinterHealthStatus.unknown => 'unknown',
  };

  static PrinterHealthStatus fromName(String? value) {
    final normalized = value?.trim().toLowerCase();
    return switch (normalized) {
      'online' => PrinterHealthStatus.online,
      'offline' => PrinterHealthStatus.offline,
      'low_paper' || 'lowpaper' => PrinterHealthStatus.lowPaper,
      'no_paper' || 'nopaper' => PrinterHealthStatus.noPaper,
      'cover_open' || 'coveropen' => PrinterHealthStatus.coverOpen,
      'error' => PrinterHealthStatus.error,
      _ => PrinterHealthStatus.unknown,
    };
  }

  /// True si la impresora puede recibir jobs ahora mismo.
  bool get isOperational => switch (this) {
    PrinterHealthStatus.online || PrinterHealthStatus.lowPaper => true,
    _ => false,
  };

  /// True si requiere acción del staff (sin papel, tapa, error).
  bool get needsAttention => switch (this) {
    PrinterHealthStatus.noPaper ||
    PrinterHealthStatus.coverOpen ||
    PrinterHealthStatus.error => true,
    _ => false,
  };
}

/// Row de la tabla `printer_health` (Printing v2). DB-layer puro.
///
/// NO confundir con `PrinterHealth` (presentation layer, en
/// `printing_health_state.dart`) que es la representación agregada que
/// combina este record con counts de jobs para derivar un nivel de salud
/// agregado (`PrinterHealthLevel.ok/warning/down`).
class PrinterHealthRecord extends Equatable {
  final String printerId;
  final PrinterHealthStatus status;
  final DateTime lastCheckedAt;
  final int consecutiveFailures;
  final String? lastProbedByDeviceId;
  final Map<String, dynamic> details;
  final DateTime updatedAt;

  const PrinterHealthRecord({
    required this.printerId,
    required this.status,
    required this.lastCheckedAt,
    this.consecutiveFailures = 0,
    this.lastProbedByDeviceId,
    this.details = const {},
    required this.updatedAt,
  });

  factory PrinterHealthRecord.fromMap(Map<String, dynamic> map) {
    return PrinterHealthRecord(
      printerId: map['printer_id']?.toString() ?? '',
      status: PrinterHealthStatusX.fromName(map['status']?.toString()),
      lastCheckedAt: _parseDateTime(map['last_checked_at']) ?? DateTime.now(),
      consecutiveFailures: (map['consecutive_failures'] as num?)?.toInt() ?? 0,
      lastProbedByDeviceId: (map['last_probed_by_device_id'] as String?)
              ?.trim()
              .isEmpty ==
          true
          ? null
          : map['last_probed_by_device_id'] as String?,
      details: _readJsonMap(map['details']),
      updatedAt: _parseDateTime(map['updated_at']) ?? DateTime.now(),
    );
  }

  Map<String, dynamic> toMap() => {
    'printer_id': printerId,
    'status': status.wireName,
    'last_checked_at': lastCheckedAt.toIso8601String(),
    'consecutive_failures': consecutiveFailures,
    'last_probed_by_device_id': lastProbedByDeviceId,
    'details': details,
    'updated_at': updatedAt.toIso8601String(),
  };

  @override
  List<Object?> get props => [
    printerId,
    status,
    lastCheckedAt,
    consecutiveFailures,
    lastProbedByDeviceId,
    details,
    updatedAt,
  ];
}

// ═════════════════════════════════════════════════════════════════════════════
// 4) DeviceAgent — row de la tabla device_agents (extendida en v2)
// ═════════════════════════════════════════════════════════════════════════════

/// Representa un agent local registrado para un device del business. El agent
/// hace UPSERT a esta fila cada ~30s vía `fn_device_agent_heartbeat`. Combina
/// los campos preexistentes (PRD 5 F2.5: id, business_id, device_name,
/// agent_url, platform, online, last_heartbeat_at) con los nuevos de v2
/// (agent_version, os, hostname, available_transports, metadata).
class DeviceAgent extends Equatable {
  final String id;
  final String businessId;
  final String? deviceName;
  final String? agentUrl;
  final String? platform;
  final bool online;
  final DateTime? lastHeartbeatAt;
  final DateTime createdAt;
  final DateTime updatedAt;
  // v2
  final String? agentVersion;
  final String? os;
  final String? hostname;
  final List<String> availableTransports;
  final Map<String, dynamic> metadata;

  const DeviceAgent({
    required this.id,
    required this.businessId,
    this.deviceName,
    this.agentUrl,
    this.platform,
    this.online = false,
    this.lastHeartbeatAt,
    required this.createdAt,
    required this.updatedAt,
    this.agentVersion,
    this.os,
    this.hostname,
    this.availableTransports = const [],
    this.metadata = const {},
  });

  factory DeviceAgent.fromMap(Map<String, dynamic> map) {
    return DeviceAgent(
      id: map['id']?.toString() ?? '',
      businessId: map['business_id']?.toString() ?? '',
      deviceName: (map['device_name'] as String?)?.trim().isEmpty == true
          ? null
          : map['device_name'] as String?,
      agentUrl: (map['agent_url'] as String?)?.trim().isEmpty == true
          ? null
          : map['agent_url'] as String?,
      platform: (map['platform'] as String?)?.trim().isEmpty == true
          ? null
          : map['platform'] as String?,
      online: map['online'] == true,
      lastHeartbeatAt: _parseDateTime(map['last_heartbeat_at']),
      createdAt: _parseDateTime(map['created_at']) ?? DateTime.now(),
      updatedAt: _parseDateTime(map['updated_at']) ?? DateTime.now(),
      agentVersion: (map['agent_version'] as String?)?.trim().isEmpty == true
          ? null
          : map['agent_version'] as String?,
      os: (map['os'] as String?)?.trim().isEmpty == true
          ? null
          : map['os'] as String?,
      hostname: (map['hostname'] as String?)?.trim().isEmpty == true
          ? null
          : map['hostname'] as String?,
      availableTransports: _readStringList(map['available_transports']),
      metadata: _readJsonMap(map['metadata']),
    );
  }

  Map<String, dynamic> toMap() => {
    'id': id,
    'business_id': businessId,
    'device_name': deviceName,
    'agent_url': agentUrl,
    'platform': platform,
    'online': online,
    'last_heartbeat_at': lastHeartbeatAt?.toIso8601String(),
    'created_at': createdAt.toIso8601String(),
    'updated_at': updatedAt.toIso8601String(),
    'agent_version': agentVersion,
    'os': os,
    'hostname': hostname,
    'available_transports': availableTransports,
    'metadata': metadata,
  };

  /// True si el heartbeat es reciente (<90s). Coincide con el threshold
  /// usado por `fn_mark_stale_device_agents_offline`.
  bool get isHeartbeatFresh {
    final hb = lastHeartbeatAt;
    if (hb == null) return false;
    return DateTime.now().toUtc().difference(hb.toUtc()) <
        const Duration(seconds: 90);
  }

  @override
  List<Object?> get props => [
    id,
    businessId,
    deviceName,
    agentUrl,
    platform,
    online,
    lastHeartbeatAt,
    createdAt,
    updatedAt,
    agentVersion,
    os,
    hostname,
    availableTransports,
    metadata,
  ];
}

// ═════════════════════════════════════════════════════════════════════════════
// Helpers compartidos
// ═════════════════════════════════════════════════════════════════════════════

DateTime? _parseDateTime(dynamic raw) {
  if (raw == null) return null;
  if (raw is DateTime) return raw;
  final s = raw.toString().trim();
  if (s.isEmpty) return null;
  return DateTime.tryParse(s);
}

Map<String, dynamic> _readJsonMap(dynamic raw) {
  if (raw == null) return const {};
  if (raw is Map<String, dynamic>) return raw;
  if (raw is Map) return Map<String, dynamic>.from(raw);
  return const {};
}

List<String> _readStringList(dynamic raw) {
  if (raw == null) return const [];
  if (raw is List) {
    return raw
        .where((e) => e != null)
        .map((e) => e.toString())
        .where((s) => s.isNotEmpty)
        .toList(growable: false);
  }
  return const [];
}
