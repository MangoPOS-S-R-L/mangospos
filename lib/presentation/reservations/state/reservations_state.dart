import '../../../data/models/dining_table.dart';
import '../../../data/models/reservation.dart';
import '../../../data/models/zone.dart';

/// Vista activa del módulo: agenda en lista o plano del salón.
enum ReservationViewMode { list, floorPlan }

class ReservationsState {
  /// Día seleccionado (local, solo fecha). La agenda muestra sus reservas.
  final DateTime selectedDay;

  final List<Reservation> reservations;

  /// Filtro de estado activo (null = todas).
  final ReservationStatus? statusFilter;

  /// Vista activa (lista vs plano del salón).
  final ReservationViewMode viewMode;

  // --- Datos del Plano del salón (carga perezosa al entrar a esa vista) ------
  /// Zonas reales del salón (sin las virtuales de ventas rápidas/manuales).
  final List<Zone> zones;

  /// Mesas por zona (`zoneId` → mesas), cargadas para el plano.
  final Map<String, List<DiningTable>> tablesByZone;

  /// Zona seleccionada en el plano.
  final String? selectedZoneId;

  /// True mientras se cargan zonas+mesas del plano por primera vez.
  final bool floorLoading;
  final bool floorLoaded;

  final bool loading;
  final String? error;
  final String? businessId;

  ReservationsState({
    required this.selectedDay,
    this.reservations = const [],
    this.statusFilter,
    this.viewMode = ReservationViewMode.list,
    this.zones = const [],
    this.tablesByZone = const {},
    this.selectedZoneId,
    this.floorLoading = false,
    this.floorLoaded = false,
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

  /// [visible] agrupada por zona (nombre), preservando el orden por hora dentro
  /// de cada grupo. Las zonas se ordenan alfabéticamente; las reservas sin zona
  /// caen al final bajo "Sin zona". Devuelve pares (zona, reservas).
  List<({String zone, List<Reservation> items})> get groupedByZone {
    final groups = <String, List<Reservation>>{};
    for (final r in visible) {
      final key = (r.zoneName?.trim().isNotEmpty ?? false)
          ? r.zoneName!.trim()
          : 'Sin zona';
      (groups[key] ??= <Reservation>[]).add(r);
    }
    final keys = groups.keys.toList()
      ..sort((a, b) {
        if (a == 'Sin zona') return 1;
        if (b == 'Sin zona') return -1;
        return a.toLowerCase().compareTo(b.toLowerCase());
      });
    return [for (final k in keys) (zone: k, items: groups[k]!)];
  }

  /// Reservas ACTIVAS del día (pending/confirmed/seated) agrupadas por mesa,
  /// ordenadas por hora. Base del coloreado y los toques del plano del salón.
  Map<String, List<Reservation>> get activeByTableId {
    final map = <String, List<Reservation>>{};
    for (final r in reservations) {
      if (!r.status.isActive) continue;
      (map[r.tableId] ??= <Reservation>[]).add(r);
    }
    for (final list in map.values) {
      list.sort((a, b) => a.reservedFor.compareTo(b.reservedFor));
    }
    return map;
  }

  ReservationsState copyWith({
    DateTime? selectedDay,
    List<Reservation>? reservations,
    ReservationStatus? statusFilter,
    bool clearStatusFilter = false,
    ReservationViewMode? viewMode,
    List<Zone>? zones,
    Map<String, List<DiningTable>>? tablesByZone,
    String? selectedZoneId,
    bool? floorLoading,
    bool? floorLoaded,
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
      viewMode: viewMode ?? this.viewMode,
      zones: zones ?? this.zones,
      tablesByZone: tablesByZone ?? this.tablesByZone,
      selectedZoneId: selectedZoneId ?? this.selectedZoneId,
      floorLoading: floorLoading ?? this.floorLoading,
      floorLoaded: floorLoaded ?? this.floorLoaded,
      loading: loading ?? this.loading,
      error: clearError ? null : (error ?? this.error),
      businessId: businessId ?? this.businessId,
    );
  }
}
