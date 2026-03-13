import 'package:equatable/equatable.dart';

export 'printing.dart' hide PrintArea, PrintAreaPrinter;

/// 📍 Área de impresión
class PrintArea extends Equatable {
  final String id;
  final String businessId;
  final String name;
  final String code; // 'kitchen_hot', 'kitchen_cold', 'bar', 'cashier', 'fiscal'
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
