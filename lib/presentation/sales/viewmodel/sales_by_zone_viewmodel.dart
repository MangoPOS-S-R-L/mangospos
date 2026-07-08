import 'dart:async';
import 'dart:developer' as developer;

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../../data/models/table_status.dart';
import '../../../data/models/dining_table.dart';
import '../../../data/repositories/zones_repository.dart';
import '../../../data/utils/business_id_resolver.dart';
import '../../../core/offline/offline_pos_service.dart';
import '../../../core/offline/hub/hub_client.dart';
import '../../../core/offline/hub/hub_config.dart';
import '../../../core/offline/hub/hub_event_stream.dart';
import '../../../core/offline/hub/hub_mode_controller.dart';
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
  final OfflinePosService _offlinePos = OfflinePosService();

  // H4 m2c: feed en vivo del Hub (modo cliente). Reemplaza el Realtime de
  // Supabase dentro de la LAN: cada op del Hub dispara un reload debounced del
  // grid para que la mesa del mesero aparezca al instante (no en 30s).
  HubEventStream? _hubEvents;
  StreamSubscription<Map<String, dynamic>>? _hubEventsSub;
  String? _hubEventsUrl;
  Timer? _hubEventDebounce;

  // Throttle del barrido de mesas fantasma: la vista llama load() cada ~30s,
  // pero no queremos disparar el RPC tan seguido.
  DateTime? _lastSweepAt;
  static const _sweepThrottle = Duration(minutes: 3);

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
      _disconnectHubEvents();
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
      final filteredLayout = Map<String, List<DiningTable>>.fromEntries(
        state.layoutByZone.entries.where(
          (entry) => validZoneIds.contains(entry.key),
        ),
      );

      state = state.copyWith(
        zones: zones,
        statusByZone: filteredStatus,
        layoutByZone: filteredLayout,
        loading: false,
        businessId: bizId,
        isOffline: result.fromCache,
        lastSyncAt: result.cachedAt ?? DateTime.now(),
      );

      _pruneIndexes(validZoneIds);
      // H4 m2c: engancha (o suelta) el feed en vivo del Hub según el modo.
      _ensureHubEventStream();
      // Realtime no funciona offline; solo lo enganchamos cuando hubo
      // respuesta fresca de Supabase. Cuando el internet vuelva, el
      // siguiente _loadData periodico re-suscribe.
      if (!result.fromCache) {
        _subscribeRealtime(bizId);
        // Red de seguridad: barrer mesas fantasma del negocio (vacías y
        // abandonadas) por si la limpieza al salir falló por crash/red.
        // Throttled y fire-and-forget para no pegar el RPC en cada refresh.
        _maybeSweepEmptyTables(bizId);
      }
    } catch (e) {
      state = state.copyWith(loading: false, error: '$e');
    }
  }

  void _maybeSweepEmptyTables(String businessId) {
    final now = DateTime.now();
    if (_lastSweepAt != null &&
        now.difference(_lastSweepAt!) < _sweepThrottle) {
      return;
    }
    _lastSweepAt = now;
    unawaited(
      ref
          .read(zonesRepoProvider)
          .releaseEmptyTables(businessId, graceMinutes: 15)
          .catchError((_) {}),
    );
  }

  Future<void> loadZoneStatus(String zoneId, {bool emitError = true}) async {
    final repo = ref.read(zonesRepoProvider);
    // Geometría para el floor map (perezosa: solo si aún no se cargó). El
    // grid no la necesita; un fallo aquí no debe tumbar la carga de estado.
    unawaited(loadZoneLayout(zoneId));
    try {
      final result = await repo.fetchByZoneWithCache(
        zoneId,
        businessId: state.businessId,
      );
      final rows = result.rows;
      // Natural Sort (Mesa 1, Mesa 2, ..., Mesa 10)
      rows.sort((a, b) => SortingUtils.naturalCompare(a.code, b.code));

      // Overlay de mesas con borrador LOCAL sin sincronizar: el server no las
      // conoce (orden local-order-…), así que el grid las perdería al recargar
      // (ese es el síntoma de "limpiar caché borra las mesas"). Las marcamos
      // ocupadas+pendientes para que no desaparezcan del salón de ESTE
      // dispositivo. La visibilidad entre cajas la aporta el Hub Local (F3).
      final overlaidRows = await _overlayPendingDrafts(rows);
      // H4c: en modo Hub, overlayamos también las mesas que el HUB conoce (las
      // que abrió OTRA caja) para que sean visibles en este equipo. Es lo que
      // hace aparecer la mesa del mesero en la caja principal.
      final hubRows = await _overlayHubSalon(overlaidRows);

      state = state.copyWith(
        statusByZone: {...state.statusByZone, zoneId: hubRows},
        isOffline: result.fromCache,
        lastSyncAt: result.cachedAt ?? DateTime.now(),
        errorByZone: {...state.errorByZone, zoneId: null},
      );
      _indexZone(zoneId, hubRows);
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
          errorByZone: {...state.errorByZone, zoneId: '$e'},
        );
      } else {
        state = state.copyWith(
          statusByZone: {...state.statusByZone, zoneId: const <TableStatus>[]},
          errorByZone: {...state.errorByZone, zoneId: '$e'},
        );
      }
    }
  }

  /// Overlaya las mesas con borrador local sin sincronizar sobre las filas del
  /// server. Solo toca mesas que el server muestra LIBRES (sin sesión) y que
  /// tienen un borrador local en ESTE dispositivo: las convierte en ocupadas +
  /// `isPendingSync` para que la tarjeta las muestre y no se pierdan al
  /// recargar. Best-effort: si algo falla, devuelve las filas del server tal
  /// cual. `ordersCount:1` e `itemsCount>=1` garantizan que cuenten como
  /// ocupadas (no "fantasma") de forma consistente con el conteo del grid.
  Future<List<TableStatus>> _overlayPendingDrafts(
    List<TableStatus> rows,
  ) async {
    final businessId = state.businessId;
    if (businessId == null || businessId.isEmpty) return rows;
    try {
      final drafts = await _offlinePos.listPendingTableDrafts(businessId);
      if (drafts.isEmpty) return rows;
      final byTable = {for (final d in drafts) d.tableId: d};
      return rows.map((r) {
        final d = byTable[r.tableId];
        // Solo overlay si hay borrador Y el server no la muestra ya ocupada.
        if (d == null || r.sessionId != null) return r;
        return TableStatus(
          tableId: r.tableId,
          zoneId: r.zoneId,
          code: r.code,
          sessionId: 'local-draft',
          ordersCount: 1,
          minutesOpen: r.minutesOpen,
          itemsCount: d.itemsCount > 0 ? d.itemsCount : 1,
          total: d.total,
          peopleCount: r.peopleCount,
          status: r.status,
          waiterName: r.waiterName,
          customerName: r.customerName,
          isOwn: true,
          isPendingSync: true,
        );
      }).toList();
    } catch (_) {
      return rows;
    }
  }

  /// H4c: overlay de las mesas que el HUB conoce (modo hub). El equipo Hub lee
  /// su propio op-log (sin HTTP); las cajas cliente leen `GET /hub/salon` del
  /// Hub alcanzable. Marca como ocupadas las mesas del Hub que el server aún
  /// muestra libres (las que abrió OTRA caja y no llegaron a Supabase). No pisa
  /// una fila ya marcada (sesión real o borrador local de este equipo).
  /// Best-effort: ante cualquier fallo devuelve las filas sin tocar.
  Future<List<TableStatus>> _overlayHubSalon(List<TableStatus> rows) async {
    final mode = ref.read(hubModeProvider);
    if (mode != TerminalMode.hubClient && mode != TerminalMode.hubHost) {
      return rows;
    }
    final businessId = state.businessId;
    if (businessId == null || businessId.isEmpty) return rows;
    try {
      List<Map<String, dynamic>> hubTables;
      if (mode == TerminalMode.hubHost) {
        hubTables = await _offlinePos.localHubSalon(businessId);
      } else {
        final url = ref.read(hubModeProvider.notifier).reachableHubUrl;
        if (url == null) return rows;
        hubTables =
            await HubClient().getSalon(url, businessId: businessId) ?? const [];
      }
      if (hubTables.isEmpty) return rows;
      final byTable = <String, Map<String, dynamic>>{
        for (final t in hubTables)
          if (t['table_id'] != null) t['table_id'].toString(): t,
      };
      return rows.map((r) {
        final t = byTable[r.tableId];
        if (t == null || r.sessionId != null) return r;
        final itemsCount = (t['items_count'] as num?)?.toInt() ?? 1;
        final total = (t['total'] as num?)?.toDouble() ?? 0;
        return TableStatus(
          tableId: r.tableId,
          zoneId: r.zoneId,
          code: r.code,
          sessionId: 'hub',
          ordersCount: 1,
          minutesOpen: r.minutesOpen,
          itemsCount: itemsCount > 0 ? itemsCount : 1,
          total: total,
          peopleCount: r.peopleCount,
          status: r.status,
          waiterName: r.waiterName,
          customerName: r.customerName,
          isOwn: false,
        );
      }).toList();
    } catch (_) {
      return rows;
    }
  }

  /// H4 m2c: conecta/reconecta el feed en vivo del Hub cuando este equipo es
  /// una caja cliente en modo hub. Cada op del Hub dispara un reload debounced
  /// del grid (para que la mesa del mesero aparezca al instante). Se desconecta
  /// si el modo cambia o el Hub deja de ser alcanzable. Idempotente: no
  /// reconecta si ya está enganchado a la misma URL.
  void _ensureHubEventStream() {
    final mode = ref.read(hubModeProvider);
    if (mode != TerminalMode.hubClient) {
      _disconnectHubEvents();
      return;
    }
    final url = ref.read(hubModeProvider.notifier).reachableHubUrl;
    final businessId = state.businessId;
    if (url == null || businessId == null || businessId.isEmpty) {
      _disconnectHubEvents();
      return;
    }
    if (_hubEventsUrl == url && _hubEvents != null) return;
    _disconnectHubEvents();
    _hubEventsUrl = url;
    final stream = HubEventStream(baseUrl: url, businessId: businessId);
    _hubEvents = stream;
    _hubEventsSub = stream.ops.listen((_) => _onHubEvent());
    stream.connect();
  }

  void _onHubEvent() {
    _hubEventDebounce?.cancel();
    _hubEventDebounce = Timer(const Duration(milliseconds: 400), () {
      final zoneIds = state.statusByZone.keys.toList(growable: false);
      for (final z in zoneIds) {
        unawaited(loadZoneStatus(z, emitError: false));
      }
    });
  }

  void _disconnectHubEvents() {
    _hubEventDebounce?.cancel();
    _hubEventDebounce = null;
    _hubEventsSub?.cancel();
    _hubEventsSub = null;
    final s = _hubEvents;
    _hubEvents = null;
    _hubEventsUrl = null;
    if (s != null) unawaited(s.dispose());
  }

  /// Carga la geometría (posición/forma/tamaño/capacidad) de las mesas de
  /// una zona para el floor map. Perezosa por defecto: si ya está en
  /// [ByZoneState.layoutByZone] no vuelve a consultar (el layout cambia
  /// rara vez). El floor map pasa `force: true` al montar para reflejar
  /// ediciones hechas en Ajustes. Best-effort: un fallo no afecta al grid
  /// ni al estado en vivo; el mapa simplemente usa su fallback.
  Future<void> loadZoneLayout(String zoneId, {bool force = false}) async {
    if (!force && state.layoutByZone.containsKey(zoneId)) return;
    try {
      final repo = ref.read(zonesRepoProvider);
      final tables = await repo.fetchTablesByZone(zoneId);
      state = state.copyWith(
        layoutByZone: {...state.layoutByZone, zoneId: tables},
      );
    } catch (e) {
      developer.log(
        'Error loading zone layout',
        name: 'ByZoneViewModel',
        error: e,
      );
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
