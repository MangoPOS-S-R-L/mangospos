import '../../../../data/models/zone.dart';
import '../../../../data/models/dining_table.dart';

class ZonesTablesState {
  final bool loading;
  final String? error;

  final String? businessId;
  final List<Zone> zones;
  /// Map de mesas por zona (zoneId -> List<DiningTable>)
  final Map<String, List<DiningTable>> tablesByZone;

  const ZonesTablesState({
    this.loading = false,
    this.error,
    this.businessId,
    this.zones = const [],
    this.tablesByZone = const {},
  });

  ZonesTablesState copyWith({
    bool? loading,
    String? error,
    String? businessId,
    List<Zone>? zones,
    Map<String, List<DiningTable>>? tablesByZone,
  }) {
    return ZonesTablesState(
      loading: loading ?? this.loading,
      error: error,
      businessId: businessId ?? this.businessId,
      zones: zones ?? this.zones,
      tablesByZone: tablesByZone ?? this.tablesByZone,
    );
  }
}
