import 'dart:convert';
import 'dart:io';
import 'package:flutter/foundation.dart';
import '../../core/printing/print_driver.dart';
import '../../core/printing/print_job.dart';

/// Direct Network Driver (TCP Socket) for Desktop
/// Used for direct IP printing without an intermediate agent
class NetworkPrintDriver implements PrintDriver {
  @override
  String get id => 'direct_network';

  @override
  Future<bool> isAvailable() async {
    // Only available on platforms that support Socket (Desktop/Mobile, NOT Web)
    if (kIsWeb) return false;
    return true;
  }

  @override
  Future<List<Map<String, dynamic>>> discoverPrinters() async {
    // Direct scanning is complex/slow in Dart main thread.
    // We rely on simple ping or manual entry here.
    return [];
  }

  @override
  Future<void> print(PrintJob job) async {
    if (kIsWeb) throw UnimplementedError('Cannot use direct socket on Web');

    final parts = job.printerId.split(':');
    final ip = parts[0];
    final port = parts.length > 1 ? int.tryParse(parts[1]) ?? 9100 : 9100;

    Socket? socket;
    try {
      socket = await Socket.connect(
        ip,
        port,
        timeout: const Duration(seconds: 5),
      );

      List<int> bytes;
      if (job.isRaw) {
        bytes = base64Decode(job.content);
      } else {
        // Basic fallback for text if not raw
        bytes = utf8.encode(job.content);
      }

      socket.add(bytes);
      await socket.flush();
    } catch (e) {
      throw Exception('Network Print Failed ($ip:$port): $e');
    } finally {
      await socket?.close();
    }
  }

  @override
  Future<bool> checkPrinterStatus(String printerId) async {
    final parts = printerId.split(':');
    final ip = parts[0];
    final port = parts.length > 1 ? int.tryParse(parts[1]) ?? 9100 : 9100;
    try {
      final socket = await Socket.connect(
        ip,
        port,
        timeout: const Duration(seconds: 2),
      );
      socket.destroy();
      return true;
    } catch (_) {
      return false;
    }
  }
}
