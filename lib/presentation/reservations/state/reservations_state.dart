import '../../../data/models/dining_table.dart';
import '../../../data/models/reservation.dart';
import '../../../data/models/zone.dart';

/// Vista activa del módulo: lista, cuadrícula por hora, o plano del salón.
enum ReservationViewMode { list, grid, floorPlan }

class ReservationsState {
  /// Día seleccionado (local, solo fecha). La agenda muestra sus reservas.
  final DateTime selectedDay;

  final List<Reservation> reservations;

  /// Filtro de estado activo (null = todas).
  final ReservationStatus? statusFilter;

  /// Texto de búsqueda (cliente/teléfono). Filtra lista y cuadrícula.
  final String searchQuery;

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
    this.searchQuery = '',
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

  /// Reservas filtradas por [statusFilter] + [searchQuery] y ordenadas por hora.
  List<Reservation> get visible {
    final q = searchQuery.trim().toLowerCase();
    final list = reservations.where((r) {
      if (statusFilter != null && r.status != statusFilter) return false;
      if (q.isNotEmpty) {
        final name = r.customerName.toLowerCase();
        final phone = (r.customerPhone ?? '').toLowerCase();
        if (!name.contains(q) && !phone.contains(q)) return false;
      }
      return true;
    }).toList();
    list.sort((a, b) => a.reservedFor.compareTo(b.reservedFor));
    return list;
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

  /// [visible] agrupada por HORA (franja) para la cuadrícula. Cada grupo trae
  /// la etiqueta "hh:00 AM/PM" y sus reservas (ya ordenadas por hora). Solo
  /// incluye las horas que tienen reservas, ascendente.
  List<({String label, int hour, List<Reservation> items})> get groupedByHour {
    final groups = <int, List<Reservation>>{};
    for (final r in visible) {
      final h = r.reservedForLocal.hour;
      (groups[h] ??= <Reservation>[]).add(r);
    }
    final hours = groups.keys.toList()..sort();
    String fmt(int h) {
      final ampm = h >= 12 ? 'PM' : 'AM';
      final h12 = h % 12 == 0 ? 12 : h % 12;
      return '$h12:00 $ampm';
    }

    return [
      for (final h in hours) (label: fmt(h), hour: h, items: groups[h]!),
    ];
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
    String? searchQuery,
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
      searchQuery: searchQuery ?? this.searchQuery,
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
