/// Estados posibles de una mesa
enum TableStatus { disponible, ocupado, pagando }

/// Extensión para conversiones de TableStatus
extension TableStatusX on TableStatus {
  /// Convierte el enum a string para la BD
  String get toDb {
    switch (this) {
      case TableStatus.disponible:
        return 'available';
      case TableStatus.ocupado:
        return 'occupied';
      case TableStatus.pagando:
        return 'paying';
    }
  }

  /// Texto en español para la UI
  String get label {
    switch (this) {
      case TableStatus.disponible:
        return 'Disponible';
      case TableStatus.ocupado:
        return 'Ocupado';
      case TableStatus.pagando:
        return 'Pagando';
    }
  }

  /// Crea un TableStatus desde un string de BD
  static TableStatus fromDb(String? value) {
    switch (value?.toLowerCase()) {
      case 'occupied':
        return TableStatus.ocupado;
      case 'paying':
      case 'checkout':
      case 'payment':
        return TableStatus.pagando;
      case 'available':
      default:
        return TableStatus.disponible;
    }
  }
}

/// Modelo de mesa para la vista de ventas
/// Documentación: DISENO_CARDS_MESAS.txt
class VentasTable {
  final String id;
  final String code;
  final TableStatus status;
  final String zone;
  final int? guests;
  final String? time;
  final double? total;
  final String? waiterId;
  final String? waiterName;

  const VentasTable({
    required this.id,
    required this.code,
    required this.status,
    required this.zone,
    this.guests,
    this.time,
    this.total,
    this.waiterId,
    this.waiterName,
  });

  /// Verifica si la mesa está ocupada
  bool get isOccupied => status == TableStatus.ocupado;

  /// Verifica si la mesa está disponible
  bool get isAvailable => status == TableStatus.disponible;

  /// Verifica si la mesa está en proceso de pago
  bool get isPaying => status == TableStatus.pagando;

  /// Verifica si esta mesa pertenece al usuario actual
  bool isOwnTable(String currentUserId) => waiterId == currentUserId;

  /// Crea una copia de la mesa con los campos modificados
  VentasTable copyWith({
    String? id,
    String? code,
    TableStatus? status,
    String? zone,
    int? guests,
    String? time,
    double? total,
    String? waiterId,
    String? waiterName,
  }) {
    return VentasTable(
      id: id ?? this.id,
      code: code ?? this.code,
      status: status ?? this.status,
      zone: zone ?? this.zone,
      guests: guests ?? this.guests,
      time: time ?? this.time,
      total: total ?? this.total,
      waiterId: waiterId ?? this.waiterId,
      waiterName: waiterName ?? this.waiterName,
    );
  }

  /// Crea una VentasTable desde un mapa
  factory VentasTable.fromMap(Map<String, dynamic> map) {
    return VentasTable(
      id: map['id'] ?? map['table_id'] ?? '',
      code: map['code'] ?? '',
      status: TableStatusX.fromDb(map['status']),
      zone: map['zone'] ?? map['zone_id'] ?? '',
      guests: map['guests'] ?? map['people_count'],
      time: map['time'],
      total: map['total'] != null ? (map['total'] as num).toDouble() : null,
      waiterId: map['waiter_id'],
      waiterName: map['waiter_name'],
    );
  }

  /// Convierte la mesa a un mapa
  Map<String, dynamic> toMap() {
    return {
      'id': id,
      'code': code,
      'status': status.toDb,
      'zone': zone,
      if (guests != null) 'guests': guests,
      if (time != null) 'time': time,
      if (total != null) 'total': total,
      if (waiterId != null) 'waiter_id': waiterId,
      if (waiterName != null) 'waiter_name': waiterName,
    };
  }

  @override
  String toString() {
    return 'VentasTable(id: $id, code: $code, status: ${status.label}, zone: $zone)';
  }

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) return true;

    return other is VentasTable &&
        other.id == id &&
        other.code == code &&
        other.status == status &&
        other.zone == zone &&
        other.guests == guests &&
        other.time == time &&
        other.total == total &&
        other.waiterId == waiterId &&
        other.waiterName == waiterName;
  }

  @override
  int get hashCode {
    return Object.hash(
      id,
      code,
      status,
      zone,
      guests,
      time,
      total,
      waiterId,
      waiterName,
    );
  }
}
