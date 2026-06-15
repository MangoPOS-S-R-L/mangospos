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
import '../network/android_net_lock.dart';
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
    // WifiLock de alto rendimiento durante toda la sesión POS: evita que el
    // radio WiFi entre en power-save al atenuarse la pantalla y que el primer
    // cobro tras inactividad falle/tarde al abrir el socket a la térmica.
    // El scheduler ya representa "sesión activa" (start al login, stop al
    // logout), así que es el punto natural para gobernar el lock. No-op fuera
    // de Android. Fire-and-forget: el lock es best-effort.
    unawaited(AndroidNetLock.acquireWifiLock());
    // Disparo inmediato para no esperar 30s al arrancar.
    Future.microtask(_safeTick);
  }

  void stop() {
    _timer?.cancel();
    _timer = null;
    unawaited(AndroidNetLock.releaseWifiLock());
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
      // PRD 5 F2.5 fix: el detector retorna http://127.0.0.1:<port> que solo
      // funciona dentro del mismo device. Para que otros devices del business
      // puedan rutear jobs hacia este host, sustituimos por la IP LAN.
      final shareableUrl = await _toShareableUrl(agentUrl!);

      try {
        if (!_deviceAgentRegistered) {
          await supabase.rpc('fn_register_device_agent', params: {
            'p_id': deviceId,
            'p_business_id': businessId,
            'p_device_name': deviceName,
            'p_agent_url': shareableUrl,
            'p_platform': DeviceIdentity.currentPlatform(),
          });
          _deviceAgentRegistered = true;
        } else {
          await supabase.rpc('fn_device_agent_heartbeat', params: {
            'p_id': deviceId,
            'p_agent_url': shareableUrl,
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
      // DESACTIVADO: el TCP probe a port 9100 sobre impresoras de red
      // disparaba prints de basura en algunas térmicas (interpretan el
      // socket abierto+cerrado como un job RAW). Reportamos heartbeat
      // optimista (true) para que la app no las marque offline. Si la
      // impresora está realmente offline, un trabajo real fallará y el
      // error se levanta por ahí.
      //
      // Históricamente este ping también detectaba impresoras de OTROS
      // negocios en la misma LAN, generando impresiones cruzadas.
      // Eliminarlo cierra ese vector también.
      return true;
    }
    // USB / Bluetooth: dependen del agent local.
    return agentReachable();
  }

  // ignore: unused_element
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

  /// Convierte `http://127.0.0.1:PORT` en `http://LAN_IP:PORT` para que el
  /// URL sea alcanzable desde otros devices del business. Si no se puede
  /// resolver la IP LAN, retorna el original (mejor algo que nada).
  Future<String> _toShareableUrl(String url) async {
    if (!url.contains('127.0.0.1') && !url.contains('localhost')) return url;
    try {
      // Preferencia: usar la IP que el OS escoge para rutear a internet.
      // Esto evita el bug de Windows con VirtualBox/Hyper-V/WSL donde
      // `NetworkInterface.list()` devuelve el adapter virtual (192.168.56.x,
      // por ej) ANTES del adapter LAN real y el primero que matcheaba IP
      // privada se quedaba — registrando un URL inalcanzable desde otros
      // devices del business.
      final routedIp = await _localIpWithInternetRoute();
      if (routedIp != null) {
        final shareable = url
            .replaceFirst('127.0.0.1', routedIp)
            .replaceFirst('localhost', routedIp);
        debugPrint(
          '[Heartbeat] agent_url shareable: $url → $shareable (routed)',
        );
        return shareable;
      }

      // Fallback: enumerar interfaces, saltando las virtuales conocidas.
      final ifaces = await NetworkInterface.list(
        includeLoopback: false,
        includeLinkLocal: false,
        type: InternetAddressType.IPv4,
      );
      for (final iface in ifaces) {
        if (_isVirtualInterface(iface.name)) continue;
        for (final addr in iface.addresses) {
          final ip = addr.address;
          if (_isVirtualSubnet(ip)) continue;
          if (ip.startsWith('192.') ||
              ip.startsWith('10.') ||
              ip.startsWith('172.')) {
            final shareable = url
                .replaceFirst('127.0.0.1', ip)
                .replaceFirst('localhost', ip);
            debugPrint(
              '[Heartbeat] agent_url shareable: $url → $shareable (iface ${iface.name})',
            );
            return shareable;
          }
        }
      }
      debugPrint(
        '[Heartbeat] no LAN IPv4 found, registering localhost (impresoras compartidas no funcionarán)',
      );
    } catch (e) {
      debugPrint('[Heartbeat] _toShareableUrl error: $e');
    }
    return url;
  }

  /// Pide al OS la IP local que usaria para alcanzar internet. Trick: abrir
  /// un UDP socket "connect" a 8.8.8.8 — no manda nada pero el OS resuelve
  /// el routing y bindea el socket a la interfaz correcta. Solo lee el
  /// address y cierra. Sin trafico real, sin DNS.
  Future<String?> _localIpWithInternetRoute() async {
    RawDatagramSocket? socket;
    try {
      socket = await RawDatagramSocket.bind(InternetAddress.anyIPv4, 0);
      // El send fuerza al OS a elegir interface. Datagram puede fallar
      // si el firewall bloquea UDP saliente — en ese caso caemos al
      // fallback de enumerar. No esperamos respuesta.
      socket.send(const [0], InternetAddress('8.8.8.8'), 53);
      // Esperar un microtask para que el bind quede establecido.
      await Future<void>.delayed(const Duration(milliseconds: 10));
      final addr = socket.address.address;
      if (addr == '0.0.0.0' || addr.isEmpty) return null;
      if (_isVirtualSubnet(addr)) return null;
      return addr;
    } catch (_) {
      return null;
    } finally {
      socket?.close();
    }
  }

  bool _isVirtualInterface(String name) {
    final n = name.toLowerCase();
    return n.contains('virtualbox') ||
        n.contains('vmware') ||
        n.contains('vethernet') ||
        n.contains('hyper-v') ||
        n.contains('hyperv') ||
        n.contains('wsl') ||
        n.contains('bluetooth') ||
        n.contains('loopback') ||
        n.contains('docker') ||
        n.contains('npcap') ||
        n.contains('tap-windows') ||
        n.contains('tap adapter');
  }

  bool _isVirtualSubnet(String ip) {
    // VirtualBox Host-Only por defecto.
    if (ip.startsWith('192.168.56.')) return true;
    // APIPA / link-local (sin DHCP exitoso).
    if (ip.startsWith('169.254.')) return true;
    // Docker default bridge.
    if (ip.startsWith('172.17.')) return true;
    return false;
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
