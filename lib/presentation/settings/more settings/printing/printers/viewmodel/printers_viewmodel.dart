// lib/presentation/settings/more settings/printing/printers/viewmodel/printers_viewmodel.dart
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:network_info_plus/network_info_plus.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

// Bluetooth
import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import 'package:permission_handler/permission_handler.dart';

import 'package:mangopos/core/business/business_resolver.dart';
import 'package:mangopos/data/models/printing_models.dart';
import 'package:mangopos/data/repositories/printing_repository.dart';

@immutable
class PrintingPrintersState {
  const PrintingPrintersState({
    this.items = const [],
    this.isLoading = false,
    this.isDiscovering = false,
    this.errorMessage,
    this.selectedIds = const {},
  });

  final List<PrinterDevice> items;
  final bool isLoading;
  final bool isDiscovering;
  final String? errorMessage;
  final Set<String> selectedIds;

  PrintingPrintersState copyWith({
    List<PrinterDevice>? items,
    bool? isLoading,
    bool? isDiscovering,
    String? errorMessage,
    Set<String>? selectedIds,
  }) {
    return PrintingPrintersState(
      items: items ?? this.items,
      isLoading: isLoading ?? this.isLoading,
      isDiscovering: isDiscovering ?? this.isDiscovering,
      errorMessage: errorMessage,
      selectedIds: selectedIds ?? this.selectedIds,
    );
  }
}

/// Resultado de escaneo que **NO** se guarda automáticamente.
class DiscoveredPrinter {
  final String name;
  final String? ip;
  final String? mac;
  final PrinterType type;
  final String? idHint; // pista opcional para la UI

  const DiscoveredPrinter({
    required this.name,
    required this.type,
    this.ip,
    this.mac,
    this.idHint,
  });
}

final printingPrintersRepositoryProvider = Provider<PrintingRepository>((ref) {
  final client = Supabase.instance.client;
  return PrintingRepository(client);
});

final printingPrintersViewModelProvider =
    NotifierProvider<PrintingPrintersViewModel, PrintingPrintersState>(
      PrintingPrintersViewModel.new,
    );

class PrintingPrintersViewModel extends Notifier<PrintingPrintersState> {
  String? _businessId;
  String? _lastLoadedBusinessId;
  bool _loadingGuard = false;

  RealtimeChannel? _printersCh;
  RealtimeChannel? _jobsCh;
  String? _activeJobId;

  Timer? _pollTimer;
  DateTime? _jobStartAt;

  PrintingRepository get _repo => ref.read(printingPrintersRepositoryProvider);

  @override
  PrintingPrintersState build() {
    ref.onDispose(() async {
      _log('build() -> onDispose called');
      await _cleanupRealtime();
      _stopPolling();
      state = state.copyWith(isLoading: false, isDiscovering: false);
    });
    return const PrintingPrintersState();
  }

  // ----------------- Carga -----------------
  Future<void> load({required String businessId, bool force = false}) async {
    if (_loadingGuard || state.isDiscovering) return;

    if (!force &&
        _lastLoadedBusinessId == businessId &&
        state.items.isNotEmpty) {
      _log('load() -> skip (already loaded for $businessId)');
      return;
    }

    _loadingGuard = true;
    state = state.copyWith(isLoading: true, errorMessage: null);
    try {
      _businessId = await BusinessResolver.ensure(
        (businessId.isEmpty) ? 'auto' : businessId,
      );
      _lastLoadedBusinessId = _businessId;

      final configs = await _repo.getPrinters(_businessId!);
      var items = configs.map(_toPrinterDevice).toList();

      // NEW: Health Check via Agent if on Web
      if (kIsWeb) {
        try {
          final isAgentUp = await _repo.isAgentUp();
          if (isAgentUp) {
            final health = await _repo.checkPrintersHealth(configs);
            // Update items status based on health map 'ip' -> bool
            items = items.map((item) {
              if (item.ip != null && health.containsKey(item.ip)) {
                return item.copyWith(online: health[item.ip]!);
              }
              return item;
            }).toList();
          }
        } catch (e) {
          _log('Health Check Error: $e');
        }
      }

      state = state.copyWith(items: items, isLoading: false);
    } catch (e, st) {
      _log('load() ERROR: $e\n$st');
      state = state.copyWith(isLoading: false, errorMessage: e.toString());
    } finally {
      _loadingGuard = false;
    }
  }

  Future<void> refresh() async {
    final b = await _ensureOrResolveBusiness();
    await load(businessId: b, force: true);
  }

  // ----------------- CRUD -----------------
  Future<bool> createPrinter({
    required String name,
    String? ip,
    String? mac,
    String? devicePath,
    dynamic type = 'network',
  }) async {
    final trimmed = name.trim();
    if (trimmed.isEmpty) {
      state = state.copyWith(
        errorMessage: 'El nombre de la impresora es obligatorio.',
      );
      return false;
    }
    try {
      state = state.copyWith(isLoading: true, errorMessage: null);
      final b = await _ensureOrResolveBusiness();
      final PrinterType t = _toPrinterType(type);

      await _repo.createPrinter(
        businessId: b,
        name: trimmed,
        ipAddress: (ip ?? '').trim().isEmpty ? null : (ip ?? '').trim(),
        mac: (mac ?? '').trim().isEmpty ? null : (mac ?? '').trim(),
        devicePath: (devicePath ?? '').trim().isEmpty
            ? null
            : (devicePath ?? '').trim(),
        type: t.name,
      );

      await load(businessId: b, force: true);
      return true;
    } catch (e, st) {
      _log('createPrinter() ERROR: $e\n$st');
      state = state.copyWith(isLoading: false, errorMessage: e.toString());
      return false;
    }
  }

  Future<bool> deletePrinter(String printerId) async {
    try {
      state = state.copyWith(isLoading: true, errorMessage: null);
      final b = await _ensureOrResolveBusiness();
      await _repo.deletePrinter(printerId);
      final nextSelectedIds = {...state.selectedIds}..remove(printerId);
      state = state.copyWith(selectedIds: nextSelectedIds);
      await load(businessId: b, force: true);
      return true;
    } catch (e, st) {
      _log('deletePrinter() ERROR: $e\n$st');
      state = state.copyWith(isLoading: false, errorMessage: e.toString());
      return false;
    }
  }

  Future<bool> updatePrinter({
    required String printerId,
    required String name,
    String? ipAddress,
    String? mac,
    String? type,
    String? devicePath,
    bool? isActive,
    int? paperWidth,
    String? encoding,
  }) async {
    final trimmedName = name.trim();
    if (trimmedName.isEmpty) {
      state = state.copyWith(
        errorMessage: 'El nombre de la impresora es obligatorio.',
      );
      return false;
    }

    try {
      state = state.copyWith(isLoading: true, errorMessage: null);
      final b = await _ensureOrResolveBusiness();
      await _repo.updatePrinter(
        printerId: printerId,
        name: trimmedName,
        ipAddress: ipAddress?.trim().isEmpty == true ? null : ipAddress?.trim(),
        mac: mac?.trim().isEmpty == true ? null : mac?.trim(),
        type: type?.trim().isEmpty == true ? null : type?.trim(),
        devicePath: devicePath?.trim().isEmpty == true
            ? null
            : devicePath?.trim(),
        isActive: isActive,
        paperWidth: paperWidth,
        encoding: encoding?.trim().isEmpty == true ? null : encoding?.trim(),
      );
      await load(businessId: b, force: true);
      return true;
    } catch (e, st) {
      _log('updatePrinter() ERROR: $e\n$st');
      state = state.copyWith(isLoading: false, errorMessage: e.toString());
      return false;
    }
  }

  Future<Map<String, PrinterUsageSummary>> loadUsageSummaries() async {
    final b = await _ensureOrResolveBusiness();
    return _repo.getPrinterUsageSummaries(b);
  }

  // ✅ No intentes sockets en Web. En Desktop/Mobile sí.
  Future<bool> printSampleDirect(String printerId) async {
    if (kIsWeb) {
      state = state.copyWith(
        errorMessage:
            'La impresión directa por socket no está disponible en Web. Usa el Agente LAN.',
      );
      return false;
    }

    try {
      final printer = state.items.firstWhere((p) => p.id == printerId);

      if (printer.type == PrinterType.network && printer.ip != null) {
        final socket = await Socket.connect(
          printer.ip!,
          9100,
          timeout: const Duration(seconds: 3),
        );

        final commands = <int>[
          27, 64, // ESC @
          27, 97, 1, // center
          ...utf8.encode('PRUEBA DE IMPRESION\n'),
          ...utf8.encode('Impresora: ${printer.name}\n'),
          ...utf8.encode('IP: ${printer.ip}\n'),
          10, 10, 10,
          27, 109, // cut
        ];
        socket.add(commands);
        await socket.flush();
        await socket.close();
        return true;
      }

      // Para BT/otros: encola en backend (si ya lo usas)
      await _repo.enqueueTestPrint(printerId);
      return true;
    } catch (e, st) {
      _log('printSampleDirect() ERROR: $e\n$st');
      state = state.copyWith(errorMessage: e.toString());
      return false;
    }
  }

  // ✅ Ruta “inteligente” que funciona en Web y Nativo.
  //   - En Web: requiere Agente LAN activo.
  //   - En Nativo: intenta Agente y si no, socket directo.
  Future<bool> testPrint(String printerId) async {
    try {
      final p = state.items.firstWhere((x) => x.id == printerId);

      if (kIsWeb) {
        try {
          final up = await _repo.isAgentUp();
          if (!up) {
            state = state.copyWith(
              errorMessage:
                  'Para imprimir desde la Web necesitas el Agente LAN activo en tu PC.',
            );
            return false;
          }
          if (p.ip?.isNotEmpty ?? false) {
            await _repo.testPrintViaAgent(ip: p.ip!, port: 9100);
            return true;
          } else {
            state = state.copyWith(
              errorMessage:
                  'Esta impresora no tiene IP configurada para el Agente LAN.',
            );
            return false;
          }
        } catch (e) {
          state = state.copyWith(
            errorMessage: 'No se pudo imprimir con el Agente LAN: $e',
          );
          return false;
        }
      }

      // Nativo (Desktop/Mobile)
      if (p.type == PrinterType.network && (p.ip?.isNotEmpty ?? false)) {
        try {
          await _repo.testPrintViaAgent(ip: p.ip!, port: 9100);
          return true;
        } catch (_) {
          // Si el agente no está disponible, intenta por socket directo
          return await printSampleDirect(printerId);
        }
      }

      // Para BT/otros, intenta el camino directo
      return await printSampleDirect(printerId);
    } catch (e, st) {
      _log('testPrint() ERROR: $e\n$st');
      state = state.copyWith(errorMessage: e.toString());
      return false;
    }
  }

  // ----------------- Selección -----------------
  void toggleSelect(String id) {
    final next = Set<String>.from(state.selectedIds);
    next.contains(id) ? next.remove(id) : next.add(id);
    state = state.copyWith(selectedIds: next);
  }

  void clearSelection() {
    state = state.copyWith(selectedIds: <String>{});
  }

  Future<void> cancelDiscovery() async {
    await _cleanupRealtime();
    _stopPolling();
    state = state.copyWith(isDiscovering: false, isLoading: false);
  }

  // ============================================================
  // ============= ESCANEOS (NO PERSISTENTES) ===================
  // ============================================================
  Future<List<DiscoveredPrinter>> scanOnLANUnified() async {
    if (kIsWeb) {
      try {
        final up = await _repo.isAgentUp();
        if (up) return await scanViaAgent();
      } catch (_) {}
      _log('scanOnLANUnified() -> web sin agente: lista vacía');
      return <DiscoveredPrinter>[];
    }
    return scanOnLAN();
  }

  Future<List<DiscoveredPrinter>> scanOnLAN({
    List<int> ports = const [9100, 631, 515],
    Duration timeout = const Duration(milliseconds: 350),
    int maxConcurrent = 96,
  }) async {
    state = state.copyWith(isDiscovering: true, errorMessage: null);

    final results = <DiscoveredPrinter>[];
    try {
      final gateways = await _getGatewayLastOctets();
      final localIps = await _getLocalIPv4Candidates();

      if (localIps.isEmpty) {
        throw Exception('No hay IP local válida. Conéctate a la red.');
      }

      final subnets = localIps.map(_subnetBaseFromIp).toSet().toList()..sort();
      final ownLastOctets = localIps
          .map((ip) => int.tryParse(ip.split('.').last))
          .whereType<int>()
          .toSet();

      final hosts = <String>[];
      for (final base in subnets) {
        for (int i = 1; i <= 254; i++) {
          if (ownLastOctets.contains(i)) continue;
          if (gateways.contains(i)) continue;
          hosts.add('$base.$i');
        }
      }

      _log(
        'scanOnLAN() -> subnets=${subnets.join(', ')} hosts=${hosts.length}',
      );

      final found = <String, Set<int>>{};
      for (int offset = 0; offset < hosts.length; offset += maxConcurrent) {
        final batch = hosts.sublist(
          offset,
          (offset + maxConcurrent > hosts.length)
              ? hosts.length
              : offset + maxConcurrent,
        );
        final futures = batch.map((h) => _scanHostPorts(h, ports, timeout));
        final resultsBatch = await Future.wait(futures);

        for (int i = 0; i < batch.length; i++) {
          final host = batch[i];
          final openPorts = resultsBatch[i];
          if (openPorts.isNotEmpty) found[host] = openPorts;
        }
      }

      for (final e in found.entries) {
        final ip = e.key;
        final p = e.value.toList()..sort();
        results.add(
          DiscoveredPrinter(
            name: 'Printer $ip:${p.join(",")}',
            ip: ip,
            mac: null,
            type: PrinterType.network,
            idHint: 'lan-$ip',
          ),
        );
      }
    } catch (e, st) {
      _log('scanOnLAN() ERROR: $e\n$st');
      state = state.copyWith(isDiscovering: false, errorMessage: e.toString());
      return <DiscoveredPrinter>[];
    } finally {
      state = state.copyWith(isDiscovering: false);
    }
    return results;
  }

  /// Escaneo vía Agente local. Acepta respuesta `PrinterDevice` **o** `Map`.
  Future<List<DiscoveredPrinter>> scanViaAgent() async {
    final b = await _ensureOrResolveBusiness();
    state = state.copyWith(isDiscovering: true, errorMessage: null);
    try {
      final raw = await _repo.discoverWithAgent(b);

      final out = <DiscoveredPrinter>[];
      // 👇 IMPORTANTE: iterar como dynamic para que la promoción funcione
      for (final dynamic x in raw) {
        String? ip;
        String? mac;
        String name = 'Printer';
        PrinterType type = PrinterType.network;
        String? idHint;

        if (x is PrinterDevice) {
          ip = x.ip;
          mac = x.mac;
          name = x.name;
          type = x.type;
          idHint = x.id;
        } else if (x is Map<String, dynamic>) {
          final map = x;
          ip =
              (map['ip'] as String?) ??
              (map['address'] as String?) ??
              (map['host'] as String?);
          mac =
              (map['mac'] as String?) ??
              (map['deviceId'] as String?) ??
              (map['address'] as String?);
          name =
              (map['name'] as String?) ??
              (ip != null
                  ? 'Printer $ip'
                  : (mac != null ? 'BT $mac' : 'Printer'));
          final t = map['type'] as String?;
          type = t != null
              ? PrinterTypeX.fromName(t)
              : (mac != null && (ip == null || ip.isEmpty)
                    ? PrinterType.bluetooth
                    : PrinterType.network);
          idHint =
              map['deviceId']?.toString() ??
              map['address']?.toString() ??
              map['id']?.toString();
        } else {
          continue; // tipo inesperado
        }

        out.add(
          DiscoveredPrinter(
            name: name,
            ip: ip,
            mac: mac,
            type: type,
            idHint: idHint,
          ),
        );
      }

      _log('scanViaAgent() -> ${out.length} resultados');
      return out;
    } catch (e, st) {
      _log('scanViaAgent() ERROR: $e\n$st');
      state = state.copyWith(errorMessage: e.toString());
      return <DiscoveredPrinter>[];
    } finally {
      state = state.copyWith(isDiscovering: false);
    }
  }

  /// Escaneo Bluetooth. **No guarda**.
  Future<List<DiscoveredPrinter>> scanBluetooth({
    Duration timeout = const Duration(seconds: 8),
  }) async {
    if (!_isBluetoothPlatformSupported()) {
      state = state.copyWith(
        errorMessage:
            'Bluetooth no soportado en esta plataforma.'
            '${kIsWeb
                ? " (Web no permite escanear BT)"
                : Platform.isLinux
                ? " (Linux sin implementación BLE)"
                : ""}',
      );
      return <DiscoveredPrinter>[];
    }

    final operational = await _isFlutterBlueOperational();
    if (!operational) {
      state = state.copyWith(
        errorMessage: Platform.isWindows
            ? 'Bluetooth no operativo en Windows: revisa el adaptador BLE.'
            : 'Bluetooth no operativo en esta instalación.',
      );
      return <DiscoveredPrinter>[];
    }

    state = state.copyWith(isDiscovering: true, errorMessage: null);
    final out = <DiscoveredPrinter>[];

    try {
      final perms = await _ensureBtPermissions();
      if (!perms) {
        throw Exception('Permisos de Bluetooth denegados o no disponibles.');
      }

      BluetoothAdapterState adapterState;
      try {
        adapterState = await FlutterBluePlus.adapterState.first;
      } catch (_) {
        adapterState = BluetoothAdapterState.on;
      }
      if (adapterState != BluetoothAdapterState.on) {
        throw Exception('Enciende el Bluetooth para escanear dispositivos.');
      }

      try {
        await FlutterBluePlus.stopScan();
      } catch (_) {}

      final found = <BluetoothDevice>{};
      final sub = FlutterBluePlus.scanResults.listen((results) {
        for (final r in results) {
          found.add(r.device);
        }
      });

      try {
        await FlutterBluePlus.startScan(timeout: timeout);
      } on UnsupportedError {
        state = state.copyWith(
          isDiscovering: false,
          errorMessage: Platform.isWindows
              ? 'Bluetooth no soportado por el runtime de Windows (solo BLE).'
              : 'Bluetooth no soportado en esta plataforma.',
        );
        await sub.cancel();
        return <DiscoveredPrinter>[];
      }

      await Future.delayed(timeout + const Duration(milliseconds: 450));
      try {
        await FlutterBluePlus.stopScan();
      } catch (_) {}
      await sub.cancel();

      final candidates = _filterLikelyPrinters(found);
      for (final d in candidates) {
        final name = (d.platformName.isNotEmpty ? d.platformName : d.advName)
            .trim();
        final id = d.remoteId.str;
        out.add(
          DiscoveredPrinter(
            name: name.isEmpty ? 'Bluetooth Printer ($id)' : name,
            ip: null,
            mac: id,
            type: PrinterType.bluetooth,
            idHint: id,
          ),
        );
      }
    } catch (e, st) {
      _log('scanBluetooth() ERROR: $e\n$st');
      state = state.copyWith(isDiscovering: false, errorMessage: e.toString());
      return <DiscoveredPrinter>[];
    } finally {
      state = state.copyWith(isDiscovering: false);
    }

    return out;
  }

  // ============================================================
  // ============= DESCUBRIMIENTOS (LEGACY, GUARDAN) ============
  // ============================================================
  Future<void> discoverOnLANUnified() async {
    if (kIsWeb) {
      try {
        final up = await _repo.isAgentUp();
        if (up) {
          await discoverViaAgent();
          return;
        }
      } catch (_) {}
      await discoverOnLANWeb();
      return;
    }
    await discoverOnLAN();
  }

  Future<void> discoverViaAgent() async {
    if (state.isDiscovering || state.isLoading) return;
    final b = await _ensureOrResolveBusiness();
    state = state.copyWith(isDiscovering: true, errorMessage: null);

    try {
      await _repo.discoverWithAgent(b);
      await load(businessId: b, force: true);
    } catch (e, st) {
      _log('discoverViaAgent() ERROR: $e\n$st');
      state = state.copyWith(errorMessage: e.toString());
    } finally {
      state = state.copyWith(isDiscovering: false);
    }
  }

  Future<void> discoverOnLANWeb() async {
    final client = Supabase.instance.client;
    final b = await _ensureOrResolveBusiness();

    await _cleanupRealtime();
    _stopPolling();

    state = state.copyWith(isDiscovering: true, errorMessage: null);

    try {
      final nowIso = DateTime.now().toIso8601String();
      final job = await client
          .from('discovery_jobs')
          .insert({
            'business_id': b,
            'status': 'pending',
            'requested_by': client.auth.currentUser?.id,
            'platform': 'web',
            'created_at': nowIso,
          })
          .select()
          .maybeSingle();

      if (job == null) throw Exception('No se pudo crear el discovery job.');

      _activeJobId = job['id'] as String;
      _jobStartAt = DateTime.tryParse(job['created_at'] as String? ?? nowIso);

      _printersCh = client
          .channel('realtime:printers:$b')
          .onPostgresChanges(
            event: PostgresChangeEvent.insert,
            schema: 'public',
            table: 'printers',
            filter: PostgresChangeFilter(
              column: 'business_id',
              type: PostgresChangeFilterType.eq,
              value: b,
            ),
            callback: (_) async => _refreshWithoutChangingDiscoveryState(),
          )
          .subscribe();

      _jobsCh = client
          .channel('realtime:discovery_jobs:${_activeJobId!}')
          .onPostgresChanges(
            event: PostgresChangeEvent.update,
            schema: 'public',
            table: 'discovery_jobs',
            filter: PostgresChangeFilter(
              column: 'id',
              type: PostgresChangeFilterType.eq,
              value: _activeJobId!,
            ),
            callback: (payload) async {
              final status = payload.newRecord['status'] as String?;
              final errMsg = payload.newRecord['error'] as String?;
              if (status == 'done') {
                await _refreshWithoutChangingDiscoveryState();
                _finishDiscovery();
              } else if (status == 'failed') {
                state = state.copyWith(
                  isDiscovering: false,
                  errorMessage: errMsg ?? 'El descubrimiento falló.',
                );
                await _cleanupRealtime();
                _stopPolling();
              }
            },
          )
          .subscribe();

      _startPolling(
        businessId: b,
        interval: const Duration(seconds: 2),
        totalTimeout: const Duration(seconds: 25),
      );
    } catch (e, st) {
      _log('discoverOnLANWeb() ERROR: $e\n$st');
      state = state.copyWith(isDiscovering: false, errorMessage: e.toString());
      await _cleanupRealtime();
      _stopPolling();
    }
  }

  Future<void> discoverOnLAN() async {
    if (kIsWeb) {
      state = state.copyWith(
        errorMessage: 'El descubrimiento LAN no está soportado en Web.',
      );
      return;
    }

    final b = await _ensureOrResolveBusiness();
    state = state.copyWith(isDiscovering: true, errorMessage: null);

    try {
      final gateways = await _getGatewayLastOctets();
      final localIps = await _getLocalIPv4Candidates();

      if (localIps.isEmpty) {
        throw Exception('No hay IP local válida. Conéctate a la red.');
      }

      final subnets = localIps.map(_subnetBaseFromIp).toSet().toList()..sort();
      final ownLastOctets = localIps
          .map((ip) => int.tryParse(ip.split('.').last))
          .whereType<int>()
          .toSet();

      const ports = [9100, 631, 515];
      const timeout = Duration(milliseconds: 350);
      const int maxConcurrent = 96;

      final hosts = <String>[];
      for (final base in subnets) {
        for (int i = 1; i <= 254; i++) {
          if (ownLastOctets.contains(i)) continue;
          if (gateways.contains(i)) continue;
          hosts.add('$base.$i');
        }
      }

      _log(
        'discoverOnLAN() -> subnets=${subnets.join(', ')} hosts=${hosts.length}',
      );

      final found = <String, Set<int>>{};
      for (int offset = 0; offset < hosts.length; offset += maxConcurrent) {
        final batch = hosts.sublist(
          offset,
          (offset + maxConcurrent > hosts.length)
              ? hosts.length
              : offset + maxConcurrent,
        );
        final futures = batch.map((h) => _scanHostPorts(h, ports, timeout));
        final results = await Future.wait(futures);
        for (int i = 0; i < batch.length; i++) {
          final host = batch[i];
          final openPorts = results[i];
          if (openPorts.isNotEmpty) found[host] = openPorts;
        }
      }

      for (final entry in found.entries) {
        final ip = entry.key;
        final portsOpen = entry.value.toList()..sort();
        final prettyName = 'Printer $ip:${portsOpen.join(",")}';

        final exists = state.items.any((p) => (p.ip ?? '') == ip);
        if (!exists) {
          await _repo.createPrinter(
            businessId: b,
            name: prettyName,
            ipAddress: ip,
            type: PrinterType.network.name,
          );
        }
      }

      await refresh();
    } catch (e, st) {
      _log('discoverOnLAN() ERROR: $e\n$st');
      state = state.copyWith(isDiscovering: false, errorMessage: e.toString());
      return;
    }

    state = state.copyWith(isDiscovering: false);
  }

  // ----------------- Realtime / Polling -----------------
  void _finishDiscovery() async {
    state = state.copyWith(isDiscovering: false);
    await _cleanupRealtime();
    _stopPolling();
  }

  void _startPolling({
    required String businessId,
    required Duration interval,
    required Duration totalTimeout,
  }) {
    final started = DateTime.now();
    _pollTimer = Timer.periodic(interval, (t) async {
      if (!state.isDiscovering) {
        _stopPolling();
        return;
      }
      if (DateTime.now().difference(started) > totalTimeout) {
        state = state.copyWith(
          isDiscovering: false,
          errorMessage:
              'No se detectaron impresoras a tiempo. ¿Está activo el Agente LAN?',
        );
        _stopPolling();
        _cleanupRealtime();
        return;
      }

      try {
        final since = _jobStartAt ?? started;
        final configs = await _repo.getPrinters(businessId);
        final items = configs.map(_toPrinterDevice).toList();
        final hasNew = items.any((p) => p.createdAt.isAfter(since));
        if (hasNew) state = state.copyWith(items: items);

        if (_activeJobId != null) {
          final job = await Supabase.instance.client
              .from('discovery_jobs')
              .select('status,error')
              .eq('id', _activeJobId!)
              .maybeSingle();

          final status = job?['status'] as String?;
          final err = job?['error'] as String?;
          if (status == 'done') {
            _finishDiscovery();
          } else if (status == 'failed') {
            state = state.copyWith(
              isDiscovering: false,
              errorMessage: err ?? 'Fallo.',
            );
            _stopPolling();
            _cleanupRealtime();
          }
        }
      } catch (e) {
        _log('poll ERROR: $e');
      }
    });
  }

  void _stopPolling() {
    _pollTimer?.cancel();
    _pollTimer = null;
  }

  Future<void> _refreshWithoutChangingDiscoveryState() async {
    try {
      final b = await _ensureOrResolveBusiness();
      final configs = await _repo.getPrinters(b);
      final items = configs.map(_toPrinterDevice).toList();
      state = state.copyWith(items: items);
    } catch (e) {
      _log('_refreshWithoutChangingDiscoveryState() ERROR: $e');
    }
  }

  // ----------------- Helpers -----------------
  Future<String> _ensureOrResolveBusiness() async {
    if (_businessId == null || _businessId!.isEmpty || _businessId == 'auto') {
      _businessId = await BusinessResolver.ensure('auto');
    }
    return _businessId!;
  }

  String _subnetBaseFromIp(String ip) {
    final parts = ip.split('.');
    if (parts.length != 4) {
      throw Exception('Formato de IP inválido: $ip');
    }
    return '${parts[0]}.${parts[1]}.${parts[2]}';
  }

  Future<List<String>> _getLocalIPv4Candidates() async {
    final out = <String>[];

    try {
      final wifiIp = await NetworkInfo().getWifiIP();
      if (wifiIp != null && wifiIp.isNotEmpty && _isPrivateIPv4(wifiIp)) {
        out.add(wifiIp);
      }
    } catch (e) {
      _log('_getLocalIPv4Candidates() wifi ERROR: $e');
    }

    try {
      final interfaces = await NetworkInterface.list(
        includeLoopback: false,
        type: InternetAddressType.IPv4,
      );

      final preferred = <String>[];
      final others = <String>[];

      for (final ni in interfaces) {
        final name = ni.name.toLowerCase();
        final looksVirtual =
            name.contains('virtual') ||
            name.contains('vmware') ||
            name.contains('vbox') ||
            name.contains('hyper-v') ||
            name.contains('tailscale') ||
            name.contains('zerotier') ||
            name.contains('loopback') ||
            name.contains('awdl') ||
            name.contains('bridge');

        for (final addr in ni.addresses) {
          final ip = addr.address;
          if (!_isPrivateIPv4(ip)) continue;
          if (looksVirtual) {
            others.add(ip);
          } else {
            preferred.add(ip);
          }
        }
      }

      out
        ..addAll(preferred)
        ..addAll(others);
    } catch (e) {
      _log('_getLocalIPv4Candidates() interfaces ERROR: $e');
    }

    final seen = <String>{};
    return out.where((ip) => seen.add(ip)).toList(growable: false);
  }

  Future<Set<int>> _getGatewayLastOctets() async {
    final out = <int>{};
    try {
      final gatewayIp = await NetworkInfo().getWifiGatewayIP();
      if (gatewayIp != null && gatewayIp.contains('.')) {
        final last = int.tryParse(gatewayIp.split('.').last);
        if (last != null) out.add(last);
      }
    } catch (e) {
      _log('_getGatewayLastOctets() ERROR: $e');
    }
    return out;
  }

  bool _isPrivateIPv4(String ip) {
    if (ip.isEmpty || !ip.contains('.')) return false;
    if (ip.startsWith('127.') || ip.startsWith('169.254.')) return false;
    return ip.startsWith('10.') ||
        ip.startsWith('192.168.') ||
        ip.startsWith('172.');
  }

  Future<Set<int>> _scanHostPorts(
    String host,
    List<int> ports,
    Duration timeout,
  ) async {
    final open = <int>{};
    for (final p in ports) {
      if (await _isTcpOpen(host, p, timeout)) {
        open.add(p);
      }
    }
    return open;
  }

  Future<bool> _isTcpOpen(String host, int port, Duration timeout) async {
    try {
      final s = await Socket.connect(host, port, timeout: timeout);
      await s.close();
      return true;
    } catch (_) {
      return false;
    }
  }

  PrinterType _toPrinterType(dynamic v) {
    if (v is PrinterType) return v;
    if (v is String) return PrinterTypeX.fromName(v);
    return PrinterType.network;
  }

  bool _isBluetoothPlatformSupported() {
    if (kIsWeb) return false;
    if (Platform.isAndroid) return true;
    if (Platform.isIOS) return true;
    if (Platform.isMacOS) return true;
    if (Platform.isWindows) return true;
    if (Platform.isLinux) return false;
    return false;
  }

  Future<bool> _isFlutterBlueOperational() async {
    if (!_isBluetoothPlatformSupported()) return false;
    try {
      await FlutterBluePlus.adapterState.first.timeout(
        const Duration(milliseconds: 500),
      );
      return true;
    } on UnsupportedError catch (e) {
      _log('_isFlutterBlueOperational() -> UnsupportedError: $e');
      return false;
    } catch (e) {
      _log('_isFlutterBlueOperational() -> unexpected: $e');
      return false;
    }
  }

  Future<bool> _ensureBtPermissions() async {
    try {
      if (Platform.isAndroid) {
        final scan = await Permission.bluetoothScan.request();
        final connect = await Permission.bluetoothConnect.request();
        final loc = await Permission.location.request();
        return scan.isGranted && connect.isGranted && loc.isGranted;
      }
      if (Platform.isIOS) return true;
      if (Platform.isWindows || Platform.isMacOS) return true;
      return false;
    } catch (e, st) {
      _log('_ensureBtPermissions() ERROR: $e\n$st');
      return false;
    }
  }

  Set<BluetoothDevice> _filterLikelyPrinters(Set<BluetoothDevice> devices) {
    final patterns = <RegExp>[
      RegExp(r'printer', caseSensitive: false),
      RegExp(r'\bpos\b', caseSensitive: false),
      RegExp(r'\bescpos\b', caseSensitive: false),
      RegExp(
        r'\b(epson|star|bixolon|gprinter|xprinter)\b',
        caseSensitive: false,
      ),
    ];

    bool looksLikePrinter(String s) =>
        s.isNotEmpty && patterns.any((rx) => rx.hasMatch(s));

    final out = <BluetoothDevice>{};
    for (final d in devices) {
      final name = (d.platformName.isNotEmpty ? d.platformName : d.advName)
          .trim();
      final match = looksLikePrinter(name);
      _log(
        'BT found -> id=${d.remoteId.str}, name="$name", printerLikely=$match',
      );
      if (match) out.add(d);
    }
    return out;
  }

  // ---------- Realtime cleanup ----------
  Future<void> _cleanupRealtime() async {
    final client = Supabase.instance.client;
    try {
      if (_printersCh != null) {
        await client.removeChannel(_printersCh!);
        _printersCh = null;
      }
      if (_jobsCh != null) {
        await client.removeChannel(_jobsCh!);
        _jobsCh = null;
      }
      _activeJobId = null;
    } catch (e) {
      _log('_cleanupRealtime() ERROR: $e');
    }
  }

  void _log(String msg) {
    if (kDebugMode) debugPrint('[PrintersVM] $msg');
  }

  /// Helper method to convert PrinterConfig to PrinterDevice
  PrinterDevice _toPrinterDevice(PrinterConfig config) {
    return PrinterDevice.fromConfig(config);
  }
}
