import 'dart:async';

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
  Timer? _realtimeDebounceTimer;
  bool _realtimeFlushInProgress = false;
  bool _reloadAllPending = false;
  final Set<String> _dirtyZoneIds = <String>{};
  final Set<String> _dirtyOrderIds = <String>{};
  final Map<String, String> _tableToZoneIndex = <String, String>{};
  final Map<String, String> _sessionToZoneIndex = <String, String>{};

  static const _realtimeDebounce = Duration(milliseconds: 450);

  @override
  ByZoneState build() {
    sb = Supabase.instance.client;
    ref.onDispose(() {
      _rt?.unsubscribe();
      _rt = null;
      _rtBusinessId = null;
      _realtimeDebounceTimer?.cancel();
      _realtimeDebounceTimer = null;
      _dirtyZoneIds.clear();
      _dirtyOrderIds.clear();
      _tableToZoneIndex.clear();
      _sessionToZoneIndex.clear();
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

      _pruneIndexes(validZoneIds);
      _subscribeRealtime(bizId);
    } catch (e) {
      state = state.copyWith(loading: false, error: '$e');
    }
  }

  Future<void> loadZoneStatus(String zoneId, {bool emitError = true}) async {
    final repo = ref.read(zonesRepoProvider);
    try {
      final rows = await repo.fetchByZone(zoneId);
      state = state.copyWith(
        statusByZone: {...state.statusByZone, zoneId: rows},
      );
      _indexZone(zoneId, rows);
    } catch (e) {
      if (emitError) {
        state = state.copyWith(error: '$e');
      }
    }
  }

  void _subscribeRealtime(String businessId) {
    if (_rt != null && _rtBusinessId == businessId) return;
    _rt?.unsubscribe();

    // Realtime con debounce e invalidación incremental por zona.
    _rt = sb
        .channel('sales_by_zone_$businessId')
        .onPostgresChanges(
          event: PostgresChangeEvent.all,
          schema: 'public',
          table: 'table_sessions',
          callback: (payload) {
            final newRecord = payload.newRecord;
            final oldRecord = payload.oldRecord;

            final tableId =
                _toStringOrNull(newRecord['table_id']) ??
                _toStringOrNull(oldRecord['table_id']);
            final sessionId =
                _toStringOrNull(newRecord['id']) ??
                _toStringOrNull(oldRecord['id']);

            if (tableId == null) {
              _queueRealtimeRefresh(fullReload: true);
              return;
            }

            final zoneId = _tableToZoneIndex[tableId];
            if (zoneId == null) {
              _queueRealtimeRefresh(fullReload: true);
              return;
            }

            if (sessionId != null) {
              _sessionToZoneIndex[sessionId] = zoneId;
            }
            _queueRealtimeRefresh(zoneId: zoneId);
          },
        )
        .onPostgresChanges(
          event: PostgresChangeEvent.all,
          schema: 'public',
          table: 'orders',
          callback: (payload) {
            final newRecord = payload.newRecord;
            final oldRecord = payload.oldRecord;
            final sessionId =
                _toStringOrNull(newRecord['session_id']) ??
                _toStringOrNull(oldRecord['session_id']);

            if (sessionId == null) {
              _queueRealtimeRefresh(fullReload: true);
              return;
            }

            final zoneId = _sessionToZoneIndex[sessionId];
            if (zoneId == null) {
              _queueRealtimeRefresh(fullReload: true);
              return;
            }

            _queueRealtimeRefresh(zoneId: zoneId);
          },
        )
        .onPostgresChanges(
          event: PostgresChangeEvent.all,
          schema: 'public',
          table: 'order_items',
          callback: (payload) {
            final newRecord = payload.newRecord;
            final oldRecord = payload.oldRecord;
            final orderId =
                _toStringOrNull(newRecord['order_id']) ??
                _toStringOrNull(oldRecord['order_id']);

            if (orderId == null) {
              _queueRealtimeRefresh(fullReload: true);
              return;
            }

            _queueRealtimeRefresh(orderId: orderId);
          },
        )
        .subscribe();

    _rtBusinessId = businessId;
  }

  void _queueRealtimeRefresh({
    String? zoneId,
    String? orderId,
    bool fullReload = false,
  }) {
    if (fullReload) {
      _reloadAllPending = true;
    }
    if (zoneId != null && zoneId.isNotEmpty) {
      _dirtyZoneIds.add(zoneId);
    }
    if (orderId != null && orderId.isNotEmpty) {
      _dirtyOrderIds.add(orderId);
    }

    _realtimeDebounceTimer?.cancel();
    _realtimeDebounceTimer = Timer(_realtimeDebounce, () {
      unawaited(_flushRealtimeQueue());
    });
  }

  Future<void> _flushRealtimeQueue() async {
    if (_realtimeFlushInProgress) return;
    _realtimeFlushInProgress = true;

    try {
      final businessId = _rtBusinessId ?? state.businessId;
      if (businessId == null) return;

      while (true) {
        final reloadAll = _reloadAllPending;
        final zonesToReload = Set<String>.from(_dirtyZoneIds);
        final orderIds = Set<String>.from(_dirtyOrderIds);

        _reloadAllPending = false;
        _dirtyZoneIds.clear();
        _dirtyOrderIds.clear();

        if (reloadAll) {
          await load(businessId);
        } else {
          if (orderIds.isNotEmpty) {
            final resolved = await _resolveZonesFromOrderIds(orderIds);
            zonesToReload.addAll(resolved.zones);
            if (resolved.requiresFullReload) {
              await load(businessId);
              // Ya recargamos todo; evita llamadas extra de zonas en esta vuelta.
              zonesToReload.clear();
            }
          }

          if (zonesToReload.isNotEmpty) {
            await Future.wait(
              zonesToReload.map(
                (zoneId) => loadZoneStatus(zoneId, emitError: false),
              ),
            );
          }
        }

        final hasNewPending =
            _reloadAllPending ||
            _dirtyZoneIds.isNotEmpty ||
            _dirtyOrderIds.isNotEmpty;
        if (!hasNewPending) break;
      }
    } finally {
      _realtimeFlushInProgress = false;
      if (_reloadAllPending ||
          _dirtyZoneIds.isNotEmpty ||
          _dirtyOrderIds.isNotEmpty) {
        unawaited(_flushRealtimeQueue());
      }
    }
  }

  Future<({Set<String> zones, bool requiresFullReload})>
  _resolveZonesFromOrderIds(Set<String> orderIds) async {
    if (orderIds.isEmpty) {
      return (zones: <String>{}, requiresFullReload: false);
    }

    try {
      final rows = await sb
          .from('orders')
          .select('id, session_id')
          .inFilter('id', orderIds.toList(growable: false));

      final zones = <String>{};
      var requiresFullReload = false;

      for (final row in rows) {
        final sessionId = _toStringOrNull(row['session_id']);
        if (sessionId == null) {
          requiresFullReload = true;
          continue;
        }
        final zoneId = _sessionToZoneIndex[sessionId];
        if (zoneId == null) {
          requiresFullReload = true;
          continue;
        }
        zones.add(zoneId);
      }

      return (zones: zones, requiresFullReload: requiresFullReload);
    } catch (_) {
      return (zones: <String>{}, requiresFullReload: true);
    }
  }

  void _pruneIndexes(Set<String> validZoneIds) {
    _tableToZoneIndex.removeWhere(
      (_, zoneId) => !validZoneIds.contains(zoneId),
    );
    _sessionToZoneIndex.removeWhere(
      (_, zoneId) => !validZoneIds.contains(zoneId),
    );
  }

  void _indexZone(String zoneId, List<TableStatus> rows) {
    _tableToZoneIndex.removeWhere((_, z) => z == zoneId);
    _sessionToZoneIndex.removeWhere((_, z) => z == zoneId);

    for (final row in rows) {
      _tableToZoneIndex[row.tableId] = zoneId;
      final sessionId = row.sessionId;
      if (sessionId != null && sessionId.isNotEmpty) {
        _sessionToZoneIndex[sessionId] = zoneId;
      }
    }
  }

  String? _toStringOrNull(dynamic value) {
    if (value == null) return null;
    final text = value.toString().trim();
    return text.isEmpty ? null : text;
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
