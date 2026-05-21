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
import '../../../../../../data/models/printing_v2.dart';
import '../../../../../../data/repositories/printing_repository.dart';
import '../../../../../../data/repositories/printing_v2_repository.dart';
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
      // Slice C: status granular (no_paper/cover_open/error) desde
      // la tabla printer_health (Fase 1).
      final granularHealthFuture = _fetchGranularHealth(bid);
      final results = await Future.wait([
        printersFuture,
        jobsFuture,
        granularHealthFuture,
      ]);

      final granularByPrinterId =
          results[2] as Map<String, PrinterHealthRecord>;

      final printers = (results[0] as List)
          .map((m) => PrinterHealth.fromMap(m as Map<String, dynamic>))
          .map((h) {
            final record = granularByPrinterId[h.id];
            if (record == null) return h;
            return h.copyWith(granularStatus: record.status);
          })
          .toList(growable: false);
      final jobs = (results[1] as List)
          .map((m) => PrintJobRow.fromMap(m as Map<String, dynamic>))
          .toList(growable: false);

      if (_disposed) return;

      // Slice C.2: detectar transiciones a peor estado para emitir
      // notificaciones. Compara el snapshot anterior con el nuevo —
      // si alguna impresora cambió de ok → warning/down, se agrega a
      // pendingTransitions. La UI las consume y llama a clearTransitions.
      final transitions = _detectTransitions(state.printers, printers);

      state = state.copyWith(
        printers: printers,
        activeJobs: jobs,
        loading: false,
        lastUpdatedAt: DateTime.now(),
        clearError: true,
        pendingTransitions: transitions,
      );
    } catch (e, st) {
      debugPrint('[PrintingHealth] _fetch error: $e\n$st');
      if (_disposed) return;
      state = state.copyWith(loading: false, error: e.toString());
    }
  }

  /// Slice C.2: identifica impresoras que pasaron de ok → warning/down.
  /// Solo emite la primera vez (no re-notifica si sigue en el mismo mal
  /// estado). No emite para transiciones a mejor (warning → ok).
  List<PrinterStateTransition> _detectTransitions(
    List<PrinterHealth> previous,
    List<PrinterHealth> current,
  ) {
    if (previous.isEmpty) {
      // Primer load — no notificar (sería ruido al abrir la pantalla).
      return const [];
    }
    final prevById = {for (final p in previous) p.id: p};
    final result = <PrinterStateTransition>[];
    for (final cur in current) {
      final prev = prevById[cur.id];
      if (prev == null) continue; // impresora nueva, no notificamos.
      if (prev.level == cur.level) continue;
      // Solo notificar transiciones a peor.
      final isWorse = (prev.level == PrinterHealthLevel.ok &&
              cur.level != PrinterHealthLevel.ok) ||
          (prev.level == PrinterHealthLevel.warning &&
              cur.level == PrinterHealthLevel.down);
      if (!isWorse) continue;
      result.add(PrinterStateTransition(
        printerId: cur.id,
        printerName: cur.name,
        previous: prev.level,
        current: cur.level,
        granularLabel: cur.granularStatusLabel,
      ));
    }
    return result;
  }

  /// Slice C.2: limpiar transiciones pendientes después de mostrarlas
  /// para que no se re-emitan en cada rebuild de la UI.
  void clearTransitions() {
    if (_disposed) return;
    if (state.pendingTransitions.isEmpty) return;
    state = state.copyWith(pendingTransitions: const []);
  }

  /// Slice C.3: jobs ya impresos en las últimas 24h para que el cajero
  /// pueda reimprimir si algo no salió bien físicamente. NO se cachea
  /// en state — se pide on-demand al abrir el bottom sheet.
  Future<List<PrintJobRow>> loadRecentlyPrinted({int limit = 30}) async {
    final bid = _businessId;
    if (bid == null) return const [];
    try {
      final rows = await _repo.getRecentPrintedJobs(bid, limit: limit);
      return rows
          .map((m) => PrintJobRow.fromMap(Map<String, dynamic>.from(m)))
          .toList(growable: false);
    } catch (e) {
      debugPrint('[PrintingHealth] loadRecentlyPrinted error: $e');
      return const [];
    }
  }

  /// Slice C.3: reimprime un job ya impreso. Clona payload y encola
  /// nuevo job pending. Retorna true si se logró encolar.
  Future<bool> reprintJob(String jobId) async {
    try {
      await _repo.reprintJob(jobId);
      // Refrescar la cola para que el nuevo job aparezca.
      await _fetch();
      return true;
    } catch (e) {
      debugPrint('[PrintingHealth] reprintJob error: $e');
      return false;
    }
  }

  /// Slice C: lee la tabla `printer_health` (Fase 1) joineada con printers
  /// del business. Retorna map por printer_id para enriquecer la lista
  /// principal con status granular.
  Future<Map<String, PrinterHealthRecord>> _fetchGranularHealth(
      String businessId) async {
    try {
      final repo = PrinterHealthRepository(Supabase.instance.client);
      final list = await repo.getHealthForBusiness(businessId);
      return {for (final r in list) r.printerId: r};
    } catch (e) {
      debugPrint('[PrintingHealth] granular health fetch failed: $e');
      return const {};
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
