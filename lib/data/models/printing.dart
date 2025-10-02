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
