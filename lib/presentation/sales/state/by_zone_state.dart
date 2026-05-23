import '../../../data/models/zone.dart';
import '../../../data/models/table_status.dart';

class ByZoneState {
  final List<Zone> zones;
  final Map<String, List<TableStatus>> statusByZone;
  final bool loading;
  final String? error;
  final String? businessId;

  /// 👇 nuevo: mesas en proceso de abrir (para deshabilitar botón y mostrar loader)
  final Set<String> openingTables;

  /// Indica que la ultima carga vino del cache offline (Supabase
  /// inalcanzable). Las mesas mostradas pueden estar stale — sesiones
  /// abiertas en otro terminal mientras estabamos offline no se reflejan.
  final bool isOffline;

  /// Timestamp del snapshot que se esta mostrando (cuando [isOffline]
  /// es true). Sirve para mostrar "ultima sincronizacion hace X".
  final DateTime? lastSyncAt;

  const ByZoneState({
    this.zones = const [],
    this.statusByZone = const {},
    this.loading = false,
    this.error,
    this.businessId,
    this.openingTables = const {},
    this.isOffline = false,
    this.lastSyncAt,
  });

  ByZoneState copyWith({
    List<Zone>? zones,
    Map<String, List<TableStatus>>? statusByZone,
    bool? loading,
    String? error,
    String? businessId,
    Set<String>? openingTables,
    bool? isOffline,
    DateTime? lastSyncAt,
  }) {
    return ByZoneState(
      zones: zones ?? this.zones,
      statusByZone: statusByZone ?? this.statusByZone,
      loading: loading ?? this.loading,
      error: error,
      businessId: businessId ?? this.businessId,
      openingTables: openingTables ?? this.openingTables,
      isOffline: isOffline ?? this.isOffline,
      lastSyncAt: lastSyncAt ?? this.lastSyncAt,
    );
  }
}
