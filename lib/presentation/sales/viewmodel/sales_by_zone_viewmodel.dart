import 'dart:convert';

import 'package:flutter/services.dart' show rootBundle;
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../data/models/table_status.dart';
import '../../../data/models/zone.dart';
import '../state/by_zone_state.dart';

final byZoneVmProvider =
    NotifierProvider<ByZoneViewModel, ByZoneState>(ByZoneViewModel.new);

const _zonesAssetPath = 'assets/data/sales_by_zone_view.json';
const _statusAssetPath = 'assets/data/sales_by_zone_viewmodel.json';

class ByZoneViewModel extends Notifier<ByZoneState> {
  Map<String, List<TableStatus>>? _cachedStatus;

  @override
  ByZoneState build() => const ByZoneState();

  Future<void> load(String businessId) async {
    state = state.copyWith(loading: true, error: null);
    try {
      final zones = await _loadZonesFromAssets();
      state = state.copyWith(zones: zones, loading: false);
    } catch (e) {
      state = state.copyWith(loading: false, error: '$e');
    }
  }

  Future<void> loadZoneStatus(String zoneId) async {
    try {
      final status = await _loadStatusByZone();
      final rows = status[zoneId] ?? const <TableStatus>[];
      state = state.copyWith(
        statusByZone: {...state.statusByZone, zoneId: rows},
      );
    } catch (e) {
      state = state.copyWith(error: '$e');
    }
  }

  Future<List<Zone>> _loadZonesFromAssets() async {
    final raw = await rootBundle.loadString(_zonesAssetPath);
    final data = jsonDecode(raw) as Map<String, dynamic>;
    final list = (data['zones'] as List<dynamic>? ?? <dynamic>[])
        .map((z) => Zone.fromMap(Map<String, dynamic>.from(z as Map)))
        .toList()
      ..sort((a, b) {
        final sort = a.sortIndex.compareTo(b.sortIndex);
        return sort != 0 ? sort : a.name.compareTo(b.name);
      });
    return list;
  }

  Future<Map<String, List<TableStatus>>> _loadStatusByZone() async {
    if (_cachedStatus != null) return _cachedStatus!;

    final raw = await rootBundle.loadString(_statusAssetPath);
    final data = jsonDecode(raw) as Map<String, dynamic>;
    final status = <String, List<TableStatus>>{};
    final map = data['zone_status'] as Map<String, dynamic>? ?? {};
    map.forEach((key, value) {
      final rows = (value as List<dynamic>)
          .map((row) =>
              TableStatus.fromMap(Map<String, dynamic>.from(row as Map)))
          .toList()
        ..sort((a, b) => a.code.compareTo(b.code));
      status[key] = rows;
    });
    _cachedStatus = status;
    return status;
  }
}
