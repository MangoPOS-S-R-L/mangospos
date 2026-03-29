import 'dart:convert';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'dart:io';
import 'dart:async';
import 'package:flutter/foundation.dart' show kIsWeb;

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

  /// Enviar datos ESC/POS directos por TCP (solo plataformas nativas)
  Future<void> printRawDirectTcp({
    required String ip,
    int port = 9100,
    required List<int> data,
    Duration timeout = const Duration(seconds: 3),
  }) async {
    final socket = await Socket.connect(ip, port, timeout: timeout);
    socket.add(data);
    await socket.flush();
    await socket.close();
  }

  Future<void> printEscPos({
    required PrinterConfig printer,
    required List<int> data,
    Duration timeout = const Duration(seconds: 5),
  }) async {
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
          throw Exception(
            'Las impresoras USB no se usan desde la Web. Usa la app local de Windows o una impresora de red.',
          );
        }
        await printRawDirectUsb(printer: printer, data: data, timeout: timeout);
        return;
      case PrinterType.bluetooth:
        throw Exception(
          'La impresión Bluetooth directa no está soportada en este flujo.',
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
}

class _CachedLookup<T> {
  const _CachedLookup(this.value, this.cachedAt);

  final T value;
  final DateTime cachedAt;
}
