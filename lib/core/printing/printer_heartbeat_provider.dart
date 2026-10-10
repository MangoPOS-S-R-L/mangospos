// =============================================================================
// Printer heartbeat provider
//
// StreamProvider que sondea periódicamente todas las impresoras activas del
// business mediante la recuperación por identidad y un probe sin bytes.
// El resultado se publica como Map<printerId, PrinterStatus> y el topbar
// del shell `ref.watch`-ea para mostrar un badge:
//
//   - 🟢 verde:   todas las impresoras responden.
//   - 🟡 amarillo: al menos una está offline.
//   - ⚪ gris:    aún no se sondea o no hay impresoras configuradas.
//
// Cadencia: cada 30s. Probe individual con timeout 1.2s. Web consulta al
// agente local porque el TCP directo no aplica desde browser.
//
// Diseño: family por businessId para que el cambio de sucursal renueve
// el stream limpio. AutoDispose para que no quede corriendo cuando el
// usuario cierra sesión.
// =============================================================================

import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../data/models/printing.dart';
import '../../data/repositories/printing_repository.dart';
import '../../presentation/settings/more settings/printing/printers/viewmodel/printers_viewmodel.dart';

/// Estado de una impresora después de resolver su dirección por identidad.
@immutable
class PrinterStatus {
  const PrinterStatus({
    required this.printerId,
    required this.name,
    required this.online,
    required this.checkedAt,
    this.ipAddress,
  });

  final String printerId;
  final String name;
  final String? ipAddress;
  final bool online;
  final DateTime checkedAt;

  PrinterStatus copyWith({
    bool? online,
    DateTime? checkedAt,
    String? ipAddress,
  }) {
    return PrinterStatus(
      printerId: printerId,
      name: name,
      ipAddress: ipAddress ?? this.ipAddress,
      online: online ?? this.online,
      checkedAt: checkedAt ?? this.checkedAt,
    );
  }
}

/// Snapshot agregado del estado de todas las impresoras del business.
@immutable
class PrinterHeartbeatSnapshot {
  const PrinterHeartbeatSnapshot({
    required this.statuses,
    required this.lastUpdated,
  });

  /// Indexado por `printer.id` para fácil lookup.
  final Map<String, PrinterStatus> statuses;
  final DateTime lastUpdated;

  bool get hasPrinters => statuses.isNotEmpty;
  Iterable<PrinterStatus> get offline =>
      statuses.values.where((s) => !s.online);
  bool get allOnline => statuses.values.every((s) => s.online);
  bool get anyOffline => !allOnline && hasPrinters;
}

/// Resuelve la identidad antes de aceptar una dirección como online.
Future<PrinterStatus> probeNetworkPrinterStatus(
  PrintingRepository repo,
  PrinterConfig printer,
) async {
  var ip = repo.getKnownNetworkIp(printer) ?? printer.effectiveIp;
  var online = false;
  try {
    final resolved = await repo.resolveReachableNetworkIp(
      printer: printer,
      cachedIp: ip ?? '',
    );
    if (resolved.trim().isNotEmpty) {
      ip = resolved.trim();
      online = await repo.probePrinter(
        ip: ip,
        port: printer.effectivePort ?? 9100,
      );
    }
  } catch (_) {
    // Una IP reutilizada por otro equipo tampoco es una impresora online.
    online = false;
  }
  return PrinterStatus(
    printerId: printer.id,
    name: printer.name,
    ipAddress: ip,
    online: online,
    checkedAt: DateTime.now(),
  );
}

/// Un error individual no oculta el estado de las otras impresoras activas.
Future<Map<String, PrinterStatus>> probeNetworkPrinters(
  PrintingRepository repo,
  List<PrinterConfig> printers,
) async {
  if (printers.isEmpty) return const <String, PrinterStatus>{};
  final futures = printers
      .where((p) => p.isActive && p.isNetwork)
      .map((p) => probeNetworkPrinterStatus(repo, p))
      .toList(growable: false);
  final results = await Future.wait(futures);
  return {for (final s in results) s.printerId: s};
}

/// StreamProvider family que emite snapshots cada 30s. Auto-dispose al
/// salir de pantalla para no mantener timers vivos.
final printerHeartbeatProvider = StreamProvider.autoDispose
    .family<PrinterHeartbeatSnapshot, String>((ref, businessId) {
      if (businessId.isEmpty) {
        return Stream<PrinterHeartbeatSnapshot>.value(
          PrinterHeartbeatSnapshot(
            statuses: const {},
            lastUpdated: DateTime.now(),
          ),
        );
      }
      final repo = ref.read(printingPrintersRepositoryProvider);
      late final StreamController<PrinterHeartbeatSnapshot> controller;
      Timer? timer;
      var tickInFlight = false;
      var tickAgain = false;
      var disposed = false;
      StreamSubscription<PrinterAddressChange>? addressChanges;

      Future<void> tick() async {
        if (disposed || controller.isClosed) return;
        if (tickInFlight) {
          tickAgain = true;
          return;
        }
        tickInFlight = true;
        try {
          final printers = await repo.getActivePrinters(businessId);
          if (disposed || controller.isClosed) return;
          final statuses = await probeNetworkPrinters(repo, printers);
          if (!disposed && !controller.isClosed) {
            controller.add(
              PrinterHeartbeatSnapshot(
                statuses: statuses,
                lastUpdated: DateTime.now(),
              ),
            );
          }
        } catch (_) {
          // Errores del tick no deben romper el stream; el próximo tick
          // intenta de nuevo.
        } finally {
          tickInFlight = false;
          if (tickAgain && !disposed) {
            tickAgain = false;
            unawaited(tick());
          }
        }
      }

      controller = StreamController<PrinterHeartbeatSnapshot>(
        onListen: () {
          // Primer tick inmediato + recurrente cada 30s.
          unawaited(tick());
          timer = Timer.periodic(const Duration(seconds: 30), (_) => tick());
          addressChanges = PrintingRepository.printerAddressChanges.listen((
            change,
          ) {
            if (change.businessId == businessId) unawaited(tick());
          });
        },
        onCancel: () {
          timer?.cancel();
          timer = null;
          unawaited(addressChanges?.cancel());
        },
      );
      ref.onDispose(() {
        disposed = true;
        timer?.cancel();
        unawaited(addressChanges?.cancel());
        controller.close();
      });
      return controller.stream;
    });
