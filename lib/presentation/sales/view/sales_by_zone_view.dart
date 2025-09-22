import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import '../../../data/repositories/zones_repository.dart';
import '../state/by_zone_state.dart';

final zonesRepoProvider = Provider((ref) => ZonesRepository(Supabase.instance.client));
final byZoneVmProvider = NotifierProvider<ByZoneViewModel, ByZoneState>(ByZoneViewModel.new);

class ByZoneViewModel extends Notifier<ByZoneState> {
  RealtimeChannel? _rt;

  @override
  ByZoneState build() => const ByZoneState();

  Future<void> load(String businessId) async {
    state = state.copyWith(loading: true, error: null);
    final repo = ref.read(zonesRepoProvider);
    try {
      final zones = await repo.fetchZones(businessId);
      state = state.copyWith(zones: zones, loading: false);
      _rt ??= repo.subscribe(() => load(businessId));
    } catch (e) {
      state = state.copyWith(loading: false, error: '$e');
    }
  }

  Future<void> loadZoneStatus(String zoneId) async {
    final repo = ref.read(zonesRepoProvider);
    final rows = await repo.fetchByZone(zoneId);
    state = state.copyWith(statusByZone: {...state.statusByZone, zoneId: rows});
  }

  @override
  void dispose() {
    _rt?.unsubscribe();
    _rt = null;
  }
}
