import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../../data/models/table_status.dart';
import '../../../data/repositories/zones_repository.dart';
import '../../../data/utils/business_id_resolver.dart';
import '../state/by_zone_state.dart';

final zonesRepoProvider = Provider(
  (ref) => ZonesRepository(Supabase.instance.client),
);

final byZoneVmProvider = NotifierProvider<ByZoneViewModel, ByZoneState>(
  ByZoneViewModel.new,
);

class ByZoneViewModel extends Notifier<ByZoneState> {
  late final SupabaseClient sb;
  RealtimeChannel? _rt;
  String? _rtBusinessId;

  @override
  ByZoneState build() {
    sb = Supabase.instance.client;
    ref.onDispose(() {
      _rt?.unsubscribe();
      _rt = null;
      _rtBusinessId = null;
    });
    return const ByZoneState();
  }

  Future<void> load(String businessId) async {
    state = state.copyWith(loading: true, error: null);

    try {
      final bizId = await resolveBusinessIdOrNull(sb, businessId);
      if (bizId == null) {
        state = state.copyWith(
          loading: false,
          error:
              'No se pudo resolver el negocio del usuario (businessId=auto).',
        );
        return;
      }

      final repo = ref.read(zonesRepoProvider);

      final zones = await repo.fetchZones(bizId);
      zones.sort((a, b) {
        final sortCompare = a.sortIndex.compareTo(b.sortIndex);
        return sortCompare != 0 ? sortCompare : a.name.compareTo(b.name);
      });

      final validZoneIds = zones.map((z) => z.id).toSet();
      final filteredStatus = Map<String, List<TableStatus>>.fromEntries(
        state.statusByZone.entries.where(
          (entry) => validZoneIds.contains(entry.key),
        ),
      );

      state = state.copyWith(
        zones: zones,
        statusByZone: filteredStatus,
        loading: false,
        businessId: bizId,
      );

      _subscribeRealtime(repo, bizId);
    } catch (e) {
      state = state.copyWith(loading: false, error: '$e');
    }
  }

  Future<void> loadZoneStatus(String zoneId) async {
    final repo = ref.read(zonesRepoProvider);
    try {
      final rows = await repo.fetchByZone(zoneId);
      state = state.copyWith(
        statusByZone: {...state.statusByZone, zoneId: rows},
      );
    } catch (e) {
      state = state.copyWith(error: '$e');
    }
  }

  void _subscribeRealtime(ZonesRepository repo, String businessId) {
    if (_rt != null && _rtBusinessId == businessId) return;
    _rt?.unsubscribe();
    _rt = repo.subscribe(() => load(businessId));
    _rtBusinessId = businessId;
  }

  // 👇 Nuevo: marcar/desmarcar una mesa como "abriendo"
  void setOpening(String tableId, bool value) {
    final set = {...state.openingTables};
    if (value) {
      set.add(tableId);
    } else {
      set.remove(tableId);
    }
    state = state.copyWith(openingTables: set);
  }
}
