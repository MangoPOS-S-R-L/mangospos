import '../../../data/models/reservation.dart';

class ReservationsState {
  /// Día seleccionado (local, solo fecha). La agenda muestra sus reservas.
  final DateTime selectedDay;

  final List<Reservation> reservations;

  /// Filtro de estado activo (null = todas).
  final ReservationStatus? statusFilter;

  final bool loading;
  final String? error;
  final String? businessId;

  ReservationsState({
    required this.selectedDay,
    this.reservations = const [],
    this.statusFilter,
    this.loading = false,
    this.error,
    this.businessId,
  });

  /// Reservas ya filtradas por [statusFilter] y ordenadas por hora.
  List<Reservation> get visible {
    final list = statusFilter == null
        ? reservations
        : reservations.where((r) => r.status == statusFilter).toList();
    final sorted = [...list]
      ..sort((a, b) => a.reservedFor.compareTo(b.reservedFor));
    return sorted;
  }

  ReservationsState copyWith({
    DateTime? selectedDay,
    List<Reservation>? reservations,
    ReservationStatus? statusFilter,
    bool clearStatusFilter = false,
    bool? loading,
    String? error,
    bool clearError = false,
    String? businessId,
  }) {
    return ReservationsState(
      selectedDay: selectedDay ?? this.selectedDay,
      reservations: reservations ?? this.reservations,
      statusFilter:
          clearStatusFilter ? null : (statusFilter ?? this.statusFilter),
      loading: loading ?? this.loading,
      error: clearError ? null : (error ?? this.error),
      businessId: businessId ?? this.businessId,
    );
  }
}
