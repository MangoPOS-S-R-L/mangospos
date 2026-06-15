// Drenador de la cola de impresión (cloud queue) desde la app.
//
// Contexto: cuando TODOS los caminos directos de impresión fallan (TCP/USB/BT),
// el job se encola en `print_jobs` (ver `enqueuePrintJobToCloud`). En despliegues
// CON un agente Node ese agente drena la cola. Pero en despliegues SOLO-TABLETS
// (lo más común: 4 tablets, 3 impresoras de red compartidas, sin PC) NADIE la
// drena → una comanda que falla en pico (puerto 9100 ocupado) queda atascada
// para siempre = "la comanda no salió".
//
// Este worker convierte esa cola en una RED DE SEGURIDAD real: cada ~15s lista
// los jobs pendientes/retry del negocio, hace un CLAIM ATÓMICO (`fn_claim_print_job`)
// y, si lo gana, imprime los bytes ESC/POS (guardados en `data_hex`) por el path
// TCP directo. Con 4 tablets corriendo el worker, el claim atómico garantiza que
// solo UNA imprima cada job → sin doble impresión.
//
// Ciclo de vida: igual que el heartbeat scheduler — `start()` al entrar al shell
// de ventas, `stop()` al disponer el provider. No-op en Web (no hay socket TCP).

import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'package:mangopos/data/repositories/printing_repository.dart';
import 'package:mangopos/data/repositories/printing_v2_repository.dart';
import 'package:mangopos/presentation/settings/more settings/printing/printers/viewmodel/printers_viewmodel.dart';
import 'device_identity.dart';

class CloudPrintQueueWorker {
  CloudPrintQueueWorker(this._ref);

  final Ref _ref;
  Timer? _timer;
  bool _tickInFlight = false;

  // 15s: lo bastante ágil para que una comanda atascada salga rápido, sin
  // martillar Supabase. El path directo (con attempts:4 + jitter + lock por IP)
  // resuelve la mayoría en tiempo real; esto es solo el último recurso.
  static const Duration _interval = Duration(seconds: 15);

  // Cuántos jobs procesamos por tick. Con el claim atómico repartido entre las
  // tablets, cada una toma un puñado y entre todas drenan la cola rápido.
  static const int _batchPerTick = 10;

  void start() {
    if (_timer != null) return;
    if (kIsWeb) return; // Web no puede imprimir por socket TCP directo.
    _timer = Timer.periodic(_interval, (_) => _safeTick());
    // Primer barrido inmediato: no esperar 15s para drenar lo ya pendiente.
    Future.microtask(_safeTick);
  }

  void stop() {
    _timer?.cancel();
    _timer = null;
  }

  Future<void> _safeTick() async {
    if (_tickInFlight) return;
    _tickInFlight = true;
    try {
      await _tick();
    } catch (e, st) {
      debugPrint('[QueueDrainer] tick error: $e\n$st');
    } finally {
      _tickInFlight = false;
    }
  }

  Future<void> _tick() async {
    final supabase = Supabase.instance.client;
    final user = supabase.auth.currentUser;
    if (user == null) return; // sin auth, sin negocio que drenar

    final businessId = await _resolveBusinessId(supabase, user.id);
    if (businessId == null) return;

    final List<dynamic> rows;
    try {
      rows = await supabase
          .from('print_jobs')
          .select('id, data_hex, ip, port')
          .eq('business_id', businessId)
          .inFilter('status', const ['pending', 'retry'])
          .order('created_at', ascending: true)
          .limit(_batchPerTick);
    } catch (e) {
      // Si el esquema/estados difieren, no rompemos nada: simplemente no
      // drenamos este tick.
      debugPrint('[QueueDrainer] no se pudo listar la cola: $e');
      return;
    }
    if (rows.isEmpty) return;

    final deviceId = await DeviceIdentity.getOrCreateId(businessId);
    final v2 = PrintJobV2Repository(supabase);
    final repo = _ref.read(printingPrintersRepositoryProvider);

    for (final raw in rows) {
      final m = raw as Map<String, dynamic>;
      final jobId = (m['id'] as String?)?.trim();
      final ip = (m['ip'] as String?)?.trim();
      final port = (m['port'] as num?)?.toInt() ?? 9100;
      final hex = (m['data_hex'] as String?)?.trim();

      if (jobId == null || jobId.isEmpty) continue;
      // Sin destino de red real (USB/BT van por host; '0.0.0.0' es placeholder).
      if (ip == null || ip.isEmpty || ip == '0.0.0.0') continue;
      if (hex == null || hex.length < 2) continue;
      final bytes = _hexToBytes(hex);
      if (bytes.isEmpty) continue;

      // CLAIM ATÓMICO: con 4 tablets corriendo el worker, solo UNA gana cada
      // job. Si el claim no está disponible (RPC ausente), abortamos el tick:
      // NUNCA imprimimos sin haber ganado el claim, porque eso sí causaría
      // impresión múltiple del mismo ticket.
      bool won;
      try {
        won = await v2.claim(jobId: jobId, deviceId: deviceId);
      } catch (e) {
        debugPrint('[QueueDrainer] claim no disponible, aborto tick: $e');
        return;
      }
      if (!won) continue; // otra tablet lo tomó

      try {
        await repo.printRawDirectTcp(
          ip: ip,
          port: port,
          data: bytes,
          attempts: 3,
        );
        await v2.markPrinted(jobId);
        debugPrint('[QueueDrainer] job $jobId impreso desde la cola → $ip:$port');
      } on PrintLikelyDeliveredException {
        // Los bytes salieron (RST post-flush). Tratamos como impreso para no
        // re-imprimir el mismo ticket.
        await v2.markPrinted(jobId);
      } catch (e) {
        // markFailed decide del lado servidor si reintenta (con backoff) o lo
        // manda a dead-letter tras max_attempts.
        final status = await v2.markFailed(
          jobId: jobId,
          error: e.toString(),
          transport: 'network',
        );
        debugPrint('[QueueDrainer] job $jobId falló ($status): $e');
      }
    }
  }

  Future<String?> _resolveBusinessId(SupabaseClient sb, String userId) async {
    try {
      final row = await sb
          .from('user_businesses')
          .select('business_id')
          .eq('user_id', userId)
          .order('created_at', ascending: true)
          .limit(1)
          .maybeSingle();
      return row?['business_id'] as String?;
    } catch (_) {
      return null;
    }
  }

  /// Decodifica el ESC/POS guardado como hex contiguo (2 chars por byte, ver
  /// `_bytesToHex` en printing_service.dart). Si el hex es inválido devuelve
  /// vacío para NO mandar basura a la impresora.
  List<int> _hexToBytes(String hex) {
    final clean = hex.length.isEven ? hex : hex.substring(0, hex.length - 1);
    final out = <int>[];
    for (var i = 0; i + 1 < clean.length; i += 2) {
      final b = int.tryParse(clean.substring(i, i + 2), radix: 16);
      if (b == null) return const [];
      out.add(b);
    }
    return out;
  }
}

/// Provider singleton del worker. Mirror de `printerHeartbeatSchedulerProvider`:
/// la app llama `.start()` al entrar al shell de ventas; `onDispose` lo detiene.
final cloudPrintQueueWorkerProvider = Provider<CloudPrintQueueWorker>((ref) {
  final worker = CloudPrintQueueWorker(ref);
  ref.onDispose(worker.stop);
  return worker;
});
