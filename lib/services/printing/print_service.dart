import 'dart:async';
import 'dart:io';

import '../../data/models/printing_models.dart';
import '../../data/repositories/printing_repository.dart';
import 'esc_pos_generator.dart';

/// 🖨️ Servicio principal de impresión
/// Gestiona el envío de trabajos a impresoras
class PrintService {
  final PrintingRepository _printingRepo;
  final Map<String, StreamSubscription> _subscriptions = {};

  PrintService(this._printingRepo);

  // ============================================================
  // 🚀 INICIALIZACIÓN
  // ============================================================

  /// Iniciar worker de impresión
  Future<void> startPrintWorker(String businessId) async {
    // Cancelar suscripción anterior si existe
    await stopPrintWorker();

    // Suscribirse a nuevos trabajos
    final subscription = _printingRepo.subscribeToPrintJobs(businessId).listen((
      jobs,
    ) async {
      for (final job in jobs) {
        await _processPrintJob(job);
      }
    });

    _subscriptions[businessId] = subscription;
  }

  /// Detener worker de impresión
  Future<void> stopPrintWorker() async {
    for (final sub in _subscriptions.values) {
      await sub.cancel();
    }
    _subscriptions.clear();
  }

  // ============================================================
  // 📄 PROCESAMIENTO DE TRABAJOS
  // ============================================================

  /// Procesar trabajo de impresión
  Future<void> _processPrintJob(PrintJob job) async {
    try {
      // Marcar como imprimiendo
      await _printingRepo.updateJobStatus(jobId: job.id, status: 'printing');

      // Obtener impresoras del área
      final printers = await _printingRepo.getPrintersForArea(job.areaId);

      if (printers.isEmpty) {
        throw Exception('No hay impresoras asignadas al área');
      }

      // Intentar imprimir en cada impresora (por prioridad)
      bool printed = false;
      String? lastError;

      for (final printer in printers) {
        try {
          await _printToDevice(printer, job);
          printed = true;

          // Marcar como impreso
          await _printingRepo.updateJobStatus(
            jobId: job.id,
            status: 'printed',
            printerId: printer.id,
          );

          break;
        } catch (e) {
          lastError = e.toString();
          continue;
        }
      }

      if (!printed) {
        throw Exception(
          lastError ?? 'No se pudo imprimir en ninguna impresora',
        );
      }
    } catch (e) {
      // Marcar como fallido
      await _printingRepo.updateJobStatus(
        jobId: job.id,
        status: 'failed',
        errorMessage: e.toString(),
      );
    }
  }

  /// Imprimir en dispositivo
  Future<void> _printToDevice(PrinterConfig printer, PrintJob job) async {
    // Generar comandos ESC/POS según el tipo de trabajo
    final commands = _generateCommands(job);

    if (printer.isNetwork) {
      await _printToNetwork(printer.ipAddress!, printer.port ?? 9100, commands);
    } else if (printer.isUSB) {
      await _printToUSB(printer.devicePath!, commands);
    } else {
      throw Exception('Tipo de impresora no soportado: ${printer.type}');
    }
  }

  /// Imprimir en impresora de red
  Future<void> _printToNetwork(
    String ipAddress,
    int port,
    List<int> commands,
  ) async {
    Socket? socket;
    try {
      socket = await Socket.connect(
        ipAddress,
        port,
        timeout: const Duration(seconds: 5),
      );

      socket.add(commands);
      await socket.flush();
      await Future.delayed(const Duration(milliseconds: 500));
    } finally {
      await socket?.close();
    }
  }

  /// Imprimir en impresora USB
  Future<void> _printToUSB(String devicePath, List<int> commands) async {
    // En Windows: devicePath sería algo como "\\.\USB001"
    // En Linux: devicePath sería algo como "/dev/usb/lp0"

    final file = File(devicePath);
    await file.writeAsBytes(commands);
  }

  /// Generar comandos ESC/POS según tipo de trabajo
  List<int> _generateCommands(PrintJob job) {
    // Por ahora retornamos comandos vacíos
    // En producción, aquí se llamaría a PrintTicketService
    // para generar el ticket correspondiente

    // Ejemplo básico:
    // final ticket = PrintTicketService.generateKitchenTicket(...);
    // return ticket.escPosCommands;

    return [];
  }

  // ============================================================
  // 🔧 UTILIDADES
  // ============================================================

  /// Test de impresión
  Future<bool> testPrinter(PrinterConfig printer) async {
    try {
      // Generar ticket de prueba simple
      final testCommands = _generateTestTicket(printer.paperWidth);

      if (printer.isNetwork) {
        await _printToNetwork(
          printer.ipAddress!,
          printer.port ?? 9100,
          testCommands,
        );
      } else if (printer.isUSB) {
        await _printToUSB(printer.devicePath!, testCommands);
      }

      return true;
    } catch (e) {
      return false;
    }
  }

  /// Generar ticket de prueba
  List<int> _generateTestTicket(int paperWidth) {
    final gen = EscPosGenerator(paperWidth: paperWidth);

    gen.initialize();
    gen.lineFeed(2);

    gen.setTextSize(width: 2, height: 2);
    gen.setBold(true);
    gen.textCentered('TEST DE IMPRESIÓN');
    gen.setBold(false);
    gen.setTextSize();

    gen.lineFeed();
    gen.separator();
    gen.lineFeed();

    gen.textCentered('MangoPOS');
    gen.textCentered('Sistema de Punto de Venta');
    gen.lineFeed();
    gen.textCentered('Fecha: ${DateTime.now()}');

    gen.lineFeed();
    gen.separator();
    gen.lineFeed();

    gen.textCentered('Si puedes leer esto,');
    gen.textCentered('la impresora funciona correctamente');

    gen.lineFeed(3);
    gen.cut();

    return gen.getCommands();
  }

  /// Descubrir impresoras en red
  Future<List<String>> discoverNetworkPrinters() async {
    final discovered = <String>[];

    // Escanear rango de IPs común (192.168.1.1 - 192.168.1.254)
    // En producción, esto debería ser más sofisticado

    for (int i = 1; i <= 254; i++) {
      final ip = '192.168.1.$i';

      try {
        final socket = await Socket.connect(
          ip,
          9100,
          timeout: const Duration(milliseconds: 100),
        );

        discovered.add(ip);
        await socket.close();
      } catch (e) {
        // No hay impresora en esta IP
      }
    }

    return discovered;
  }
}
