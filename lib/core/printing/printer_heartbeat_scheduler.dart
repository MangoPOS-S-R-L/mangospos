// PRD 5 F1.2 — Heartbeat scheduler de impresoras.
//
// Cada 30s, pingea cada impresora activa del business y reporta heartbeat al
// backend (RPC `fn_printer_heartbeat`). Las que no responden no actualizan;
// el cron `fn_mark_stale_printers_offline` (corriendo en backend cada 30s)
// las pasa a offline después de 90s sin heartbeat.
//
// Diseño:
//   - El agent local Node.js NO se modifica en F1. La app Flutter es quien
//     reporta heartbeat usando su propio Supabase auth.
//   - Para impresoras `network`: TCP ping al puerto 9100.
//   - Para impresoras `usb`/`bluetooth`: ping al agent local en :4000/health
//     (si el agent responde online, asumimos que las USB/BT que tiene
//     vinculadas también están alcanzables).
//
// Entry point: instanciar via provider, llamar `start()` cuando el user se
// autentica y la app llega al shell de ventas. `stop()` al logout.

import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:http/http.dart' as http;
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../data/models/printing.dart';
import '../../services/print_agent_detector.dart';
import 'device_identity.dart';
import 'package:mangopos/presentation/settings/more settings/printing/printers/viewmodel/printers_viewmodel.dart';

class PrinterHeartbeatScheduler {
  PrinterHeartbeatScheduler(this._ref);

  final Ref _ref;
  Timer? _timer;
  bool _tickInFlight = false;
  // PRD 5 F2.5: tracking si ya hicimos el register full este ciclo.
  // Reset en cada error para que el próximo tick reintente completo.
  bool _deviceAgentRegistered = false;

  static const Duration _interval = Duration(seconds: 30);
  static const Duration _pingTimeout = Duration(seconds: 2);

  void start() {
    if (_timer != null) return;
    _timer = Timer.periodic(_interval, (_) => _safeTick());
    // Disparo inmediato para no esperar 30s al arrancar.
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
      // No queremos crashear el scheduler si una iteración falla.
      debugPrint('PrinterHeartbeatScheduler tick error: $e\n$st');
    } finally {
      _tickInFlight = false;
    }
  }

  Future<void> _tick() async {
    final supabase = Supabase.instance.client;
    final user = supabase.auth.currentUser;
    if (user == null) return; // sin auth, no hay heartbeat

    final businessId = await _resolveBusinessId(supabase, user.id);
    if (businessId == null) return;

    // PRD 5 F2.5: registrar / actualizar este device como agent host del
    // business. Permite que otros devices del business lo usen como proxy
    // para imprimir a sus impresoras locales (USB/BT).
    final deviceId = await DeviceIdentity.getOrCreateId(businessId);
    final deviceName = await DeviceIdentity.getDisplayName();

    // Ping una sola vez al agent local; reusamos el resultado para todas
    // las impresoras USB/BT que dependen de él.
    bool? agentReachable;
    String? agentUrl;
    Future<bool> isAgentReachable() async {
      if (agentReachable != null) return agentReachable!;
      agentUrl ??= await _resolveAgentUrl();
      if (agentUrl == null) {
        agentReachable = false;
        return false;
      }
      agentReachable = await _pingAgent(agentUrl!);
      return agentReachable!;
    }

    // Solo registramos el device como host si su agent local está activo.
    // Sino otros devices verían un host "online" pero sin manera real de
    // alcanzarlo, lo que rompería el flujo de routing.
    if (await isAgentReachable() && agentUrl != null) {
      try {
        if (!_deviceAgentRegistered) {
          await supabase.rpc('fn_register_device_agent', params: {
            'p_id': deviceId,
            'p_business_id': businessId,
            'p_device_name': deviceName,
            'p_agent_url': agentUrl,
            'p_platform': DeviceIdentity.currentPlatform(),
          });
          _deviceAgentRegistered = true;
        } else {
          await supabase.rpc('fn_device_agent_heartbeat', params: {
            'p_id': deviceId,
            'p_agent_url': agentUrl,
          });
        }
      } catch (e) {
        debugPrint('Device agent heartbeat failed: $e');
        // Reset flag para que el próximo tick reintente register completo.
        _deviceAgentRegistered = false;
      }
    }

    final repo = _ref.read(printingPrintersRepositoryProvider);
    final List<PrinterConfig> printers;
    try {
      printers = await repo.getActivePrinters(businessId);
    } catch (e) {
      debugPrint('Heartbeat: error fetching printers: $e');
      return;
    }
    if (printers.isEmpty) return;

    for (final printer in printers) {
      final reachable = await _ping(
        printer,
        agentReachable: isAgentReachable,
      );
      if (reachable) {
        try {
          await supabase.rpc(
            'fn_printer_heartbeat',
            params: {'p_printer_id': printer.id},
          );
        } catch (e) {
          // Heartbeat fallido — log y continuamos. La limpieza posterior la
          // pasará a offline si sigue sin reportar.
          debugPrint('Heartbeat RPC failed for ${printer.id}: $e');
        }
      }
    }

    // PRD 5 F1+F2.5: invocar la limpieza de stale en cada tick.
    // Reemplaza la dependencia de pg_cron cuando la extensión no está
    // habilitada. Costo: 2 RPCs extra por tick (~100ms). Si pg_cron está
    // activo, las llamadas son idempotentes.
    try {
      await supabase.rpc('fn_mark_stale_printers_offline');
    } catch (e) {
      debugPrint('Stale printer cleanup failed: $e');
    }
    try {
      await supabase.rpc('fn_mark_stale_device_agents_offline');
    } catch (e) {
      debugPrint('Stale device agent cleanup failed: $e');
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

  Future<bool> _ping(
    PrinterConfig printer, {
    required Future<bool> Function() agentReachable,
  }) async {
    final type = printer.type.toLowerCase();
    if (type == 'network' && (printer.ipAddress?.isNotEmpty ?? false)) {
      return _pingTcp(printer.ipAddress!, printer.port ?? 9100);
    }
    // USB / Bluetooth: dependen del agent local.
    return agentReachable();
  }

  Future<bool> _pingTcp(String ip, int port) async {
    try {
      final socket =
          await Socket.connect(ip, port, timeout: _pingTimeout);
      socket.destroy();
      return true;
    } catch (_) {
      return false;
    }
  }

  Future<String?> _resolveAgentUrl() async {
    try {
      final detector = PrintAgentDetector();
      return await detector.scanLocalFirst();
    } catch (_) {
      return null;
    }
  }

  Future<bool> _pingAgent(String url) async {
    try {
      final res = await http
          .get(Uri.parse('$url/health'))
          .timeout(_pingTimeout);
      return res.statusCode == 200;
    } catch (_) {
      return false;
    }
  }
}

/// Provider singleton del scheduler. La app debe llamar `.start()` desde
/// donde inicialice servicios autenticados (típicamente al entrar al shell
/// de ventas o tras login).
final printerHeartbeatSchedulerProvider =
    Provider<PrinterHeartbeatScheduler>((ref) {
  final scheduler = PrinterHeartbeatScheduler(ref);
  ref.onDispose(scheduler.stop);
  return scheduler;
});
