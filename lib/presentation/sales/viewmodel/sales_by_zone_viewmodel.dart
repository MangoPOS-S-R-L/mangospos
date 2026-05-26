import 'dart:async';
import 'dart:developer' as developer;

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../../data/models/table_status.dart';
import '../../../data/repositories/zones_repository.dart';
import '../../../data/utils/business_id_resolver.dart';
import '../../../core/utils/sorting_utils.dart';
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

      final result = await repo.fetchZonesWithCache(bizId);
      final zones = result.zones.where((z) {
        final name = z.name.toLowerCase();
        return name != 'ventas manuales' && name != 'ventas rápidas' && name != 'delivery';
      }).toList();

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
        isOffline: result.fromCache,
        lastSyncAt: result.cachedAt ?? DateTime.now(),
      );

      _pruneIndexes(validZoneIds);
      // Realtime no funciona offline; solo lo enganchamos cuando hubo
      // respuesta fresca de Supabase. Cuando el internet vuelva, el
      // siguiente _loadData periodico re-suscribe.
      if (!result.fromCache) {
        _subscribeRealtime(bizId);
      }
    } catch (e) {
      state = state.copyWith(loading: false, error: '$e');
    }
  }

  Future<void> loadZoneStatus(String zoneId, {bool emitError = true}) async {
    final repo = ref.read(zonesRepoProvider);
    try {
      final result = await repo.fetchByZoneWithCache(
        zoneId,
        businessId: state.businessId,
      );
      final rows = result.rows;
      // Natural Sort (Mesa 1, Mesa 2, ..., Mesa 10)
      rows.sort((a, b) => SortingUtils.naturalCompare(a.code, b.code));

      state = state.copyWith(
        statusByZone: {...state.statusByZone, zoneId: rows},
        isOffline: result.fromCache,
        lastSyncAt: result.cachedAt ?? DateTime.now(),
      );
      _indexZone(zoneId, rows);
    } catch (e) {
      developer.log(
        'Error loading zone status',
        name: 'ByZoneViewModel',
        error: e,
      );
      if (emitError) {
        state = state.copyWith(
          statusByZone: {...state.statusByZone, zoneId: const <TableStatus>[]},
          error: '$e',
        );
      } else {
        state = state.copyWith(
          statusByZone: {...state.statusByZone, zoneId: const <TableStatus>[]},
        );
      }
    }
  }

  void _subscribeRealtime(String businessId) {
    if (_rt != null && _rtBusinessId == businessId) return;
    _rt?.unsubscribe();

    // PRD 7 Fase 4.1 — Realtime con debounce e invalidación incremental
    // por zona. `filter: business_id=eq.X` server-side donde la columna
    // existe (table_sessions, payments). orders/order_items/order_checks
    // dependen de RLS + el filter manual ya implementado en cada callback.
    _rt = sb
        .channel('sales_by_zone_$businessId')
        .onPostgresChanges(
          event: PostgresChangeEvent.all,
          schema: 'public',
          table: 'table_sessions',
          filter: PostgresChangeFilter(
            type: PostgresChangeFilterType.eq,
            column: 'business_id',
            value: businessId,
          ),
          callback: (payload) {
            final newRecord = payload.newRecord;
            final oldRecord = payload.oldRecord;
            final changedBusinessId =
                _toStringOrNull(newRecord['business_id']) ??
                _toStringOrNull(oldRecord['business_id']);

            if (changedBusinessId != null && changedBusinessId != businessId) {
              return;
            }

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
        .onPostgresChanges(
          event: PostgresChangeEvent.all,
          schema: 'public',
          table: 'order_checks',
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
        .onPostgresChanges(
          event: PostgresChangeEvent.all,
          schema: 'public',
          table: 'payments',
          filter: PostgresChangeFilter(
            type: PostgresChangeFilterType.eq,
            column: 'business_id',
            value: businessId,
          ),
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
          .select('id, session_id, table_sessions!inner(business_id)')
          .inFilter('id', orderIds.toList(growable: false));

      final zones = <String>{};
      var requiresFullReload = false;

      for (final row in rows) {
        final session = row['table_sessions'] as Map<String, dynamic>?;
        final rowBusinessId = _toStringOrNull(session?['business_id']);
        if (state.businessId != null &&
            rowBusinessId != null &&
            rowBusinessId != state.businessId) {
          continue;
        }

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
