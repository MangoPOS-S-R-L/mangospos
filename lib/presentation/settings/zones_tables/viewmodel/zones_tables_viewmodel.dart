// lib/presentation/settings/zones_tables/viewmodel/zones_tables_viewmodel.dart
import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../../../data/models/dining_table.dart';
import '../../../../data/repositories/zones_repository.dart';
import '../../../../data/utils/business_id_resolver.dart';
import '../state/zones_tables_state.dart';

final zonesRepoProvider =
    Provider((ref) => ZonesRepository(Supabase.instance.client));

final zonesTablesVmProvider =
    NotifierProvider<ZonesTablesViewModel, ZonesTablesState>(
  ZonesTablesViewModel.new,
);

class ZonesTablesViewModel extends Notifier<ZonesTablesState> {
  late final SupabaseClient sb;
  RealtimeChannel? _rtZones;
  RealtimeChannel? _rtTables;
  Timer? _debounce;

  @override
  ZonesTablesState build() {
    sb = Supabase.instance.client;
    ref.onDispose(() {
      _debounce?.cancel();
      _rtZones?.unsubscribe();
      _rtTables?.unsubscribe();
      _rtZones = null;
      _rtTables = null;
    });
    return const ZonesTablesState();
  }

  // ---------------- CARGA ----------------
  Future<void> load({required String businessId}) async {
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
        final s = (a.sortIndex ?? 0).compareTo(b.sortIndex ?? 0);
        return s != 0 ? s : a.name.compareTo(b.name);
      });

      state = state.copyWith(
        loading: false,
        businessId: bizId,
        zones: zones,
      );

      await Future.wait(zones.map((z) => refreshTables(z.id)));
      _subscribeRealtime(bizId);
    } catch (e) {
      state = state.copyWith(loading: false, error: '$e');
    }
  }

  // ---------------- CRUD ----------------
  Future<void> addZone(String businessId, String name) async {
    state = state.copyWith(loading: true, error: null);
    try {
      final bizId = await resolveBusinessIdOrNull(sb, businessId);
      if (bizId == null) {
        state = state.copyWith(loading: false, error: 'BusinessId inválido');
        return;
      }

      await sb.from('zones').insert({'business_id': bizId, 'name': name});
      await load(businessId: bizId); // asegura refresco si RT tarda
    } catch (e) {
      state = state.copyWith(error: '$e');
    } finally {
      state = state.copyWith(loading: false);
    }
  }

  Future<void> addTable(String zoneId, String code) async {
    state = state.copyWith(loading: true, error: null);
    try {
      await sb
          .from('dining_tables')
          .insert({'zone_id': zoneId, 'code': code, 'label': code});
      await refreshTables(zoneId);
    } catch (e) {
      state = state.copyWith(error: '$e');
    } finally {
      state = state.copyWith(loading: false);
    }
  }

  Future<void> deleteTable(String tableId, {String? zoneId}) async {
    await sb.from('dining_tables').delete().eq('id', tableId);
    if (zoneId != null) {
      await refreshTables(zoneId);
    }
  }

  // ---------------- Helpers ----------------
  Future<void> refreshTables(String zoneId) async {
    final repo = ref.read(zonesRepoProvider);
    final rows = await repo.fetchTablesByZone(zoneId);
    final map = Map<String, List<DiningTable>>.from(state.tablesByZone);
    map[zoneId] = rows;
    state = state.copyWith(tablesByZone: map);
  }

  void _subscribeRealtime(String businessId) {
    _rtZones ??= sb
        .channel('rt:settings_zones:$businessId')
        .onPostgresChanges(
          event: PostgresChangeEvent.all,
          schema: 'public',
          table: 'zones',
          filter: PostgresChangeFilter(
            type: PostgresChangeFilterType.eq,
            column: 'business_id',
            value: businessId,
          ),
          callback: (_) => _debounced(() => load(businessId: businessId)),
        )
      ..subscribe();

    _rtTables ??= sb
        .channel('rt:settings_tables:$businessId')
        .onPostgresChanges(
          event: PostgresChangeEvent.all,
          schema: 'public',
          table: 'dining_tables',
          callback: (payload) {
            final zId = (payload.newRecord['zone_id'] ??
                payload.oldRecord['zone_id']) as String?;
            if (zId != null) _debounced(() => refreshTables(zId));
          },
        )
      ..subscribe();
  }

  void _debounced(void Function() fn) {
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 220), fn);
  }
}
