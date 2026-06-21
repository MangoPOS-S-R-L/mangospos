/// Estado de una reserva (espejo del enum `reservation_status` en BD).
enum ReservationStatus {
  pending,
  confirmed,
  seated,
  completed,
  cancelled,
  noShow,
}

extension ReservationStatusX on ReservationStatus {
  String get wireValue {
    switch (this) {
      case ReservationStatus.pending:
        return 'pending';
      case ReservationStatus.confirmed:
        return 'confirmed';
      case ReservationStatus.seated:
        return 'seated';
      case ReservationStatus.completed:
        return 'completed';
      case ReservationStatus.cancelled:
        return 'cancelled';
      case ReservationStatus.noShow:
        return 'no_show';
    }
  }

  String get label {
    switch (this) {
      case ReservationStatus.pending:
        return 'Pendiente';
      case ReservationStatus.confirmed:
        return 'Confirmada';
      case ReservationStatus.seated:
        return 'Sentada';
      case ReservationStatus.completed:
        return 'Completada';
      case ReservationStatus.cancelled:
        return 'Cancelada';
      case ReservationStatus.noShow:
        return 'No llegó';
    }
  }

  /// Estados que ocupan la franja de la mesa (cuentan para el anti
  /// doble-reserva y para el badge del salón).
  bool get isActive =>
      this == ReservationStatus.pending ||
      this == ReservationStatus.confirmed ||
      this == ReservationStatus.seated;

  /// Se puede editar mientras no haya sido sentada ni cerrada.
  bool get isEditable =>
      this == ReservationStatus.pending ||
      this == ReservationStatus.confirmed;
}

ReservationStatus reservationStatusFromWire(String? raw) {
  switch (raw) {
    case 'pending':
      return ReservationStatus.pending;
    case 'seated':
      return ReservationStatus.seated;
    case 'completed':
      return ReservationStatus.completed;
    case 'cancelled':
      return ReservationStatus.cancelled;
    case 'no_show':
      return ReservationStatus.noShow;
    case 'confirmed':
    default:
      return ReservationStatus.confirmed;
  }
}

/// Una reserva de mesa para una fecha/hora futura. Mapea la tabla
/// `public.reservations`. `tableCode` y `zoneName` vienen del embed de
/// `dining_tables`/`zones` cuando el select los pide (opcional).
class Reservation {
  final String id;
  final String businessId;
  final String? branchId;
  final String tableId;
  final String? customerId;
  final String customerName;
  final String? customerPhone;
  final int partySize;

  /// Inicio de la reserva. Guardado en UTC; usa [reservedForLocal] para la UI.
  final DateTime reservedFor;
  final int durationMinutes;
  final ReservationStatus status;
  final String? notes;
  final String? sessionId;
  final DateTime? createdAt;

  // Campos derivados (embed), solo para mostrar.
  final String? tableCode;
  final String? zoneName;

  const Reservation({
    required this.id,
    required this.businessId,
    required this.tableId,
    required this.customerName,
    required this.partySize,
    required this.reservedFor,
    required this.durationMinutes,
    required this.status,
    this.branchId,
    this.customerId,
    this.customerPhone,
    this.notes,
    this.sessionId,
    this.createdAt,
    this.tableCode,
    this.zoneName,
  });

  DateTime get reservedForLocal => reservedFor.toLocal();

  DateTime get endsAtLocal =>
      reservedForLocal.add(Duration(minutes: durationMinutes));

  bool get isSeated => status == ReservationStatus.seated;

  factory Reservation.fromMap(Map<String, dynamic> map) {
    // El embed de Supabase puede venir como objeto anidado bajo
    // 'dining_tables' (y 'zones' adentro), o aplanado si el select usa alias.
    final table = map['dining_tables'] as Map<String, dynamic>?;
    final zone = table?['zones'] as Map<String, dynamic>?;

    return Reservation(
      id: map['id'] as String,
      businessId: map['business_id'] as String,
      branchId: map['branch_id'] as String?,
      tableId: map['table_id'] as String,
      customerId: map['customer_id'] as String?,
      customerName: (map['customer_name'] as String?) ?? '',
      customerPhone: map['customer_phone'] as String?,
      partySize: (map['party_size'] as num?)?.toInt() ?? 1,
      reservedFor: DateTime.parse(map['reserved_for'] as String),
      durationMinutes: (map['duration_minutes'] as num?)?.toInt() ?? 90,
      status: reservationStatusFromWire(map['status'] as String?),
      notes: map['notes'] as String?,
      sessionId: map['session_id'] as String?,
      createdAt: map['created_at'] == null
          ? null
          : DateTime.parse(map['created_at'] as String),
      tableCode: (map['table_code'] as String?) ?? table?['code'] as String?,
      zoneName: (map['zone_name'] as String?) ?? zone?['name'] as String?,
    );
  }
}
