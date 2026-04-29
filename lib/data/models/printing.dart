import 'dart:convert';

import 'package:flutter/foundation.dart';

/// Connection types supported by the printing service.
enum PrinterType { network, bluetooth, usb }

extension PrinterTypeX on PrinterType {
  static PrinterType fromName(String? value) {
    final normalized = value?.trim().toLowerCase();
    switch (normalized) {
      case 'bluetooth':
      case 'bt':
        return PrinterType.bluetooth;
      case 'usb':
        return PrinterType.usb;
      case 'network':
      case 'tcp':
      case 'lan':
      default:
        return PrinterType.network;
    }
  }

  String get label {
    switch (this) {
      case PrinterType.network:
        return 'network';
      case PrinterType.bluetooth:
        return 'bluetooth';
      case PrinterType.usb:
        return 'usb';
    }
  }
}

@immutable
class PrinterDevice {
  const PrinterDevice({
    required this.id,
    required this.businessId,
    required this.name,
    this.ip,
    this.port,
    this.mac,
    this.devicePath,
    required this.type,
    required this.online,
    this.lastSeen,
    this.paperWidth = 80,
    this.encoding = 'CP437',
    required this.createdAt,
  });

  final String id;
  final String businessId;
  final String name;
  final String? ip;
  final int? port;
  final String? mac;
  final String? devicePath;
  final PrinterType type;
  final bool online;
  final DateTime? lastSeen;
  final int paperWidth;
  final String encoding;
  final DateTime createdAt;

  factory PrinterDevice.fromMap(Map<String, dynamic> map) {
    final normalized = PrinterFieldMapper.normalize(map);
    return PrinterDevice(
      id: normalized['id'] as String,
      businessId: normalized['business_id'] as String,
      name: normalized['name'] as String,
      ip: normalized['ip'] as String?,
      port: normalized['port'] as int?,
      mac: normalized['mac'] as String?,
      devicePath: normalized['device_path'] as String?,
      type: PrinterTypeX.fromName(normalized['type'] as String?),
      online: normalized['online'] as bool,
      lastSeen: normalized['last_seen'] as DateTime?,
      paperWidth: normalized['paper_width'] as int,
      encoding: normalized['encoding'] as String,
      createdAt: normalized['created_at'] as DateTime,
    );
  }

  factory PrinterDevice.fromConfig(PrinterConfig config) {
    return PrinterDevice(
      id: config.id,
      businessId: config.businessId,
      name: config.name,
      ip: config.ipAddress,
      port: config.port,
      mac: config.mac,
      devicePath: config.devicePath,
      type: config.printerType,
      online: config.online,
      lastSeen: config.lastSeen,
      paperWidth: config.paperWidth,
      encoding: config.encoding,
      createdAt: config.createdAt,
    );
  }

  Map<String, dynamic> toMap() {
    final ipValue = ip;
    final macValue = mac;
    return {
      'id': id,
      'business_id': businessId,
      'name': name,
      'ip': ipValue == null || ipValue.isEmpty ? null : ipValue,
      'ip_address': ipValue == null || ipValue.isEmpty ? null : ipValue,
      'port': port,
      'mac': macValue == null || macValue.isEmpty ? null : macValue,
      'device_path': devicePath,
      'type': type.name,
      'online': online,
      'is_active': online,
      'paper_width': paperWidth,
      'encoding': encoding,
      'last_seen': lastSeen?.toIso8601String(),
      'created_at': createdAt.toIso8601String(),
    };
  }

  PrinterDevice copyWith({
    String? id,
    String? businessId,
    String? name,
    String? ip,
    int? port,
    String? mac,
    String? devicePath,
    PrinterType? type,
    bool? online,
    DateTime? lastSeen,
    int? paperWidth,
    String? encoding,
    DateTime? createdAt,
  }) {
    return PrinterDevice(
      id: id ?? this.id,
      businessId: businessId ?? this.businessId,
      name: name ?? this.name,
      ip: ip ?? this.ip,
      port: port ?? this.port,
      mac: mac ?? this.mac,
      devicePath: devicePath ?? this.devicePath,
      type: type ?? this.type,
      online: online ?? this.online,
      lastSeen: lastSeen ?? this.lastSeen,
      paperWidth: paperWidth ?? this.paperWidth,
      encoding: encoding ?? this.encoding,
      createdAt: createdAt ?? this.createdAt,
    );
  }
}

@immutable
class PrintArea {
  const PrintArea({
    required this.id,
    required this.businessId,
    required this.name,
    required this.createdAt,
    this.productsCount = 0,
  });

  final String id;
  final String businessId;
  final String name;
  final DateTime createdAt;
  final int productsCount;

  factory PrintArea.fromMap(Map<String, dynamic> map) {
    return PrintArea(
      id: map['id'] as String,
      businessId: map['business_id'] as String,
      name: map['name'] as String,
      createdAt: map['created_at'] == null
          ? DateTime.now()
          : DateTime.parse(map['created_at'] as String),
      productsCount: (map['products_count'] as int?) ?? 0,
    );
  }
}

@immutable
class PrintAreaPrinter {
  const PrintAreaPrinter({
    required this.id,
    required this.businessId,
    required this.areaId,
    required this.printerId,
    this.enabled = true,
    this.printsOrders = true,
    this.printsPrebills = false,
    this.printsReceipts = false,
  });

  final String id;
  final String businessId;
  final String areaId;
  final String printerId;
  final bool enabled;
  final bool printsOrders;
  final bool printsPrebills;
  final bool printsReceipts;

  factory PrintAreaPrinter.fromMap(Map<String, dynamic> map) {
    return PrintAreaPrinter(
      id: map['id'] as String,
      businessId: map['business_id'] as String,
      areaId: map['area_id'] as String,
      printerId: map['printer_id'] as String,
      enabled: (map['enabled'] as bool?) ?? true,
      printsOrders: (map['prints_orders'] as bool?) ?? true,
      printsPrebills: (map['prints_prebills'] as bool?) ?? false,
      printsReceipts: (map['prints_receipts'] as bool?) ?? false,
    );
  }

  Map<String, dynamic> toMap() {
    return {
      'id': id,
      'business_id': businessId,
      'area_id': areaId,
      'printer_id': printerId,
      'enabled': enabled,
      'prints_orders': printsOrders,
      'prints_prebills': printsPrebills,
      'prints_receipts': printsReceipts,
    };
  }
}

@immutable
class PrinterUsageSummary {
  const PrinterUsageSummary({
    this.assignedAreas = 0,
    this.ordersAssignments = 0,
    this.prebillAssignments = 0,
    this.receiptAssignments = 0,
  });

  final int assignedAreas;
  final int ordersAssignments;
  final int prebillAssignments;
  final int receiptAssignments;
}

/// 🖨️ Configuración de impresora (legacy support)
@immutable
class PrinterConfig {
  final String id;
  final String businessId;
  final String name;
  final String type; // 'network', 'usb', 'bluetooth'
  final String? ipAddress;
  final int? port;
  final String? devicePath;
  final String? mac;
  final bool isActive;
  final int paperWidth; // 58mm, 80mm
  final String encoding; // 'CP437', 'CP850', 'UTF-8'
  final DateTime? lastSeen;
  final DateTime createdAt;

  /// PRD 5 F2.5: si la impresora es USB/BT, este es el UUID del device
  /// (de `device_agents.id`) que la tiene físicamente conectada. NULL para
  /// impresoras de red. Cuando otro device del business quiere imprimir,
  /// el frontend lookups `device_agents.agent_url` y rutea via HTTP.
  final String? hostDeviceId;

  const PrinterConfig({
    required this.id,
    required this.businessId,
    required this.name,
    required this.type,
    this.ipAddress,
    this.port,
    this.devicePath,
    this.mac,
    required this.isActive,
    this.paperWidth = 80,
    this.encoding = 'CP437',
    this.lastSeen,
    required this.createdAt,
    this.hostDeviceId,
  });

  factory PrinterConfig.fromMap(Map<String, dynamic> map) {
    final normalized = PrinterFieldMapper.normalize(map);
    return PrinterConfig(
      id: normalized['id'] as String,
      businessId: normalized['business_id'] as String,
      name: normalized['name'] as String,
      type: (normalized['type'] as String?) ?? PrinterType.network.name,
      ipAddress: normalized['ip'] as String?,
      port: normalized['port'] as int?,
      devicePath: normalized['device_path'] as String?,
      mac: normalized['mac'] as String?,
      isActive: normalized['online'] as bool,
      paperWidth: normalized['paper_width'] as int,
      encoding: normalized['encoding'] as String,
      lastSeen: normalized['last_seen'] as DateTime?,
      createdAt: normalized['created_at'] as DateTime,
      hostDeviceId: map['host_device_id'] as String?,
    );
  }

  bool get isNetwork => printerType == PrinterType.network;
  bool get isUSB => printerType == PrinterType.usb;
  bool get isBluetooth => printerType == PrinterType.bluetooth;
  PrinterType get printerType => PrinterTypeX.fromName(type);
  bool get online => isActive;
  String? get ip => ipAddress;

  Map<String, dynamic> toMap() {
    final ipValue = ipAddress?.trim();
    final macValue = mac?.trim();
    return {
      'id': id,
      'business_id': businessId,
      'name': name,
      'type': printerType.name,
      'ip': ipValue == null || ipValue.isEmpty ? null : ipValue,
      'ip_address': ipValue == null || ipValue.isEmpty ? null : ipValue,
      'port': port,
      'device_path': devicePath,
      'mac': macValue == null || macValue.isEmpty ? null : macValue,
      'online': isActive,
      'is_active': isActive,
      'paper_width': paperWidth,
      'encoding': encoding,
      'last_seen': lastSeen?.toIso8601String(),
      'created_at': createdAt.toIso8601String(),
      'host_device_id': hostDeviceId,
    };
  }
}

/// 📄 Trabajo de impresión
@immutable
class PrintJob {
  final String id;
  final String businessId;
  final String areaId;
  final String? orderId;
  final String? checkId;
  final String
  type; // 'kitchen_order', 'precheck', 'fiscal_invoice', 'cash_close'
  final String status; // 'pending', 'printing', 'printed', 'failed'
  final Map<String, dynamic> data;
  final String? printerId;
  final int retryCount;
  final String? errorMessage;
  final DateTime createdAt;
  final DateTime? printedAt;

  const PrintJob({
    required this.id,
    required this.businessId,
    required this.areaId,
    this.orderId,
    this.checkId,
    required this.type,
    required this.status,
    required this.data,
    this.printerId,
    this.retryCount = 0,
    this.errorMessage,
    required this.createdAt,
    this.printedAt,
  });

  factory PrintJob.fromMap(Map<String, dynamic> map) {
    final payload = _decodePrintJobPayload(map['data_hex']);
    final payloadData = payload['data'];

    return PrintJob(
      id: map['id'] ?? '',
      businessId: map['business_id'] ?? '',
      areaId: map['area_id'] ?? payload['area_id'] ?? '',
      orderId: map['order_id'] ?? payload['order_id'],
      checkId: map['check_id'] ?? payload['check_id'],
      type: map['type'] ?? payload['type'] ?? '',
      status: map['status'] ?? 'pending',
      data: map['data'] is Map<String, dynamic>
          ? Map<String, dynamic>.from(map['data'])
          : payloadData is Map<String, dynamic>
          ? Map<String, dynamic>.from(payloadData)
          : {},
      printerId: map['printer_id'],
      retryCount: map['retry_count'] ?? 0,
      errorMessage: map['error_message'] ?? map['error'],
      createdAt: DateTime.tryParse(map['created_at'] ?? '') ?? DateTime.now(),
      printedAt: map['printed_at'] != null
          ? DateTime.tryParse(map['printed_at'])
          : null,
    );
  }

  bool get isPending => status == 'pending';
  bool get isPrinting => status == 'printing';
  bool get isPrinted => status == 'printed';
  bool get isFailed => status == 'failed';
}

/// 🎫 Ticket generado para imprimir
@immutable
class PrintTicket {
  final String type;
  final List<int> escPosCommands;
  final String? rawText;

  const PrintTicket({
    required this.type,
    required this.escPosCommands,
    this.rawText,
  });
}

final class PrinterFieldMapper {
  const PrinterFieldMapper._();

  static Map<String, dynamic> normalize(Map<String, dynamic> map) {
    final ip = _readString(map, const ['ip', 'ip_address']);
    final rawType = _readString(map, const ['type']);
    final printerType = PrinterTypeX.fromName(rawType);

    return {
      'id': _readString(map, const ['id']) ?? '',
      'business_id': _readString(map, const ['business_id']) ?? '',
      'name': _readString(map, const ['name']) ?? 'Printer',
      'ip': ip,
      'mac': _readString(map, const ['mac']),
      'type': printerType.name,
      'online': _readBool(map, const ['online', 'is_active']) ?? false,
      'last_seen': _readDateTime(map, const ['last_seen']),
      'created_at': _readDateTime(map, const ['created_at']) ?? DateTime.now(),
      'port': _readInt(map, const ['port']),
      'device_path': _readString(map, const ['device_path']),
      'paper_width': _readInt(map, const ['paper_width']) ?? 80,
      'encoding': _readString(map, const ['encoding']) ?? 'CP437',
    };
  }

  static String? _readString(Map<String, dynamic> map, List<String> keys) {
    for (final key in keys) {
      final value = map[key];
      if (value == null) continue;
      final text = value.toString().trim();
      if (text.isNotEmpty) return text;
    }
    return null;
  }

  static bool? _readBool(Map<String, dynamic> map, List<String> keys) {
    for (final key in keys) {
      final value = map[key];
      if (value == null) continue;
      if (value is bool) return value;
      if (value is num) return value != 0;
      final normalized = value.toString().trim().toLowerCase();
      if (normalized == 'true' || normalized == '1') return true;
      if (normalized == 'false' || normalized == '0') return false;
    }
    return null;
  }

  static int? _readInt(Map<String, dynamic> map, List<String> keys) {
    for (final key in keys) {
      final value = map[key];
      if (value == null) continue;
      if (value is int) return value;
      if (value is num) return value.toInt();
      final parsed = int.tryParse(value.toString().trim());
      if (parsed != null) return parsed;
    }
    return null;
  }

  static DateTime? _readDateTime(Map<String, dynamic> map, List<String> keys) {
    for (final key in keys) {
      final value = map[key];
      if (value == null) continue;
      if (value is DateTime) return value;
      final parsed = DateTime.tryParse(value.toString());
      if (parsed != null) return parsed;
    }
    return null;
  }
}

Map<String, dynamic> _decodePrintJobPayload(dynamic rawHex) {
  if (rawHex is! String || rawHex.isEmpty) return const {};
  try {
    final bytes = <int>[];
    for (var i = 0; i < rawHex.length; i += 2) {
      bytes.add(int.parse(rawHex.substring(i, i + 2), radix: 16));
    }
    final decoded = jsonDecode(utf8.decode(bytes));
    return decoded is Map<String, dynamic> ? decoded : const {};
  } catch (_) {
    return const {};
  }
}
