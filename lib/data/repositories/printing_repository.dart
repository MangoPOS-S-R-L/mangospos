import 'dart:convert';
import 'package:http/http.dart' as http;
import 'package:supabase_flutter/supabase_flutter.dart';
import 'dart:io';
import 'dart:async';
import 'dart:math';
import 'package:flutter/foundation.dart' show debugPrint, kIsWeb;

import 'package:mangopos/core/printing/bluetooth_print_service.dart';
import 'package:mangopos/core/printing/device_identity.dart';
import 'package:mangopos/core/services/local_print_service.dart';
import 'package:mangopos/core/storage/storage_service.dart';

import '../models/printing_models.dart';

/// Resultado del intento de impresión. Permite a la UI mostrar mensajes
/// distintos según el camino que tomó el job:
///   - `directSuccess`: imprimió por TCP/USB/agent local. El ticket
///     físicamente salió (o está saliendo) en segundos.
///   - `escalatedToCloud`: los caminos directos fallaron pero el job
///     entró a la cola en Supabase. El worker del agent lo procesará
///     con retry/failover. El cajero NO tiene que preocuparse — solo
///     informarle que la impresión está en cola.
///
/// Caso "todo fallido" (cloud queue también rechaza) no es un valor del
/// enum: `printEscPos` lanza excepción en ese escenario y la UI muestra
/// el diálogo de reintentar.
enum PrintOutcome {
  directSuccess,
  escalatedToCloud,
}

/// Los bytes ya se enviaron a la impresora (flush OK) y muy probablemente
/// imprimió, pero la impresora cerró la conexión después (RST/EPIPE post-flush
/// — comportamiento normal en muchas térmicas). NO se debe reintentar ni
/// escalar este caso: hacerlo re-imprime la MISMA comanda (doble print). El
/// reintento solo es seguro cuando los bytes NO llegaron a enviarse.
class PrintLikelyDeliveredException implements Exception {
  final Object cause;
  PrintLikelyDeliveredException(this.cause);
  @override
  String toString() => 'PrintLikelyDeliveredException(post-flush): $cause';
}

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
      // Printing v2: derivar `transport` desde `type` legacy.
      // BD también tiene trigger fn_printer_autofill_transport (migración
      // 20260521_0009) como defensa, pero lo mandamos explícito desde acá
      // para que la query sea autodescriptiva.
      final transport = _transportFromLegacyType(type);

      final data = await _client
          .from('printers')
          .insert({
            'business_id': businessId,
            'name': name,
            'type': type,
            'transport': transport,
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

  /// Mapeo del enum legacy `type` → text `transport` de v2.
  /// Coincide con el trigger BD `fn_printer_autofill_transport`.
  static String _transportFromLegacyType(String legacyType) {
    switch (legacyType.toLowerCase()) {
      case 'bluetooth':
        return 'bluetooth';
      case 'usb':
        return 'usb';
      case 'network':
      default:
        return 'lan';
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
    String? fallbackPrinterId,
    bool clearFallback = false,
  }) async {
    try {
      final updates = <String, dynamic>{};
      if (name != null) updates['name'] = name;
      if (ipAddress != null) updates['ip_address'] = ipAddress;
      if (port != null) updates['port'] = port;
      if (type != null) {
        updates['type'] = type;
        // Printing v2: cuando se cambia el type legacy, mantener transport
        // sincronizado para que las queries v2 sigan correctas.
        updates['transport'] = _transportFromLegacyType(type);
      }
      if (devicePath != null) updates['device_path'] = devicePath;
      if (mac != null) updates['mac'] = mac;
      // BUG fix: `is_active` es el flag administrativo (habilitada/
      // deshabilitada lógicamente). `online` es el heartbeat en tiempo
      // real — lo sobreescribe el ping cada 30s. Antes este código
      // actualizaba `online` y el heartbeat borraba el cambio. Ahora
      // persiste correctamente en `is_active`.
      if (isActive != null) updates['is_active'] = isActive;
      if (paperWidth != null) updates['paper_width'] = paperWidth;
      if (encoding != null) updates['encoding'] = encoding;
      // Sprint 3 — `clearFallback` distingue "quitar respaldo" (NULL)
      // de "no tocar el campo" (default). Si ambos vienen, gana clearFallback.
      if (clearFallback) {
        updates['fallback_printer_id'] = null;
      } else if (fallbackPrinterId != null) {
        updates['fallback_printer_id'] = fallbackPrinterId;
      }

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

  /// Printing v2 (Slice 1.5): devuelve TODAS las impresoras asignadas por área
  /// para un tipo de comprobante, no solo la primera.
  ///
  /// Retorna `Map<area_id, List<printer_id>>` con el orden por priority asc.
  /// Permite la UX de N impresoras por tipo (precheck / receipt / orders).
  Future<Map<String, List<String>>> getAllPrinterIdsByType({
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

      final result = <String, List<String>>{};
      for (final row in data) {
        final areaId = row['area_id']?.toString();
        final printerId = row['printer_id']?.toString();
        if (areaId == null ||
            areaId.isEmpty ||
            printerId == null ||
            printerId.isEmpty) {
          continue;
        }
        final list = result.putIfAbsent(areaId, () => <String>[]);
        if (!list.contains(printerId)) {
          list.add(printerId);
        }
      }
      return result;
    } catch (e) {
      throw Exception('Error al obtener impresoras de área por tipo: $e');
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
          // Persistir en disco para que precuenta/factura funcionen offline
          // tras un restart de la app (Fase 1.5 — fix audit §H4).
          await _persistAssignedPrinter(cacheKey, resolved);
          return resolved;
        }
      }

      _writeCached<PrinterConfig?>(_assignedPrinterCache, cacheKey, null);
      return null;
    } catch (e) {
      // Offline fallback: si la query a print_area_printers falla por
      // conectividad, intentar restaurar la última impresora conocida
      // desde el cache persistente. Esto permite imprimir precuenta y
      // factura no-fiscal sin internet, asumiendo que la app se abrió
      // online al menos una vez con esa misma configuración de impresora.
      final persisted = await _readPersistedAssignedPrinter(cacheKey);
      if (persisted != null) {
        debugPrint(
          '⚠️ Usando cache local de impresora asignada ($cacheKey): $e',
        );
        _writeCached(_assignedPrinterCache, cacheKey, persisted);
        return persisted;
      }
      throw Exception('Error al obtener la impresora asignada: $e');
    }
  }

  String _assignedPrinterPersistKey(String cacheKey) =>
      'printing_assigned_printer_$cacheKey';

  Future<void> _persistAssignedPrinter(
    String cacheKey,
    PrinterConfig printer,
  ) async {
    try {
      final storage = await StorageService.getInstance();
      await storage.write(
        _assignedPrinterPersistKey(cacheKey),
        jsonEncode(printer.toMap()),
      );
    } catch (e) {
      debugPrint('printing: error persistiendo impresora asignada: $e');
    }
  }

  Future<PrinterConfig?> _readPersistedAssignedPrinter(String cacheKey) async {
    try {
      final storage = await StorageService.getInstance();
      final raw = await storage.read(_assignedPrinterPersistKey(cacheKey));
      if (raw == null || raw.isEmpty) return null;
      final decoded = jsonDecode(raw);
      if (decoded is Map) {
        return PrinterConfig.fromMap(Map<String, dynamic>.from(decoded));
      }
    } catch (e) {
      debugPrint('printing: error leyendo impresora persistida: $e');
    }
    return null;
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

  /// Sprint 1.3: API limpia para encolar un print job al cloud (Supabase).
  ///
  /// Se usa en el patrón híbrido: cliente Dart intenta imprimir directo
  /// primero (TCP/USB/BT con latencia baja). Si falla, encola aquí. El
  /// agent (Sprint 1.2) toma el job vía `fn_claim_next_print_job` y lo
  /// imprime con retry/backoff exponencial.
  ///
  /// Resiliencia: si Supabase no responde, esta función THROW; el caller
  /// debería tener fallback adicional (ej. HTTP POST al agent legacy).
  ///
  /// Idempotencia: si pasás `idempotencyKey` y ya existe un job activo
  /// con esa key + business, el INSERT falla por unique constraint. El
  /// caller debería atrapar la excepción y considerarlo "ya encolado" =
  /// éxito. Esto evita doble impresión ante retry del cliente.
  ///
  /// Devuelve el row insertado (o el existente si idempotency duplicó).
  Future<PrintJob> enqueuePrintJobToCloud({
    required String businessId,
    required String dataHex,
    required String kind,
    required String areaCode,
    String? printerId,
    String? ip,
    int? port,
    String? idempotencyKey,
    int priority = 100,
  }) async {
    try {
      final insertPayload = <String, dynamic>{
        'business_id': businessId,
        'data_hex': dataHex,
        'kind': kind,
        'area_code': areaCode,
        'printer_id': printerId,
        'ip': ip ?? '0.0.0.0',
        'port': port ?? 9100,
        'priority': priority,
        'status': 'pending',
        if (idempotencyKey != null) 'idempotency_key': idempotencyKey,
      };

      try {
        final jobData = await _client
            .from('print_jobs')
            .insert(insertPayload)
            .select()
            .single();
        return PrintJob.fromMap(jobData);
      } on PostgrestException catch (e) {
        // 23505 = unique_violation. Si el INSERT chocó contra el unique
        // partial index idx_print_jobs_idempotency, significa que ya
        // existe un job activo con la misma idempotency_key. Lo
        // recuperamos y devolvemos como si lo hubiéramos creado — el
        // caller no debe duplicar el ticket.
        if (e.code == '23505' && idempotencyKey != null) {
          final existing = await _client
              .from('print_jobs')
              .select()
              .eq('business_id', businessId)
              .eq('idempotency_key', idempotencyKey)
              .neq('status', 'cancelled')
              .order('created_at', ascending: false)
              .limit(1)
              .maybeSingle();
          if (existing != null) {
            return PrintJob.fromMap(existing);
          }
        }
        rethrow;
      }
    } catch (e) {
      throw Exception('Error al encolar trabajo en cloud queue: $e');
    }
  }

  /// Sprint 1.3: marca un print_job como impreso exitosamente desde el
  /// cliente. Útil cuando el cliente Dart imprimió directo (sin pasar
  /// por el agent) y solo quiere registrar el éxito en la cola para
  /// auditoría / dashboard.
  ///
  /// Backend equivalente: `fn_complete_print_job(job_id, true, null)`.
  /// Aquí hacemos UPDATE directo porque es desde cliente con RLS y
  /// queremos evitar permisos extra.
  Future<void> markPrintJobPrinted(String jobId) async {
    try {
      await _client
          .from('print_jobs')
          .update({
            'status': 'printed',
            'printed_at': DateTime.now().toIso8601String(),
            'claimed_by': null,
            'claimed_at': null,
            'last_error': null,
          })
          .eq('id', jobId);
    } catch (e) {
      // Fail-soft: si no podemos marcar printed, el dashboard quedará
      // con un 'pending' fantasma, pero el ticket SÍ se imprimió. No
      // bloqueamos al cajero por una telemetría que falla.
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

  /// Reintentar trabajo fallido. Sprint 5: además de resetear status,
  /// limpia retry_count y next_retry_at para que el worker lo tome ya
  /// en el próximo tick (sin esperar el backoff acumulado).
  Future<void> retryJob(String jobId) async {
    try {
      await _client
          .from('print_jobs')
          .update({
            'status': 'pending',
            'error': null,
            'last_error': null,
            'retry_count': 0,
            'next_retry_at': null,
            'claimed_by': null,
            'claimed_at': null,
          })
          .eq('id', jobId);
    } catch (e) {
      throw Exception('Error al reintentar trabajo: $e');
    }
  }

  /// Sprint 5 — Cancela un job. Útil cuando el cajero decide no insistir
  /// en una impresora rota (paper out, sin tinta, etc.) y prefiere
  /// reimprimir manualmente desde el historial.
  Future<void> cancelJob(String jobId) async {
    try {
      await _client
          .from('print_jobs')
          .update({
            'status': 'cancelled',
            'claimed_by': null,
            'claimed_at': null,
            'next_retry_at': null,
          })
          .eq('id', jobId);
    } catch (e) {
      throw Exception('Error al cancelar trabajo: $e');
    }
  }

  /// Sprint 5 — Trae las impresoras del negocio con métricas de los
  /// jobs en la última hora. Sirve para el dashboard de salud. Devuelve
  /// una lista de Maps con: id, name, type, online, last_seen,
  /// host_device_id, fallback_printer_id, pending_count, failed_count.
  ///
  /// Hace 2 queries en paralelo (printers + print_jobs agregados) y
  /// hace el join client-side, porque PostgREST no soporta GROUP BY en
  /// la API.
  Future<List<Map<String, dynamic>>> getPrintersHealth(
    String businessId,
  ) async {
    try {
      final printersFuture = _client
          .from('printers')
          .select(
            'id, name, type, online, last_seen, host_device_id, '
            'fallback_printer_id, paper_width',
          )
          .eq('business_id', businessId)
          .order('name', ascending: true);

      final since = DateTime.now()
          .toUtc()
          .subtract(const Duration(hours: 1))
          .toIso8601String();
      final jobsFuture = _client
          .from('print_jobs')
          .select('printer_id, status, retry_count')
          .eq('business_id', businessId)
          .gte('created_at', since)
          .inFilter('status', ['pending', 'failed', 'printing']);

      final responses = await Future.wait([printersFuture, jobsFuture]);
      final printers = List<Map<String, dynamic>>.from(responses[0] as List);
      final jobs = List<Map<String, dynamic>>.from(responses[1] as List);

      // Contar por printer_id.
      final pendingByPrinter = <String, int>{};
      final failedByPrinter = <String, int>{};
      final printingByPrinter = <String, int>{};
      for (final job in jobs) {
        final pid = job['printer_id']?.toString();
        if (pid == null || pid.isEmpty) continue;
        final status = job['status']?.toString() ?? '';
        final retryCount = (job['retry_count'] as num?)?.toInt() ?? 0;
        if (status == 'pending') {
          pendingByPrinter[pid] = (pendingByPrinter[pid] ?? 0) + 1;
        } else if (status == 'failed' && retryCount >= 5) {
          // status='failed' con retry_count < 5 es transitorio (en
          // backoff). Solo contamos como failed terminal los que
          // agotaron retries.
          failedByPrinter[pid] = (failedByPrinter[pid] ?? 0) + 1;
        } else if (status == 'failed') {
          // Failed transitorio = pendiente de retry. Lo mostramos como
          // pending para no alarmar.
          pendingByPrinter[pid] = (pendingByPrinter[pid] ?? 0) + 1;
        } else if (status == 'printing') {
          printingByPrinter[pid] = (printingByPrinter[pid] ?? 0) + 1;
        }
      }

      return printers.map((p) {
        final id = p['id']?.toString() ?? '';
        return {
          ...p,
          'pending_count': pendingByPrinter[id] ?? 0,
          'failed_count': failedByPrinter[id] ?? 0,
          'printing_count': printingByPrinter[id] ?? 0,
        };
      }).toList(growable: false);
    } catch (e) {
      throw Exception('Error al obtener salud de impresoras: $e');
    }
  }

  /// Sprint 5 — Lista los jobs recientes (no terminados) del negocio.
  /// Incluye pending, failed (con o sin retry pendiente), printing.
  /// Lo usa el dashboard para mostrar la cola viva.
  Future<List<Map<String, dynamic>>> getActivePrintJobs(
    String businessId, {
    int limit = 100,
  }) async {
    try {
      final data = await _client
          .from('print_jobs')
          .select(
            'id, business_id, printer_id, area_code, kind, status, '
            'retry_count, last_error, error, next_retry_at, created_at, '
            'claimed_at, original_printer_id, failover_count, '
            'printers!print_jobs_printer_id_fkey(name, type)',
          )
          .eq('business_id', businessId)
          .inFilter('status', ['pending', 'failed', 'printing'])
          .order('created_at', ascending: false)
          .limit(limit);

      return List<Map<String, dynamic>>.from(data as List);
    } catch (e) {
      throw Exception('Error al obtener jobs activos: $e');
    }
  }

  /// Printing v2 — Slice C.3: lista los jobs ya IMPRESOS recientemente.
  /// Útil para el flujo "el cajero dice 'no salió el ticket' y quiere
  /// reimprimir desde historial".
  Future<List<Map<String, dynamic>>> getRecentPrintedJobs(
    String businessId, {
    int limit = 30,
    Duration window = const Duration(hours: 24),
  }) async {
    try {
      final since = DateTime.now().toUtc().subtract(window);
      final data = await _client
          .from('print_jobs')
          .select(
            'id, business_id, printer_id, area_code, kind, status, '
            'retry_count, last_error, error, next_retry_at, created_at, '
            'claimed_at, original_printer_id, failover_count, printed_at, '
            'printers!print_jobs_printer_id_fkey(name, type)',
          )
          .eq('business_id', businessId)
          .eq('status', 'printed')
          .gte('printed_at', since.toIso8601String())
          .order('printed_at', ascending: false)
          .limit(limit);

      return List<Map<String, dynamic>>.from(data as List);
    } catch (e) {
      throw Exception('Error al obtener jobs impresos: $e');
    }
  }

  /// Printing v2 — Slice C.3: clona un job existente y lo encola como
  /// nuevo (pending). El job original se mantiene intacto. Útil para
  /// reimprimir cuando el papel se atoró o el cliente pidió una copia.
  ///
  /// IMPORTANTE: copia data_hex/payload exactamente (es la representación
  /// ESC/POS del ticket original). El nuevo job toma su propio id +
  /// idempotency_key para no chocar con el unique parcial.
  Future<String> reprintJob(String sourceJobId) async {
    try {
      final source = await _client
          .from('print_jobs')
          .select('business_id, printer_id, data_hex, ip, port, area_code, kind')
          .eq('id', sourceJobId)
          .single();

      final inserted = await _client.from('print_jobs').insert({
        'business_id': source['business_id'],
        'printer_id': source['printer_id'],
        'data_hex': source['data_hex'],
        'ip': source['ip'],
        'port': source['port'],
        'area_code': source['area_code'],
        'kind': source['kind'],
        'status': 'pending',
        'retry_count': 0,
        // idempotency_key vacío → no choca con unique parcial.
      }).select('id').single();

      _clearLookupCaches();
      return inserted['id']?.toString() ?? '';
    } catch (e) {
      throw Exception('Error al reimprimir job: $e');
    }
  }

  /// Sprint 5 — Suscripción realtime al stream de print_jobs del
  /// negocio. La pantalla de salud se refresca al recibir cualquier
  /// cambio. Caller debe llamar `.unsubscribe()` al desmontar.
  RealtimeChannel subscribePrintJobsHealth(
    String businessId,
    void Function() onChange,
  ) {
    final ch = _client.channel('print_jobs_health:$businessId')
      ..onPostgresChanges(
        event: PostgresChangeEvent.all,
        schema: 'public',
        table: 'print_jobs',
        filter: PostgresChangeFilter(
          type: PostgresChangeFilterType.eq,
          column: 'business_id',
          value: businessId,
        ),
        callback: (_) => onChange(),
      )
      ..onPostgresChanges(
        event: PostgresChangeEvent.all,
        schema: 'public',
        table: 'printers',
        filter: PostgresChangeFilter(
          type: PostgresChangeFilterType.eq,
          column: 'business_id',
          value: businessId,
        ),
        callback: (_) => onChange(),
      )
      ..subscribe();
    return ch;
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

  // ── Serialización por impresora dentro de ESTE device ────────────────────
  // Una térmica de red atiende UNA conexión TCP al puerto 9100 a la vez. Si la
  // misma tablet abre dos sockets concurrentes a la misma impresora (ej.
  // comanda + precuenta disparando juntas, o re-disparos rápidos), el segundo
  // recibe refused/timeout o, peor, se mezcla el ticket. Encadenamos los prints
  // por `ip:port` para que esperen en fila en vez de chocar. NOTA: esto
  // serializa solo DENTRO de esta tablet; entre las 4 tablets no hay lock
  // compartido (eso requeriría un host/cola) — para eso está el jitter del
  // backoff, que desincroniza los reintentos de tablets distintas.
  // ESTÁTICO a propósito: el lock representa el socket físico device→impresora,
  // que es global al dispositivo. Si fuera por-instancia, la ruta de cocina
  // (su propia instancia de PrintingRepository) y el drenador de cola (otra
  // instancia) NO se serializarían entre sí y podrían chocar contra la misma
  // térmica en la misma tablet. Compartir el mapa por clase lo evita.
  static final Map<String, Future<void>> _printerChainByKey = {};
  static final Random _backoffRng = Random();

  static Future<void> _serializedByPrinter(
    String key,
    Future<void> Function() action,
  ) {
    final prior = _printerChainByKey[key] ?? Future<void>.value();
    final run = prior.then((_) => action(), onError: (_) => action());
    // El tail ignora resultado/errores para no romper la cadena.
    _printerChainByKey[key] = run.then((_) {}, onError: (_) {});
    return run;
  }

  /// Backoff con jitter: [baseMs] más un componente aleatorio, en el rango
  /// aprox. [0.5×, 1.5×] de la base. El jitter evita que varias tablets que
  /// chocan contra la misma impresora reintenten en lockstep y vuelvan a
  /// chocar exactamente en el mismo instante.
  static Duration _jitteredBackoff(int baseMs) {
    final half = baseMs ~/ 2;
    return Duration(milliseconds: half + _backoffRng.nextInt(baseMs + 1));
  }

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

  /// Verifica que una impresora de red responda en `ip:port` sin emitir datos.
  ///
  /// Uso típico: feedback "Probar conexión" en el formulario de alta antes de
  /// persistir. Abre socket, lo cierra inmediato. No escribe payload — la
  /// térmica no imprime nada de prueba; solo se valida alcanzabilidad TCP.
  ///
  /// Devuelve `true` si conecta dentro de [timeout]; `false` ante cualquier
  /// fallo (timeout, ECONNREFUSED, EHOSTUNREACH, etc.). No lanza.
  Future<bool> pingNetworkPrinter({
    required String ip,
    int port = 9100,
    Duration timeout = const Duration(seconds: 3),
  }) async {
    if (kIsWeb) return false; // dart:io.Socket no disponible en Web
    Socket? socket;
    try {
      socket = await Socket.connect(ip, port, timeout: timeout);
      return true;
    } catch (_) {
      return false;
    } finally {
      try {
        socket?.destroy();
      } catch (_) {}
    }
  }

  /// Enviar datos ESC/POS directos por TCP (solo plataformas nativas).
  ///
  /// Hardening contra "se desconectó a mitad de impresión":
  /// - Retry interno (`attempts`): el primer intento captura blips de
  ///   red (WiFi, switch flap, NIC powersave wake) sin que el cajero
  ///   tenga que reintentar a mano.
  /// - `tcpNoDelay`: pequeñas ráfagas ESC/POS salen sin Nagle. Sin
  ///   esto la térmica puede recibir el corte (GS V) ~40-200ms tarde
  ///   y el spool driver del POS asume desconexión.
  /// - Listener de errores sobre el stream: RST/EPIPE asíncronos
  ///   (post-flush) llegan al stream, no a `flush()`. Sin este listen
  ///   los errores se pierden y `close()/done` se cuelga indefinido.
  /// - Drain delay antes de `close()`: damos tiempo a la impresora a
  ///   consumir el TX buffer antes del FIN, evitando que trunque el
  ///   último corte/feed.
  /// - Timeout en `close()` y `done`: si el peer no responde el FIN
  ///   (caso común con térmicas chinas) no colgamos la cola del cajero.
  Future<void> printRawDirectTcp({
    required String ip,
    int port = 9100,
    required List<int> data,
    Duration timeout = const Duration(seconds: 5),
    int attempts = 2,
  }) {
    // Serializamos por impresora dentro de este device: dos prints simultáneos
    // de ESTA tablet a la misma térmica esperan en fila en vez de abrir dos
    // sockets que el puerto 9100 no puede atender a la vez.
    return _serializedByPrinter(
      '$ip:$port',
      () => _printRawDirectTcpUnlocked(
        ip: ip,
        port: port,
        data: data,
        timeout: timeout,
        attempts: attempts,
      ),
    );
  }

  Future<void> _printRawDirectTcpUnlocked({
    required String ip,
    int port = 9100,
    required List<int> data,
    Duration timeout = const Duration(seconds: 5),
    int attempts = 2,
  }) async {
    final totalAttempts = attempts < 1 ? 1 : attempts;
    Object? lastError;
    StackTrace? lastStack;
    for (var attempt = 0; attempt < totalAttempts; attempt++) {
      if (attempt > 0) {
        // Backoff creciente con jitter (~300ms × intento ± jitter): separa los
        // reintentos de esta tablet y los desincroniza de los de las otras 3,
        // para que no vuelvan a chocar en el mismo instante contra el puerto
        // 9100 compartido.
        await Future.delayed(_jitteredBackoff(300 * attempt));
      }
      try {
        await _sendRawTcpOnce(
          ip: ip,
          port: port,
          data: data,
          timeout: timeout,
        );
        return;
      } on PrintLikelyDeliveredException {
        // Los bytes se enviaron (RST post-flush). NO reintentar: re-imprimiría
        // la misma comanda. Propagar para que el caller tampoco escale.
        rethrow;
      } catch (e, st) {
        lastError = e;
        lastStack = st;
        debugPrint(
          '[TCP] intento ${attempt + 1}/$totalAttempts a $ip:$port falló: $e',
        );
      }
    }
    Error.throwWithStackTrace(
      lastError ?? Exception('TCP print failed'),
      lastStack ?? StackTrace.current,
    );
  }

  Future<void> _sendRawTcpOnce({
    required String ip,
    required int port,
    required List<int> data,
    required Duration timeout,
  }) async {
    final socket = await Socket.connect(ip, port, timeout: timeout);
    try {
      socket.setOption(SocketOption.tcpNoDelay, true);
    } catch (_) {}

    Object? asyncError;
    StreamSubscription<List<int>>? sub;
    try {
      // Suscripción para capturar errores asíncronos del socket (RST/
      // EPIPE que llegan después del flush). Sin esto, esos errores
      // se pierden silenciosamente y vemos "todo OK" aunque la
      // impresora cortó la conexión a media impresión. Los bytes de
      // status que algunas térmicas emiten los descartamos.
      sub = socket.listen(
        (_) {},
        onError: (Object e, StackTrace st) {
          asyncError ??= e;
        },
        cancelOnError: false,
      );

      socket.add(data);
      await socket.flush();

      // Drain: dejamos que la térmica procese los últimos bytes
      // (incluyendo GS V 'B 0' = corte) antes del FIN. Sin esto
      // algunas impresoras truncan el corte y el cajero ve "como si
      // se desconectara" a mitad de ticket.
      await Future.delayed(const Duration(milliseconds: 80));

      if (asyncError != null) {
        // RST/EPIPE post-flush: los bytes YA se enviaron (flush OK) y la
        // impresora muy probablemente imprimió antes de cerrar la conexión
        // (normal en térmicas). Lo marcamos como "probablemente entregado"
        // para que el retry de abajo y el fallback al agente NO re-impriman
        // (eso causaba la comanda duplicada). Reintentar solo es seguro
        // cuando los bytes NO llegaron a enviarse (fallo de connect/flush).
        throw PrintLikelyDeliveredException(asyncError!);
      }
    } finally {
      try {
        await sub?.cancel();
      } catch (_) {}
      try {
        await socket.close().timeout(const Duration(seconds: 2));
      } catch (_) {
        try {
          socket.destroy();
        } catch (_) {}
      }
      try {
        await socket.done.timeout(const Duration(seconds: 2));
      } catch (_) {
        try {
          socket.destroy();
        } catch (_) {}
      }
    }
  }

  Future<PrintOutcome> printEscPos({
    required PrinterConfig printer,
    required List<int> data,
    Duration timeout = const Duration(seconds: 5),
    // Sprint 1.3.b: si el caller pasa `idempotencyKey`, habilita el
    // fallback al cloud queue cuando TODOS los intentos directos fallan
    // (TCP, agent HTTP, USB con retry, BT). El agent del Sprint 1.2
    // retomará el job vía `fn_claim_next_print_job` con backoff
    // exponencial. Sin idempotencyKey, comportamiento legacy: el error
    // se propaga al caller.
    String? idempotencyKey,
    String kind = 'other',
    String? areaCode,
  }) async {
    // PRD 5 F2.5: routing por host_device_id.
    // Si la impresora está vinculada a un device físico (USB/BT) que NO es
    // este device, mandamos el job al agent remoto del host vía LAN.
    final hostId = printer.hostDeviceId?.trim();
    if (hostId != null && hostId.isNotEmpty) {
      final selfId =
          await DeviceIdentity.getOrCreateId(printer.businessId);
      if (hostId != selfId) {
        try {
          // No propagamos `timeout` (5s default) — el remoto necesita más
          // tiempo para abrir USB e imprimir físicamente. Usar el default
          // generoso de _printViaRemoteHost.
          await _printViaRemoteHost(
            printer: printer,
            data: data,
            hostDeviceId: hostId,
          );
          return PrintOutcome.directSuccess;
        } catch (e) {
          // Fallback inteligente: si el host_device_id apunta a un agent
          // que ya NO existe (registro huerfano por reinstall del app,
          // device viejo borrado, etc), no tiene sentido escalar al cloud
          // — la imp puede estar fisicamente conectada a ESTE device.
          // Intentamos el path local antes de la cloud queue para que el
          // ticket salga ya en vez de quedar pendiente. Mismo razonamiento
          // si el host remoto esta offline (last_heartbeat > 90s): igual
          // probamos local — si tampoco funciona, ahi si escalamos.
          //
          // Caso de uso real: cajero unico que reinstalo el app, el viejo
          // device_id quedo en printer.host_device_id apuntando a una fila
          // de device_agents que ya no existe. El test de pagina (que no
          // mira host_device_id) imprime bien; precuenta/factura/comanda
          // no. Con este fallback ambos paths quedan equivalentes en
          // robustez.
          final shouldTryLocal = _isOrphanHostError(e);
          if (shouldTryLocal) {
            try {
              await _printEscPosLocal(
                printer: printer,
                data: data,
                timeout: timeout,
              );
              return PrintOutcome.directSuccess;
            } catch (_) {
              // Local tampoco anduvo: caer al cloud queue normal.
            }
          }

          if (idempotencyKey == null) rethrow;
          await _escalateToCloudQueue(
            printer: printer,
            data: data,
            idempotencyKey: idempotencyKey,
            kind: kind,
            areaCode: areaCode,
            originalError: e,
          );
          return PrintOutcome.escalatedToCloud;
        }
      }
    }

    try {
      await _printEscPosLocal(printer: printer, data: data, timeout: timeout);
      return PrintOutcome.directSuccess;
    } catch (e) {
      // FALLBACK FINAL: todos los caminos directos (TCP/agent/USB/BT)
      // fallaron. Si tenemos contexto (idempotencyKey + businessId),
      // escalamos al cloud queue. El agent procesará con retry exp.
      if (idempotencyKey == null) rethrow;
      await _escalateToCloudQueue(
        printer: printer,
        data: data,
        idempotencyKey: idempotencyKey,
        kind: kind,
        areaCode: areaCode,
        originalError: e,
      );
      return PrintOutcome.escalatedToCloud;
    }
  }

  /// Detecta los errores de [_printViaRemoteHost] donde la mejor estrategia
  /// es intentar imprimir local en vez de escalar al cloud queue:
  ///   - host_device_id apunta a un device_agent que ya no existe en BD
  ///   - host_device_id existe pero el agent esta offline (heartbeat viejo)
  ///   - agent_url esta vacio
  ///
  /// En cualquiera de estos casos, la imp puede estar fisicamente conectada
  /// a este device — probar local antes de dar por perdido el ticket.
  bool _isOrphanHostError(Object e) {
    final msg = e.toString().toLowerCase();
    return msg.contains('no esta registrado') ||
        msg.contains('no está registrado') ||
        msg.contains('fuera de l') || // 'fuera de línea' / 'fuera de linea'
        msg.contains('agent_url') ||
        msg.contains('agent no disponible');
  }

  /// Body original de printEscPos extraído para envolverlo con cloud
  /// fallback sin duplicar código. Hace los 3 intentos directos según
  /// tipo de impresora (network TCP, USB con retry, BT directo).
  Future<void> _printEscPosLocal({
    required PrinterConfig printer,
    required List<int> data,
    required Duration timeout,
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
          // Retry silencioso con backoff exponencial antes de escalar a
          // recovery por MAC. Cubre fallos transitorios típicos: blip de
          // WiFi, impresora despertándose, ARP stale, contención de red
          // cuando varios cobros caen al mismo tiempo. Si tras 3 intentos
          // sigue fallando, asumimos que el problema NO es transitorio
          // (impresora cambió de IP, está apagada, etc.) y caemos al
          // path de recovery / agent fallback / cloud queue.
          await _printTcpWithRetries(
            ip: ip,
            port: printer.port ?? 9100,
            data: data,
            timeout: timeout,
          );
          // Print directo OK. Si no tenemos MAC para esta impresora, intentar
          // capturarlo en background — sirve para auto-recovery futuro si la
          // IP cambia por DHCP.
          _captureMacIfMissing(printer);
        } on PrintLikelyDeliveredException catch (e) {
          // Bytes enviados (RST post-flush): el ticket muy probablemente ya
          // imprimió. NO hacer recovery por MAC ni fallback al agente — eso
          // re-imprimiría el MISMO ticket (doble impresión). Tratamos como OK.
          debugPrint(
            'ℹ️ ${printer.name}: conexión cerrada tras enviar (post-flush); '
            'ticket probablemente impreso, no se reintenta: $e',
          );
          _captureMacIfMissing(printer);
        } catch (originalError) {
          // Recovery por MAC ANTES del fallback al agente: si la impresora
          // tiene MAC guardado y el agente está vivo, le pedimos que escanee
          // la LAN. Si encuentra la impresora en otra IP, actualizamos
          // Supabase y reintentamos el print directo una vez.
          final recoveredIp = await _tryRecoverPrinterIpByMac(printer, ip);
          if (recoveredIp != null) {
            try {
              await printRawDirectTcp(
                ip: recoveredIp,
                port: printer.port ?? 9100,
                data: data,
                timeout: timeout,
              );
              return;
            } catch (_) {
              // El IP nuevo tampoco respondió — caemos al fallback de agente.
            }
          }
          if (await isAgentUp()) {
            await printRawViaAgent(
              ip: recoveredIp ?? ip,
              port: printer.port ?? 9100,
              data: data,
            );
            return;
          }
          Error.throwWithStackTrace(originalError, StackTrace.current);
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

        // ─── PRE-FLIGHT ─────────────────────────────────────────────
        // Si el último heartbeat reportó offline y la última señal es
        // claramente vieja (>60s = más allá del threshold del SQL),
        // fail rápido en vez de timeout-ear 10s contra un puerto muerto.
        // Si no tenemos lastSeen confiable (printer recién agregada)
        // permitimos el intento — el retry abajo se encarga.
        if (printer.online == false) {
          final ls = printer.lastSeen;
          final age = ls == null
              ? null
              : DateTime.now().toUtc().difference(ls.toUtc());
          if (age != null && age > const Duration(seconds: 60)) {
            throw Exception(
              'La impresora "${printer.name}" está fuera de línea según '
              'el último heartbeat (hace ${age.inSeconds}s). Verifica el '
              'cable USB o que el agente local esté corriendo.',
            );
          }
        }

        // ─── DIRECT USB CON RETRY ───────────────────────────────────
        // USB se desconecta brevemente bajo carga / sleep / cable
        // suelto. 3 intentos con backoff (0s, 2s, 5s) recuperan ~70%
        // de los casos sin que el cajero tenga que reintentar manual.
        // No reintentamos en errores de configuración (devicePath
        // vacío) — esos no se arreglan esperando.
        const usbBackoff = <Duration>[
          Duration.zero,
          Duration(seconds: 2),
          Duration(seconds: 5),
        ];
        Object? lastUsbError;
        StackTrace? lastUsbStack;
        for (var attempt = 0; attempt < usbBackoff.length; attempt++) {
          if (usbBackoff[attempt] > Duration.zero) {
            await Future.delayed(usbBackoff[attempt]);
          }
          try {
            await printRawDirectUsb(
              printer: printer,
              data: data,
              timeout: timeout,
              // El loop de arriba ya hace 3 intentos con backoff —
              // adentro pasamos 1 para no multiplicar (sería 9 intentos
              // con winspool, lentísimo).
              attempts: 1,
            );
            return;
          } catch (e, st) {
            lastUsbError = e;
            lastUsbStack = st;
            // Errores de configuración: no reintentar.
            final msg = e.toString();
            if (msg.contains('no tiene una ruta local') ||
                msg.contains('no tiene un puerto local')) {
              break;
            }
            debugPrint(
              '[USB] intento ${attempt + 1}/${usbBackoff.length} falló para '
              '${printer.name}: $e',
            );
          }
        }

        // ─── FALLBACK: AGENTE LOCAL ─────────────────────────────────
        if (await isAgentUp()) {
          try {
            await printRawViaAgentToPrinter(printer: printer, data: data);
            return;
          } catch (e) {
            debugPrint(
              '[USB] fallback al agente también falló para '
              '${printer.name}: $e',
            );
          }
        }

        // Nada funcionó → propagar el último error del retry directo
        // (suele ser el más informativo: "device or resource busy", etc).
        if (lastUsbError != null) {
          Error.throwWithStackTrace(
            lastUsbError,
            lastUsbStack ?? StackTrace.current,
          );
        }
        throw Exception(
          'No se pudo imprimir en "${printer.name}" después de varios '
          'intentos. Verifica la conexión USB.',
        );
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

  /// Sprint 1.3.b: si todos los intentos directos fallan, escalamos el
  /// job al cloud queue (Supabase print_jobs). El agent (Sprint 1.2) lo
  /// retomará con backoff exponencial.
  ///
  /// Si el INSERT al cloud queue también falla (sin internet, RLS, etc),
  /// propagamos el error ORIGINAL de los intentos directos — es el más
  /// informativo para mostrar al cajero.
  Future<void> _escalateToCloudQueue({
    required PrinterConfig printer,
    required List<int> data,
    required String idempotencyKey,
    required String kind,
    String? areaCode,
    required Object originalError,
  }) async {
    final businessId = printer.businessId.trim();
    if (businessId.isEmpty) {
      Error.throwWithStackTrace(originalError, StackTrace.current);
    }
    try {
      await enqueuePrintJobToCloud(
        businessId: businessId,
        dataHex: data
            .map((b) => b.toRadixString(16).padLeft(2, '0'))
            .join(),
        kind: kind,
        areaCode: areaCode ?? 'cashier',
        printerId: printer.id,
        ip: printer.ipAddress,
        port: printer.port,
        idempotencyKey: idempotencyKey,
      );
      debugPrint(
        '🆘 Cloud queue fallback OK para ${printer.name} '
        '(kind=$kind, area=${areaCode ?? '-'}): agent retomará. '
        '(intento directo: $originalError)',
      );
      // No rethrow: el job está encolado, el cajero NO ve error. Si la
      // impresora vuelve, se imprime. Si falla 5 retries, queda en
      // dashboard como failed (Sprint 5).
    } catch (cloudErr) {
      debugPrint(
        '❌ Cloud queue fallback FALLÓ: $cloudErr (intento directo: $originalError)',
      );
      Error.throwWithStackTrace(originalError, StackTrace.current);
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
    // El receipt path (`_printEscPosLocal`) ya envuelve esta llamada en
    // un retry de 3 intentos con backoff, así que ahí pasamos
    // `attempts: 1` para no multiplicar. Otros callers (kitchen, test)
    // usan el default y obtienen 2 intentos transparentes para cubrir
    // bumps transitorios de WMI / spooler.
    int attempts = 2,
  }) async {
    if (Platform.isWindows) {
      await _printRawDirectUsbWindows(
        printerName: printer.name,
        devicePath: printer.devicePath,
        portHint: printer.mac,
        data: data,
        timeout: timeout,
        attempts: attempts,
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
    // El filtro original (`PortName -match '^USB'`) descartaba impresoras
    // térmicas chinas (POS80, ZJiang, Goojprt, 2connect, etc.) cuyo driver
    // crea puertos custom tipo CP001, POS001, GP001 en vez del USB001
    // estándar. Físicamente son USB, pero Windows muestra otro PortName.
    //
    // Solución: aceptar todas las impresoras locales (Local=true) EXCEPTO
    // las que tienen puertos/drivers que sabemos que NO son USB:
    //   - PORTPROMPT, FILE, XPSPort:   PDF / XPS / Print to File
    //   - SHRFAX, FaxPort:             Fax modems
    //   - nul:                         OneNote / send-to-OneNote
    //   - IP_, WSD-, http:, lpr:       impresoras de red
    //   - drivers Microsoft genéricos: XPS, PDF, OneNote, Fax
    final script = r'''
$ErrorActionPreference = 'Stop'
$items = @(
  Get-CimInstance Win32_Printer |
    Where-Object {
      $_.Local -eq $true -and
      $_.PortName -notmatch '^(PORTPROMPT|FILE|XPSPort|SHRFAX|FaxPort|nul|IP_|WSD-|http|lpr)' -and
      $_.DriverName -notmatch '(XPS|PDF|OneNote|Fax|Send To OneNote|Microsoft Print)'
    } |
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
''';

    // WMI/CIM en frio (primer query del proceso) puede tardar varios
    // segundos en hardware viejo; 6s quedaba muy justo y un timeout dejaba
    // la lista USB vacia ("no sale la impresora"). Subimos a 12s + 1
    // reintento para que un hipo puntual de WMI no borre la impresora.
    ProcessResult? result;
    for (var attempt = 0; attempt < 2; attempt++) {
      try {
        result = await _runPowerShell(
          script,
          timeout: const Duration(seconds: 12),
        );
        break;
      } catch (_) {
        if (attempt == 1) rethrow;
      }
    }
    if (result == null) return const [];

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
    int attempts = 1,
  }) async {
    final totalAttempts = attempts < 1 ? 1 : attempts;
    Object? lastError;
    StackTrace? lastStack;
    for (var attempt = 0; attempt < totalAttempts; attempt++) {
      if (attempt > 0) {
        // Backoff corto: spooler / WMI suelen recuperarse en ~500ms.
        await Future.delayed(const Duration(milliseconds: 500));
      }
      try {
        await _printRawDirectUsbWindowsOnce(
          printerName: printerName,
          data: data,
          devicePath: devicePath,
          portHint: portHint,
          timeout: timeout,
        );
        return;
      } catch (e, st) {
        // Errores de configuración (printer no encontrado, mala ruta)
        // no se arreglan reintentando — fail rápido.
        final msg = e.toString();
        if (msg.contains('USB_PRINTER_NOT_FOUND') ||
            msg.contains('no tiene una ruta')) {
          rethrow;
        }
        lastError = e;
        lastStack = st;
        debugPrint(
          '[USB-Win] intento ${attempt + 1}/$totalAttempts a "$printerName" falló: $e',
        );
      }
    }
    Error.throwWithStackTrace(
      lastError ?? Exception('USB print failed'),
      lastStack ?? StackTrace.current,
    );
  }

  Future<void> _printRawDirectUsbWindowsOnce({
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
  # Fallback difuso: usa los MISMOS filtros de exclusion que el
  # discovery (_discoverLocalUsbPrintersWindows) en vez de exigir
  # "PortName -match '^USB'". Ese filtro previo descartaba las termicas
  # chinas (2Connect, ZJiang, Goojprt, POS80) cuyo driver crea puertos
  # custom tipo POS001/CP001/GP001 — quedaban listadas pero irrecuperables
  # aqui si el match exacto por nombre fallaba (cola renombrada, etc).
  \$target = Get-CimInstance Win32_Printer |
    Where-Object {
      \$_.Local -eq \$true -and
      \$_.PortName -notmatch '^(PORTPROMPT|FILE|XPSPort|SHRFAX|FaxPort|nul|IP_|WSD-|http|lpr)' -and
      \$_.DriverName -notmatch '(XPS|PDF|OneNote|Fax|Send To OneNote|Microsoft Print)' -and (
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

  // En un .exe empaquetado el PATH del proceso hijo no siempre incluye
  // System32, y `Process.run('powershell')` lanza ProcessException — que
  // el descubrimiento traga como "no hay impresoras USB" (lista vacia) y
  // la impresion reporta como fallo. Resolvemos la ruta ABSOLUTA de
  // powershell.exe via %SystemRoot%/%windir% y caemos al nombre suelto
  // solo si el archivo no existe. Se cachea porque no cambia en runtime.
  static String? _cachedPowerShellExe;
  String _powerShellExecutable() {
    final cached = _cachedPowerShellExe;
    if (cached != null) return cached;
    var exe = 'powershell';
    try {
      final root = Platform.environment['SystemRoot'] ??
          Platform.environment['windir'];
      if (root != null && root.isNotEmpty) {
        final full =
            '$root\\System32\\WindowsPowerShell\\v1.0\\powershell.exe';
        if (File(full).existsSync()) exe = full;
      }
    } catch (_) {/* usa el nombre suelto */}
    _cachedPowerShellExe = exe;
    return exe;
  }

  Future<ProcessResult> _runPowerShell(
    String script, {
    Duration timeout = const Duration(seconds: 10),
  }) async {
    final result = await Process.run(_powerShellExecutable(), [
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
  ///
  /// Printing v2 (Slice 4.A): agrega soporte para `color` (hex #RRGGBB) y
  /// `displayOrder` (int) introducidos en migración 20260521_0002.
  /// Pasar [clearColor]=true setea color a NULL (volver al default UI).
  Future<PrintArea> updateArea({
    required String areaId,
    String? name,
    String? code,
    bool? isActive,
    String? color,
    int? displayOrder,
    bool clearColor = false,
  }) async {
    final patch = <String, dynamic>{};
    if (name != null) patch['name'] = name.trim();
    if (code != null) patch['code'] = code.trim().toLowerCase();
    if (isActive != null) patch['is_active'] = isActive;
    if (clearColor) {
      patch['color'] = null;
    } else if (color != null) {
      patch['color'] = color.trim();
    }
    if (displayOrder != null) patch['display_order'] = displayOrder;

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

  /// Asigna una impresora a un área con flags específicos (orders / prebills /
  /// receipts).
  ///
  /// [exclusive] controla si esta asignación es la ÚNICA para el(los) flag(s)
  /// dados dentro del área:
  ///   - `true`  (legacy, default): apaga el mismo flag en otras impresoras
  ///     del área. Útil cuando solo una impresora puede ser la "primaria"
  ///     de un tipo (ej. impresora de órdenes a cocina caliente).
  ///   - `false` (Printing v2 — Slice 1.5): respeta otras asignaciones, solo
  ///     agrega/actualiza esta. Útil para multi-destino (ej. precuenta
  ///     duplicada en 2 impresoras).
  Future<void> setAreaPrinterAssignment({
    required String businessId,
    required String areaId,
    required String printerId,
    bool printsOrders = false,
    bool printsPrebills = false,
    bool printsReceipts = false,
    int priority = 1,
    bool exclusive = true,
  }) async {
    try {
      if (!printsOrders && !printsPrebills && !printsReceipts) {
        throw Exception('Debes indicar al menos un tipo de impresión.');
      }

      if (exclusive) {
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

  // ===========================================================================
  // Printer auto-recovery por MAC (DHCP rotó la IP de la impresora)
  // ===========================================================================

  /// Si el [printer] tiene MAC guardado, pedirle al agente local que escanee
  /// el LAN y reporte la IP actual. Si la IP cambió, actualizar Supabase y
  /// devolver la nueva IP. Si no encuentra o no aplica, devolver null.
  ///
  /// Diseñado para no throwear: cualquier fallo retorna null y deja al
  /// caller seguir con su fallback (típicamente printRawViaAgent).
  /// Sonda rápida de conectividad TCP a una impresora — connect + close
  /// con timeout corto (default 1.2s). No envía datos, no requiere
  /// permisos del impresora, no afecta su buffer interno. Pensada para:
  ///   - pre-validación al abrir el modal de cobro (evitar cobrar y
  ///     descubrir después que la impresora está caída),
  ///   - heartbeat periódico que actualiza un badge en la UI.
  ///
  /// Devuelve `true` si el TCP handshake completa exitosamente.
  /// Devuelve `false` ante cualquier error (timeout, refused,
  /// unreachable, host not found).
  Future<bool> probePrinter({
    String? ip,
    int port = 9100,
    Duration timeout = const Duration(milliseconds: 1200),
  }) async {
    final trimmedIp = ip?.trim();
    if (trimmedIp == null || trimmedIp.isEmpty) return false;
    if (kIsWeb) {
      // En web no podemos hacer TCP directo — el caller deberá usar el
      // agent. Devolvemos `true` (optimista) para no bloquear el flow;
      // el path real de impresión ya tiene su propio error handling.
      return true;
    }
    try {
      final socket = await Socket.connect(trimmedIp, port, timeout: timeout);
      socket.destroy();
      return true;
    } catch (_) {
      return false;
    }
  }

  /// Reintenta `printRawDirectTcp` hasta 3 veces con backoff exponencial
  /// (1s, 2s) entre intentos. Solo reintenta en errores que parecen
  /// transitorios (timeout, connection refused, network blip). Si el
  /// primer intento tira un error claramente no-transitorio (ej. host
  /// not found, permission denied), rinde de inmediato para no demorar
  /// la escalada al path de recovery.
  ///
  /// Total worst-case latency antes de escalar: ~3-4s (intento1 timeout
  /// + 1s + intento2 timeout + 2s + intento3 timeout). Con timeouts
  /// típicos de 2s eso es ~10s en el peor caso, pero la mayoría de los
  /// "fallos transitorios" reales resuelven en el segundo intento — el
  /// cajero ve <2s extra en lugar de la escalada completa que toma
  /// 5-30s.
  Future<void> _printTcpWithRetries({
    required String ip,
    required int port,
    required List<int> data,
    required Duration timeout,
    int maxAttempts = 3,
  }) async {
    Object? lastError;
    StackTrace? lastStack;
    for (var attempt = 1; attempt <= maxAttempts; attempt++) {
      try {
        await printRawDirectTcp(
          ip: ip,
          port: port,
          data: data,
          timeout: timeout,
        );
        if (attempt > 1) {
          debugPrint(
            '[PrintRetry] $ip:$port OK al intento $attempt/$maxAttempts',
          );
        }
        return;
      } on PrintLikelyDeliveredException {
        // Los bytes se enviaron (RST post-flush). NO reintentar: re-imprimiría
        // el mismo ticket. Propagar para que el caller lo trate como entregado.
        rethrow;
      } catch (e, st) {
        lastError = e;
        lastStack = st;
        final transient = _isTransientPrintError(e);
        if (!transient || attempt == maxAttempts) {
          break;
        }
        // Backoff exponencial CON jitter: base 1s/2s/4s ± jitter, para que
        // varias tablets que chocan contra la misma impresora compartida no
        // reintenten en lockstep y vuelvan a chocar.
        final base = 500 * (1 << attempt); // 1000, 2000, 4000
        final wait = _jitteredBackoff(base);
        debugPrint(
          '[PrintRetry] $ip:$port intento $attempt fallo: $e — '
          'reintentando en ${wait.inMilliseconds}ms',
        );
        await Future.delayed(wait);
      }
    }
    Error.throwWithStackTrace(
      lastError ?? Exception('Print failed'),
      lastStack ?? StackTrace.current,
    );
  }

  /// Heurística: ¿el error parece un blip transitorio que vale la pena
  /// reintentar, o algo que NO va a resolverse con otro intento?
  ///
  /// Transitorios: timeout, connection refused, network unreachable
  /// momentáneo, host is down (a veces la impresora tarda en responder
  /// ARP tras un sleep).
  ///
  /// No transitorios: host not found, permission denied, malformed
  /// payload. Esos van directo al path de recovery.
  bool _isTransientPrintError(Object error) {
    final lower = error.toString().toLowerCase();
    return lower.contains('timeout') ||
        lower.contains('timed out') ||
        lower.contains('etimedout') ||
        lower.contains('connection refused') ||
        lower.contains('econnrefused') ||
        lower.contains('errno = 61') ||
        lower.contains('errno = 111') ||
        lower.contains('network is unreachable') ||
        lower.contains('host is down') ||
        lower.contains('connection reset') ||
        lower.contains('econnreset') ||
        lower.contains('broken pipe') ||
        lower.contains('socketexception');
  }

  Future<String?> _tryRecoverPrinterIpByMac(
    PrinterConfig printer,
    String currentIp,
  ) async {
    // Web no puede llamar el endpoint local del agente sin agente publicado;
    // el caller ya tiene su propio camino (printRawViaAgent) — saltar.
    if (kIsWeb) return null;
    final mac = printer.effectiveMac?.trim();
    if (mac == null || mac.isEmpty) return null;

    try {
      // skipCache: true — venimos de un fallo de TCP a `currentIp`. Si
      // la cache del agente todavía tiene esa misma IP almacenada de
      // un resolve anterior, sin skip nos devolvería de nuevo lo mismo
      // y caeríamos en loop. Forzar re-resolución fresca evita el loop
      // y triggera el scan del /24 para encontrar la IP actual real.
      final newIp = await _localService.resolveIpByMac(
        mac: mac,
        printerId: printer.id,
        skipCache: true,
      );
      if (newIp == null) return null;
      if (newIp == currentIp) return null; // sigue siendo la misma, no actualizar

      debugPrint(
        '[PrinterRecovery] MAC $mac: IP actualizada $currentIp → $newIp',
      );
      // Persistir en Supabase para que próximas impresiones empiecen por la IP correcta.
      await updatePrinter(printerId: printer.id, ipAddress: newIp);
      // Invalidar caches in-memory de lookup de impresoras — si no
      // hacemos esto, la próxima impresión dentro del TTL (5 min) sigue
      // recibiendo la PrinterConfig vieja con la IP antigua y volvería
      // a pasar por todo el flow de recovery innecesariamente.
      _clearLookupCaches();
      return newIp;
    } catch (e) {
      debugPrint('[PrinterRecovery] resolveIpByMac falló para ${printer.id}: $e');
      return null;
    }
  }

  /// Si la impresora aún no tiene MAC guardado, intentar capturarlo desde el
  /// agente local. Llamar tras un print exitoso. Fire-and-forget: no
  /// bloquea al caller ni propaga errores.
  void _captureMacIfMissing(PrinterConfig printer) {
    captureMacForPrinterIfMissing(
      printerId: printer.id,
      ipAddress: printer.ipAddress,
      existingMac: printer.effectiveMac,
    );
  }

  /// Versión pública/parametrizada para callers que tienen los campos sueltos
  /// (ej. tests de Settings que trabajan con un UI model en vez de
  /// [PrinterConfig]). Idéntica semántica: fire-and-forget, no throw.
  void captureMacForPrinterIfMissing({
    required String printerId,
    String? ipAddress,
    String? existingMac,
  }) {
    if (kIsWeb) return;
    final existing = existingMac?.trim();
    if (existing != null && existing.isNotEmpty) return;
    final ip = ipAddress?.trim();
    if (ip == null || ip.isEmpty) return;

    Future.microtask(() async {
      try {
        final mac = await _localService.captureMacForIp(ip);
        if (mac == null) return;
        await updatePrinter(printerId: printerId, mac: mac);
        debugPrint('[PrinterRecovery] MAC capturado para $printerId: $mac');
      } catch (e) {
        debugPrint('[PrinterRecovery] captureMacForIp falló para $printerId: $e');
      }
    });
  }
}

class _CachedLookup<T> {
  const _CachedLookup(this.value, this.cachedAt);

  final T value;
  final DateTime cachedAt;
}
