// lib/data/repositories/printing_service.dart
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import '../models/printing_models.dart';
import '../models/sales_models.dart';
import '../../core/offline/offline_pos_service.dart';
import '../../core/storage/storage_service.dart';
import '../../services/printing/print_ticket_service.dart';
import '../../presentation/sales/state/sales_state.dart';
import 'printing_repository.dart';
import 'sales_repository.dart';

/// 🖨️ Servicio de Impresión con Agrupación por Departamento
/// Maneja la lógica de envío de órdenes a diferentes áreas de impresión
class NoAssignedKitchenPrinterException implements Exception {
  final List<String> areaCodes;

  const NoAssignedKitchenPrinterException(this.areaCodes);

  @override
  String toString() {
    if (areaCodes.isEmpty) {
      return 'NO_ASSIGNED_KITCHEN_PRINTER';
    }
    return 'NO_ASSIGNED_KITCHEN_PRINTER:${areaCodes.join(",")}';
  }
}

class PrintingService {
  final SupabaseClient _client;
  late final PrintingRepository _printingRepo;
  late final SalesRepository _salesRepo;
  final OfflinePosService _offlinePos = OfflinePosService();

  PrintingService(this._client) {
    _printingRepo = PrintingRepository(_client);
    _salesRepo = SalesRepository(_client);
  }

  /// Enviar orden a cocina con agrupación automática por departamento
  Future<Map<String, String>> sendOrderToKitchen({
    required String orderId,
    required String businessId,
  }) async {
    try {
      // 1. Obtener información de la orden
      final order = await _salesRepo.getOrder(orderId);
      if (order == null) {
        throw Exception('Orden no encontrada');
      }

      // 2. Obtener items de la orden
      final items = await _salesRepo.getOrderItems(
        orderId,
        includeModifiers: true,
      );

      final draftItems = items
          .where((item) => item.status == 'draft' || item.status == 'open')
          .toList(growable: false);

      if (draftItems.isEmpty) {
        throw Exception('No hay items nuevos pendientes de enviar a cocina');
      }

      if (items.isEmpty) {
        throw Exception('La orden no tiene items');
      }

      // 3. Obtener información adicional para el ticket
      final orderData = await _getOrderDisplayData(orderId);
      final businessName = await _getBusinessName(businessId);

      // 4. Agrupar items por área de impresión
      final itemsByArea = await _groupItemsByPrintArea(draftItems);

      // 5. Resolver áreas e impresoras antes de marcar la orden.
      final printersByAreaCode = <String, List<PrinterConfig>>{};
      final missingPrinterAreas = <String>[];
      final areasByCode = <String, PrintArea>{};

      for (final areaCode in itemsByArea.keys) {
        final area = await _ensureAreaForCode(businessId, areaCode);
        areasByCode[areaCode] = area;

        final printers = await _getOrderPrintersWithOfflineFallback(
          businessId: businessId,
          areaId: area.id,
          areaCode: areaCode,
        );
        printersByAreaCode[areaCode] = printers;
        if (printers.isEmpty) {
          missingPrinterAreas.add(areaCode);
        }
      }

      if (missingPrinterAreas.isNotEmpty) {
        throw NoAssignedKitchenPrinterException(missingPrinterAreas);
      }

      // 6. Marcar orden como enviada a cocina solo cuando hay impresoras.
      await _salesRepo.sendToKitchen(orderId);

      final createdJobs = <String, String>{}; // areaCode -> local dispatch id

      for (final entry in itemsByArea.entries) {
        final areaCode = entry.key;
        final areaItems = entry.value;

        areasByCode[areaCode] ??= await _ensureAreaForCode(
          businessId,
          areaCode,
        );

        final printers = printersByAreaCode[areaCode] ?? const [];
        final dispatchId = _createLocalDispatchId(areaCode);
        createdJobs[areaCode] = dispatchId;

        final ticket = PrintTicketService.generateKitchenTicket(
          order: order,
          items: areaItems,
          tableName: orderData['tableName']?.toString() ?? 'N/A',
          waiterName: orderData['waiterName']?.toString(),
          businessName: businessName,
        );

        await _dispatchKitchenTicket(
          printers: printers,
          bytes: ticket.escPosCommands,
          areaCode: areaCode,
          fallbackData: {
            'title': 'COMANDA ${orderData['tableName'] ?? 'COCINA'}',
            'body':
                'Orden ${orderData['orderNumber'] ?? ''}\n'
                'Mesa: ${orderData['tableName'] ?? 'N/A'}\n'
                'Mesero: ${orderData['waiterName'] ?? 'N/A'}',
          },
        );
      }

      return createdJobs;
    } on NoAssignedKitchenPrinterException {
      rethrow;
    } catch (e) {
      throw Exception('Error al enviar orden a cocina: $e');
    }
  }

  Future<void> _dispatchKitchenTicket({
    required List<PrinterConfig> printers,
    required List<int> bytes,
    required String areaCode,
    required Map<String, dynamic> fallbackData,
  }) async {
    final errors = <String>[];
    String? firstPrintedPrinterId;

    for (final printer in printers) {
      try {
        await _printKitchenTicketToPrinter(
          printer: printer,
          bytes: bytes,
          areaCode: areaCode,
          fallbackData: fallbackData,
        );
        firstPrintedPrinterId ??= printer.id;
      } catch (e) {
        errors.add('${printer.name}: $e');
      }
    }

    if (firstPrintedPrinterId != null) {
      if (errors.isNotEmpty) {
        debugPrint(
          '⚠️ Impresión parcial en área $areaCode. Impresora exitosa: $firstPrintedPrinterId. Errores: ${errors.join(' | ')}',
        );
      }
      return;
    }

    if (errors.isNotEmpty) {
      throw Exception(errors.join(' | '));
    }
  }

  Future<void> _printKitchenTicketToPrinter({
    required PrinterConfig printer,
    required List<int> bytes,
    required String areaCode,
    required Map<String, dynamic> fallbackData,
  }) async {
    switch (printer.type) {
      case 'network':
        final ip = printer.ipAddress?.trim();
        if (ip == null || ip.isEmpty) {
          throw Exception('La impresora de red no tiene IP configurada.');
        }
        if (kIsWeb) {
          await _printingRepo.printRawViaAgent(
            ip: ip,
            port: printer.port ?? 9100,
            data: bytes,
          );
          return;
        }
        try {
          await _printingRepo.printRawDirectTcp(
            ip: ip,
            port: printer.port ?? 9100,
            data: bytes,
          );
        } catch (_) {
          await _printingRepo.printRawViaAgent(
            ip: ip,
            port: printer.port ?? 9100,
            data: bytes,
          );
        }
        return;
      case 'usb':
        await _printingRepo.printJobViaAgent({
          'id': 'KITCHEN-${DateTime.now().millisecondsSinceEpoch}',
          'printer': {
            'id': printer.id,
            'type': 'usb',
            'name': printer.name,
            'devicePath': printer.devicePath,
            'path': printer.devicePath,
          },
          'content': {
            'type': 'raw_base64',
            'dataBase64': base64Encode(bytes),
            'fallback': fallbackData,
          },
          'meta': {'areaCode': areaCode},
        });
        return;
      case 'bluetooth':
        throw Exception(
          'La autoimpresión de cocina no soporta Bluetooth todavía.',
        );
      default:
        throw Exception('Tipo de impresora no soportado: ${printer.type}.');
    }
  }

  /// Agrupar items por área de impresión
  Future<Map<String, List<OrderItem>>> _groupItemsByPrintArea(
    List<OrderItem> items,
  ) async {
    final itemsByArea = <String, List<OrderItem>>{};

    for (final item in items) {
      // Obtener área de impresión del item
      // Primero intentar desde el item directamente
      String areaCode = item.printAreaCode ?? 'kitchen_hot'; // Default

      // Si el item no tiene área asignada, obtener del menu_item
      if (item.printAreaCode == null && item.productId != null) {
        areaCode =
            await _getMenuItemPrintArea(item.productId!) ?? 'kitchen_hot';
      }

      // Agrupar
      if (!itemsByArea.containsKey(areaCode)) {
        itemsByArea[areaCode] = [];
      }
      itemsByArea[areaCode]!.add(item);
    }

    return itemsByArea;
  }

  /// Obtener área de impresión de un menu item
  Future<String?> _getMenuItemPrintArea(String productId) async {
    try {
      final data = await _client
          .from('menu_items')
          .select('print_area_code')
          .eq('id', productId)
          .maybeSingle();

      return data?['print_area_code'] as String?;
    } catch (e) {
      debugPrint('Error al obtener área de impresión: $e');
      return null;
    }
  }

  /// Obtener datos de la orden para mostrar en el ticket
  Future<Map<String, dynamic>> _getOrderDisplayData(String orderId) async {
    try {
      final data = await _client
          .from('orders')
          .select('''
            *,
            table_sessions!inner(
              dining_tables(label),
              users(full_name)
            )
          ''')
          .eq('id', orderId)
          .single();

      final tableSession = data['table_sessions'] as Map<String, dynamic>?;
      final diningTable =
          tableSession?['dining_tables'] as Map<String, dynamic>?;
      final user = tableSession?['users'] as Map<String, dynamic>?;

      return {
        'orderNumber': data['order_number'] ?? '',
        'tableName': diningTable?['label'] ?? 'N/A',
        'waiterName': user?['full_name'] ?? 'N/A',
        'peopleCount': tableSession?['people_count'] ?? 1,
        'createdAt': data['created_at'],
      };
    } catch (e) {
      debugPrint('Error al obtener datos de orden: $e');
      return {
        'orderNumber': '',
        'tableName': 'N/A',
        'waiterName': 'N/A',
        'peopleCount': 1,
        'createdAt': DateTime.now().toIso8601String(),
      };
    }
  }

  Future<String?> _getBusinessName(String businessId) async {
    try {
      final data = await _client
          .from('businesses')
          .select('business_name, branch_name')
          .eq('id', businessId)
          .maybeSingle();

      final branchName = data?['branch_name']?.toString().trim();
      if (branchName != null && branchName.isNotEmpty) {
        return branchName;
      }
      final businessName = data?['business_name']?.toString().trim();
      if (businessName != null && businessName.isNotEmpty) {
        return businessName;
      }
      return null;
    } catch (_) {
      return null;
    }
  }

  Future<PrintArea> _ensureAreaForCode(String businessId, String areaCode) async {
    // Primero intentar GET (todos los miembros del negocio tienen SELECT).
    final existing = await _printingRepo.getPrintAreaByCode(
      businessId: businessId,
      code: areaCode,
    );
    if (existing != null) return existing;

    // El área no existe: solo un admin puede crearla.
    // Intentamos la inserción y capturamos el error RLS para dar un mensaje claro.
    try {
      return await _printingRepo.ensurePrintArea(
        businessId: businessId,
        code: areaCode,
        name: _friendlyAreaName(areaCode),
      );
    } catch (_) {
      throw Exception(
        'El área de impresión "${_friendlyAreaName(areaCode)}" no está configurada. '
        'Un administrador debe ir a Ajustes → Impresoras y crear el área "$areaCode" '
        'antes de enviar a cocina.',
      );
    }
  }

  String _friendlyAreaName(String areaCode) {
    const areaNames = {
      'kitchen_hot': 'Cocina Caliente',
      'kitchen_cold': 'Cocina Fría',
      'bar': 'Bar',
      'cashier': 'Caja',
      'fiscal': 'Fiscal',
    };

    return areaNames[areaCode] ?? areaCode.toUpperCase();
  }

  Future<Map<String, String>> sendLocalOrderToKitchen({
    required String businessId,
    required CurrentOrderState localState,
    String tableName = 'LOCAL',
    String? waiterName,
    String? businessName,
  }) async {
    final order = localState.order;
    if (order == null) {
      throw Exception('No hay orden local para imprimir');
    }

    final draftItems = localState.items
        .where((item) => item.status == 'draft' || item.status == 'open')
        .toList(growable: false);
    if (draftItems.isEmpty) {
      throw Exception('No hay items locales pendientes de imprimir');
    }

    final itemsByArea = await _groupItemsByPrintArea(draftItems);
    final createdJobs = <String, String>{};

    for (final entry in itemsByArea.entries) {
      final areaCode = entry.key;
      final printers = await _readCachedOrderPrinters(
        businessId: businessId,
        areaCode: areaCode,
      );
      if (printers.isEmpty) {
        await _offlinePos.enqueuePrintJob(
          businessId: businessId,
          job: {
            'order_id': order.id,
            'area_code': areaCode,
            'reason': 'missing_cached_printer',
            'items': entry.value.map((item) => item.productName).toList(),
          },
        );
        throw Exception(
          'No hay impresoras cacheadas para $areaCode. Abre online una vez para guardar configuración.',
        );
      }

      final ticket = PrintTicketService.generateKitchenTicket(
        order: order,
        items: entry.value,
        tableName: tableName,
        waiterName: waiterName,
        businessName: businessName,
      );

      final dispatchId = _createLocalDispatchId(areaCode);
      createdJobs[areaCode] = dispatchId;

      await _dispatchKitchenTicket(
        printers: printers,
        bytes: ticket.escPosCommands,
        areaCode: areaCode,
        fallbackData: {
          'title': 'COMANDA $tableName',
          'body':
              'Orden local ${order.id}\n'
              'Mesa: $tableName\n'
              'Mesero: ${waiterName ?? 'N/A'}',
        },
      );
    }

    await _offlinePos.enqueueAction(
      businessId: businessId,
      action: {
        'type': 'confirm_local_order',
        'order_id': order.id,
        'origin': localState.origin,
        'item_count': draftItems.length,
      },
    );

    return createdJobs;
  }

  /// Reimprimir orden en un área específica
  Future<String> reprintOrderInArea({
    required String orderId,
    required String businessId,
    required String areaCode,
  }) async {
    try {
      final order = await _salesRepo.getOrder(orderId);
      if (order == null) {
        throw Exception('Orden no encontrada');
      }

      // Obtener items de la orden
      final items = await _salesRepo.getOrderItems(
        orderId,
        includeModifiers: true,
      );

      // Filtrar items por área
      final itemsByArea = await _groupItemsByPrintArea(items);
      final areaItems = itemsByArea[areaCode];

      if (areaItems == null || areaItems.isEmpty) {
        throw Exception('No hay items para el área $areaCode');
      }

      // Obtener datos de la orden
      final orderData = await _getOrderDisplayData(orderId);
      final businessName = await _getBusinessName(businessId);

      // Obtener área
      final areas = await _printingRepo.getPrintAreas(businessId);
      final area = areas.where((a) => a.code == areaCode).firstOrNull;

      if (area == null) {
        throw Exception('Área no encontrada: $areaCode');
      }

      final printers = await _getOrderPrintersWithOfflineFallback(
        businessId: businessId,
        areaId: area.id,
        areaCode: areaCode,
      );
      if (printers.isEmpty) {
        throw Exception('No hay impresoras asignadas al área $areaCode');
      }

      final ticket = PrintTicketService.generateKitchenTicket(
        order: order,
        items: areaItems,
        tableName: orderData['tableName']?.toString() ?? 'N/A',
        waiterName: orderData['waiterName']?.toString(),
        businessName: businessName,
      );

      final dispatchId = _createLocalDispatchId(areaCode);
      await _dispatchKitchenTicket(
        printers: printers,
        bytes: ticket.escPosCommands,
        areaCode: areaCode,
        fallbackData: {
          'title': 'COMANDA ${orderData['tableName'] ?? 'COCINA'}',
          'body':
              'Orden ${orderData['orderNumber'] ?? ''}\n'
              'Mesa: ${orderData['tableName'] ?? 'N/A'}\n'
              'Mesero: ${orderData['waiterName'] ?? 'N/A'}',
        },
      );

      return dispatchId;
    } catch (e) {
      throw Exception('Error al reimprimir: $e');
    }
  }

  String _createLocalDispatchId(String areaCode) {
    return 'LAN-$areaCode-${DateTime.now().microsecondsSinceEpoch}';
  }

  Future<List<PrinterConfig>> _getOrderPrintersWithOfflineFallback({
    required String businessId,
    required String areaId,
    required String areaCode,
  }) async {
    try {
      final printers = await _printingRepo.getOrderPrintersForArea(areaId);
      await _cacheOrderPrinters(
        businessId: businessId,
        areaCode: areaCode,
        printers: printers,
      );
      return printers;
    } catch (e) {
      debugPrint('⚠️ Usando cache local de impresoras para $areaCode: $e');
      return _readCachedOrderPrinters(
        businessId: businessId,
        areaCode: areaCode,
      );
    }
  }

  Future<void> _cacheOrderPrinters({
    required String businessId,
    required String areaCode,
    required List<PrinterConfig> printers,
  }) async {
    final storage = await StorageService.getInstance();
    await storage.writeList(
      'printing_cached_printers_${businessId}_$areaCode',
      printers.map((printer) => printer.toMap()).toList(growable: false),
    );
  }

  Future<List<PrinterConfig>> _readCachedOrderPrinters({
    required String businessId,
    required String areaCode,
  }) async {
    final storage = await StorageService.getInstance();
    final cached = await storage.readList(
      'printing_cached_printers_${businessId}_$areaCode',
    );
    if (cached == null) return const [];
    return cached
        .map(
          (row) => PrinterConfig.fromMap(Map<String, dynamic>.from(row as Map)),
        )
        .toList(growable: false);
  }

  /// Obtener resumen de impresión de una orden
  Future<Map<String, dynamic>> getOrderPrintSummary(String orderId) async {
    try {
      final items = await _salesRepo.getOrderItems(orderId);
      final itemsByArea = await _groupItemsByPrintArea(items);

      final summary = <String, dynamic>{};

      for (final entry in itemsByArea.entries) {
        summary[entry.key] = {
          'itemCount': entry.value.length,
          'items': entry.value.map((i) => i.productName).toList(),
        };
      }

      return summary;
    } catch (e) {
      throw Exception('Error al obtener resumen: $e');
    }
  }
}

/// Extensión para OrderItem con área de impresión
extension OrderItemPrintArea on OrderItem {
  String? get printAreaCode {
    // Si el item tiene el campo directamente
    // Esto requeriría agregar el campo a OrderItem
    // Por ahora retornamos null y se obtiene del menu_item
    return null;
  }
}
