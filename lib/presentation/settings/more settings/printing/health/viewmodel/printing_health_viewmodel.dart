// Sprint 5 — ViewModel del dashboard "Salud de impresión".
//
// Responsabilidades:
//   1. Cargar `getPrintersHealth` + `getActivePrintJobs` desde Supabase
//      al montar la pantalla.
//   2. Suscribirse al canal realtime `subscribePrintJobsHealth`. Cada
//      vez que llega un cambio en print_jobs o printers, refresca la
//      data (con debounce de 500ms para no spamear queries en bursts).
//   3. Exponer acciones `retryJob`, `cancelJob`, `refresh` que las
//      cards/lista llaman desde la UI.
//   4. Limpiar la suscripción al desmontar (autoDispose).

import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../../../../../core/business/business_resolver.dart';
import '../../../../../../data/repositories/printing_repository.dart';
import '../state/printing_health_state.dart';

final printingHealthRepositoryProvider = Provider<PrintingRepository>((ref) {
  return PrintingRepository(Supabase.instance.client);
});

final printingHealthViewModelProvider = NotifierProvider.autoDispose<
    PrintingHealthViewModel,
    PrintingHealthState>(PrintingHealthViewModel.new);

class PrintingHealthViewModel extends AutoDisposeNotifier<PrintingHealthState> {
  String? _businessId;
  RealtimeChannel? _channel;
  Timer? _refreshDebounce;
  bool _disposed = false;

  PrintingRepository get _repo =>
      ref.read(printingHealthRepositoryProvider);

  @override
  PrintingHealthState build() {
    ref.onDispose(() {
      _disposed = true;
      _refreshDebounce?.cancel();
      final ch = _channel;
      if (ch != null) {
        try {
          Supabase.instance.client.removeChannel(ch);
        } catch (e) {
          debugPrint('[PrintingHealth] removeChannel falló: $e');
        }
      }
    });
    return const PrintingHealthState();
  }

  /// Llama esto desde la View al montar. Resuelve businessId, hace el
  /// fetch inicial y abre la suscripción realtime.
  Future<void> initialize({String businessId = 'auto'}) async {
    if (_disposed) return;
    state = state.copyWith(loading: true, clearError: true);
    try {
      _businessId = await BusinessResolver.ensure(businessId);
      await _fetch();
      _openRealtime();
    } catch (e, st) {
      debugPrint('[PrintingHealth] initialize error: $e\n$st');
      state = state.copyWith(loading: false, error: e.toString());
    }
  }

  /// Refresh manual (botón en el AppBar / pull-to-refresh).
  Future<void> refresh() async {
    if (_disposed || _businessId == null) return;
    state = state.copyWith(loading: true, clearError: true);
    await _fetch();
  }

  Future<void> _fetch() async {
    final bid = _businessId;
    if (bid == null) return;
    try {
      final printersFuture = _repo.getPrintersHealth(bid);
      final jobsFuture = _repo.getActivePrintJobs(bid);
      final results = await Future.wait([printersFuture, jobsFuture]);

      final printers = (results[0] as List)
          .map((m) => PrinterHealth.fromMap(m as Map<String, dynamic>))
          .toList(growable: false);
      final jobs = (results[1] as List)
          .map((m) => PrintJobRow.fromMap(m as Map<String, dynamic>))
          .toList(growable: false);

      if (_disposed) return;
      state = state.copyWith(
        printers: printers,
        activeJobs: jobs,
        loading: false,
        lastUpdatedAt: DateTime.now(),
        clearError: true,
      );
    } catch (e, st) {
      debugPrint('[PrintingHealth] _fetch error: $e\n$st');
      if (_disposed) return;
      state = state.copyWith(loading: false, error: e.toString());
    }
  }

  void _openRealtime() {
    final bid = _businessId;
    if (bid == null) return;
    final existing = _channel;
    if (existing != null) {
      try {
        Supabase.instance.client.removeChannel(existing);
      } catch (_) {}
    }
    _channel = _repo.subscribePrintJobsHealth(bid, _scheduleRefresh);
  }

  /// Coalescer: si llegan muchos eventos seguidos (5 INSERT/UPDATE en
  /// 50ms), solo refrescamos una vez al final. 500ms es buen balance:
  /// percepción "instantánea" para el admin sin tirar 10 queries seguidas.
  void _scheduleRefresh() {
    if (_disposed) return;
    _refreshDebounce?.cancel();
    _refreshDebounce = Timer(const Duration(milliseconds: 500), () {
      if (_disposed) return;
      _fetch();
    });
  }

  /// Reset retry_count y status=pending. El worker tomará el job en el
  /// próximo tick (sin esperar backoff acumulado).
  Future<bool> retryJob(String jobId) async {
    try {
      await _repo.retryJob(jobId);
      // No esperamos al realtime: refrescamos optimista.
      _scheduleRefresh();
      return true;
    } catch (e) {
      debugPrint('[PrintingHealth] retryJob error: $e');
      state = state.copyWith(error: e.toString());
      return false;
    }
  }

  Future<bool> cancelJob(String jobId) async {
    try {
      await _repo.cancelJob(jobId);
      _scheduleRefresh();
      return true;
    } catch (e) {
      debugPrint('[PrintingHealth] cancelJob error: $e');
      state = state.copyWith(error: e.toString());
      return false;
    }
  }
}
