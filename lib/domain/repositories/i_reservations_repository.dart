import '../../data/models/reservation.dart';

/// Contrato del repositorio de reservas. La implementación vive en
/// `data/repositories/reservations_repository.dart`. Mantenido fino a
/// propósito: el módulo es online-first (F1), sin cola offline.
abstract class IReservationsRepository {
  /// Reservas de un día local (zona del negocio), opcionalmente filtradas.
  Future<List<Reservation>> fetchByDay(
    String businessId,
    DateTime localDay, {
    ReservationStatus? status,
  });

  /// Reservas activas próximas de una mesa, para validar disponibilidad y el
  /// badge del salón.
  Future<List<Reservation>> fetchUpcomingByTable(
    String businessId,
    String tableId, {
    Duration window,
  });

  Future<Reservation> create(ReservationInput input);

  Future<Reservation> update(String id, ReservationInput input);

  /// Abre la mesa (sesión dine-in) y enlaza la reserva. Devuelve el sessionId.
  Future<String> seat(String id);

  Future<void> cancel(String id, {String? reason});

  /// Marca la reserva como "no llegó" (estado inactivo, libera la franja).
  Future<void> markNoShow(String id);
}

/// Payload de creación/edición. Las horas se pasan como DateTime local y el
/// repositorio las envía en UTC ISO al RPC.
class ReservationInput {
  final String businessId;
  final String tableId;
  final String customerName;
  final int partySize;
  final DateTime reservedForLocal;
  final int durationMinutes;
  final String? customerId;
  final String? customerPhone;
  final String? notes;

  const ReservationInput({
    required this.businessId,
    required this.tableId,
    required this.customerName,
    required this.partySize,
    required this.reservedForLocal,
    this.durationMinutes = 90,
    this.customerId,
    this.customerPhone,
    this.notes,
  });
}
