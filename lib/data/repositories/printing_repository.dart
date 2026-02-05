import 'package:supabase_flutter/supabase_flutter.dart';

import 'package:mangopos/core/services/local_print_service.dart';

import '../models/printing_models.dart';

/// 🖨️ Repositorio de Impresión
class PrintingRepository {
  final SupabaseClient _client;

  PrintingRepository(this._client);

  // ============================================================
  // 🖨️ IMPRESORAS
  // ============================================================

  /// Obtener impresoras activas
  Future<List<PrinterConfig>> getActivePrinters(String businessId) async {
    try {
      final data = await _client
          .from('printers')
          .select()
          .eq('business_id', businessId)
          .order('name', ascending: true);

      return data.map((json) => PrinterConfig.fromMap(json)).toList();
    } catch (e) {
      throw Exception('Error al obtener impresoras: $e');
    }
  }

  /// Obtener impresora por ID
  Future<PrinterConfig?> getPrinter(String printerId) async {
    try {
      final data = await _client
          .from('printers')
          .select()
          .eq('id', printerId)
          .maybeSingle();

      if (data == null) return null;

      return PrinterConfig.fromMap(data);
    } catch (e) {
      throw Exception('Error al obtener impresora: $e');
    }
  }

  /// Crear impresora
  Future<PrinterConfig> createPrinter({
    required String businessId,
    required String name,
    required String type,
    String? ipAddress,
    int? port,
    String? devicePath,
    int paperWidth = 80,
  }) async {
    try {
      final data = await _client
          .from('printers')
          .insert({
            'business_id': businessId,
            'name': name,
            'type': type,
            'ip_address': ipAddress,
            'port': port,
            'device_path': devicePath,
            'paper_width': paperWidth,
            'online': false,
          })
          .select()
          .single();

      return PrinterConfig.fromMap(data);
    } catch (e) {
      throw Exception('Error al crear impresora: $e');
    }
  }

  /// Actualizar impresora
  Future<void> updatePrinter({
    required String printerId,
    String? name,
    String? ipAddress,
    int? port,
    bool? isActive,
  }) async {
    try {
      final updates = <String, dynamic>{};
      if (name != null) updates['name'] = name;
      if (ipAddress != null) updates['ip_address'] = ipAddress;
      if (port != null) updates['port'] = port;
      if (isActive != null) updates['online'] = isActive;

      await _client.from('printers').update(updates).eq('id', printerId);
    } catch (e) {
      throw Exception('Error al actualizar impresora: $e');
    }
  }

  // ============================================================
  // 📍 ÁREAS DE IMPRESIÓN
  // ============================================================

  /// Obtener áreas de impresión
  Future<List<PrintArea>> getPrintAreas(String businessId) async {
    try {
      final data = await _client
          .from('print_areas')
          .select()
          .eq('business_id', businessId)
          .order('name', ascending: true);

      return data.map((json) => PrintArea.fromMap(json)).toList();
    } catch (e) {
      throw Exception('Error al obtener áreas: $e');
    }
  }

  /// Obtener impresoras asignadas a un área
  Future<List<PrinterConfig>> getPrintersForArea(String areaId) async {
    try {
      final data = await _client
          .from('print_area_printers')
          .select('printer_id, printers(*)')
          .eq('area_id', areaId)
          .order('priority', ascending: true);

      return data
          .map((json) => PrinterConfig.fromMap(json['printers']))
          .toList();
    } catch (e) {
      throw Exception('Error al obtener impresoras del área: $e');
    }
  }

  /// Asignar impresora a área
  Future<void> assignPrinterToArea({
    required String areaId,
    required String printerId,
    int priority = 1,
  }) async {
    try {
      await _client.from('print_area_printers').insert({
        'area_id': areaId,
        'printer_id': printerId,
        'priority': priority,
      });
    } catch (e) {
      throw Exception('Error al asignar impresora: $e');
    }
  }

  /// Remover impresora de área
  Future<void> removePrinterFromArea({
    required String areaId,
    required String printerId,
  }) async {
    try {
      await _client
          .from('print_area_printers')
          .delete()
          .eq('area_id', areaId)
          .eq('printer_id', printerId);
    } catch (e) {
      throw Exception('Error al remover impresora: $e');
    }
  }

  // ============================================================
  // 📄 TRABAJOS DE IMPRESIÓN
  // ============================================================

  /// Obtener trabajos pendientes
  Future<List<PrintJob>> getPendingJobs(String businessId) async {
    try {
      final data = await _client
          .from('print_jobs')
          .select()
          .eq('business_id', businessId)
          .eq('status', 'pending')
          .order('created_at', ascending: true)
          .limit(50);

      return data.map((json) => PrintJob.fromMap(json)).toList();
    } catch (e) {
      throw Exception('Error al obtener trabajos pendientes: $e');
    }
  }

  /// Crear trabajo de impresión
  Future<PrintJob> createPrintJob({
    required String businessId,
    required String areaId,
    required String type,
    required Map<String, dynamic> data,
    String? orderId,
    String? checkId,
  }) async {
    try {
      final jobData = await _client
          .from('print_jobs')
          .insert({
            'business_id': businessId,
            'area_id': areaId,
            'order_id': orderId,
            'check_id': checkId,
            'type': type,
            'status': 'pending',
            'data': data,
          })
          .select()
          .single();

      return PrintJob.fromMap(jobData);
    } catch (e) {
      throw Exception('Error al crear trabajo de impresión: $e');
    }
  }

  /// Actualizar estado de trabajo
  Future<void> updateJobStatus({
    required String jobId,
    required String status,
    String? printerId,
    String? errorMessage,
  }) async {
    try {
      final updates = <String, dynamic>{'status': status};

      if (printerId != null) updates['printer_id'] = printerId;
      if (errorMessage != null) updates['error_message'] = errorMessage;
      if (status == 'printed') {
        updates['printed_at'] = DateTime.now().toIso8601String();
      }

      await _client.from('print_jobs').update(updates).eq('id', jobId);
    } catch (e) {
      throw Exception('Error al actualizar estado: $e');
    }
  }

  /// Reintentar trabajo fallido
  Future<void> retryJob(String jobId) async {
    try {
      await _client
          .from('print_jobs')
          .update({
            'status': 'pending',
            'retry_count': 0,
            'error_message': null,
          })
          .eq('id', jobId);
    } catch (e) {
      throw Exception('Error al reintentar trabajo: $e');
    }
  }

  // ============================================================
  // 🔔 SUSCRIPCIONES EN TIEMPO REAL
  // ============================================================

  /// Suscribirse a nuevos trabajos de impresión
  Stream<List<PrintJob>> subscribeToPrintJobs(String businessId) {
    return _client
        .from('print_jobs')
        .stream(primaryKey: ['id'])
        .map(
          (data) => data
              .where(
                (json) =>
                    json['business_id'] == businessId &&
                    json['status'] == 'pending',
              )
              .toList(),
        )
        .map((data) => data.map((json) => PrintJob.fromMap(json)).toList());
  }

  // ============================================================
  // 🔄 MÉTODOS DE COMPATIBILIDAD (para código viejo)
  // ============================================================

  /// Alias de getActivePrinters (compatibilidad)
  Future<List<PrinterConfig>> getPrinters(String businessId) async {
    return getActivePrinters(businessId);
  }

  /// Eliminar impresora (compatibilidad)
  Future<void> deletePrinter(String printerId) async {
    await updatePrinter(printerId: printerId, isActive: false);
  }

  /// Crear trabajo de test (compatibilidad)
  Future<void> enqueueTestPrint(String printerId) async {
    final printer = await getPrinter(printerId);
    if (printer == null) throw Exception('Impresora no encontrada');

    await createPrintJob(
      businessId: printer.businessId,
      areaId: 'test',
      type: 'test',
      data: {'printer_id': printerId},
    );
  }

  // Local Print Service
  final _localService = LocalPrintService();

  /// Verificar si agent (Mango Local Agent) está activo
  Future<bool> isAgentUp() async {
    return await _localService.isAgentAvailable();
  }

  /// Verificar estado de conectividad de una lista de impresoras
  Future<Map<String, bool>> checkPrintersHealth(
    List<PrinterConfig> printers,
  ) async {
    final payload = printers
        .where((p) => p.ipAddress != null)
        .map((p) => {'ip': p.ipAddress, 'port': p.port ?? 9100})
        .toList();

    return await _localService.checkConnectivity(payload);
  }

  /// Test via agent (Local Agent)
  Future<void> testPrintViaAgent({
    required String ip,
    required int port,
    List<int>? customData,
  }) async {
    // Construct Job Payload for Agent
    final job = {
      'id': 'TEST-${DateTime.now().millisecondsSinceEpoch}',
      'printer': {'type': 'network', 'ip': ip, 'port': port},
      'content': {
        'title': 'Test de Impresión',
        'body': 'Si lees esto, el Agente Local funciona correctamente.',
        'lines': [
          '--------------------------------',
          'Conexión: OK',
          'IP: $ip',
          '--------------------------------',
        ],
      },
    };

    final success = await _localService.printJob(job);
    if (!success) {
      throw Exception('El agente no pudo completar la impresión');
    }
  }

  /// Imprimir Job genérico vía Agente (Público)
  Future<void> printJobViaAgent(Map<String, dynamic> jobPayload) async {
    final success = await _localService.printJob(jobPayload);
    if (!success) {
      throw Exception('El agente local rechazó el trabajo de impresión.');
    }
  }

  /// Descubrir con agent (Scan Subnet)
  Future<List<dynamic>> discoverWithAgent(String businessId) async {
    // TODO: Implementar endpoint /scan en el agente
    // Por ahora retornamos lista vacía o mock
    return [];
  }

  // ... (Resto de métodos de compatibilidad)

  /// Print Custom ESC/POS Data via Agent
  Future<void> printCustomData({
    required String ip,
    required List<int> data,
  }) async {
    // Para RAW printing el agente necesitaría soportar base64 o similar
    // Por ahora enviamos un mensaje genérico.
    final job = {
      'id': 'RAW-${DateTime.now().millisecondsSinceEpoch}',
      'printer': {'type': 'network', 'ip': ip, 'port': 9100},
      'content': {
        'title': 'RAW DATA PRINT',
        'body': 'Raw printing not yet fully implemented in dart-side.',
      },
    };
    await _localService.printJob(job);
  }

  /// Crear área de impresión (compatibilidad)
  Future<PrintArea> createArea({
    required String businessId,
    required String name,
    required String code,
  }) async {
    final data = await _client
        .from('print_areas')
        .insert({
          'business_id': businessId,
          'name': name,
          'code': code,
          'is_active': true,
        })
        .select()
        .single();

    return PrintArea.fromMap(data);
  }

  /// Eliminar área (compatibilidad)
  Future<void> deleteArea(String areaId) async {
    await _client.from('print_areas').delete().eq('id', areaId);
  }

  /// Vincular area a impresora con configuracion de tipos de impresion
  Future<void> linkAreaToPrinter({
    required String businessId,
    required String areaId,
    required String printerId,
    bool enabled = true,
    bool printsOrders = true,
    bool printsPrebills = false,
    bool printsReceipts = false,
    int priority = 1,
  }) async {
    try {
      await _client.from('print_area_printers').upsert({
        'business_id': businessId,
        'area_id': areaId,
        'printer_id': printerId,
        'priority': priority,
        'enabled': enabled,
        'prints_orders': printsOrders,
        'prints_prebills': printsPrebills,
        'prints_receipts': printsReceipts,
      }, onConflict: 'area_id,printer_id');
    } catch (e) {
      throw Exception('Error al vincular impresora a area: $e');
    }
  }
}
