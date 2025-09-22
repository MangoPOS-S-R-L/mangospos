import '../../../../data/models/zone.dart';
import '../../../../data/models/dining_table.dart';

class ZonesTablesState {
  static const Object _errorSentinel = Object();

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
    Object? error = _errorSentinel,
    String? businessId,
    List<Zone>? zones,
    Map<String, List<DiningTable>>? tablesByZone,
  }) {
    return ZonesTablesState(
      loading: loading ?? this.loading,
      error: identical(error, _errorSentinel)
          ? this.error
          : error is String
          ? error
          : error == null
          ? null
          : this.error,
      businessId: businessId ?? this.businessId,
      zones: zones ?? this.zones,
      tablesByZone: tablesByZone ?? this.tablesByZone,
    );
  }
}
