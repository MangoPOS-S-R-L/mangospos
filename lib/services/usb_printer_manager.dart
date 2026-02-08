import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:process_run/process_run.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Manejo de impresoras USB a través del Print Agent local.
class UsbPrinterManager {
  final String agentUrl;
  UsbPrinterManager(this.agentUrl);

  Future<List<dynamic>> fetchPrinters() async {
    final res = await http.get(Uri.parse('$agentUrl/printers'));
    if (res.statusCode != 200) return [];
    return jsonDecode(res.body) as List;
  }

  /// Lanza `npm run usb-scan` en el host local (requiere que el agente esté en 127.0.0.1).
  Future<void> triggerUsbScan() async {
    if (!agentUrl.contains('127.0.0.1')) {
      throw Exception(
        'USB scan solo disponible cuando el agente es local (127.0.0.1).',
      );
    }
    await run('npm run usb-scan', verbose: false);
  }

  Future<void> assignPrinter(String area, String printerName) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('printer_$area', printerName);
  }

  Future<String?> getAssignedPrinter(String area) async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getString('printer_$area');
  }
}
