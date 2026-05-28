// =============================================================================
// Printer heartbeat provider
//
// StreamProvider que sondea periódicamente todas las impresoras activas del
// business mediante `PrintingRepository.probePrinter` (TCP connect rápido).
// El resultado se publica como Map<printerId, PrinterStatus> y el topbar
// del shell `ref.watch`-ea para mostrar un badge:
//
//   - 🟢 verde:   todas las impresoras responden.
//   - 🟡 amarillo: al menos una está offline.
//   - ⚪ gris:    aún no se sondea o no hay impresoras configuradas.
//
// Cadencia: cada 30s. Probe individual con timeout 1.2s. Web devuelve
// optimista (todo OK) porque el TCP directo no aplica desde browser.
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

/// Estado de una impresora derivado del sondeo TCP.
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

  PrinterStatus copyWith({bool? online, DateTime? checkedAt}) {
    return PrinterStatus(
      printerId: printerId,
      name: name,
      ipAddress: ipAddress,
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

/// Sondeo en paralelo de un conjunto de impresoras. Devuelve el mapa
/// `printerId → PrinterStatus` con resultados frescos. Cualquier error
/// por impresora cae a `online: false` (defensivo).
Future<Map<String, PrinterStatus>> _probeAll(
  PrintingRepository repo,
  List<PrinterConfig> printers,
) async {
  if (printers.isEmpty) return const <String, PrinterStatus>{};
  final futures = printers.map((p) async {
    // Solo sondeamos impresoras de red — USB/Bluetooth no aplican a
    // este chequeo (su disponibilidad la maneja el agent local).
    final ip = p.ipAddress?.trim();
    final bool online;
    if (ip == null || ip.isEmpty) {
      online = true; // optimista: no sabemos, asumimos OK.
    } else {
      online = await repo.probePrinter(ip: ip, port: p.port ?? 9100);
    }
    return PrinterStatus(
      printerId: p.id,
      name: p.name,
      ipAddress: ip,
      online: online,
      checkedAt: DateTime.now(),
    );
  }).toList(growable: false);
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

  Future<void> tick() async {
    try {
      final printers = await repo.getActivePrinters(businessId);
      // Filtramos solo impresoras de red — son las que tiene sentido
      // sondear vía TCP.
      final networkPrinters = printers
          .where((p) =>
              p.printerType == PrinterType.network &&
              (p.ipAddress ?? '').trim().isNotEmpty)
          .toList(growable: false);
      final statuses = await _probeAll(repo, networkPrinters);
      if (!controller.isClosed) {
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
    }
  }

  controller = StreamController<PrinterHeartbeatSnapshot>(
    onListen: () {
      // Primer tick inmediato + recurrente cada 30s.
      unawaited(tick());
      timer = Timer.periodic(const Duration(seconds: 30), (_) => tick());
    },
    onCancel: () {
      timer?.cancel();
      timer = null;
    },
  );
  ref.onDispose(() {
    timer?.cancel();
    controller.close();
  });
  return controller.stream;
});
