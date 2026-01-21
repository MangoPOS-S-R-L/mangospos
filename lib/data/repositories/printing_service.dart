// lib/data/repositories/printing_service.dart
import 'package:supabase_flutter/supabase_flutter.dart';
import '../models/sales_models.dart';
import 'printing_repository.dart';
import 'sales_repository.dart';

/// 🖨️ Servicio de Impresión con Agrupación por Departamento
/// Maneja la lógica de envío de órdenes a diferentes áreas de impresión
class PrintingService {
  final SupabaseClient _client;
  late final PrintingRepository _printingRepo;
  late final SalesRepository _salesRepo;

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

      if (items.isEmpty) {
        throw Exception('La orden no tiene items');
      }

      // 3. Obtener información adicional para el ticket
      final orderData = await _getOrderDisplayData(orderId);

      // 4. Agrupar items por área de impresión
      final itemsByArea = await _groupItemsByPrintArea(items);

      // 5. Crear trabajos de impresión para cada área
      final createdJobs = <String, String>{}; // areaCode -> jobId

      for (final entry in itemsByArea.entries) {
        final areaCode = entry.key;
        final areaItems = entry.value;

        // Obtener área por código
        final areas = await _printingRepo.getPrintAreas(businessId);
        final area = areas.where((a) => a.code == areaCode).firstOrNull;

        if (area == null) {
          print(
            '⚠️ Área no encontrada: $areaCode - Creando automáticamente...',
          );
          // Crear área automáticamente si no existe
          final newAreaId = await _createDefaultArea(businessId, areaCode);

          // Crear job con el área nueva
          final jobId = await _createKitchenPrintJob(
            businessId: businessId,
            areaId: newAreaId,
            orderId: orderId,
            items: areaItems,
            orderData: orderData,
          );

          createdJobs[areaCode] = jobId;
          continue;
        }

        // Verificar que el área tenga impresoras asignadas
        final printers = await _printingRepo.getPrintersForArea(area.id);

        if (printers.isEmpty) {
          print('⚠️ Área "$areaCode" no tiene impresoras asignadas');
          // Continuar de todas formas - el job quedará pendiente
        }

        // Crear trabajo de impresión
        final jobId = await _createKitchenPrintJob(
          businessId: businessId,
          areaId: area.id,
          orderId: orderId,
          items: areaItems,
          orderData: orderData,
        );

        createdJobs[areaCode] = jobId;
      }

      // 6. Marcar orden como enviada a cocina
      await _salesRepo.sendToKitchen(orderId);

      return createdJobs;
    } catch (e) {
      throw Exception('Error al enviar orden a cocina: $e');
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
      print('Error al obtener área de impresión: $e');
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
      print('Error al obtener datos de orden: $e');
      return {
        'orderNumber': '',
        'tableName': 'N/A',
        'waiterName': 'N/A',
        'peopleCount': 1,
        'createdAt': DateTime.now().toIso8601String(),
      };
    }
  }

  /// Crear trabajo de impresión para cocina
  Future<String> _createKitchenPrintJob({
    required String businessId,
    required String areaId,
    required String orderId,
    required List<OrderItem> items,
    required Map<String, dynamic> orderData,
  }) async {
    // Preparar datos del ticket
    final ticketData = {
      'orderNumber': orderData['orderNumber'],
      'tableName': orderData['tableName'],
      'waiterName': orderData['waiterName'],
      'peopleCount': orderData['peopleCount'],
      'timestamp': DateTime.now().toIso8601String(),
      'items': items
          .map(
            (item) => {
              'name': item.productName,
              'quantity': item.quantity,
              'notes': item.notes,
              'isTakeout': item.isTakeout,
              'modifiers': item.modifiers
                  .map((m) => {'name': m.name, 'quantity': m.qty})
                  .toList(),
            },
          )
          .toList(),
    };

    // Crear trabajo de impresión
    final job = await _printingRepo.createPrintJob(
      businessId: businessId,
      areaId: areaId,
      type: 'kitchen_order',
      orderId: orderId,
      data: ticketData,
    );

    return job.id;
  }

  /// Crear área por defecto si no existe
  Future<String> _createDefaultArea(String businessId, String areaCode) async {
    // Mapeo de códigos a nombres amigables
    final areaNames = {
      'kitchen_hot': 'Cocina Caliente',
      'kitchen_cold': 'Cocina Fría',
      'bar': 'Bar',
      'cashier': 'Caja',
      'fiscal': 'Fiscal',
    };

    final areaName = areaNames[areaCode] ?? areaCode.toUpperCase();

    final area = await _printingRepo.createArea(
      businessId: businessId,
      name: areaName,
      code: areaCode,
    );

    return area.id;
  }

  /// Reimprimir orden en un área específica
  Future<String> reprintOrderInArea({
    required String orderId,
    required String businessId,
    required String areaCode,
  }) async {
    try {
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

      // Obtener área
      final areas = await _printingRepo.getPrintAreas(businessId);
      final area = areas.where((a) => a.code == areaCode).firstOrNull;

      if (area == null) {
        throw Exception('Área no encontrada: $areaCode');
      }

      // Crear trabajo de impresión
      final jobId = await _createKitchenPrintJob(
        businessId: businessId,
        areaId: area.id,
        orderId: orderId,
        items: areaItems,
        orderData: orderData,
      );

      return jobId;
    } catch (e) {
      throw Exception('Error al reimprimir: $e');
    }
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
