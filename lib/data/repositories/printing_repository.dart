import 'dart:convert';
import 'package:http/http.dart' as http;
import 'package:supabase_flutter/supabase_flutter.dart';
import 'dart:io';
import 'dart:async';
import 'package:flutter/foundation.dart' show kIsWeb;

import 'package:mangopos/core/printing/bluetooth_print_service.dart';
import 'package:mangopos/core/printing/device_identity.dart';
import 'package:mangopos/core/services/local_print_service.dart';

import '../models/printing_models.dart';

/// 🖨️ Repositorio de Impresión
class PrintingRepository {
  final SupabaseClient _client;
  static const Duration _lookupCacheTtl = Duration(minutes: 5);
  static final Map<String, _CachedLookup<List<PrintArea>>> _printAreasCache =
      {};
  static final Map<String, _CachedLookup<PrinterConfig?>>
  _assignedPrinterCache = {};
  static final Map<String, _CachedLookup<List<PrinterConfig>>>
  _orderPrintersCache = {};

  PrintingRepository(this._client);

  static T? _readCached<T>(Map<String, _CachedLookup<T>> cache, String key) {
    final entry = cache[key];
    if (entry == null) return null;
    if (DateTime.now().difference(entry.cachedAt) >= _lookupCacheTtl) {
      cache.remove(key);
      return null;
    }
    return entry.value;
  }

  static void _writeCached<T>(
    Map<String, _CachedLookup<T>> cache,
    String key,
    T value,
  ) {
    cache[key] = _CachedLookup(value, DateTime.now());
  }

  static void _clearLookupCaches() {
    _printAreasCache.clear();
    _assignedPrinterCache.clear();
    _orderPrintersCache.clear();
  }

  String _assignedPrinterLookupKey({
    required String businessId,
    required List<String> preferredAreaCodes,
    required bool printsOrders,
    required bool printsPrebills,
    required bool printsReceipts,
  }) {
    return [
      businessId,
      preferredAreaCodes.join(','),
      if (printsOrders) 'orders',
      if (printsPrebills) 'prebills',
      if (printsReceipts) 'receipts',
    ].join('|');
  }

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
    String? mac,
    int paperWidth = 80,
    String? hostDeviceId,
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
            'mac': mac,
            'paper_width': paperWidth,
            'online': false,
            if (hostDeviceId != null && hostDeviceId.isNotEmpty)
              'host_device_id': hostDeviceId,
          })
          .select()
          .single();

      _clearLookupCaches();
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
    String? type,
    String? devicePath,
    String? mac,
    bool? isActive,
    int? paperWidth,
    String? encoding,
  }) async {
    try {
      final updates = <String, dynamic>{};
      if (name != null) updates['name'] = name;
      if (ipAddress != null) updates['ip_address'] = ipAddress;
      if (port != null) updates['port'] = port;
      if (type != null) updates['type'] = type;
      if (devicePath != null) updates['device_path'] = devicePath;
      if (mac != null) updates['mac'] = mac;
      if (isActive != null) updates['online'] = isActive;
      if (paperWidth != null) updates['paper_width'] = paperWidth;
      if (encoding != null) updates['encoding'] = encoding;

      if (updates.isEmpty) return;
      await _client.from('printers').update(updates).eq('id', printerId);
      _clearLookupCaches();
    } catch (e) {
      throw Exception('Error al actualizar impresora: $e');
    }
  }

  Future<Map<String, PrinterUsageSummary>> getPrinterUsageSummaries(
    String businessId,
  ) async {
    try {
      final data = await _client
          .from('print_area_printers')
          .select(
            'printer_id, area_id, enabled, prints_orders, prints_prebills, prints_receipts',
          )
          .eq('business_id', businessId)
          .eq('enabled', true);

      final areaIdsByPrinter = <String, Set<String>>{};
      final ordersByPrinter = <String, int>{};
      final prebillsByPrinter = <String, int>{};
      final receiptsByPrinter = <String, int>{};

      for (final row in data) {
        final printerId = row['printer_id']?.toString();
        final areaId = row['area_id']?.toString();
        if (printerId == null ||
            printerId.isEmpty ||
            areaId == null ||
            areaId.isEmpty) {
          continue;
        }

        areaIdsByPrinter.putIfAbsent(printerId, () => <String>{}).add(areaId);
        if (row['prints_orders'] == true) {
          ordersByPrinter[printerId] = (ordersByPrinter[printerId] ?? 0) + 1;
        }
        if (row['prints_prebills'] == true) {
          prebillsByPrinter[printerId] =
              (prebillsByPrinter[printerId] ?? 0) + 1;
        }
        if (row['prints_receipts'] == true) {
          receiptsByPrinter[printerId] =
              (receiptsByPrinter[printerId] ?? 0) + 1;
        }
      }

      final summaries = <String, PrinterUsageSummary>{};
      final printerIds = <String>{
        ...areaIdsByPrinter.keys,
        ...ordersByPrinter.keys,
        ...prebillsByPrinter.keys,
        ...receiptsByPrinter.keys,
      };

      for (final printerId in printerIds) {
        summaries[printerId] = PrinterUsageSummary(
          assignedAreas: areaIdsByPrinter[printerId]?.length ?? 0,
          ordersAssignments: ordersByPrinter[printerId] ?? 0,
          prebillAssignments: prebillsByPrinter[printerId] ?? 0,
          receiptAssignments: receiptsByPrinter[printerId] ?? 0,
        );
      }

      return summaries;
    } catch (e) {
      throw Exception('Error al obtener uso de impresoras: $e');
    }
  }

  // ============================================================
  // 📍 ÁREAS DE IMPRESIÓN
  // ============================================================

  /// Obtener áreas de impresión
  Future<List<PrintArea>> getPrintAreas(String businessId) async {
    final cached = _readCached(_printAreasCache, businessId);
    if (cached != null) return cached;

    try {
      final data = await _client
          .from('print_areas')
          .select()
          .eq('business_id', businessId)
          .order('name', ascending: true);

      final areas = data.map((json) => PrintArea.fromMap(json)).toList();
      _writeCached(_printAreasCache, businessId, areas);
      return areas;
    } catch (e) {
      throw Exception('Error al obtener áreas: $e');
    }
  }

  Future<PrintArea?> getPrintAreaByCode({
    required String businessId,
    required String code,
  }) async {
    try {
      final data = await _client
          .from('print_areas')
          .select()
          .eq('business_id', businessId)
          .eq('code', code)
          .maybeSingle();

      if (data == null) return null;
      return PrintArea.fromMap(data);
    } catch (e) {
      throw Exception('Error al obtener área por código: $e');
    }
  }

  Future<PrintArea> ensurePrintArea({
    required String businessId,
    required String code,
    required String name,
  }) async {
    try {
      final existing = await getPrintAreaByCode(
        businessId: businessId,
        code: code,
      );
      if (existing != null) return existing;

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

      _clearLookupCaches();
      return PrintArea.fromMap(data);
    } catch (e) {
      throw Exception('Error al asegurar área de impresión: $e');
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

  Future<List<PrinterConfig>> getOrderPrintersForArea(String areaId) async {
    final cached = _readCached(_orderPrintersCache, areaId);
    if (cached != null) return cached;

    try {
      final data = await _client
          .from('print_area_printers')
          .select('priority, printers(*)')
          .eq('area_id', areaId)
          .eq('enabled', true)
          .eq('prints_orders', true)
          .order('priority', ascending: true);

      final printers = data
          .map((json) => PrinterConfig.fromMap(json['printers']))
          .toList();
      _writeCached(_orderPrintersCache, areaId, printers);
      return printers;
    } catch (e) {
      throw Exception('Error al obtener impresoras activas del área: $e');
    }
  }

  Future<List<PrinterConfig>> getReadyPrintersForArea(String areaId) async {
    try {
      final data = await _client
          .from('print_area_printers')
          .select('priority, printers(*)')
          .eq('area_id', areaId)
          .eq('enabled', true)
          .eq('prints_receipts', true)
          .order('priority', ascending: true);

      return data
          .map((json) => PrinterConfig.fromMap(json['printers']))
          .toList();
    } catch (e) {
      throw Exception('Error al obtener impresoras de listos del área: $e');
    }
  }

  Future<List<PrintAreaPrinter>> getAreaPrinterAssignments(
    String areaId,
  ) async {
    try {
      final data = await _client
          .from('print_area_printers')
          .select()
          .eq('area_id', areaId)
          .order('priority', ascending: true);

      return data
          .map(
            (row) => PrintAreaPrinter.fromMap(Map<String, dynamic>.from(row)),
          )
          .toList(growable: false);
    } catch (e) {
      throw Exception('Error al obtener asignaciones del área: $e');
    }
  }

  Future<Map<String, String>> getOrderPrinterSelections(
    String businessId,
  ) async {
    return getPrinterSelectionsByType(
      businessId: businessId,
      printsOrders: true,
    );
  }

  Future<Map<String, String>> getPrinterSelectionsByType({
    required String businessId,
    bool printsOrders = false,
    bool printsPrebills = false,
    bool printsReceipts = false,
  }) async {
    try {
      var query = _client
          .from('print_area_printers')
          .select('area_id, printer_id, priority')
          .eq('business_id', businessId)
          .eq('enabled', true);

      if (printsOrders) query = query.eq('prints_orders', true);
      if (printsPrebills) query = query.eq('prints_prebills', true);
      if (printsReceipts) query = query.eq('prints_receipts', true);

      final data = await query.order('priority', ascending: true);

      final selections = <String, String>{};
      for (final row in data) {
        final areaId = row['area_id']?.toString();
        final printerId = row['printer_id']?.toString();
        if (areaId == null ||
            areaId.isEmpty ||
            printerId == null ||
            printerId.isEmpty ||
            selections.containsKey(areaId)) {
          continue;
        }
        selections[areaId] = printerId;
      }
      return selections;
    } catch (e) {
      throw Exception('Error al obtener asignaciones de áreas: $e');
    }
  }

  Future<PrinterConfig?> getAssignedPrinterForType({
    required String businessId,
    required List<String> preferredAreaCodes,
    bool printsOrders = false,
    bool printsPrebills = false,
    bool printsReceipts = false,
  }) async {
    final cacheKey = _assignedPrinterLookupKey(
      businessId: businessId,
      preferredAreaCodes: preferredAreaCodes,
      printsOrders: printsOrders,
      printsPrebills: printsPrebills,
      printsReceipts: printsReceipts,
    );
    final cached = _readCached(_assignedPrinterCache, cacheKey);
    if (cached != null) return cached;

    try {
      final areas = await getPrintAreas(businessId);
      final areasByCode = {for (final area in areas) area.code: area};

      for (final areaCode in preferredAreaCodes) {
        final area = areasByCode[areaCode];
        if (area == null) continue;

        var query = _client
            .from('print_area_printers')
            .select('priority, printers(*)')
            .eq('business_id', businessId)
            .eq('area_id', area.id)
            .eq('enabled', true);

        if (printsOrders) query = query.eq('prints_orders', true);
        if (printsPrebills) query = query.eq('prints_prebills', true);
        if (printsReceipts) query = query.eq('prints_receipts', true);

        final data = await query.order('priority', ascending: true).limit(1);
        if (data.isEmpty) continue;

        final printer = data.first['printers'];
        if (printer != null) {
          final resolved = PrinterConfig.fromMap(printer);
          _writeCached(_assignedPrinterCache, cacheKey, resolved);
          return resolved;
        }
      }

      _writeCached<PrinterConfig?>(_assignedPrinterCache, cacheKey, null);
      return null;
    } catch (e) {
      throw Exception('Error al obtener la impresora asignada: $e');
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
      _clearLookupCaches();
    } catch (e) {
      throw Exception('Error al asignar impresora: $e');
    }
  }

  Future<void> updateAreaPrinterModes({
    required String areaId,
    required String printerId,
    required bool printsOrders,
    required bool printsReceipts,
  }) async {
    try {
      await _client
          .from('print_area_printers')
          .update({
            'prints_orders': printsOrders,
            'prints_receipts': printsReceipts,
            'enabled': printsOrders || printsReceipts,
          })
          .eq('area_id', areaId)
          .eq('printer_id', printerId);
      _clearLookupCaches();
    } catch (e) {
      throw Exception('Error al actualizar la configuración de impresión: $e');
    }
  }

  /// Remover impresora de área
  Future<void> removePrinterFromArea({
    required String areaId,
    required String printerId,
    bool removeOrders = true,
    bool removePrebills = true,
    bool removeReceipts = true,
  }) async {
    try {
      final row = await _client
          .from('print_area_printers')
          .select('prints_orders, prints_prebills, prints_receipts')
          .eq('area_id', areaId)
          .eq('printer_id', printerId)
          .maybeSingle();

      if (row == null) return;

      final nextOrders = (row['prints_orders'] == true) && !removeOrders;
      final nextPrebills = (row['prints_prebills'] == true) && !removePrebills;
      final nextReceipts = (row['prints_receipts'] == true) && !removeReceipts;

      if (!nextOrders && !nextPrebills && !nextReceipts) {
        await _client
            .from('print_area_printers')
            .delete()
            .eq('area_id', areaId)
            .eq('printer_id', printerId);
        _clearLookupCaches();
        return;
      }

      await _client
          .from('print_area_printers')
          .update({
            'prints_orders': nextOrders,
            'prints_prebills': nextPrebills,
            'prints_receipts': nextReceipts,
            'enabled': nextOrders || nextPrebills || nextReceipts,
          })
          .eq('area_id', areaId)
          .eq('printer_id', printerId);
      _clearLookupCaches();
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
      final payload = <String, dynamic>{
        'area_id': areaId,
        'type': type,
        'order_id': orderId,
        'check_id': checkId,
        'data': data,
      };

      final jobData = await _client
          .from('print_jobs')
          .insert({
            'business_id': businessId,
            'ip': _extractJobIp(data),
            'port': _extractJobPort(data),
            'data_hex': _encodePrintJobPayload(payload),
            'status': 'pending',
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

      if (errorMessage != null) updates['error'] = errorMessage;
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
          .update({'status': 'pending', 'error': null})
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
    try {
      await _client.from('printers').delete().eq('id', printerId);
      _clearLookupCaches();
    } catch (e) {
      throw Exception('Error al eliminar impresora: $e');
    }
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

  /// Enviar datos ESC/POS ya formateados (raw) vía agente
  Future<void> printRawViaAgent({
    required String ip,
    int port = 9100,
    required List<int> data,
  }) async {
    final ok = await _localService.printRawData(ip: ip, port: port, data: data);
    if (!ok) {
      throw Exception('El agente local rechazó los datos RAW');
    }
  }

  /// Enviar datos ESC/POS RAW a una impresora ya configurada en MangoPOS,
  /// incluyendo impresoras USB que dependen del Agente Local.
  Future<void> printRawViaAgentToPrinter({
    required PrinterConfig printer,
    required List<int> data,
    Map<String, dynamic>? meta,
  }) async {
    await _localService.printRawToAssignedPrinter(
      printer: printer.toMap(),
      data: data,
      meta: meta,
    );
  }

  /// Enviar datos ESC/POS directos por TCP (solo plataformas nativas).
  ///
  /// Garantías del flush+close:
  /// - try/finally cierra el socket aunque `flush` lance, evitando leaks de
  ///   FD cuando la térmica corta la conexión a media impresión.
  /// - `await socket.done` espera el handshake de cierre real; sin esto, el
  ///   `close()` retorna apenas inicia el shutdown y la térmica puede recibir
  ///   un FIN antes de procesar los últimos bytes (paper jam / corte parcial).
  Future<void> printRawDirectTcp({
    required String ip,
    int port = 9100,
    required List<int> data,
    Duration timeout = const Duration(seconds: 3),
  }) async {
    final socket = await Socket.connect(ip, port, timeout: timeout);
    try {
      socket.add(data);
      await socket.flush();
    } finally {
      await socket.close();
      await socket.done;
    }
  }

  Future<void> printEscPos({
    required PrinterConfig printer,
    required List<int> data,
    Duration timeout = const Duration(seconds: 5),
  }) async {
    // PRD 5 F2.5: routing por host_device_id.
    // Si la impresora está vinculada a un device físico (USB/BT) que NO es
    // este device, mandamos el job al agent remoto del host vía LAN.
    final hostId = printer.hostDeviceId?.trim();
    if (hostId != null && hostId.isNotEmpty) {
      final selfId =
          await DeviceIdentity.getOrCreateId(printer.businessId);
      if (hostId != selfId) {
        // No propagamos `timeout` (5s default) — el remoto necesita más
        // tiempo para abrir USB e imprimir físicamente. Usar el default
        // generoso de _printViaRemoteHost.
        await _printViaRemoteHost(
          printer: printer,
          data: data,
          hostDeviceId: hostId,
        );
        return;
      }
    }

    switch (printer.printerType) {
      case PrinterType.network:
        final ip = printer.ipAddress?.trim();
        if (ip == null || ip.isEmpty) {
          throw Exception('La impresora de red no tiene IP configurada.');
        }
        if (kIsWeb) {
          final up = await isAgentUp();
          if (!up) {
            throw Exception(
              'Para imprimir por red desde la Web necesitas el Agente LAN activo.',
            );
          }
          await printRawViaAgent(
            ip: ip,
            port: printer.port ?? 9100,
            data: data,
          );
          return;
        }
        try {
          await printRawDirectTcp(
            ip: ip,
            port: printer.port ?? 9100,
            data: data,
            timeout: timeout,
          );
        } catch (_) {
          if (await isAgentUp()) {
            await printRawViaAgent(
              ip: ip,
              port: printer.port ?? 9100,
              data: data,
            );
            return;
          }
          rethrow;
        }
        return;
      case PrinterType.usb:
        if (kIsWeb) {
          final up = await isAgentUp();
          if (!up) {
            throw Exception(
              'La impresora USB está asignada, pero este flujo necesita el Agente Local activo en la PC donde está conectada.',
            );
          }
          await printRawViaAgentToPrinter(printer: printer, data: data);
          return;
        }

        try {
          await printRawDirectUsb(
            printer: printer,
            data: data,
            timeout: timeout,
          );
          return;
        } catch (_) {
          if (await isAgentUp()) {
            await printRawViaAgentToPrinter(printer: printer, data: data);
            return;
          }
          rethrow;
        }
      case PrinterType.bluetooth:
        // PRD 5 F3: impresión BT directa via flutter_blue_plus (Mac/iOS/Android).
        // Evita depender del agente Node.js que no maneja BT.
        if (kIsWeb) {
          throw Exception(
            'La impresión Bluetooth no está disponible desde la Web.',
          );
        }
        final btId = (printer.mac ?? printer.devicePath ?? '').trim();
        if (btId.isEmpty) {
          throw Exception(
            'La impresora Bluetooth no tiene identificador para conectarse.',
          );
        }
        await BluetoothPrintService.printRaw(remoteId: btId, data: data);
        return;
    }
  }

  /// PRD 5 F2.5: rutear job a impresora hosteada por OTRO device del business.
  ///
  /// Lookup `device_agents.agent_url` del host → POST `/print` con el payload
  /// que el agent local sabe procesar (mismo formato que el agent procesa
  /// para sus printers locales).
  ///
  /// Si el host está offline (last_heartbeat_at > 90s), throw — el caller
  /// puede mostrar mensaje amigable al operador.
  Future<void> _printViaRemoteHost({
    required PrinterConfig printer,
    required List<int> data,
    required String hostDeviceId,
    // El agente remoto debe abrir USB, escribir payload, feed y cut antes
    // de responder. En impresoras lentas/cargadas eso supera 5s fácil.
    // 30s es generoso pero sigue acotado para no colgar la UI.
    Duration timeout = const Duration(seconds: 30),
  }) async {
    final row = await _client
        .from('device_agents')
        .select('agent_url, online, last_heartbeat_at, device_name')
        .eq('id', hostDeviceId)
        .maybeSingle();

    if (row == null) {
      throw Exception(
        'Esta impresora no está disponible. El dispositivo asociado no está registrado.',
      );
    }

    final online = row['online'] == true;
    final agentUrl = (row['agent_url'] as String?)?.trim();
    final hostName = (row['device_name'] as String?) ?? 'otro dispositivo';

    if (!online || agentUrl == null || agentUrl.isEmpty) {
      throw Exception(
        'No se puede imprimir: $hostName está fuera de línea.',
      );
    }

    // El agent local de Node.js expone POST /print con payload compatible.
    // Reusamos el mismo formato del Socket.io job para no fragmentar.
    final base64Data = base64Encode(data);
    final payload = <String, dynamic>{
      'id': 'REMOTE-${DateTime.now().millisecondsSinceEpoch}',
      'printer': {
        'id': printer.id,
        'type': printer.printerType.name,
        'name': printer.name,
        'ip': printer.ipAddress,
        'port': printer.port,
        'devicePath': printer.devicePath,
        'mac': printer.mac,
      },
      'content': {
        'type': 'raw_base64',
        'dataBase64': base64Data,
      },
    };

    final response = await http
        .post(
          Uri.parse('$agentUrl/print'),
          headers: const {'Content-Type': 'application/json'},
          body: jsonEncode(payload),
        )
        .timeout(timeout);

    if (response.statusCode != 200) {
      String detail = response.body.trim();
      try {
        final parsed = jsonDecode(response.body);
        if (parsed is Map && parsed['error'] is String) {
          detail = parsed['error'] as String;
        }
      } catch (_) {}
      if (detail.length > 200) detail = '${detail.substring(0, 200)}…';
      throw Exception(
        'No se pudo imprimir desde $hostName (código ${response.statusCode})'
        '${detail.isEmpty ? '' : ': $detail'}.',
      );
    }
  }

  Future<void> printRawDirectUsb({
    required PrinterConfig printer,
    required List<int> data,
    Duration timeout = const Duration(seconds: 10),
  }) async {
    if (Platform.isWindows) {
      await _printRawDirectUsbWindows(
        printerName: printer.name,
        devicePath: printer.devicePath,
        portHint: printer.mac,
        data: data,
        timeout: timeout,
      );
      return;
    }

    final devicePath = printer.devicePath?.trim();
    if (devicePath == null || devicePath.isEmpty) {
      throw Exception(
        'La impresora USB no tiene una ruta local configurada para impresión directa.',
      );
    }

    final file = File(devicePath);
    await file.writeAsBytes(data, mode: FileMode.writeOnly, flush: true);
  }

  Future<List<Map<String, dynamic>>> discoverLocalUsbPrinters() async {
    if (kIsWeb) return const [];
    if (Platform.isWindows) {
      return _discoverLocalUsbPrintersWindows();
    }
    if (Platform.isMacOS) {
      return _discoverLocalUsbPrintersMacOS();
    }
    if (Platform.isLinux) {
      return _discoverLocalUsbPrintersLinux();
    }
    return const [];
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
    return await _localService.discoverPrinters();
  }

  Future<List<Map<String, dynamic>>> _discoverLocalUsbPrintersWindows() async {
    final result = await _runPowerShell(r'''
$ErrorActionPreference = 'Stop'
$items = @(
  Get-CimInstance Win32_Printer |
    Where-Object { $_.Local -eq $true -and $_.PortName -match '^USB' } |
    Sort-Object Name |
    ForEach-Object {
      [pscustomobject]@{
        name = $_.Name
        type = 'usb'
        devicePath = $_.Name
        mac = $_.PortName
        portName = $_.PortName
        driverName = $_.DriverName
        deviceId = $_.DeviceID
      }
    }
)

if ($items.Count -eq 0) {
  '[]'
} else {
  $items | ConvertTo-Json -Compress
}
''', timeout: const Duration(seconds: 6));

    final stdout = result.stdout.toString().trim();
    if (stdout.isEmpty || stdout == 'null') return const [];

    final decoded = jsonDecode(stdout);
    if (decoded is List) {
      return decoded
          .whereType<Map>()
          .map((item) => Map<String, dynamic>.from(item))
          .toList(growable: false);
    }
    if (decoded is Map) {
      return [Map<String, dynamic>.from(decoded)];
    }
    return const [];
  }

  // PRD 5 F2.1 — descubrimiento USB en macOS via system_profiler.
  // Devuelve devices USB con vendor/product IDs filtrados a un set conocido
  // de fabricantes de impresoras térmicas (Epson, Star, Bixolon, genéricos).
  // Sin filtro devolvería decenas de devices irrelevantes (teclados, hubs, etc.).
  Future<List<Map<String, dynamic>>> _discoverLocalUsbPrintersMacOS() async {
    if (kIsWeb) return const [];
    try {
      final result = await Process.run(
        'system_profiler',
        const ['SPUSBDataType', '-json'],
      ).timeout(const Duration(seconds: 8));

      if (result.exitCode != 0) {
        return const [];
      }

      final stdout = result.stdout.toString().trim();
      if (stdout.isEmpty) return const [];

      final decoded = jsonDecode(stdout);
      if (decoded is! Map<String, dynamic>) return const [];

      final list = decoded['SPUSBDataType'];
      if (list is! List) return const [];

      final printers = <Map<String, dynamic>>[];
      _walkMacUsbTree(list, printers);
      return printers;
    } catch (_) {
      return const [];
    }
  }

  // Recursive walker: SPUSBDataType es un árbol (host controller → hub → device).
  // Identificamos como impresora si:
  //   - vendor_id matchea fabricante térmico conocido, O
  //   - device_class matchea clase USB Printer (07h), O
  //   - product_id contiene "thermal"/"printer" en el _name.
  void _walkMacUsbTree(
    List<dynamic> nodes,
    List<Map<String, dynamic>> out,
  ) {
    const knownThermalVendors = {
      // VID hex (sin 0x), normalizado a uppercase.
      '04B8': 'Epson',
      '0519': 'Star Micronics',
      '1504': 'Bixolon',
      '0FE6': 'ICS Advent / Generic 80mm',
      '0416': 'Winbond / Generic',
      '067B': 'Prolific (a veces usado por chinas genéricas)',
      '154F': 'SNBC',
      '0AA7': 'WinUsb / Generic POS',
      '20D1': 'Rongta',
      '0DD4': 'POS Generic',
    };

    for (final raw in nodes) {
      if (raw is! Map<String, dynamic>) continue;

      final children = raw['_items'];
      if (children is List) {
        _walkMacUsbTree(children, out);
      }

      final vendorIdRaw = raw['vendor_id']?.toString() ?? '';
      final productIdRaw = raw['product_id']?.toString() ?? '';
      final name = (raw['_name']?.toString() ?? 'USB device').trim();
      final manufacturer = raw['manufacturer']?.toString().trim() ?? '';
      final serial = raw['serial_num']?.toString().trim();
      final locationId = raw['location_id']?.toString().trim();

      if (vendorIdRaw.isEmpty && productIdRaw.isEmpty) continue;

      // vendor_id viene como '0x04b8 (Seiko Epson)' o '0x04b8'.
      final vidHex = _extractHexFromMacUsbField(vendorIdRaw);
      final pidHex = _extractHexFromMacUsbField(productIdRaw);
      if (vidHex == null) continue;

      final isThermalVendor = knownThermalVendors.containsKey(vidHex);
      final nameMatchesPrinter = name.toLowerCase().contains('printer') ||
          name.toLowerCase().contains('thermal') ||
          name.toLowerCase().contains('pos');

      if (!isThermalVendor && !nameMatchesPrinter) continue;

      out.add({
        'name': name.isNotEmpty ? name : 'USB Printer',
        'type': 'usb',
        'vid': vidHex,
        'pid': pidHex,
        'manufacturer': manufacturer.isNotEmpty
            ? manufacturer
            : (knownThermalVendors[vidHex] ?? ''),
        'devicePath': serial?.isNotEmpty == true ? 'usb://$vidHex:$pidHex/$serial' : 'usb://$vidHex:${pidHex ?? '*'}',
        'serial': serial,
        'locationId': locationId,
        'mac': '$vidHex:${pidHex ?? '0000'}',
      });
    }
  }

  // Convierte '0x04b8 (Seiko Epson)' o '0x04b8' a '04B8'.
  String? _extractHexFromMacUsbField(String raw) {
    if (raw.isEmpty) return null;
    final match = RegExp(r'0x([0-9a-fA-F]{1,4})').firstMatch(raw);
    if (match == null) return null;
    return match.group(1)!.toUpperCase().padLeft(4, '0');
  }

  // PRD 5 F2.1 — descubrimiento USB en Linux via lsusb.
  // Output de lsusb tipo: "Bus 002 Device 003: ID 04b8:0202 Seiko Epson Corp."
  Future<List<Map<String, dynamic>>> _discoverLocalUsbPrintersLinux() async {
    if (kIsWeb) return const [];
    try {
      final result = await Process.run('lsusb', const [])
          .timeout(const Duration(seconds: 5));
      if (result.exitCode != 0) return const [];

      final stdout = result.stdout.toString();
      const knownThermalVendors = {
        '04b8', '0519', '1504', '0fe6', '0416', '067b',
        '154f', '0aa7', '20d1', '0dd4',
      };

      final printers = <Map<String, dynamic>>[];
      final lineRe = RegExp(
        r'^Bus\s+\d+\s+Device\s+\d+:\s+ID\s+([0-9a-fA-F]{4}):([0-9a-fA-F]{4})\s*(.*)$',
        multiLine: true,
      );

      for (final match in lineRe.allMatches(stdout)) {
        final vid = match.group(1)!.toLowerCase();
        final pid = match.group(2)!.toLowerCase();
        final name = (match.group(3) ?? 'USB device').trim();

        final isThermalVendor = knownThermalVendors.contains(vid);
        final nameMatchesPrinter = name.toLowerCase().contains('printer') ||
            name.toLowerCase().contains('thermal') ||
            name.toLowerCase().contains('pos');

        if (!isThermalVendor && !nameMatchesPrinter) continue;

        printers.add({
          'name': name.isNotEmpty ? name : 'USB Printer',
          'type': 'usb',
          'vid': vid.toUpperCase(),
          'pid': pid.toUpperCase(),
          'manufacturer': name,
          'devicePath': 'usb://${vid.toUpperCase()}:${pid.toUpperCase()}',
          'mac': '${vid.toUpperCase()}:${pid.toUpperCase()}',
        });
      }

      return printers;
    } catch (_) {
      return const [];
    }
  }

  Future<void> _printRawDirectUsbWindows({
    required String printerName,
    required List<int> data,
    String? devicePath,
    String? portHint,
    Duration timeout = const Duration(seconds: 10),
  }) async {
    final base64Data = base64Encode(data);
    final result = await _runPowerShell('''
\$ErrorActionPreference = 'Stop'
\$printerName = ${_toPowerShellSingleQuoted(printerName)}
\$devicePath = ${_toPowerShellSingleQuoted(devicePath?.trim() ?? '')}
\$portHint = ${_toPowerShellSingleQuoted(portHint?.trim() ?? '')}
\$payload = '$base64Data'
\$bytes = [Convert]::FromBase64String(\$payload)

\$target = Get-CimInstance Win32_Printer |
  Where-Object {
    (\$printerName -and \$_.Name -eq \$printerName) -or
    (\$devicePath -and (\$_.Name -eq \$devicePath -or \$_.DeviceID -eq \$devicePath)) -or
    (\$portHint -and \$_.PortName -eq \$portHint)
  } |
  Select-Object -First 1

if (-not \$target) {
  \$target = Get-CimInstance Win32_Printer |
    Where-Object {
      \$_.Local -eq \$true -and \$_.PortName -match '^USB' -and (
        (\$printerName -and \$_.Name -like "*\$printerName*") -or
        (\$devicePath -and (\$_.Name -like "*\$devicePath*" -or \$_.DeviceID -like "*\$devicePath*")) -or
        (\$portHint -and \$_.PortName -like "*\$portHint*")
      )
    } |
    Select-Object -First 1
}

if (-not \$target) {
  throw "USB_PRINTER_NOT_FOUND name=\$printerName devicePath=\$devicePath port=\$portHint"
}

Add-Type -TypeDefinition @"
using System;
using System.Runtime.InteropServices;

public static class RawPrinterHelper
{
    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Ansi)]
    public class DOCINFOA
    {
        [MarshalAs(UnmanagedType.LPStr)]
        public string pDocName;
        [MarshalAs(UnmanagedType.LPStr)]
        public string pOutputFile;
        [MarshalAs(UnmanagedType.LPStr)]
        public string pDataType;
    }

    [DllImport("Winspool.drv", EntryPoint = "OpenPrinterA", SetLastError = true, CharSet = CharSet.Ansi, ExactSpelling = true, CallingConvention = CallingConvention.StdCall)]
    public static extern bool OpenPrinter(string szPrinter, out IntPtr hPrinter, IntPtr pd);

    [DllImport("Winspool.drv", EntryPoint = "ClosePrinter", SetLastError = true, ExactSpelling = true, CallingConvention = CallingConvention.StdCall)]
    public static extern bool ClosePrinter(IntPtr hPrinter);

    [DllImport("Winspool.drv", EntryPoint = "StartDocPrinterA", SetLastError = true, CharSet = CharSet.Ansi, ExactSpelling = true, CallingConvention = CallingConvention.StdCall)]
    public static extern bool StartDocPrinter(IntPtr hPrinter, int level, [In, MarshalAs(UnmanagedType.LPStruct)] DOCINFOA di);

    [DllImport("Winspool.drv", EntryPoint = "EndDocPrinter", SetLastError = true, ExactSpelling = true, CallingConvention = CallingConvention.StdCall)]
    public static extern bool EndDocPrinter(IntPtr hPrinter);

    [DllImport("Winspool.drv", EntryPoint = "StartPagePrinter", SetLastError = true, ExactSpelling = true, CallingConvention = CallingConvention.StdCall)]
    public static extern bool StartPagePrinter(IntPtr hPrinter);

    [DllImport("Winspool.drv", EntryPoint = "EndPagePrinter", SetLastError = true, ExactSpelling = true, CallingConvention = CallingConvention.StdCall)]
    public static extern bool EndPagePrinter(IntPtr hPrinter);

    [DllImport("Winspool.drv", EntryPoint = "WritePrinter", SetLastError = true, ExactSpelling = true, CallingConvention = CallingConvention.StdCall)]
    public static extern bool WritePrinter(IntPtr hPrinter, byte[] pBytes, int dwCount, out int dwWritten);
}
"@

\$handle = [IntPtr]::Zero
\$docStarted = \$false
\$pageStarted = \$false

if (-not [RawPrinterHelper]::OpenPrinter(\$target.Name, [ref]\$handle, [IntPtr]::Zero)) {
  \$err = [Runtime.InteropServices.Marshal]::GetLastWin32Error()
  throw "OPEN_PRINTER_FAILED \$err (\$(\$target.Name))"
}

try {
  \$doc = New-Object RawPrinterHelper+DOCINFOA
  \$doc.pDocName = 'MangoPOS'
  \$doc.pDataType = 'RAW'

  if (-not [RawPrinterHelper]::StartDocPrinter(\$handle, 1, \$doc)) {
    \$err = [Runtime.InteropServices.Marshal]::GetLastWin32Error()
    throw "START_DOC_FAILED \$err"
  }
  \$docStarted = \$true

  if (-not [RawPrinterHelper]::StartPagePrinter(\$handle)) {
    \$err = [Runtime.InteropServices.Marshal]::GetLastWin32Error()
    throw "START_PAGE_FAILED \$err"
  }
  \$pageStarted = \$true

  \$written = 0
  if (-not [RawPrinterHelper]::WritePrinter(\$handle, \$bytes, \$bytes.Length, [ref]\$written)) {
    \$err = [Runtime.InteropServices.Marshal]::GetLastWin32Error()
    throw "WRITE_PRINTER_FAILED \$err"
  }

  if (\$written -ne \$bytes.Length) {
    throw "WRITE_PRINTER_INCOMPLETE \$written/\$(\$bytes.Length)"
  }
}
finally {
  if (\$pageStarted) { [void][RawPrinterHelper]::EndPagePrinter(\$handle) }
  if (\$docStarted) { [void][RawPrinterHelper]::EndDocPrinter(\$handle) }
  if (\$handle -ne [IntPtr]::Zero) { [void][RawPrinterHelper]::ClosePrinter(\$handle) }
}
''', timeout: timeout);

    if (result.exitCode != 0) {
      final stderr = result.stderr.toString().trim();
      throw Exception(
        stderr.isEmpty ? 'No se pudo imprimir por USB en Windows.' : stderr,
      );
    }
  }

  Future<ProcessResult> _runPowerShell(
    String script, {
    Duration timeout = const Duration(seconds: 10),
  }) async {
    final result = await Process.run('powershell', [
      '-NoProfile',
      '-ExecutionPolicy',
      'Bypass',
      '-Command',
      script,
    ]).timeout(timeout);

    if (result.exitCode != 0) {
      final stderr = result.stderr.toString().trim();
      final stdout = result.stdout.toString().trim();
      throw Exception(
        [
          if (stderr.isNotEmpty) stderr,
          if (stdout.isNotEmpty) stdout,
        ].join('\n'),
      );
    }

    return result;
  }

  String _toPowerShellSingleQuoted(String value) {
    return "'${value.replaceAll("'", "''")}'";
  }

  // ... (Resto de métodos de compatibilidad)

  /// Print Custom ESC/POS Data via Agent
  Future<void> printCustomData({
    required String ip,
    required List<int> data,
  }) async {
    await _localService.printRawData(ip: ip, data: data);
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

    _clearLookupCaches();
    return PrintArea.fromMap(data);
  }

  /// Eliminar área (compatibilidad)
  Future<void> deleteArea(String areaId) async {
    await _client.from('print_areas').delete().eq('id', areaId);
    _clearLookupCaches();
  }

  // PRD 5 F4.2 — Bulk asignación de productos a áreas de impresión.
  // Carga categorías + items del business para que la UI ofrezca selección
  // masiva por categoría.

  /// Devuelve las categorías activas del business ordenadas por position.
  Future<List<Map<String, dynamic>>> getCategoriesForBusiness(
    String businessId,
  ) async {
    final data = await _client
        .from('categories')
        .select('id, name, position, is_active')
        .eq('business_id', businessId)
        .eq('is_active', true)
        .order('position', ascending: true)
        .order('name', ascending: true);
    return List<Map<String, dynamic>>.from(data as List);
  }

  /// Devuelve menu_items mínimos del business (id, name, category_id,
  /// print_area_code) para el bulk picker. Solo activos.
  Future<List<Map<String, dynamic>>> getMenuItemsMinimal(
    String businessId,
  ) async {
    final data = await _client
        .from('menu_items')
        .select('id, name, category_id, print_area_code, is_active')
        .eq('business_id', businessId)
        .eq('is_active', true)
        .order('name', ascending: true);
    return List<Map<String, dynamic>>.from(data as List);
  }

  /// Asigna [areaCode] a TODOS los menu_items en [itemIds] en una sola
  /// query batch. Idempotente — vuelve a llamar con el mismo set no
  /// genera side effects.
  Future<void> bulkUpdateMenuItemsPrintArea({
    required List<String> itemIds,
    required String areaCode,
  }) async {
    if (itemIds.isEmpty) return;
    await _client
        .from('menu_items')
        .update({'print_area_code': areaCode})
        .inFilter('id', itemIds);
  }

  /// PRD 5 F4.1: actualizar nombre y/o código de un área existente.
  Future<PrintArea> updateArea({
    required String areaId,
    String? name,
    String? code,
    bool? isActive,
  }) async {
    final patch = <String, dynamic>{};
    if (name != null) patch['name'] = name.trim();
    if (code != null) patch['code'] = code.trim().toLowerCase();
    if (isActive != null) patch['is_active'] = isActive;

    if (patch.isEmpty) {
      throw Exception('No hay cambios para guardar.');
    }

    final data = await _client
        .from('print_areas')
        .update(patch)
        .eq('id', areaId)
        .select()
        .single();

    _clearLookupCaches();
    return PrintArea.fromMap(data);
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
      _clearLookupCaches();
    } catch (e) {
      throw Exception('Error al vincular impresora a area: $e');
    }
  }

  Future<void> setAreaPrinterAssignment({
    required String businessId,
    required String areaId,
    required String printerId,
    bool printsOrders = false,
    bool printsPrebills = false,
    bool printsReceipts = false,
    int priority = 1,
  }) async {
    try {
      if (!printsOrders && !printsPrebills && !printsReceipts) {
        throw Exception('Debes indicar al menos un tipo de impresión.');
      }

      final rows = await _client
          .from('print_area_printers')
          .select(
            'area_id, printer_id, prints_orders, prints_prebills, prints_receipts',
          )
          .eq('business_id', businessId)
          .eq('area_id', areaId);

      for (final row in rows) {
        final rowPrinterId = row['printer_id']?.toString();
        if (rowPrinterId == null || rowPrinterId.isEmpty) continue;

        final nextOrders = (row['prints_orders'] == true) && !printsOrders;
        final nextPrebills =
            (row['prints_prebills'] == true) && !printsPrebills;
        final nextReceipts =
            (row['prints_receipts'] == true) && !printsReceipts;

        final touchesSameType =
            (printsOrders && row['prints_orders'] == true) ||
            (printsPrebills && row['prints_prebills'] == true) ||
            (printsReceipts && row['prints_receipts'] == true);

        if (!touchesSameType || rowPrinterId == printerId) continue;

        if (!nextOrders && !nextPrebills && !nextReceipts) {
          await _client
              .from('print_area_printers')
              .delete()
              .eq('business_id', businessId)
              .eq('area_id', areaId)
              .eq('printer_id', rowPrinterId);
        } else {
          await _client
              .from('print_area_printers')
              .update({
                'prints_orders': nextOrders,
                'prints_prebills': nextPrebills,
                'prints_receipts': nextReceipts,
                'enabled': nextOrders || nextPrebills || nextReceipts,
              })
              .eq('business_id', businessId)
              .eq('area_id', areaId)
              .eq('printer_id', rowPrinterId);
        }
      }

      await _client.from('print_area_printers').upsert({
        'business_id': businessId,
        'area_id': areaId,
        'printer_id': printerId,
        'priority': priority,
        'enabled': true,
        'prints_orders': printsOrders,
        'prints_prebills': printsPrebills,
        'prints_receipts': printsReceipts,
      }, onConflict: 'area_id,printer_id');
      _clearLookupCaches();
    } catch (e) {
      throw Exception('Error al asignar impresora al área: $e');
    }
  }

  String _extractJobIp(Map<String, dynamic> data) {
    final value = data['ip'];
    if (value is String && value.trim().isNotEmpty) {
      return value.trim();
    }
    return '127.0.0.1';
  }

  int _extractJobPort(Map<String, dynamic> data) {
    final value = data['port'];
    if (value is int) return value;
    if (value is String) return int.tryParse(value) ?? 9100;
    return 9100;
  }

  String _encodePrintJobPayload(Map<String, dynamic> payload) {
    final bytes = utf8.encode(jsonEncode(payload));
    return bytes.map((byte) => byte.toRadixString(16).padLeft(2, '0')).join();
  }

  /// Get a printer by its ID (used for register-specific printer lookup).
  Future<PrinterConfig?> getPrinterById(String printerId) async {
    try {
      final data = await _client
          .from('printers')
          .select()
          .eq('id', printerId)
          .maybeSingle();
      if (data == null) return null;
      return PrinterConfig.fromMap(data);
    } catch (e) {
      return null;
    }
  }
}

class _CachedLookup<T> {
  const _CachedLookup(this.value, this.cachedAt);

  final T value;
  final DateTime cachedAt;
}
