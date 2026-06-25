import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../../data/models/dining_table.dart';
import '../../../data/models/reservation.dart';
import '../../../data/models/zone.dart';
import '../../../data/repositories/reservations_repository.dart';
import '../../../data/repositories/zones_repository.dart';
import '../../../data/utils/business_id_resolver.dart';
import '../../../domain/repositories/i_reservations_repository.dart';
import '../state/reservations_state.dart';

final reservationsRepoProvider = Provider<ReservationsRepository>(
  (ref) => ReservationsRepository(Supabase.instance.client),
);

final _reservationsZonesRepoProvider = Provider<ZonesRepository>(
  (ref) => ZonesRepository(Supabase.instance.client),
);

/// Zonas virtuales de ventas que NO son parte del salón físico y por tanto no
/// se muestran en el plano de reservas.
const _virtualZoneNames = {'ventas manuales', 'ventas rápidas', 'delivery'};

final reservationsVmProvider =
    NotifierProvider<ReservationsViewModel, ReservationsState>(
  ReservationsViewModel.new,
);

class ReservationsViewModel extends Notifier<ReservationsState> {
  late final SupabaseClient _sb;
  RealtimeChannel? _rt;
  String? _resolvedBusinessId;
  Timer? _debounce;
  static const _realtimeDebounce = Duration(milliseconds: 450);

  @override
  ReservationsState build() {
    _sb = Supabase.instance.client;
    ref.onDispose(() {
      _rt?.unsubscribe();
      _rt = null;
      _debounce?.cancel();
      _debounce = null;
    });
    final now = DateTime.now();
    return ReservationsState(selectedDay: DateTime(now.year, now.month, now.day));
  }

  /// Carga inicial: resuelve el negocio, baja el día actual y abre realtime.
  Future<void> load(String businessId) async {
    state = state.copyWith(loading: true, clearError: true);
    try {
      final bizId = await resolveBusinessIdOrNull(_sb, businessId);
      if (bizId == null) {
        state = state.copyWith(
          loading: false,
          error: 'No se pudo resolver el negocio del usuario.',
        );
        return;
      }
      _resolvedBusinessId = bizId;
      state = state.copyWith(businessId: bizId);
      await _fetchDay();
      _subscribeRealtime(bizId);
    } catch (e) {
      state = state.copyWith(loading: false, error: e.toString());
    }
  }

  Future<void> setDay(DateTime day) async {
    state = state.copyWith(
      selectedDay: DateTime(day.year, day.month, day.day),
    );
    await _fetchDay();
  }

  Future<void> shiftDay(int days) =>
      setDay(state.selectedDay.add(Duration(days: days)));

  void setStatusFilter(ReservationStatus? status) {
    state = status == null
        ? state.copyWith(clearStatusFilter: true)
        : state.copyWith(statusFilter: status);
  }

  Future<void> refresh() => _fetchDay();

  // --- Plano del salón -------------------------------------------------------

  /// Cambia de vista. Al entrar al plano por primera vez, carga zonas+mesas.
  void setViewMode(ReservationViewMode mode) {
    if (state.viewMode == mode) return;
    state = state.copyWith(viewMode: mode);
    if (mode == ReservationViewMode.floorPlan && !state.floorLoaded) {
      _loadFloorData();
    }
  }

  void selectZone(String zoneId) {
    if (state.selectedZoneId == zoneId) return;
    state = state.copyWith(selectedZoneId: zoneId);
  }

  /// Carga (una vez) las zonas reales del salón y sus mesas para el plano.
  Future<void> _loadFloorData() async {
    final bizId = _resolvedBusinessId;
    if (bizId == null) return;
    state = state.copyWith(floorLoading: true, clearError: true);
    try {
      final repo = ref.read(_reservationsZonesRepoProvider);
      final allZones = await repo.fetchZones(bizId);
      final zones = allZones
          .where((z) => !_virtualZoneNames.contains(z.name.trim().toLowerCase()))
          .toList(growable: false);

      final tablesByZone = <String, List<DiningTable>>{};
      for (final Zone z in zones) {
        tablesByZone[z.id] = await repo.fetchTablesByZone(z.id);
      }

      final selected = state.selectedZoneId ??
          (zones.isNotEmpty ? zones.first.id : null);

      state = state.copyWith(
        zones: zones,
        tablesByZone: tablesByZone,
        selectedZoneId: selected,
        floorLoading: false,
        floorLoaded: true,
      );
    } catch (e) {
      state = state.copyWith(floorLoading: false, error: e.toString());
    }
  }

  Future<void> _fetchDay() async {
    final bizId = _resolvedBusinessId;
    if (bizId == null) return;
    state = state.copyWith(loading: true, clearError: true);
    try {
      final repo = ref.read(reservationsRepoProvider);
      final rows = await repo.fetchByDay(bizId, state.selectedDay);
      state = state.copyWith(reservations: rows, loading: false);
    } catch (e) {
      state = state.copyWith(loading: false, error: e.toString());
    }
  }

  void _subscribeRealtime(String businessId) {
    if (_rt != null) return;
    final repo = ref.read(reservationsRepoProvider);
    _rt = repo.subscribe(
      businessId: businessId,
      onChange: () {
        _debounce?.cancel();
        _debounce = Timer(_realtimeDebounce, _fetchDay);
      },
    );
  }

  // --- Mutaciones (devuelven null en éxito, o el mensaje de error) -----------

  Future<String?> create(ReservationInput input) async {
    try {
      await ref.read(reservationsRepoProvider).create(input);
      await _fetchDay();
      return null;
    } on ReservationException catch (e) {
      return e.message;
    } catch (e) {
      return 'No se pudo crear la reserva.';
    }
  }

  Future<String?> update(String id, ReservationInput input) async {
    try {
      await ref.read(reservationsRepoProvider).update(id, input);
      await _fetchDay();
      return null;
    } on ReservationException catch (e) {
      return e.message;
    } catch (e) {
      return 'No se pudo actualizar la reserva.';
    }
  }

  /// Sienta la reserva (abre la mesa). Devuelve el sessionId o lanza el mensaje.
  Future<({String? error, String? sessionId})> seat(String id) async {
    try {
      final sessionId = await ref.read(reservationsRepoProvider).seat(id);
      await _fetchDay();
      return (error: null, sessionId: sessionId);
    } on ReservationException catch (e) {
      return (error: e.message, sessionId: null);
    } catch (e) {
      return (error: 'No se pudo sentar la reserva.', sessionId: null);
    }
  }

  Future<String?> cancel(String id, {String? reason}) async {
    try {
      await ref.read(reservationsRepoProvider).cancel(id, reason: reason);
      await _fetchDay();
      return null;
    } on ReservationException catch (e) {
      return e.message;
    } catch (e) {
      return 'No se pudo cancelar la reserva.';
    }
  }

  Future<String?> markNoShow(String id) async {
    try {
      await ref.read(reservationsRepoProvider).markNoShow(id);
      await _fetchDay();
      return null;
    } on ReservationException catch (e) {
      return e.message;
    } catch (e) {
      return 'No se pudo marcar la reserva.';
    }
  }
}
