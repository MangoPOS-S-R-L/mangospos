// lib/data/printing/models.dart
import 'package:meta/meta.dart';

enum PrinterConn { network, bluetooth, usb }
enum PrinterBrand { generic, epson, bematech, star }

@immutable
class PrinterDevice {
  final String id;            // uuid
  final String businessId;    // fk
  final String name;          // "TP300 PROMaria"
  final String ip;            // puede ser ""
  final String mac;           // "00-1A-CD-DE-55-BC"
  final PrinterConn conn;     // network|bluetooth|usb
  final PrinterBrand brand;   // generic|...
  final bool online;          // ping lógico
  final DateTime? lastSeen;
  final int? statusRssi;      // opcional para BT/WiFi
  final String? notes;

  const PrinterDevice({
    required this.id,
    required this.businessId,
    required this.name,
    required this.ip,
    required this.mac,
    required this.conn,
    required this.brand,
    required this.online,
    this.lastSeen,
    this.statusRssi,
    this.notes,
  });

  factory PrinterDevice.fromMap(Map m) => PrinterDevice(
    id: m['id'],
    businessId: m['business_id'],
    name: m['name'] ?? 'Printer',
    ip: m['ip'] ?? '',
    mac: m['mac'] ?? '',
    conn: PrinterConn.values.byName((m['conn'] ?? 'network') as String),
    brand: PrinterBrand.values.byName((m['brand'] ?? 'generic') as String),
    online: (m['online'] ?? false) as bool,
    lastSeen: m['last_seen'] == null ? null : DateTime.parse(m['last_seen']),
    statusRssi: m['status_rssi'],
    notes: m['notes'],
  );

  Map<String, dynamic> toMap() => {
    'id': id,
    'business_id': businessId,
    'name': name,
    'ip': ip,
    'mac': mac,
    'conn': conn.name,
    'brand': brand.name,
    'online': online,
    'last_seen': lastSeen?.toIso8601String(),
    'status_rssi': statusRssi,
    'notes': notes,
  };
}

@immutable
class PrintArea {
  final String id;           // uuid
  final String businessId;
  final String title;        // "Cocina", "Barra", "Horno"
  final int productCount;    // cache de cantidad de productos del área (opcional)
  const PrintArea({
    required this.id,
    required this.businessId,
    required this.title,
    required this.productCount,
  });

  factory PrintArea.fromMap(Map m) => PrintArea(
    id: m['id'],
    businessId: m['business_id'],
    title: m['title'],
    productCount: (m['product_count'] ?? 0) as int,
  );
}

@immutable
class AreaPrinter { // tabla pivote
  final String areaId;
  final String printerId;
  const AreaPrinter({required this.areaId, required this.printerId});
  Map<String, dynamic> toMap() => {'area_id': areaId, 'printer_id': printerId};
}
