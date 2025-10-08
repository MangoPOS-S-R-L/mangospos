// lib/data/repositories/printing_repository.dart
import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:http/http.dart' as http;
import 'package:mangopos/data/models/printing.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

class PrintingRepository {
  PrintingRepository(this._client, {List<String>? agentBases})
    : _agentBases =
          agentBases ??
          const [
            // Puertos típicos para el agente (Express/Electron/etc.)
            'http://127.0.0.1:3000',
            'http://localhost:3000',
            'http://127.0.0.1:3001',
            'http://localhost:3001',
            // Emulador Android accediendo al host
            'http://10.0.2.2:3000',
            'http://10.0.2.2:3001',
            // (opcional) algunos agentes usan 9977
            'http://127.0.0.1:9977',
            'http://localhost:9977',
            'http://10.0.2.2:9977',
          ];

  final SupabaseClient _client;

  // ====== Agente local (Express/Electron) ======
  final List<String> _agentBases;

  Future<Uri?> _resolveAgentBase() async {
    // Más margen por preflight/CORS/antivirus en Web
    final healthTimeout = kIsWeb
        ? const Duration(milliseconds: 1500)
        : const Duration(milliseconds: 1200);

    for (final base in _agentBases) {
      final uri = Uri.parse('$base/health');
      try {
        final r = await http.get(uri).timeout(healthTimeout);
        if (r.statusCode == 200) return Uri.parse(base);
      } catch (_) {
        // intenta con la siguiente base
      }
    }
    return null;
  }

  /// Indica si el agente LAN está disponible en alguna de las bases.
  Future<bool> isAgentUp() async => (await _resolveAgentBase()) != null;

  /// Llama al agente para **descubrir impresoras** y devuelve la lista **cruda** (NO guarda).
  /// Estructura esperada por item: `{ ip, name?, type? }`.
  Future<List<Map<String, dynamic>>> discoverWithAgentRaw({
    String? hintCidr, // ej. '192.168.0.0/24' para acelerar
  }) async {
    final base = await _resolveAgentBase();
    if (base == null) {
      throw Exception(
        'Agente de impresión no disponible en localhost/127.0.0.1.',
      );
    }

    final path = '/api/printers/discover';
    final uri = (hintCidr == null || hintCidr.isEmpty)
        ? base.replace(path: path)
        : base.replace(path: path, queryParameters: {'hint': hintCidr});

    // Tiempo mayor en Web (preflight + escaneo)
    final discoverTimeout = kIsWeb
        ? const Duration(seconds: 45)
        : const Duration(seconds: 15);

    http.Response r;
    try {
      r = await http.get(uri).timeout(discoverTimeout);
    } on TimeoutException {
      throw Exception(
        'El agente tardó más de ${discoverTimeout.inSeconds}s en responder /discover.',
      );
    }

    if (r.statusCode != 200) {
      throw Exception('Agent /discover respondió ${r.statusCode}: ${r.body}');
    }

    final data = jsonDecode(r.body) as Map<String, dynamic>;
    final items = (data['items'] as List? ?? const [])
        .cast<Map<String, dynamic>>();
    return items;
  }

  /// Llama al agente y **asegura upsert** en Supabase (GUARDA).
  Future<List<PrinterDevice>> discoverWithAgent(
    String businessId, {
    String? hintCidr,
  }) async {
    final raw = await discoverWithAgentRaw(hintCidr: hintCidr);
    final out = <PrinterDevice>[];
    for (final m in raw) {
      final ip = (m['ip'] as String?)?.trim();
      final name =
          (m['name'] as String?)?.trim() ?? (ip != null ? 'Printer $ip' : null);
      if (ip == null || name == null) continue;
      final dev = await _upsertNetworkPrinter(
        businessId: businessId,
        name: name,
        ip: ip,
      );
      out.add(dev);
    }
    return out;
  }

  /// Envia una **impresión de prueba** al agente.
  /// El agente debe abrir socket al `ip:port` indicado (por defecto 9100).
  // Devuelve la base seleccionada (útil para debug UI/SnackBar)
  Future<Uri?> agentBaseSelected() => _resolveAgentBase();

  Future<void> testPrintViaAgent({required String ip, int port = 9100}) async {
    final base = await _resolveAgentBase();
    if (base == null) {
      throw Exception('Agente no disponible (no respondió /health).');
    }

    // Endpoints compatibles que vamos a intentar en orden
    final paths = <String>[
      '/api/printers/test',
      '/api/print/test',
      '/print/test',
      '/test-print',
    ];

    // Tiempo por intento (un poco mayor en Web)
    final attemptTimeout = kIsWeb
        ? const Duration(seconds: 15)
        : const Duration(seconds: 8);

    // Acumulamos errores para un mensaje útil
    final errors = <String>[];

    for (final p in paths) {
      final uri = base.replace(path: p);
      try {
        final res = await http
            .post(
              uri,
              headers: {'Content-Type': 'application/json'},
              // Enviamos ambas claves posibles: ip y host
              body: jsonEncode({'ip': ip, 'host': ip, 'port': port}),
            )
            .timeout(attemptTimeout);

        if (res.statusCode == 200) {
          // Éxito
          return;
        } else {
          errors.add('${uri.path} -> ${res.statusCode} ${res.body}');
        }
      } on TimeoutException {
        errors.add('${uri.path} -> timeout (${attemptTimeout.inSeconds}s)');
      } catch (e) {
        errors.add('${uri.path} -> $e');
      }

      // Si el POST no funcionó, probamos GET con query (algunos agentes lo esperan así)
      try {
        final getUri = base.replace(
          path: p,
          queryParameters: {'ip': ip, 'port': '$port'},
        );
        final res = await http.get(getUri).timeout(attemptTimeout);
        if (res.statusCode == 200) {
          return;
        } else {
          errors.add('GET ${getUri.path} -> ${res.statusCode} ${res.body}');
        }
      } on TimeoutException {
        errors.add('GET $p -> timeout (${attemptTimeout.inSeconds}s)');
      } catch (e) {
        errors.add('GET $p -> $e');
      }
    }

    // Si llegamos aquí, todos los intentos fallaron
    throw Exception(
      'Ninguna ruta del Agente respondió OK. '
      'Base=${base.toString()}.\n'
      'Detalles:\n- ${errors.join('\n- ')}',
    );
  }

  // =================== SUPABASE ===================

  // ------- Printers -------
  Future<List<PrinterDevice>> getPrinters(String businessId) async {
    final rows = await _client
        .from('printers')
        .select()
        .eq('business_id', businessId)
        .order('created_at');
    return (rows as List<dynamic>)
        .map((e) => PrinterDevice.fromMap(e as Map<String, dynamic>))
        .toList();
  }

  Future<void> createPrinter({
    required String businessId,
    required String name,
    String? ip,
    String? mac,
    PrinterType type = PrinterType.network,
  }) {
    return _client.from('printers').insert({
      'business_id': businessId,
      'name': name,
      'ip': ip,
      'mac': mac,
      'type': type.name,
    });
  }

  Future<void> savePrinter(PrinterDevice printer) {
    return _client.from('printers').upsert(printer.toMap());
  }

  Future<void> deletePrinter(String id) {
    return _client.from('printers').delete().eq('id', id);
  }

  Future<void> enqueueTestPrint(String printerId) {
    return _client.rpc(
      'enqueue_print_test',
      params: {'p_printer_id': printerId},
    );
  }

  // ------- Areas -------
  Future<List<PrintArea>> getPrintAreas(String businessId) async {
    final rows = await _client
        .from('print_areas_view')
        .select()
        .eq('business_id', businessId)
        .order('created_at');
    return (rows as List<dynamic>)
        .map((e) => PrintArea.fromMap(e as Map<String, dynamic>))
        .toList();
  }

  Future<void> createArea({required String businessId, required String name}) {
    return _client.from('print_areas').insert({
      'business_id': businessId,
      'name': name,
    });
  }

  Future<void> deleteArea(String id) {
    return _client.from('print_areas').delete().eq('id', id);
  }

  // ------- Area <-> Printer assignments -------
  Future<List<PrintAreaPrinter>> getAreaPrinters(String areaId) async {
    final rows = await _client
        .from('print_area_printers')
        .select()
        .eq('area_id', areaId);
    return (rows as List<dynamic>)
        .map((e) => PrintAreaPrinter.fromMap(e as Map<String, dynamic>))
        .toList();
  }

  Future<void> linkAreaToPrinter({
    required String businessId,
    required String areaId,
    required String printerId,
    bool enabled = true,
    bool printsOrders = true,
    bool printsPrebills = false,
    bool printsReceipts = false,
  }) {
    return _client.from('print_area_printers').upsert({
      'business_id': businessId,
      'area_id': areaId,
      'printer_id': printerId,
      'enabled': enabled,
      'prints_orders': printsOrders,
      'prints_prebills': printsPrebills,
      'prints_receipts': printsReceipts,
    });
  }

  Future<void> unlinkAreaPrinter({
    required String areaId,
    required String printerId,
  }) {
    return _client.from('print_area_printers').delete().match({
      'area_id': areaId,
      'printer_id': printerId,
    });
  }

  // =================== Helpers privados ===================

  Future<PrinterDevice?> _findByIp(String businessId, String ip) async {
    final row = await _client
        .from('printers')
        .select()
        .eq('business_id', businessId)
        .eq('ip', ip)
        .maybeSingle();
    if (row == null) return null;
    return PrinterDevice.fromMap(row);
  }

  Future<PrinterDevice> _upsertNetworkPrinter({
    required String businessId,
    required String name,
    required String ip,
  }) async {
    final exists = await _findByIp(businessId, ip);
    if (exists != null) return exists;

    final inserted = await _client
        .from('printers')
        .insert({
          'business_id': businessId,
          'name': name,
          'ip': ip,
          'type': PrinterType.network.name,
          'online': true,
        })
        .select()
        .single();

    return PrinterDevice.fromMap(inserted);
  }
}
