import '../../../../../../data/models/zone.dart';
import '../../../../../../data/models/dining_table.dart';

class ZonesTablesState {
  static const Object _errorSentinel = Object();

  final bool loading;
  final String? error;

  final String? businessId;
  final List<Zone> zones;
  final bool promptPeopleCountOnOpen;
  final bool savingOpenTableConfig;

  /// Cuando es `true`, el listado incluye zonas y mesas con `is_active=false`
  /// (las que se desactivaron via soft-delete). Se usa para "papelera" /
  /// reactivación.
  final bool showInactive;

  /// Map de mesas por zona (`zoneId -> List<DiningTable>`)
  final Map<String, List<DiningTable>> tablesByZone;

  const ZonesTablesState({
    this.loading = false,
    this.error,
    this.businessId,
    this.zones = const [],
    this.promptPeopleCountOnOpen = false,
    this.savingOpenTableConfig = false,
    this.showInactive = false,
    this.tablesByZone = const {},
  });

  ZonesTablesState copyWith({
    bool? loading,
    Object? error = _errorSentinel,
    String? businessId,
    List<Zone>? zones,
    bool? promptPeopleCountOnOpen,
    bool? savingOpenTableConfig,
    bool? showInactive,
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
      promptPeopleCountOnOpen:
          promptPeopleCountOnOpen ?? this.promptPeopleCountOnOpen,
      savingOpenTableConfig:
          savingOpenTableConfig ?? this.savingOpenTableConfig,
      showInactive: showInactive ?? this.showInactive,
      tablesByZone: tablesByZone ?? this.tablesByZone,
    );
  }
}
