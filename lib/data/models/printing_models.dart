import 'package:equatable/equatable.dart';
import 'package:meta/meta.dart';

/// Connection types supported by the printing service.
enum PrinterType { network, bluetooth, usb }

extension PrinterTypeX on PrinterType {
  static PrinterType fromName(String? value) {
    if (value == null) return PrinterType.network;
    return PrinterType.values.firstWhere(
      (type) => type.name == value,
      orElse: () => PrinterType.network,
    );
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
    this.mac,
    required this.type,
    required this.online,
    this.lastSeen,
    required this.createdAt,
  });

  final String id;
  final String businessId;
  final String name;
  final String? ip;
  final String? mac;
  final PrinterType type;
  final bool online;
  final DateTime? lastSeen;
  final DateTime createdAt;

  factory PrinterDevice.fromMap(Map<String, dynamic> map) {
    return PrinterDevice(
      id: map['id'] as String,
      businessId: map['business_id'] as String,
      name: (map['name'] as String?) ?? 'Printer',
      ip: map['ip']?.toString(),
      mac: map['mac'] as String?,
      type: PrinterTypeX.fromName(map['type'] as String?),
      online: (map['online'] as bool?) ?? false,
      lastSeen: map['last_seen'] == null
          ? null
          : DateTime.parse(map['last_seen'] as String),
      createdAt: map['created_at'] == null
          ? DateTime.now()
          : DateTime.parse(map['created_at'] as String),
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
      'mac': macValue == null || macValue.isEmpty ? null : macValue,
      'type': type.name,
      'online': online,
      'last_seen': lastSeen?.toIso8601String(),
    };
  }

  PrinterDevice copyWith({
    String? id,
    String? businessId,
    String? name,
    String? ip,
    String? mac,
    PrinterType? type,
    bool? online,
    DateTime? lastSeen,
    DateTime? createdAt,
  }) {
    return PrinterDevice(
      id: id ?? this.id,
      businessId: businessId ?? this.businessId,
      name: name ?? this.name,
      ip: ip ?? this.ip,
      mac: mac ?? this.mac,
      type: type ?? this.type,
      online: online ?? this.online,
      lastSeen: lastSeen ?? this.lastSeen,
      createdAt: createdAt ?? this.createdAt,
    );
  }
}

/// 🖨️ Configuración de impresora
class PrinterConfig extends Equatable {
  final String id;
  final String businessId;
  final String name;
  final String type; // 'network', 'usb', 'bluetooth'
  final String? ipAddress;
  final int? port;
  final String? devicePath;
  final bool isActive;
  final int paperWidth; // 58mm, 80mm
  final String encoding; // 'CP437', 'CP850', 'UTF-8'

  const PrinterConfig({
    required this.id,
    required this.businessId,
    required this.name,
    required this.type,
    this.ipAddress,
    this.port,
    this.devicePath,
    required this.isActive,
    this.paperWidth = 80,
    this.encoding = 'CP437',
  });

  factory PrinterConfig.fromMap(Map<String, dynamic> map) {
    return PrinterConfig(
      id: map['id'] ?? '',
      businessId: map['business_id'] ?? '',
      name: map['name'] ?? '',
      type: map['type'] ?? 'network',
      ipAddress: map['ip_address'],
      port: map['port'],
      devicePath: map['device_path'],
      isActive: map['is_active'] ?? true,
      paperWidth: map['paper_width'] ?? 80,
      encoding: map['encoding'] ?? 'CP437',
    );
  }

  bool get isNetwork => type == 'network';
  bool get isUSB => type == 'usb';
  bool get isBluetooth => type == 'bluetooth';

  @override
  List<Object?> get props => [
    id,
    businessId,
    name,
    type,
    ipAddress,
    port,
    devicePath,
    isActive,
    paperWidth,
    encoding,
  ];
}

/// 📍 Área de impresión
class PrintArea extends Equatable {
  final String id;
  final String businessId;
  final String name;
  final String
  code; // 'kitchen_hot', 'kitchen_cold', 'bar', 'cashier', 'fiscal'
  final bool isActive;

  const PrintArea({
    required this.id,
    required this.businessId,
    required this.name,
    required this.code,
    required this.isActive,
  });

  factory PrintArea.fromMap(Map<String, dynamic> map) {
    return PrintArea(
      id: map['id'] ?? '',
      businessId: map['business_id'] ?? '',
      name: map['name'] ?? '',
      code: map['code'] ?? '',
      isActive: map['is_active'] ?? true,
    );
  }

  @override
  List<Object?> get props => [id, businessId, name, code, isActive];
}

/// 🔗 Asignación de impresora a área
class PrintAreaPrinter extends Equatable {
  final String id;
  final String areaId;
  final String printerId;
  final int priority;

  const PrintAreaPrinter({
    required this.id,
    required this.areaId,
    required this.printerId,
    required this.priority,
  });

  factory PrintAreaPrinter.fromMap(Map<String, dynamic> map) {
    return PrintAreaPrinter(
      id: map['id'] ?? '',
      areaId: map['area_id'] ?? '',
      printerId: map['printer_id'] ?? '',
      priority: map['priority'] ?? 1,
    );
  }

  @override
  List<Object?> get props => [id, areaId, printerId, priority];
}

/// 📄 Trabajo de impresión
class PrintJob extends Equatable {
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
    return PrintJob(
      id: map['id'] ?? '',
      businessId: map['business_id'] ?? '',
      areaId: map['area_id'] ?? '',
      orderId: map['order_id'],
      checkId: map['check_id'],
      type: map['type'] ?? '',
      status: map['status'] ?? 'pending',
      data: Map<String, dynamic>.from(map['data'] ?? {}),
      printerId: map['printer_id'],
      retryCount: map['retry_count'] ?? 0,
      errorMessage: map['error_message'],
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

  @override
  List<Object?> get props => [
    id,
    businessId,
    areaId,
    orderId,
    checkId,
    type,
    status,
    data,
    printerId,
    retryCount,
    errorMessage,
    createdAt,
    printedAt,
  ];
}

/// 🎫 Ticket generado para imprimir
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
