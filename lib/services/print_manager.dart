import 'dart:convert';

import 'package:http/http.dart' as http;

import 'escpos_ticket_service.dart';
import 'print_agent_detector.dart';
import 'usb_printer_manager.dart';

/// Orquestador principal para detección de agente y envío de impresiones.
class PrintManager {
  final _detector = PrintAgentDetector();
  final _escpos = EscposTicketService();

  String? _agentUrl;
  UsbPrinterManager? _usb;

  String? get agentUrl => _agentUrl;

  /// Auto-detecta agente (localhost > cache > LAN) y prepara USB manager.
  Future<void> init() async {
    _agentUrl = await _detector.scanLocalFirst();
    if (_agentUrl == null) {
      throw Exception('No se encontró Print Agent en LAN.');
    }
    _usb = UsbPrinterManager(_agentUrl!);
  }

  Future<void> usbScan() async {
    if (_usb == null) throw Exception('init() no ejecutado');
    await _usb!.triggerUsbScan();
  }

  Future<List<dynamic>> listPrinters() async {
    if (_usb == null) throw Exception('init() no ejecutado');
    return _usb!.fetchPrinters();
  }

  Future<void> assignAreaPrinter(String area, String printer) async {
    if (_usb == null) throw Exception('init() no ejecutado');
    await _usb!.assignPrinter(area, printer);
  }

  Future<String> statusText() async {
    if (_agentUrl == null) return '⚪ Sin agente';
    final st = await _detector.testAgent(_agentUrl!);
    final count = st.printers.length;
    return st.ok
        ? '🟢 ${_agentUrl!.replaceFirst('http://', '')} ($count printers)'
        : '🔴 ${_agentUrl!.replaceFirst('http://', '')} offline';
  }

  Future<void> printKitchenTicket({
    required String orderId,
    required List<Map<String, dynamic>> items,
    String area = 'kitchen',
  }) async {
    final bytes = await _escpos.buildKitchenBytes(
      orderId: orderId,
      items: items,
      area: area,
    );
    await _sendPrint(area: area, bytes: bytes);
  }

  Future<void> printReceipt({
    required String orderId,
    required List<Map<String, dynamic>> items,
    required double total,
  }) async {
    final bytes = await _escpos.buildReceiptBytes(
      orderId: orderId,
      items: items,
      total: total,
    );
    await _sendPrint(area: 'cashier', bytes: bytes);
  }

  Future<void> _sendPrint({
    required String area,
    required List<int> bytes,
  }) async {
    if (_agentUrl == null) throw Exception('init() no ejecutado');
    final res = await http.post(
      Uri.parse('$_agentUrl/print'),
      headers: {'Content-Type': 'application/json'},
      body: jsonEncode({'area': area, 'bytes': bytes}),
    );
    if (res.statusCode != 200) {
      throw Exception('Error al imprimir: ${res.body}');
    }
  }
}
