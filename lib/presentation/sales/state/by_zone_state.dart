import '../../../data/models/zone.dart';
import '../../../data/models/table_status.dart';

class ByZoneState {
  final List<Zone> zones;
  final Map<String, List<TableStatus>> statusByZone;
  final bool loading;
  final String? error;

  const ByZoneState({
    this.zones = const [],
    this.statusByZone = const {},
    this.loading = false,
    this.error,
  });

  ByZoneState copyWith({
    List<Zone>? zones,
    Map<String, List<TableStatus>>? statusByZone,
    bool? loading,
    String? error,
  }) {
    return ByZoneState(
      zones: zones ?? this.zones,
      statusByZone: statusByZone ?? this.statusByZone,
      loading: loading ?? this.loading,
      error: error,
    );
  }
}
